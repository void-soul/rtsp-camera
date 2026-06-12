import Foundation
import QuartzCore

// MARK: - NativeFrame (Pre-allocated reusable buffer)
class NativeFrame {
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int
    var length: Int = 0
    var timestampUs: Int64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        buffer.deallocate()
    }
}

// MARK: - VideoFrameProvider (Pre-allocated pool + bounded queue for video)
class VideoFrameProvider {
    private let poolSize: Int
    private let queueCapacity: Int
    private var framePool = [NativeFrame]()
    private var filledQueue = [NativeFrame]()
    private let lock = NSLock()
    private let semaphore: DispatchSemaphore

    private(set) var totalDroppedFrames: Int = 0
    var keyframeRequester: (() -> Void)?
    private var lastKeyframeRequestTime: TimeInterval = 0

    private var isPrepared = false

    /// SPS/PPS/VPS cached for SDP generation
    private(set) var sps: Data?
    private(set) var pps: Data?
    private(set) var vps: Data?

    init(queueCapacity: Int = 5) {
        self.queueCapacity = queueCapacity
        self.poolSize = queueCapacity + 10
        self.semaphore = DispatchSemaphore(value: 0)
    }

    /// Allocate buffer pool lazily when streaming starts
    func prepare() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared else { return }
        for _ in 0..<poolSize {
            framePool.append(NativeFrame(capacity: 2 * 1024 * 1024)) // 2MB per frame
        }
        isPrepared = true
    }

    /// Get an empty frame from the pool
    func obtainEmptyFrame() -> NativeFrame? {
        lock.lock()
        defer { lock.unlock() }
        if !isPrepared { prepare() }
        return framePool.popLast()
    }

    private func recycleFrameLocked(_ frame: NativeFrame) {
        frame.length = 0
        framePool.append(frame)
    }

    /// Add a filled frame to the bounded queue
    func addFrame(_ frame: NativeFrame) {
        lock.lock()
        if filledQueue.count >= queueCapacity {
            // Drop oldest
            if let oldest = filledQueue.first {
                totalDroppedFrames += 1
                recycleFrameLocked(oldest)
                filledQueue.removeFirst()
            }
            // Request keyframe recovery (rate-limited to 1/sec)
            let now = CACurrentMediaTime()
            if now - lastKeyframeRequestTime > 1.0 {
                lastKeyframeRequestTime = now
                keyframeRequester?()
            }
        }
        filledQueue.append(frame)
        lock.unlock()
        semaphore.signal()
    }

    /// Get a filled frame, blocks until available or timeout
    func getFrameBlocking(timeoutMs: Int) -> NativeFrame? {
        let result = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
        guard result == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return filledQueue.isEmpty ? nil : filledQueue.removeFirst()
    }

    /// Return a frame to the pool
    func recycleFrame(_ frame: NativeFrame) {
        lock.lock()
        recycleFrameLocked(frame)
        lock.unlock()
    }

    /// Drop all queued frames
    func clearFilledQueue() {
        lock.lock()
        for frame in filledQueue {
            frame.length = 0
            framePool.append(frame)
        }
        filledQueue.removeAll()
        lastKeyframeRequestTime = 0
        lock.unlock()
    }

    func clear() {
        clearFilledQueue()
    }

    func resetDroppedFrameStats() {
        lock.lock()
        totalDroppedFrames = 0
        lastKeyframeRequestTime = 0
        lock.unlock()
    }

    // MARK: - SPS/PPS/VPS management

    func setParameterSets(data: Data) {
        var i = 0
        let bytes = [UInt8](data)
        let length = bytes.count
        while i < length - 2 {
            var startCodeSize = 0
            if i < length - 3 && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeSize = 4
            } else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeSize = 3
            }
            if startCodeSize > 0 {
                let start = i + startCodeSize
                var end = length
                for j in start..<(length - 2) {
                    if bytes[j] == 0 && bytes[j+1] == 0 {
                        if (j < length - 3 && bytes[j+2] == 0 && bytes[j+3] == 1) || bytes[j+2] == 1 {
                            end = j
                            break
                        }
                    }
                }
                let nalData = Data(bytes[start..<end])
                let rawByte = bytes[start]
                let h264Type = Int(rawByte & 0x1F)
                let h265Type = Int((rawByte >> 1) & 0x3F)
                switch h264Type {
                case 7: sps = nalData
                case 8: pps = nalData
                default: break
                }
                switch h265Type {
                case 32: vps = nalData
                case 33: sps = nalData
                case 34: pps = nalData
                default: break
                }
                i = end
            } else {
                i += 1
            }
        }
    }
}

// MARK: - AudioFrameProvider (Pre-allocated pool + bounded queue for audio)
class AudioFrameProvider {
    private let poolSize = 150
    private let queueCapacity = 100
    private var framePool = [NativeFrame]()
    private var filledQueue = [NativeFrame]()
    private let lock = NSLock()
    private let semaphore: DispatchSemaphore

    init() {
        self.semaphore = DispatchSemaphore(value: 0)
        // Pre-allocate small audio buffers
        for _ in 0..<poolSize {
            framePool.append(NativeFrame(capacity: 4096))
        }
    }

    func obtainEmptyFrame() -> NativeFrame? {
        lock.lock()
        defer { lock.unlock() }
        return framePool.popLast()
    }

    private func recycleFrameLocked(_ frame: NativeFrame) {
        frame.length = 0
        framePool.append(frame)
    }

    func addFrame(_ frame: NativeFrame) {
        lock.lock()
        if filledQueue.count >= queueCapacity {
            if let oldest = filledQueue.first {
                recycleFrameLocked(oldest)
                filledQueue.removeFirst()
            }
        }
        filledQueue.append(frame)
        lock.unlock()
        semaphore.signal()
    }

    func getFrameBlocking(timeoutMs: Int) -> NativeFrame? {
        let result = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
        guard result == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return filledQueue.isEmpty ? nil : filledQueue.removeFirst()
    }

    func recycleFrame(_ frame: NativeFrame) {
        lock.lock()
        recycleFrameLocked(frame)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        for frame in filledQueue {
            frame.length = 0
            framePool.append(frame)
        }
        filledQueue.removeAll()
        lock.unlock()
    }
}
