import Foundation
import Darwin
import SystemConfiguration

enum PingResult: Equatable {
    case measuring
    case delay(Int)
    case failed
}

// The real round trip through each proxy, not a TCP handshake: a CDN front completes a
// handshake instantly while the node behind it is dead. A user-space sing-box carries every
// server as an outbound behind its Clash API, whose delay test sends one HEAD request through
// that outbound. xray servers sit behind a user-space xray with a SOCKS inbound each and are
// chained in as socks outbounds — the shape the tunnel already uses for them. No sudo, no TUN.
// Every outbound that leaves the machine is bound to the primary interface, so a tunnel that
// is up does not swallow the probe: the number is the proxy, never tunnel + proxy.
@Observable
@MainActor
final class PingService {
    var results: [String: PingResult] = [:]
    var error: String?
    private(set) var isRunning = false

    private var task: Task<Void, Never>?
    private var generation = 0
    private var engines: [Process] = []
    private let secret = UUID().uuidString

    // Plain http:// is ignored by the API and replaced with its own default.
    private static let testURL = "https://cp.cloudflare.com/generate_204"
    private static let timeoutMilliseconds = 5000
    private static let concurrency = 10
    private static let readinessAttempts = 100
    private static let readinessInterval = Duration.milliseconds(30)

    // sing-box 1.14 moved wireguard to `endpoints` and rejects the type inside `outbounds`. One
    // such server in a feed would fail the merged config, and with it every other server's row.
    private static let singBoxPingTypes = SubscriptionService.vpnTypesSingBox.subtracting(["wireguard"])

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = PingService.concurrency
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private let singBoxConfigFile = FileManager.default.temporaryDirectory.path
        + "/warpveil-ping-singbox-\(ProcessInfo.processInfo.processIdentifier).json"
    private let xrayConfigFile = FileManager.default.temporaryDirectory.path
        + "/warpveil-ping-xray-\(ProcessInfo.processInfo.processIdentifier).json"

    func start(_ servers: [(server: Server, engine: Engine)]) {
        guard !servers.isEmpty else { return }
        generation += 1
        let run = generation
        let previous = task
        previous?.cancel()
        // Raised here rather than inside the task: start() returns before the previous run has
        // unwound, and an enabled button in that gap invites a click that does nothing visible.
        isRunning = true
        error = nil
        task = Task {
            // Runs never overlap: the engines and the config files are shared.
            await previous?.value
            guard run == generation else { return }
            for entry in servers { results[entry.server.id] = .measuring }
            await measure(servers)
            results = results.filter { $0.value != .measuring }
            // A superseded run must not clear the flag its successor has already raised.
            guard run == generation else { return }
            isRunning = false
        }
    }

    // Synchronous on purpose: the quit path calls it and exits without waiting.
    func cancel() {
        task?.cancel()
        stopEngines()
        isRunning = false
    }

    // MARK: - Run

    private func measure(_ servers: [(server: Server, engine: Engine)]) async {
        defer { stopEngines() }
        do {
            // A cancel that lands while this run is still parked on the previous one has no
            // engines to stop yet, so the check has to happen before each launch.
            guard !Task.isCancelled else { return }
            let xrayServers = servers.filter { $0.engine == .xray }.map(\.server)
            let ports = Self.freePorts(1 + xrayServers.count)
            guard let apiPort = ports.first, ports.count == 1 + xrayServers.count else {
                throw PingError("no free local port")
            }
            var xrayPorts = Dictionary(zip(xrayServers.map(\.id), ports.dropFirst()),
                                       uniquingKeysWith: { first, _ in first })
            let interface = Self.primaryInterface()
            // An xray that will not start costs the xray rows their value, not the whole run:
            // the sing-box servers in the same list never needed it.
            if !xrayServers.isEmpty, await !launchXray(xrayServers, ports: xrayPorts, interface: interface) {
                xrayPorts = [:]
            }
            guard !Task.isCancelled else { return }
            let tags = try await launchSingBox(servers, xrayPorts: xrayPorts, apiPort: apiPort, interface: interface)
            guard !Task.isCancelled else { return }
            await measureAll(tags, apiPort: apiPort)
        } catch {
            // A cancel kills the engines, and the launch that was waiting on them reports it.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func measureAll(_ tags: [String], apiPort: UInt16) async {
        var pending = tags[...]
        await withTaskGroup(of: (String, PingResult?).self) { group in
            func addNext() {
                guard !Task.isCancelled, let tag = pending.popFirst() else { return }
                group.addTask { (tag, await self.delay(of: tag, apiPort: apiPort)) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            for await (tag, result) in group {
                results[tag] = result
                addNext()
            }
        }
    }

    private func delay(of tag: String, apiPort: UInt16) async -> PingResult? {
        let query = [
            URLQueryItem(name: "url", value: Self.testURL),
            URLQueryItem(name: "timeout", value: String(Self.timeoutMilliseconds))
        ]
        // No answer at all means the engine is gone — the run was cancelled — and the row goes
        // back to unmeasured rather than to a failure it did not have.
        guard let (data, status) = await api("/proxies/\(tag)/delay", query: query, apiPort: apiPort) else {
            return nil
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let milliseconds = json["delay"] as? Int
        else { return .failed }
        return .delay(milliseconds)
    }

    private func api(_ path: String, query: [URLQueryItem] = [], apiPort: UInt16) async -> (Data, Int)? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(apiPort)
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        return (data, status)
    }

    // MARK: - Engines

    private func launch(_ path: String, _ arguments: [String]) throws -> (Process, Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        engines.append(process)
        return (process, output)
    }

    // Reports whether the xray leg is usable; the caller drops the xray rows rather than the run.
    // Readiness is every socks inbound accepting a connection, not a log line: a log line is
    // upstream's wording, and waiting for one that never comes hangs the whole service. Every
    // inbound, because xray starts tagged inbounds in map order — the first one listed is not
    // the first one up, and a delay test against a port nobody listens on fails in 14 ms.
    private func launchXray(_ servers: [Server], ports: [String: UInt16], interface: String?) async -> Bool {
        let (config, tags) = Self.xrayConfig(servers, ports: ports, interface: interface)
        let listeningPorts = tags.compactMap { ports[$0] }
        guard !listeningPorts.isEmpty else { return false }
        guard let xray = ProcessManager.findBinary("xray") else {
            error = "xray is not bundled"
            return false
        }
        write(config, to: xrayConfigFile)
        guard let (process, output) = try? launch(xray, ["run", "-config", xrayConfigFile]) else {
            error = "xray did not launch"
            return false
        }
        for _ in 0..<Self.readinessAttempts {
            guard (try? await Task.sleep(for: Self.readinessInterval)) != nil else { return false }
            guard process.isRunning else {
                error = "xray: \(Self.lastLine(of: readAll(output)))"
                return false
            }
            if listeningPorts.allSatisfy(Self.isListening) {
                drainInBackground(output)
                return true
            }
        }
        error = "xray did not start"
        return false
    }

    // Returns the tags actually in the config. sing-box prints nothing at the warn level, so
    // readiness is the API answering; an exit before that leaves the reason on the pipe.
    private func launchSingBox(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16, interface: String?
    ) async throws -> [String] {
        let (config, tags) = singBoxConfig(servers, xrayPorts: xrayPorts, apiPort: apiPort, interface: interface)
        guard !tags.isEmpty else { return [] }
        guard let singBox = ProcessManager.findBinary("sing-box") else { throw PingError("sing-box is not bundled") }
        write(config, to: singBoxConfigFile)
        let (process, output) = try launch(singBox, ["run", "-c", singBoxConfigFile])
        for _ in 0..<Self.readinessAttempts {
            try await Task.sleep(for: Self.readinessInterval)
            guard process.isRunning else {
                throw PingError("sing-box: \(Self.lastLine(of: readAll(output)))")
            }
            if await api("/", apiPort: apiPort) != nil {
                drainInBackground(output)
                return tags
            }
        }
        throw PingError("sing-box did not start")
    }

    private func stopEngines() {
        engines.forEach { $0.terminate() }
        engines = []
        try? FileManager.default.removeItem(atPath: singBoxConfigFile)
        try? FileManager.default.removeItem(atPath: xrayConfigFile)
    }

    private func readAll(_ output: Pipe) -> String {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Nothing reads an engine's output once it is up, and a full pipe buffer would block the
    // engine on its next write.
    private func drainInBackground(_ output: Pipe) {
        let handle = output.fileHandleForReading
        Task.detached { _ = try? handle.readToEnd() }
    }

    // MARK: - Configs

    // The socks outbounds are not pinned: they dial loopback, which the kernel refuses to bind to
    // a physical interface (EADDRNOTAVAIL). sing-box happens to skip the bind for loopback, but
    // the config should not lean on that.
    private func singBoxConfig(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16, interface: String?
    ) -> (String, [String]) {
        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        for entry in servers {
            var outbound: [String: Any]?
            switch entry.engine {
            case .singBox:
                outbound = Self.proxyOutbound(of: entry.server, types: Self.singBoxPingTypes, typeKey: "type")
                if let interface { outbound?["bind_interface"] = interface }
            case .xray:
                outbound = xrayPorts[entry.server.id].map {
                    ["type": "socks", "tag": entry.server.id, "server": "127.0.0.1", "server_port": Int($0)]
                }
            }
            guard let outbound else { continue }
            outbounds.append(outbound)
            tags.append(entry.server.id)
        }
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "dns": ["servers": [["type": "local", "tag": "local"]]],
            "outbounds": outbounds,
            "route": ["default_domain_resolver": "local"],
            "experimental": ["clash_api": ["external_controller": "127.0.0.1:\(apiPort)", "secret": secret]]
        ]
        return (Self.serialize(config), tags)
    }

    private static func xrayConfig(_ servers: [Server], ports: [String: UInt16], interface: String?) -> (String, [String]) {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        var tags: [String] = []
        for server in servers {
            guard let port = ports[server.id],
                  var outbound = proxyOutbound(of: server, types: SubscriptionService.vpnTypesXray, typeKey: "protocol")
            else { continue }
            if let interface {
                var streamSettings = outbound["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = streamSettings["sockopt"] as? [String: Any] ?? [:]
                sockopt["interface"] = interface
                streamSettings["sockopt"] = sockopt
                outbound["streamSettings"] = streamSettings
            }
            let inboundTag = "in-\(server.id)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": Int(port), "protocol": "socks"])
            outbounds.append(outbound)
            rules.append(["type": "field", "inboundTag": [inboundTag], "outboundTag": server.id])
            tags.append(server.id)
        }
        let config: [String: Any] = [
            "log": ["loglevel": "warning", "access": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["rules": rules]
        ]
        return (serialize(config), tags)
    }

    // Every builder and parser puts the proxy first. Anything else — a pasted config whose first
    // outbound is a selector — would take the whole merged config down, so it is left out.
    private static func proxyOutbound(of server: Server, types: Set<String>, typeKey: String) -> [String: Any]? {
        guard let data = server.config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbound = (root["outbounds"] as? [[String: Any]])?.first,
              let type = outbound[typeKey] as? String, types.contains(type)
        else { return nil }
        outbound["tag"] = server.id
        // Both name a sibling outbound to dial through that the merged config does not carry, and
        // a missing dependency is fatal for every row rather than for this one.
        outbound["detour"] = nil
        outbound["proxySettings"] = nil
        return outbound
    }

    // MARK: - Helpers

    // The interface carrying the system's default route. sing-box's TUN adds half routes and
    // leaves the real default on the physical interface, so this stays physical while the
    // tunnel is up — `route get` would answer the TUN. nil means no IPv4 network at all.
    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "WarpVeil" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private static func serialize(_ config: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // 0600: the configs carry the servers' credentials.
    private func write(_ config: String, to path: String) {
        FileManager.default.createFile(atPath: path, contents: config.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func lastLine(of text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = plain.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.last ?? "exited without a message"
    }

    private static func isListening(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // Binds port 0 once per port and keeps every socket open until all are read back, so no
    // two calls hand out the same number.
    private static func freePorts(_ count: Int) -> [UInt16] {
        var sockets: [Int32] = []
        var ports: [UInt16] = []
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, length) == 0 && getsockname(fd, sockaddrPointer, &length) == 0
                }
            }
            guard bound else { close(fd); break }
            sockets.append(fd)
            ports.append(UInt16(bigEndian: address.sin_port))
        }
        sockets.forEach { close($0) }
        return ports
    }
}

private struct PingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
