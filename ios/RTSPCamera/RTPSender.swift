import Foundation
import Network
import QuartzCore

// MARK: - RTCPSender (Sends RTCP Sender Reports)
class RTCPSender {
    private var connection: NWConnection?
    private let ssrc: UInt32
    private let clockRate: UInt32
    private let queue = DispatchQueue(label: "com.gld.rtsp_camera.rtcpSenderQueue")
    private var isRunning = false
    
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private var lastRtpTimestamp: UInt32 = 0
    
    private let ntpEpochOffset: UInt64 = 2208988800
    private let srInterval: TimeInterval = 5.0
    
    // ABR callback for packet loss feedback
    var onPacketLoss: ((UInt8) -> Void)?
    
    init(clientHost: String, clientPort: UInt16, localPort: UInt16?, ssrc: UInt32, clockRate: UInt32) {
        self.ssrc = ssrc
        self.clockRate = clockRate
        
        let host = NWEndpoint.Host(clientHost)
        let port = NWEndpoint.Port(integerLiteral: clientPort)
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        if let local = localPort {
            let isClientIpv6 = clientHost.contains(":")
            let localHost: NWEndpoint.Host = isClientIpv6 ? .ipv6(.any) : .ipv4(.any)
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: localHost, port: NWEndpoint.Port(integerLiteral: local))
        }
        self.connection = NWConnection(host: host, port: port, using: parameters)
    }
    
    func start() {
        guard let connection = connection else { return }
        isRunning = true
        
        let clientHostDesc = String(describing: connection.endpoint)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[RTSPCamera] RTCPSender UDP connection to \(clientHostDesc) ready")
            case .failed(let error):
                print("[RTSPCamera] RTCPSender UDP connection failed: \(error)")
            case .waiting(let error):
                print("[RTSPCamera] RTCPSender UDP connection waiting: \(error)")
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        scheduleNextSenderReport()
    }
    
    func stop() {
        isRunning = false
        connection?.cancel()
        connection = nil
    }
    
    func reportPacket(length: Int) {
        queue.async {
            self.packetCount += 1
            self.octetCount += UInt32(length)
        }
    }
    
    func updateRtpTimestamp(_ ts: UInt32) {
        queue.async {
            self.lastRtpTimestamp = ts
        }
    }
    
    private func scheduleNextSenderReport() {
        guard isRunning else { return }
        
        queue.asyncAfter(deadline: .now() + srInterval) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.sendSenderReport()
            self.scheduleNextSenderReport()
        }
    }
    
    private func sendSenderReport() {
        let now = Date().timeIntervalSince1970
        let ntpSeconds = UInt64(now) + ntpEpochOffset
        let ntpFraction = UInt64((now - floor(now)) * Double(UInt64.max)) // 64-bit fraction
        let ntpFraction32 = UInt32(ntpFraction >> 32)
        
        var srBuffer = Data(repeating: 0, count: 28)
        
        // Header: V=2, P=0, RC=0 -> 0x80; PT=200 (SR) -> 0xC8; length=6 (28 bytes total / 4 = 7 words - 1 = 6)
        srBuffer[0] = 0x80
        srBuffer[1] = 0xC8
        srBuffer[2] = 0x00
        srBuffer[3] = 0x06
        
        // SSRC
        srBuffer[4...7] = Data(withUnsafeBytes(of: ssrc.bigEndian) { Data($0) })
        
        // NTP timestamp (64-bit)
        srBuffer[8...11] = Data(withUnsafeBytes(of: UInt32(ntpSeconds).bigEndian) { Data($0) })
        srBuffer[12...15] = Data(withUnsafeBytes(of: ntpFraction32.bigEndian) { Data($0) })
        
        // RTP timestamp
        srBuffer[16...19] = Data(withUnsafeBytes(of: lastRtpTimestamp.bigEndian) { Data($0) })
        
        // Packet count
        srBuffer[20...23] = Data(withUnsafeBytes(of: packetCount.bigEndian) { Data($0) })
        
        // Octet count
        srBuffer[24...27] = Data(withUnsafeBytes(of: octetCount.bigEndian) { Data($0) })
        
        connection?.send(content: srBuffer, completion: .contentProcessed({ _ in }))
        
        // Try to receive RTCP RR for ABR feedback
        receiveRTCP()
    }
    
    private func receiveRTCP() {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1500) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else { return }
            
            // Parse RTCP RR (Receiver Report)
            if data.count >= 28 {
                let pt = data[1]
                if pt == 201 { // PT=201 is RR
                    // Extract fraction lost from byte 12
                    if data.count >= 13 {
                        let fractionLost = data[12]
                        self.onPacketLoss?(fractionLost)
                    }
                }
            }
        }
    }
}


// MARK: - RTPSender (Handles both Video H.264/H.265 and Audio AAC RTP transmission)
class RTPSender {
    var onPacketLoss: ((UInt8) -> Void)?
    private let clientHost: String
    private let clientPort: UInt16
    private let localPort: UInt16?
    private let isTcp: Bool
    private let codec: String
    private let tcpChannel: Int
    
    private var tcpConnection: NWConnection?
    private var rtpUdpConnection: NWConnection?
    private var rtcpUdpConnection: NWConnection?
    
    private let queue = DispatchQueue(label: "com.gld.rtsp_camera.rtpSenderQueue", qos: .userInteractive)

    /// Shared serial queue for all TCP writes to a given connection.
    /// Video and audio RTPSenders share the same NWConnection in TCP interleaved mode;
    /// without serialization, concurrent `NWConnection.send` calls from each sender's
    /// queue can interleave the 4-byte `$|ch|len` interleaved headers, corrupting the
    /// client's RTSP/RTP demuxer. Routing every actual socket write through this single
    /// serial queue guarantees strict FIFO ordering on the byte stream.
    static let sharedTcpWriteQueue = DispatchQueue(label: "com.gld.rtsp_camera.tcpWriteQueue", qos: .userInteractive)

    /// Bounded concurrency for the shared TCP write queue.  At most this many writes
    /// may be pending on sharedTcpWriteQueue; when the limit is hit sendRawTcp blocks
    /// its caller (which runs on the per-sender serial queue), which blocks the sender
    /// queue, which stops sendVideoFrame from signalling its per-frame semaphore,
    /// which finally propagates backpressure to the FrameReader → FrameProvider chain.
    /// This matches Android's natural backpressure from blocking OutputStream.write().
    static let tcpWriteSlot = DispatchSemaphore(value: 4)

    /// Set true when the sender is stopped or its connection is known to be dead.
    /// Checked at the entry of sendVideoFrame/sendAudioFrame to drop work early instead
    /// of repeatedly sending into a cancelled connection.
    private var isStopped = false
    private let stopLock = NSLock()

    private var sequenceNumber: UInt16 = UInt16.random(in: 0...65535)
    private var ssrc: UInt32 = UInt32.random(in: 0...UInt32.max)
    private var timestamp: UInt32 = 0
    private let sharedState: SharedStreamState
    
    private var rtcpSender: RTCPSender?
    private var sentCodecConfig = false
    private var tcpBatchData = Data()
    private var isBatching = false
    private let maxPacketSize = 1400
    private var debugFrameCount = 0
    private var debugByteCount = 0



    // Config params
    private let isH265: Bool
    private let clockRate: UInt32
    
    // Video provider refs
    private var getSps: (() -> Data?)?
    private var getPps: (() -> Data?)?
    private var getVps: (() -> Data?)? // For H.265
    
    init(clientHost: String,
         clientPort: UInt16,
         localPort: UInt16? = nil,
         codec: String,
         isTcp: Bool,
         tcpConnection: NWConnection?,
         tcpChannel: Int,
         clockRate: UInt32 = 90000,
         sharedState: SharedStreamState,
         getSps: (() -> Data?)? = nil,
         getPps: (() -> Data?)? = nil,
         getVps: (() -> Data?)? = nil) {
        
        self.clientHost = clientHost
        self.clientPort = clientPort
        self.localPort = localPort
        self.codec = codec.lowercased()
        self.isH265 = (self.codec == "h265")
        self.isTcp = isTcp
        self.tcpConnection = tcpConnection
        self.tcpChannel = tcpChannel
        self.clockRate = clockRate
        self.sharedState = sharedState
        
        self.getSps = getSps
        self.getPps = getPps
        self.getVps = getVps
    }
    
    func start() {
        print("[RTSPCamera] RTPSender \(codec) start() called, isTcp=\(isTcp), tcpConnection=\(tcpConnection != nil ? "valid" : "nil")")
        // Clear the stopped flag for this (re)start
        stopLock.lock()
        isStopped = false
        stopLock.unlock()
        queue.async { [weak self] in
            guard let self = self else { return }
            print("[RTSPCamera] RTPSender \(self.codec) starting: host=\(self.clientHost), port=\(self.clientPort), isTcp=\(self.isTcp), localPort=\(self.localPort ?? 0)")
            
            if !self.isTcp {
                // Initialize UDP sockets
                let host = NWEndpoint.Host(self.clientHost)
                let rtpPort = NWEndpoint.Port(integerLiteral: self.clientPort)
                let rtcpPort = NWEndpoint.Port(integerLiteral: self.clientPort + 1)
                
                let rtpParams = NWParameters.udp
                rtpParams.allowLocalEndpointReuse = true
                if let local = self.localPort {
                    let isClientIpv6 = self.clientHost.contains(":")
                    let localHost: NWEndpoint.Host = isClientIpv6 ? .ipv6(.any) : .ipv4(.any)
                    rtpParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: localHost, port: NWEndpoint.Port(integerLiteral: local))
                }
                
                let rtpConn = NWConnection(host: host, port: rtpPort, using: rtpParams)
                self.rtpUdpConnection = rtpConn
                
                rtpConn.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        print("[RTSPCamera] RTPSender \(self.codec) UDP connection to \(self.clientHost):\(self.clientPort) ready")
                    case .failed(let error):
                        print("[RTSPCamera] RTPSender \(self.codec) UDP connection failed: \(error)")
                    case .waiting(let error):
                        print("[RTSPCamera] RTPSender \(self.codec) UDP connection waiting: \(error)")
                    default:
                        break
                    }
                }
                
                rtpConn.start(queue: self.queue)
                
                let rtcpParams = NWParameters.udp
                rtcpParams.allowLocalEndpointReuse = true
                if let local = self.localPort {
                    let rtcpLocalPort = local + 1
                    let isClientIpv6 = self.clientHost.contains(":")
                    let localHost: NWEndpoint.Host = isClientIpv6 ? .ipv6(.any) : .ipv4(.any)
                    rtcpParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: localHost, port: NWEndpoint.Port(integerLiteral: rtcpLocalPort))
                }
                self.rtcpUdpConnection = NWConnection(host: host, port: rtcpPort, using: rtcpParams)
                
                let rtcpLocal = self.localPort != nil ? self.localPort! + 1 : nil
                let rtcp = RTCPSender(clientHost: self.clientHost, clientPort: self.clientPort + 1, localPort: rtcpLocal, ssrc: self.ssrc, clockRate: self.clockRate)
                rtcp.onPacketLoss = { [weak self] fractionLost in
                    self?.onPacketLoss?(fractionLost)
                }
                self.rtcpSender = rtcp
                rtcp.start()
            }
        }
    }
    
    func stop() {
        // Mark stopped immediately so in-flight sendVideoFrame/sendAudioFrame calls
        // short-circuit instead of queueing more work onto a connection we're tearing down.
        stopLock.lock()
        isStopped = true
        stopLock.unlock()

        // Unblock any threads waiting on the backpressure semaphore (up to the slot
        // depth). Each unblocked thread will see isStopped==true, signal back, and
        // return — so the semaphore balance stays correct.
        for _ in 0..<4 { RTPSender.tcpWriteSlot.signal() }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.rtcpSender?.stop()
            self.rtcpSender = nil

            self.rtpUdpConnection?.cancel()
            self.rtpUdpConnection = nil
            self.rtcpUdpConnection?.cancel()
            self.rtcpUdpConnection = nil

            self.tcpConnection = nil
        }
    }

    private func isStoppedFlag() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return isStopped
    }
    
    func resetSPSPPS() {
        queue.async {
            self.sentCodecConfig = false
        }
    }
    
    // MARK: - Sending Frames

    func sendVideoFrame(data: Data, timestampUs: Int64, isKeyFrame: Bool) {
        // Drop work early if this sender has been stopped (client disconnect / teardown).
        if isStoppedFlag() { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isStoppedFlag() { return }

            self.isBatching = true
            self.tcpBatchData.removeAll(keepingCapacity: true)
            // Pre-reserve a typical frame's worth of capacity (RTP payload + per-fragment
            // interleaved headers) so the batch append loop does not trigger repeated
            // Data reallocations/copies while assembling the ~32 fragments of a P-frame.
            self.tcpBatchData.reserveCapacity(80 * 1024)

            // Maintain timestamp (relative to the first frame of this session)
            let startPts = self.sharedState.getOrSetStartPts(timestampUs)
            let relativePtsUs = timestampUs - startPts
            self.timestamp = UInt32((relativePtsUs * Int64(self.clockRate) / 1000000) & 0xFFFFFFFF)

            self.debugFrameCount += 1
            self.debugByteCount += data.count
            if self.debugFrameCount <= 2 || self.debugFrameCount % 150 == 0 {
                print("[RTSPCamera] RTPSender \(self.codec) frame #\(self.debugFrameCount), size=\(data.count)B, keyframe=\(isKeyFrame), isTcp=\(self.isTcp), channel=\(self.tcpChannel)")
            }

            if isKeyFrame && !self.sentCodecConfig {
                let sent = self.isH265 ? self.sendVpsSpsPps() : self.sendStapA()
                self.sentCodecConfig = sent
                print("[RTSPCamera] RTPSender \(self.codec) sent codec config (VPS/SPS/PPS): \(sent)")
            }

            // Search NALUs inside Annex-B
            var i = 0
            let length = data.count
            var packetCount = 0
            while i < length - 3 {
                var startCodeSize = 0
                if data[i] == 0 && data[i + 1] == 0 {
                    if data[i + 2] == 1 {
                        startCodeSize = 3
                    } else if i + 3 < length && data[i + 2] == 0 && data[i + 3] == 1 {
                        startCodeSize = 4
                    }
                }

                if startCodeSize > 0 {
                    let start = i + startCodeSize
                    let end = self.findNextStartCode(data: data, start: start)
                    let nalSize = end - start

                    if nalSize > 0 {
                        let isLastNALU = (end == length)
                        if nalSize <= self.maxPacketSize {
                            self.sendSingleNALUPacket(data: data, offset: start, size: nalSize, marker: isLastNALU)
                            packetCount += 1
                        } else {
                            self.sendFUAPackets(data: data, offset: start, size: nalSize, marker: isLastNALU)
                            packetCount += (nalSize + self.maxPacketSize - 1) / self.maxPacketSize
                        }
                    }
                    i = end
                } else {
                    i += 1
                }
            }

            self.isBatching = false
            self.flushTcpBatch()

            self.rtcpSender?.updateRtpTimestamp(self.timestamp)

            // Pacing sleep: for large I-frames on UDP, spread packet transmission slightly to avoid burst packet loss
            if !self.isTcp && packetCount > 10 {
                usleep(500)
            }
        }
    }
    
    func sendAudioFrame(data: Data, timestampUs: Int64) {
        // Drop work early if this sender has been stopped (client disconnect / teardown).
        if isStoppedFlag() { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isStoppedFlag() { return }

            // Maintain timestamp
            let startPts = self.sharedState.getOrSetStartPts(timestampUs)
            let relativePtsUs = timestampUs - startPts
            self.timestamp = UInt32((relativePtsUs * Int64(self.clockRate) / 1000000) & 0xFFFFFFFF)
            
            self.debugFrameCount += 1
            self.debugByteCount += data.count
            if self.debugFrameCount % 200 == 0 {
                print("[RTSPCamera] RTPSender \(self.codec) sent \(self.debugFrameCount) frames (\(self.debugByteCount) bytes)")
            }
            
            // RFC 3640 AAC
            let rtpHeaderSize = 12
            let auHeaderSize = 4
            let totalLen = rtpHeaderSize + auHeaderSize + data.count
            
            var rtpBuffer = Data(repeating: 0, count: totalLen)
            self.writeRTPHeader(packet: &rtpBuffer, marker: true, payloadType: 97)
            
            // AU-headers-length (16 bits value = 16)
            rtpBuffer[rtpHeaderSize] = 0
            rtpBuffer[rtpHeaderSize + 1] = 16
            
            // AU-header: size(13bits) + index(3bits)
            let auHeader = UInt16((data.count << 3) & 0xFFF8)
            rtpBuffer[rtpHeaderSize + 2] = UInt8((auHeader >> 8) & 0xFF)
            rtpBuffer[rtpHeaderSize + 3] = UInt8(auHeader & 0xFF)
            
            rtpBuffer.replaceSubrange(rtpHeaderSize + auHeaderSize..<rtpBuffer.count, with: data)
            
            self.sendPacket(data: rtpBuffer)
            self.rtcpSender?.updateRtpTimestamp(self.timestamp)
        }
    }
    
    // MARK: - Internal Packetization
    
    private func findNextStartCode(data: Data, start: Int) -> Int {
        var i = start
        let limit = data.count - 3
        while i < limit {
            if data[i] == 0 && data[i + 1] == 0 {
                if data[i + 2] == 1 { return i }
                if i + 3 < data.count && data[i + 2] == 0 && data[i + 3] == 1 { return i }
                i += 2
            } else {
                i += 1
            }
        }
        return data.count
    }
    
    private func getNalType(data: Data, offset: Int) -> UInt8 {
        let b = data[offset]
        if isH265 {
            return (b >> 1) & 0x3F
        } else {
            return b & 0x1F
        }
    }
    
    private func sendSingleNALUPacket(data: Data, offset: Int, size: Int, marker: Bool) {
        var packet = Data(repeating: 0, count: 12 + size)
        writeRTPHeader(packet: &packet, marker: marker, payloadType: 96)
        packet[12...] = data[offset..<(offset + size)]
        sendPacket(data: packet)
    }
    
    private func sendFUAPackets(data: Data, offset: Int, size: Int, marker: Bool) {
        let nalType = getNalType(data: data, offset: offset)
        let nalHeaderSize = isH265 ? 2 : 1
        let fuOverhead = isH265 ? 3 : 2
        
        let fuIndicator: UInt8
        let fuPayloadHdrByte2: UInt8
        let fuHeaderStart: UInt8
        let fuHeaderMid: UInt8
        let fuHeaderEnd: UInt8
        
        if isH265 {
            let origByte1 = data[offset]
            let origByte2 = data[offset + 1]
            fuIndicator = (origByte1 & 0x81) | 0x62 // type=49 (FU)
            fuPayloadHdrByte2 = origByte2
            fuHeaderStart = 0x80 | nalType
            fuHeaderMid = nalType
            fuHeaderEnd = 0x40 | nalType
        } else {
            let nalRefIdc = (data[offset] & 0x60) >> 5
            fuIndicator = (nalRefIdc << 5) | 28 // type=28 (FU-A)
            fuPayloadHdrByte2 = 0
            fuHeaderStart = 0x80 | nalType
            fuHeaderMid = nalType
            fuHeaderEnd = 0x40 | nalType
        }
        
        var currentOffset = offset + nalHeaderSize
        let endOffset = offset + size
        var firstPacket = true
        
        while currentOffset < endOffset {
            let remaining = endOffset - currentOffset
            let chunkSize = min(maxPacketSize - fuOverhead, remaining)
            let lastPacket = (currentOffset + chunkSize) >= endOffset
            
            var packet = Data(repeating: 0, count: 12 + fuOverhead + chunkSize)
            writeRTPHeader(packet: &packet, marker: lastPacket && marker, payloadType: 96)
            
            if isH265 {
                packet[12] = fuIndicator
                packet[13] = fuPayloadHdrByte2
                packet[14] = firstPacket ? fuHeaderStart : (lastPacket ? fuHeaderEnd : fuHeaderMid)
                packet[15...] = data[currentOffset..<(currentOffset + chunkSize)]
            } else {
                packet[12] = fuIndicator
                packet[13] = firstPacket ? fuHeaderStart : (lastPacket ? fuHeaderEnd : fuHeaderMid)
                packet[14...] = data[currentOffset..<(currentOffset + chunkSize)]
            }
            
            sendPacket(data: packet)
            
            currentOffset += chunkSize
            firstPacket = false
        }
    }
    
    private func sendStapA() -> Bool {
        guard let sps = getSps?(), let pps = getPps?() else { return false }
        let spsData = extractNAL(sps)
        let ppsData = extractNAL(pps)
        
        let totalNalSize = 2 + spsData.count + 2 + ppsData.count
        var packet = Data(repeating: 0, count: 13 + totalNalSize)
        
        writeRTPHeader(packet: &packet, marker: false, payloadType: 96)
        packet[12] = 0x78 // STAP-A
        var pos = 13
        
        packet[pos] = UInt8((spsData.count >> 8) & 0xFF)
        packet[pos + 1] = UInt8(spsData.count & 0xFF)
        pos += 2
        packet[pos..<(pos + spsData.count)] = spsData
        pos += spsData.count
        
        packet[pos] = UInt8((ppsData.count >> 8) & 0xFF)
        packet[pos + 1] = UInt8(ppsData.count & 0xFF)
        pos += 2
        packet[pos..<(pos + ppsData.count)] = ppsData
        
        sendPacket(data: packet)
        return true
    }
    
    private func sendVpsSpsPps() -> Bool {
        guard let vps = getVps?(), let sps = getSps?(), let pps = getPps?() else { return false }
        let vpsData = extractNAL(vps)
        let spsData = extractNAL(sps)
        let ppsData = extractNAL(pps)
        
        let totalSize = 2 + vpsData.count + 2 + spsData.count + 2 + ppsData.count
        var packet = Data(repeating: 0, count: 14 + totalSize)
        
        writeRTPHeader(packet: &packet, marker: false, payloadType: 96)
        packet[12] = 0x60 // AP payload header byte 1 (type 48)
        packet[13] = 0x01 // AP payload header byte 2
        var pos = 14
        
        packet[pos] = UInt8((vpsData.count >> 8) & 0xFF)
        packet[pos + 1] = UInt8(vpsData.count & 0xFF)
        pos += 2
        packet[pos..<(pos + vpsData.count)] = vpsData
        pos += vpsData.count
        
        packet[pos] = UInt8((spsData.count >> 8) & 0xFF)
        packet[pos + 1] = UInt8(spsData.count & 0xFF)
        pos += 2
        packet[pos..<(pos + spsData.count)] = spsData
        pos += spsData.count
        
        packet[pos] = UInt8((ppsData.count >> 8) & 0xFF)
        packet[pos + 1] = UInt8(ppsData.count & 0xFF)
        pos += 2
        packet[pos..<(pos + ppsData.count)] = ppsData
        
        sendPacket(data: packet)
        return true
    }
    
    private func extractNAL(_ data: Data) -> Data {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        } else if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }
    
    private func writeRTPHeader(packet: inout Data, marker: Bool, payloadType: UInt8) {
        packet[0] = 0x80
        packet[1] = (marker ? 0x80 : 0x00) | (payloadType & 0x7F)
        
        packet[2...3] = Data(withUnsafeBytes(of: sequenceNumber.bigEndian) { Data($0) })
        sequenceNumber = sequenceNumber &+ 1
        
        packet[4...7] = Data(withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })
        
        packet[8...11] = Data(withUnsafeBytes(of: ssrc.bigEndian) { Data($0) })
    }
    
    private func sendPacket(data: Data) {
        if isTcp {
            // Write the TCP Interleaved Frame directly into the batch buffer when batching,
            // avoiding the intermediate `rtpHeader + data` allocation+copy per RTP fragment
            // (a large P-frame is ~32 fragments, so this saves ~32 Data objects per frame).
            if isBatching {
                tcpBatchData.append(0x24)                              // Magic '$'
                tcpBatchData.append(UInt8(tcpChannel))
                tcpBatchData.append(UInt8((data.count >> 8) & 0xFF))
                tcpBatchData.append(UInt8(data.count & 0xFF))
                tcpBatchData.append(data)
            } else {
                // Non-batch path (audio / codec config): build a single interleaved frame.
                var tcpFrame = Data(capacity: 4 + data.count)
                tcpFrame.append(0x24)
                tcpFrame.append(UInt8(tcpChannel))
                tcpFrame.append(UInt8((data.count >> 8) & 0xFF))
                tcpFrame.append(UInt8(data.count & 0xFF))
                tcpFrame.append(data)
                sendRawTcp(tcpFrame)
            }
        } else {
            // Write UDP
            rtpUdpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
        }
        rtcpSender?.reportPacket(length: data.count)
    }

    private static var tcpSendCount = 0
    private func sendRawTcp(_ data: Data) {
        // Bail out if we've been stopped — avoids writing to a torn-down connection.
        if isStoppedFlag() { return }

        RTPSender.tcpSendCount += 1
        let count = RTPSender.tcpSendCount
        if count <= 3 {
            print("[RTSPCamera] RTPSender TCP send #\(count): \(data.count) bytes, connection=\(tcpConnection != nil ? "valid" : "nil")")
        }
        // Limit the number of pending TCP writes on the shared serial queue.
        // When the slot is exhausted the senderʼs own serial queue blocks here,
        // which cascades backpressure up to the FrameReader → FrameProvider chain.
        // Signal happens inside contentProcessed (after NWConnection confirms
        // delivery), so the backpressure reflects the real network drain rate —
        // the mechanism that originally solved PotPlayer buffering in b57f8c0.
        RTPSender.tcpWriteSlot.wait()
        if isStoppedFlag() { RTPSender.tcpWriteSlot.signal(); return }

        RTPSender.sharedTcpWriteQueue.async { [weak self] in
            guard let self = self, !self.isStoppedFlag() else {
                RTPSender.tcpWriteSlot.signal()
                return
            }
            self.tcpConnection?.send(content: data, completion: .contentProcessed({ [weak self] error in
                if let error = error {
                    print("[RTSPCamera] \(self?.codec ?? "") TCP send error: \(error)")
                    // Connection failed mid-stream — stop this sender so we don't keep
                    // pushing frames into a dead socket.
                    self?.stop()
                } else if count <= 3 {
                    print("[RTSPCamera] \(self?.codec ?? "") TCP send #\(count) succeeded")
                }
                // Release the backpressure slot once the write has been delivered
                // to the kernel/network (contentProcessed), not just dispatched.
                RTPSender.tcpWriteSlot.signal()
            }))
        }
    }

    private func flushTcpBatch() {
        if isTcp && !tcpBatchData.isEmpty {
            if debugFrameCount <= 2 {
                print("[RTSPCamera] RTPSender \(codec) flushTcpBatch: \(tcpBatchData.count) bytes")
            }
            sendRawTcp(tcpBatchData)
            tcpBatchData.removeAll(keepingCapacity: true)
        }
    }
}
