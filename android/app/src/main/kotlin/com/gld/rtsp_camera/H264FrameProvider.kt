package com.gld.rtsp_camera

import android.util.Log
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Holder for a frame buffer to allow zero-allocation passing.
 */
class NativeFrame(val buffer: ByteArray, var length: Int = 0, var presentationTimeUs: Long = 0)

class H264FrameProvider {
    private val tag = "H264FrameProvider"
    private val POOL_SIZE = 10
    private val framePool = LinkedBlockingQueue<NativeFrame>()

    @Volatile
    private var queueCapacity = 5

    @Volatile
    private var filledQueue = LinkedBlockingQueue<NativeFrame>(queueCapacity)

    @Synchronized
    fun setQueueCapacity(capacity: Int) {
        if (capacity == this.queueCapacity) return
        this.queueCapacity = capacity
        
        val oldQueue = filledQueue
        filledQueue = LinkedBlockingQueue<NativeFrame>(capacity)
        
        var frame = oldQueue.poll()
        while (frame != null) {
            recycleFrame(frame)
            frame = oldQueue.poll()
        }
        Log.d(tag, "Queue capacity updated to: $capacity")
        
        // Ensure pool has enough frames to avoid exhaustion
        val neededPoolSize = capacity + 10
        val currentPoolSize = framePool.size + filledQueue.size
        if (isPrepared && currentPoolSize < neededPoolSize) {
            val toAllocate = neededPoolSize - currentPoolSize
            Log.d(tag, "Expanding frame pool by $toAllocate frames to match new queue capacity")
            for (i in 0 until toAllocate) {
                framePool.offer(NativeFrame(ByteArray(2 * 1024 * 1024)))
            }
        }
    }

    @Volatile
    var totalDroppedFrames = 0L
        private set

    fun getFilledQueueSize(): Int = filledQueue.size
    fun getQueueCapacity(): Int = queueCapacity

    fun resetStats() {
        totalDroppedFrames = 0L
    }

    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var vps: ByteArray? = null
    private var isPrepared = false

    // Called when queue overflows to request a keyframe for recovery
    var keyframeRequester: (() -> Unit)? = null

    // Cooldown to prevent infinite I-frame request loop during startup
    private var lastKeyframeRequestTime = 0L

    /**
     * Lazy allocation of the buffer pool. 
     * This avoids allocating 20-40MB on app startup when not yet streaming.
     */
    @Synchronized
    fun prepare() {
        if (isPrepared) return
        val size = queueCapacity + 10
        Log.d(tag, "Allocating frame pool: $size frames")
        try {
            for (i in 0 until size) {
                framePool.offer(NativeFrame(ByteArray(2 * 1024 * 1024))) 
            }
            isPrepared = true
        } catch (e: OutOfMemoryError) {
            Log.e(tag, "Failed to allocate frame pool - OOM", e)
        }
    }

    /**
     * Get an empty frame from the pool to fill.
     */
    fun obtainEmptyFrame(): NativeFrame? {
        if (!isPrepared) prepare()
        return framePool.poll()
    }

    /**
     * Add a filled frame to the queue.
     */
    fun addFrame(frame: NativeFrame) {
        if (!filledQueue.offer(frame)) {
            // Queue full, drop oldest and recycle it
            val oldest = filledQueue.poll()
            if (oldest != null) {
                totalDroppedFrames++
                recycleFrame(oldest)
            }
            filledQueue.offer(frame)
            // Request keyframe so player can recover from the gap, but only once per second
            val now = System.currentTimeMillis()
            if (now - lastKeyframeRequestTime > 1000) {
                lastKeyframeRequestTime = now
                keyframeRequester?.invoke()
            }
        }
    }

    /**
     * Get a filled frame to send. Blocks if empty.
     */
    fun getFrameBlocking(timeoutMs: Long): NativeFrame? {
        return filledQueue.poll(timeoutMs, TimeUnit.MILLISECONDS)
    }

    /**
     * Return a frame to the pool for reuse.
     */
    fun recycleFrame(frame: NativeFrame) {
        frame.length = 0
        framePool.offer(frame)
    }

    /**
     * Drop all queued frames (e.g. on new PLAY to avoid sending stale data).
     */
    fun clearFilledQueue() {
        var frame = filledQueue.poll()
        while (frame != null) {
            recycleFrame(frame)
            frame = filledQueue.poll()
        }
        lastKeyframeRequestTime = 0L  // Reset cooldown on new session
        Log.d(tag, "Filled queue cleared")
    }

    @Synchronized
    fun clear() {
        clearFilledQueue()
        Log.d(tag, "Provider cleared")
    }

    fun setSPSPPS(data: ByteArray, length: Int) {
        Log.d(tag, "setSPSPPS: length=$length")
        var i = 0
        while (i < length - 2) {
            val startCodeSize = if (i < length - 3 && data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                4
            } else if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
                3
            } else {
                0
            }

            if (startCodeSize > 0) {
                val start = i + startCodeSize
                // Find next start code (3 or 4 byte)
                var end = length
                for (j in start until length - 2) {
                    if (data[j] == 0.toByte() && data[j + 1] == 0.toByte()) {
                        if ((j < length - 3 && data[j + 2] == 0.toByte() && data[j + 3] == 1.toByte()) ||
                            data[j + 2] == 1.toByte()) {
                            end = j
                            break
                        }
                    }
                }
                val nalData = data.copyOfRange(i, end)
                val rawByte = data[start].toInt() and 0xFF
                val h264Type = rawByte and 0x1F
                val h265Type = (rawByte shr 1) and 0x3F
                when {
                    h264Type == 7 -> sps = nalData
                    h264Type == 8 -> pps = nalData
                    h265Type == 32 -> vps = nalData
                    h265Type == 33 -> sps = nalData
                    h265Type == 34 -> pps = nalData
                }
                i = end
            } else {
                i++
            }
        }
    }

    fun getSPS(): ByteArray? = sps
    fun getPPS(): ByteArray? = pps
    fun getVPS(): ByteArray? = vps

    /**
     * 从 SPS 中提取 profile-level-id（3字节十六进制字符串）。
     * 格式: profile_idc(1B) + constraint_set_flags(1B) + level_idc(1B)
     */
    fun getProfileLevelId(): String? {
        val spsData = sps ?: return null
        var offset = 0
        if (spsData.size >= 4 && spsData[0] == 0.toByte() && spsData[1] == 0.toByte() &&
            spsData[2] == 0.toByte() && spsData[3] == 1.toByte()) {
            offset = 4
        } else if (spsData.size >= 3 && spsData[0] == 0.toByte() && spsData[1] == 0.toByte() &&
            spsData[2] == 1.toByte()) {
            offset = 3
        }
        if (spsData.size < offset + 4) return null
        // Skip NAL header byte at offset, read profile_idc / constraint_set_flags / level_idc
        return String.format("%02X%02X%02X",
            spsData[offset + 1].toInt() and 0xFF,
            spsData[offset + 2].toInt() and 0xFF,
            spsData[offset + 3].toInt() and 0xFF)
    }
}
