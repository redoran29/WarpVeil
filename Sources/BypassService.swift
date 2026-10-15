import Foundation

enum BypassService {

    // MARK: - sing-box config injection

    // Goes into the sing-box that holds the TUN in front of xray. A TUN connection arrives as an
    // IP destination and its domain exists only after the sniff action, so the rule has to sit
    // after the first `sniff` — before it, it never matches. Only an unconditional one counts: a
    // sniff limited to an inbound or a protocol may never run for the TUN's connections, or never
    // read their SNI.
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

    // MARK: - xray server

    // The proxy outbound's address as the subscription wrote it: an IP literal or a name.
    // vless and vmess carry it in `vnext`, trojan, shadowsocks and socks in `servers`.
    static func xrayServerHost(_ json: String) -> String? {
        guard let root = parseJSON(json),
              let outbounds = root["outbounds"] as? [[String: Any]] else { return nil }
        return outbounds.lazy.compactMap(serverAddress).first
    }

    // xray dials its server by name; the wrapper in front of it routes that dial by address.
    // Pinning the name in xray's own DNS to the addresses the app resolved makes both engines
    // use the same ones — xray's own lookup could answer differently (round-robin, a CDN).
    static func pinXrayServer(_ json: String, host: String, addresses: [String]) -> String {
        guard !addresses.isEmpty, var root = parseJSON(json),
              var outbounds = root["outbounds"] as? [[String: Any]],
              let index = outbounds.firstIndex(where: { serverAddress($0) == host }) else { return json }
        var dns = root["dns"] as? [String: Any] ?? [:]
        var hosts = dns["hosts"] as? [String: Any] ?? [:]
        hosts[host] = addresses
        dns["hosts"] = hosts
        root["dns"] = dns
        var streamSettings = outbounds[index]["streamSettings"] as? [String: Any] ?? [:]
        var sockopt = streamSettings["sockopt"] as? [String: Any] ?? [:]
        sockopt["domainStrategy"] = "UseIP"
        streamSettings["sockopt"] = sockopt
        outbounds[index]["streamSettings"] = streamSettings
        root["outbounds"] = outbounds
        return serializeJSON(root) ?? json
    }

    private static func serverAddress(_ outbound: [String: Any]) -> String? {
        guard let settings = outbound["settings"] as? [String: Any] else { return nil }
        let first = (settings["vnext"] as? [[String: Any]])?.first
            ?? (settings["servers"] as? [[String: Any]])?.first
        return first?["address"] as? String
    }

    // getaddrinfo blocks, so callers run it off the main actor. AI_ADDRCONFIG drops the
    // families the host has no address for — what every app's own lookup gets.
    static func resolveAddresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if !addresses.contains(address) { addresses.append(address) }
            }
            node = info.pointee.ai_next
        }
        return addresses
    }

    // MARK: - Root safety

    // The top-level sections a root sing-box may get; ProcessManager.configPolicy refuses the rest.
    static let configSections = ["log", "dns", "ntp", "inbounds", "outbounds", "endpoints", "route", "experimental"]

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
