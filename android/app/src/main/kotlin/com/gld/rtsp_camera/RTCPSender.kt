package com.gld.rtsp_camera

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sends RTCP Sender Reports (SR) periodically per RFC 3550.
 * Also handles receiving RTCP SDES and BYE from the client.
 */
class RTCPSender(
    private val clientAddress: InetAddress,
    private val clientRTCPPort: Int,
    private val ssrc: Long,
    private val clockRate: Int = 90000,
    private val preCreatedSocket: DatagramSocket? = null
) {
    // Adaptive bitrate: callback with fraction lost (0-255, where 255 = 100%)
    var onPacketLoss: ((fractionLost: Int) -> Unit)? = null
    private val tag = "RTCPSender"
    private val running = AtomicBoolean(false)
    private var socket: DatagramSocket? = null

    // Sender statistics updated from the RTP sender thread
    private val packetCount = AtomicInteger(0)
    private val octetCount = AtomicInteger(0)
    @Volatile private var lastRTPTimestamp: Long = 0

    // NTP epoch offset: seconds from 1900-01-01 to 1970-01-01
    private val NTP_EPOCH_OFFSET = 2208988800L
    private val SR_INTERVAL_MS = 5000L

    // Reuse buffers to reduce GC pressure
    private val srBuffer = ByteArray(28) // SR: 7 x 32-bit words
    private var srPacket: DatagramPacket? = null
    private val recvBuffer = ByteArray(1500)
    private var recvPacket: DatagramPacket? = null

    fun start() {
        running.set(true)
        socket = preCreatedSocket ?: DatagramSocket()
        socket?.soTimeout = 1000 // 1s timeout for receive loop

        Thread({
            Log.d(tag, "RTCP sender started to ${clientAddress.hostAddress}:$clientRTCPPort (local port: ${socket?.localPort})")
            while (running.get()) {
                try {
                    sendSenderReport()
                    receiveRTCP()
                } catch (e: Exception) {
                    if (running.get()) Log.w(tag, "RTCP error: ${e.message}")
                }
                // Wait for next interval, checking running flag every 100ms
                val waitEnd = System.currentTimeMillis() + SR_INTERVAL_MS
                while (running.get() && System.currentTimeMillis() < waitEnd) {
                    try { Thread.sleep(100) } catch (e: InterruptedException) { break }
                }
            }
            Log.d(tag, "RTCP sender stopped")
        }, "RTCPSender").start()
    }

    fun stop() {
        running.set(false)
        try { socket?.close() } catch (e: Exception) {}
        socket = null
    }

    /** Call from the RTP sender thread after each RTP packet is sent. */
    fun reportPacket(length: Int) {
        packetCount.incrementAndGet()
        octetCount.addAndGet(length)
    }

    /** Call from the RTP sender thread to keep the RTP timestamp current. */
    fun updateRTPTimestamp(ts: Long) {
        lastRTPTimestamp = ts
    }

    private fun sendSenderReport() {
        val now = System.currentTimeMillis()
        val ntpSeconds = now / 1000 + NTP_EPOCH_OFFSET
        val ntpFraction = ((now % 1000) * 0x100000000L) / 1000
        val ntpTime = (ntpSeconds shl 32) or (ntpFraction and 0xFFFFFFFFL)
        val rtpTs = lastRTPTimestamp

        // Header: V=2, P=0, RC=0 -> 0x80; PT=200 (SR) -> 0xC8; length=6
        srBuffer[0] = 0x80.toByte()
        srBuffer[1] = 0xC8.toByte()
        srBuffer[2] = 0x00
        srBuffer[3] = 0x06

        // SSRC (bytes 4-7)
        srBuffer[4] = ((ssrc shr 24) and 0xFF).toByte()
        srBuffer[5] = ((ssrc shr 16) and 0xFF).toByte()
        srBuffer[6] = ((ssrc shr 8) and 0xFF).toByte()
        srBuffer[7] = (ssrc and 0xFF).toByte()

        // NTP timestamp (bytes 8-15, 64-bit)
        for (i in 0..7) {
            srBuffer[8 + i] = ((ntpTime shr (56 - i * 8)) and 0xFF).toByte()
        }

        // RTP timestamp (bytes 16-19)
        srBuffer[16] = ((rtpTs shr 24) and 0xFF).toByte()
        srBuffer[17] = ((rtpTs shr 16) and 0xFF).toByte()
        srBuffer[18] = ((rtpTs shr 8) and 0xFF).toByte()
        srBuffer[19] = (rtpTs and 0xFF).toByte()

        // Sender's packet count (bytes 20-23)
        val pc = packetCount.get()
        srBuffer[20] = ((pc shr 24) and 0xFF).toByte()
        srBuffer[21] = ((pc shr 16) and 0xFF).toByte()
        srBuffer[22] = ((pc shr 8) and 0xFF).toByte()
        srBuffer[23] = (pc and 0xFF).toByte()

        // Sender's octet count (bytes 24-27)
        val oc = octetCount.get()
        srBuffer[24] = ((oc shr 24) and 0xFF).toByte()
        srBuffer[25] = ((oc shr 16) and 0xFF).toByte()
        srBuffer[26] = ((oc shr 8) and 0xFF).toByte()
        srBuffer[27] = (oc and 0xFF).toByte()

        try {
            if (srPacket == null) {
                srPacket = DatagramPacket(srBuffer, srBuffer.size, clientAddress, clientRTCPPort)
            } else {
                srPacket?.setData(srBuffer, 0, srBuffer.size)
            }
            socket?.send(srPacket)
            Log.d(tag, "Sent SR: packets=$pc, octets=$oc")
        } catch (e: Exception) {
            Log.w(tag, "Send SR error: ${e.message}")
        }
    }

    private fun receiveRTCP() {
        try {
            if (recvPacket == null) {
                recvPacket = DatagramPacket(recvBuffer, recvBuffer.size)
            } else {
                recvPacket?.setData(recvBuffer, 0, recvBuffer.size)
            }
            socket?.receive(recvPacket)

            val len = recvPacket?.length ?: 0
            if (len >= 8) {
                val pt = recvBuffer[1].toInt() and 0xFF
                // Parse RR (type 201) for ABR: extract fraction lost from first report block
                if (pt == 201 && len >= 32) {
                    val fractionLost = recvBuffer[12].toInt() and 0xFF
                    if (fractionLost > 0) {
                        Log.d(tag, "RTCP RR: fraction lost=$fractionLost/256")
                        onPacketLoss?.invoke(fractionLost)
                    }
                }
            }
        } catch (e: java.net.SocketTimeoutException) {
            // Expected when no data available within timeout
        } catch (e: Exception) {
            if (running.get()) Log.w(tag, "Receive RTCP error: ${e.message}")
        }
    }
}
