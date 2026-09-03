import Foundation
import Darwin

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
@Observable
@MainActor
final class PingService {
    var results: [String: PingResult] = [:]
    var error: String?
    private(set) var isRunning = false

    private var task: Task<Void, Never>?
    private var engines: [Process] = []
    private let secret = UUID().uuidString

    // Plain http:// is ignored by the API and replaced with its own default.
    private static let testURL = "https://cp.cloudflare.com/generate_204"
    private static let timeoutMilliseconds = 5000
    private static let concurrency = 10

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
        let previous = task
        previous?.cancel()
        task = Task {
            // Runs never overlap: the engines and the config files are shared.
            await previous?.value
            isRunning = true
            error = nil
            for entry in servers { results[entry.server.id] = .measuring }
            await measure(servers)
            results = results.filter { $0.value != .measuring }
            isRunning = false
        }
    }

    // Synchronous on purpose: the quit path calls it and exits without waiting.
    func cancel() {
        task?.cancel()
        stopEngines()
    }

    // MARK: - Run

    private func measure(_ servers: [(server: Server, engine: Engine)]) async {
        defer { stopEngines() }
        do {
            let xrayServers = servers.filter { $0.engine == .xray }.map(\.server)
            let ports = Self.freePorts(1 + xrayServers.count)
            guard let apiPort = ports.first, ports.count == 1 + xrayServers.count else {
                throw PingError("no free local port")
            }
            let xrayPorts = Dictionary(zip(xrayServers.map(\.id), ports.dropFirst()), uniquingKeysWith: { first, _ in first })
            if !xrayServers.isEmpty {
                try await launchXray(xrayServers, ports: xrayPorts)
            }
            try await launchSingBox(servers, xrayPorts: xrayPorts, apiPort: apiPort)
            await measureAll(servers.map(\.server.id), apiPort: apiPort)
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
        // No answer at all means the engine is gone — a cancel, or run.sh's pkill on connect —
        // and the row goes back to unmeasured rather than to a failure it did not have.
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

    // xray announces its inbounds with a "started" line; an exit before it leaves the reason
    // as the last line.
    private func launchXray(_ servers: [Server], ports: [String: UInt16]) async throws {
        guard let xray = ProcessManager.findBinary("xray") else { throw PingError("xray is not bundled") }
        write(Self.xrayConfig(servers, ports: ports), to: xrayConfigFile)
        let (_, output) = try launch(xray, ["run", "-config", xrayConfigFile])
        var lastLine = ""
        for try await line in output.fileHandleForReading.bytes.lines {
            if line.contains("started") { return }
            lastLine = line
        }
        throw PingError("xray: \(lastLine)")
    }

    // sing-box prints nothing at the warn level, so readiness is the API answering; an exit
    // before that leaves the reason on the pipe.
    private func launchSingBox(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16
    ) async throws {
        guard let singBox = ProcessManager.findBinary("sing-box") else { throw PingError("sing-box is not bundled") }
        write(singBoxConfig(servers, xrayPorts: xrayPorts, apiPort: apiPort), to: singBoxConfigFile)
        let (process, output) = try launch(singBox, ["run", "-c", singBoxConfigFile])
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(30))
            if !process.isRunning {
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw PingError("sing-box: \(Self.lastLine(of: text))")
            }
            if await api("/", apiPort: apiPort) != nil { return }
        }
        throw PingError("sing-box did not start")
    }

    private func stopEngines() {
        engines.forEach { $0.terminate() }
        engines = []
        try? FileManager.default.removeItem(atPath: singBoxConfigFile)
        try? FileManager.default.removeItem(atPath: xrayConfigFile)
    }

    // MARK: - Configs

    private func singBoxConfig(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16
    ) -> String {
        let outbounds: [[String: Any]] = servers.compactMap { entry in
            switch entry.engine {
            case .singBox:
                return Self.proxyOutbound(of: entry.server, types: SubscriptionService.vpnTypesSingBox, typeKey: "type")
            case .xray:
                guard let port = xrayPorts[entry.server.id] else { return nil }
                return ["type": "socks", "tag": entry.server.id, "server": "127.0.0.1", "server_port": Int(port)]
            }
        }
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "dns": ["servers": [["type": "local", "tag": "local"]]],
            "outbounds": outbounds,
            "route": ["default_domain_resolver": "local"],
            "experimental": ["clash_api": ["external_controller": "127.0.0.1:\(apiPort)", "secret": secret]]
        ]
        return Self.serialize(config)
    }

    private static func xrayConfig(_ servers: [Server], ports: [String: UInt16]) -> String {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for server in servers {
            guard let port = ports[server.id],
                  let outbound = proxyOutbound(of: server, types: SubscriptionService.vpnTypesXray, typeKey: "protocol")
            else { continue }
            let inboundTag = "in-\(server.id)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": Int(port), "protocol": "socks"])
            outbounds.append(outbound)
            rules.append(["type": "field", "inboundTag": [inboundTag], "outboundTag": server.id])
        }
        let config: [String: Any] = [
            "log": ["loglevel": "warning", "access": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["rules": rules]
        ]
        return serialize(config)
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
        return outbound
    }

    // MARK: - Helpers

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
        return plain.split(separator: "\n").last.map(String.init) ?? "exited"
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
