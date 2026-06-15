import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore

class H264Encoder {
    private var session: VTCompressionSession?
    let lock = NSLock()
    
    fileprivate var callback: ((Data, Bool, Int64) -> Void)?
    
    fileprivate var _sps: Data?
    fileprivate var _pps: Data?
    fileprivate var _vps: Data?
    
    var sps: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _sps
    }
    
    var pps: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _pps
    }
    
    var vps: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _vps
    }
    
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    fileprivate var _currentCodec: String = ""
    
    var currentCodec: String {
        lock.lock()
        defer { lock.unlock() }
        return _currentCodec
    }

    // FPS counter
    var frameCount: Int = 0
    var lastFpsTimestamp: TimeInterval = 0
    fileprivate var _currentFps: Double = 0.0
    
    var currentFps: Double {
        lock.lock()
        defer { lock.unlock() }
        return _currentFps
    }

    // Keyframe request flag (set when client connects to ensure first frame is a keyframe)
    private var _forceKeyframe: Bool = false

    func requestKeyframe() {
        lock.lock()
        defer { lock.unlock() }
        _forceKeyframe = true
    }
    
    func updateDynamicBitrate(bps: Int) {
        lock.lock()
        let activeSession = session
        lock.unlock()
        guard let session = activeSession else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
    }
    
    func setCallback(_ callback: @escaping (Data, Bool, Int64) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.callback = callback
    }
    
    func configure(width: Int32, height: Int32, codec: String, fps: Int, bitrateMbps: Int, gop: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        if session != nil && currentWidth == width && currentHeight == height && _currentCodec == codec {
            // Already configured for same dimensions/codec. We can adjust bitrate/FPS/GOP dynamically.
            adjustDynamicParameters(fps: fps, bitrateMbps: bitrateMbps, gop: gop)
            return
        }
        
        stopLocked()
        
        currentWidth = width
        currentHeight = height
        _currentCodec = codec
        
        let codecType: CMVideoCodecType = (codec.lowercased() == "h265") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        // Define callback context
        let encoderSelf = Unmanaged.passUnretained(self).toOpaque()

        // Explicitly prefer the hardware-accelerated VideoToolbox encoder. This keeps
        // real-time encoding off the CPU and reduces per-frame latency, matching the
        // behavior of Android's hardware MediaCodec path.
        let encoderSpec: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue
        ] as CFDictionary

        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: encoderSelf,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("VTCompressionSessionCreate failed: \(status)")
            return
        }
        
        // Configure Session Properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // Low latency (No B-frames)
        // Require encoder output for every input frame without latency-generating lookahead.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        let profile = (codecType == kCMVideoCodecType_HEVC) ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        // Cap the peak data rate to smooth out I-frame bursts that otherwise flood the
        // TCP send path and trigger PotPlayer buffering. Format: [bytes, duration_seconds]
        // meaning "no more than `bytes` bytes over any `duration_seconds` window".
        // We allow ~2.0x the average bitrate over a 1-second window so instantaneous
        // keyframe spikes are clipped while still leaving headroom for motion.
        let bitrateBps = bitrateMbps * 1000 * 1000
        let peakBytes = Int(Double(bitrateBps) * 2.0 / 8.0) // bytes per second window
        let dataRateLimits: [NSNumber] = [peakBytes as NSNumber, 1.0 as NSNumber]
        let drStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        if drStatus != noErr {
            print("[RTSPCamera] Failed to set DataRateLimits: \(drStatus)")
        }

        adjustDynamicParameters(fps: fps, bitrateMbps: bitrateMbps, gop: gop)
        
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        if status != noErr {
            print("VTCompressionSessionPrepareToEncodeFrames failed: \(status)")
        }
    }
    
    private func adjustDynamicParameters(fps: Int, bitrateMbps: Int, gop: Int) {
        guard let session = session else { return }
        
        let bitrateBps = bitrateMbps * 1000 * 1000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateBps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: (Double(gop) / Double(fps)) as CFNumber)
    }
    
    func encode(pixelBuffer: CVPixelBuffer, timestampUs: Int64) {
        lock.lock()
        guard let session = session else {
            lock.unlock()
            return
        }
        
        let presentationTimeStamp = CMTime(value: timestampUs, timescale: 1000000)
        let duration = CMTime(value: 1, timescale: 30) // dummy
        
        // If a keyframe was requested (e.g. client just connected), force the next frame to be a keyframe
        var frameProperties: CFDictionary? = nil
        if _forceKeyframe {
            _forceKeyframe = false
            let props: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue]
            frameProperties = props as CFDictionary
        }
        lock.unlock()
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            print("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }
    
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }
    
    private func stopLocked() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        _sps = nil
        _pps = nil
        _vps = nil
        frameCount = 0
        lastFpsTimestamp = 0
        _currentFps = 0.0
    }
    
    deinit {
        stop()
    }
}

// Global Callback function for VideoToolbox compression
private let compressionCallback: VTCompressionOutputCallback = { (
    outputCallbackRefCon,
    sourceFrameRefCon,
    status,
    infoFlags,
    sampleBuffer
) in
    guard status == noErr, let sampleBuffer = sampleBuffer else {
        print("Compression callback returned error: \(status)")
        return
    }
    
    let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
    
    // Check if keyframe
    var isKeyFrame = false
    let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
    if let attachments = attachmentsArray as? [CFDictionary], !attachments.isEmpty {
        let dict = attachments[0]
        let notSync = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        isKeyFrame = (notSync == nil)
    }
    
    // Extract format description to get SPS/PPS/VPS
    let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)

    // Extract SPS/PPS/VPS when keyframe comes or if they are missing
    let needsParams: Bool
    if encoder.currentCodec.lowercased() == "h265" {
        needsParams = encoder.sps == nil || encoder.pps == nil || encoder.vps == nil
    } else {
        needsParams = encoder.sps == nil || encoder.pps == nil
    }
    if isKeyFrame && needsParams, let formatDescription = formatDescription {
        if encoder.currentCodec.lowercased() == "h265" {
            var vpsSize = 0, spsSize = 0, ppsSize = 0
            var vpsCount = 0, spsCount = 0, ppsCount = 0
            var vpsPointer: UnsafePointer<UInt8>?, spsPointer: UnsafePointer<UInt8>?, ppsPointer: UnsafePointer<UInt8>?
            
            // In iOS, HEVC parameters are extracted via CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
            // Since we need it to be dynamic, let's call the standard OS entry points
            if #available(iOS 11.0, *) {
                // H.265 parameter extraction
                var nalHeaderLength: Int32 = 0
                
                let vpsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: 0,
                    parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: &vpsCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                let spsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: 1,
                    parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                let ppsStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: 2,
                    parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount,
                    nalUnitHeaderLengthOut: &nalHeaderLength
                )
                
                if vpsStatus == noErr, spsStatus == noErr, ppsStatus == noErr,
                   let vpsPtr = vpsPointer, let spsPtr = spsPointer, let ppsPtr = ppsPointer {
                    encoder.lock.lock()
                    encoder._vps = Data(bytes: vpsPtr, count: vpsSize)
                    encoder._sps = Data(bytes: spsPtr, count: spsSize)
                    encoder._pps = Data(bytes: ppsPtr, count: ppsSize)
                    encoder.lock.unlock()
                }
            }
        } else {
            // H.264 parameter extraction
            var spsSize = 0, ppsSize = 0
            var spsCount = 0, ppsCount = 0
            var spsPointer: UnsafePointer<UInt8>?, ppsPointer: UnsafePointer<UInt8>?
            var nalHeaderLength: Int32 = 0
            
            let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )
            let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )
            
            if spsStatus == noErr, ppsStatus == noErr,
               let spsPtr = spsPointer, let ppsPtr = ppsPointer {
                encoder.lock.lock()
                encoder._sps = Data(bytes: spsPtr, count: spsSize)
                encoder._pps = Data(bytes: ppsPtr, count: ppsSize)
                encoder.lock.unlock()
            }
        }
    }
    
    // Log if formatDescription is nil (unusual but not fatal for NAL extraction)
    if formatDescription == nil {
        print("[RTSPCamera] Encoder: formatDescription is nil for \(isKeyFrame ? "keyframe" : "delta frame"), NAL data will still be extracted")
    }

    // Read the NALUs from block buffer and convert AVCC to Annex-B (prepending 0x00000001)
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        print("[RTSPCamera] Encoder: blockBuffer is nil, dropping frame")
        return
    }
    
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    let statusBlock = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    
    guard statusBlock == kCMBlockBufferNoErr, let rawData = dataPointer else { return }
    
    var offset = 0
    var streamData = Data()
    
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timeUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)
    
    let startCode = Data([0x00, 0x00, 0x00, 0x01])
    
    if isKeyFrame {
        encoder.lock.lock()
        let localSps = encoder._sps
        let localPps = encoder._pps
        let localVps = encoder._vps
        let isH265 = (encoder._currentCodec.lowercased() == "h265")
        encoder.lock.unlock()
        
        if isH265 {
            if let vps = localVps, let sps = localSps, let pps = localPps {
                streamData.append(startCode)
                streamData.append(vps)
                streamData.append(startCode)
                streamData.append(sps)
                streamData.append(startCode)
                streamData.append(pps)
            }
        } else {
            if let sps = localSps, let pps = localPps {
                streamData.append(startCode)
                streamData.append(sps)
                streamData.append(startCode)
                streamData.append(pps)
            }
        }
    }
    
    while offset < totalLength - 4 {
        // Read 4-byte big-endian NALU length
        var naluLength: UInt32 = 0
        memcpy(&naluLength, rawData.advanced(by: offset), 4)
        naluLength = CFSwapInt32BigToHost(naluLength)
        
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        streamData.append(startCode)
        
        let naluPtr = rawData.advanced(by: offset + 4)
        streamData.append(UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(naluPtr)), count: Int(naluLength)))
        
        offset += 4 + Int(naluLength)
    }
    
    // Update FPS counter
    encoder.lock.lock()
    encoder.frameCount += 1
    let now = CACurrentMediaTime()
    if encoder.lastFpsTimestamp == 0 {
        encoder.lastFpsTimestamp = now
    }
    let elapsed = now - encoder.lastFpsTimestamp
    if elapsed >= 1.0 {
        encoder._currentFps = Double(encoder.frameCount) / elapsed
        encoder.frameCount = 0
        encoder.lastFpsTimestamp = now
    }
    let cb = encoder.callback
    let totalFrames = encoder.frameCount
    encoder.lock.unlock()

    // Log every 30 frames (~1/sec at 30fps) to confirm encoder is producing output
    if totalFrames % 30 == 0 {
        print("[RTSPCamera] Encoder: produced frame #\(totalFrames), size=\(streamData.count) bytes, keyframe=\(isKeyFrame)")
    }

    cb?(streamData, isKeyFrame, timeUs)
}
