import Foundation

@Observable
@MainActor
final class SubscriptionService {
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

    init() {
        load()
    }

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

    func refreshSubscription(_ id: UUID) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }),
              !subscriptions[idx].isManual,
              let url = buildURL(for: subscriptions[idx])
        else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let servers = parseConfig(json, engine: subscriptions[idx].engine)
            subscriptions[idx].servers = servers
            subscriptions[idx].lastUpdated = Date()
            save()
        } catch {
            // Network error — keep existing servers
        }
    }

    func refreshAll() async {
        for sub in subscriptions where !sub.isManual {
            await refreshSubscription(sub.id)
        }
    }

    private func buildURL(for sub: Subscription) -> URL? {
        guard var components = URLComponents(string: sub.url) else { return nil }
        var items = components.queryItems ?? []
        let format = sub.engine == .singBox ? "singbox" : "xray"
        items.removeAll { $0.name == "format" }
        items.append(URLQueryItem(name: "format", value: format))
        components.queryItems = items
        return components.url
    }

    private func parseConfig(_ json: String, engine: Engine) -> [Server] {
        switch engine {
        case .singBox: return parseSingBox(json)
        case .xray: return parseXray(json)
        }
    }

    // MARK: - sing-box parsing

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

    // MARK: - xray parsing

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

    func addManualConfig(name: String, json: String, engine: Engine) {
        var sub = Subscription(name: name, isManual: true, engine: engine)
        sub.servers = parseConfig(json, engine: engine)
        if sub.servers.isEmpty {
            sub.servers = [Server(name: name, protocolType: "custom", address: "—", config: json)]
        }
        sub.lastUpdated = Date()
        subscriptions.append(sub)
        save()
    }

    // MARK: - Helpers

    private func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
