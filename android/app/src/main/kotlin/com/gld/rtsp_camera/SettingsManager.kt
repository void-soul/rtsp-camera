package com.gld.rtsp_camera

import android.content.Context
import android.content.SharedPreferences
import androidx.preference.PreferenceManager

class SettingsManager(context: Context) {
    private val prefs: SharedPreferences = PreferenceManager.getDefaultSharedPreferences(context)

    var resolution: String
        get() = prefs.getString("resolution", "1280x720") ?: "1280x720"
        set(value) { prefs.edit().putString("resolution", value).apply(); cachedWidth = -1 }

    @Volatile private var cachedWidth = -1
    @Volatile private var cachedHeight = -1
    fun getWidth(): Int {
        if (cachedWidth <= 0) { val parts = resolution.split("x"); cachedWidth = try { parts[0].toInt() } catch (e: Exception) { 1280 }; cachedHeight = try { parts[1].toInt() } catch (e: Exception) { 720 } }
        return cachedWidth
    }
    fun getHeight(): Int {
        if (cachedHeight <= 0) { val parts = resolution.split("x"); cachedWidth = try { parts[0].toInt() } catch (e: Exception) { 1280 }; cachedHeight = try { parts[1].toInt() } catch (e: Exception) { 720 } }
        return cachedHeight
    }

    var fps: Int
        get() = prefs.getString("fps", "30")?.toInt() ?: 30
        set(value) = prefs.edit().putString("fps", value.toString()).apply()

    var language: String
        get() = prefs.getString("language", "auto") ?: "auto"
        set(value) = prefs.edit().putString("language", value).apply()

    var bitrate: Int
        get() = try {
            val v = prefs.getString("bitrate", "10")?.toInt() ?: 10
            // 兼容旧版本：旧版以bps存储(如10000000)，新版以Mbps存储(如10)
            if (v >= 1000) v / 1000 else v
        } catch (e: Exception) {
            // 回退到int类型读取（兼容旧格式）
            prefs.getInt("bitrate", 10)
        }
        set(value) = prefs.edit().putString("bitrate", value.toString()).apply()

    var gop: Int
        get() = try {
            val v = prefs.getString("gop", "30")?.toInt() ?: 30
            // 兼容旧版本：旧版以秒存储(如2表示2秒)，新版以帧数存储(1-120)
            // 旧版典型值: 2,3 等(秒)，新版典型值: 1,5,10,15,...,120
            // 若值<=10且不是5的倍数(即1除外)，视为旧版秒数，按30fps换算
            if (v in 2..10 && v != 5 && v != 10) v * 30 else v
        } catch (e: Exception) {
            prefs.getInt("gop", 30)
        }
        set(value) = prefs.edit().putString("gop", value.toString()).apply()

    var queueCapacity: Int
        get() = try {
            prefs.getString("queue_capacity", "5")?.toInt() ?: 5
        } catch (e: Exception) {
            prefs.getInt("queue_capacity", 5)
        }
        set(value) = prefs.edit().putString("queue_capacity", value.toString()).apply()

    var rtspPort: Int
        get() = try {
            prefs.getString("rtsp_port", "9527")?.toInt() ?: 9527
        } catch (e: Exception) {
            prefs.getInt("rtsp_port", 9527)
        }
        set(value) = prefs.edit().putString("rtsp_port", value.toString()).apply()

    var rtspPath: String
        get() = prefs.getString("rtsp_path", "/live") ?: "/live"
        set(value) = prefs.edit().putString("rtsp_path", value).apply()

    // 编码器类型: h264 / h265 (h265为不稳定实验特性，默认h264)
    var videoCodec: String
        get() = prefs.getString("video_codec", "h264") ?: "h264"
        set(value) = prefs.edit().putString("video_codec", value).apply()

    // 声音与渲染开关
    var audioEnabled: Boolean
        get() = prefs.getBoolean("audio_enabled", true)
        set(value) = prefs.edit().putBoolean("audio_enabled", value).apply()

    var previewEnabled: Boolean
        get() = prefs.getBoolean("preview_enabled", true)
        set(value) = prefs.edit().putBoolean("preview_enabled", value).apply()

    var perfMonitorEnabled: Boolean
        get() = prefs.getBoolean("perf_monitor_enabled", false)
        set(value) = prefs.edit().putBoolean("perf_monitor_enabled", value).apply()

    val useOIS: Boolean get() = prefs.getBoolean("use_ois", true)
    val useEIS: Boolean get() = prefs.getBoolean("use_eis", true)
    val useDistortionCorrection: Boolean get() = prefs.getBoolean("use_distortion", true)
    val edgeEnhancement: Int get() = try {
        prefs.getString("edge_mode", "1")?.toInt() ?: 1
    } catch(e: Exception) { 1 }

    companion object {
        @Volatile
        private var instance: SettingsManager? = null
        fun getInstance(context: Context): SettingsManager {
            return instance ?: synchronized(this) {
                instance ?: SettingsManager(context.applicationContext).also { instance = it }
            }
        }
    }
}
