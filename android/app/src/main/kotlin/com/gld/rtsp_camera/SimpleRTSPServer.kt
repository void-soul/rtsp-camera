package com.gld.rtsp_camera

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.DatagramSocket
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SimpleRTSPServer(
    private val port: Int,
    private val path: String,
    private val videoProvider: H264FrameProvider,
    private val audioProvider: AudioFrameProvider,
    private val audioEnabled: Boolean,
    private val videoCodec: String = "h264"
) {
    private val tag = "SimpleRTSPServer"
    private var serverSocket: ServerSocket? = null
    private val running = AtomicBoolean(false)
    private val clients = ConcurrentHashMap<String, RTSPSession>()

    // 动态端口分配计数器，从 50000 开始
    private val nextRtpPort = AtomicInteger(50000)

    // Session 回调: 包含预创建的 RTP/RTCP Socket 及协商后的 TCP 通道号
    private var onSessionPlay: ((address: java.net.InetAddress, videoPort: Int, audioPort: Int, videoSocket: DatagramSocket?, audioSocket: DatagramSocket?, videoRtcpSocket: DatagramSocket?, audioRtcpSocket: DatagramSocket?, tcpOutputStream: OutputStream?, videoTcpChannel: Int, audioTcpChannel: Int) -> Unit)? = null
    private var onStartStreaming: (() -> Unit)? = null
    private var onStopStreaming: (() -> Unit)? = null
    private var onClientChange: ((ip: String?) -> Unit)? = null
    private var onTransportNegotiated: ((transport: String) -> Unit)? = null

    fun setSessionCallback(callback: (java.net.InetAddress, Int, Int, DatagramSocket?, DatagramSocket?, DatagramSocket?, DatagramSocket?, OutputStream?, Int, Int) -> Unit) {
        onSessionPlay = callback
    }

    fun setStreamingCallbacks(start: () -> Unit, stop: () -> Unit, clientChange: (String?) -> Unit) {
        onStartStreaming = start
        onStopStreaming = stop
        onClientChange = clientChange
    }

    fun setTransportCallback(callback: (String) -> Unit) {
        onTransportNegotiated = callback
    }

    fun start() {
        if (running.get()) return
        running.set(true)
        Thread {
            try {
                serverSocket = ServerSocket(port)
                serverSocket?.reuseAddress = true
                Log.d(tag, "RTSP server started on port $port")
                while (running.get()) {
                    val client = serverSocket?.accept() ?: break
                    client.tcpNoDelay = true // Disable Nagle for low-latency TCP interleaved
                    try {
                        client.sendBufferSize = 512 * 1024 // Enlarge send buffer for high-bitrate video
                    } catch (e: Exception) {
                        Log.w(tag, "Failed to set TCP send buffer size: ${e.message}")
                    }
                    val sessionId = "${client.inetAddress.hostAddress}:${client.port}"
                    Log.d(tag, "New RTSP connection: $sessionId")

                    // Single client enforcement: reject if already serving a client
                    if (clients.isNotEmpty()) {
                        Log.w(tag, "Rejecting $sessionId — single client limit reached")
                        try {
                            val out = client.getOutputStream()
                            out.write("RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: 0\r\n\r\n".toByteArray())
                            out.flush()
                            client.close()
                        } catch (e: Exception) {}
                        continue
                    }

                    onClientChange?.invoke(client.inetAddress.hostAddress)
                    val session = RTSPSession(client, sessionId)
                    clients[sessionId] = session
                    Thread { session.handle() }.start()
                }
            } catch (e: Exception) {
                if (running.get()) Log.e(tag, "Server loop error", e)
            } finally {
                stop()
            }
        }.start()
    }

    fun stop() {
        if (!running.get()) return
        running.set(false)
        try { serverSocket?.close() } catch (e: Exception) {}
        clients.values.forEach { it.close() }
        clients.clear()
        Log.d(tag, "RTSP server stopped")
    }

    /**
     * 分配一对连续的 RTP/RTCP 端口
     */
    private fun allocateRtpPortPair(): Int {
        var port = nextRtpPort.getAndAdd(2)
        // 确保端口不超过 60000
        if (port > 60000) {
            nextRtpPort.set(50000)
            port = nextRtpPort.getAndAdd(2)
        }
        return port
    }

    /**
     * 生成随机的 8 位十六进制 Session ID
     */
    private fun generateSessionId(): String {
        val chars = "0123456789ABCDEF"
        val rng = java.util.Random()
        return (1..8).map { chars[rng.nextInt(chars.length)] }.joinToString("")
    }

    inner class RTSPSession(val socket: Socket, private val sessionId: String) {
        private var cSeq = 0
        private var clientVideoPort = 0
        private var clientAudioPort = 0
        private var isPlaying = false
        private var rtspSessionId = generateSessionId()

        // 在 SETUP 时预创建 RTP/RTCP Socket，以便在 Transport 头中报告正确的 server_port
        private var videoRtpSocket: DatagramSocket? = null
        private var audioRtpSocket: DatagramSocket? = null
        private var videoRtcpSocket: DatagramSocket? = null
        private var audioRtcpSocket: DatagramSocket? = null

        // TCP interleaved 状态
        private var useTcp = false
        private var videoTcpChannel = 0
        private var audioTcpChannel = 2

        fun handle() {
            try {
                val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                val output = socket.getOutputStream()
                while (running.get() && !socket.isClosed) {
                    val request = readRequest(reader) ?: break
                    val response = processRequest(request)
                    synchronized(output) {
                        output.write(response.toByteArray())
                        output.flush()
                    }
                }
            } catch (e: Exception) {
                Log.d(tag, "Session $sessionId error: ${e.message}")
            } finally {
                close()
            }
        }

        private fun readRequest(reader: BufferedReader): String? {
            val lines = mutableListOf<String>()
            var line: String?
            while (true) {
                line = reader.readLine() ?: return null
                if (line.isEmpty()) break
                lines.add(line)
                if (line.startsWith("CSeq:", ignoreCase = true)) {
                    cSeq = line.substringAfter(":").trim().toIntOrNull() ?: 0
                }
            }
            return if (lines.isEmpty()) null else lines.joinToString("\r\n")
        }

        private fun processRequest(request: String): String {
            val lines = request.split("\r\n")
            val firstLine = lines.firstOrNull() ?: ""
            val parts = firstLine.split(" ")
            val method = parts.getOrNull(0) ?: ""
            val url = parts.getOrNull(1) ?: ""

            Log.d(tag, "RTSP $method for $url")

            return when (method) {
                "OPTIONS" -> buildResponse("200 OK", "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER")
                "DESCRIBE" -> {
                    onStartStreaming?.invoke()
                    val sdp = buildSDP()
                    buildResponse("200 OK", "Content-Type: application/sdp\r\nContent-Length: ${sdp.length}", sdp)
                }
                "SETUP" -> {
                    val transport = lines.find { it.startsWith("Transport:", true) } ?: ""
                    val isTcpRequest = transport.contains("TCP", ignoreCase = true) || transport.contains("interleaved", ignoreCase = true)
                    val portMatch = Regex("client_port=(\\d+)-(\\d+)").find(transport)
                    val rtpPort = portMatch?.groupValues?.get(1)?.toInt() ?: 0

                    if (isTcpRequest) {
                        if (!useTcp) {
                            useTcp = true
                            onTransportNegotiated?.invoke("TCP")
                        }
                        // If we were already playing over UDP, allow re-PLAY with new transport
                        if (isPlaying) isPlaying = false
                        // Parse interleaved channels from Transport header, default to 0-1 for video, 2-3 for audio
                        val interleavedMatch = Regex("interleaved=(\\d+)-(\\d+)").find(transport)
                        if (interleavedMatch != null && url.contains("track0")) {
                            videoTcpChannel = interleavedMatch.groupValues[1].toInt()
                        } else if (interleavedMatch != null && url.contains("track1")) {
                            audioTcpChannel = interleavedMatch.groupValues[1].toInt()
                        }
                    } else if (!useTcp) {
                        // Only invoke UDP callback if we haven't already negotiated TCP
                        onTransportNegotiated?.invoke("UDP")
                    }

                    var serverPortRange = "50000-50001"
                    if (url.contains("track0")) {
                        clientVideoPort = rtpPort
                        if (!useTcp) {
                            try {
                                val allocated = allocateRtpPortPair()
                                videoRtpSocket = DatagramSocket(allocated).apply { sendBufferSize = 256 * 1024 }
                                videoRtcpSocket = DatagramSocket(allocated + 1)
                                serverPortRange = "$allocated-${allocated + 1}"
                                Log.d(tag, "Video SETUP: client port $rtpPort, server port $allocated-${allocated + 1}")
                            } catch (e: Exception) {
                                Log.e(tag, "Failed to create video RTP/RTCP sockets", e)
                            }
                        }
                    } else if (url.contains("track1")) {
                        clientAudioPort = rtpPort
                        if (!useTcp) {
                            try {
                                val allocated = allocateRtpPortPair()
                                audioRtpSocket = DatagramSocket(allocated).apply { sendBufferSize = 256 * 1024 }
                                audioRtcpSocket = DatagramSocket(allocated + 1)
                                serverPortRange = "$allocated-${allocated + 1}"
                                Log.d(tag, "Audio SETUP: client port $rtpPort, server port $allocated-${allocated + 1}")
                            } catch (e: Exception) {
                                Log.e(tag, "Failed to create audio RTP/RTCP sockets", e)
                            }
                        }
                    }

                    if (useTcp) {
                        val ch = if (url.contains("track0")) videoTcpChannel else audioTcpChannel
                        buildResponse("200 OK", "Transport: RTP/AVP/TCP;unicast;interleaved=$ch-${ch+1}\r\nSession: $rtspSessionId")
                    } else {
                        buildResponse("200 OK", "Transport: RTP/AVP;unicast;client_port=$rtpPort-${rtpPort+1};server_port=$serverPortRange\r\nSession: $rtspSessionId")
                    }
                }
                "PLAY" -> {
                    if (!isPlaying) {
                        isPlaying = true
                        if (useTcp) {
                            Log.d(tag, "PLAY TCP: videoCh=$videoTcpChannel, audioCh=$audioTcpChannel")
                            onSessionPlay?.invoke(socket.inetAddress, 0, 0, null, null, null, null, socket.getOutputStream(), videoTcpChannel, audioTcpChannel)
                        } else {
                            Log.d(tag, "PLAY UDP: vPort=$clientVideoPort, aPort=$clientAudioPort")
                            onSessionPlay?.invoke(socket.inetAddress, clientVideoPort, clientAudioPort, videoRtpSocket, audioRtpSocket, videoRtcpSocket, audioRtcpSocket, null, 0, 2)
                        }
                    }
                    buildResponse("200 OK", "Session: $rtspSessionId")
                }
                "TEARDOWN" -> {
                    close()
                    buildResponse("200 OK", "Session: $rtspSessionId")
                }
                "GET_PARAMETER" -> buildResponse("200 OK", "Session: $rtspSessionId")
                else -> buildResponse("200 OK", "Session: $rtspSessionId")
            }
        }

        private fun buildSDP(): String {
            val sps = videoProvider.getSPS()
            val pps = videoProvider.getPPS()
            val vps = videoProvider.getVPS()
            val isHevc = videoCodec == "h265"
            Log.d(tag, "buildSDP: codec=$videoCodec, VPS=${vps?.size ?: "null"}, SPS=${sps?.size ?: "null"}, PPS=${pps?.size ?: "null"}")
            val ip = socket.localAddress.hostAddress
            val base = "rtsp://$ip:$port$path"

            val videoSection: String
            if (isHevc) {
                var sprop = ""
                if (vps != null && sps != null && pps != null) {
                    val vpsB64 = android.util.Base64.encodeToString(extract(vps), android.util.Base64.NO_WRAP)
                    val spsB64 = android.util.Base64.encodeToString(extract(sps), android.util.Base64.NO_WRAP)
                    val ppsB64 = android.util.Base64.encodeToString(extract(pps), android.util.Base64.NO_WRAP)
                    sprop = " sprop-vps=$vpsB64;sprop-sps=$spsB64;sprop-pps=$ppsB64"
                }
                videoSection = "m=video 0 RTP/AVP 96\r\n" +
                    "a=rtpmap:96 H265/90000\r\n" +
                    "a=fmtp:96$sprop\r\n" +
                    "a=control:$base/track0\r\n"
            } else {
                var sprop = ""
                if (sps != null && pps != null) {
                    val spsB64 = android.util.Base64.encodeToString(extract(sps), android.util.Base64.NO_WRAP)
                    val ppsB64 = android.util.Base64.encodeToString(extract(pps), android.util.Base64.NO_WRAP)
                    sprop = ";sprop-parameter-sets=$spsB64,$ppsB64"
                }
                val profileLevelId = videoProvider.getProfileLevelId() ?: "640029"
                videoSection = "m=video 0 RTP/AVP 96\r\n" +
                    "a=rtpmap:96 H264/90000\r\n" +
                    "a=fmtp:96 packetization-mode=1;profile-level-id=$profileLevelId$sprop\r\n" +
                    "a=control:$base/track0\r\n"
            }

            val audioSection = if (audioEnabled) {
                "m=audio 0 RTP/AVP 97\r\n" +
                "a=rtpmap:97 mpeg4-generic/44100/1\r\n" +
                "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1210\r\n" +
                "a=control:$base/track1\r\n"
            } else {
                ""
            }

            return "v=0\r\n" +
                   "o=- 0 0 IN IP4 $ip\r\ns=RTSP Camera\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n" +
                   "a=range:npt=now-\r\n" +
                   videoSection +
                   audioSection
        }

        private fun extract(d: ByteArray): ByteArray {
            if (d.size < 4) return d
            return if (d[0] == 0.toByte() && d[1] == 0.toByte() && d[2] == 0.toByte() && d[3] == 1.toByte()) {
                d.copyOfRange(4, d.size)
            } else if (d[0] == 0.toByte() && d[1] == 0.toByte() && d[2] == 1.toByte()) {
                d.copyOfRange(3, d.size)
            } else {
                d
            }
        }

        private fun buildResponse(s: String, h: String, b: String = ""): String {
            return "RTSP/1.0 $s\r\nCSeq: $cSeq\r\n$h\r\n\r\n$b"
        }

        fun close() {
            try {
                if (!socket.isClosed) socket.close()
            } catch (e: Exception) {}
            // 关闭 RTP/RTCP Socket（仅当 PLAY 未触发时需要；PLAY 后由 RTPSender 管理）
            if (!isPlaying) {
                try { videoRtpSocket?.close() } catch (e: Exception) {}
                try { audioRtpSocket?.close() } catch (e: Exception) {}
                try { videoRtcpSocket?.close() } catch (e: Exception) {}
                try { audioRtcpSocket?.close() } catch (e: Exception) {}
            }
            clients.remove(sessionId)
            if (clients.isEmpty()) {
                Log.d(tag, "All clients disconnected, stopping stream")
                onClientChange?.invoke(null)
                onStopStreaming?.invoke()
            } else {
                onClientChange?.invoke(clients.values.firstOrNull()?.socket?.inetAddress?.hostAddress)
            }
        }
    }
}
