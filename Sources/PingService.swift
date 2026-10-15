import Foundation
import Darwin
import SystemConfiguration

enum PingResult: Equatable {
    case measuring
    case delay(Int)
    case failed
}

// The real round trip through each proxy, not a TCP handshake: a CDN front completes a
// handshake instantly while the node behind it is dead. Every server sits behind a user-space
// xray with a SOCKS inbound each, chained into a user-space sing-box as a socks outbound behind
// its Clash API, whose delay test sends one HEAD request through that outbound — the shape the
// tunnel uses. No sudo, no TUN.
// Every tag is measured in several passes over the same engines and the minimum is reported: the
// first request through a proxy pays its REALITY/TLS handshake, which puts every server at
// ~800 ms and hides the ~50 ms that actually separate them.
// Every server's dial is bound to the primary interface, so a tunnel that is up does not
// swallow the probe. The bind covers the dial, not name resolution: a server given as a
// hostname is still resolved by the system resolver, and that lookup lands inside the
// measured time.
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
    private static let passes = 3
    private static let readinessAttempts = 100
    private static let readinessInterval = Duration.milliseconds(30)

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = PingService.concurrency
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private var configFiles: [String] = []

    func start(_ servers: [Server]) {
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
            for server in servers { results[server.id] = .measuring }
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

    private func measure(_ servers: [Server]) async {
        defer { stopEngines() }
        do {
            // A cancel that lands while this run is still parked on the previous one has no
            // engines to stop yet, so the check has to happen before each launch.
            guard !Task.isCancelled else { return }
            let ports = Self.freePorts(1 + servers.count)
            guard let apiPort = ports.first, ports.count == 1 + servers.count else {
                throw PingError("no free local port")
            }
            let xrayPorts = Dictionary(zip(servers.map(\.id), ports.dropFirst()),
                                       uniquingKeysWith: { first, _ in first })
            let tags = await launchXray(servers, ports: xrayPorts, interface: Self.primaryInterface())
            guard !tags.isEmpty, !Task.isCancelled else { return }
            let measured = try await launchSingBox(tags, xrayPorts: xrayPorts, apiPort: apiPort)
            guard !Task.isCancelled else { return }
            await measureAll(measured, apiPort: apiPort)
        } catch {
            // A cancel kills the engines, and the launch that was waiting on them reports it.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    // Passes over every tag, not repeats inside one: nine cold handshakes at once is also what
    // makes a pass fail, and a tag that lost that race gets another chance instead of a `--`.
    private func measureAll(_ tags: [String], apiPort: UInt16) async {
        for _ in 0..<Self.passes {
            guard !Task.isCancelled else { return }
            await measurePass(tags, apiPort: apiPort)
        }
    }

    private func measurePass(_ tags: [String], apiPort: UInt16) async {
        var pending = tags[...]
        await withTaskGroup(of: (String, PingResult?).self) { group in
            func addNext() {
                guard !Task.isCancelled, let tag = pending.popFirst() else { return }
                group.addTask { (tag, await self.delay(of: tag, apiPort: apiPort)) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            for await (tag, result) in group {
                record(result, for: tag)
                addNext()
            }
        }
    }

    // The minimum across the passes is the value the handshake cannot inflate. A pass that fails
    // after another one measured does not erase that measurement, and no answer at all means the
    // engines are gone — the row keeps whatever it already shows.
    private func record(_ result: PingResult?, for tag: String) {
        switch (result, results[tag]) {
        case (nil, _): return
        case (.delay(let measured), .delay(let best)): results[tag] = .delay(min(measured, best))
        case (.failed, .delay): return
        default: results[tag] = result
        }
    }

    private func delay(of tag: String, apiPort: UInt16) async -> PingResult? {
        let query = [
            URLQueryItem(name: "url", value: Self.testURL),
            URLQueryItem(name: "timeout", value: String(Self.timeoutMilliseconds))
        ]
        // No answer at all means the engine is gone — the run was cancelled — which `record`
        // keeps apart from a failure the server did not have.
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

    // The tags whose socks inbound is up. One server xray refuses at config load takes a merged
    // config down with it: when the merge exits, each server is checked alone with `xray run
    // -test`, and the refused ones are marked failed and named in `error`. The rest run merged once
    // more — after a slow start or a port taken in the meantime as well, which no test would show.
    private func launchXray(_ servers: [Server], ports: [String: UInt16], interface: String?) async -> [String] {
        guard let xray = ProcessManager.findBinary("xray") else {
            error = "xray is not bundled"
            return []
        }
        guard let merged = startXray(xray, servers, ports: ports, interface: interface, name: "xray") else { return [] }
        if let tags = await awaitXray(merged) { return tags }
        let exited = !merged.process.isRunning
        await stop(merged)
        guard !Task.isCancelled else { return [] }
        let refused = exited ? await refusedServers(xray, servers, ports: ports, interface: interface) : []
        guard !Task.isCancelled else { return [] }
        var tags: [String] = []
        if let retry = startXray(xray, servers.filter { !refused.contains($0.id) }, ports: ports,
                                 interface: interface, name: "xray") {
            tags = await awaitXray(retry) ?? []
        }
        guard !Task.isCancelled else { return [] }
        let named = servers.filter { refused.contains($0.id) }
        if !named.isEmpty {
            named.forEach { results[$0.id] = .failed }
            error = "xray refused \(named.map(\.name).joined(separator: ", "))"
        }
        return tags
    }

    // The IDs of the servers whose config alone xray will not load.
    private func refusedServers(
        _ xray: String, _ servers: [Server], ports: [String: UInt16], interface: String?
    ) async -> Set<String> {
        await withTaskGroup(of: String?.self) { group in
            for (index, server) in servers.enumerated() {
                let (config, _) = Self.xrayConfig([server], ports: ports, interface: interface)
                let file = write(config, name: "xray-test-\(index)")
                group.addTask { await Self.loads(xray, file) ? nil : server.id }
            }
            var refused: Set<String> = []
            for await id in group {
                if let id { refused.insert(id) }
            }
            return refused
        }
    }

    // `xray run -test` loads a config and exits; waited for without holding a thread.
    private nonisolated static func loads(_ xray: String, _ file: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let test = Process()
            test.executableURL = URL(fileURLWithPath: xray)
            test.arguments = ["run", "-test", "-config", file]
            test.standardOutput = FileHandle.nullDevice
            test.standardError = FileHandle.nullDevice
            test.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try test.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // A launch that never got ready has to let go of its ports before the retry binds them.
    private func stop(_ launch: XrayLaunch) async {
        launch.process.terminate()
        for _ in 0..<Self.readinessAttempts where launch.process.isRunning {
            try? await Task.sleep(for: Self.readinessInterval)
        }
    }

    private struct XrayLaunch {
        let process: Process
        let output: Pipe
        let tags: [String]
        let ports: [UInt16]
    }

    private func startXray(
        _ xray: String, _ servers: [Server], ports: [String: UInt16], interface: String?, name: String
    ) -> XrayLaunch? {
        let (config, tags) = Self.xrayConfig(servers, ports: ports, interface: interface)
        let listeningPorts = tags.compactMap { ports[$0] }
        guard !listeningPorts.isEmpty else { return nil }
        let file = write(config, name: name)
        guard let (process, output) = try? launch(xray, ["run", "-config", file]) else {
            error = "xray did not launch"
            return nil
        }
        return XrayLaunch(process: process, output: output, tags: tags, ports: listeningPorts)
    }

    // Readiness is every socks inbound accepting a connection, not a log line: a log line is
    // upstream's wording, and waiting for one that never comes hangs the whole service. Every
    // inbound, because xray starts tagged inbounds in map order — the first one listed is not
    // the first one up, and a delay test against a port nobody listens on fails in 14 ms.
    private func awaitXray(_ launch: XrayLaunch) async -> [String]? {
        for _ in 0..<Self.readinessAttempts {
            guard (try? await Task.sleep(for: Self.readinessInterval)) != nil else { return nil }
            guard launch.process.isRunning else {
                error = "xray: \(Self.lastLine(of: readAll(launch.output)))"
                return nil
            }
            if launch.ports.allSatisfy(Self.isListening) {
                drainInBackground(launch.output)
                return launch.tags
            }
        }
        error = "xray did not start"
        return nil
    }

    // Returns the tags actually in the config. sing-box prints nothing at the warn level, so
    // readiness is the API answering; an exit before that leaves the reason on the pipe.
    private func launchSingBox(_ xrayTags: [String], xrayPorts: [String: UInt16], apiPort: UInt16) async throws -> [String] {
        let (config, tags) = singBoxConfig(xrayTags, xrayPorts: xrayPorts, apiPort: apiPort)
        guard !tags.isEmpty else { return [] }
        guard let singBox = ProcessManager.findBinary("sing-box") else { throw PingError("sing-box is not bundled") }
        let file = write(config, name: "singbox")
        let (process, output) = try launch(singBox, ["run", "-c", file])
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
        configFiles.forEach { try? FileManager.default.removeItem(atPath: $0) }
        configFiles = []
    }

    private func readAll(_ output: Pipe) -> String {
        // One invalid byte must not drop the reason with the rest of the output.
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // Nothing reads an engine's output once it is up, and a full pipe buffer would block the
    // engine on its next write.
    private func drainInBackground(_ output: Pipe) {
        let handle = output.fileHandleForReading
        Task.detached { _ = try? handle.readToEnd() }
    }

    // MARK: - Configs

    // The socks outbounds are not pinned: they dial loopback, which the kernel refuses to bind to
    // a physical interface (EADDRNOTAVAIL).
    private func singBoxConfig(_ xrayTags: [String], xrayPorts: [String: UInt16], apiPort: UInt16) -> (String, [String]) {
        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        for tag in xrayTags {
            guard let port = xrayPorts[tag] else { continue }
            outbounds.append(["type": "socks", "tag": tag, "server": "127.0.0.1", "server_port": Int(port)])
            tags.append(tag)
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
                  let serverOutbounds = proxyOutbounds(of: server, interface: interface)
            else { continue }
            let inboundTag = "in-\(server.id)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": Int(port), "protocol": "socks"])
            outbounds += serverOutbounds
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

    // The server's proxy, tagged with its ID, and the freedom outbounds it dials through under
    // tags of their own, so two servers' dialers cannot collide in the merged config — the probe
    // goes the way the connection does. Whatever dials leaves through the physical interface.
    // Every builder and parser puts the proxy first; anything else — a pasted config whose first
    // outbound is a selector — would take the whole merged config down, so it is left out.
    private static func proxyOutbounds(of server: Server, interface: String?) -> [[String: Any]]? {
        guard let data = server.config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              var proxy = outbounds.first,
              let type = proxy["protocol"] as? String, SubscriptionService.vpnTypesXray.contains(type)
        else { return nil }
        let dialers = BypassService.xrayDialers(of: proxy, in: outbounds).map { dialer in
            var dialer = dialer
            dialer["tag"] = "\(server.id)-\(dialer["tag"] as? String ?? "")"
            return dialer
        }
        proxy["tag"] = server.id
        // A dialer the frame does not carry stays named: the dial fails here as it does on connect.
        if let tag = dialers.first?["tag"] { proxy = BypassService.settingSockopt(proxy, "dialerProxy", tag) }
        return ([proxy] + dialers).map { outbound in
            interface.map { BypassService.settingSockopt(outbound, "interface", $0) } ?? outbound
        }
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

    // 0600: the configs carry the servers' credentials. xray picks the format by the extension.
    private func write(_ config: String, name: String) -> String {
        let path = FileManager.default.temporaryDirectory.path
            + "/warpveil-ping-\(name)-\(ProcessInfo.processInfo.processIdentifier).json"
        FileManager.default.createFile(atPath: path, contents: config.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
        configFiles.append(path)
        return path
    }

    private static func lastLine(of text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = plain.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.last ?? "exited without a message"
    }

    // A TCP connect to loopback answers at once: refused until the port is bound.
    static func isListening(_ port: UInt16) -> Bool {
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
