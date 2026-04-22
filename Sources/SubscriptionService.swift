import Foundation

@Observable
@MainActor
final class SubscriptionService: NSObject, URLSessionDelegate {
    var subscriptions: [Subscription] = []

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
        subscriptions = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        try? data.write(to: filePath, options: .atomic)
    }

    func addSubscription(_ sub: Subscription) {
        subscriptions.append(sub)
        save()
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    func updateSubscription(_ sub: Subscription) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        subscriptions[idx] = sub
        save()
    }

    // MARK: - Fetch & Parse

    func addFromURL(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct vless:// or vmess:// URI — add as single server immediately
        if trimmed.hasPrefix("vless://") || trimmed.hasPrefix("vmess://") {
            var server: Server?
            if trimmed.hasPrefix("vless://") { server = parseVlessURI(trimmed) }
            else { server = parseVmessURI(trimmed) }
            guard let server else { return }
            var sub = Subscription(name: server.name, isManual: true, engine: .singBox)
            sub.servers = [server]
            sub.lastUpdated = Date()
            subscriptions.append(sub)
            save()
            return
        }

        // Subscription URL
        let name = URLComponents(string: trimmed)?.host ?? "Subscription"
        let sub = Subscription(name: name, url: trimmed, engine: .singBox)
        subscriptions.append(sub)
        save()
        await refreshSubscription(sub.id)
    }

    func refreshSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }),
              !subscriptions[idx].isManual
        else { return }

        let urlString = subscriptions[idx].url

        // Strategy 1: fetch raw URL → decode base64 → parse vless:// URIs
        if let servers = await fetchAndParseURIs(urlString), !servers.isEmpty {
            subscriptions[idx].engine = .singBox
            subscriptions[idx].servers = servers
            subscriptions[idx].lastUpdated = Date()
            save()
            return
        }

        // Strategy 2: try ?format=singbox, then ?format=xray
        for engine in [Engine.singBox, .xray] {
            if let servers = await fetchFormattedConfig(urlString, engine: engine), !servers.isEmpty {
                subscriptions[idx].engine = engine
                subscriptions[idx].servers = servers
                subscriptions[idx].lastUpdated = Date()
                save()
                return
            }
        }
    }

    func refreshAll() async {
        for sub in subscriptions where !sub.isManual {
            await refreshSubscription(sub.id)
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

    private func fetchFormattedConfig(_ urlString: String, engine: Engine) async -> [Server]? {
        guard var components = URLComponents(string: urlString) else { return nil }
        var items = components.queryItems ?? []
        let format = engine == .singBox ? "singbox" : "xray"
        items.removeAll { $0.name == "format" }
        items.append(URLQueryItem(name: "format", value: format))
        components.queryItems = items
        guard let urlStr = components.string else { return nil }

        guard let data = await fetchData(from: urlStr),
              let json = String(data: data, encoding: .utf8)
        else { return nil }

        let servers = engine == .singBox ? parseSingBox(json) : parseXray(json)
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

        let transportType = params["type"] ?? "tcp"
        let needsXray = transportType == "xhttp" || transportType == "splithttp"

        let config: String
        let engine: Engine
        if needsXray {
            config = buildXrayConfig(protocol: "vless", uuid: uuid, host: host, port: port, params: params, tag: name)
            engine = .xray
        } else {
            config = buildSingBoxConfig(protocol: "vless", uuid: uuid, host: host, port: port, params: params, tag: name)
            engine = .singBox
        }

        return Server(name: name, protocolType: "vless", address: "\(host):\(port)", config: config, engine: engine)
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
        let tls = obj["tls"] as? String ?? ""
        let sni = obj["sni"] as? String ?? ""

        var outbound: [String: Any] = [
            "type": "vmess",
            "tag": name,
            "server": host,
            "server_port": port,
            "uuid": id,
            "security": "auto",
            "alter_id": 0
        ]

        if net == "ws" {
            let wsPath = obj["path"] as? String ?? "/"
            let wsHost = obj["host"] as? String ?? ""
            outbound["transport"] = [
                "type": "ws",
                "path": wsPath,
                "headers": ["Host": wsHost]
            ] as [String: Any]
        }

        if tls == "tls" {
            outbound["tls"] = [
                "enabled": true,
                "server_name": sni.isEmpty ? host : sni
            ] as [String: Any]
        }

        let config = buildSingBoxConfigFromOutbound(outbound)
        return Server(name: name, protocolType: "vmess", address: "\(host):\(port)", config: config)
    }

    // MARK: - sing-box config builder from URI params

    private func buildSingBoxConfig(protocol proto: String, uuid: String, host: String, port: Int, params: [String: String], tag: String) -> String {
        var outbound: [String: Any] = [
            "type": proto,
            "tag": tag,
            "server": host,
            "server_port": port,
            "uuid": uuid
        ]

        // Flow (for VLESS XTLS)
        if let flow = params["flow"], !flow.isEmpty {
            outbound["flow"] = flow
        }

        // Transport
        let transportType = params["type"] ?? "tcp"
        switch transportType {
        case "ws":
            var transport: [String: Any] = ["type": "ws"]
            if let path = params["path"] { transport["path"] = path }
            if let wsHost = params["host"], !wsHost.isEmpty {
                transport["headers"] = ["Host": wsHost]
            }
            outbound["transport"] = transport
        case "grpc":
            var transport: [String: Any] = ["type": "grpc"]
            if let sn = params["serviceName"] { transport["service_name"] = sn }
            outbound["transport"] = transport
        case "xhttp", "splithttp":
            var transport: [String: Any] = ["type": "splithttp"]
            if let path = params["path"] { transport["path"] = path }
            if let xHost = params["host"], !xHost.isEmpty {
                transport["host"] = xHost
            }
            if let mode = params["mode"], !mode.isEmpty {
                transport["mode"] = mode
            }
            outbound["transport"] = transport
        case "httpupgrade":
            var transport: [String: Any] = ["type": "httpupgrade"]
            if let path = params["path"] { transport["path"] = path }
            if let hHost = params["host"], !hHost.isEmpty {
                transport["host"] = hHost
            }
            outbound["transport"] = transport
        default:
            break // tcp — no transport block needed
        }

        // TLS / Reality
        let security = params["security"] ?? ""
        switch security {
        case "tls":
            var tls: [String: Any] = ["enabled": true]
            if let sni = params["sni"], !sni.isEmpty { tls["server_name"] = sni }
            if let fp = params["fp"], !fp.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fp] as [String: Any]
            }
            if let alpn = params["alpn"], !alpn.isEmpty {
                tls["alpn"] = alpn.components(separatedBy: ",")
            }
            outbound["tls"] = tls
        case "reality":
            var tls: [String: Any] = [
                "enabled": true,
                "reality": ["enabled": true] as [String: Any]
            ]
            if let sni = params["sni"], !sni.isEmpty { tls["server_name"] = sni }
            if let fp = params["fp"], !fp.isEmpty {
                tls["utls"] = ["enabled": true, "fingerprint": fp] as [String: Any]
            }

            var reality: [String: Any] = ["enabled": true]
            if let pbk = params["pbk"] { reality["public_key"] = pbk }
            if let sid = params["sid"] { reality["short_id"] = sid }
            tls["reality"] = reality

            outbound["tls"] = tls
        default:
            break
        }

        return buildSingBoxConfigFromOutbound(outbound)
    }

    private func buildSingBoxConfigFromOutbound(_ outbound: [String: Any]) -> String {
        let tag = outbound["tag"] as? String ?? "proxy"
        let config: [String: Any] = [
            "log": ["level": "info"],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    "auto_route": true,
                    "strict_route": true
                ] as [String: Any]
            ],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"] as [String: Any]
            ],
            "route": [
                "auto_detect_interface": true,
                "default_domain_resolver": ["server": "local"] as [String: Any],
                "final": tag,
                "rules": [
                    ["action": "hijack-dns", "protocol": "dns"] as [String: Any],
                    ["action": "sniff"] as [String: Any]
                ]
            ] as [String: Any],
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": tag] as [String: Any],
                    ["tag": "local", "type": "tls", "server": "8.8.8.8"] as [String: Any]
                ],
                "strategy": "prefer_ipv4",
                "independent_cache": true
            ] as [String: Any]
        ]
        return serializeJSON(config) ?? "{}"
    }

    // MARK: - Xray config builder from URI params

    private func buildXrayConfig(protocol proto: String, uuid: String, host: String, port: Int, params: [String: String], tag: String) -> String {
        let transportType = params["type"] ?? "tcp"

        var vnext: [String: Any] = [
            "address": host,
            "port": port,
            "users": [
                [
                    "id": uuid,
                    "encryption": params["encryption"] ?? "none",
                    "flow": params["flow"] ?? ""
                ] as [String: Any]
            ]
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
                    "port": 10808,
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

    // MARK: - sing-box JSON parsing (for ?format=singbox)

    private static let vpnTypesSingBox: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "shadowtls",
        "hysteria", "hysteria2", "tuic", "wireguard"
    ]

    private static let serviceTypesSingBox: Set<String> = [
        "direct", "block", "dns", "selector", "urltest"
    ]

    private func parseSingBox(_ json: String) -> [Server] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]]
        else { return [] }

        let serviceOutbounds = outbounds.filter {
            guard let type = $0["type"] as? String else { return false }
            return Self.serviceTypesSingBox.contains(type)
        }

        var servers: [Server] = []
        for ob in outbounds {
            guard let type = ob["type"] as? String,
                  Self.vpnTypesSingBox.contains(type) else { continue }

            let name = ob["tag"] as? String ?? type
            let host = ob["server"] as? String ?? "?"
            let port = ob["server_port"] as? Int ?? 0
            let address = "\(host):\(port)"

            var modifiedRoot = root
            modifiedRoot["outbounds"] = [ob] + serviceOutbounds
            let config = serializeJSON(modifiedRoot) ?? ""

            servers.append(Server(name: name, protocolType: type, address: address, config: config))
        }
        return servers
    }

    // MARK: - xray JSON parsing (for ?format=xray)

    private static let vpnTypesXray: Set<String> = [
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

            var modifiedRoot = root
            modifiedRoot["outbounds"] = [ob] + serviceOutbounds
            let config = serializeJSON(modifiedRoot) ?? ""

            servers.append(Server(name: name, protocolType: proto, address: address, config: config))
        }
        return servers
    }

    // MARK: - Manual config

    func addManualConfig(name: String, json: String) {
        var sub = Subscription(name: name, isManual: true, engine: .singBox)

        let singBoxServers = parseSingBox(json)
        let xrayServers = parseXray(json)
        if !singBoxServers.isEmpty {
            sub.engine = .singBox
            sub.servers = singBoxServers
        } else if !xrayServers.isEmpty {
            sub.engine = .xray
            sub.servers = xrayServers
        } else {
            sub.servers = [Server(name: name, protocolType: "custom", address: "—", config: json)]
        }

        sub.lastUpdated = Date()
        subscriptions.append(sub)
        save()
    }

    // MARK: - Helpers

    private func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
