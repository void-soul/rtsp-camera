package com.gld.rtsp_camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

class H265Encoder(
    private val width: Int,
    private val height: Int,
    private val bitrate: Int,
    private var framerate: Int,
    private val gop: Int,
    val frameProvider: H264FrameProvider
) {
    private val tag = "H265Encoder"
    private var encoder: MediaCodec? = null
    private val running = AtomicBoolean(false)
    private var drainThread: Thread? = null
    private var selectedColorFormat = 0
    private var inputSurface: android.view.Surface? = null

    fun getInputSurface(): android.view.Surface? = inputSurface

    fun start(persistentSurface: android.view.Surface? = null): Boolean {
        if (running.get()) return true
        running.set(true)
        initEncoder(persistentSurface)
        if (encoder != null) {
            startDrainThread()
            return true
        } else {
            running.set(false)
            return false
        }
    }

    private fun initEncoder(persistentSurface: android.view.Surface? = null) {
        var format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_HEVC,
            width, height
        )
        val colorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
        selectedColorFormat = colorFormat
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, selectedColorFormat)
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate * 1000000)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, framerate)
        val iInterval = if (gop > 0) (gop.toFloat() / framerate).coerceAtLeast(1f).toInt() else 1
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iInterval)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LATENCY, 0)
        }
        
        Log.d(tag, "Encoder Config: ${width}x${height}, Bitrate=${bitrate}Mbps, FPS=$framerate, GOP=$gop, I-Interval=$iInterval, ColorFormat=$selectedColorFormat")

        format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
        format.setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.HEVCHighTierLevel5)

        try {
            val codecName = selectBestEncoder(selectedColorFormat)
            encoder = if (codecName != null) {
                Log.d(tag, "Using encoder: $codecName")
                MediaCodec.createByCodecName(codecName)
            } else {
                MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
            encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            if (selectedColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface) {
                if (persistentSurface != null) {
                    encoder?.setInputSurface(persistentSurface)
                    inputSurface = persistentSurface
                } else {
                    inputSurface = encoder?.createInputSurface()
                }
            }
            encoder?.start()
            Log.d(tag, "H265 encoder started: ${width}x${height} with format $selectedColorFormat")
        } catch (e: Exception) {
            Log.w(tag, "Failed to initialize H265 encoder with HEVCProfileMain + HEVCHighTierLevel5: ${e.message}")
            try { encoder?.release() } catch (_: Exception) {}
            encoder = null
            
            // Retry configuring without explicit profile/level keys for maximum hardware compatibility
            Log.i(tag, "Retrying H265 encoder with auto profile/level...")
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                format.removeKey(MediaFormat.KEY_PROFILE)
                format.removeKey(MediaFormat.KEY_LEVEL)
            } else {
                format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
                    setInteger(MediaFormat.KEY_COLOR_FORMAT, selectedColorFormat)
                    setInteger(MediaFormat.KEY_BIT_RATE, bitrate * 1000000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, framerate)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iInterval)
                }
            }
            try {
                val codecName = selectBestEncoder(selectedColorFormat)
                encoder = if (codecName != null) {
                    MediaCodec.createByCodecName(codecName)
                } else {
                    MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                }
                encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                if (selectedColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface) {
                    if (persistentSurface != null) {
                        encoder?.setInputSurface(persistentSurface)
                        inputSurface = persistentSurface
                    } else {
                        inputSurface = encoder?.createInputSurface()
                    }
                }
                encoder?.start()
                Log.d(tag, "H265 encoder started (auto profile/level): ${width}x${height} with format $selectedColorFormat")
            } catch (e2: Exception) {
                Log.e(tag, "Failed to initialize H265 encoder even with auto profile/level", e2)
                try { encoder?.release() } catch (_: Exception) {}
                encoder = null
                running.set(false)
            }
        }
    }

    fun encode(data: ByteArray, presentationTimeUs: Long) {
        val enc = encoder ?: return
        if (!running.get()) return
        try {
            val inputBufferIndex = enc.dequeueInputBuffer(5000)
            if (inputBufferIndex >= 0) {
                val inputBuffer = enc.getInputBuffer(inputBufferIndex)
                if (inputBuffer != null) {
                    inputBuffer.clear()
                    if (selectedColorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) {
                        putI420(data, inputBuffer, width, height)
                    } else {
                        inputBuffer.put(data)
                    }
                    enc.queueInputBuffer(inputBufferIndex, 0, inputBuffer.position(), presentationTimeUs, 0)
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "Encode error: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun putI420(nv12: ByteArray, buf: java.nio.ByteBuffer, w: Int, h: Int) {
        val ySize = w * h
        val uvSize = ySize / 4
        buf.put(nv12, 0, ySize)
        if (buf.hasArray()) {
            val arr = buf.array()
            val base = buf.arrayOffset() + ySize
            for (i in 0 until uvSize) {
                arr[base + i] = nv12[ySize + i * 2]
                arr[base + uvSize + i] = nv12[ySize + i * 2 + 1]
            }
            buf.position(ySize + uvSize * 2)
        } else {
            val staging = ByteArray(minOf(uvSize, 8192))
            var srcOff = ySize
            var remaining = uvSize
            while (remaining > 0) {
                val chunk = minOf(remaining, staging.size)
                for (j in 0 until chunk) { staging[j] = nv12[srcOff]; srcOff += 2 }
                buf.put(staging, 0, chunk)
                remaining -= chunk
            }
            srcOff = ySize + 1; remaining = uvSize
            while (remaining > 0) {
                val chunk = minOf(remaining, staging.size)
                for (j in 0 until chunk) { staging[j] = nv12[srcOff]; srcOff += 2 }
                buf.put(staging, 0, chunk)
                remaining -= chunk
            }
        }
    }

    private fun startDrainThread() {
        drainThread = Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_DISPLAY)
            drainEncoder()
        }, "H265Drain")
        drainThread?.start()
    }

    private fun drainEncoder() {
        val bufferInfo = MediaCodec.BufferInfo()
        var frameCount = 0
        var timeoutCount = 0
        var lastHeartbeat = 0L
        while (running.get()) {
            try {
                val enc = encoder ?: return
                val outputBufferIndex = enc.dequeueOutputBuffer(bufferInfo, 20000)
                if (outputBufferIndex >= 0) {
                    val outputBuffer = enc.getOutputBuffer(outputBufferIndex)
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        val frame = frameProvider.obtainEmptyFrame()
                        if (frame != null) {
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.get(frame.buffer, 0, bufferInfo.size)
                            frame.length = bufferInfo.size
                            frame.presentationTimeUs = bufferInfo.presentationTimeUs

                            val isCodecConfig = bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            val frameSize = frame.length  // Save before recycleFrame resets it
                            if (isCodecConfig) {
                                frameProvider.setSPSPPS(frame.buffer, frame.length)
                                frameProvider.recycleFrame(frame)
                            } else {
                                frameProvider.addFrame(frame)
                            }
                            frameCount++
                            timeoutCount = 0
                            if (frameCount <= 3 || frameCount % 300 == 0) {
                                Log.d(tag, "Frame #$frameCount: flags=${bufferInfo.flags}, size=$frameSize")
                            }
                        } else {
                            // Pool exhausted
                            if (frameCount % 60 == 0) Log.w(tag, "Frame pool exhausted at drain count $frameCount")
                        }
                    }
                    enc.releaseOutputBuffer(outputBufferIndex, false)
                } else {
                    // timeout or info change
                    timeoutCount++
                    if (timeoutCount % 100 == 0) {
                        Log.w(tag, "dequeueOutputBuffer result=$outputBufferIndex (timeout #$timeoutCount, drainFrames=$frameCount)")
                    }
                }
                // Heartbeat: confirm drain thread is alive
                val now = System.currentTimeMillis()
                if (now - lastHeartbeat > 5000) {
                    Log.d(tag, "Drain alive: frames=$frameCount, timeouts=$timeoutCount")
                    lastHeartbeat = now
                }
            } catch (e: Exception) {
                if (running.get()) Log.w(tag, "Drain loop error: ${e.javaClass.simpleName}: ${e.message}", e)
            }
        }
        Log.d(tag, "Drain thread exiting (sent $frameCount frames)")
    }

    fun updateBitrate(newBitrateMbps: Int) {
        val enc = encoder ?: return
        if (!running.get()) return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrateMbps * 1000000)
            enc.setParameters(params)
            Log.d(tag, "Dynamically updated bitrate to ${newBitrateMbps} Mbps")
        } catch (e: Exception) {
            Log.e(tag, "Failed to update bitrate dynamically", e)
        }
    }

    fun requestSyncFrame() {
        val enc = encoder ?: return
        if (!running.get()) return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            enc.setParameters(params)
            Log.d(tag, "Requested dynamic I-Frame sync")
        } catch (e: Exception) {
            Log.e(tag, "Failed to request sync frame", e)
        }
    }

    /**
     * Restart encoder with corrected FPS to match actual camera output.
     */
    fun restartWithFps(newFps: Int): Boolean {
        if (newFps == framerate) return true
        Log.d(tag, "Restarting encoder: FPS $framerate -> $newFps")
        running.set(false)
        try { drainThread?.join(500) } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        encoder = null
        framerate = newFps
        frameProvider.clearFilledQueue()
        running.set(true)
        initEncoder(inputSurface)
        if (encoder != null) {
            startDrainThread()
            return true
        } else {
            running.set(false)
            return false
        }
    }

    fun release() {
        running.set(false)
        try { drainThread?.join(500) } catch (_: Exception) {}
        try {
            encoder?.stop()
            encoder?.release()
        } catch (e: Exception) {
            Log.w(tag, "Error stopping encoder: ${e.message}")
        }
        encoder = null
        frameProvider.clear()
    }

    private fun selectBestColorFormat(): Int {
        val candidates = intArrayOf(
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
        )
        for (candidate in candidates) {
            if (encoderSupportsColorFormat(candidate)) {
                Log.d(tag, "Selected color format: $candidate")
                return candidate
            }
        }
        return MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
    }

    private fun encoderSupportsColorFormat(targetFormat: Int): Boolean {
        return try {
            val codecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            for (info in codecs) {
                if (!info.isEncoder) continue
                if (!info.supportedTypes.contains(MediaFormat.MIMETYPE_VIDEO_HEVC)) continue
                val caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                if (caps.colorFormats.contains(targetFormat)) return true
            }
            false
        } catch (e: Exception) { false }
    }

    private fun selectBestEncoder(colorFormat: Int): String? {
        return try {
            val codecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            var hwCodec: String? = null
            var swCodec: String? = null
            for (info in codecs) {
                if (!info.isEncoder) continue
                if (!info.supportedTypes.contains(MediaFormat.MIMETYPE_VIDEO_HEVC)) continue
                val caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                if (!caps.colorFormats.contains(colorFormat)) continue
                val name = info.name.lowercase()
                if (name.contains("omx.google") || name.contains("sw") || name.contains("c2.android")) {
                    if (swCodec == null) swCodec = info.name
                } else {
                    if (hwCodec == null) hwCodec = info.name
                }
            }
            hwCodec ?: swCodec
        } catch (e: Exception) { null }
    }
}
