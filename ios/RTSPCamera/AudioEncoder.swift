import Foundation
import AudioToolbox
import CoreMedia

class AudioEncoder {
    private var audioConverter: AudioConverterRef?
    private var pcmBuffer = Data()
    private var callback: ((Data, Int64) -> Void)?
    private let lock = NSLock()
    
    private var srcFormat = AudioStreamBasicDescription()
    private var dstFormat = AudioStreamBasicDescription()
    
    private let outBufferMaxSizeBytes: UInt32 = 1024 * 8
    private var outBuffer: UnsafeMutablePointer<UInt8>
    
    init() {
        outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(outBufferMaxSizeBytes))
    }
    
    deinit {
        stop()
        outBuffer.deallocate()
    }
    
    func setCallback(_ callback: @escaping (Data, Int64) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.callback = callback
    }
    
    func configure(sampleRate: Double, channels: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
        
        // Setup source format (PCM from AVCaptureAudioDataOutput)
        srcFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        // Setup destination format (AAC-LC)
        dstFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        var status = AudioConverterNew(&srcFormat, &dstFormat, &audioConverter)
        guard status == noErr, let converter = audioConverter else {
            print("AudioConverterNew failed: \(status)")
            return
        }
        
        // Set Bitrate
        var bitrate: UInt32 = 64000 // 64kbps
        let size = UInt32(MemoryLayout.size(ofValue: bitrate))
        status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, size, &bitrate)
        if status != noErr {
            print("Failed to set audio bitrate: \(status)")
        }
    }
    
    func encode(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let converter = audioConverter else {
            lock.unlock()
            return
        }
        
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else {
            lock.unlock()
            return
        }
        
        let timestampUs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)
        
        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBufferList.mBuffers, count: Int(audioBufferList.mNumberBuffers))
        for buffer in buffers {
            if let mData = buffer.mData {
                pcmBuffer.append(Data(bytes: mData, count: Int(buffer.mDataByteSize)))
            }
        }
        
        let bytesPerFrame = srcFormat.mBytesPerFrame
        let bytesNeeded = 1024 * Int(bytesPerFrame)
        
        while pcmBuffer.count >= bytesNeeded {
            guard let activeConverter = audioConverter else { break }
            var chunk = pcmBuffer.prefix(bytesNeeded)
            pcmBuffer.removeFirst(bytesNeeded)
            
            chunk.withUnsafeMutableBytes { (rawBufferPointer: UnsafeMutableRawBufferPointer) in
                guard let baseAddress = rawBufferPointer.baseAddress else { return }
                
                var context = AudioEncoderInputContext(
                    dataPointer: baseAddress,
                    dataSize: UInt32(bytesNeeded),
                    bytesPerFrame: bytesPerFrame
                )
                
                var ioOutputDataPacketSize: UInt32 = 1
                var outAudioBufferList = AudioBufferList()
                outAudioBufferList.mNumberBuffers = 1
                outAudioBufferList.mBuffers.mNumberChannels = dstFormat.mChannelsPerFrame
                outAudioBufferList.mBuffers.mDataByteSize = outBufferMaxSizeBytes
                outAudioBufferList.mBuffers.mData = UnsafeMutableRawPointer(outBuffer)
                
                let encodeStatus = AudioConverterFillComplexBuffer(
                    activeConverter,
                    inputDataProc,
                    &context,
                    &ioOutputDataPacketSize,
                    &outAudioBufferList,
                    nil
                )
                
                var aacData: Data? = nil
                if encodeStatus == noErr && ioOutputDataPacketSize > 0 {
                    aacData = Data(bytes: outBuffer, count: Int(outAudioBufferList.mBuffers.mDataByteSize))
                }
                
                let cb = callback
                lock.unlock()
                
                if let aac = aacData {
                    cb?(aac, timestampUs)
                }
                
                lock.lock()
            }
        }
        lock.unlock()
    }
    
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }
    
    private func stopLocked() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        pcmBuffer.removeAll()
    }
}

// Struct to pass to the AudioConverter callback without heap allocations
private struct AudioEncoderInputContext {
    var dataPointer: UnsafeRawPointer
    var dataSize: UInt32
    var bytesPerFrame: UInt32
}

// Input Data Procedure for AudioConverter (C-compatible function pointer)
private let inputDataProc: AudioConverterComplexInputDataProc = { (
    inAudioConverter,
    ioNumberDataPackets,
    ioData,
    outDataPacketDescription,
    inUserData
) -> OSStatus in
    
    let context = inUserData!.assumingMemoryBound(to: AudioEncoderInputContext.self)
    
    let requestedPackets = ioNumberDataPackets.pointee
    let availablePackets = context.pointee.dataSize / context.pointee.bytesPerFrame
    
    if availablePackets == 0 || requestedPackets == 0 {
        ioNumberDataPackets.pointee = 0
        return 100 // End of data
    }
    
    let packetsToProcess = min(requestedPackets, availablePackets)
    ioNumberDataPackets.pointee = packetsToProcess
    
    let bytesToProcess = packetsToProcess * context.pointee.bytesPerFrame
    
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mDataByteSize = bytesToProcess
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: context.pointee.dataPointer)
    
    // Advance internal pointers
    context.pointee.dataPointer = context.pointee.dataPointer.advanced(by: Int(bytesToProcess))
    context.pointee.dataSize -= bytesToProcess
    
    return noErr
}
