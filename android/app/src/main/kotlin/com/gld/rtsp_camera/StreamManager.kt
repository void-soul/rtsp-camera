package com.gld.rtsp_camera

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log

class StreamManager(
    private val activity: Activity,
    private val settingsManager: SettingsManager,
    private val videoProvider: H264FrameProvider,
    private val audioProvider: AudioFrameProvider,
    private val cameraManager: CameraManager
) {
    private var videoEncoder: H264Encoder? = null
    private var h265Encoder: H265Encoder? = null
    private var audioEncoder: AudioEncoder? = null
    private var audioActive = false
    // ABR state
    private var currentBitrate: Int = 0
    private var minBitrate: Int = 1
    private var lastLossTime = 0L
    private var rtspserver: SimpleRTSPServer? = null
    private var videoSender: RTPSender? = null
    private var audioSender: AudioRTPSender? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var activeCodec: String = "h264"
    @Volatile
    private var lastLossPercent = 0.0

    val streamStartPtsUs = java.util.concurrent.atomic.AtomicLong(-1L)

    var callback: Callback? = null

    interface Callback {
        fun onClientIpChanged(ip: String?)
        fun onStreamingChanged(streaming: Boolean)
        fun onTransportNegotiated(transport: String)
    }

    fun isStreaming(): Boolean = cameraManager.isStreaming

    fun getSentFrames(): Long = videoSender?.totalSentFrames ?: 0L
    fun getDroppedFrames(): Long = videoProvider.totalDroppedFrames
    fun getQueueSize(): Int = videoProvider.getFilledQueueSize()
    fun getQueueCapacity(): Int = videoProvider.getQueueCapacity()
    fun getPushFps(): Double = videoSender?.currentFps ?: 0.0
    fun getLossPercent(): Double = lastLossPercent
    fun getAbrBitrate(): Pair<Int, Int> = Pair(currentBitrate, settingsManager.bitrate)

    fun getActiveCodecName(): String {
        return if (cameraManager.isStreaming) {
            if (activeCodec == "h265") "H.265" else "H.264"
        } else {
            settingsManager.videoCodec.uppercase()
        }
    }

    fun getVideoEncoder(): H264Encoder? = videoEncoder

    fun getH265Encoder(): H265Encoder? = h265Encoder

    fun getEncoderSurface(): android.view.Surface? {
        return videoEncoder?.getInputSurface() ?: h265Encoder?.getInputSurface()
    }

    fun setVideoEncoder(encoder: H264Encoder?) { videoEncoder = encoder; h265Encoder = null }

    /** Set H.265 encoder as active (clears H.264 encoder). */
    fun setH265Encoder(encoder: H265Encoder?) { h265Encoder = encoder; videoEncoder = null }

    fun setActiveCodec(codec: String) { activeCodec = codec }

    /** Encode a frame using whichever encoder is active. */
    fun encodeFrame(data: ByteArray, timestampUs: Long) {
        videoEncoder?.encode(data, timestampUs)
        h265Encoder?.encode(data, timestampUs)
    }

    /** Restart active encoder with corrected FPS. */
    fun restartEncoderWithFps(newFps: Int): Boolean {
        return videoEncoder?.restartWithFps(newFps) ?: h265Encoder?.restartWithFps(newFps) ?: false
    }

    private fun requestEncoderSyncFrame() {
        videoEncoder?.requestSyncFrame() ?: h265Encoder?.requestSyncFrame()
    }

    private fun updateEncoderBitrate(mbps: Int) {
        videoEncoder?.updateBitrate(mbps) ?: h265Encoder?.updateBitrate(mbps)
    }

    fun startAll() {
        if (cameraManager.isStreaming) return
        videoProvider.resetStats()
        lastLossPercent = 0.0
        cameraManager.isStreaming = true
        acquireWakeLock()

        val (w, h) = cameraManager.getActualVideoDimensions()
        val width = if (w >= 100) w else settingsManager.getWidth()
        val height = if (h >= 100) h else settingsManager.getHeight()
        Log.d("StreamManager", "Starting encoder: ${width}x${height} (actual=${w}x${h}, target=${settingsManager.getWidth()}x${settingsManager.getHeight()})")

        videoProvider.prepare()
        videoProvider.keyframeRequester = { requestEncoderSyncFrame() }
        val codec = settingsManager.videoCodec
        activeCodec = codec

        // Try H.265 first if configured, fall back to H.264
        var encoderStarted = false
        if (codec == "h265") {
            h265Encoder = H265Encoder(width, height, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
            encoderStarted = h265Encoder?.start() ?: false
            if (!encoderStarted) {
                Log.w("StreamManager", "H.265 unavailable, falling back to H.264")
                h265Encoder = null
                activeCodec = "h264"
            }
        }
        if (!encoderStarted) {
            videoEncoder = H264Encoder(width, height, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
            encoderStarted = videoEncoder?.start() ?: false
            activeCodec = "h264"
        }
        cameraManager.encoderWidth = width
        cameraManager.encoderHeight = height
        if (!encoderStarted) {
            stopAll()
            return
        }

        val audioPermission = androidx.core.content.ContextCompat.checkSelfPermission(
            activity,
            android.Manifest.permission.RECORD_AUDIO
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        audioActive = settingsManager.audioEnabled && audioPermission

        if (audioActive) { audioEncoder = AudioEncoder(audioProvider); audioEncoder?.start() }

        rtspserver = SimpleRTSPServer(settingsManager.rtspPort, settingsManager.rtspPath, videoProvider, audioProvider, audioActive, activeCodec)
        rtspserver?.setStreamingCallbacks(
            start = {},
            stop = {
                // Client disconnected — stop all senders so resources are released
                videoSender?.stop(); videoSender = null
                audioSender?.stop(); audioSender = null
            },
            clientChange = { ip -> activity.runOnUiThread { callback?.onClientIpChanged(ip) } }
        )
        rtspserver?.setTransportCallback { transport -> activity.runOnUiThread { callback?.onTransportNegotiated(transport) } }
        rtspserver?.setSessionCallback { addr, vPort, aPort, vSocket, aSocket, vRtcpSocket, aRtcpSocket, tcpOutput, videoTcpCh, audioTcpCh ->
            // Drop stale frames accumulated before PLAY to avoid initial latency
            videoProvider.clearFilledQueue()
            videoSender?.stop()
            streamStartPtsUs.set(-1L)
            videoSender = if (tcpOutput != null) {
                RTPSender(addr, 0, videoProvider, tcpOutputStream = tcpOutput, tcpChannel = videoTcpCh, videoCodec = activeCodec, streamStartPtsUs = streamStartPtsUs)
            } else {
                RTPSender(addr, vPort, videoProvider, vSocket, rtcpSocket = vRtcpSocket, videoCodec = activeCodec, streamStartPtsUs = streamStartPtsUs)
            }
            videoSender?.setFramerate(settingsManager.fps)
            setupAbr()
            Thread {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
                try { videoSender?.start() } catch (e: Exception) { Log.e("StreamManager", "Video sender error", e) }
            }.apply { name = "VideoRTPSender" }.start()
            requestEncoderSyncFrame()

            if (audioActive) {
                audioSender?.stop()
                audioSender = if (tcpOutput != null) {
                    AudioRTPSender(addr, 0, audioProvider, tcpOutputStream = tcpOutput, tcpChannel = audioTcpCh, streamStartPtsUs = streamStartPtsUs)
                } else if (aPort > 0) {
                    AudioRTPSender(addr, aPort, audioProvider, aSocket, rtcpSocket = aRtcpSocket, streamStartPtsUs = streamStartPtsUs)
                } else {
                    null
                }
                audioSender?.let {
                    Thread {
                        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
                        try { it.start() } catch (e: Exception) { Log.e("StreamManager", "Audio sender error", e) }
                    }.apply { name = "AudioRTPSender" }.start()
                }
            }
        }
        rtspserver?.start()
        cameraManager.bindCameraUseCases()
        startForegroundService()
        callback?.onStreamingChanged(true)
    }

    fun stopAll() {
        cameraManager.isStreaming = false
        lastLossPercent = 0.0
        cameraManager.bindCameraUseCases()
        releaseWakeLock()
        stopForegroundService()
        rtspserver?.stop(); rtspserver = null
        videoSender?.stop(); videoSender = null
        audioSender?.stop(); audioSender = null
        videoEncoder?.release(); videoEncoder = null
        h265Encoder?.release(); h265Encoder = null
        audioEncoder?.stop(); audioEncoder = null
        callback?.onStreamingChanged(false)
    }

    fun setAudioMuted(muted: Boolean) {
        audioSender?.stop(); audioSender = null
    }

    private fun setupAbr() {
        currentBitrate = settingsManager.bitrate
        minBitrate = maxOf(1, settingsManager.bitrate / 5)
        lastLossTime = 0L
        videoSender?.setPacketLossCallback { fractionLost ->
            // fractionLost: 0-255, where 255 = 100% loss
            val lossPercent = fractionLost / 2.55
            lastLossPercent = lossPercent
            if (fractionLost > 12) { // > ~5% loss: reduce bitrate aggressively
                val newBr = maxOf(minBitrate, (currentBitrate * 0.75).toInt())
                if (newBr < currentBitrate) {
                    Log.d("StreamManager", "ABR: loss ${"%.1f".format(lossPercent)}%, reducing bitrate $currentBitrate→$newBr Mbps")
                    currentBitrate = newBr
                    updateEncoderBitrate(newBr)
                    lastLossTime = System.currentTimeMillis()
                }
            } else if (fractionLost == 0 && lastLossTime > 0 &&
                       System.currentTimeMillis() - lastLossTime > 30000) {
                // 30s no loss: slowly increase
                val newBr = minOf(settingsManager.bitrate, (currentBitrate * 1.1).toInt() + 1)
                if (newBr > currentBitrate) {
                    Log.d("StreamManager", "ABR: recovering $currentBitrate→$newBr Mbps")
                    currentBitrate = newBr
                    updateEncoderBitrate(newBr)
                }
                lastLossTime = 0L
            }
        }
    }

    // Update notification with current streaming info
    fun updateNotification(url: String, clientIp: String) {
        val wifi = StreamService.getWifiInfo(activity)
        val codec = if (h265Encoder != null) "H.265" else "H.264"
        val info = "$codec  ${settingsManager.getWidth()}x${settingsManager.getHeight()}  ${settingsManager.bitrate}Mbps  $wifi"
        try {
            val service = StreamService::class.java
            // Use the service instance via a static helper — for now we just send a broadcast intent
            // that the service picks up for notification updates
        } catch (e: Exception) { Log.w("StreamManager", "Notification update failed: ${e.message}") }
    }

    private fun startForegroundService() {
        val intent = Intent(activity, StreamService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun stopForegroundService() {
        activity.stopService(Intent(activity, StreamService::class.java))
    }

    fun requestSyncFrame() {
        requestEncoderSyncFrame()
    }

    fun updateBitrate(mbps: Int) {
        updateEncoderBitrate(mbps)
    }

    fun setFramerate(fps: Int) {
        videoSender?.setFramerate(fps)
    }

    fun resetVideoSPSPPS() {
        videoSender?.resetSPSPPS()
    }

    /**
     * 推流过程中动态切换分辨率：释放旧编码器，用新尺寸重建。
     * 支持 H.264 和 H.265 两种编码器。
     */
    fun restartEncoderForResolution(width: Int, height: Int) {
        if (!cameraManager.isStreaming) return
        // Find the active encoder (H.264 or H.265)
        val isH265Active = h265Encoder != null
        if (videoEncoder == null && h265Encoder == null) return
        if (cameraManager.encoderWidth == width && cameraManager.encoderHeight == height) return

        Log.d("StreamManager", "Restarting encoder for resolution: ${width}x${height}")
        if (isH265Active) { h265Encoder?.release() } else { videoEncoder?.release() }

        videoProvider.prepare()
        videoProvider.keyframeRequester = { requestEncoderSyncFrame() }

        if (isH265Active) {
            h265Encoder = H265Encoder(width, height, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
            videoEncoder = null
            val started = h265Encoder?.start() ?: false
            if (!started) {
                // H.265 failed, fall back to H.264
                Log.w("StreamManager", "H.265 restart failed, falling back to H.264")
                h265Encoder = null
                activeCodec = "h264"
                videoEncoder = H264Encoder(width, height, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
                if (!videoEncoder!!.start()) { stopAll(); return }
            }
        } else {
            videoEncoder = H264Encoder(width, height, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
            h265Encoder = null
            if (!videoEncoder!!.start()) { stopAll(); return }
        }
        cameraManager.encoderWidth = width
        cameraManager.encoderHeight = height

        videoSender?.resetSPSPPS()
        requestEncoderSyncFrame()
    }

    @Suppress("DEPRECATION")
    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rtsp-camera::stream")
                wakeLock?.setReferenceCounted(false)
            }
            wakeLock?.acquire(4 * 60 * 60 * 1000L)
        } catch (e: Exception) { Log.w("StreamManager", "Failed to acquire WakeLock: ${e.message}") }
    }

    private fun releaseWakeLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (e: Exception) {}
    }
}
