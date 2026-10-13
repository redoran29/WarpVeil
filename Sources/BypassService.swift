import Foundation

enum BypassService {

    // MARK: - sing-box config injection

    // Goes into whichever sing-box holds the TUN: the server config, or the wrapper in front
    // of xray. A TUN connection arrives as an IP destination and its domain exists only after
    // the sniff action, so the rule has to sit after the first `sniff` — before it, it never
    // matches. Only an unconditional one counts: a sniff limited to an inbound or a protocol may
    // never run for the TUN's connections, or never read their SNI.
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
        if let existing = rules.firstIndex(where: isUnconditionalSniff) {
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

    private static func isUnconditionalSniff(_ rule: [String: Any]) -> Bool {
        (rule["action"] as? String) == "sniff" && Set(rule.keys).isSubset(of: ["action", "timeout"])
    }

    // MARK: - TUN address families

    // The TUN mirrors the host's IP families, whatever the stored config says. With no global
    // IPv6 on the host, an IPv6 address here makes macOS hand out AAAA records and a bypassed
    // destination dials direct over IPv6 into "no route to host". With one, the TUN needs it:
    // sing-tun routes IPv6 into the tunnel only when the TUN has an IPv6 address, and without
    // that IPv6 leaves past the VPN.
    static func fitTunToHost(_ json: String, hostHasIPv6: Bool) -> String {
        guard var root = parseJSON(json),
              var inbounds = root["inbounds"] as? [[String: Any]] else { return json }
        for i in inbounds.indices where (inbounds[i]["type"] as? String) == "tun" {
            var addresses = (inbounds[i]["address"] as? [String] ?? []).filter { !$0.contains(":") }
            if hostHasIPv6 { addresses.append("fdfe:dcba:9876::1/126") }
            inbounds[i]["address"] = addresses
        }
        root["inbounds"] = inbounds
        return serializeJSON(root) ?? json
    }

    // MARK: - Domain input

    // Accepts a bare domain or a pasted URL and returns what a sniffed SNI looks like:
    // lowercase ASCII (punycode for IDN), no scheme, port, path, wildcard or trailing dot.
    // nil for anything that is not a DNS name — IP literals included, which `domain_suffix`
    // cannot match. A bare TLD counts: `ru` covers every .ru site.
    static func normalizeDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: url)?.encodedHost?.lowercased() else { return nil }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        return isDomainName(host) ? host : nil
    }

    // Splits pasted text on whitespace, and on commas outside a URL — its path or query may carry
    // them. The tokens that do not normalize come back so the caller can leave them in the field.
    static func parseDomains(_ text: String) -> (domains: [String], rejected: [String]) {
        var domains: [String] = []
        var rejected: [String] = []
        for word in text.components(separatedBy: .whitespacesAndNewlines) {
            let tokens = word.contains("://") ? [word] : word.components(separatedBy: ",")
            for token in tokens where !token.isEmpty {
                guard let domain = normalizeDomain(token) else {
                    rejected.append(token)
                    continue
                }
                if !domains.contains(domain) { domains.append(domain) }
            }
        }
        return (domains, rejected)
    }

    private static func isDomainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.count <= 253, let last = labels.last, last.count >= 2,
              !last.allSatisfy(\.isNumber) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count)
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
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
