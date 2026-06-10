package com.gld.rtsp_camera

import android.os.Process
import android.util.Log
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean

class AudioRTPSender(
    private val clientAddress: InetAddress,
    private val clientPort: Int,
    private val frameProvider: AudioFrameProvider,
    private val preCreatedSocket: DatagramSocket? = null,
    private val tcpOutputStream: OutputStream? = null,
    private val tcpChannel: Int = 2,
    private val rtcpSocket: DatagramSocket? = null,
    private val streamStartPtsUs: java.util.concurrent.atomic.AtomicLong? = null
) {
    private val tag = "AudioRTPSender"
    private val running = AtomicBoolean(false)
    private val isTcp = tcpOutputStream != null
    private var socket: DatagramSocket? = null
    private var ownsSocket = true

    private var sequenceNumber = java.util.Random().nextInt(65536)
    private var timestamp = (System.currentTimeMillis() and 0xFFFFFFFFL)
    private var ssrc = java.util.Random().nextInt().toLong() and 0xFFFFFFFFL

    // RTCP sender for stream quality monitoring
    private var rtcpSender: RTCPSender? = null

    private val rtpBuffer = ByteArray(2000)
    private var rtpPacket: DatagramPacket? = null
    // TCP interleaved: larger staging buffer for batched writes
    private val tcpBatchBuffer = ByteArray(16384)
    private var tcpBatchLen = 0

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
            try {
                socket?.sendBufferSize = 256 * 1024
                socket?.trafficClass = 0x10
            } catch (e: Exception) { Log.w(tag, "Socket tuning failed: ${e.message}") }
            Log.d(tag, "Audio RTP sender started to ${clientAddress.hostAddress}:$clientPort (local port: ${socket?.localPort})")
            rtcpSender = RTCPSender(clientAddress, clientPort + 1, ssrc, 44100, rtcpSocket)
            rtcpSender?.start()
        } else {
            Log.d(tag, "Audio RTP sender started TCP interleaved channel $tcpChannel to ${clientAddress.hostAddress}")
            Thread.sleep(100)
        }

        while (running.get()) {
            val frame = frameProvider.getFrameBlocking(1000)
            if (frame != null) {
                sendAACFrame(frame)
                flushTcpBatch()
                frameProvider.recycleFrame(frame)
            }
        }
    }

    fun stop() {
        running.set(false)
        rtcpSender?.stop()
        rtcpSender = null
        if (!isTcp && ownsSocket) {
            socket?.close()
        }
        socket = null
        Log.d(tag, "Audio RTP sender stopped")
    }

    private fun sendAACFrame(frame: NativeFrame) {
        // RFC 3640 / RFC 6416 generic AAC-hbr
        val rtpHeaderSize = 12
        val auHeaderSize = 4

        if (frame.presentationTimeUs > 0) {
            val startPts = streamStartPtsUs?.get() ?: -1L
            val relativePtsUs = if (startPts > 0) {
                frame.presentationTimeUs - startPts
            } else {
                streamStartPtsUs?.compareAndSet(-1L, frame.presentationTimeUs)
                frame.presentationTimeUs - (streamStartPtsUs?.get() ?: frame.presentationTimeUs)
            }
            timestamp = (relativePtsUs * 44100 / 1000000) and 0xFFFFFFFFL
        }

        writeRTPHeader(rtpBuffer, true)

        // AU-headers-length (in bits)
        rtpBuffer[rtpHeaderSize] = 0
        rtpBuffer[rtpHeaderSize + 1] = 16

        // AU-header: size(13bits) + index(3bits)
        val auHeader = (frame.length shl 3) and 0xFFF8
        rtpBuffer[rtpHeaderSize + 2] = (auHeader shr 8).toByte()
        rtpBuffer[rtpHeaderSize + 3] = (auHeader and 0xFF).toByte()

        System.arraycopy(frame.buffer, 0, rtpBuffer, rtpHeaderSize + auHeaderSize, frame.length)

        val totalLen = rtpHeaderSize + auHeaderSize + frame.length
        try {
            if (isTcp) {
                sendInterleaved(rtpBuffer, totalLen)
            } else {
                if (rtpPacket == null) {
                    rtpPacket = DatagramPacket(rtpBuffer, totalLen, clientAddress, clientPort)
                } else {
                    rtpPacket?.setData(rtpBuffer, 0, totalLen)
                }
                socket?.send(rtpPacket)
            }
            rtcpSender?.reportPacket(totalLen)
        } catch (e: Exception) {
            Log.w(tag, "Send error: ${e.message}")
        }

        if (frame.presentationTimeUs <= 0) {
            timestamp = (timestamp + 1024) and 0xFFFFFFFFL
        }
        rtcpSender?.updateRTPTimestamp(timestamp)
    }

    private fun writeRTPHeader(packet: ByteArray, marker: Boolean) {
        packet[0] = 0x80.toByte()
        packet[1] = (if (marker) 0x80 else 0x00).toByte()
        packet[1] = (packet[1].toInt() or 97).toByte()

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

    private fun sendInterleaved(data: ByteArray, length: Int) {
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
            tcpBatchLen = 0
        }
    }
}
