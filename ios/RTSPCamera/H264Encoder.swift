import Foundation
import VideoToolbox
import CoreMedia
import QuartzCore

class H264Encoder {
    private var session: VTCompressionSession?
    
    private var callback: ((Data, Bool, Int64) -> Void)?
    private(set) var sps: Data?
    private(set) var pps: Data?
    private(set) var vps: Data? // For H.265
    
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var currentCodec: String = ""

    // FPS counter
    private var frameCount: Int = 0
    private var lastFpsTimestamp: TimeInterval = 0
    private(set) var currentFps: Double = 0.0

    // Keyframe request flag (set when client connects to ensure first frame is a keyframe)
    private var forceKeyframe: Bool = false

    func requestKeyframe() {
        forceKeyframe = true
    }
    
    func updateDynamicBitrate(bps: Int) {
        guard let session = session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
    }
    
    func setCallback(_ callback: @escaping (Data, Bool, Int64) -> Void) {
        self.callback = callback
    }
    
    func configure(width: Int32, height: Int32, codec: String, fps: Int, bitrateMbps: Int, gop: Int) {
        if session != nil && currentWidth == width && currentHeight == height && currentCodec == codec {
            // Already configured for same dimensions/codec. We can adjust bitrate/FPS/GOP dynamically.
            adjustDynamicParameters(fps: fps, bitrateMbps: bitrateMbps, gop: gop)
            return
        }
        
        stop()
        
        currentWidth = width
        currentHeight = height
        currentCodec = codec
        
        let codecType: CMVideoCodecType = (codec.lowercased() == "h265") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        
        // Define callback context
        let encoderSelf = Unmanaged.passUnretained(self).toOpaque()
        
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: nil,
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
        
        let profile = (codecType == kCMVideoCodecType_HEVC) ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        
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
        guard let session = session else { return }

        let presentationTimeStamp = CMTime(value: timestampUs, timescale: 1000000)
        let duration = CMTime(value: 1, timescale: 30) // dummy

        // If a keyframe was requested (e.g. client just connected), force the next frame to be a keyframe
        var frameProperties: CFDictionary? = nil
        if forceKeyframe {
            forceKeyframe = false
            let props: [CFString: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue]
            frameProperties = props as CFDictionary
        }

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
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        sps = nil
        pps = nil
        vps = nil
        frameCount = 0
        lastFpsTimestamp = 0
        currentFps = 0.0
    }
    
    deinit {
        stop()
    }
    
    fileprivate func handleCompressionOutput(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer = sampleBuffer else {
            print("Compression callback returned error: \(status)")
            return
        }
        
        // Check if keyframe
        var isKeyFrame = false
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        if let attachments = attachmentsArray as? [CFDictionary], !attachments.isEmpty {
            let dict = attachments[0]
            let notSync = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
            isKeyFrame = (notSync == nil)
        }
        
        // Extract format description to get SPS/PPS/VPS
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        
        // Extract SPS/PPS/VPS when keyframe comes or if they are missing
        if isKeyFrame && (sps == nil || pps == nil) {
            if currentCodec.lowercased() == "h265" {
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
                        vps = Data(bytes: vpsPtr, count: vpsSize)
                        sps = Data(bytes: spsPtr, count: spsSize)
                        pps = Data(bytes: ppsPtr, count: ppsSize)
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
                    sps = Data(bytes: spsPtr, count: spsSize)
                    pps = Data(bytes: ppsPtr, count: ppsSize)
                }
            }
        }
        
        // Read the NALUs from block buffer and convert AVCC to Annex-B (prepending 0x00000001)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let statusBlock = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard statusBlock == kCMBlockBufferNoErr, let rawData = dataPointer else { return }
        
        var offset = 0
        var streamData = Data()
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)
        
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
        frameCount += 1
        let now = CACurrentMediaTime()
        if lastFpsTimestamp == 0 {
            lastFpsTimestamp = now
        }
        let elapsed = now - lastFpsTimestamp
        if elapsed >= 1.0 {
            currentFps = Double(frameCount) / elapsed
            frameCount = 0
            lastFpsTimestamp = now
        }
        
        callback?(streamData, isKeyFrame, timeUs)
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
    guard let refCon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleCompressionOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}
