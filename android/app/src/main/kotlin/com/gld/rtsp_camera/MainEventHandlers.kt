package com.gld.rtsp_camera

import android.util.Log
import android.view.View
import androidx.appcompat.app.AppCompatActivity

class MainEventHandlers(
    private val activity: AppCompatActivity,
    private val cameraManager: CameraManager,
    private val streamManager: StreamManager,
    private val uiController: UiController,
    private val settingsManager: SettingsManager,
    private val videoProvider: H264FrameProvider
) {
    fun setupCallbacks() {
        cameraManager.callback = object : CameraManager.Callback {
            override fun onVideoFrame(data: ByteArray, timestampUs: Long) {
                streamManager.encodeFrame(data, timestampUs)
            }

            override fun onFrameSizeMismatch() {
                val enc = streamManager.getVideoEncoder()
                val h265Enc = streamManager.getH265Encoder()
                if (enc == null && h265Enc == null) return
                enc?.release(); h265Enc?.release()
                val newW = cameraManager.actualVideoWidth; val newH = cameraManager.actualVideoHeight
                val isH265 = h265Enc != null
                if (isH265) {
                    val newEnc = H265Encoder(newW, newH, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
                    cameraManager.encoderWidth = newW; cameraManager.encoderHeight = newH
                    streamManager.setH265Encoder(newEnc)
                    if (!newEnc.start()) {
                        // Fall back to H.264
                        Log.w("MainEventHandlers", "H.265 restart failed, falling back to H.264")
                        streamManager.setActiveCodec("h264")
                        val fallback = H264Encoder(newW, newH, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
                        streamManager.setVideoEncoder(fallback)
                        fallback.start()
                    }
                } else {
                    val newEnc = H264Encoder(newW, newH, settingsManager.bitrate, settingsManager.fps, settingsManager.gop, videoProvider)
                    cameraManager.encoderWidth = newW; cameraManager.encoderHeight = newH
                    streamManager.setVideoEncoder(newEnc)
                    newEnc.start()
                }
            }

            override fun onCameraCapabilitiesUpdated(caps: CameraCapabilities) {
                uiController.applyCapabilityUI()
            }

            override fun onActualFpsDetected(actualFps: Int) {
                val targetFps = settingsManager.fps
                Log.d("MainEventHandlers", "onActualFpsDetected: actual=${actualFps}, target=${targetFps}")
                if (actualFps < targetFps - 5) {
                    Log.d("MainEventHandlers", "Camera delivers ${actualFps}fps vs target ${targetFps}fps, adjusting encoder")
                    streamManager.restartEncoderWithFps(actualFps)
                    streamManager.resetVideoSPSPPS()
                }
            }
        }

        streamManager.callback = object : StreamManager.Callback {
            override fun onClientIpChanged(ip: String?) {
                uiController.tvClientIp.text = if (ip != null) " $ip" else ""
                // Flash red border when client disconnects while streaming is active
                if (ip == null && streamManager.isStreaming()) {
                    uiController.startAlertBorder()
                } else if (ip != null) {
                    uiController.stopAlertBorder()
                }
            }

            override fun onStreamingChanged(streaming: Boolean) {
                if (streaming) {
                    uiController.startStatusUpdater()
                } else {
                    uiController.stopStatusUpdater()
                    uiController.tvClientIp.text = ""
                    uiController.stopAlertBorder()
                }
                uiController.updateRtspAddress()
                uiController.updateFab(streaming)
                uiController.updatePreviewState()
                uiController.updateCenterStatus()
            }

            override fun onTransportNegotiated(transport: String) {
                uiController.updateTransportLabel(transport)
            }
        }

        uiController.callback = object : UiController.Callback {
            override fun onStartStreaming() { streamManager.startAll() }
            override fun onStopStreaming() { streamManager.stopAll() }
            override fun onToggleCamera() { cameraManager.toggleCamera() }
            override fun onToggleFlash() { cameraManager.enableTorch(uiController.isTorchOn) }
            override fun onToggleAudio() { settingsManager.audioEnabled = !settingsManager.audioEnabled; uiController.updateTogglesUI() }
            override fun onTogglePreview() {
                settingsManager.previewEnabled = !settingsManager.previewEnabled
                uiController.updatePreviewState()
                uiController.updateTogglesUI()
                cameraManager.bindCameraUseCases()
                (activity as? MainActivity)?.let {
                    if (settingsManager.previewEnabled) it.wakeUpScreen() else it.resetDimTimer()
                }
            }
            override fun onCopyRtspUrl() { uiController.copyRtspAddress() }
            override fun onNetworkSettingsChanged() { uiController.updateRtspAddress() }
            override fun onResolutionChanged() {
                cameraManager.bindCameraUseCases()
                if (streamManager.isStreaming()) {
                    // 推流中切换分辨率：重启编码器产出新分辨率流
                    val newW = settingsManager.getWidth()
                    val newH = settingsManager.getHeight()
                    if (newW >= 100 && newH >= 100) {
                        streamManager.restartEncoderForResolution(newW, newH)
                    }
                }
            }
            override fun onFpsChanged(fps: Int) { streamManager.setFramerate(fps) }
            override fun onCodecChanged(codec: String) {
                Log.d("MainEventHandlers", "Codec changed to: $codec")
            }
            override fun getActiveCodec(): String = streamManager.getActiveCodecName()
            override fun onWbOrFilterChanged() { cameraManager.applyCamera2Options(); uiController.updateTogglesUI() }
            override fun onFocusDialChanged(distance: Float) { cameraManager.applyCamera2Options() }
            override fun onResetAutoFocus() { cameraManager.isManualFocus = false; cameraManager.currentFocusDistance = 0.0f; uiController.tvFocusValue.text = "AF"; cameraManager.applyCamera2Options() }
            override fun isStreaming(): Boolean = streamManager.isStreaming()
            override fun updateEncoderBitrate(mbps: Int) { streamManager.updateBitrate(mbps) }
            override fun requestEncoderKeyFrame() { streamManager.requestSyncFrame() }
            override fun onQueueCapacityChanged(capacity: Int) {
                videoProvider.setQueueCapacity(capacity)
            }
        }
    }

    fun setupListeners() {
        uiController.apply {
            fabAction.setOnClickListener { if (!streamManager.isStreaming()) callback?.onStartStreaming() else callback?.onStopStreaming() }
            btnFlip.setOnClickListener { if (streamManager.isStreaming()) return@setOnClickListener; callback?.onToggleCamera() }
        }
        activity.findViewById<View>(android.R.id.content).setOnClickListener { uiController.toggleUI() }
        uiController.surfaceView.setOnClickListener { uiController.toggleUI() }
        uiController.btnFlash.setOnClickListener { uiController.isTorchOn = !uiController.isTorchOn; uiController.callback?.onToggleFlash(); uiController.updateTogglesUI() }
        uiController.btnAudio.setOnClickListener { uiController.callback?.onToggleAudio() }
        uiController.btnPreview.setOnClickListener { uiController.callback?.onTogglePreview() }
        uiController.btnSettings.setOnClickListener { if (streamManager.isStreaming()) return@setOnClickListener; uiController.showNetworkDialog() }
        uiController.btnPerfToggle.setOnClickListener { uiController.togglePerfMonitor() }
        uiController.btnHelp.setOnClickListener { uiController.showHelpDialog() }

        activity.findViewById<View>(R.id.btnParamZoomLayout).setOnClickListener { uiController.activateDial("zoom") }
        activity.findViewById<View>(R.id.btnParamExpLayout).setOnClickListener { uiController.activateDial("ev") }
        activity.findViewById<View>(R.id.btnParamFocusLayout).setOnClickListener { uiController.activateDial("focus") }

        uiController.tvBitrate.setOnClickListener { uiController.showBitratePopup(it as View) }
        uiController.tvFps.setOnClickListener { uiController.showFpsPopup(it as View) }
        uiController.tvGop.setOnClickListener { uiController.showGopPopup(it as View) }
        uiController.tvQueue.setOnClickListener { uiController.showQueuePopup(it as View) }
        uiController.tvCodec.setOnClickListener { uiController.showCodecPopup(it as View) }

        activity.findViewById<View>(R.id.btnWbLayout).setOnClickListener { uiController.showWbPopup(it as View) }
        activity.findViewById<View>(R.id.btnFilterLayout).setOnClickListener { uiController.showFilterPopup(it as View) }
        uiController.tvLanguage.setOnClickListener { uiController.showLanguagePopup(it as View) }
        uiController.tvResolution.setOnClickListener { uiController.showResolutionPopup(it as View) }

        activity.findViewById<View>(R.id.btnParamFocusLayout).setOnLongClickListener { uiController.deactivateDial(); uiController.callback?.onResetAutoFocus(); true }
    }
}
