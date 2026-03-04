import Foundation
import Darwin

@Observable
final class NetworkMonitor {
    var uploadSpeed: String = ""
    var downloadSpeed: String = ""
    var isActive = false

    private var timer: Timer?
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0

    func start() {
        (lastIn, lastOut) = Self.readBytes()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        uploadSpeed = ""
        downloadSpeed = ""
        isActive = false
    }

    private func tick() {
        let (totalIn, totalOut) = Self.readBytes()
        let dIn = totalIn > lastIn ? totalIn - lastIn : 0
        let dOut = totalOut > lastOut ? totalOut - lastOut : 0
        lastIn = totalIn
        lastOut = totalOut

        DispatchQueue.main.async { [self] in
            isActive = dIn > 1024 || dOut > 1024
            downloadSpeed = Self.format(dIn)
            uploadSpeed = Self.format(dOut)
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1024: return "\(bytes) B/s"
        case 1024..<1_048_576: return "\(bytes / 1024) KB/s"
        default: return String(format: "%.1f MB/s", Double(bytes) / 1_048_576)
        }
    }

    private static func readBytes() -> (UInt64, UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let addr = ifa.pointee
            // AF_LINK = link-layer, has byte counters
            if addr.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                if let data = addr.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    totalIn += UInt64(d.ifi_ibytes)
                    totalOut += UInt64(d.ifi_obytes)
                }
            }
            cursor = addr.ifa_next
        }
        return (totalIn, totalOut)
    }
}
