# Routing bypass: a rule that matches, an Add button, input the sniffer can use

Status: implemented — steps 1–5 committed; live checks of Verification 4 run after deploy. Written against `d9a5856`, macOS 27.0.1 (Darwin 27.0.0), Xcode 27.0, bundled
sing-box 1.14.0 and Xray 26.3.27, deployment target 14.0, `CFBundleShortVersionString` = `1.2`.

## Owner's ask

"Fix bypass — there's no Add button — and check all of its functionality." Bypass is the Routing
page: a toggle and a list of domains routed outside the tunnel. Checking it found that the rule
the app injects never matches, so the feature has been dead in both topologies, and that the TUN's
IPv6 address will break bypassed destinations the moment the rule starts working.

Out of scope and untouched: `run.sh`/`stop.sh` (`ProcessManager.runShContent`/`stopShContent` —
a byte change there reads the owner's installed passwordless scripts as stale), the order of
`hijack-dns`/`sniff` in the config builders, `AppState.bypassDomains`' storage format (one domain
per line in `@AppStorage("bypassDomains")`), `PingService`, `project.pbxproj` (no new files).

## Verified facts

Checked in this run on this machine, not recalled. Line numbers are against `d9a5856`.

### Code

- `Sources/RoutingView.swift:38-39` — the input row is `TextField("example.com", text: $newDomain)
  .onSubmit(addDomain)`, nothing else. In a grouped `Form` the title renders as the row's label,
  so the page shows the text "example.com" and an empty field; nothing says Enter adds.
  `:59-64` `addDomain()` trims, lowercases, skips duplicates, appends to `bypassDomainsRaw`.
  `:44-45` both `@AppStorage` keys trigger `scheduleReconnect()` (`:50-57`, 2 s debounce →
  `app.routingChanged()`).
- `Sources/BypassService.swift:7-40` `injectSingBox(_:domains:)`: ensures a `direct` outbound
  (`:12-17`), inserts the bypass rule at index 0 (`:27`), then appends `{"action":"sniff"}` at the
  **end** when none exists (`:31-37`). `:44-79` `injectXray(_:domains:)`: a `routing.rules` domain
  rule at index 0 and — side effect — `log.loglevel` forced to `info` unless `debug` (`:70-76`),
  both only when domains are non-empty.
- `Sources/ProcessManager.swift:336-343` `connect` routes each engine's config through the
  matching injector; `:348-354` builds the TUN wrapper with `buildTunWrapperConfig(serverIP:
  bypassDomains:)`, which puts the bypass rule at index 0 of the wrapper (`:496-502`), **before**
  its `hijack-dns`/`sniff` (`:473-476`); the server-IP rule is inserted at 0 as well (`:480-494`).
  `:147-149` `lastConnection` keeps `bypassDomains`; `:545-563` `reconnect(bypassDomains:)` guards
  only on `isRunning` and `lastConnection`, then tears down and reconnects unconditionally.
  `:356-358` logs `[Bypass] N domain(s) will route direct`. `:510` the wrapper's TUN address is
  `["172.19.0.1/30", "fdfe:dcba:9876::1/126"]`.
- `Sources/SubscriptionService.swift:492-529` `buildSingBoxConfigFromOutbound`: rules
  `[hijack-dns, sniff]` (`:513-516`), the same TUN address (`:501`). `:649-680` `parseSingBox`
  stores the **user's whole config** with the outbounds reduced, so a `?format=singbox` feed or a
  manual JSON (`:731-754`) can carry any `route.rules` — a conditioned `sniff`, no `sniff`, no
  `route` at all. `:531-647` `buildXrayConfig`: `routing.rules: []` (`:631`).
- `Sources/AppState.swift:49-54` `bypassDomains` splits the raw string on `\n` and trims;
  `:62-65` `activeBypassDomains` is `[]` while the toggle is off; `:124-127` `routingChanged()`
  → `pm.reconnect(bypassDomains: activeBypassDomains)`.
- `Sources/PingService.swift:366-371` `primaryInterface()` reads `PrimaryInterface` from
  `SCDynamicStore` `State:/Network/Global/IPv4`; `:294` pins outbounds with `bind_interface`.
- Canon: `CLAUDE.md:72` architecture line for `BypassService.swift`; `:97-100` "Two connection
  topologies"; `:244-245` Runtime Files calls the xray file "injected xray config"; `:254` gotcha
  "sing-box and xray have different config formats — `BypassService` handles each separately".
  `README.md:75` "Domain bypass config injection".

### Engine

- **A domain rule before `sniff` never matches a TUN connection.** The main session verified it
  with the bundled sing-box 1.14.0, a `mixed` inbound and `curl --socks5` (local resolution, so
  the engine gets an IP destination — exactly how TUN connections arrive): rule before `sniff` →
  the connection went to the proxy outbound; rule after `sniff` → direct. Re-verified in this run
  on the app's own wrapper shape, end to end, see "Validation of this plan".
- `domain_suffix: ["example.com"]` matches `example.com` and `www.example.com`, not
  `notexample.com`: an entry covers its subdomains.
- sing-box 1.14's DNS sniffer sets only `metadata.Protocol = dns`, never `Domain`
  (`common/sniff/dns.go` at v1.14.0), so a domain rule placed right after `sniff` cannot pull a
  DNS packet away from a later `hijack-dns`.
- Sniffed SNI is ASCII/punycode. `URLComponents(string: "https://госуслуги.рф")?.encodedHost`
  → `xn--c1aapkosapc.xn--p1ai` on this macOS; `URL.host()` percent-encodes instead (wrong).
  `URLComponents` also strips scheme, port and path: `https://www.YouTube.com:443/watch?v=1` →
  `www.YouTube.com`. `*.example.com`, `.example.com`, `example.com.` come back as-is;
  `a b.com` → nil. All of this is asserted by the harness below.
- `Binaries/sing-box check` accepts the injected server shape and the injected wrapper shape (TUN
  inbound included); `check` builds the instance without starting it.

### Machine

- Live right now: an Xcode-launched Debug copy (pid 1858) in the **xray topology** — root `xray`
  (99354) and root `sing-box` wrapper (99399). `$TMPDIR/warpveil-singbox-1858.json` has rules
  `[route ip_cidr → direct, hijack-dns, sniff]` — the owner's domain list is empty, so no bypass
  rule is present. `bypassEnabled` is unset in `com.warpveil.app` (defaults to on). Passwordless
  is installed and in use.
- `scutil` → `PrimaryInterface : en0`, `Router : 192.168.1.1`. en0 has only a link-local IPv6;
  with the tunnel up the system resolver hands out AAAA (`dscacheutil -q host -a name ya.ru` →
  `ipv6_address: 2a02:6b8::2:242`) because the TUN's ULA makes macOS consider IPv6 usable and
  `auto_route` installs an IPv6 default route into the tunnel. Once bypass works, a bypassed
  destination reached over IPv6 is routed `direct`, the direct dial has no IPv6 route and fails
  with `no route to host`; apps without a Happy-Eyeballs fallback (Yandex Music, own DoH — the
  2026-06-15 debug) half-load or die. `dns.strategy: ipv4_only` does not help: app-private
  resolvers never pass through sing-box. What fixed it then: an IPv4-only TUN address.
- The project builds clean under Xcode 27.0 with `xcodebuild … -configuration Debug` into a
  scratch derived-data dir (baseline, before any change).

## Design

**D1. One injection point, placed after `sniff`.** `BypassService.injectSingBox` finds the first
rule whose `action` is `sniff` and inserts the bypass rule right after it. A config with no `sniff`
gets `{"action":"sniff"}` at index 0 and the bypass rule at index 1. The "append sniff at the end"
step is gone: a `sniff` after a terminating `route` runs for nothing. The "ensure a `direct`
outbound" step stays. User rules before the first `sniff` keep running first — a config whose
own rules already send something direct or block it is not second-guessed.

**D2. The xray topology uses the same function on the wrapper.** `buildTunWrapperConfig` loses
its `bypassDomains` parameter; `connect` runs the built wrapper through `injectSingBox` and writes
the xray config as the subscription produced it. `injectXray` is deleted: the wrapper is the only
router in that topology (canon), xray gets IP destinations over SOCKS and its domain rule never
saw a domain. Behaviour change that comes with it: xray's `loglevel` is no longer forced to `info`
when the list is non-empty — our own `buildXrayConfig` sets `info` anyway, and a pasted xray config
keeps what it says.

**D3. Normalization is two pure statics on `BypassService`.** `normalizeDomain(_:) -> String?`
takes a bare domain or a pasted URL, prepends `https://` when there is no scheme, reads
`URLComponents(...).encodedHost` (punycode for IDN), lowercases, strips a leading `*.` or `.`
and a trailing `.`, and accepts only a DNS name: ASCII letters, digits and hyphens, no label
starting or ending with `-`, labels of 1–63, at most 253 in all, **at least two labels, and the
last one not all digits** — which rejects IPv4 literals, and `[::1]`/`::1` fail the character
rule. `domain_suffix` cannot match an IP, so one stored would silently do nothing.
`parseDomains(_:) -> (domains: [String], rejected: [String])` splits on whitespace and commas,
normalizes each token, drops duplicates within the paste and returns the tokens that failed so the
view can leave them in the field. Both live in `BypassService` so the `swiftc` harness compiles
the real file; `BypassService` imports only `Foundation`.

**D4. The input row.** `HStack { TextField("Domain", text:, prompt: Text("example.com"))
.labelsHidden().onSubmit(addDomains); Button("Add", action: addDomains).disabled(!canAdd) }` as
the last row of the Domains section, so the section is never empty (canon gotcha). `canAdd` is
`!parseDomains(newDomain).domains.isEmpty` — the button is live as soon as one token normalizes;
if every token is a duplicate, Add consumes them and adds nothing. Enter calls the same function
and reaches it without passing the button's disabled state, so `addDomains` has to be correct on
empty input (it is: nothing added, the field keeps its rejected tokens). The section gets a
footer caption: subdomains are included, a URL or several domains at once are accepted. The caption
is `Text(verbatim:)`: as a literal it is parsed as a `LocalizedStringKey` and macOS turns the bare
`www.example.com` into a clickable link (seen on the dev build, reproduced with `ImageRenderer`). The
`Section("Domains")` becomes `Section { } header: { Text("Domains") } footer: { … }`.

**D5. Reconnect only when the effective list changed.** The guard goes into
`ProcessManager.reconnect(bypassDomains:)` — `lastConnection` is private there and already holds
the list the running engines were started with. Toggling bypass with an empty list, or editing
the list while the toggle is off, then costs nothing; without passwordless that was two admin
prompts for a no-op.

**D6. IPv4-only TUN address**, in both builders, as its own commit — a behaviour change to the
tunnel independent of the bypass code, so it has to be revertable on its own. The IPv6 half of
`auto_route` disappears with the address: no IPv6 default route into the tunnel, no global IPv6
source address, macOS stops handing out AAAA, everything goes IPv4.

Not chosen: re-normalizing entries already stored (the owner's list is empty; a legacy entry is
removed and re-added by hand); moving the 2 s debounce out of `RoutingView` (the parity plan does
that when it has a second caller); a migration of the raw string format; an `@Observable` domain
list on `AppState` (the `@AppStorage` stays where the editing is — canon).

## Steps

Each step compiles on its own and is one commit. Each was applied to a scratch copy of the repo
in this order and built with `xcodebuild` after every step — see "Validation of this plan".

### 1. Engine: the bypass rule after `sniff`, one injector for both topologies

Commit: `Put the bypass rule after sniff in the sing-box that holds the TUN`.

`Sources/BypassService.swift` — replace `injectSingBox` and delete `injectXray` (the `// MARK: -
xray config injection` section goes entirely); `parseJSON`/`serializeJSON` stay:

```swift
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
```

`Sources/ProcessManager.swift`:

- `connect` (`:340-343`): the `.xray` case becomes `finalConfig = config` (the xray config is
  written as-is). The wrapper block (`:348-354`) becomes:

```swift
        // The wrapper is the only sing-box in the xray topology, so the bypass rule goes there:
        // xray gets IP destinations over SOCKS and never sees a domain.
        if engine == .xray {
            let wrapper = Self.buildTunWrapperConfig(serverIP: Self.extractServerIP(from: config))
            let finalWrapper = BypassService.injectSingBox(wrapper, domains: bypassDomains)
            FileManager.default.createFile(atPath: singboxConfigFile, contents: finalWrapper.data(using: .utf8),
                                            attributes: [.posixPermissions: 0o600])
        }
```

- `buildTunWrapperConfig(serverIP: String?, bypassDomains: [String])` (`:472`) →
  `buildTunWrapperConfig(serverIP: String?)`; delete the `if !bypassDomains.isEmpty { … }` block
  (`:496-502`). The `rules` it builds stay `[server-IP → direct (when the server is an IP
  literal; `domain_suffix` otherwise), hijack-dns, sniff]`.
- `lastConnection`, `handleWake`, `reconnect`, the `[Bypass] N domain(s) will route direct` line
  and both run scripts are untouched.

Resulting rule order, server shape: `hijack-dns, sniff, bypass→direct`. Wrapper shape:
`server-IP→direct, hijack-dns, sniff, bypass→direct`.

### 2. UI: Add button, placeholder, normalization, multi-paste, caption

Commit: `Add an Add button and domain normalization to the Routing page`.

`Sources/BypassService.swift` — add between the injection section and `// MARK: - JSON helpers`:

```swift
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
```

`Sources/RoutingView.swift` — the Domains section (`:24-40`) becomes:

```swift
                Section {
                    ForEach(app.bypassDomains, id: \.self) { domain in
                        LabeledContent(domain) {
                            Button {
                                removeDomain(domain)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    // A TextField's title is a row label in a grouped Form, so the example
                    // goes in the prompt and the label is hidden.
                    HStack {
                        TextField("Domain", text: $newDomain, prompt: Text("example.com"))
                            .labelsHidden()
                            .onSubmit(addDomains)
                        Button("Add", action: addDomains)
                            .disabled(!canAdd)
                    }
                } header: {
                    Text("Domains")
                } footer: {
                    Text(verbatim: "Subdomains are included: example.com also covers www.example.com. A URL or several domains at once are accepted.")
                }
```

and `addDomain()` (`:59-64`) is replaced by:

```swift
    private var canAdd: Bool {
        !BypassService.parseDomains(newDomain).domains.isEmpty
    }

    // Enter reaches here without passing the button's disabled state. Tokens that did not
    // normalize stay in the field so the user sees what was not accepted.
    private func addDomains() {
        let parsed = BypassService.parseDomains(newDomain)
        let fresh = parsed.domains.filter { !app.bypassDomains.contains($0) }
        if !fresh.isEmpty {
            bypassDomainsRaw = (app.bypassDomains + fresh).joined(separator: "\n")
        }
        newDomain = parsed.rejected.joined(separator: " ")
    }
```

`removeDomain`, `scheduleReconnect`, the two `@AppStorage`s and the toggle section are unchanged.
`canAdd` runs `parseDomains` on every render of the page; the input is a few words.

### 3. Reconnect only when the list changed

Commit: `Skip the reconnect when the bypass list is unchanged`.

`Sources/ProcessManager.swift` `reconnect(bypassDomains:)` (`:545-546`):

```swift
    // Toggling bypass with an empty list, or editing the list while bypass is off, changes
    // nothing in the config; without passwordless a reconnect is two admin prompts.
    func reconnect(bypassDomains: [String]) {
        guard isRunning, let params = lastConnection, bypassDomains != params.bypassDomains else { return }
```

Nothing else changes: `AppState.routingChanged()` still calls it after the debounce, and the
`[Routing changed — reconnecting...]` line is now printed only for a real change. `handleWake`
replays `params.bypassDomains` and is unaffected.

### 4. IPv4-only TUN address

> Superseded by review fix R1 below: an unconditional IPv4-only TUN leaks IPv6 on a dual-stack
> host. What was built is R1.

Commit: `Give the TUN an IPv4 address only`.

In both `Sources/SubscriptionService.swift:501` and `Sources/ProcessManager.swift:510` (the
wrapper), replace the `"address"` line with:

```swift
                    // IPv4 only: a ULA here makes macOS hand out AAAA records on a host with no
                    // global IPv6, and a bypassed destination then dials direct over IPv6 and
                    // fails with "no route to host".
                    "address": ["172.19.0.1/30"],
```

`rg fdfe Sources` must then find nothing. Same commit, `CLAUDE.md` Gotchas — add:

```
- The TUN inbound carries an IPv4 address only. A ULA next to it makes `auto_route` install an
  IPv6 default route and macOS hand out AAAA records on a host with no global IPv6; a bypassed
  destination then dials direct over IPv6 and fails with `no route to host`. `dns.strategy` does
  not help — apps with their own DoH never pass through sing-box
```

### 5. Canon and README

Commit: `Record the bypass fix in the canon`.

`CLAUDE.md`:

- `:72` → `├── BypassService.swift        # Bypass rule injection and domain input normalization` (the
  longer wording broke the tree's column)
- `:97-100`, append to the "Two connection topologies" paragraph: `The bypass rule is injected
  into the wrapper by the same `BypassService.injectSingBox` that handles a sing-box server
  config; the xray config is written as the subscription produced it.`
- `:245` Runtime Files → `` `$TMPDIR/warpveil-xray-<pid>.json` — xray config, as the subscription produced it ``
- `:254` replace the gotcha with these two (a third, "the bypass rule goes into the sing-box that
  holds the TUN", was dropped while implementing: the topology paragraph above already says it):

```
- A domain rule placed before `sniff` never matches a TUN connection: it arrives as an IP
  destination and the domain exists only after the sniff action. `injectSingBox` puts the bypass
  rule right after the first `sniff`, inserting one at the top when the config has none
- A sniffed SNI is lowercase punycode, so bypass domains are stored that way
  (`BypassService.normalizeDomain`); `domain_suffix` covers subdomains and never an IP literal
```

- Gotchas, next to the two grouped-`Form` entries (`:264-267`), after the visual check in
  Verification 5 confirms it (it did, and also surfaced the `Text` autolink):

```
- In a grouped `Form` a `TextField` title renders as the row's label, not as a placeholder — put
  the example in `prompt:` and hide the label
- A `Text` literal is a `LocalizedStringKey`, and a bare `www.` domain in it renders as a clickable
  link — UI copy that names a domain is `Text(verbatim:)`
```

`README.md:75` → `├── BypassService.swift        # Bypass rule injection and domain input normalization`.

Then move this file to `plans/done/` and run `/code-review` (canon workflow, step 3).

## Verification

### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
```

Expect `BUILD SUCCEEDED` after every step. Two pre-existing warnings (`AppState.swift:158`,
`WarpVeilApp.swift:141`, `'weak' ownership of capture 'self' differs …`, new with the Xcode 27
compiler) are not from this plan. Never `swift build`.

### 2. `swiftc` harness over the real `BypassService.swift`

After step 2. `main.swift` carries copies of the two builders' literals (they are `private`), so
a change to `buildSingBoxConfigFromOutbound` or `buildTunWrapperConfig` has to be mirrored here:

```bash
mkdir -p "$TMPDIR/bypass-harness" && cd "$TMPDIR/bypass-harness"
cat > main.swift <<'EOF'
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print((condition ? "ok   " : "FAIL ") + label)
    if !condition { failures += 1 }
}
func json(_ dict: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!
}
func parse(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any] }
func rules(of c: String) -> [[String: Any]] { ((parse(c)["route"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? [] }
func actions(of c: String) -> [String] { rules(of: c).map { ($0["action"] as? String) ?? "-" } }

let tun: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true]
let dns: [String: Any] = ["servers": [["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "proxy"] as [String: Any],
                                      ["tag": "local", "type": "tls", "server": "8.8.8.8"] as [String: Any]], "strategy": "prefer_ipv4"]

// Copy of SubscriptionService.buildSingBoxConfigFromOutbound's literal.
func serverConfig() -> String {
    json(["log": ["level": "info"], "inbounds": [tun],
          "outbounds": [["type": "vless", "tag": "proxy", "server": "203.0.113.7", "server_port": 443, "uuid": "x"] as [String: Any],
                        ["type": "direct", "tag": "direct"] as [String: Any]],
          "route": ["auto_detect_interface": true, "default_domain_resolver": ["server": "local"] as [String: Any], "final": "proxy",
                    "rules": [["action": "hijack-dns", "protocol": "dns"] as [String: Any], ["action": "sniff"] as [String: Any]]] as [String: Any],
          "dns": dns])
}
// Copy of ProcessManager.buildTunWrapperConfig's literal with an IP server.
func wrapperConfig() -> String {
    json(["log": ["level": "info"], "inbounds": [tun],
          "outbounds": [["type": "socks", "tag": "xray-proxy", "server": "127.0.0.1", "server_port": 10808] as [String: Any],
                        ["type": "direct", "tag": "direct"] as [String: Any]],
          "route": ["auto_detect_interface": true, "default_domain_resolver": ["server": "local"] as [String: Any], "final": "xray-proxy",
                    "rules": [["action": "route", "outbound": "direct", "ip_cidr": ["203.0.113.7/32"]] as [String: Any],
                              ["action": "hijack-dns", "protocol": "dns"] as [String: Any], ["action": "sniff"] as [String: Any]]] as [String: Any],
          "dns": dns])
}

let domains = ["example.com", "xn--c1aapkosapc.xn--p1ai"]

let server = BypassService.injectSingBox(serverConfig(), domains: domains)
check(actions(of: server) == ["hijack-dns", "sniff", "route"], "server shape: bypass right after sniff")
check((rules(of: server)[2]["domain_suffix"] as? [String]) == domains && (rules(of: server)[2]["outbound"] as? String) == "direct", "server shape: rule content")
check((parse(server)["outbounds"] as! [[String: Any]]).count == 2, "server shape: direct not duplicated")

let wrapper = BypassService.injectSingBox(wrapperConfig(), domains: domains)
check(actions(of: wrapper) == ["route", "hijack-dns", "sniff", "route"], "wrapper shape: server rule first, bypass after sniff")
check((rules(of: wrapper)[0]["ip_cidr"] as? [String]) == ["203.0.113.7/32"], "wrapper shape: server rule untouched")
check((rules(of: wrapper)[3]["domain_suffix"] as? [String]) == domains, "wrapper shape: last rule is the bypass")

var noSniff = parse(serverConfig()); var r = noSniff["route"] as! [String: Any]
r["rules"] = [["outbound": "direct", "ip_is_private": true] as [String: Any]]; noSniff["route"] = r
check(actions(of: BypassService.injectSingBox(json(noSniff), domains: domains)) == ["sniff", "route", "-"], "no sniff: sniff at 0, bypass at 1, user rule after")

var bare = parse(serverConfig()); bare["route"] = nil
bare["outbounds"] = [["type": "vless", "tag": "proxy", "server": "203.0.113.7", "server_port": 443] as [String: Any]]
let bareOut = BypassService.injectSingBox(json(bare), domains: domains)
check(actions(of: bareOut) == ["sniff", "route"], "no route key: sniff + bypass")
check(((parse(bareOut)["outbounds"] as! [[String: Any]]).last?["tag"] as? String) == "direct", "no direct outbound: one appended")

var mid = parse(serverConfig()); r = mid["route"] as! [String: Any]
r["rules"] = [["action": "hijack-dns", "protocol": "dns"] as [String: Any],
              ["action": "route", "outbound": "direct", "ip_is_private": true] as [String: Any],
              ["action": "sniff", "inbound": "tun-in", "timeout": "1s"] as [String: Any],
              ["action": "route", "outbound": "proxy", "domain_suffix": ["example.com"]] as [String: Any]]
mid["route"] = r
let midOut = BypassService.injectSingBox(json(mid), domains: domains)
check(actions(of: midOut) == ["sniff", "route", "hijack-dns", "route", "sniff", "route"] && (rules(of: midOut)[1]["outbound"] as? String) == "direct", "conditioned sniff only: own sniff at 0, bypass at 1")
var timed = parse(serverConfig()); r = timed["route"] as! [String: Any]
r["rules"] = [["action": "hijack-dns", "protocol": "dns"] as [String: Any], ["action": "sniff", "timeout": "1s"] as [String: Any]]; timed["route"] = r
check(actions(of: BypassService.injectSingBox(json(timed), domains: domains)) == ["hijack-dns", "sniff", "route"], "sniff with only a timeout counts as unconditional")

check(BypassService.injectSingBox(serverConfig(), domains: []) == serverConfig(), "empty domains: unchanged")
check(BypassService.injectSingBox("not json", domains: domains) == "not json", "invalid json: unchanged")

let cases: [(String, String?)] = [
    ("example.com", "example.com"), ("  Example.COM  ", "example.com"),
    ("https://www.YouTube.com:443/watch?v=1", "www.youtube.com"), ("http://example.com/path", "example.com"),
    ("госуслуги.рф", "xn--c1aapkosapc.xn--p1ai"), ("https://госуслуги.рф/", "xn--c1aapkosapc.xn--p1ai"),
    ("*.example.com", "example.com"), (".example.com", "example.com"), ("example.com.", "example.com"),
    ("example.com:8443", "example.com"), ("user@example.com", "example.com"), ("sub.domain.example.co.uk", "sub.domain.example.co.uk"),
    ("a b.com", nil), ("1.2.3.4", nil), ("[::1]", nil), ("::1", nil), ("localhost", "localhost"), ("ru", "ru"), (".ru", "ru"), ("рф", "xn--p1ai"), ("a", nil), ("1234", nil),
    ("", nil), ("   ", nil), ("-bad.com", nil), ("bad-.com", nil), ("ex_ample.com", nil),
    (String(repeating: "a", count: 64) + ".com", nil),
]
for (input, expected) in cases {
    let got = BypassService.normalizeDomain(input)
    check(got == expected, "normalize \(input.debugDescription) -> \(got ?? "nil")")
}

let parsed = BypassService.parseDomains("Example.com, https://госуслуги.рф/x  foo\nbar.org,1.2.3.4 example.com")
check(parsed.domains == ["example.com", "xn--c1aapkosapc.xn--p1ai", "foo", "bar.org"], "parseDomains: order kept, duplicates dropped")
check(parsed.rejected == ["1.2.3.4"], "parseDomains: rejected tokens verbatim")
let commaURL = BypassService.parseDomains("https://maps.example.com/@55.7,37.6,12z")
check(commaURL.domains == ["maps.example.com"] && commaURL.rejected.isEmpty, "parseDomains: a URL keeps its commas")
let single = BypassService.parseDomains("a b.com")
check(single.domains == ["b.com"] && single.rejected == ["a"], "parseDomains: 'a b.com'")
let none = BypassService.parseDomains("  ,  ")
check(none.domains.isEmpty && none.rejected.isEmpty, "parseDomains: separators only")

print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
EOF
swiftc -target arm64-apple-macosx14.0 main.swift \
  "/Users/lortan29/Documents/Home Projects/vpn-swift/Sources/BypassService.swift" -o harness && ./harness
```

Expect every line `ok` and `ALL OK` (46 checks after the review fixes). `fitTunToHost` has its
own harness, compiled the same way:

```swift
import Foundation
var failures = 0
func check(_ c: Bool, _ l: String) { print((c ? "ok   " : "FAIL ") + l); if !c { failures += 1 } }
func parse(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any] }
func json(_ d: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)! }
func tunAddresses(_ s: String) -> [[String]] { (parse(s)["inbounds"] as! [[String: Any]]).filter { $0["type"] as? String == "tun" }.map { $0["address"] as! [String] } }
let old = json(["inbounds": [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]] as [String: Any],
                             ["type": "mixed", "tag": "m", "listen_port": 1] as [String: Any]], "outbounds": [] as [Any]])
let v4 = json(["inbounds": [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"]] as [String: Any]]])
check(tunAddresses(BypassService.fitTunToHost(old, hostHasIPv6: false)) == [["172.19.0.1/30"]], "stored ULA dropped on an IPv4-only host")
check(tunAddresses(BypassService.fitTunToHost(v4, hostHasIPv6: true)) == [["172.19.0.1/30", "fdfe:dcba:9876::1/126"]], "ULA added on a dual-stack host")
check(tunAddresses(BypassService.fitTunToHost(old, hostHasIPv6: true)) == [["172.19.0.1/30", "fdfe:dcba:9876::1/126"]], "no duplicate ULA")
check(tunAddresses(BypassService.fitTunToHost(v4, hostHasIPv6: false)) == [["172.19.0.1/30"]], "IPv4-only stays")
check(((parse(BypassService.fitTunToHost(old, hostHasIPv6: false))["inbounds"] as! [[String: Any]])[1]["type"] as? String) == "mixed", "other inbounds untouched")
check(BypassService.fitTunToHost("nope", hostHasIPv6: true) == "nope", "invalid json unchanged")
print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)"); exit(failures == 0 ? 0 : 1)
```

Expect every line `ok` and `ALL OK`. This exact harness (with the pre-step-4 TUN address in the
literals, which the rule-order checks do not look at) ran green in this run against the proposed
`BypassService.swift`.

### 3. User-space end to end: the injected wrapper shape through the live xray SOCKS

Runs while the tunnel is up and touches no engine of the app's: a user-space sing-box with a
`mixed` inbound on localhost, every outbound that leaves the machine pinned to the primary
interface with `bind_interface` (as `PingService` does), the socks hop to `127.0.0.1:10808` left
unbound. The live TUN would otherwise capture the test traffic. Needs the live xray topology
(it is live now); for a sing-box server the proxy outbound of the live
`$TMPDIR/warpveil-singbox-<pid>.json` takes the socks outbound's place and the transform below
pins it too.

```bash
W="$TMPDIR/bypass-e2e"; mkdir -p "$W/cli"; cd "$W"
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
LIVE=$(ls -t "$TMPDIR"/warpveil-singbox-*.json | head -1)      # the live wrapper, written by the app

# the real injector as a CLI: inject <in> <out> <domain>...
cat > cli/main.swift <<'EOF'
import Foundation
let a = CommandLine.arguments
let input = try! String(contentsOfFile: a[1], encoding: .utf8)
try! BypassService.injectSingBox(input, domains: Array(a[3...])).write(toFile: a[2], atomically: true, encoding: .utf8)
EOF
swiftc -target arm64-apple-macosx14.0 cli/main.swift "$REPO/Sources/BypassService.swift" -o cli/inject
cli/inject "$LIVE" fixed.json ifconfig.me

# control: the old shape, bypass rule moved to index 0
python3 -I - fixed.json control.json <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); rules = c["route"]["rules"]
rules.insert(0, rules.pop(next(i for i, r in enumerate(rules) if "domain_suffix" in r)))
json.dump(c, open(sys.argv[2], "w"), indent=2)
EOF

# tun -> mixed on a free port, bind_interface on everything that leaves the machine
IFACE=$(scutil <<< "show State:/Network/Global/IPv4" | awk '/PrimaryInterface/ {print $3}')
PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1])")
cat > userspace.py <<'EOF'
import json, sys
src, dst, port, iface = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
cfg = json.load(open(src))
cfg["inbounds"] = [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port}]
for ob in cfg["outbounds"]:
    if ob.get("server") not in ("127.0.0.1", "::1", "localhost"):
        ob["bind_interface"] = iface
cfg["log"] = {"level": "info"}
json.dump(cfg, open(dst, "w"), indent=2)
print([r.get("action", "-") for r in cfg["route"]["rules"]])
EOF
python3 -I userspace.py fixed.json fixed-us.json "$PORT" "$IFACE"      # [... "hijack-dns", "sniff", "route"]
python3 -I userspace.py control.json control-us.json "$PORT" "$IFACE"  # ["route", ... "hijack-dns", "sniff"]
"$REPO/Binaries/sing-box" check -c fixed.json && "$REPO/Binaries/sing-box" check -c fixed-us.json

run_case() {
  "$REPO/Binaries/sing-box" run -c "$2" > "$1.log" 2>&1 & local pid=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
  echo "[$1] bypassed     ifconfig.me   -> $(curl -s --max-time 20 --socks5 127.0.0.1:$PORT https://ifconfig.me/ip)"
  echo "[$1] not bypassed api.ipify.org -> $(curl -s --max-time 20 --socks5 127.0.0.1:$PORT https://api.ipify.org)"
  kill "$pid"; wait "$pid" 2>/dev/null
  sed 's/\x1b\[[0-9;]*m//g' "$1.log" | rg "outbound/"
}
echo "[plain] via the live tunnel -> $(curl -s --max-time 20 https://api.ipify.org)"
run_case fixed fixed-us.json
run_case control control-us.json
ps -axo pid,user,comm | rg sing-box | rg -v root || echo "no user-space sing-box left"
```

Expect: `[plain]` = the VPN exit IP; `[fixed] bypassed` = the **home** IP with
`outbound/direct[direct]: outbound connection to <ifconfig.me IP>:443` in the log and
`[fixed] not bypassed` = the VPN exit IP via `outbound/socks[xray-proxy]`; `[control]` both the
VPN exit IP, both via `outbound/socks[xray-proxy]`. The `curl --socks5` form resolves locally and
hands the engine an IP destination, which is how TUN connections arrive. This ran in this run with
exactly that outcome (IPs withheld from the file; see the run report).

**Not exercised here, and why:** the real TUN path — root engines, `auto_route`, the system
resolver and `hijack-dns`. Starting a second TUN engine on this machine fails at the TUN (canon)
and stopping the live one cuts the session off. What the user-space run proves is the rule order
inside sing-box on the exact injected shape; what it cannot prove is that a TUN connection
reaches `sniff` with a sniffable payload, which the main session's earlier verification covered.

### 4. Live checks after deploy (main session, after `./install.sh` and a connect on the new build)

Bypass, end to end through the TUN. Either add `api.ipify.org` on the Routing page (that also
exercises Add and the debounce → reconnect), or with the app disconnected:

```bash
SAVED=$(defaults read com.warpveil.app bypassDomains 2>/dev/null || echo "")
defaults write com.warpveil.app bypassDomains -string "api.ipify.org"
# connect in the app, wait for the location to settle, then:
curl -s --max-time 20 https://api.ipify.org; echo " <- must be the home IP"
curl -s --max-time 20 https://ifconfig.me/ip; echo " <- must be the VPN exit IP"
python3 -I -c "import json,glob,os;f=max(glob.glob(os.environ['TMPDIR']+'/warpveil-singbox-*.json'),key=os.path.getmtime);print(f,[r.get('action','-') for r in json.load(open(f))['route']['rules']])"
# restore
if [ -n "$SAVED" ]; then defaults write com.warpveil.app bypassDomains -string "$SAVED"; else defaults delete com.warpveil.app bypassDomains; fi
```

The rules line must end `..., "sniff", "route"`. Logs must show `[Bypass] 1 domain(s) will route
direct` and, on a later toggle of the switch with the same list, no `[Routing changed —
reconnecting...]`; toggling with an **empty** list must not reconnect at all (step 3).

IPv4-only TUN (step 4) — only a live tunnel shows it:

```bash
dscacheutil -flushcache
dscacheutil -q host -a name ya.ru      # no ipv6_address line
ifconfig | rg -c fdfe                  # 0
netstat -rn -f inet6 | rg utun         # no default/::/1 routes into the tunnel
```

### 5. Visual check (main session, Xcode Cmd+R or `./dev-run.sh`, Routing page)

The field shows `example.com` greyed as a placeholder with no "example.com" label on the left;
Add is disabled on an empty field, on `foo`, on `1.2.3.4`, enabled on `Example.com`; Enter and
Add both add; `https://www.YouTube.com:443/watch?v=1` adds `www.youtube.com`; `госуслуги.рф` adds
`xn--c1aapkosapc.xn--p1ai`; `a, b.com foo` adds `b.com` and leaves `a foo` in the field; the
footer caption renders under the card. Only then add the grouped-`Form` gotcha of step 5.

## Out of scope / found in passing

- **DNS bypasses the tunnel entirely**: the LAN resolver `192.168.1.1` is routed via en0 and the
  TUN log shows zero port-53 packets, so `hijack-dns` never fires on this machine. The parity
  plan's item 2 owns this.
- **An xray server given by hostname would loop in the wrapper**: `buildTunWrapperConfig` writes a
  `domain_suffix` rule for it, which is matched against the sniffed REALITY camouflage SNI, not
  the server name. All current servers are IPs.
- `plans/client-feature-parity.md` (proposed) named code this plan changed; it now carries a
  rebase note at the top (review finding 14).
- A sing-box server's config is generated once and stored in `subscriptions.json`, TUN inbound
  included. Feed servers are rebuilt by `refreshAll` on every launch, before auto-connect, so
  they lose the IPv6 address on the first launch of the new build; a manual `vless://` server
  keeps it until it is removed and re-added, and so does a feed whose refresh fails. The owner
  has no manual servers today (checked: all eight are feed servers).
- Entries stored before this change are not re-normalized: a `*.foo.com` or an IP literal that an
  older build accepted sits in the list and matches nothing until removed and re-added. The
  owner's list is empty today.
- Two compiler warnings under Xcode 27 in files this plan does not touch (`AppState.swift:158`,
  `WarpVeilApp.swift:141`, implicit strong capture next to `[weak self]`).
- `normalizeDomain`'s IDN result rests on `URLComponents.encodedHost` returning punycode, verified
  on macOS 27 only; on macOS 14 the pre-Swift-Foundation parser may return nil for a non-ASCII
  host, in which case such an entry is rejected rather than mis-stored.

## Validation of this plan

Done in this run, repo untouched (`git status --porcelain` empty afterwards), no engine of the
app's started or stopped:

- Baseline `xcodebuild … Debug` into a scratch derived-data dir: `BUILD SUCCEEDED`.
- The proposed `BypassService.swift` and the `main.swift` above, extracted from this file
  verbatim, compiled with `swiftc -target arm64-apple-macosx14.0`: 40 checks, all `ok`.
- A scratch copy of the repo received steps 1 → 2 → 3 → 4 in order, `xcodebuild` after each:
  four times `BUILD SUCCEEDED`, no new warnings. A second copy received step 1 alone (new
  `injectSingBox`, no `injectXray`, no normalization yet, the original `RoutingView`): `BUILD
  SUCCEEDED`.
- `Binaries/sing-box check` on the injected wrapper (TUN inbound) and on its user-space transform:
  both accepted.
- The user-space e2e of Verification 3, the script extracted from this file verbatim, on the
  live wrapper config: fixed shape → bypassed domain via `outbound/direct[direct]` to the home IP
  (a different address from the plain curl), other domain via `outbound/socks[xray-proxy]` to the
  VPN exit; control (old shape) → both via `outbound/socks[xray-proxy]` to the VPN exit. The
  user-space engine was killed by its own PID; `ps` shows no user-owned sing-box afterwards.
- Every symbol named above was read in the source at the cited lines.

## Review fixes

`/code-review d9a5856..HEAD` found 14 issues. Fixed:

- **R1. The TUN's IP families follow the host's, at connect time** (replaces step 4). Step 4 made
  every TUN IPv4-only. sing-tun's `BuildAutoRouteRanges` (v0.9.0-beta.4, the one sing-box 1.14.0
  pins) builds IPv6 routes only when the TUN has an IPv6 address, and `tun_darwin.go` never reads
  `StrictRoute` — so on a dual-stack host every IPv6 connection would leave past the VPN. Now
  `BypassService.fitTunToHost(_:hostHasIPv6:)` rewrites each `tun` inbound's `address` in
  `ProcessManager.connect`: IPv4 entries as given, plus `fdfe:dcba:9876::1/126` only when
  `ProcessManager.hostHasGlobalIPv6()` finds configd's `State:/Network/Global/IPv6` (absent on
  this host, which has only a link-local IPv6; the live TUN does not register it). The builders
  stay IPv4-only. Because it runs at connect, stored configs (manual servers, failed refreshes,
  `?format=singbox` feeds) are covered too — that was review finding 5, and the literal now lives
  once (finding 13). Residual: a network that gains or loses IPv6 mid-session keeps the TUN shape
  until the next reconnect (sleep/wake reconnects).
- **R2. The bypass rule anchors on the first unconditional `sniff`** (finding 3). A `sniff` with an
  `inbound` or a `sniffer` list — possible in a `?format=singbox` feed or a pasted config — may
  never run for TUN connections or never read their SNI. `isUnconditionalSniff` accepts only
  `action` and `timeout`; with none, `{"action":"sniff"}` goes to index 0 as before. Harness:
  the conditioned-sniff case now expects `[sniff, route, hijack-dns, route, sniff, route]`, plus a
  timeout-only case; 41/41 ok.
- **R3. Domain input accepts a bare TLD and keeps a URL's commas** (findings 2, 9). `ru` — the usual
  first entry of a Russian bypass list, which the old `addDomain` stored — was rejected by the
  two-label rule; `isDomainName` now needs only a last label of 2+ characters that is not all
  digits (IP literals still fail). Verified with the bundled sing-box: `domain_suffix: ["ru"]`
  sends `ya.ru` and `www.gosuslugi.ru` direct and `example.com` to the proxy. `parseDomains` splits
  on whitespace, and on commas only outside a token with `://`, so
  `https://maps.example.com/@55.7,37.6,12z` adds `maps.example.com` and leaves nothing behind.
  The footer says `ru covers every .ru site`. Harness 46/46 ok.
- **R4. The prompt is `Text(verbatim:)` too** (finding 11), per the canon rule this plan added.
- **R5. Stored domains are normalized on read** (finding 8). `AppState.bypassDomains` is
  `BypassService.parseDomains(raw).domains`, so an entry an older build stored as typed
  (`*.YouTube.com`, a URL, an IP) reaches `domain_suffix` normalized or not at all, and the list
  is deduplicated; the raw string is rewritten from the normalized list at the next edit. Checked:
  `"*.YouTube.com\nhttps://Example.org/path\n10.0.0.1\nexample.org\n  ru  "` →
  `["youtube.com", "example.org", "ru"]`. This replaces "Not chosen: re-normalizing entries already
  stored" above. `addDomains` reads `app.bypassDomains` once instead of per element.
- **R6. The reconnect guard compares sets** (finding 7): removing and re-adding a domain inside the
  debounce reorders the list without changing the routing.
- **R7. The parity plan carries a rebase note** (finding 14).

Not fixed, with the reason:

- **Finding 4, an xray server given by hostname loops in the wrapper** — already listed under
  "found in passing". Every fix changes how xray reaches its server (pin `sockopt.interface`,
  which goes stale on an interface change; resolve to `ip_cidr`, which can disagree with xray's
  own lookup; a `process_path` rule), and none can be verified here: it needs a live TUN on a
  hostname server, and dropping the live tunnel cuts the session off. No current server is a
  hostname.
- **Finding 6, bypass for clients of xray's local SOCKS 10808 / HTTP 10809** — `injectXray` never
  delivered it: xray's `freedom` dial entered the TUN, the old wrapper's rule sat before `sniff`,
  and the flow went `final → xray-proxy` back into the VPN. Nothing working was removed; making the
  local proxies bypass-aware is new scope.
- **Finding 10, IDN on macOS 14** — `URLComponents.encodedHost` returning punycode is verified on
  macOS 27 only. Where it does not, the IDN token is rejected and stays in the field, never stored
  wrong; a hand-written punycode encoder is not worth it before someone hits this.
- **Finding 12, the wrapper's serialize → parse → serialize round trip** — one extra pass per
  connect on a small dictionary; the `"{}"` failure path cannot happen for a literal.

`/code-review e3a7fa4..HEAD` (second pass, over the fixes above) found 11. Fixed:

- **R8. A routing edit made while a reconnect is pending is kept** (finding 5). `handleWake` and
  `reconnect(bypassDomains:)` share `ProcessManager.restart(_:after:)`, whose delayed connect reads
  `lastConnection` when it fires. `reconnect` records a changed list in `lastConnection` first and
  restarts only while running; `AppState.routingChanged()` no longer gates on `isRunning`, so a
  domain removed during the 5 s after wake is not connected with the old list.
- **R9. A change of the host's IPv6 restarts the engines** (finding 2). R1 fixed the TUN's families
  at connect, so a network that gained IPv6 mid-session leaked it and one that lost it kept the
  AAAA problem. `ProcessManager.watchHostIPv6()` subscribes to configd's
  `State:/Network/Global/IPv6` (`SCDynamicStoreSetNotificationKeys` on the main queue); when the
  host's answer stops matching `tunHasIPv6`, `restart` runs with the wake path's 5 s settle delay.
  sing-box 1.14 has no rule action that re-resolves a sniffed domain (`resolve` needs a domain
  destination, `route-options.override_address` is fixed), so "ULA always, bypassed traffic
  re-resolved to IPv4" was not an option. Not exercised: a non-root process cannot write a
  dynamic-store key to trigger the callback (a scratch test: `SCDynamicStoreSetValue` → false,
  while subscribing returns true), and no network change was made here.
