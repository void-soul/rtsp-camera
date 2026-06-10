package com.gld.rtsp_camera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log

class StreamService : Service() {
    companion object {
        private const val CHANNEL_ID = "rtsp_stream"
        private const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.gld.rtsp_camera.STOP"
        private var instance: StreamService? = null

        fun getWifiInfo(context: Context): String {
            return try {
                val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val info: WifiInfo? = wifiManager?.connectionInfo
                val ssid = info?.ssid?.replace("\"", "") ?: ""
                if (ssid.isBlank() || ssid == "<unknown ssid>") ""
                else {
                    val rssi = info?.rssi ?: 0
                    val bars = when { rssi >= -50 -> "●●●●"; rssi >= -65 -> "●●●○"; rssi >= -75 -> "●●○○"; else -> "●○○○" }
                    "$ssid $bars"
                }
            } catch (e: Exception) { "" }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification("", "", ""))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    fun updateNotification(url: String, clientIp: String, info: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(url, clientIp, info))
    }

    private fun buildNotification(url: String, clientIp: String, info: String): Notification {
        val stopIntent = Intent(this, StreamService::class.java).apply { action = ACTION_STOP }
        val stopPendingIntent = PendingIntent.getService(this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val launchIntent = Intent(this, MainActivity::class.java)
        val launchPendingIntent = PendingIntent.getActivity(this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val contentText = buildString {
            if (url.isNotBlank()) append(url)
            if (clientIp.isNotBlank()) append("  → $clientIp")
            if (info.isNotBlank()) append("\n$info")
        }

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("RTSP 推流中")
                .setContentText(contentText.ifBlank { "推流进行中" })
                .setContentIntent(launchPendingIntent)
                .addAction(android.R.drawable.ic_media_pause, "停止", stopPendingIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("RTSP 推流中")
                .setContentText(contentText.ifBlank { "推流进行中" })
                .setContentIntent(launchPendingIntent)
                .setOngoing(true)
                .build()
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "RTSP 推流", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "RTSP 推流状态" }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }
}
