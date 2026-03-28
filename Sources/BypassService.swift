import Foundation

enum BypassService {

    // MARK: - sing-box config injection

    static func injectSingBox(_ json: String, domains: [String]) -> String {
        guard !domains.isEmpty,
              var root = parseJSON(json) else { return json }

        // 1. Ensure "direct" outbound exists
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let hasDirectOutbound = outbounds.contains { ($0["tag"] as? String) == "direct" }
        if !hasDirectOutbound {
            outbounds.append(["type": "direct", "tag": "direct"])
            root["outbounds"] = outbounds
        }

        // 2. Add bypass routing rule at the top
        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [[String: Any]] ?? []
        let bypassRule: [String: Any] = [
            "domain_suffix": domains,
            "outbound": "direct"
        ]
        rules.insert(bypassRule, at: 0)
        route["rules"] = rules
        root["route"] = route

        // 3. Enable sniffing on inbounds so sing-box can see domain names
        if var inbounds = root["inbounds"] as? [[String: Any]] {
            for i in inbounds.indices {
                inbounds[i]["sniff"] = true
                inbounds[i]["sniff_override_destination"] = false
            }
            root["inbounds"] = inbounds
        }

        // 4. Set log level to "debug" so routing decisions are visible
        var log = root["log"] as? [String: Any] ?? [:]
        log["level"] = "debug"
        root["log"] = log

        return serializeJSON(root) ?? json
    }

    // MARK: - xray config injection

    static func injectXray(_ json: String, domains: [String]) -> String {
        guard !domains.isEmpty,
              var root = parseJSON(json) else { return json }

        // 1. Ensure "direct" outbound exists
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let hasDirectOutbound = outbounds.contains {
            ($0["tag"] as? String) == "direct" || ($0["protocol"] as? String) == "freedom"
        }
        if !hasDirectOutbound {
            outbounds.append(["protocol": "freedom", "tag": "direct"])
            root["outbounds"] = outbounds
        }

        // 2. Add bypass routing rule at the top
        var routing = root["routing"] as? [String: Any] ?? [:]
        var rules = routing["rules"] as? [[String: Any]] ?? []
        let bypassRule: [String: Any] = [
            "type": "field",
            "domain": domains,
            "outboundTag": "direct"
        ]
        rules.insert(bypassRule, at: 0)
        routing["rules"] = rules
        root["routing"] = routing

        // 3. Set log level to at least "info"
        var log = root["log"] as? [String: Any] ?? [:]
        let currentLevel = log["loglevel"] as? String ?? ""
        if currentLevel != "debug" {
            log["loglevel"] = "info"
        }
        root["log"] = log

        return serializeJSON(root) ?? json
    }

    // MARK: - JSON helpers

    private static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func serializeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}
