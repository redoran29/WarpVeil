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
        (rule["action"] as? String) == "sniff" && Set(rule.keys).isSubset(of: ["type", "action", "timeout"])
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
            // sing-box takes a single string here as well as a list.
            let stored = inbounds[i]["address"] as? [String] ?? (inbounds[i]["address"] as? String).map { [$0] } ?? []
            var addresses = stored.filter { !$0.contains(":") }
            if hostHasIPv6 { addresses.append("fdfe:dcba:9876::1/126") }
            inbounds[i]["address"] = addresses
        }
        root["inbounds"] = inbounds
        return serializeJSON(root) ?? json
    }

    // MARK: - Root safety

    // The root sing-box refuses a config that names a file (ProcessManager.configPolicy).
    // Provider templates often carry a few such keys the tunnel does not need — a cache file, a
    // dashboard, a log file — so those are dropped here instead of failing the connect. Anything
    // else that touches a file still fails it, by name, in Logs.
    static func dropUnneededFileKeys(_ json: String) -> (json: String, dropped: [String]) {
        guard var root = parseJSON(json) else { return (json, []) }
        let sections: Set = ["log", "dns", "ntp", "inbounds", "outbounds", "endpoints", "route", "experimental"]
        var dropped = root.keys.filter { !sections.contains($0) }.sorted()
        dropped.forEach { root[$0] = nil }
        if var log = root["log"] as? [String: Any] {
            dropped += removeKeys(["output"], from: &log).map { "log." + $0 }
            root["log"] = log
        }
        if var experimental = root["experimental"] as? [String: Any] {
            dropped += removeKeys(["cache_file"], from: &experimental).map { "experimental." + $0 }
            if var api = experimental["clash_api"] as? [String: Any] {
                let dashboard: Set = ["external_ui", "external_ui_download_url", "external_ui_download_detour"]
                dropped += removeKeys(dashboard, from: &api).map { "experimental.clash_api." + $0 }
                experimental["clash_api"] = api
            }
            root["experimental"] = experimental
        }
        if var route = root["route"] as? [String: Any] {
            dropped += removeKeys(["geoip", "geosite"], from: &route).map { "route." + $0 }
            root["route"] = route
        }
        guard !dropped.isEmpty else { return (json, []) }
        return (serializeJSON(root) ?? json, dropped)
    }

    // Case-insensitive, the way sing-box matches field names.
    private static func removeKeys(_ names: Set<String>, from object: inout [String: Any]) -> [String] {
        let matches = object.keys.filter { names.contains($0.lowercased()) }.sorted()
        matches.forEach { object[$0] = nil }
        return matches
    }

    // MARK: - Domain input

    // Accepts a bare domain or a pasted URL and returns the entry as stored and as handed to
    // `domain_suffix`, in the form a sniffed SNI takes: lowercase ASCII (punycode for IDN), no
    // scheme, port, path, wildcard or trailing dot. A whole TLD keeps its dot (`.ru`) and has to
    // be typed with it: a bare word from pasted text, or a typo like `youtubecom`, would
    // otherwise route a whole zone past the VPN. nil for anything that is not a DNS name — IP
    // literals included, which `domain_suffix` cannot match.
    static func normalizeDomain(_ input: String) -> String? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stripped before parsing: IDNA rejects a host that starts with a dot.
        var namesZone = trimmed.hasPrefix(".") || trimmed.hasPrefix("*.")
        if trimmed.hasPrefix("*.") { trimmed.removeFirst(2) }
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        // One wildcard only: a second one is a typo, and stripping it too would widen it to a zone.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("*") else { return nil }
        let url = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: url)?.encodedHost?.lowercased() else { return nil }
        if host.hasPrefix("*.") {
            host.removeFirst(2)
            namesZone = true
        }
        while host.hasSuffix(".") { host.removeLast() }
        guard isDomainName(host) else { return nil }
        if host.contains(".") { return host }
        return namesZone ? "." + host : nil
    }

    // Splits pasted text on whitespace and commas; the tokens that do not normalize come back
    // so the caller can leave them in the field. A URL with commas in its path leaves its tail
    // there too — visible, where a smarter split lost or invented domains silently.
    static func parseDomains(_ text: String) -> (domains: [String], rejected: [String]) {
        var domains: [String] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for token in tokens(in: text) {
            guard let domain = normalizeDomain(token) else {
                rejected.append(token)
                continue
            }
            if seen.insert(domain).inserted { domains.append(domain) }
        }
        return (domains, rejected)
    }

    private static func tokens(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        return text.components(separatedBy: separators).filter { !$0.isEmpty }
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
