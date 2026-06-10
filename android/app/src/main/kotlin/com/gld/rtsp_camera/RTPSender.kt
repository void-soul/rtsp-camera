package com.gld.rtsp_camera

import android.os.Process
import android.util.Log
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

class RTPSender(
    private val clientAddress: InetAddress,
    private val clientPort: Int,
    private val frameProvider: H264FrameProvider,
    private val preCreatedSocket: DatagramSocket? = null,
    private val tcpOutputStream: OutputStream? = null,
    private val tcpChannel: Int = 0,
    private val rtcpSocket: DatagramSocket? = null,
    private val videoCodec: String = "h264",
    private val streamStartPtsUs: java.util.concurrent.atomic.AtomicLong? = null
) {
    private val tag = "RTPSender"
    private val running = AtomicBoolean(false)
    private val isTcp = tcpOutputStream != null
    private val isH265 = videoCodec == "h265"
    private var socket: DatagramSocket? = null
    private var ownsSocket = true

    @Volatile
    var totalSentFrames = 0L
        private set

    @Volatile
    var currentFps = 0.0
        private set

    private var fpsLastTime = 0L
    private var fpsFrameCount = 0

    // RTP state
    private var sequenceNumber = java.util.Random().nextInt(65536)
    private var timestamp = 0L
    private var ssrc = java.util.Random().nextInt().toLong() and 0xFFFFFFFFL

    private val clockRate = 90000
    private var frameIntervalTicks = 3000
    private val maxPacketSize = 1400

    // RTCP sender for stream quality monitoring
    private var rtcpSender: RTCPSender? = null

    // Track whether we've sent codec config (SPS/PPS or VPS/SPS/PPS) for this session
    private var sentCodecConfig = false

    // H.265-specific helpers
    private fun getNalType(data: ByteArray, offset: Int): Int {
        val b = data[offset].toInt() and 0xFF
        return if (isH265) (b shr 1) and 0x3F else b and 0x1F
    }
    private fun isIdr(nalType: Int): Boolean =
        if (isH265) nalType in 19..21 else nalType == 5

    // Reuse buffer and packet for outgoing UDP to reduce GC
    private val rtpBuffer = ByteArray(1500)
    private var rtpPacket: DatagramPacket? = null
    // TCP interleaved: larger staging buffer for batched writes
    private val tcpBatchBuffer = ByteArray(65536)
    private var tcpBatchLen = 0
    private var tcpTotalBytes = 0L
    private var tcpLastLogTime = 0L

    fun setFramerate(fps: Int) {
        frameIntervalTicks = if (fps > 0) clockRate / fps else 3000
    }

    fun resetSPSPPS() {
        sentCodecConfig = false
    }

    fun setPacketLossCallback(cb: (Int) -> Unit) {
        // Will be set on rtcpSender after start
        rtcpSender?.onPacketLoss = cb
    }

    fun start() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        running.set(true)
        if (!isTcp) {
            if (preCreatedSocket != null) {
                socket = preCreatedSocket
                ownsSocket = false
            } else {
                socket = DatagramSocket()
                ownsSocket = true
            }
            // Enlarge send buffer and set low-delay TOS for UDP
            try {
                socket?.sendBufferSize = 512 * 1024
                socket?.trafficClass = 0x10 // IPTOS_LOWDELAY
            } catch (e: Exception) { Log.w(tag, "Socket tuning failed: ${e.message}") }
            Log.d(tag, "RTP sender started to ${clientAddress.hostAddress}:$clientPort (local port: ${socket?.localPort})")
            rtcpSender = RTCPSender(clientAddress, clientPort + 1, ssrc, clockRate, rtcpSocket)
            rtcpSender?.start()
        } else {
            Log.d(tag, "RTP sender started TCP interleaved channel $tcpChannel to ${clientAddress.hostAddress}")
            // Ensure RTSP PLAY response is sent before we start writing RTP data
            Thread.sleep(100)
        }

        var sentFrameCount = 0
        try {
            while (running.get()) {
                val frame = frameProvider.getFrameBlocking(1000)
                if (frame != null) {
                    sendH264Frame(frame)
                    sentFrameCount++
                    if (sentFrameCount <= 5 || sentFrameCount % 300 == 0) {
                        Log.d(tag, "Sent frame #$sentFrameCount: size=${frame.length}, pts=${frame.presentationTimeUs}")
                    }
                    frameProvider.recycleFrame(frame)
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "RTP sender thread crashed after $sentFrameCount frames", e)
        }
        Log.d(tag, "RTP sender loop exiting (sent $sentFrameCount frames)")
    }

    fun stop() {
        running.set(false)
        rtcpSender?.stop()
        rtcpSender = null
        if (!isTcp && ownsSocket) {
            socket?.close()
        }
        socket = null
        Log.d(tag, "RTP sender stopped")
    }

    private var diagFrameCount = 0

    private fun sendH264Frame(frame: NativeFrame) {
        val nowMs = android.os.SystemClock.elapsedRealtime()
        if (fpsLastTime == 0L) {
            fpsLastTime = nowMs
        }
        fpsFrameCount++
        if (nowMs - fpsLastTime >= 1000) {
            currentFps = fpsFrameCount * 1000.0 / (nowMs - fpsLastTime)
            fpsFrameCount = 0
            fpsLastTime = nowMs
        }
        totalSentFrames++

        val data = frame.buffer
        val length = frame.length

        // Use capture-based timestamp for sync with player clock
        if (frame.presentationTimeUs > 0) {
            val startPts = streamStartPtsUs?.get() ?: -1L
            val relativePtsUs = if (startPts > 0) {
                frame.presentationTimeUs - startPts
            } else {
                streamStartPtsUs?.compareAndSet(-1L, frame.presentationTimeUs)
                frame.presentationTimeUs - (streamStartPtsUs?.get() ?: frame.presentationTimeUs)
            }
            timestamp = (relativePtsUs * 90000 / 1000000) and 0xFFFFFFFFL
        }

        var packetCount = 0
        var nalCount = 0
        var i = 0
        while (i < length - 3) {
            var startCodeSize = 0
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (data[i + 2] == 1.toByte()) {
                    startCodeSize = 3
                } else if (i + 3 < length && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    startCodeSize = 4
                }
            }

            if (startCodeSize > 0) {
                val start = i + startCodeSize
                val end = findNextStartCode(data, start, length)
                val nalSize = end - start

                if (nalSize > 0) {
                    val nalType = getNalType(data, start)
                    // NAL type diagnostic (first 10 frames)
                    if (nalCount == 0 && diagFrameCount < 10) {
                        Log.d(tag, "Frame #${diagFrameCount+1} NAL[0]: type=$nalType, isIDR=${isIdr(nalType)}")
                    }
                    if (isIdr(nalType) && !sentCodecConfig) {
                        // Send VPS/SPS/PPS only once per session to initialize the decoder
                        sentCodecConfig = if (isH265) sendVpsSpsPps() else sendStapA()
                    }
                    val isLastNALU = end == length
                    if (nalSize <= maxPacketSize) {
                        sendSingleNALUPacket(data, start, nalSize, isLastNALU)
                        packetCount++
                    } else {
                        packetCount += sendFUAPackets(data, start, nalSize, isLastNALU)
                    }
                    nalCount++
                }
                i = end
            } else {
                i++
            }
        }

        // Flush any batched TCP data at frame boundary
        flushTcpBatch()

        // Pacing: for large I-frames, spread packets to avoid burst loss
        if (!isTcp && packetCount > 10) {
            Thread.sleep(0, 500_000)
        }

        if (frame.presentationTimeUs <= 0) {
            timestamp = (timestamp + frameIntervalTicks) and 0xFFFFFFFFL
        }
        rtcpSender?.updateRTPTimestamp(timestamp)

        diagFrameCount++
        if (diagFrameCount <= 5 || diagFrameCount % 300 == 0) {
            Log.d(tag, "sendFrame #$diagFrameCount: nals=$nalCount, pkts=$packetCount, len=$length, ts=$timestamp")
        }
    }

    /** Fast NAL start code scanner: finds 00 00 01 or 00 00 00 01. */
    private fun findNextStartCode(data: ByteArray, start: Int, length: Int): Int {
        var i = start
        val limit = length - 3
        while (i < limit) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (data[i + 2] == 1.toByte()) return i
                if (i + 3 < length && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) return i
                i += 2 // skip past the second 00
            } else {
                i++
            }
        }
        return length
    }

    private fun sendSingleNALUPacket(source: ByteArray, offset: Int, size: Int, marker: Boolean) {
        writeRTPHeader(rtpBuffer, marker)
        System.arraycopy(source, offset, rtpBuffer, 12, size)
        sendPacket(rtpBuffer, 12 + size)
    }

    private fun sendFUAPackets(source: ByteArray, offset: Int, size: Int, marker: Boolean): Int {
        val nalType = getNalType(source, offset)
        val nalHeaderSize = if (isH265) 2 else 1

        // H.264 FU-A: indicator(1) + header(1) = 2 bytes overhead
        // H.265 FU:   PayloadHdr(2) + header(1) = 3 bytes overhead
        val fuOverhead = if (isH265) 3 else 2

        // H.264: FU-A indicator = (nalRefIdc<<5)|28, FU header = S|E|R|type
        // H.265: PayloadHdr byte1 = F+Type49+LayerId_MSB, byte2 = LayerId_LSB+TID; FU header = S|E|FuType
        val fuIndicator: Int
        val fuPayloadHdrByte2: Int  // H.265 only: second byte of PayloadHdr (LayerId_LSB + TID)
        val fuHeaderStart: Int
        val fuHeaderMid: Int
        val fuHeaderEnd: Int
        if (isH265) {
            val origByte1 = source[offset].toInt() and 0xFF
            val origByte2 = source[offset + 1].toInt() and 0xFF
            fuIndicator = (origByte1 and 0x81) or 0x62 // preserve F+LayerId_MSB, set type=49
            fuPayloadHdrByte2 = origByte2               // preserve LayerId_LSB + TID
            fuHeaderStart = 0x80 or nalType
            fuHeaderMid = nalType
            fuHeaderEnd = 0x40 or nalType
        } else {
            val nalRefIdc = (source[offset].toInt() and 0x60) shr 5
            fuIndicator = (nalRefIdc shl 5) or 0x1C
            fuPayloadHdrByte2 = 0 // unused for H.264
            fuHeaderStart = 0x80 or nalType
            fuHeaderMid = nalType
            fuHeaderEnd = 0x40 or nalType
        }

        var currentOffset = offset + nalHeaderSize
        val endOffset = offset + size

        var firstPacket = true
        var count = 0
        while (currentOffset < endOffset) {
            val remaining = endOffset - currentOffset
            val chunkSize = minOf(maxPacketSize - fuOverhead, remaining)
            val lastPacket = (currentOffset + chunkSize) >= endOffset

            writeRTPHeader(rtpBuffer, lastPacket && marker)

            if (isH265) {
                // H.265 FU: PayloadHdr(2) + FU header(1) + payload
                rtpBuffer[12] = fuIndicator.toByte()
                rtpBuffer[13] = fuPayloadHdrByte2.toByte()
                rtpBuffer[14] = when {
                    firstPacket -> fuHeaderStart.toByte()
                    lastPacket -> fuHeaderEnd.toByte()
                    else -> fuHeaderMid.toByte()
                }
                System.arraycopy(source, currentOffset, rtpBuffer, 15, chunkSize)
            } else {
                // H.264 FU-A: indicator(1) + FU header(1) + payload
                rtpBuffer[12] = fuIndicator.toByte()
                rtpBuffer[13] = when {
                    firstPacket -> fuHeaderStart.toByte()
                    lastPacket -> fuHeaderEnd.toByte()
                    else -> fuHeaderMid.toByte()
                }
                System.arraycopy(source, currentOffset, rtpBuffer, 14, chunkSize)
            }

            sendPacket(rtpBuffer, 12 + fuOverhead + chunkSize)

            currentOffset += chunkSize
            firstPacket = false
            count++
        }
        return count
    }

    private fun sendStapA(): Boolean {
        val sps = frameProvider.getSPS() ?: return false
        val pps = frameProvider.getPPS() ?: return false

        val spsData = extractNAL(sps)
        val ppsData = extractNAL(pps)

        val totalNalSize = 2 + spsData.size + 2 + ppsData.size
        if (12 + 1 + totalNalSize > rtpBuffer.size) {
            Log.w(tag, "SPS/PPS too large for STAP-A: $totalNalSize")
            return false
        }

        writeRTPHeader(rtpBuffer, false)
        rtpBuffer[12] = 0x78.toByte() // STAP-A: NRI=3(0x60) | type=24(0x18)
        var pos = 13
        rtpBuffer[pos++] = (spsData.size shr 8).toByte()
        rtpBuffer[pos++] = (spsData.size and 0xFF).toByte()
        System.arraycopy(spsData, 0, rtpBuffer, pos, spsData.size)
        pos += spsData.size
        rtpBuffer[pos++] = (ppsData.size shr 8).toByte()
        rtpBuffer[pos++] = (ppsData.size and 0xFF).toByte()
        System.arraycopy(ppsData, 0, rtpBuffer, pos, ppsData.size)
        pos += ppsData.size

        sendPacket(rtpBuffer, pos)
        Log.d(tag, "Sent STAP-A: SPS=${spsData.size}, PPS=${ppsData.size}")
        return true
    }

    /** H.265 Aggregation Packet: VPS + SPS + PPS with 2-byte NAL size prefixes. */
    private fun sendVpsSpsPps(): Boolean {
        val vps = frameProvider.getVPS() ?: return false
        val sps = frameProvider.getSPS() ?: return false
        val pps = frameProvider.getPPS() ?: return false

        val vpsData = extractNAL(vps)
        val spsData = extractNAL(sps)
        val ppsData = extractNAL(pps)

        val totalSize = 2 + vpsData.size + 2 + spsData.size + 2 + ppsData.size
        if (12 + 2 + totalSize > rtpBuffer.size) {
            Log.w(tag, "VPS/SPS/PPS too large: $totalSize")
            return false
        }

        writeRTPHeader(rtpBuffer, false)
        // AP payload header (2 bytes): type 48 << 1 = 0x60, layer_id=0, tid+1=1
        rtpBuffer[12] = 0x60.toByte()
        rtpBuffer[13] = 0x01.toByte()
        var pos = 14
        // VPS
        rtpBuffer[pos++] = (vpsData.size shr 8).toByte()
        rtpBuffer[pos++] = (vpsData.size and 0xFF).toByte()
        System.arraycopy(vpsData, 0, rtpBuffer, pos, vpsData.size)
        pos += vpsData.size
        // SPS
        rtpBuffer[pos++] = (spsData.size shr 8).toByte()
        rtpBuffer[pos++] = (spsData.size and 0xFF).toByte()
        System.arraycopy(spsData, 0, rtpBuffer, pos, spsData.size)
        pos += spsData.size
        // PPS
        rtpBuffer[pos++] = (ppsData.size shr 8).toByte()
        rtpBuffer[pos++] = (ppsData.size and 0xFF).toByte()
        System.arraycopy(ppsData, 0, rtpBuffer, pos, ppsData.size)
        pos += ppsData.size

        sendPacket(rtpBuffer, pos)
        Log.d(tag, "Sent H.265 AP: VPS=${vpsData.size}, SPS=${spsData.size}, PPS=${ppsData.size}")
        return true
    }

    private fun extractNAL(data: ByteArray): ByteArray {
        if (data.size >= 4 && data[0] == 0.toByte() && data[1] == 0.toByte() &&
            data[2] == 0.toByte() && data[3] == 1.toByte()) {
            return data.copyOfRange(4, data.size)
        } else if (data.size >= 3 && data[0] == 0.toByte() && data[1] == 0.toByte() &&
            data[2] == 1.toByte()) {
            return data.copyOfRange(3, data.size)
        }
        return data
    }

    private fun writeRTPHeader(packet: ByteArray, marker: Boolean) {
        packet[0] = 0x80.toByte()
        val payloadType = 96
        packet[1] = ((if (marker) 0x80 else 0x00) or (payloadType and 0x7F)).toByte()

        packet[2] = ((sequenceNumber shr 8) and 0xFF).toByte()
        packet[3] = (sequenceNumber and 0xFF).toByte()
        sequenceNumber = (sequenceNumber + 1) and 0xFFFF

        packet[4] = ((timestamp shr 24) and 0xFF).toByte()
        packet[5] = ((timestamp shr 16) and 0xFF).toByte()
        packet[6] = ((timestamp shr 8) and 0xFF).toByte()
        packet[7] = (timestamp and 0xFF).toByte()

        packet[8] = ((ssrc shr 24) and 0xFF).toByte()
        packet[9] = ((ssrc shr 16) and 0xFF).toByte()
        packet[10] = ((ssrc shr 8) and 0xFF).toByte()
        packet[11] = (ssrc and 0xFF).toByte()
    }

    private fun sendPacket(data: ByteArray, length: Int) {
        try {
            if (isTcp) {
                sendInterleaved(data, length)
            } else {
                if (rtpPacket == null) {
                    rtpPacket = DatagramPacket(data, length, clientAddress, clientPort)
                } else {
                    rtpPacket?.setData(data, 0, length)
                }
                socket?.send(rtpPacket)
            }
            rtcpSender?.reportPacket(length)
        } catch (e: Exception) {
            Log.w(tag, "Send error: ${e.message}")
        }
    }

    private fun sendInterleaved(data: ByteArray, length: Int) {
        // Batch TCP interleaved writes to reduce system calls
        val headerLen = 4
        val totalLen = headerLen + length
        if (tcpBatchLen + totalLen > tcpBatchBuffer.size) {
            flushTcpBatch()
        }
        tcpBatchBuffer[tcpBatchLen] = 0x24.toByte()
        tcpBatchBuffer[tcpBatchLen + 1] = tcpChannel.toByte()
        tcpBatchBuffer[tcpBatchLen + 2] = (length shr 8).toByte()
        tcpBatchBuffer[tcpBatchLen + 3] = (length and 0xFF).toByte()
        System.arraycopy(data, 0, tcpBatchBuffer, tcpBatchLen + headerLen, length)
        tcpBatchLen += totalLen
    }

    private fun flushTcpBatch() {
        if (isTcp && tcpBatchLen > 0) {
            val output = tcpOutputStream ?: return
            synchronized(output) {
                output.write(tcpBatchBuffer, 0, tcpBatchLen)
                output.flush()
            }
            tcpTotalBytes += tcpBatchLen
            val now = System.currentTimeMillis()
            if (now - tcpLastLogTime > 5000 && tcpTotalBytes > 0) {
                Log.d(tag, "TCP sent: ${tcpTotalBytes / 1024}KB total, last batch=${tcpBatchLen}B")
                tcpLastLogTime = now
            }
            tcpBatchLen = 0
        }
    }
}
