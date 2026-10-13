import Foundation

enum BypassService {

    // MARK: - sing-box config injection

    // Goes into whichever sing-box holds the TUN: the server config, or the wrapper in front
    // of xray. A TUN connection arrives as an IP destination and its domain exists only after
    // the sniff action, so the rule has to sit after the first `sniff` — before it, it never
    // matches.
    static func injectSingBox(_ json: String, domains: [String]) -> String {
        guard !domains.isEmpty,
              var root = parseJSON(json) else { return json }

        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let hasDirectOutbound = outbounds.contains { ($0["tag"] as? String) == "direct" }
        if !hasDirectOutbound {
            outbounds.append(["type": "direct", "tag": "direct"])
            root["outbounds"] = outbounds
        }

        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [[String: Any]] ?? []
        let sniffIndex: Int
        if let existing = rules.firstIndex(where: { ($0["action"] as? String) == "sniff" }) {
            sniffIndex = existing
        } else {
            rules.insert(["action": "sniff"], at: 0)
            sniffIndex = 0
        }
        let bypassRule: [String: Any] = [
            "action": "route",
            "outbound": "direct",
            "domain_suffix": domains
        ]
        rules.insert(bypassRule, at: sniffIndex + 1)
        route["rules"] = rules
        root["route"] = route

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
