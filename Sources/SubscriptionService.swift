import Foundation

// What an add reports back. The wording lives in the sheet, with the rest of the UI copy.
enum AddResult {
    case added
    case emptyInput
    case unparsableLink
    case duplicateServer
    case refreshing(String)
    case emptyFeed
    case invalidJSON
    case noXrayServer
    case refreshFailed(String)
}

@Observable
@MainActor
final class SubscriptionService: NSObject, URLSessionDelegate {
    var subscriptions: [Subscription] = []
    var refreshingIDs: Set<UUID> = []

    private let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/warpveil")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var filePath: URL {
        configDir.appendingPathComponent("subscriptions.json")
    }

    private var _session: URLSession?
    private var session: URLSession {
        if let s = _session { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = s
        return s
    }

    override init() {
        super.init()
        load()
    }

    // Allow self-signed / invalid certs (common for 3x-ui panels)
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    // MARK: - CRUD

    func load() {
        guard let data = try? Data(contentsOf: filePath),
              let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
        else { return }
        // Older builds appended a new subscription every time the same URL was added. Keep the
        // copy that actually holds servers — the first one may be a refresh that failed.
        var bestByURL: [String: Int] = [:]
        for (i, sub) in decoded.enumerated() where !sub.url.isEmpty {
            if let best = bestByURL[sub.url], decoded[best].servers.count >= sub.servers.count { continue }
            bestByURL[sub.url] = i
        }
        subscriptions = decoded.enumerated()
            .filter { i, sub in sub.url.isEmpty || bestByURL[sub.url] == i }
            .map(\.element)
        // Keys minted for a file that predates them must reach the disk before a selection can
        // point at one — but only then: the file is shared with other builds.
        if let rewritten = try? JSONEncoder().encode(subscriptions), rewritten != data {
            try? rewritten.write(to: filePath, options: .atomic)
        }
    }

    // Both cores accept two spellings for the same transport, and a panel that switches
    // spelling would otherwise rename every server and drop the selection.
    static func canonicalTransport(_ raw: String) -> String {
        switch raw {
        case "raw": "tcp"
        case "splithttp": "xhttp"
        default: raw
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        try? data.write(to: filePath, options: .atomic)
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    // MARK: - Fetch & Parse

    func addFromURL(_ urlString: String) async -> AddResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyInput }

        // Direct vless:// or vmess:// URI — add as single server immediately
        if trimmed.hasPrefix("vless://") || trimmed.hasPrefix("vmess://") {
            guard let server = parseVlessURI(trimmed) ?? parseVmessURI(trimmed) else {
                return .unparsableLink
            }
            guard !subscriptions.contains(where: { $0.servers.contains { $0.isSameNode(as: server) } }) else {
                return .duplicateServer
            }
            var sub = Subscription(name: server.name, isManual: true, engine: .xray)
            sub.servers = [server]
            sub.lastUpdated = Date()
            subscriptions.append(sub)
            save()
            return .added
        }

        // Re-adding a known feed means "update it", not "add a second copy". A refresh already
        // in flight is left to finish; otherwise the outcome is reported.
        if let existing = subscriptions.first(where: { $0.url == trimmed }) {
            guard !refreshingIDs.contains(existing.id) else { return .refreshing(existing.name) }
            guard await refreshSubscription(existing.id) else { return .refreshFailed(existing.name) }
            return .added
        }

        let name = URLComponents(string: trimmed)?.host ?? "Subscription"
        let sub = Subscription(name: name, url: trimmed, engine: .xray)
        subscriptions.append(sub)
        save()
        await refreshSubscription(sub.id)
        guard subscriptions.first(where: { $0.id == sub.id })?.servers.isEmpty == false else {
            removeSubscription(sub.id)
            return .emptyFeed
        }
        return .added
    }

    // Reports whether the feed yielded servers; a failed fetch leaves the previous ones in place.
    @discardableResult
    func refreshSubscription(_ id: UUID) async -> Bool {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }),
              !subscriptions[idx].isManual,
              !refreshingIDs.contains(id)
        else { return false }

        // A visible refresh button makes double-clicking easy; without this the two runs race.
        refreshingIDs.insert(id)
        defer { refreshingIDs.remove(id) }

        let urlString = subscriptions[idx].url

        // A list of links first, then the panel's xray format: every server runs on xray.
        if let servers = await fetchAndParseURIs(urlString), !servers.isEmpty {
            store(servers, in: id)
            return true
        }
        if let servers = await fetchXrayFormat(urlString), !servers.isEmpty {
            store(servers, in: id)
            return true
        }
        return false
    }

    // A refresh rebuilds every Server; the key has to outlive the rebuild or the selection dies
    // on every launch. Each previous server is claimed at most once, so a feed that lists one
    // node twice keeps two keys.
    private func keepingIDs(from previous: [Server], _ fresh: [Server]) -> [Server] {
        var unclaimed = previous
        var result = fresh
        var pending = Array(result.indices)

        // Exact transports first. The wildcard that covers files predating the field is not
        // transitive, so one greedy pass can hand a key to a node it does not belong to.
        for requireExactTransport in [true, false] {
            pending = pending.filter { i in
                let match = unclaimed.firstIndex {
                    $0.isSameNode(as: result[i])
                        && (!requireExactTransport || $0.transport == result[i].transport)
                }
                guard let match else { return true }
                result[i].id = unclaimed.remove(at: match).id
                return false
            }
        }
        return result
    }

    private func store(_ servers: [Server], in id: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[idx].engine = .xray
        subscriptions[idx].servers = keepingIDs(from: subscriptions[idx].servers, servers)
        subscriptions[idx].lastUpdated = Date()
        save()
    }

    func refreshAll() async {
        // Sequentially, one unreachable feed at a 15s timeout would hold up auto-connect
        // behind all the others.
        let ids = subscriptions.filter { !$0.isManual }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refreshSubscription(id) }
            }
        }
    }

    // MARK: - Fetch helpers

    private func fetchData(from urlString: String) async -> Data? {
        // Never downgrade https→http: a handshake failure could be a MITM RST
        // that would leak the subscription token in the URL over cleartext.
        let urlsToTry: [String]
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            urlsToTry = [urlString]
        } else {
            urlsToTry = ["https://" + urlString]
        }

        for urlStr in urlsToTry {
            guard let url = URL(string: urlStr) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    return data
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func fetchAndParseURIs(_ urlString: String) async -> [Server]? {
        guard let data = await fetchData(from: urlString),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        // Try base64 decode first
        let decoded: String
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedData = Data(base64Encoded: trimmed),
           let decodedStr = String(data: decodedData, encoding: .utf8) {
            decoded = decodedStr
        } else {
            // Maybe it's already plain text with URIs
            decoded = text
        }

        let lines = decoded.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var servers: [Server] = []
        for line in lines {
            if let server = parseVlessURI(line) {
                servers.append(server)
            } else if let server = parseVmessURI(line) {
                servers.append(server)
            }
            // Can add trojan://, ss:// etc. later
        }
        return servers.isEmpty ? nil : servers
    }

    private func fetchXrayFormat(_ urlString: String) async -> [Server]? {
        guard var components = URLComponents(string: urlString) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "format" }
        items.append(URLQueryItem(name: "format", value: "xray"))
        components.queryItems = items
        guard let urlStr = components.string else { return nil }

        guard let data = await fetchData(from: urlStr),
              let json = String(data: data, encoding: .utf8)
        else { return nil }

        let servers = parseXray(json)
        return servers.isEmpty ? nil : servers
    }

    // MARK: - vless:// URI parser

    private func parseVlessURI(_ uri: String) -> Server? {
        guard uri.hasPrefix("vless://") else { return nil }

        // vless://uuid@host:port?params#name
        let withoutScheme = String(uri.dropFirst("vless://".count))

        let name: String
        let mainPart: String
        if let hashIdx = withoutScheme.lastIndex(of: "#") {
            name = String(withoutScheme[withoutScheme.index(after: hashIdx)...])
                .removingPercentEncoding ?? String(withoutScheme[withoutScheme.index(after: hashIdx)...])
            mainPart = String(withoutScheme[..<hashIdx])
        } else {
            name = "vless"
            mainPart = withoutScheme
        }

        guard let atIdx = mainPart.firstIndex(of: "@") else { return nil }
        let uuid = String(mainPart[..<atIdx])
        let hostAndParams = String(mainPart[mainPart.index(after: atIdx)...])

        let hostPort: String
        let queryString: String
        if let qIdx = hostAndParams.firstIndex(of: "?") {
            hostPort = String(hostAndParams[..<qIdx])
            queryString = String(hostAndParams[hostAndParams.index(after: qIdx)...])
        } else {
            hostPort = hostAndParams
            queryString = ""
        }

        // URLComponents handles IPv6 literals like [::1]:443 correctly
        guard let url = URL(string: "scheme://\(hostPort)"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty,
              let port = comps.port else { return nil }

        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }

        let config = buildXrayConfig(protocol: "vless", uuid: uuid, host: host, port: port, params: params, tag: name)
        return Server(name: name, protocolType: "vless", address: "\(host):\(port)",
                      transport: Self.canonicalTransport(params["type"] ?? "tcp"), config: config, engine: .xray)
    }

    // MARK: - vmess:// URI parser

    private func parseVmessURI(_ uri: String) -> Server? {
        guard uri.hasPrefix("vmess://") else { return nil }
        let encoded = String(uri.dropFirst("vmess://".count))
        guard let data = Data(base64Encoded: encoded),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let host = obj["add"] as? String ?? "?"
        let port = (obj["port"] as? Int) ?? Int(obj["port"] as? String ?? "") ?? 443
        let id = obj["id"] as? String ?? ""
        let name = obj["ps"] as? String ?? "vmess"
        let net = obj["net"] as? String ?? "tcp"

        // The v2rayN fields mapped onto a vless link's query, so one builder serves both;
        // gRPC carries its service name in `path`.
        var params: [String: String] = ["type": net]
        for (field, param) in [("path", "path"), ("host", "host"), ("tls", "security"),
                               ("sni", "sni"), ("fp", "fp"), ("alpn", "alpn")] {
            if let value = obj[field] as? String, !value.isEmpty { params[param] = value }
        }
        if net == "grpc" { params["serviceName"] = params["path"] }

        let config = buildXrayConfig(protocol: "vmess", uuid: id, host: host, port: port, params: params, tag: name)
        return Server(name: name, protocolType: "vmess", address: "\(host):\(port)",
                      transport: Self.canonicalTransport(net), config: config, engine: .xray)
    }

    // MARK: - Xray config builder from URI params

    private func buildXrayConfig(protocol proto: String, uuid: String, host: String, port: Int, params: [String: String], tag: String) -> String {
        let transportType = params["type"] ?? "tcp"

        let user: [String: Any] = proto == "vmess"
            ? ["id": uuid, "alterId": 0, "security": "auto"]
            : ["id": uuid, "encryption": params["encryption"] ?? "none", "flow": params["flow"] ?? ""]
        let vnext: [String: Any] = [
            "address": host,
            "port": port,
            "users": [user]
        ]

        var outbound: [String: Any] = [
            "protocol": proto,
            "tag": tag,
            "settings": ["vnext": [vnext]],
            "mux": ["enabled": false]
        ]

        // Stream settings
        var streamSettings: [String: Any] = [
            "network": transportType
        ]

        // Transport settings
        switch transportType {
        case "xhttp", "splithttp":
            var xhttpSettings: [String: Any] = [:]
            if let path = params["path"] { xhttpSettings["path"] = path }
            if let xHost = params["host"], !xHost.isEmpty { xhttpSettings["host"] = xHost }
            if let mode = params["mode"], !mode.isEmpty { xhttpSettings["mode"] = mode }
            streamSettings["xhttpSettings"] = xhttpSettings
        case "ws":
            var wsSettings: [String: Any] = [:]
            if let path = params["path"] { wsSettings["path"] = path }
            if let wsHost = params["host"], !wsHost.isEmpty {
                wsSettings["headers"] = ["Host": wsHost]
            }
            streamSettings["wsSettings"] = wsSettings
        case "grpc":
            var grpcSettings: [String: Any] = [:]
            if let sn = params["serviceName"] { grpcSettings["serviceName"] = sn }
            streamSettings["grpcSettings"] = grpcSettings
        case "httpupgrade":
            var httpupgradeSettings: [String: Any] = [:]
            if let path = params["path"] { httpupgradeSettings["path"] = path }
            if let hHost = params["host"], !hHost.isEmpty { httpupgradeSettings["host"] = hHost }
            streamSettings["httpupgradeSettings"] = httpupgradeSettings
        default:
            break
        }

        // Security
        let security = params["security"] ?? "none"
        streamSettings["security"] = security

        switch security {
        case "tls":
            var tlsSettings: [String: Any] = [:]
            if let sni = params["sni"], !sni.isEmpty { tlsSettings["serverName"] = sni }
            if let fp = params["fp"], !fp.isEmpty { tlsSettings["fingerprint"] = fp }
            if let alpn = params["alpn"], !alpn.isEmpty {
                tlsSettings["alpn"] = alpn.components(separatedBy: ",")
            }
            streamSettings["tlsSettings"] = tlsSettings
        case "reality":
            var realitySettings: [String: Any] = [:]
            if let sni = params["sni"], !sni.isEmpty { realitySettings["serverName"] = sni }
            if let fp = params["fp"], !fp.isEmpty { realitySettings["fingerprint"] = fp }
            if let pbk = params["pbk"] { realitySettings["publicKey"] = pbk }
            if let sid = params["sid"] { realitySettings["shortId"] = sid }
            if let spx = params["spx"] { realitySettings["spiderX"] = spx }
            streamSettings["realitySettings"] = realitySettings
        default:
            break
        }

        outbound["streamSettings"] = streamSettings

        let config: [String: Any] = [
            "log": ["loglevel": "info"],
            "inbounds": [
                [
                    "tag": "socks-in",
                    "port": ProcessManager.xraySocksPort,
                    "listen": "127.0.0.1",
                    "protocol": "socks",
                    "settings": ["udp": true]
                ] as [String: Any],
                [
                    "tag": "http-in",
                    "port": 10809,
                    "listen": "127.0.0.1",
                    "protocol": "http"
                ] as [String: Any]
            ],
            "outbounds": [
                outbound,
                ["protocol": "freedom", "tag": "direct"] as [String: Any]
            ],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [] as [[String: Any]]
            ] as [String: Any]
        ]

        return serializeJSON(config) ?? "{}"
    }

    // MARK: - xray JSON parsing (for ?format=xray)

    static let vpnTypesXray: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks"
    ]

    private static let serviceTypesXray: Set<String> = [
        "freedom", "blackhole", "dns"
    ]

    private func parseXray(_ json: String) -> [Server] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [] }

        let serviceOutbounds = outbounds.filter {
            guard let proto = $0["protocol"] as? String else { return false }
            return Self.serviceTypesXray.contains(proto)
        }

        var servers: [Server] = []
        for ob in outbounds {
            guard let proto = ob["protocol"] as? String,
                  Self.vpnTypesXray.contains(proto) else { continue }

            let name = ob["tag"] as? String ?? proto
            let address: String
            if let settings = ob["settings"] as? [String: Any],
               let vnext = settings["vnext"] as? [[String: Any]],
               let first = vnext.first {
                let host = first["address"] as? String ?? "?"
                let port = first["port"] as? Int ?? 0
                address = "\(host):\(port)"
            } else if let settings = ob["settings"] as? [String: Any],
                      let srvs = settings["servers"] as? [[String: Any]],
                      let first = srvs.first {
                let host = first["address"] as? String ?? "?"
                let port = first["port"] as? Int ?? 0
                address = "\(host):\(port)"
            } else {
                address = "?"
            }
            let transport = Self.canonicalTransport((ob["streamSettings"] as? [String: Any])?["network"] as? String ?? "tcp")

            var modifiedRoot = root
            modifiedRoot["outbounds"] = [ob] + serviceOutbounds
            let config = serializeJSON(modifiedRoot) ?? ""

            servers.append(Server(name: name, protocolType: proto, address: address,
                                  transport: transport, config: config))
        }
        return servers
    }

    // MARK: - Manual config

    func addManualConfig(name: String, json: String) -> AddResult {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return .invalidJSON }

        // Every server runs on xray, so a sing-box config — or any JSON with no xray server in
        // it — is refused rather than stored as something that cannot connect.
        let servers = parseXray(json)
        guard !servers.isEmpty else { return .noXrayServer }

        var sub = Subscription(name: name, isManual: true, engine: .xray)
        sub.servers = servers
        sub.lastUpdated = Date()
        subscriptions.append(sub)
        save()
        return .added
    }

    // MARK: - Helpers

    private func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
