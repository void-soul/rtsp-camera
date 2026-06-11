import Foundation
import Network

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
    
    init(clientHost: String, clientPort: UInt16, ssrc: UInt32, clockRate: UInt32) {
        self.ssrc = ssrc
        self.clockRate = clockRate
        
        let host = NWEndpoint.Host(clientHost)
        let port = NWEndpoint.Port(integerLiteral: clientPort)
        self.connection = NWConnection(host: host, port: port, using: .udp)
    }
    
    func start() {
        guard let connection = connection else { return }
        isRunning = true
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
    }
}


// MARK: - RTPSender (Handles both Video H.264/H.265 and Audio AAC RTP transmission)
class RTPSender {
    private let clientHost: String
    private let clientPort: UInt16
    private let isTcp: Bool
    private let codec: String
    private let tcpChannel: Int
    
    private var tcpConnection: NWConnection?
    private var rtpUdpConnection: NWConnection?
    private var rtcpUdpConnection: NWConnection?
    
    private let queue = DispatchQueue(label: "com.gld.rtsp_camera.rtpSenderQueue", qos: .userInteractive)
    
    private var sequenceNumber: UInt16 = UInt16.random(in: 0...65535)
    private var ssrc: UInt32 = UInt32.random(in: 0...UInt32.max)
    private var timestamp: UInt32 = 0
    private var streamStartPtsUs: Int64 = -1
    
    private var rtcpSender: RTCPSender?
    private var sentCodecConfig = false
    private let maxPacketSize = 1400

    // Frame pacing: track wall clock time when first frame is sent
    private var wallStartUs: Int64 = -1
    
    // Config params
    private let isH265: Bool
    private let clockRate: UInt32
    
    // Video provider refs
    private var getSps: (() -> Data?)?
    private var getPps: (() -> Data?)?
    private var getVps: (() -> Data?)? // For H.265
    
    init(clientHost: String,
         clientPort: UInt16,
         codec: String,
         isTcp: Bool,
         tcpConnection: NWConnection?,
         tcpChannel: Int,
         clockRate: UInt32 = 90000,
         getSps: (() -> Data?)? = nil,
         getPps: (() -> Data?)? = nil,
         getVps: (() -> Data?)? = nil) {
        
        self.clientHost = clientHost
        self.clientPort = clientPort
        self.codec = codec.lowercased()
        self.isH265 = (self.codec == "h265")
        self.isTcp = isTcp
        self.tcpConnection = tcpConnection
        self.tcpChannel = tcpChannel
        self.clockRate = clockRate
        
        self.getSps = getSps
        self.getPps = getPps
        self.getVps = getVps
    }
    
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.isTcp {
                // Initialize UDP sockets
                let host = NWEndpoint.Host(self.clientHost)
                let rtpPort = NWEndpoint.Port(integerLiteral: self.clientPort)
                let rtcpPort = NWEndpoint.Port(integerLiteral: self.clientPort + 1)
                
                self.rtpUdpConnection = NWConnection(host: host, port: rtpPort, using: .udp)
                self.rtpUdpConnection?.start(queue: self.queue)
                
                self.rtcpUdpConnection = NWConnection(host: host, port: rtcpPort, using: .udp)
                
                self.rtcpSender = RTCPSender(clientHost: self.clientHost, clientPort: self.clientPort + 1, ssrc: self.ssrc, clockRate: self.clockRate)
                self.rtcpSender?.start()
            }
        }
    }
    
    func stop() {
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
    
    func resetSPSPPS() {
        queue.async {
            self.sentCodecConfig = false
        }
    }
    
    // MARK: - Sending Frames
    
    func sendVideoFrame(data: Data, timestampUs: Int64, isKeyFrame: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Maintain timestamp
            if self.streamStartPtsUs == -1 {
                self.streamStartPtsUs = timestampUs
                self.wallStartUs = Int64(CACurrentMediaTime() * 1_000_000)
            }
            let relativePtsUs = timestampUs - self.streamStartPtsUs
            self.timestamp = UInt32((relativePtsUs * Int64(self.clockRate) / 1000000) & 0xFFFFFFFF)

            // Frame pacing: calculate when this frame should be sent based on PTS,
            // so we send frames at real-time rate instead of in bursts.
            let sendBlock = { [weak self] in
                guard let self = self else { return }

                if self.streamStartPtsUs == timestampUs {
                    // First frame — send SPS/PPS immediately
                    if isKeyFrame && !self.sentCodecConfig {
                        self.sentCodecConfig = self.isH265 ? self.sendVpsSpsPps() : self.sendStapA()
                    }
                }

                // Search NALUs inside Annex-B
                var i = 0
                let length = data.count
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
                            } else {
                                self.sendFUAPackets(data: data, offset: start, size: nalSize, marker: isLastNALU)
                            }
                        }
                        i = end
                    } else {
                        i += 1
                    }
                }

                self.rtcpSender?.updateRtpTimestamp(self.timestamp)
            }

            // First frame: send immediately. Others: pace to real-time.
            if relativePtsUs == 0 {
                sendBlock()
            } else {
                let nowUs = Int64(CACurrentMediaTime() * 1_000_000)
                let targetSendUs = self.wallStartUs + relativePtsUs
                let delayUs = targetSendUs - nowUs

                if delayUs > 1000 { // > 1ms: schedule for later
                    self.queue.asyncAfter(deadline: .now() + .microseconds(Int(delayUs)), execute: sendBlock)
                } else {
                    sendBlock() // Already behind schedule, send now
                }
            }
        }
    }
    
    func sendAudioFrame(data: Data, timestampUs: Int64) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Maintain timestamp
            if self.streamStartPtsUs == -1 {
                self.streamStartPtsUs = timestampUs
            }
            let relativePtsUs = timestampUs - self.streamStartPtsUs
            self.timestamp = UInt32((relativePtsUs * Int64(self.clockRate) / 1000000) & 0xFFFFFFFF)
            
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
            // Write TCP Interleaved Frame
            var rtpHeader = Data(repeating: 0, count: 4)
            rtpHeader[0] = 0x24 // Magic '$'
            rtpHeader[1] = UInt8(tcpChannel)
            rtpHeader[2] = UInt8((data.count >> 8) & 0xFF)
            rtpHeader[3] = UInt8(data.count & 0xFF)
            
            let tcpFrame = rtpHeader + data
            tcpConnection?.send(content: tcpFrame, completion: .contentProcessed({ _ in }))
        } else {
            // Write UDP
            rtpUdpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
        }
        rtcpSender?.reportPacket(length: data.count)
    }
}
