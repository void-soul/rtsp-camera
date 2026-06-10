package com.gld.rtsp_camera

import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CameraCharacteristics
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraInfo
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop

/**
 * 当前摄像头的硬件能力信息。
 */
data class CameraCapabilities(
    /** 支持的帧率列表 */
    val supportedFps: List<Int> = listOf(15, 24, 30, 60),
    /** 是否支持闪光灯 */
    val hasFlash: Boolean = false,
    /** 变焦最小值 */
    val minZoom: Float = 1.0f,
    /** 变焦最大值 */
    val maxZoom: Float = 1.0f,
    /** 曝光补偿最小值 */
    val minEv: Int = 0,
    /** 曝光补偿最大值 */
    val maxEv: Int = 0,
    /** 支持的白平衡模式列表 */
    val supportedWb: List<Int> = listOf(CaptureRequest.CONTROL_AWB_MODE_AUTO),
    /** 支持的效果/滤镜列表 */
    val supportedEffects: List<Int> = listOf(CaptureRequest.CONTROL_EFFECT_MODE_OFF),
    /** 是否支持手动对焦 */
    val supportsManualFocus: Boolean = false
) {
    companion object {
        private const val TAG = "CameraCapabilities"

        @OptIn(ExperimentalCamera2Interop::class)
        fun fromCameraInfo(cameraInfo: CameraInfo): CameraCapabilities {
            val hasFlash = cameraInfo.hasFlashUnit()

            val zoomState = cameraInfo.zoomState.value
            val zMin = zoomState?.minZoomRatio ?: 1.0f
            val zMax = zoomState?.maxZoomRatio ?: 1.0f

            val evRange = cameraInfo.exposureState.exposureCompensationRange

            var fpsList = listOf(15, 24, 30, 60)
            var wbList = listOf(CaptureRequest.CONTROL_AWB_MODE_AUTO)
            var effectList = listOf(CaptureRequest.CONTROL_EFFECT_MODE_OFF)
            var supportsManualFocus = false

            try {
                val cam2Info = Camera2CameraInfo.from(cameraInfo)
                
                // 1. 获取支持的帧率上限列表
                val fpsRanges = cam2Info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                if (fpsRanges != null) {
                    val uppers = fpsRanges.map { it.upper }.distinct().sorted()
                    if (uppers.isNotEmpty()) {
                        fpsList = uppers
                    }
                }

                // 2. 获取支持的白平衡模式
                val awbModes = cam2Info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)
                if (awbModes != null) {
                    wbList = awbModes.toList()
                }

                // 3. 获取支持的效果模式
                val effects = cam2Info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AVAILABLE_EFFECTS)
                if (effects != null) {
                    effectList = effects.toList()
                }

                // 4. 判断是否支持手动对焦
                val minFocusDist = cam2Info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
                val afModes = cam2Info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                val hasManualAFMode = afModes?.contains(CaptureRequest.CONTROL_AF_MODE_OFF) ?: false
                // 最小焦距 > 0 (如果是0表示固定焦点镜头) 且 支持 CONTROL_AF_MODE_OFF
                supportsManualFocus = (minFocusDist != null && minFocusDist > 0.0f) && hasManualAFMode
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse Camera2 characteristics", e)
            }

            return CameraCapabilities(
                supportedFps = fpsList,
                hasFlash = hasFlash,
                minZoom = zMin,
                maxZoom = zMax,
                minEv = evRange.lower,
                maxEv = evRange.upper,
                supportedWb = wbList,
                supportedEffects = effectList,
                supportsManualFocus = supportsManualFocus
            )
        }
    }
}

