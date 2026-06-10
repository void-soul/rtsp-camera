package com.gld.rtsp_camera

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

class AudioEncoder(private val frameProvider: AudioFrameProvider) {
    private val tag = "AudioEncoder"
    private var encoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private val running = AtomicBoolean(false)
    private var thread: Thread? = null

    fun start() {
        if (running.get()) return
        running.set(true)
        
        val sampleRate = 44100
        val bufferSize = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT) * 2
        
        try {
            audioRecord = AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufferSize)
            
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
            format.setInteger(MediaFormat.KEY_BIT_RATE, 64000)
            format.setInteger(MediaFormat.KEY_AAC_PROFILE, android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
            format.setInteger("aac-encoding-adts-enabled", 0)

            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder?.start()
            audioRecord?.startRecording()
        } catch (e: Exception) {
            Log.e(tag, "Failed to start audio encoder", e)
            stop()
            return
        }

        thread = Thread {
            val bufferInfo = MediaCodec.BufferInfo()
            while (running.get()) {
                try {
                    val enc = encoder ?: break
                    val inputIndex = enc.dequeueInputBuffer(10000)
                    if (inputIndex >= 0) {
                        val inputBuffer = enc.getInputBuffer(inputIndex)
                        if (inputBuffer != null) {
                            inputBuffer.clear()
                            val ar = audioRecord
                            val read = if (ar != null && ar.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                                ar.read(inputBuffer, inputBuffer.remaining())
                            } else -1
                            if (read > 0) {
                                enc.queueInputBuffer(inputIndex, 0, read, android.os.SystemClock.elapsedRealtimeNanos() / 1000, 0)
                            } else {
                                enc.queueInputBuffer(inputIndex, 0, 0, android.os.SystemClock.elapsedRealtimeNanos() / 1000, 0)
                            }
                        }
                    }

                    var outputIndex = enc.dequeueOutputBuffer(bufferInfo, 10000)
                    while (outputIndex >= 0) {
                        val outputBuffer = enc.getOutputBuffer(outputIndex)
                        if (outputBuffer != null && bufferInfo.size > 0) {
                            if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                // Skip codec config (AudioSpecificConfig); already in SDP fmtp line
                            } else {
                                val frame = frameProvider.obtainEmptyFrame()
                                if (frame != null) {
                                    outputBuffer.get(frame.buffer, 0, bufferInfo.size)
                                    frame.length = bufferInfo.size
                                    frame.presentationTimeUs = bufferInfo.presentationTimeUs
                                    frameProvider.addFrame(frame)
                                }
                            }
                        }
                        enc.releaseOutputBuffer(outputIndex, false)
                        outputIndex = enc.dequeueOutputBuffer(bufferInfo, 0)
                    }
                } catch (e: Exception) {
                    Log.e(tag, "Encoding error", e)
                    break
                }
            }
        }
        thread?.start()
        Log.d(tag, "Audio encoder started")
    }

    fun stop() {
        running.set(false)
        thread?.join(500)
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {}
        try {
            encoder?.stop()
            encoder?.release()
        } catch (e: Exception) {}
        audioRecord = null
        encoder = null
        Log.d(tag, "Audio encoder stopped")
    }
}
