package com.gld.rtsp_camera

import android.animation.ValueAnimator
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.*
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.Camera
import kotlin.math.absoluteValue

class UiController(
    private val activity: AppCompatActivity,
    private val cameraManager: CameraManager,
    private val settingsManager: SettingsManager
) {
    private val uiHandler = Handler(Looper.getMainLooper())

    lateinit var surfaceView: SurfaceView
    lateinit var layoutCenterStatus: View
    lateinit var tvCenterUrl: TextView
    lateinit var tvCenterClient: TextView
    lateinit var tvStreamUrl: TextView
    lateinit var tvClientIp: TextView
    lateinit var tvResolution: TextView
    lateinit var tvBitrate: TextView
    lateinit var tvFps: TextView
    lateinit var tvGop: TextView
    lateinit var tvQueue: TextView
    lateinit var tvCodec: TextView
    lateinit var tvLanguage: TextView
    lateinit var tvZoomValue: TextView
    lateinit var tvExpValue: TextView
    lateinit var tvFocusValue: TextView
    lateinit var tvWbValue: TextView
    lateinit var tvFilterValue: TextView
    lateinit var fabAction: ImageButton
    lateinit var btnSettings: ImageButton
    lateinit var btnFlip: ImageButton
    lateinit var btnFlash: ImageButton
    lateinit var btnAudio: ImageButton
    lateinit var btnPreview: ImageButton
    lateinit var btnHelp: ImageButton
    lateinit var layoutBottomControls: View
    lateinit var layoutTopControls: View
    lateinit var rulerWheel: RulerWheelView
    lateinit var tvParamZoom: TextView
    lateinit var tvParamExp: TextView
    lateinit var tvParamFocus: TextView
    lateinit var tvStreamDuration: TextView
    lateinit var tvTransport: TextView
    lateinit var tvWifi: TextView
    lateinit var viewAlertBorder: View
    lateinit var btnPerfToggle: ImageButton
    lateinit var layoutPerfMonitor: View
    lateinit var tvPerfNetwork: TextView
    lateinit var tvPerfCpu: TextView
    lateinit var tvPerfMemory: TextView
    lateinit var tvPerfAbrLoss: TextView
    lateinit var tvPerfFpsQueue: TextView
    lateinit var tvPerfFrames: TextView

    var isTorchOn = false
    var isUiVisible = true
    private var activeDialType: String? = null
    private var streamStartTime = 0L

    var callback: Callback? = null

    interface Callback {
        fun onStartStreaming()
        fun onStopStreaming()
        fun onToggleCamera()
        fun onToggleFlash()
        fun onToggleAudio()
        fun onTogglePreview()
        fun onCopyRtspUrl()
        fun onNetworkSettingsChanged()
        fun onResolutionChanged()
        fun onFpsChanged(fps: Int)
        fun onWbOrFilterChanged()
        fun onFocusDialChanged(distance: Float)
        fun onResetAutoFocus()
        fun onCodecChanged(codec: String)
        fun getActiveCodec(): String
        fun isStreaming(): Boolean
        fun updateEncoderBitrate(mbps: Int)
        fun requestEncoderKeyFrame()
        fun onQueueCapacityChanged(capacity: Int)
    }

    // ==================== Status updater ====================

    private val statusUpdater = object : Runnable {
        override fun run() {
            if (callback?.isStreaming() == true) {
                tvWifi.text = StreamService.getWifiInfo(activity)
                val bitrateText = String.format(java.util.Locale.US, "%.1f Mbps", settingsManager.bitrate.toDouble())
                val fpsText = "${settingsManager.fps} FPS"
                val gopText = "K:${settingsManager.gop}"
                val codecText = callback?.getActiveCodec() ?: settingsManager.videoCodec.uppercase()
                val (w, h) = cameraManager.getActualVideoDimensions()
                val resText = "${w}x${h}"
                tvBitrate.text = bitrateText; tvFps.text = fpsText; tvGop.text = gopText
                tvCodec.text = codecText
                tvResolution.text = resText
                tvCenterUrl.text = tvStreamUrl.text; tvCenterClient.text = tvClientIp.text
                // Streaming duration
                val elapsed = (System.currentTimeMillis() - streamStartTime) / 1000
                val hrs = elapsed / 3600; val mins = (elapsed % 3600) / 60; val secs = elapsed % 60
                tvStreamDuration.text = if (hrs > 0) String.format("%d:%02d:%02d", hrs, mins, secs) else String.format("%02d:%02d", mins, secs)
            }
            if (!settingsManager.previewEnabled) {
                tvCenterUrl.text = tvStreamUrl.text; tvCenterClient.text = tvClientIp.text
            }
            if (callback?.isStreaming() == true) { uiHandler.postDelayed(this, 1000) }
        }
    }

    fun startStatusUpdater() {
        streamStartTime = System.currentTimeMillis()
        tvStreamDuration.text = "00:00"
        tvStreamDuration.visibility = View.VISIBLE
        uiHandler.post(statusUpdater)
    }

    fun stopStatusUpdater() {
        uiHandler.removeCallbacks(statusUpdater)
        tvStreamDuration.visibility = View.GONE
    }

    // ==================== Popup menus ====================

    fun showLanguagePopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val items = mapOf("A" to "auto", "中" to "zh", "EN" to "en")
        items.forEach { popup.menu.add(it.key) }
        popup.setOnMenuItemClickListener { settingsManager.language = items[it.title]!!; uiHandler.post { activity.recreate() }; true }
        popup.show()
    }

    fun showWbPopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val modes = linkedMapOf(
            activity.getString(R.string.wb_auto)           to CaptureRequest.CONTROL_AWB_MODE_AUTO,
            activity.getString(R.string.wb_incandescent)    to CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT,
            activity.getString(R.string.wb_fluorescent)     to CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT,
            activity.getString(R.string.wb_day)             to CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT,
            activity.getString(R.string.wb_cloudy)          to CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
        )
        val caps = cameraManager.getCameraCaps()
        modes.forEach { (name, value) ->
            val item = popup.menu.add(name)
            if (caps != null && !caps.supportedWb.contains(value)) {
                item.isEnabled = false
            }
        }
        popup.setOnMenuItemClickListener {
            cameraManager.currentWbMode = modes[it.title]!!; tvWbValue.text = it.title
            callback?.onWbOrFilterChanged(); true
        }
        popup.show()
    }

    fun showFilterPopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val effects = linkedMapOf(
            activity.getString(R.string.filter_none)  to CaptureRequest.CONTROL_EFFECT_MODE_OFF,
            activity.getString(R.string.filter_bw)    to CaptureRequest.CONTROL_EFFECT_MODE_MONO,
            activity.getString(R.string.filter_vivid) to CaptureRequest.CONTROL_EFFECT_MODE_AQUA,
            activity.getString(R.string.filter_warm)  to CaptureRequest.CONTROL_EFFECT_MODE_SEPIA,
            activity.getString(R.string.filter_cool)  to CaptureRequest.CONTROL_EFFECT_MODE_NEGATIVE
        )
        val caps = cameraManager.getCameraCaps()
        effects.forEach { (name, value) ->
            val item = popup.menu.add(name)
            if (caps != null && !caps.supportedEffects.contains(value)) {
                item.isEnabled = false
            }
        }
        popup.setOnMenuItemClickListener {
            cameraManager.currentEffectMode = effects[it.title]!!; tvFilterValue.text = it.title
            callback?.onWbOrFilterChanged(); true
        }
        popup.show()
    }

    fun showResolutionPopup(anchor: View) {
        val entries = activity.resources.getStringArray(R.array.resolution_entries)
        val popup = PopupMenu(activity, anchor)
        entries.forEach { popup.menu.add(it) }
        popup.setOnMenuItemClickListener {
            val title = it.title ?: ""
            val res = Regex("(\\d+x\\d+)").find(title)?.value ?: title.toString()
            settingsManager.resolution = res; tvResolution.text = res
            cameraManager.resetActualVideoDimensions()
            callback?.onResolutionChanged(); true
        }
        popup.show()
    }

    fun showBitratePopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        for (v in 5..60 step 5) { popup.menu.add("${v} Mbps") }
        popup.setOnMenuItemClickListener { item ->
            val v = item.title.toString().replace(" Mbps", "").toIntOrNull()
            if (v == null || v !in 5..60) return@setOnMenuItemClickListener false
            settingsManager.bitrate = v; tvBitrate.text = "$v Mbps"
            if (callback?.isStreaming() == true) {
                callback?.updateEncoderBitrate(v)
            }
            true
        }
        popup.show()
    }

    fun showFpsPopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val candidateFps = listOf(10, 15, 20, 24, 25, 30, 50, 60, 120)
        val caps = cameraManager.getCameraCaps()
        candidateFps.forEach { fps ->
            val item = popup.menu.add("$fps FPS")
            if (caps != null) {
                val isSupported = caps.supportedFps.any { Math.abs(it - fps) <= 2 }
                if (!isSupported) {
                    item.isEnabled = false
                }
            }
        }
        popup.setOnMenuItemClickListener { item ->
            val v = item.title.toString().replace(" FPS", "").toIntOrNull()
            if (v == null || v !in 10..120) return@setOnMenuItemClickListener false
            settingsManager.fps = v; tvFps.text = "$v FPS"
            if (callback?.isStreaming() == true) {
                callback?.onFpsChanged(v)
            }
            true
        }
        popup.show()
    }

    fun showGopPopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        popup.menu.add("1")
        for (v in 5..120 step 5) { popup.menu.add("$v") }
        popup.setOnMenuItemClickListener { item ->
            val v = item.title.toString().toIntOrNull()
            if (v == null || v !in 1..120) return@setOnMenuItemClickListener false
            settingsManager.gop = v; tvGop.text = "K:$v"
            if (callback?.isStreaming() == true) {
                callback?.requestEncoderKeyFrame()
            }
            true
        }
        popup.show()
    }

    fun showCodecPopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val codecs = listOf("H.264", "H.265 (HEVC)")
        codecs.forEach { popup.menu.add(it) }
        popup.setOnMenuItemClickListener { item ->
            val codecStr = if (item.title == "H.265 (HEVC)") "h265" else "h264"
            settingsManager.videoCodec = codecStr
            tvCodec.text = codecStr.uppercase()
            callback?.onCodecChanged(codecStr)
            true
        }
        popup.show()
    }

    fun showQueuePopup(anchor: View) {
        val popup = PopupMenu(activity, anchor)
        val list = listOf(2, 3, 5, 8, 10, 15, 20, 25, 30)
        list.forEach { popup.menu.add("$it") }
        popup.setOnMenuItemClickListener { item ->
            val v = item.title.toString().toIntOrNull()
            if (v == null || v !in 2..30) return@setOnMenuItemClickListener false
            settingsManager.queueCapacity = v; tvQueue.text = "Q:$v"
            callback?.onQueueCapacityChanged(v)
            true
        }
        popup.show()
    }

    fun showNetworkDialog() {
        val dp = activity.resources.displayMetrics.density
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((24 * dp).toInt(), (16 * dp).toInt(), (24 * dp).toInt(), (8 * dp).toInt())
        }

        // Port
        TextView(activity).apply {
            text = activity.getString(R.string.pref_port_title)
            setTextColor(Color.parseColor("#88FFFFFF"))
            textSize = 12f
        }.also { container.addView(it) }
        val portInput = EditText(activity).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            setText(settingsManager.rtspPort.toString())
            setTextColor(Color.WHITE)
            setPadding(0, (4 * dp).toInt(), 0, (8 * dp).toInt())
        }.also { container.addView(it) }

        // Path
        TextView(activity).apply {
            text = activity.getString(R.string.pref_path_title)
            setTextColor(Color.parseColor("#88FFFFFF"))
            textSize = 12f
            setPadding(0, (8 * dp).toInt(), 0, 0)
        }.also { container.addView(it) }
        val pathInput = EditText(activity).apply {
            setText(settingsManager.rtspPath)
            setTextColor(Color.WHITE)
            setPadding(0, (4 * dp).toInt(), 0, (8 * dp).toInt())
        }.also { container.addView(it) }

        AlertDialog.Builder(activity)
            .setTitle(activity.getString(R.string.pref_net_title))
            .setView(container)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val p = portInput.text.toString().toIntOrNull()
                if (p != null && p in 1..65535) settingsManager.rtspPort = p
                val path = pathInput.text.toString().trim()
                if (path.startsWith("/")) settingsManager.rtspPath = path
                updateRtspAddress()
                callback?.onNetworkSettingsChanged()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ==================== Dial control ====================

    fun activateDial(type: String) {
        if (activeDialType == type) { deactivateDial(); return }
        deactivateDial()

        activeDialType = type
        val activeColor = Color.parseColor("#FFD700")
        when (type) {
            "zoom"  -> tvParamZoom.setTextColor(activeColor)
            "ev"    -> tvParamExp.setTextColor(activeColor)
            "focus" -> tvParamFocus.setTextColor(activeColor)
        }

        data class DialData(val labels: List<String>, val realValues: List<Float>, val initIdx: Int)
        val cam = cameraManager.getCamera()
        val data: DialData? = when (type) {
            "zoom" -> {
                val state = cam?.cameraInfo?.zoomState?.value ?: run { deactivateDial(); return }
                val list = mutableListOf<Float>()
                var v = state.minZoomRatio
                while (v <= state.maxZoomRatio + 0.001f) { list.add(v); v += 0.05f }
                val idx = list.indexOfFirst { (it - state.zoomRatio).absoluteValue < 0.03f }.coerceIn(0, list.size - 1)
                DialData(list.map { "%.2fx".format(it) }, list, idx)
            }
            "ev" -> {
                val evState = cam?.cameraInfo?.exposureState ?: run { deactivateDial(); return }
                val r = evState.exposureCompensationRange
                if (r.lower >= r.upper) { deactivateDial(); return }
                val curIdx = evState.exposureCompensationIndex?.let { it - r.lower } ?: 0
                val labels = (r.lower..r.upper).map { if (it > 0) "+$it" else "$it" }
                val vals = (r.lower..r.upper).map { it.toFloat() }
                DialData(labels, vals, curIdx.coerceIn(0, vals.size - 1))
            }
            "focus" -> {
                val list = mutableListOf<Float>(); var v = 0.25f
                while (v <= 10f) { list.add(v); v += 0.05f }
                val cur = if (cameraManager.currentFocusDistance > 0) cameraManager.currentFocusDistance else 3.0f
                val idx = list.indexOfFirst { (it - cur).absoluteValue < 0.03f }.coerceIn(0, list.size - 1)
                DialData(list.map { "%.2fm".format(it) }, list, idx)
            }
            else -> null
        } ?: run { deactivateDial(); return }

        val d = data!!
        rulerWheel.visibility = View.VISIBLE
        rulerWheel.setData(d.labels, d.initIdx)
        rulerWheel.onItemSelectedListener = { index, label ->
            if (index in d.realValues.indices) {
                val realVal = d.realValues[index]
                when (type) {
                "zoom" -> try { cam?.cameraControl?.setZoomRatio(realVal); tvZoomValue.text = String.format("%.2fx", realVal) } catch (_: Exception) {}
                "ev"   -> try { cam?.cameraControl?.setExposureCompensationIndex(realVal.toInt()); tvExpValue.text = "${if (realVal > 0) "+" else ""}${realVal.toInt()}" } catch (_: Exception) {}
                "focus" -> { cameraManager.currentFocusDistance = realVal; cameraManager.isManualFocus = true; tvFocusValue.text = "MF ${String.format("%.1f", realVal)}"; callback?.onFocusDialChanged(realVal) }
            }
            }
        }
    }

    fun deactivateDial() {
        activeDialType = null; rulerWheel.visibility = View.GONE
        tvParamZoom.setTextColor(Color.WHITE); tvParamExp.setTextColor(Color.WHITE); tvParamFocus.setTextColor(Color.WHITE)
    }

    // ==================== Help dialog ====================

    fun showHelpDialog() {
        val isZh = settingsManager.language == "zh" || (settingsManager.language == "auto" && java.util.Locale.getDefault().language == "zh")

        data class HelpItem(val iconRes: Int, val title: String, val desc: String)

        val items = if (isZh) listOf(
            HelpItem(android.R.drawable.ic_menu_crop, "分辨率", "视频画面尺寸。仅支持设备硬件支持的分辨率，不同摄像头支持的分辨率可能不同。"),
            HelpItem(android.R.drawable.ic_menu_crop, "码率", "视频压缩码率(Mbps)。越高画质越好，但带宽占用越大。"),
            HelpItem(android.R.drawable.ic_media_play, "帧率(FPS)", "每秒编码帧数。越高越流畅，但发热和带宽增加。"),
            HelpItem(android.R.drawable.ic_menu_agenda, "K(关键帧间隔)", "每隔多少帧产生一个关键帧(I帧)。建议设为帧率的整数倍(如帧率30则K选30/60)，值越小延迟越低但码率增加。"),
            HelpItem(android.R.drawable.ic_menu_agenda, "Q(帧队列容量)", "发送前暂存的视频帧数。较小值(2-3)延迟最低但易因网络抖动丢包卡顿；较大值(15-30)更平滑但积压延迟。建议网络好设小，网络差调大。"),
            HelpItem(R.drawable.ic_network, "网络设置", "配置RTSP端口和路径。"),
            HelpItem(R.drawable.ic_network, "UDP/TCP 传输", "UDP 适合实时低延迟，丢包仅产生瞬间花屏；若被 PC 防火墙拦截会降级为 TCP，网络拥塞时会导致画面卡住并累积高延迟。"),
            HelpItem(android.R.drawable.ic_menu_view, "预览渲染", "开关预览画面，关闭可降低发热。"),
            HelpItem(android.R.drawable.ic_btn_speak_now, "音频", "开关麦克风声音推送。"),
            HelpItem(R.drawable.ic_flash_off, "闪光灯", "开关手电筒/闪光灯。"),
            HelpItem(android.R.drawable.ic_menu_rotate, "摄像头切换", "切换前置/后置摄像头。推流中不可切换。"),
            HelpItem(android.R.drawable.ic_menu_sort_by_size, "变焦/曝光/对焦", "通过底部拨轮调节。不同镜头支持程度不同。"),
            HelpItem(android.R.drawable.ic_menu_sort_by_size, "白平衡/滤镜", "通过底部按钮选择。不同镜头支持程度不同。"),
            HelpItem(android.R.drawable.ic_menu_preferences, "语言", "切换界面语言(中文/English/自动)。"),
        ) else listOf(
            HelpItem(android.R.drawable.ic_menu_crop, "Resolution", "Video size. Only hardware-supported resolutions are available; support varies by camera."),
            HelpItem(android.R.drawable.ic_menu_crop, "Bitrate", "Compression rate (Mbps). Higher = better quality but more bandwidth."),
            HelpItem(android.R.drawable.ic_media_play, "FPS", "Frames per second. Higher = smoother but more heat & bandwidth."),
            HelpItem(android.R.drawable.ic_menu_agenda, "K (Keyframe Interval)", "Frames between I-frames. Preferably equal to FPS or a multiple of FPS (e.g. FPS=30 -> K=30/60). Lower = less latency but higher bitrate."),
            HelpItem(android.R.drawable.ic_menu_agenda, "Q (Queue Capacity)", "Number of frames cached before sending. Smaller (2-3) = lowest latency but prone to stutters; larger (15-30) = smoother but aggregates latency under packet loss."),
            HelpItem(R.drawable.ic_network, "Network", "Configure RTSP port & path."),
            HelpItem(R.drawable.ic_network, "UDP/TCP Transport", "UDP is ideal for real-time video (drops cause brief glitches but no lag); TCP is used if UDP is blocked by firewall, accumulating latency under network congestion."),
            HelpItem(android.R.drawable.ic_menu_view, "Preview", "Toggle preview rendering. Disable to reduce heat."),
            HelpItem(android.R.drawable.ic_btn_speak_now, "Audio", "Toggle microphone streaming."),
            HelpItem(R.drawable.ic_flash_off, "Flash", "Toggle flashlight / torch."),
            HelpItem(android.R.drawable.ic_menu_rotate, "Camera Switch", "Switch front/rear camera. Not available during streaming."),
            HelpItem(android.R.drawable.ic_menu_sort_by_size, "Zoom/EV/Focus", "Adjust via bottom dial. Support varies by camera."),
            HelpItem(android.R.drawable.ic_menu_sort_by_size, "WB/Filter", "Select via bottom buttons. Support varies by camera."),
            HelpItem(android.R.drawable.ic_menu_preferences, "Language", "Switch interface language (中文/English/Auto)."),
        )

        val note = if (isZh)
            "\n⚠ 提示：并非所有镜头都支持全部选项和分辨率，不可用的选项会自动隐藏或禁用。推流中仅摄像头切换、网络设置不可更改，分辨率、码率、帧率、K 等参数均可实时调整生效。"
        else
            "\n⚠ Note: Not all cameras support every option or resolution. Unsupported options are automatically hidden or disabled. Camera switch and network settings cannot be changed during streaming, but resolution, bitrate, FPS, and K can be adjusted dynamically."

        val adapter = object : android.widget.BaseAdapter() {
            override fun getCount() = items.size
            override fun getItem(pos: Int) = items[pos]
            override fun getItemId(pos: Int) = pos.toLong()
            override fun getView(pos: Int, convertView: View?, parent: android.view.ViewGroup?): View {
                val item = items[pos]
                val row = LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, 12, 0, 12)
                    gravity = Gravity.CENTER_VERTICAL
                }
                ImageView(activity).apply {
                    setImageResource(item.iconRes)
                    val sz = (24 * activity.resources.displayMetrics.density).toInt()
                    layoutParams = LinearLayout.LayoutParams(sz, sz)
                    setColorFilter(Color.WHITE)
                }.also { row.addView(it) }
                TextView(activity).apply {
                    text = "${item.title} — ${item.desc}"
                    setTextColor(Color.WHITE)
                    textSize = 12f
                    setPadding((10 * activity.resources.displayMetrics.density).toInt(), 0, 0, 0)
                }.also { row.addView(it) }
                return row
            }
        }

        val listView = ListView(activity).apply {
            this.adapter = adapter
            choiceMode = ListView.CHOICE_MODE_NONE
            setPadding(24, 0, 24, 0)
            dividerHeight = 0
        }

        val noteView = TextView(activity).apply {
            text = note
            setTextColor(Color.parseColor("#FFD700"))
            textSize = 11f
            setPadding(36, 16, 36, 24)
        }

        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#222222"))
            addView(listView)
            addView(noteView)
        }

        AlertDialog.Builder(activity)
            .setTitle(if (isZh) "参数说明" else "Parameter Help")
            .setView(container)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    // ==================== UI state ====================

    fun refreshSettingsUI() {
        val (w, h) = cameraManager.getActualVideoDimensions()
        tvResolution.text = if (callback?.isStreaming() == true) "${w}x${h}" else settingsManager.resolution
        tvBitrate.text = String.format(java.util.Locale.US, "%.1f Mbps", settingsManager.bitrate.toDouble())
        tvFps.text = "${settingsManager.fps} FPS"
        tvGop.text = "K:${settingsManager.gop}"
        tvQueue.text = "Q:${settingsManager.queueCapacity}"
        tvCodec.text = callback?.getActiveCodec() ?: settingsManager.videoCodec.uppercase()
        updateLanguageLabel(); updatePreviewState(); updateTogglesUI(); applyCapabilityUI()
    }

    fun updateLanguageLabel() {
        tvLanguage.text = when (settingsManager.language) { "zh" -> "中"; "en" -> "EN"; else -> "A" }
    }

    fun applyCapabilityUI() {
        val caps = cameraManager.getCameraCaps() ?: return
        btnFlash.alpha = if (caps.hasFlash) 1.0f else 0.3f
        btnFlash.isEnabled = caps.hasFlash
        if (!caps.hasFlash && isTorchOn) { isTorchOn = false; updateTogglesUI() }

        // EV Button
        val evLayout = activity.findViewById<View>(R.id.btnParamExpLayout)
        if (evLayout != null) {
            val supportsEv = caps.minEv < caps.maxEv
            evLayout.alpha = if (supportsEv) 1.0f else 0.35f
            evLayout.isEnabled = supportsEv
        }

        // Zoom Button
        val zoomLayout = activity.findViewById<View>(R.id.btnParamZoomLayout)
        if (zoomLayout != null) {
            val supportsZoom = caps.minZoom < caps.maxZoom
            zoomLayout.alpha = if (supportsZoom) 1.0f else 0.35f
            zoomLayout.isEnabled = supportsZoom
        }

        // Focus Button
        val focusLayout = activity.findViewById<View>(R.id.btnParamFocusLayout)
        if (focusLayout != null) {
            focusLayout.alpha = if (caps.supportsManualFocus) 1.0f else 0.35f
            focusLayout.isEnabled = caps.supportsManualFocus
        }

        // Validate and downgrade setting selections based on new camera capabilities
        val currentFps = settingsManager.fps
        val isFpsSupported = caps.supportedFps.any { Math.abs(it - currentFps) <= 2 }
        if (!isFpsSupported) {
            val fallbackFps = if (caps.supportedFps.contains(30)) 30 else if (caps.supportedFps.isNotEmpty()) caps.supportedFps.first() else 30
            settingsManager.fps = fallbackFps
            tvFps.text = "$fallbackFps FPS"
            callback?.onFpsChanged(fallbackFps)
            Log.d("UiController", "FPS $currentFps not supported on this camera, auto adjusted to $fallbackFps")
        }

        if (!caps.supportedWb.contains(cameraManager.currentWbMode)) {
            cameraManager.currentWbMode = CaptureRequest.CONTROL_AWB_MODE_AUTO
            tvWbValue.text = activity.getString(R.string.wb_auto)
            callback?.onWbOrFilterChanged()
            Log.d("UiController", "AWB mode not supported on this camera, auto adjusted to AUTO")
        }

        if (!caps.supportedEffects.contains(cameraManager.currentEffectMode)) {
            cameraManager.currentEffectMode = CaptureRequest.CONTROL_EFFECT_MODE_OFF
            tvFilterValue.text = activity.getString(R.string.filter_none)
            callback?.onWbOrFilterChanged()
            Log.d("UiController", "Filter mode not supported on this camera, auto adjusted to NONE")
        }

        if (cameraManager.isManualFocus && !caps.supportsManualFocus) {
            callback?.onResetAutoFocus()
            Log.d("UiController", "Manual focus not supported on this camera, auto reset to AF")
        }
    }

    fun updateCenterStatus() {
        tvCenterUrl.text = tvStreamUrl.text; tvCenterClient.text = tvClientIp.text
    }

    fun updatePreviewState() {
        surfaceView.visibility = if (settingsManager.previewEnabled) View.VISIBLE else View.GONE
        layoutCenterStatus.visibility = if (!settingsManager.previewEnabled) View.VISIBLE else View.GONE
    }

    fun updateTogglesUI() {
        val activeColor = Color.parseColor("#FFD700"); val inactiveColor = Color.WHITE
        val disabledAlpha = 0.35f
        btnAudio.setColorFilter(if (settingsManager.audioEnabled) activeColor else inactiveColor)
        btnPreview.setColorFilter(if (settingsManager.previewEnabled) activeColor else inactiveColor)
        btnFlash.setImageResource(if (isTorchOn) R.drawable.ic_flash_on else R.drawable.ic_flash_off)
        btnFlash.setColorFilter(if (isTorchOn) activeColor else inactiveColor)
        val isStreaming = callback?.isStreaming() == true
        btnSettings.alpha = if (isStreaming) disabledAlpha else 1f
        btnSettings.isEnabled = !isStreaming
        btnFlip.alpha = if (isStreaming) disabledAlpha else 1f
        btnFlip.isEnabled = !isStreaming
        tvLanguage.alpha = if (isStreaming) disabledAlpha else 1f
        tvLanguage.isEnabled = !isStreaming
        tvCodec.alpha = if (isStreaming) disabledAlpha else 1f
        tvCodec.isEnabled = !isStreaming
        tvResolution.alpha = if (isStreaming) disabledAlpha else 1f
        tvResolution.isEnabled = !isStreaming
        tvBitrate.alpha = 1f
        tvFps.alpha = 1f
        tvGop.alpha = 1f
        tvWbValue.setTextColor(if (cameraManager.currentWbMode != CaptureRequest.CONTROL_AWB_MODE_AUTO) activeColor else Color.parseColor("#FFD700"))
        tvFilterValue.setTextColor(if (cameraManager.currentEffectMode != CaptureRequest.CONTROL_EFFECT_MODE_OFF) activeColor else Color.parseColor("#FFD700"))
        updatePerfMonitorUI()
    }

    fun togglePerfMonitor() {
        settingsManager.perfMonitorEnabled = !settingsManager.perfMonitorEnabled
        updatePerfMonitorUI()
        (activity as? MainActivity)?.updatePerfMonitorPolling()
    }

    fun updatePerfMonitorUI() {
        if (::layoutPerfMonitor.isInitialized && ::btnPerfToggle.isInitialized) {
            val enabled = settingsManager.perfMonitorEnabled
            layoutPerfMonitor.visibility = if (enabled) View.VISIBLE else View.GONE
            val activeColor = Color.parseColor("#FFD700")
            val inactiveColor = Color.WHITE
            btnPerfToggle.setColorFilter(if (enabled) activeColor else inactiveColor)
        }
    }

    fun updatePerfData(
        net: String, cpu: String, mem: String,
        isStreaming: Boolean,
        sent: Long = 0, dropped: Long = 0,
        queueSize: Int = 0, queueCap: Int = 5,
        fps: Double = 0.0, loss: Double = 0.0,
        abr: Int = 0, targetAbr: Int = 0
    ) {
        if (::tvPerfNetwork.isInitialized && ::tvPerfCpu.isInitialized && ::tvPerfMemory.isInitialized) {
            tvPerfNetwork.text = net
            tvPerfCpu.text = cpu
            tvPerfMemory.text = mem
        }

        if (::tvPerfAbrLoss.isInitialized && ::tvPerfFpsQueue.isInitialized && ::tvPerfFrames.isInitialized) {
            if (isStreaming) {
                tvPerfAbrLoss.visibility = View.VISIBLE
                tvPerfFpsQueue.visibility = View.VISIBLE
                tvPerfFrames.visibility = View.VISIBLE

                tvPerfAbrLoss.text = String.format(java.util.Locale.US, "ABR: %d/%d Mbps | Loss: %.1f%%", abr, targetAbr, loss)
                tvPerfFpsQueue.text = String.format(java.util.Locale.US, "FPS: %.1f/%d | Buf: %d/%d", fps, settingsManager.fps, queueSize, queueCap)
                
                val total = sent + dropped
                val dropRate = if (total > 0) (dropped.toDouble() / total * 100) else 0.0
                tvPerfFrames.text = String.format(java.util.Locale.US, "Sent: %d | Drop: %d (%.1f%%)", sent, dropped, dropRate)
            } else {
                tvPerfAbrLoss.visibility = View.GONE
                tvPerfFpsQueue.visibility = View.GONE
                tvPerfFrames.visibility = View.GONE
            }
        }
    }

    fun updateRtspAddress() {
        tvStreamUrl.text = "rtsp://${com.gld.rtsp_camera.Utils.getIPAddress(activity)}:${settingsManager.rtspPort}${settingsManager.rtspPath}"
    }

    fun updateTransportLabel(transport: String) {
        if (::tvTransport.isInitialized) tvTransport.text = transport
    }

    fun copyRtspAddress() {
        val url = tvStreamUrl.text.toString()
        if (url.isBlank()) return
        val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("RTSP URL", url))
        Toast.makeText(activity, activity.getString(R.string.pref_net_title) + " copied", Toast.LENGTH_SHORT).show()
    }

    // ==================== Alert border animation ====================

    private var alertBorderAnimator: ValueAnimator? = null

    fun isAlertActive(): Boolean {
        return alertBorderAnimator?.isRunning == true
    }

    /**
     * 启动红色边框闪烁报警（客户端断开时调用）。
     * 已运行时重复调用不会产生多个动画。
     */
    fun startAlertBorder() {
        if (alertBorderAnimator?.isRunning == true) return
        (activity as? MainActivity)?.wakeUpScreen()
        val view = viewAlertBorder
        view.visibility = View.VISIBLE
        view.alpha = 1f

        alertBorderAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 800
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener { anim ->
                val fraction = anim.animatedFraction
                // Fast pulse: sharp flash, slow fade
                val alpha = if (fraction < 0.3f) {
                    1f - fraction / 0.3f * 0.6f  // 1.0 → 0.4 quick fade
                } else {
                    0.4f + (fraction - 0.3f) / 0.7f * 0.6f  // 0.4 → 1.0 slow rise
                }
                view.alpha = alpha
            }
        }.also { it.start() }
    }

    /**
     * 停止红色边框闪烁报警（客户端重连时调用）。
     */
    fun stopAlertBorder() {
        alertBorderAnimator?.cancel()
        alertBorderAnimator = null
        viewAlertBorder.alpha = 1f
        viewAlertBorder.visibility = View.GONE
        (activity as? MainActivity)?.resetDimTimer()
    }

    fun updateFab(streaming: Boolean) {
        fabAction.setImageResource(if (streaming) android.R.drawable.ic_menu_close_clear_cancel else android.R.drawable.ic_media_play)
        btnSettings.isEnabled = !streaming; btnFlip.isEnabled = !streaming
        tvResolution.isEnabled = !streaming; tvBitrate.isEnabled = true; tvFps.isEnabled = true; tvGop.isEnabled = true
        updateTogglesUI()
    }

    fun toggleUI() {
        isUiVisible = !isUiVisible
        val v = if (isUiVisible) View.VISIBLE else View.GONE
        layoutBottomControls.visibility = v; layoutTopControls.visibility = v; fabAction.visibility = v
        if (!settingsManager.previewEnabled) layoutCenterStatus.visibility = View.VISIBLE
        else layoutCenterStatus.visibility = View.GONE
        if (!isUiVisible && activeDialType == null) rulerWheel.visibility = View.GONE
    }

    fun setFullScreen() {
        androidx.core.view.WindowCompat.setDecorFitsSystemWindows(activity.window, false)
        val controller = androidx.core.view.WindowInsetsControllerCompat(activity.window, activity.window.decorView)
        controller.hide(androidx.core.view.WindowInsetsCompat.Type.statusBars() or androidx.core.view.WindowInsetsCompat.Type.navigationBars())
        controller.systemBarsBehavior = androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P)
            activity.window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
    }
}
