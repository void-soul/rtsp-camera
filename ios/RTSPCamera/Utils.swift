import Foundation
import Darwin
import os.log

private let IFF_UP = Int32(0x1)
private let IFF_LOOPBACK = Int32(0x8)

enum Utils {
    static func getIPAddress() -> String {
        var address: String = "127.0.0.1"
        
        // Get list of all network interfaces
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        
        // For USB tethering (often "en3", "en4" or "bridge100") and Wi-Fi ("en0")
        // We look for any IPv4 address that is not loopback
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            
            if let addrPtr = interface.ifa_addr {
                var addr = addrPtr.pointee
                
                // Check for IPv4
                if addr.sa_family == UInt8(AF_INET) {
                    // Check if it's not a loopback interface and is active
                    if (flags & IFF_LOOPBACK) == 0 && (flags & IFF_UP) != 0 {
                        let name = String(cString: interface.ifa_name)
                        
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            
                            // We prefer interfaces like "bridge100" (usually USB network sharing) or "en0" (Wi-Fi)
                            // If we see en0 or bridge100, we prefer it, but return any non-loopback IPv4 if none other is found
                            if name.contains("bridge") || name.contains("en0") {
                                freeifaddrs(ifaddr)
                                return ip
                            }
                            address = ip
                        }
                    }
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        freeifaddrs(ifaddr)
        return address
    }
}

public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let output = items.map { String(describing: $0) }.joined(separator: separator)
    #if DEBUG
    Swift.print(output, terminator: terminator)
    #endif
    
    // Split by newline and log each line separately using os_log and NSLog.
    // This prevents NSLog/os_log from truncating or redacting the multiline strings.
    let lines = output.components(separatedBy: "\n")
    for line in lines {
        if #available(iOS 10.0, *) {
            os_log("%{public}@", log: OSLog.default, type: .default, "[RTSPCamera] \(line)")
        } else {
            NSLog("[RTSPCamera] %@", line)
        }
    }
}
