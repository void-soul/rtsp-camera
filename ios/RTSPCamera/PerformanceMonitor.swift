import Foundation
import UIKit
import Darwin
import QuartzCore

private let IFF_UP = Int32(0x1)
private let IFF_LOOPBACK = Int32(0x8)

// Replicate the BSD if_data layout for statistics since net/if.h is not bridged by default in Swift
private struct LocalIfData {
    var ifi_type: UInt8 = 0
    var ifi_typelen: UInt8 = 0
    var ifi_physical: UInt8 = 0
    var ifi_addrlen: UInt8 = 0
    var ifi_hdrlen: UInt8 = 0
    var ifi_recvquota: UInt8 = 0
    var ifi_xmitquota: UInt8 = 0
    var ifi_unused1: UInt8 = 0
    var ifi_mtu: UInt32 = 0
    var ifi_metric: UInt32 = 0
    var ifi_baudrate: UInt32 = 0
    var ifi_ipackets: UInt32 = 0
    var ifi_ierrors: UInt32 = 0
    var ifi_opackets: UInt32 = 0
    var ifi_oerrors: UInt32 = 0
    var ifi_collisions: UInt32 = 0
    var ifi_ibytes: UInt32 = 0
    var ifi_obytes: UInt32 = 0
}

class PerformanceMonitor {
    private var lastTxBytes: UInt64 = 0
    private var lastRxBytes: UInt64 = 0
    private var lastTime: TimeInterval = 0

    // MARK: - Network Speed (Upload)

    func getNetworkSpeed() -> String {
        let now = CACurrentMediaTime()
        let (txBytes, _) = getNetworkBytes()

        if lastTime == 0 {
            lastTxBytes = txBytes
            lastTime = now
            return "NET: 0.0 KB/s"
        }

        let timeDiff = now - lastTime
        let byteDiff = txBytes &- lastTxBytes

        lastTxBytes = txBytes
        lastTime = now

        guard timeDiff > 0, byteDiff > 0 else { return "NET: 0.0 KB/s" }

        let speedBytesPerSec = Double(byteDiff) / timeDiff
        if speedBytesPerSec >= 1024 * 1024 {
            return String(format: "NET: %.2f MB/s", speedBytesPerSec / (1024 * 1024))
        } else {
            return String(format: "NET: %.1f KB/s", speedBytesPerSec / 1024)
        }
    }

    private func getNetworkBytes() -> (UInt64, UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var txTotal: UInt64 = 0
        var rxTotal: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let addr = ptr {
            let flags = Int32(addr.pointee.ifa_flags)
            if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: addr.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") {
                    if let data = addr.pointee.ifa_data?.assumingMemoryBound(to: LocalIfData.self) {
                        txTotal += UInt64(data.pointee.ifi_obytes)
                        rxTotal += UInt64(data.pointee.ifi_ibytes)
                    }
                }
            }
            ptr = addr.pointee.ifa_next
        }
        return (txTotal, rxTotal)
    }

    // MARK: - Memory Usage

    func getMemoryUsage() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "MEM: N/A" }
        let rssMb = Double(info.resident_size) / (1024 * 1024)
        return String(format: "MEM: %.1f MB", rssMb)
    }

    // MARK: - CPU Usage

    private var lastCpuTime: UInt64 = 0
    private var lastCpuTimestamp: TimeInterval = 0

    func getAppCpuUsage() -> String {
        let now = CACurrentMediaTime()
        let cpuTime = getProcessCpuTimeNs()

        if lastCpuTimestamp == 0 {
            lastCpuTime = cpuTime
            lastCpuTimestamp = now
            return "CPU: 0.0%"
        }

        let timeDiff = now - lastCpuTimestamp
        let cpuDiff = cpuTime &- lastCpuTime

        lastCpuTime = cpuTime
        lastCpuTimestamp = now

        guard timeDiff > 0 else { return "CPU: 0.0%" }

        let numCores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let cpuPercent = (Double(cpuDiff) / 1_000_000_000.0) / (timeDiff * numCores) * 100.0
        let clamped = min(max(cpuPercent, 0), 100)
        return String(format: "CPU: %.1f%%", clamped)
    }

    private func getProcessCpuTimeNs() -> UInt64 {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }

        var totalTimeNs: UInt64 = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS {
                totalTimeNs += UInt64(info.user_time.seconds) * 1_000_000_000 + UInt64(info.user_time.microseconds) * 1000
                totalTimeNs += UInt64(info.system_time.seconds) * 1_000_000_000 + UInt64(info.system_time.microseconds) * 1000
            }
        }
        return totalTimeNs
    }

    // MARK: - Battery

    func getBatteryLevel() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level < 0 { return "BAT: N/A" }
        return String(format: "BAT: %d%%", Int(level * 100))
    }

    // MARK: - Combined Status

    func getStatusText() -> String {
        return "\(getAppCpuUsage()) | \(getMemoryUsage()) | \(getNetworkSpeed()) | \(getBatteryLevel())"
    }
}
