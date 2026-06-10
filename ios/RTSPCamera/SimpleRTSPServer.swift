import Foundation
import Network

class SimpleRTSPServer {
    private let port: UInt16
    private let path: String
    private let videoCodec: String
    private let audioEnabled: Bool
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.gld.rtsp_camera.rtspServerQueue")
    private var isRunning = false
    
    // Callbacks to communicate with StreamManager/MainActivity equivalent
    var onSessionPlay: ((String, UInt16, UInt16, Bool, NWConnection?, Int, Int) -> Void)?
    var onSessionStop: (() -> Void)?
    var onClientChange: ((String?) -> Void)?
    
    // Active sessions: IP:Port -> Session
    private var activeSession: RTSPSession?
    
    // SPS, PPS, VPS data providers
    var getSps: (() -> Data?)?
    var getPps: (() -> Data?)?
    var getVps: (() -> Data?)?
    
    init(port: UInt16, path: String, videoCodec: String, audioEnabled: Bool) {
        self.port = port
        self.path = path
        self.videoCodec = videoCodec.lowercased()
        self.audioEnabled = audioEnabled
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("RTSP Server listening on port \(self.port)")
                case .failed(let error):
                    print("RTSP Server listener failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.start(queue: queue)
            isRunning = true
        } catch {
            print("Failed to start RTSP listener: \(error)")
        }
    }
    
    func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
        
        activeSession?.close()
        activeSession = nil
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let clientIp = self.getIPAddress(from: connection.endpoint) ?? "Unknown"
            
            if self.activeSession != nil {
                print("Rejecting connection from \(clientIp) — single client limit reached")
                // Reject with 453 Not Enough Bandwidth
                let response = "RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: 0\r\n\r\n"
                connection.start(queue: self.queue)
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
                return
            }
            
            print("Accepted RTSP connection from \(clientIp)")
            self.onClientChange?(clientIp)
            
            let session = RTSPSession(connection: connection, server: self)
            self.activeSession = session
            session.start()
        }
    }
    
    fileprivate func clearSession() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.activeSession = nil
            self.onClientChange?(nil)
            self.onSessionStop?()
        }
    }
    
    private func getIPAddress(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            return host.description
        default:
            return nil
        }
    }
}

// MARK: - RTSP Session
private class RTSPSession {
    private let connection: NWConnection
    private weak var server: SimpleRTSPServer?
    private let queue = DispatchQueue(label: "com.gld.rtsp_camera.sessionHandlerQueue")
    
    private var cSeq = 0
    private var clientVideoPort: UInt16 = 0
    private var clientAudioPort: UInt16 = 0
    private var isPlaying = false
    private let rtspSessionId = String(format: "%08X", UInt32.random(in: 0...UInt32.max))
    
    private var useTcp = false
    private var videoTcpChannel = 0
    private var audioTcpChannel = 2
    
    private var requestBuffer = Data()
    
    init(connection: NWConnection, server: SimpleRTSPServer) {
        self.connection = connection
        self.server = server
    }
    
    func start() {
        connection.start(queue: queue)
        readNext()
    }
    
    func close() {
        connection.cancel()
        if isPlaying {
            isPlaying = false
        }
    }
    
    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Session read error: \(error)")
                self.handleDisconnect()
                return
            }
            
            if isComplete {
                self.handleDisconnect()
                return
            }
            
            if let data = data, !data.isEmpty {
                self.requestBuffer.append(data)
                self.processBuffer()
            }
            
            self.readNext()
        }
    }
    
    private func processBuffer() {
        // Look for end of headers marker \r\n\r\n (0x0D 0x0A 0x0D 0x0A)
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = requestBuffer.range(of: delimiter) else { return }
        
        let requestData = requestBuffer.subdata(in: 0..<range.upperBound)
        requestBuffer.removeSubrange(0..<range.upperBound)
        
        if let requestString = String(data: requestData, encoding: .utf8) {
            let response = processRequest(requestString)
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in }))
        }
    }
    
    private func processRequest(_ request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return buildResponse("400 Bad Request", "") }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 3 else { return buildResponse("400 Bad Request", "") }
        
        let method = parts[0]
        let url = parts[1]
        
        // Parse CSeq
        for line in lines {
            if line.lowercased().hasPrefix("cseq:") {
                let seqStr = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cSeq = Int(seqStr) ?? 0
            }
        }
        
        print("RTSP \(method) for \(url)")
        
        switch method {
        case "OPTIONS":
            return buildResponse("200 OK", "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER")
            
        case "DESCRIBE":
            let sdp = buildSDP()
            return buildResponse(
                "200 OK",
                "Content-Type: application/sdp\r\nContent-Length: \(sdp.utf8.count)",
                sdp
            )
            
        case "SETUP":
            var transportHeader = ""
            for line in lines {
                if line.lowercased().hasPrefix("transport:") {
                    transportHeader = line
                    break
                }
            }
            
            let isTcpRequest = transportHeader.lowercased().contains("tcp") || transportHeader.lowercased().contains("interleaved")
            
            // Extract ports
            var clientPort: UInt16 = 0
            if let portRangeRange = transportHeader.range(of: "client_port=") {
                let portsSubstring = transportHeader[portRangeRange.upperBound...]
                let ports = portsSubstring.components(separatedBy: ";").first?.components(separatedBy: "-") ?? []
                if let firstPort = ports.first, let portVal = UInt16(firstPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    clientPort = portVal
                }
            }
            
            if isTcpRequest {
                useTcp = true
                if let interleavedRangeRange = transportHeader.range(of: "interleaved=") {
                    let channelsSubstring = transportHeader[interleavedRangeRange.upperBound...]
                    let channels = channelsSubstring.components(separatedBy: ";").first?.components(separatedBy: "-") ?? []
                    if let firstChannel = channels.first, let channelVal = Int(firstChannel.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        if url.contains("track0") {
                            videoTcpChannel = channelVal
                        } else if url.contains("track1") {
                            audioTcpChannel = channelVal
                        }
                    }
                }
            }
            
            var transportResp = ""
            if useTcp {
                let ch = url.contains("track0") ? videoTcpChannel : audioTcpChannel
                transportResp = "Transport: RTP/AVP/TCP;unicast;interleaved=\(ch)-\(ch+1)\r\nSession: \(rtspSessionId)"
            } else {
                if url.contains("track0") {
                    clientVideoPort = clientPort
                } else if url.contains("track1") {
                    clientAudioPort = clientPort
                }
                let serverPortRange = url.contains("track0") ? "50000-50001" : "50002-50003"
                transportResp = "Transport: RTP/AVP;unicast;client_port=\(clientPort)-\(clientPort+1);server_port=\(serverPortRange)\r\nSession: \(rtspSessionId)"
            }
            return buildResponse("200 OK", transportResp)
            
        case "PLAY":
            if !isPlaying {
                isPlaying = true
                let clientIp = getClientIp()
                server?.onSessionPlay?(clientIp, clientVideoPort, clientAudioPort, useTcp, connection, videoTcpChannel, audioTcpChannel)
            }
            return buildResponse("200 OK", "Session: \(rtspSessionId)")
            
        case "TEARDOWN":
            handleDisconnect()
            return buildResponse("200 OK", "Session: \(rtspSessionId)")
            
        case "GET_PARAMETER", "SET_PARAMETER":
            return buildResponse("200 OK", "Session: \(rtspSessionId)")
            
        default:
            return buildResponse("200 OK", "Session: \(rtspSessionId)")
        }
    }
    
    private func buildSDP() -> String {
        guard let server = server else { return "" }
        let isH265 = (server.videoCodec == "h265")
        
        let sps = server.getSps?()
        let pps = server.getPps?()
        let vps = server.getVps?()
        
        let ip = Utils.getIPAddress()
        let base = "rtsp://\(ip):\(server.port)\(server.path)"
        
        var videoSection = ""
        if isH265 {
            var sprop = ""
            if let vps = vps, let sps = sps, let pps = pps {
                let vpsB64 = extractNAL(vps).base64EncodedString()
                let spsB64 = extractNAL(sps).base64EncodedString()
                let ppsB64 = extractNAL(pps).base64EncodedString()
                sprop = " sprop-vps=\(vpsB64);sprop-sps=\(spsB64);sprop-pps=\(ppsB64)"
            }
            videoSection = "m=video 0 RTP/AVP 96\r\n" +
                           "a=rtpmap:96 H265/90000\r\n" +
                           "a=fmtp:96\(sprop)\r\n" +
                           "a=control:\(base)/track0\r\n"
        } else {
            var sprop = ""
            if let sps = sps, let pps = pps {
                let spsB64 = extractNAL(sps).base64EncodedString()
                let ppsB64 = extractNAL(pps).base64EncodedString()
                sprop = ";sprop-parameter-sets=\(spsB64),\(ppsB64)"
            }
            // Baseline Profile level ID default: 640029 or 42e01f
            let profileLevelId = "42e01f"
            videoSection = "m=video 0 RTP/AVP 96\r\n" +
                           "a=rtpmap:96 H264/90000\r\n" +
                           "a=fmtp:96 packetization-mode=1;profile-level-id=\(profileLevelId)\(sprop)\r\n" +
                           "a=control:\(base)/track0\r\n"
        }
        
        let audioSection = server.audioEnabled ?
            "m=audio 0 RTP/AVP 97\r\n" +
            "a=rtpmap:97 mpeg4-generic/44100/1\r\n" +
            "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1210\r\n" +
            "a=control:\(base)/track1\r\n" : ""
            
        return "v=0\r\n" +
               "o=- 0 0 IN IP4 \(ip)\r\n" +
               "s=RTSP Camera\r\n" +
               "c=IN IP4 0.0.0.0\r\n" +
               "t=0 0\r\n" +
               "a=range:npt=now-\r\n" +
               videoSection +
               audioSection
    }
    
    private func extractNAL(_ data: Data) -> Data {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        } else if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }
    
    private func buildResponse(_ status: String, _ headers: String, _ body: String = "") -> String {
        return "RTSP/1.0 \(status)\r\nCSeq: \(cSeq)\r\n\(headers)\r\n\r\n\(body)"
    }
    
    private func getClientIp() -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return host.description
        default:
            return "127.0.0.1"
        }
    }
    
    private func handleDisconnect() {
        connection.cancel()
        server?.clearSession()
    }
}
