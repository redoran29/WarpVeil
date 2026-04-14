import Foundation
import Darwin

@Observable
final class NetworkMonitor {
    var uploadSpeed: String = ""
    var downloadSpeed: String = ""
    var downloadBPS: Double = 0
    var uploadBPS: Double = 0
    var hasTraffic = false
    var downloadHistory: [Double] = Array(repeating: 0, count: 60)
    var uploadHistory: [Double] = Array(repeating: 0, count: 60)

    private var timer: Timer?
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var historyIndex = 0

    deinit {
        timer?.invalidate()
    }

    func start() {
        (lastIn, lastOut) = Self.readBytes()
        historyIndex = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        uploadSpeed = ""
        downloadSpeed = ""
        downloadBPS = 0
        uploadBPS = 0
        hasTraffic = false
        downloadHistory = Array(repeating: 0, count: 60)
        uploadHistory = Array(repeating: 0, count: 60)
        historyIndex = 0
    }

    private func tick() {
        let (totalIn, totalOut) = Self.readBytes()
        let dIn = totalIn > lastIn ? totalIn - lastIn : 0
        let dOut = totalOut > lastOut ? totalOut - lastOut : 0
        lastIn = totalIn
        lastOut = totalOut

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            downloadSpeed = Self.format(dIn)
            uploadSpeed = Self.format(dOut)
            downloadBPS = Double(dIn)
            uploadBPS = Double(dOut)
            hasTraffic = dIn > 1024 || dOut > 1024
            downloadHistory[historyIndex] = Double(dIn)
            uploadHistory[historyIndex] = Double(dOut)
            historyIndex = (historyIndex + 1) % 60
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        String(format: "%05.2f MB/s", Double(bytes) / 1_048_576)
    }

    static func formatSplit(_ bps: Double) -> (String, String) {
        if bps >= 1_048_576 {
            return (String(format: "%.1f", bps / 1_048_576), "MB/s")
        } else if bps >= 1024 {
            return (String(format: "%.0f", bps / 1024), "KB/s")
        }
        return ("0", "KB/s")
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
