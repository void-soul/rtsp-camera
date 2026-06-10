package com.gld.rtsp_camera

import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CameraCharacteristics
import android.os.Build
import android.util.Log
import android.view.SurfaceView
import android.util.Range
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.*
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import java.util.concurrent.ExecutorService

class CameraManager(
    private val activity: MainActivity,
    private val settingsManager: SettingsManager,
    private val surfaceView: SurfaceView,
    private val cameraExecutor: ExecutorService
) {
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var camCaps: CameraCapabilities? = null

    var streamManager: StreamManager? = null
    var actualVideoWidth = 0
        private set
    var actualVideoHeight = 0
        private set

    var cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
    var isManualFocus = false
    var currentFocusDistance = 0.0f
    var currentWbMode = CaptureRequest.CONTROL_AWB_MODE_AUTO
    var currentEffectMode = CaptureRequest.CONTROL_EFFECT_MODE_OFF

    var isStreaming = false
    var encoderWidth = 0
    var encoderHeight = 0

    var callback: Callback? = null

    interface Callback {
        fun onVideoFrame(data: ByteArray, timestampUs: Long)
        fun onFrameSizeMismatch()
        fun onCameraCapabilitiesUpdated(caps: CameraCapabilities)
        fun onActualFpsDetected(actualFps: Int)
    }

    fun startCameraX() {
        ProcessCameraProvider.getInstance(activity).addListener({
            cameraProvider = ProcessCameraProvider.getInstance(activity).get()
            bindCameraUseCases()
        }, ContextCompat.getMainExecutor(activity))
    }

    fun bindCameraUseCases() {
        val provider = cameraProvider ?: return
        val rotation = surfaceView.display?.rotation ?: android.view.Surface.ROTATION_0
        val targetSize = android.util.Size(settingsManager.getWidth(), settingsManager.getHeight())

        actualVideoWidth = targetSize.width
        actualVideoHeight = targetSize.height

        val resSel = ResolutionSelector.Builder().setResolutionStrategy(
            ResolutionStrategy(targetSize, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
        ).build()

        val useCases = mutableListOf<UseCase>()
        var screenPreview: Preview? = null
        if (settingsManager.previewEnabled) {
            // Calculate a lower preview size with the same aspect ratio to save camera ISP/GPU resources
            val aspectRatio = targetSize.width.toFloat() / targetSize.height.toFloat()
            val previewTargetSize = if (Math.abs(aspectRatio - 1.777f) < 0.1f) {
                android.util.Size(1280, 720) // 16:9
            } else if (Math.abs(aspectRatio - 1.333f) < 0.1f) {
                android.util.Size(960, 720)  // 4:3
            } else {
                android.util.Size((720 * aspectRatio).toInt(), 720)
            }
            Log.d("CameraManager", "Screen preview target size: $previewTargetSize (aspectRatio: $aspectRatio)")

            val previewResSel = ResolutionSelector.Builder().setResolutionStrategy(
                ResolutionStrategy(previewTargetSize, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
            ).build()

            val preview = Preview.Builder().setResolutionSelector(previewResSel).setTargetRotation(rotation).build()
            preview.setSurfaceProvider(ContextCompat.getMainExecutor(activity)) { request ->
                request.provideSurface(surfaceView.holder.surface, ContextCompat.getMainExecutor(activity)) {}
            }
            screenPreview = preview
            useCases.add(preview)
        }

        var encoderPreview: Preview? = null
        if (isStreaming) {
            val encoderSurface = streamManager?.getEncoderSurface()
            if (encoderSurface != null) {
                Log.d("CameraManager", "Binding encoder surface directly for zero-copy: $encoderSurface")
                val encPreview = Preview.Builder().setResolutionSelector(resSel).setTargetRotation(rotation).build()
                encPreview.setSurfaceProvider(cameraExecutor) { request ->
                    request.provideSurface(encoderSurface, cameraExecutor) {}
                }
                encoderPreview = encPreview
                useCases.add(encPreview)
            } else {
                Log.w("CameraManager", "Streaming is active but encoder surface is NULL")
            }
        }

        try {
            provider.unbindAll()
            if (useCases.isNotEmpty()) {
                val boundCases = useCases.toTypedArray()
                camera = provider.bindToLifecycle(activity, cameraSelector, *boundCases)
                camera?.cameraInfo?.let { info ->
                    camCaps = CameraCapabilities.fromCameraInfo(info)
                    callback?.onCameraCapabilitiesUpdated(camCaps!!)
                }
                applyCamera2Options()
            } else {
                camera = null
            }
        } catch (e: Exception) {
            Log.e("CameraManager", "Binding use cases failed", e)
            if (useCases.size > 1 && screenPreview != null) {
                Log.w("CameraManager", "Retrying screen preview-only as fallback...")
                try {
                    provider.unbindAll()
                    camera = provider.bindToLifecycle(activity, cameraSelector, screenPreview)
                    camera?.cameraInfo?.let { info ->
                        camCaps = CameraCapabilities.fromCameraInfo(info)
                        callback?.onCameraCapabilitiesUpdated(camCaps!!)
                    }
                    applyCamera2Options()
                } catch (e2: Exception) {
                    Log.e("CameraManager", "Fallback binding also failed", e2)
                }
            }
        }
    }

    fun toggleCamera() {
        cameraSelector = if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        bindCameraUseCases()
    }

    fun enableTorch(on: Boolean) {
        camera?.cameraControl?.enableTorch(on)
    }

    fun getCamera(): Camera? = camera

    fun getCameraExecutor(): ExecutorService = cameraExecutor

    fun getCameraCaps(): CameraCapabilities? = camCaps

    fun getActualVideoDimensions(): Pair<Int, Int> = Pair(actualVideoWidth, actualVideoHeight)

    fun resetActualVideoDimensions() { actualVideoWidth = 0; actualVideoHeight = 0 }

    @OptIn(ExperimentalCamera2Interop::class)
    fun applyCamera2Options() {
        val cam = camera ?: return
        try {
            val ctrl = Camera2CameraControl.from(cam.cameraControl)
            val b = CaptureRequestOptions.Builder()
            if (isManualFocus) {
                b.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                b.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, currentFocusDistance)
            } else b.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            b.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, currentWbMode)
            b.setCaptureRequestOption(CaptureRequest.CONTROL_EFFECT_MODE, currentEffectMode)

            val oisMode = if (settingsManager.useOIS) {
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON
            } else {
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF
            }
            b.setCaptureRequestOption(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, oisMode)

            val eisMode = if (settingsManager.useEIS) {
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
            } else {
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
            }
            b.setCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, eisMode)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val dcMode = if (settingsManager.useDistortionCorrection) {
                    CaptureRequest.DISTORTION_CORRECTION_MODE_HIGH_QUALITY
                } else {
                    CaptureRequest.DISTORTION_CORRECTION_MODE_OFF
                }
                b.setCaptureRequestOption(CaptureRequest.DISTORTION_CORRECTION_MODE, dcMode)
            }

            b.setCaptureRequestOption(CaptureRequest.EDGE_MODE, settingsManager.edgeEnhancement)

            // Request target FPS from camera hardware
            val fps = settingsManager.fps
            val cam2Info = Camera2CameraInfo.from(cam.cameraInfo)
            val fpsRanges = try {
                cam2Info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            } catch (e: Exception) { null }
            
            var selectedRange: Range<Int>? = null
            if (fpsRanges != null) {
                // Find exact [fps, fps] first
                selectedRange = fpsRanges.firstOrNull { it.lower == fps && it.upper == fps }
                // If not found, find any range with upper == fps
                if (selectedRange == null) {
                    selectedRange = fpsRanges.firstOrNull { it.upper == fps }
                }
                // If still not found, find range with highest upper
                if (selectedRange == null) {
                    selectedRange = fpsRanges.maxByOrNull { it.upper }
                }
            }
            if (selectedRange != null) {
                b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, selectedRange)
                Log.d("CameraManager", "Selected camera FPS range: ${selectedRange.lower}-${selectedRange.upper} (target: $fps)")
            } else {
                b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
                Log.d("CameraManager", "Requested fallback camera FPS range: ${fps}-${fps}")
            }
            ctrl.setCaptureRequestOptions(b.build())
        } catch (e: Exception) { Log.e("CameraManager", "Failed to apply Camera2 options", e) }
    }

}
