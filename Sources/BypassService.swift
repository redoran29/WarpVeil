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

    // MARK: - Domain input

    // Accepts a bare domain or a pasted URL and returns what a sniffed SNI looks like:
    // lowercase ASCII (punycode for IDN), no scheme, port, path, wildcard or trailing dot.
    // nil for anything that is not a DNS name with at least one dot — IP literals included,
    // which `domain_suffix` cannot match.
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

    // Splits pasted text on whitespace and commas; the tokens that do not normalize come back
    // so the caller can leave them in the field.
    static func parseDomains(_ text: String) -> (domains: [String], rejected: [String]) {
        var domains: [String] = []
        var rejected: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            guard let domain = normalizeDomain(token) else {
                rejected.append(token)
                continue
            }
            if !domains.contains(domain) { domains.append(domain) }
        }
        return (domains, rejected)
    }

    private static func isDomainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253,
              let last = labels.last, !last.allSatisfy(\.isNumber) else { return false }
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
