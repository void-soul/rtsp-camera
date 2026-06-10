package com.gld.rtsp_camera

import android.net.TrafficStats
import android.os.SystemClock
import java.io.File

class PerformanceMonitor {
    private var lastTxBytes = 0L
    private var lastTimeMs = 0L

    private var lastAppCpuTime = 0L
    private var lastCpuTimeMs = 0L
    private val numCores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)

    fun getNetworkSpeed(): String {
        val nowMs = SystemClock.elapsedRealtime()
        val currentTxBytes = TrafficStats.getUidTxBytes(android.os.Process.myUid())
        if (currentTxBytes == TrafficStats.UNSUPPORTED.toLong()) return "NET: N/A"

        if (lastTimeMs == 0L) {
            lastTxBytes = currentTxBytes
            lastTimeMs = nowMs
            return "NET: 0.0 KB/s"
        }

        val timeDiffMs = nowMs - lastTimeMs
        val byteDiff = currentTxBytes - lastTxBytes

        lastTxBytes = currentTxBytes
        lastTimeMs = nowMs

        if (timeDiffMs <= 0 || byteDiff < 0) return "NET: 0.0 KB/s"

        val speedBytesPerSec = byteDiff * 1000.0 / timeDiffMs
        return if (speedBytesPerSec >= 1024 * 1024) {
            String.format(java.util.Locale.US, "NET: %.2f MB/s", speedBytesPerSec / (1024 * 1024))
        } else {
            String.format(java.util.Locale.US, "NET: %.1f KB/s", speedBytesPerSec / 1024)
        }
    }

    fun getAppCpuUsage(): String {
        val nowMs = SystemClock.elapsedRealtime()
        val appCpuTimeTicks = readAppCpuTimeTicks()
        if (appCpuTimeTicks < 0) return "CPU: 0.0%"

        if (lastCpuTimeMs == 0L) {
            lastAppCpuTime = appCpuTimeTicks
            lastCpuTimeMs = nowMs
            return "CPU: 0.0%"
        }

        val timeDiffMs = nowMs - lastCpuTimeMs
        val cpuDiffTicks = appCpuTimeTicks - lastAppCpuTime

        lastAppCpuTime = appCpuTimeTicks
        lastCpuTimeMs = nowMs

        if (timeDiffMs <= 0 || cpuDiffTicks < 0) return "CPU: 0.0%"

        // CPU time in ms = ticks * 10 (assuming 100Hz clock tick frequency)
        val cpuDiffMs = cpuDiffTicks * 10.0
        val percent = (cpuDiffMs / (timeDiffMs * numCores)) * 100.0
        val clampedPercent = percent.coerceIn(0.0, 100.0)
        return String.format(java.util.Locale.US, "CPU: %.1f%%", clampedPercent)
    }

    fun getMemoryUsage(): String {
        val rssMb = readProcessMemoryMb()
        return String.format(java.util.Locale.US, "MEM: %.1f MB", rssMb)
    }

    private fun readAppCpuTimeTicks(): Long {
        try {
            val statFile = File("/proc/self/stat")
            if (statFile.exists()) {
                val statStr = statFile.readText().trim()
                val lastParen = statStr.lastIndexOf(')')
                if (lastParen != -1 && lastParen + 2 < statStr.length) {
                    val sub = statStr.substring(lastParen + 2).trim()
                    val restParts = sub.split(Regex("\\s+"))
                    // restParts indices:
                    // 0: state (Field 3)
                    // 1: ppid (Field 4)
                    // ...
                    // 11: utime (Field 14)
                    // 12: stime (Field 15)
                    if (restParts.size >= 13) {
                        val utime = restParts[11].toLongOrNull() ?: 0L
                        val stime = restParts[12].toLongOrNull() ?: 0L
                        return utime + stime
                    }
                }
            }
        } catch (_: Exception) {}
        return -1L
    }

    private fun readProcessMemoryMb(): Double {
        try {
            val statusFile = File("/proc/self/status")
            if (statusFile.exists()) {
                val lines = statusFile.readLines()
                for (line in lines) {
                    if (line.startsWith("VmRSS:")) {
                        val parts = line.split(Regex("\\s+"))
                        if (parts.size >= 2) {
                            val rssKb = parts[1].toDoubleOrNull() ?: 0.0
                            return rssKb / 1024.0
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        // Fallback to Java VM memory
        val runtime = Runtime.getRuntime()
        return (runtime.totalMemory() - runtime.freeMemory()) / (1024.0 * 1024.0)
    }
}
