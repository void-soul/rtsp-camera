package com.gld.rtsp_camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CaptureRequest
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private lateinit var settingsManager: SettingsManager
    private val videoProvider by lazy { H264FrameProvider() }
    private val audioProvider by lazy { AudioFrameProvider() }

    private lateinit var cameraManager: CameraManager
    private lateinit var streamManager: StreamManager
    private lateinit var uiController: UiController
    private lateinit var eventHandlers: MainEventHandlers

    private var currentLanguage: String? = null

    companion object {
        private const val STATE_CAMERA_SELECTOR = "camera_selector"
        private const val STATE_LANGUAGE = "current_language"
        private const val STATE_WB_MODE = "wb_mode"
        private const val STATE_EFFECT_MODE = "effect_mode"
        private const val STATE_IS_MANUAL_FOCUS = "is_manual_focus"
        private const val STATE_FOCUS_DIST = "focus_distance"
    }

    override fun attachBaseContext(newBase: Context) { super.attachBaseContext(Utils.applyLanguage(newBase)) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        settingsManager = SettingsManager.getInstance(this)
        currentLanguage = settingsManager.language
        videoProvider.setQueueCapacity(settingsManager.queueCapacity)

        cameraManager = CameraManager(this, settingsManager, findViewById(R.id.surfaceView), Executors.newSingleThreadExecutor())
        streamManager = StreamManager(this, settingsManager, videoProvider, audioProvider, cameraManager)
        cameraManager.streamManager = streamManager
        uiController = UiController(this, cameraManager, settingsManager)
        eventHandlers = MainEventHandlers(this, cameraManager, streamManager, uiController, settingsManager, videoProvider)

        if (savedInstanceState != null) {
            cameraManager.cameraSelector = if (savedInstanceState.getInt(STATE_CAMERA_SELECTOR, 0) == 0)
                androidx.camera.core.CameraSelector.DEFAULT_BACK_CAMERA
            else
                androidx.camera.core.CameraSelector.DEFAULT_FRONT_CAMERA
            currentLanguage = savedInstanceState.getString(STATE_LANGUAGE, currentLanguage)
            cameraManager.currentWbMode = savedInstanceState.getInt(STATE_WB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
            cameraManager.currentEffectMode = savedInstanceState.getInt(STATE_EFFECT_MODE, CaptureRequest.CONTROL_EFFECT_MODE_OFF)
            cameraManager.isManualFocus = savedInstanceState.getBoolean(STATE_IS_MANUAL_FOCUS, false)
            cameraManager.currentFocusDistance = savedInstanceState.getFloat(STATE_FOCUS_DIST, 0f)
        }

        initViews()
        eventHandlers.setupCallbacks()
        eventHandlers.setupListeners()
        uiController.setFullScreen()
        requestPermissions()
    }

    override fun onSaveInstanceState(out: Bundle) {
        super.onSaveInstanceState(out)
        out.putInt(STATE_CAMERA_SELECTOR, if (cameraManager.cameraSelector == androidx.camera.core.CameraSelector.DEFAULT_BACK_CAMERA) 0 else 1)
        out.putString(STATE_LANGUAGE, currentLanguage ?: settingsManager.language)
        out.putInt(STATE_WB_MODE, cameraManager.currentWbMode)
        out.putInt(STATE_EFFECT_MODE, cameraManager.currentEffectMode)
        out.putBoolean(STATE_IS_MANUAL_FOCUS, cameraManager.isManualFocus)
        out.putFloat(STATE_FOCUS_DIST, cameraManager.currentFocusDistance)
    }

    override fun onResume() {
        super.onResume()
        if (currentLanguage != settingsManager.language) {
            currentLanguage = settingsManager.language
        }
        uiController.refreshSettingsUI()
        uiController.updateRtspAddress()
        cameraManager.bindCameraUseCases()
        resetDimTimer()
        updatePerfMonitorPolling()
    }

    override fun onPause() {
        perfHandler.removeCallbacks(perfRunnable)
        super.onPause()
    }

    override fun onDestroy() {
        streamManager.stopAll()
        cameraManager.getCameraExecutor().shutdown()
        dimHandler.removeCallbacks(dimRunnable)
        perfHandler.removeCallbacks(perfRunnable)
        super.onDestroy()
    }

    private fun initViews() {
        uiController.apply {
            surfaceView = findViewById(R.id.surfaceView)
            layoutCenterStatus = findViewById(R.id.layoutCenterStatus)
            tvCenterUrl = findViewById(R.id.tvCenterUrl); tvCenterClient = findViewById(R.id.tvCenterClient)
            tvStreamUrl = findViewById(R.id.tvStreamUrl); tvClientIp = findViewById(R.id.tvClientIp)
            tvResolution = findViewById(R.id.tvResolution); tvBitrate = findViewById(R.id.tvBitrate)
            tvFps = findViewById(R.id.tvFps); tvGop = findViewById(R.id.tvGop)
            tvQueue = findViewById(R.id.tvQueue)
            tvCodec = findViewById(R.id.tvCodec)
            tvLanguage = findViewById(R.id.tvLanguage)
            tvZoomValue = findViewById(R.id.tvZoomValue); tvExpValue = findViewById(R.id.tvExpValue)
            tvFocusValue = findViewById(R.id.tvFocusValue)
            fabAction = findViewById(R.id.fabAction); btnSettings = findViewById(R.id.btnSettings); btnHelp = findViewById(R.id.btnHelp)
            btnFlip = findViewById(R.id.btnFlip); btnFlash = findViewById(R.id.btnFlash)
            btnAudio = findViewById(R.id.btnAudio); btnPreview = findViewById(R.id.btnPreview)
            tvWbValue = findViewById(R.id.tvWbValue); tvFilterValue = findViewById(R.id.tvFilterValue)
            layoutBottomControls = findViewById(R.id.layoutBottomControls)
            layoutTopControls = findViewById(R.id.layoutTopControls)
            rulerWheel = findViewById(R.id.rulerWheel)
            tvParamZoom = findViewById(R.id.tvParamZoom); tvParamExp = findViewById(R.id.tvParamExp)
            tvParamFocus = findViewById(R.id.tvParamFocus)
            tvStreamDuration = findViewById(R.id.tvStreamDuration)
            tvTransport = findViewById(R.id.tvTransport)
            tvWifi = findViewById(R.id.tvWifi)
            viewAlertBorder = findViewById(R.id.viewAlertBorder)
            btnPerfToggle = findViewById(R.id.btnPerfToggle)
            layoutPerfMonitor = findViewById(R.id.layoutPerfMonitor)
            tvPerfNetwork = findViewById(R.id.tvPerfNetwork)
            tvPerfCpu = findViewById(R.id.tvPerfCpu)
            tvPerfMemory = findViewById(R.id.tvPerfMemory)
            tvPerfAbrLoss = findViewById(R.id.tvPerfAbrLoss)
            tvPerfFpsQueue = findViewById(R.id.tvPerfFpsQueue)
            tvPerfFrames = findViewById(R.id.tvPerfFrames)
        }
        findViewById<View>(R.id.btnRtspUrlLayout).setOnClickListener { uiController.copyRtspAddress() }
        uiController.tvResolution.text = settingsManager.resolution
        uiController.updatePreviewState()
        uiController.updateRtspAddress()
        uiController.updateTogglesUI()
        uiController.updateCenterStatus()
    }

    private fun requestPermissions() {
        val p = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        if (p.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) cameraManager.startCameraX()
        else ActivityCompat.requestPermissions(this, p, 101)
    }

    override fun onRequestPermissionsResult(rc: Int, p: Array<out String>, gr: IntArray) {
        super.onRequestPermissionsResult(rc, p, gr)
        if (rc == 101 && gr.isNotEmpty() && gr[0] == PackageManager.PERMISSION_GRANTED) cameraManager.startCameraX()
    }

    // ==================== 屏幕节能暗屏模式 ====================
    private val dimHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var isScreenDimmed = false
    private val dimRunnable = Runnable {
        if (!settingsManager.previewEnabled && !uiController.isAlertActive()) {
            dimScreen()
        }
    }

    override fun dispatchTouchEvent(ev: android.view.MotionEvent?): Boolean {
        wakeUpScreen()
        return super.dispatchTouchEvent(ev)
    }

    fun wakeUpScreen() {
        if (isScreenDimmed) {
            val lp = window.attributes
            lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE // -1.0f
            window.attributes = lp
            isScreenDimmed = false
            Log.d("MainActivity", "Screen brightness restored")
        }
        resetDimTimer()
    }

    private fun dimScreen() {
        if (!isScreenDimmed) {
            val lp = window.attributes
            lp.screenBrightness = 0.01f
            window.attributes = lp
            isScreenDimmed = true
            Log.d("MainActivity", "Screen dimmed to save power")
        }
    }

    fun resetDimTimer() {
        dimHandler.removeCallbacks(dimRunnable)
        if (!settingsManager.previewEnabled) {
            dimHandler.postDelayed(dimRunnable, 10000L) // 10s
        }
    }

    // ==================== 性能监控轮询 ====================
    private var perfMonitor: PerformanceMonitor? = null
    private val perfHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val perfRunnable = object : Runnable {
        override fun run() {
            if (settingsManager.perfMonitorEnabled) {
                val monitor = perfMonitor ?: PerformanceMonitor().also { perfMonitor = it }
                val net = monitor.getNetworkSpeed()
                val cpu = monitor.getAppCpuUsage()
                val mem = monitor.getMemoryUsage()
                val isStreaming = streamManager.isStreaming()
                val sent = if (isStreaming) streamManager.getSentFrames() else 0L
                val dropped = if (isStreaming) streamManager.getDroppedFrames() else 0L
                val queueSize = if (isStreaming) streamManager.getQueueSize() else 0
                val queueCap = if (isStreaming) streamManager.getQueueCapacity() else 5
                val fps = if (isStreaming) streamManager.getPushFps() else 0.0
                val loss = if (isStreaming) streamManager.getLossPercent() else 0.0
                val (abr, target) = if (isStreaming) streamManager.getAbrBitrate() else Pair(0, 0)

                uiController.updatePerfData(
                    net, cpu, mem, isStreaming, sent, dropped, queueSize, queueCap, fps, loss, abr, target
                )
                perfHandler.postDelayed(this, 1000L) // 1s
            }
        }
    }

    fun updatePerfMonitorPolling() {
        perfHandler.removeCallbacks(perfRunnable)
        if (settingsManager.perfMonitorEnabled) {
            perfMonitor = PerformanceMonitor()
            perfHandler.post(perfRunnable)
        }
    }
}
