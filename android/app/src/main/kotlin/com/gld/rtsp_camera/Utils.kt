package com.gld.rtsp_camera

import android.content.Context
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Locale

object Utils {
    fun getIPAddress(context: Context): String {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val intf = interfaces.nextElement()
                val addrs = intf.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (!addr.isLoopbackAddress && addr is InetAddress) {
                        val sAddr = addr.getHostAddress()
                        val isIPv4 = sAddr.indexOf(':') < 0
                        if (isIPv4) return sAddr
                    }
                }
            }
        } catch (ex: Exception) { }
        return "127.0.0.1"
    }

    /**
     * 根据用户语言设置创建对应的 Context，供 attachBaseContext 使用。
     * 提取自 MainActivity/SettingsActivity 中重复的语言切换逻辑。
     */
    fun applyLanguage(newBase: Context): Context {
        val sm = SettingsManager.getInstance(newBase)
        val lang = sm.language
        return if (lang != "auto") {
            val locale = Locale(lang)
            Locale.setDefault(locale)
            val config = newBase.resources.configuration
            config.setLocale(locale)
            newBase.createConfigurationContext(config)
        } else {
            newBase
        }
    }
}
