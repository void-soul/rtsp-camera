package com.gld.rtsp_camera

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class AudioFrameProvider {
    private val framePool = LinkedBlockingQueue<NativeFrame>()
    private val filledQueue = LinkedBlockingQueue<NativeFrame>(100)
    
    init {
        // Audio frames are small, we can pre-allocate more
        for (i in 0 until 50) {
            framePool.offer(NativeFrame(ByteArray(4096)))
        }
    }

    fun obtainEmptyFrame(): NativeFrame? = framePool.poll()
    
    fun addFrame(frame: NativeFrame) {
        if (!filledQueue.offer(frame)) {
            filledQueue.poll()?.let { recycleFrame(it) }
            filledQueue.offer(frame)
        }
    }

    fun getFrameBlocking(timeoutMs: Long): NativeFrame? = filledQueue.poll(timeoutMs, TimeUnit.MILLISECONDS)

    fun recycleFrame(frame: NativeFrame) {
        frame.length = 0
        framePool.offer(frame)
    }

    fun clear() {
        var frame = filledQueue.poll()
        while (frame != null) {
            recycleFrame(frame)
            frame = filledQueue.poll()
        }
    }
}
