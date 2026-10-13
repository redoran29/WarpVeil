# xray server given by hostname: route its dial by address, and make xray dial the same address

Status: proposed. Written against `5de6c1c`, macOS 27.0.1 (Darwin 27.0.0), Xcode 27.0, bundled
sing-box 1.14.0 and Xray 26.3.27, deployment target 14.0, `CFBundleShortVersionString` = `1.2`.

> **Rebase note.** While this plan was being written, DNS-upstream work (the parity plan's item 2)
> was in flight in a scratch copy: `BypassService.setUpstream`/`proxyTag`, a `DNSUpstream` type in
> `Models.swift`, and ~80 changed lines in `ProcessManager.swift`. Nothing of it is in `5de6c1c`.
> Step 1 below inserts one section into `BypassService.swift` (before `// MARK: - Domain input`)
> and rewrites `connect`'s xray branch and `buildTunWrapperConfig`; if that work lands first,
> both apply — keep both, re-run Verification 1 and 2.

## Owner's ask

Fix the latent loop found by the bypass review (`plans/done/routing-bypass-fix.md`, first-pass
finding 4): in the xray topology the wrapper routes xray's own connection to the VPN server
`direct` by `ip_cidr` when the server is an IP literal, but by `domain_suffix` when it is a
hostname — and that rule can never match. Compare a `process_path` rule, resolving the name at
connect, and pinning xray to the primary interface; pick one; keep the IP-literal path as it is
unless the chosen mechanism replaces it safely. All of the owner's servers are IP literals today,
so nothing is broken live; a hostname server (the usual shape of an xhttp server behind a CDN)
would loop on first use.

Out of scope and untouched: `run.sh`/`stop.sh` (`ProcessManager.runShContent`/`stopShContent` —
a byte change reads the installed passwordless scripts as stale), the `hijack-dns`/`sniff` order
in the builders (the parity plan's DNS item owns it; see "found in passing"), `PingService`,
`SubscriptionService`'s builders, `project.pbxproj` (no new files: the project is a plain
`PBXGroup` with explicit file references).

## Verified facts

Checked in this run on this machine, not recalled. Line numbers are against `5de6c1c`.

### Code

- `Sources/ProcessManager.swift:371-375` `connect(config:engine:binaryPath:singBoxPath:bypassDomains:)`,
  `@MainActor`, synchronous. `:384-395` parks itself in `reconnectTask` while a stop is running
  and re-enters with the same parameters — the pattern this plan copies for the lookup. `:405`
  records `lastConnection`; `:415-424` writes the xray config **as is**; `:431-436` builds the
  wrapper with `buildTunWrapperConfig(serverIP: extractServerIP(from: config))` and runs it
  through `injectSingBox` + `fitTunToHost`.
- `:545-565` `extractServerIP(from:)` returns `settings.vnext[0].address` of the first outbound
  that has one, else the first `server` key (sing-box shape). It is called only for `.xray`
  (`:431`), so the sing-box branch is dead; and an xray config whose proxy is trojan, shadowsocks
  or socks (`settings.servers[0].address`, reachable through `?format=xray` feeds and pasted
  JSON, `SubscriptionService.swift:716-721` reads it for display) gets **no server rule at all** —
  it loops today even with an IP literal.
- `:567-631` `buildTunWrapperConfig(serverIP:)`: `ip_cidr` for an `IPv4Address`/`IPv6Address`
  literal, else `domain_suffix: [host]` (`:573-589`); rules `[server rule, hijack-dns, sniff]`;
  `route.final: xray-proxy`; DNS servers `remote` (DoT 1.1.1.1, `detour: xray-proxy`) and `local`
  (DoT 8.8.8.8, no detour), no `dns.final`, no `dns.rules`.
- `:353-367` `restart(_:after:)` calls `connect` with `lastConnection`'s parameters; `:636-641`
  `reconnect(bypassDomains:)`; `:643-649` `disconnect` cancels `reconnectTask` first.
- `Sources/SubscriptionService.swift:339-350` `parseVlessURI` picks xray only for `type=xhttp`/
  `splithttp`; `:532-637` `buildXrayConfig`: `vnext.address = host` (`:536`), `tlsSettings.serverName`
  only when `sni` is given (`:589`), `realitySettings.serverName` likewise (`:597`),
  `xhttpSettings.host` only when `host` is given (`:564`), `routing.domainStrategy: AsIs` (`:631`),
  no `dns` block. `:692-735` `parseXray` stores the user's whole config with the proxy outbound
  first.
- `Sources/BypassService.swift:55-67` `fitTunToHost` — the precedent for a connect-time rewrite
  living here; `:132-144` `parseJSON`/`serializeJSON` (private). The file imports Foundation
  only, so a `swiftc` harness compiles it as is.
- `Sources/PingService.swift:314-329` pins a user-space xray with `streamSettings.sockopt.interface`;
  `:366-371` `primaryInterface()` (private). `:19-22` records that the bind covers the dial, not
  name resolution.
- `Sources/AppState.swift:85-101` `connect()` calls `pm.connect` and starts the location timer at
  once; `:128-130` `routingChanged()`.
- Canon: `CLAUDE.md:72` architecture line; `:97-102` "Two connection topologies" ends with "the
  xray config is written as the subscription produced it"; `:246` Runtime Files, xray config line;
  `:256-259` the "domain rule before sniff" gotcha. `README.md:75` mirrors `:72`.

### Engine: sing-box 1.14.0 (sources read at tag `v1.14.0` via `gh api`)

- **Process rules on macOS read `net.inet.tcp.pcblist_n`/`net.inet.udp.pcblist_n`**
  (`common/process/searcher_darwin_shared.go`): one sysctl snapshot per network, cached 200 ms,
  parsed with fixed offsets (`structSize` 408 on Darwin ≥ 22, +208 for TCP), matched **exactly**
  on local *and* remote address+port for TCP — fallbacks on local address only exist for UDP.
  The path comes from `proc_pidpath` of the socket's `so_last_pid`. Lookup is on whenever a
  rule has a process field (`route/router.go:66`, `hasRule(options.Rules, isProcessRule)`;
  `find_process` only adds it when no rule needs it); it runs for every connection whose source
  is a local address (`route/process_cache.go:38-48`, `isLocalSource` — the TUN's 172.19.0.1 is
  one), before rule evaluation, and failure is one `INFO router: failed to search process` line
  and no match.
- **On this macOS 27 the sysctl answers an unentitled, non-root process with the header only**:
  a C program (`sysctlbyname("net.inet.tcp.pcblist_n")`) gets 48 bytes = two `xinpgen`, zero
  records, sandboxed or not; `netstat -anv` lists everything because it carries
  `com.apple.private.network.statistics` (`codesign -d --entitlements`); the bundled engines carry
  no entitlement. The published xnu (`xnu-12377.*`, macOS 26) has no such gate in `get_pcblist_n`
  — the size query there is `2*sizeof(xig) + (n + n/8 + 1)*item_size`, never 48 — so Darwin 27
  changed it and its source is not out. **Whether root without the entitlement still gets the
  list is unknown**; it cannot be tested here without an admin prompt (one `osascript … with
  administrator privileges` running the same C program would settle it). The finder is identical
  at `v1.14.3` (latest release, 2026-10-09).
- A `mixed`/`socks` inbound can never match a TCP process rule: its routed destination is the
  proxied target, not the socket's peer, so the exact match fails by construction. Probed: a
  user-space sing-box with `process_path: ["/usr/bin/curl"]` → `router: failed to search process:
  process not found` for every connection, including one whose destination was the proxy itself.
- `protocol: dns` matches only a sniffed protocol (`route/rule/rule_item_protocol.go:28-30`:
  `r.protocolMap[metadata.Protocol]`). The TUN inbound sets `Protocol = dns` before rules only for
  destinations in `dnsHijackAddress` (`protocol/tun/inbound.go:333-338, 553-555`), which this app
  does not configure. With the builders' order `[hijack-dns, sniff]` the hijack never fires; a
  port-53 flow that enters the TUN goes to `final` (the parity plan's DNS item).
- A DNS server with no `detour` dials direct (`common/dialer/dialer.go:46-64`, `NewDefault`;
  `docs/configuration/dns/server/tls.md:33` "equivalent to using an empty direct outbound").
  `dns.final` empty → the first server is the default (`docs/configuration/dns/index.md:52-56`),
  i.e. `remote` through `xray-proxy` in the wrapper.
- `Binaries/sing-box check` accepts a wrapper whose server rule is
  `ip_cidr: ["203.0.113.20/32", "2001:db8::1/128"]` (Verification 2 writes it).

### Engine: Xray 26.3.27 (sources read at tag `v26.3.27`)

- `streamSettings.sockopt.domainStrategy` other than `AsIs` makes the system dialer resolve a
  domain destination through xray's **own** DNS app and dial the IP (`transport/internet/dialer.go:252-257`,
  `LookupForIP`); the DNS app answers from `dns.hosts` first (`app/dns/dns.go:227+`). The
  substitution is local to the raw dial: TLS `serverName` falls back to `dest.Address` of the
  outbound's destination (`transport/internet/tls/config.go:490-495`), and the xhttp `Host`
  falls back `transport host → tls serverName → reality serverName → dest.Address`
  (`transport/internet/splithttp/dialer.go:365-373`), all still the hostname. Both the h2/TCP
  path (`:119`) and the h3 path (`:226`) dial through `DialSystem` with the hostname destination.
- **Probed in user space**: xray with `dns.hosts: {"wv-probe.invalid": ["127.0.0.1"]}` and a
  `freedom` outbound with `sockopt.domainStrategy: UseIP` served `curl --socks5-hostname … http://wv-probe.invalid:<port>/`
  from a local HTTP server, which saw `Host: wv-probe.invalid:<port>` — log `app/dns: returning 1
  IP(s) for domain wv-probe.invalid -> [127.0.0.1]`. Without the `dns` block the same request
  failed with `lookup wv-probe.invalid: no such host`. A `dns` block with `hosts` and no `servers`
  passes `xray run -test` and runs.
- With `AsIs` (the builder's default) a hostname is resolved by Go's `net.Dialer`
  (`transport/internet/system_dialer.go:113-146`), and on darwin Go prefers the libc resolver
  (`src/net/conf.go:178-181` at `go1.26.1`: "Darwin pops up annoying dialog boxes… prefer cgo") —
  `getaddrinfo` → mDNSResponder. So xray's own lookup is **not** a packet from xray's process,
  and it follows the system's resolver configuration.
- `sockopt.interface` is `IP_BOUND_IF`/`IPV6_BOUND_IF` by interface index, set once per dial
  from the name in the config (`transport/internet/sockopt_darwin.go:136-151`); nothing in xray
  follows an interface change.
- `xray run -test` accepts the owner's live server config with its address swapped for
  `203-0-113-20.sslip.io` and pinned by the new function (`Configuration OK.`; the config stayed
  in a 0600 scratch file).

### Machine

- Live now: the installed `1.2` copy (pid 61254), xray topology on New Jersey — root `xray`
  (61370) and root `sing-box` (61387), both `proc_pidpath` → `/Applications/WarpVeil.app/Contents/Resources/{xray,sing-box}`.
  The live wrapper's rules: `[ip_cidr 203.0.113.20/32 → direct, hijack-dns, sniff, route(ifconfig.me) → direct]`;
  the live xray config: `vnext.address` = the IP, `realitySettings.serverName: rust-lang.org`, no
  `xhttpSettings.host`, no `dns`, no `sockopt`. Passwordless is installed; `autoConnect = 1`;
  `selectedServerID` is the New Jersey server; `bypassEnabled` unset; the stored list is empty.
- `netstat -anv`: xray's connections to the server have local address **172.19.0.1** (the TUN —
  so the dial does enter the wrapper), and for each one sing-box holds a matching connection
  from **192.168.1.86** (en0) to the same server — the `ip_cidr` rule at work, `direct` bound to
  the physical interface by `auto_detect_interface`.
- `203-0-113-20.sslip.io` resolves to `203.0.113.20` through the system resolver here
  (`dscacheutil -q host`, `dig`, and `getaddrinfo` from the harness: 3 ms).
- `scutil --dns`: every resolver is `192.168.1.1`, scoped to en0 and reached via en0 — system
  DNS does not enter our TUN on this machine, so the DNS cases below cannot be reproduced here.
- `Bundle.main.resourcePath` keeps the spelling the app was launched with (`/tmp/…` stays
  `/tmp/…`, `proc_pidpath` says `/private/tmp/…`); `URL.resolvingSymlinksInPath()` does not
  resolve `/tmp` → `/private/tmp` either, only `realpath(3)` does. Relevant to a `process_path`
  rule only.
- The project builds clean under Xcode 27.0 into a scratch derived-data dir (baseline), and with
  step 1 applied (`BUILD SUCCEEDED`, no new warnings).

## Design

The three candidates, and why the second one in a stronger form is the choice.

**(a) `process_path` rule for the bundled xray → direct.** The right *shape* in principle — "the
engine's own traffic never re-enters the tunnel" is the invariant, and sing-box's `direct`
outbound follows interface changes on its own. But its mechanism is the `pcblist_n` sysctl,
which macOS 27 now withholds from a process without `com.apple.private.network.statistics` (the
engines have none); root is untested and the kernel source is unpublished. A rule that silently
fails is exactly the bug being fixed, in a new place. It also does not cover xray's own name
lookup (mDNSResponder's packets, not xray's) and it adds a sysctl walk to every connection. Not
chosen; the gate is recorded in the canon so nobody builds on it later. If it is ever wanted, the
one admin prompt described under "found in passing" answers the root question first.

**(b) Resolve at connect → `ip_cidr`.** Weak on its own: xray resolves the name again, through
the system resolver, and a round-robin or CDN answer can differ — then xray dials an address the
wrapper does not route direct and loops. **Chosen with the hole closed:** the app's answer is
also pinned into xray's own DNS (`dns.hosts[host] = addresses`) and the proxy outbound gets
`sockopt.domainStrategy: UseIP`, so xray dials only addresses the wrapper routes direct, never
asks the system resolver, and keeps its SNI and `Host` on the hostname (verified above). This
also sidesteps the DNS trap the other two share: on a network whose resolver is reached through
the TUN, xray's lookup would be routed to `final` → `xray-proxy` → xray, which cannot connect
until it has resolved — a connect that never completes. Here the only lookup is the app's, before
the engines start. Costs: `getaddrinfo` blocks, so `connect` parks itself exactly like the stop
wait and re-enters with the addresses; a name that does not resolve is an error line and no
connect; a restart (wake, IPv6 change, routing) re-resolves, which is what a changed network
wants. A CDN edge that moves mid-session keeps working: every address in the answer is routed,
and xray's dial is held to that set until the next reconnect.

**(c) `sockopt.interface` on xray's outbound.** The mechanism `PingService` already uses and the
least code. Not chosen: the bind is fixed at dial time, so after a Wi-Fi→Ethernet switch every
xray reconnect fails until the app restarts the engines — a new watcher on `PrimaryInterface`
would be needed, where the sing-box topology needs none; and it leaves xray's name lookup on
the system resolver, with the DNS trap above.

**D1. The IP-literal path is unchanged.** `serverAddresses = [literal]`, the wrapper rule is the
same `ip_cidr: [<ip>/32]` the live tunnel runs on, and the xray config is written as before —
no `dns`, no `sockopt`. Only a hostname goes through resolution and pinning.

**D2. Where things live.** JSON rewriting and the lookup go into `BypassService` next to
`fitTunToHost` (connect-time fitting, Foundation-only, harness-compilable); the flow stays in
`ProcessManager.connect`. `extractServerIP` moves to `BypassService.xrayServerHost` and reads
`settings.servers[0].address` too — the trojan/shadowsocks gap above is the same rule and closes
with it; its dead sing-box branch goes.

**D3. Hand-off.** `connect` gains `resolvedAddresses: [String]? = nil`. `AppState`, `restart` and
the stop wait call it without; the lookup task re-enters with the answer; the stop wait forwards
whatever it was given. A connect or disconnect during the lookup cancels it (`reconnectTask`),
as for a pending restart.

Not chosen: rewriting `vnext.address` to the IP (SNI, `Host`, authority all default to the
address — every transport would need patching, for arbitrary feed configs too); a `dns.rules`
entry sending the server name to `local` in the wrapper (it would only matter if the hijack
fired, and it does not — see "found in passing"); keeping `domain_suffix` as a second rule (it
cannot match; dead config).

## Steps

Each step compiles on its own and is one commit. Step 1 was applied to a private scratch copy of
the repo and built — see "Validation of this plan".

### 1. Engine: resolve a hostname server once, route and dial it by address

Commit: `Route an xray server given by hostname by its resolved addresses`.

`Sources/BypassService.swift` — insert before `    // MARK: - Domain input` (after
`fitTunToHost`'s closing brace, `:67`):

```swift
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
    // use the same ones — xray's own lookup could answer differently (round-robin, a CDN), and
    // it would go through the system resolver, which the tunnel may already be carrying.
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

```

`Sources/ProcessManager.swift`:

- `connect` (`:371-375`) gains a parameter; the stop wait (`:391-392`) forwards it:

```swift
    func connect(
        config: String, engine: Engine,
        binaryPath: String, singBoxPath: String = "",
        bypassDomains: [String] = [], resolvedAddresses: [String]? = nil
    ) {
```

```swift
                connect(config: config, engine: engine, binaryPath: binaryPath, singBoxPath: singBoxPath,
                        bypassDomains: bypassDomains, resolvedAddresses: resolvedAddresses)
```

- Between the binary guard (`:400-403`) and `lastConnection = …` (`:405`), insert:

```swift
        // xray dials its server by name while the wrapper routes that dial by address, so a
        // name is resolved here, once, and both engines get the same addresses. getaddrinfo
        // blocks, so the connect parks itself like the stop wait above and re-enters with the
        // answer; a restart re-enters without one and resolves again, on the network it has.
        let serverHost = engine == .xray ? BypassService.xrayServerHost(config) : nil
        let serverName = serverHost.flatMap { IPv4Address($0) == nil && IPv6Address($0) == nil ? $0 : nil }
        if let name = serverName, resolvedAddresses == nil {
            logs.append("[Resolving \(name)...]")
            reconnectTask = Task {
                let addresses = await Task.detached { BypassService.resolveAddresses(of: name) }.value
                guard !Task.isCancelled else { return }
                guard !addresses.isEmpty else {
                    logs.append("[Error: \(name) does not resolve]")
                    return
                }
                connect(config: config, engine: engine, binaryPath: binaryPath, singBoxPath: singBoxPath,
                        bypassDomains: bypassDomains, resolvedAddresses: addresses)
            }
            return
        }
        let serverAddresses = resolvedAddresses ?? serverHost.map { [$0] } ?? []
```

- The xray branch of the `switch` (`:421-423`) becomes:

```swift
        case .xray:
            finalConfig = serverName.map { BypassService.pinXrayServer(config, host: $0, addresses: serverAddresses) } ?? config
            configFile = xrayConfigFile
```

- The wrapper call (`:432`) becomes
  `let wrapper = Self.buildTunWrapperConfig(serverAddresses: serverAddresses)`.
- Delete `extractServerIP(from:)` (`:545-565`). Replace the head of `buildTunWrapperConfig`
  (`:567-589`, through the end of the server-rule block) with:

```swift
    private nonisolated static func buildTunWrapperConfig(serverAddresses: [String]) -> String {
        var rules: [[String: Any]] = [
            ["action": "hijack-dns", "protocol": "dns"] as [String: Any],
            ["action": "sniff"] as [String: Any]
        ]

        // xray's own connection to the server enters the TUN too; without this rule it would be
        // handed back to xray. By address only: the connection arrives as an IP, before sniff,
        // and the SNI a sniff would read is the REALITY camouflage name, never the server's.
        if !serverAddresses.isEmpty {
            rules.insert([
                "action": "route",
                "outbound": "direct",
                "ip_cidr": serverAddresses.map { "\($0)/\($0.contains(":") ? 128 : 32)" }
            ] as [String: Any], at: 0)
        }
```

  The rest of the function (`let config: [String: Any] = …`) is unchanged. `import Network`
  stays: `IPv4Address`/`IPv6Address` are used in `connect` now. `rg -n "extractServerIP|serverIP:|domain_suffix\": \[addr\]" Sources`
  must find nothing.

Behaviour after the step: IP-literal server — identical configs to today. Hostname server —
Logs show `[Resolving <name>...]`, the wrapper's first rule is `ip_cidr` over every resolved
address (`/32` and `/128`), the xray config carries `dns.hosts[<name>]` and
`sockopt.domainStrategy: "UseIP"` on the proxy outbound. A name that does not resolve logs
`[Error: <name> does not resolve]` and nothing starts; Connect again retries.

### 2. Canon and README

Commit: `Record the hostname server rule in the canon`.

`CLAUDE.md`:

- `:72` → `├── BypassService.swift        # Connect-time fitting: bypass rule, TUN IP families, xray server pin; domain input`
- `:100-102`, replace the last sentence of the topology paragraph (from "The bypass rule goes
  into it") with:

```
The bypass rule goes into it through
the same `BypassService.injectSingBox` that handles a sing-box server config. xray's own
connection to its server enters that TUN as well and is routed `direct` by address (`ip_cidr`),
never by name: it arrives as an IP, before `sniff`, and the SNI a sniff would read is the REALITY
camouflage name. A server given as a hostname is resolved by the app at connect
(`BypassService.resolveAddresses`, off the main actor — `connect` parks itself the way it waits
for a stop), every address goes into the wrapper's rule, and the xray config gets the same
addresses pinned in xray's own DNS (`dns.hosts` + `sockopt.domainStrategy: UseIP`,
`BypassService.pinXrayServer`), so xray cannot dial one the wrapper does not route direct and
never asks the system resolver — which a tunnel may already be carrying. An IP-literal server's
xray config is written as the subscription produced it.
```

- `:246` → `` - `$TMPDIR/warpveil-xray-<pid>.json` — xray config; for a server given by name, with that name pinned to the resolved addresses ``
- Gotchas, after the "domain rule placed before `sniff`" entry (`:256-259`), add:

```
- The wrapper's server rule is `ip_cidr`, never `domain_suffix`: xray's dial to its server arrives
  as an IP, and what a sniff would read is the REALITY camouflage SNI (`rust-lang.org` on the live
  log), not the server's name — a domain rule for the server never matches and the dial loops
  back into xray
- sing-box's `process_path`/`process_name` rules read `net.inet.tcp.pcblist_n`, which macOS 27
  answers with an empty list for a process without `com.apple.private.network.statistics`
  (`netstat` has it, the bundled engines do not; root is untested) — not a way to route an
  engine's own traffic
```

`README.md:75` → `├── BypassService.swift        # Bypass rule, TUN IP families, xray server pin, domain input normalization`.

Then move this file to `plans/done/` and run `/code-review` (canon workflow, step 3).

## Verification

### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
```

Expect `BUILD SUCCEEDED` after each step, no new warnings. Never `swift build`.

### 2. `swiftc` harness over the real `BypassService.swift`

After step 1. `main.swift` carries a copy of `buildXrayConfig`'s shape and of the wrapper's
server rule (both `private`), so a change to either has to be mirrored here. It also writes
`wrapper.json` for `sing-box check` and needs the network for the `resolve:` cases.

```bash
mkdir -p "$TMPDIR/hostname-harness" && cd "$TMPDIR/hostname-harness"
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
func outbound(_ c: String, _ i: Int = 0) -> [String: Any] { (parse(c)["outbounds"] as! [[String: Any]])[i] }
func sockopt(_ c: String, _ i: Int = 0) -> [String: Any]? { ((outbound(c, i)["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]) }
func hosts(_ c: String) -> [String: Any]? { (parse(c)["dns"] as? [String: Any])?["hosts"] as? [String: Any] }

// Copy of SubscriptionService.buildXrayConfig's shape for a REALITY xhttp server.
func xrayConfig(address: String) -> String {
    json(["log": ["loglevel": "info"],
          "inbounds": [["tag": "socks-in", "port": 10808, "listen": "127.0.0.1", "protocol": "socks", "settings": ["udp": true]] as [String: Any]],
          "outbounds": [["protocol": "vless", "tag": "proxy", "mux": ["enabled": false],
                         "settings": ["vnext": [["address": address, "port": 443, "users": [["id": "x", "encryption": "none", "flow": ""]]] as [String: Any]]],
                         "streamSettings": ["network": "xhttp", "security": "reality", "xhttpSettings": ["path": "/p", "mode": "auto"],
                                            "realitySettings": ["serverName": "rust-lang.org", "fingerprint": "chrome", "publicKey": "k", "shortId": "s"]] as [String: Any]] as [String: Any],
                        ["protocol": "freedom", "tag": "direct"] as [String: Any]],
          "routing": ["domainStrategy": "AsIs", "rules": [] as [[String: Any]]] as [String: Any]])
}

let name = "203-0-113-20.sslip.io"
let addresses = ["203.0.113.20", "2001:db8::1"]

check(BypassService.xrayServerHost(xrayConfig(address: name)) == name, "xrayServerHost: vnext address")
check(BypassService.xrayServerHost(xrayConfig(address: "1.2.3.4")) == "1.2.3.4", "xrayServerHost: IP literal comes back as is")
var trojan = parse(xrayConfig(address: name)); var ob = (trojan["outbounds"] as! [[String: Any]])
ob[0] = ["protocol": "trojan", "tag": "proxy", "settings": ["servers": [["address": "trojan.example", "port": 443, "password": "p"] as [String: Any]]]] as [String: Any]
trojan["outbounds"] = ob
check(BypassService.xrayServerHost(json(trojan)) == "trojan.example", "xrayServerHost: trojan servers[0].address")
var serviceFirst = parse(xrayConfig(address: name)); serviceFirst["outbounds"] = Array((serviceFirst["outbounds"] as! [[String: Any]]).reversed())
check(BypassService.xrayServerHost(json(serviceFirst)) == name, "xrayServerHost: skips an outbound without settings")
check(BypassService.xrayServerHost("not json") == nil && BypassService.xrayServerHost("{}") == nil, "xrayServerHost: nil on junk")

let pinned = BypassService.pinXrayServer(xrayConfig(address: name), host: name, addresses: addresses)
check((hosts(pinned)?[name] as? [String]) == addresses, "pin: dns.hosts carries the addresses")
check((sockopt(pinned)?["domainStrategy"] as? String) == "UseIP", "pin: proxy outbound dials by IP")
check(sockopt(pinned, 1) == nil, "pin: other outbounds untouched")
check(((outbound(pinned)["streamSettings"] as! [String: Any])["realitySettings"] as! [String: Any])["serverName"] as? String == "rust-lang.org", "pin: REALITY serverName kept")
check((parse(pinned)["dns"] as! [String: Any]).count == 1, "pin: no dns servers invented")
var existing = parse(xrayConfig(address: name))
existing["dns"] = ["servers": ["1.1.1.1"], "hosts": ["example.com": "1.1.1.1"], "queryStrategy": "UseIPv4"] as [String: Any]
var eob = (existing["outbounds"] as! [[String: Any]]); var ss = eob[0]["streamSettings"] as! [String: Any]
ss["sockopt"] = ["tcpFastOpen": true, "domainStrategy": "AsIs"] as [String: Any]; eob[0]["streamSettings"] = ss; existing["outbounds"] = eob
let pinnedExisting = BypassService.pinXrayServer(json(existing), host: name, addresses: ["203.0.113.20"])
check((hosts(pinnedExisting)?["example.com"] as? String) == "1.1.1.1" && (hosts(pinnedExisting)?[name] as? [String]) == ["203.0.113.20"], "pin: existing hosts kept, ours added")
check(((parse(pinnedExisting)["dns"] as! [String: Any])["servers"] as? [String]) == ["1.1.1.1"] && ((parse(pinnedExisting)["dns"] as! [String: Any])["queryStrategy"] as? String) == "UseIPv4", "pin: existing dns fields kept")
check((sockopt(pinnedExisting)?["tcpFastOpen"] as? Bool) == true && (sockopt(pinnedExisting)?["domainStrategy"] as? String) == "UseIP", "pin: existing sockopt kept, strategy overridden")
check(BypassService.pinXrayServer(xrayConfig(address: name), host: "other.example", addresses: addresses) == xrayConfig(address: name), "pin: unknown host leaves the config alone")
check(BypassService.pinXrayServer(xrayConfig(address: name), host: name, addresses: []) == xrayConfig(address: name), "pin: no addresses leaves the config alone")
check(BypassService.pinXrayServer("not json", host: name, addresses: addresses) == "not json", "pin: junk unchanged")

check(BypassService.resolveAddresses(of: "203-0-113-20.sslip.io") == ["203.0.113.20"], "resolve: sslip.io name through the system resolver")
check(BypassService.resolveAddresses(of: "203.0.113.20") == ["203.0.113.20"], "resolve: an IPv4 literal is itself")
check(BypassService.resolveAddresses(of: "2606:4700::6810:84e5") == ["2606:4700::6810:84e5"], "resolve: an IPv6 literal is itself")
check(BypassService.resolveAddresses(of: "no-such-host.invalid").isEmpty, "resolve: NXDOMAIN is empty")
check(!BypassService.resolveAddresses(of: "www.cloudflare.com").isEmpty, "resolve: a CDN name gives addresses")

// Copy of ProcessManager.buildTunWrapperConfig's rule for the sing-box check below.
let cidrs = addresses.map { "\($0)/\($0.contains(":") ? 128 : 32)" }
check(cidrs == ["203.0.113.20/32", "2001:db8::1/128"], "wrapper rule: /32 and /128")
let wrapper = json(["log": ["level": "info"],
                    "inbounds": [["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true] as [String: Any]],
                    "outbounds": [["type": "socks", "tag": "xray-proxy", "server": "127.0.0.1", "server_port": 10808] as [String: Any], ["type": "direct", "tag": "direct"] as [String: Any]],
                    "route": ["auto_detect_interface": true, "default_domain_resolver": ["server": "local"] as [String: Any], "final": "xray-proxy",
                              "rules": [["action": "route", "outbound": "direct", "ip_cidr": cidrs] as [String: Any],
                                        ["action": "hijack-dns", "protocol": "dns"] as [String: Any], ["action": "sniff"] as [String: Any]]] as [String: Any],
                    "dns": ["servers": [["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "xray-proxy"] as [String: Any],
                                        ["tag": "local", "type": "tls", "server": "8.8.8.8"] as [String: Any]], "strategy": "prefer_ipv4"] as [String: Any]])
try! wrapper.write(toFile: "wrapper.json", atomically: true, encoding: .utf8)
print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
EOF
swiftc -target arm64-apple-macosx14.0 main.swift \
  "/Users/lortan29/Documents/Home Projects/vpn-swift/Sources/BypassService.swift" -o harness && ./harness \
  && "/Users/lortan29/Documents/Home Projects/vpn-swift/Binaries/sing-box" check -c wrapper.json && echo "wrapper ok"
```

Expect 22 `ok`, `ALL OK`, `wrapper ok`. This exact harness ran green in this run against the
proposed `BypassService.swift`.

### 3. The real server config, named and pinned, through `xray run -test`

Structure check of what step 1 writes for a hostname server, on the owner's actual config shape.
Credentials stay in 0600 scratch files; nothing is printed but the host and addresses.

```bash
mkdir -p "$TMPDIR/hostname-pin" && cd "$TMPDIR/hostname-pin" && umask 077
cat > main.swift <<'EOF'
import Foundation
let a = CommandLine.arguments
let input = try! String(contentsOfFile: a[1], encoding: .utf8)
let host = BypassService.xrayServerHost(input)!
let addresses = BypassService.resolveAddresses(of: host)
try! BypassService.pinXrayServer(input, host: host, addresses: addresses).write(toFile: a[2], atomically: true, encoding: .utf8)
print("pinned \(host) -> \(addresses)")
EOF
swiftc -target arm64-apple-macosx14.0 main.swift \
  "/Users/lortan29/Documents/Home Projects/vpn-swift/Sources/BypassService.swift" -o pin
python3 -I -c "
import json,os
s=json.load(open(os.path.expanduser('~/.config/warpveil/subscriptions.json')))
srv=[x for sub in s for x in sub['servers'] if x['address']=='203.0.113.20:443'][0]
open('live-named.json','w').write(srv['config'].replace('203.0.113.20','203-0-113-20.sslip.io'))"
./pin live-named.json live-pinned.json
"/Users/lortan29/Documents/Home Projects/vpn-swift/Binaries/xray" run -test -config live-pinned.json 2>&1 | tail -1
python3 -I -c "
import json; c=json.load(open('live-pinned.json'))
print(c['dns'], c['outbounds'][0]['streamSettings']['sockopt'], c['outbounds'][0]['settings']['vnext'][0]['address'])"
```

Expect `pinned 203-0-113-20.sslip.io -> ["203.0.113.20"]`, `Configuration OK.`, and
`{'hosts': {'203-0-113-20.sslip.io': ['203.0.113.20']}} {'domainStrategy': 'UseIP'} 203-0-113-20.sslip.io`.
Ran with exactly that outcome in this run.

### 4. Live check (main session, after step 1 — one self-contained script)

Drives the installed app through a hostname server built from the live one: the New Jersey
server with its IP swapped for `203-0-113-20.sslip.io`, in `address` and in the stored config.
The script restarts the tunnel three times (new build on the usual server, the named server,
back to the usual server) and **always** ends by putting the original subscriptions file and
selection back and relaunching; if the tunnel does not return on the new build it puts the
previous `/Applications/WarpVeil.app` back and relaunches that. The session's API access rides on
the tunnel, so nothing here is to be run by hand step by step — save the script and run it once.

Preconditions it checks: the installed copy is running and connected to the New Jersey server
(`selectedServerID` is its id, `autoConnect = 1`), passwordless is installed (no dialogs can be
answered), the repo is at the step-1 commit. It needs the network: ~2–4 min, mostly the build.

```bash
cat > "$TMPDIR/hostname-live-check.sh" <<'EOF'
#!/bin/bash
# Live check for plans/xray-hostname-server.md. Backs up the installed app, installs the build
# from the working tree, connects to a hostname variant of the live server, checks the configs
# and sockets, then restores the original selection and relaunches. Every exit path brings the
# tunnel back: restore_and_relaunch runs on EXIT, and falls back to the backed-up app.
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
APP="/Applications/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"; DOMAIN="com.warpveil.app"
SUBS="$HOME/.config/warpveil/subscriptions.json"
HOST="203-0-113-20.sslip.io"; IP="203.0.113.20"; ADDRESS="$IP:443"
W="$TMPDIR/hostname-live"; mkdir -p "$W"; umask 077
log() { printf '%s %s\n' "$(date +%T)" "$*"; }

app_pid() { pgrep -f "^${BIN}$" | head -1; }
tunnel_ip() { curl -s --max-time 10 https://api.ipify.org || true; }
quit_app() {
    [ -n "$(app_pid)" ] || return 0
    osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 200); do [ -n "$(app_pid)" ] || break; sleep 0.2; done
    [ -z "$(app_pid)" ] || pkill -f "^${BIN}$" || true
    for _ in $(seq 1 50); do ifconfig 2>/dev/null | grep -q "inet 172.19.0.1" || break; sleep 0.2; done
}
# Up when the TUN address is present and the public IP is the expected exit.
wait_tunnel() {   # $1 expected exit ip, $2 seconds
    local deadline=$((SECONDS + $2)) ip
    while [ $SECONDS -lt $deadline ]; do
        if ifconfig 2>/dev/null | grep -q "inet 172.19.0.1"; then
            ip=$(tunnel_ip); [ "$ip" = "$1" ] && { log "tunnel up, exit $ip"; return 0; }
        fi
        sleep 2
    done
    log "tunnel NOT up within $2 s (exit: $(tunnel_ip))"; return 1
}

RESTORED=0
restore_and_relaunch() {
    [ "$RESTORED" = 1 ] && return 0; RESTORED=1
    log "restoring the original selection and subscriptions"
    quit_app
    [ -f "$W/subscriptions.bak" ] && cp "$W/subscriptions.bak" "$SUBS"
    [ -n "${ORIG_SELECTION:-}" ] && defaults write "$DOMAIN" selectedServerID -string "$ORIG_SELECTION"
    open -n "$APP"
    if ! wait_tunnel "$VPN_IP" 90; then
        log "falling back to the previous build"
        quit_app
        rm -rf "$APP" && ditto "$W/WarpVeil.prev.app" "$APP"
        open -n "$APP"
        wait_tunnel "$VPN_IP" 90 || log "STILL DOWN — reconnect by hand in the app"
    fi
}
trap restore_and_relaunch EXIT

# --- preconditions ---
[ -n "$(app_pid)" ] || { log "installed app not running"; exit 1; }
[ "$(defaults read "$DOMAIN" autoConnect 2>/dev/null)" = 1 ] || { log "autoConnect is off"; exit 1; }
[ -f /etc/sudoers.d/warpveil-1-2 ] || { log "passwordless not installed"; exit 1; }
ORIG_SELECTION=$(defaults read "$DOMAIN" selectedServerID)
python3 -I -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if any(x['id']==sys.argv[2] and x['address']==sys.argv[3] for sub in s for x in sub['servers']) else 1)" "$SUBS" "$ORIG_SELECTION" "$ADDRESS" \
    || { log "selection is not the $ADDRESS server"; exit 1; }
VPN_IP=$(tunnel_ip); [ -n "$VPN_IP" ] || { log "no public IP — tunnel down?"; exit 1; }
log "exit IP now: $VPN_IP (both servers are the same box, so it must not change)"
cp "$SUBS" "$W/subscriptions.bak"
rm -rf "$W/WarpVeil.prev.app"; ditto "$APP" "$W/WarpVeil.prev.app"

# --- 1. new build on the usual server (IP literal: configs must be as before) ---
cd "$REPO" && ./install.sh || { log "install.sh failed"; exit 1; }
wait_tunnel "$VPN_IP" 120 || exit 1
PID=$(app_pid)
python3 -I - "$TMPDIR/warpveil-singbox-$PID.json" "$TMPDIR/warpveil-xray-$PID.json" "$IP" <<'PY'
import json, sys
w = json.load(open(sys.argv[1])); x = json.load(open(sys.argv[2])); ip = sys.argv[3]
print("[literal] wrapper rules:", [r.get("action") for r in w["route"]["rules"]], "rule0:", w["route"]["rules"][0])
assert w["route"]["rules"][0]["ip_cidr"] == [ip + "/32"], "wrapper rule changed for an IP literal"
assert "dns" not in x and "sockopt" not in x["outbounds"][0]["streamSettings"], "xray config changed for an IP literal"
print("[literal] xray config untouched: ok")
PY

# --- 2. the hostname variant ---
quit_app
NEW_ID=$(python3 -I - "$SUBS" "$ADDRESS" "$HOST" <<'PY'
import json, sys, uuid, time
path, address, hostname = sys.argv[1:4]
subs = json.load(open(path)); ip = address.split(":")[0]
source = next(s for sub in subs for s in sub["servers"] if s["address"] == address)
server = dict(source, id=str(uuid.uuid4()).upper(), name=source["name"] + " (named)",
              address=address.replace(ip, hostname), config=source["config"].replace(ip, hostname))
subs.append({"id": str(uuid.uuid4()).upper(), "name": "hostname check", "url": "", "isManual": True,
             "engine": server.get("engine", "xray"), "servers": [server], "lastUpdated": time.time() - 978307200})
json.dump(subs, open(path, "w")); print(server["id"])
PY
)
defaults write "$DOMAIN" selectedServerID -string "$NEW_ID"
open -n "$APP"
wait_tunnel "$VPN_IP" 120 || exit 1
PID=$(app_pid)
python3 -I - "$TMPDIR/warpveil-singbox-$PID.json" "$TMPDIR/warpveil-xray-$PID.json" "$HOST" "$IP" <<'PY'
import json, sys
w = json.load(open(sys.argv[1])); x = json.load(open(sys.argv[2])); host, ip = sys.argv[3], sys.argv[4]
print("[named] wrapper rule0:", w["route"]["rules"][0])
assert w["route"]["rules"][0]["ip_cidr"] == [ip + "/32"], "wrapper does not route the resolved address"
assert not any("domain_suffix" in r and host in r["domain_suffix"] for r in w["route"]["rules"]), "a domain rule survived"
ob = x["outbounds"][0]
assert ob["settings"]["vnext"][0]["address"] == host, "xray still dials the literal"
assert x["dns"]["hosts"][host] == [ip] and ob["streamSettings"]["sockopt"]["domainStrategy"] == "UseIP", "xray not pinned"
print("[named] xray pinned:", x["dns"], ob["streamSettings"]["sockopt"])
PY
echo "[named] sockets to the server (xray must dial from 172.19.0.1, sing-box from the LAN address):"
netstat -anv -p tcp | grep "$IP.443" | awk '{print "   ", $4, "->", $5, $6, $(NF-9)}'
echo "[named] wrapper log, last server connections:"
grep "$IP:443" "$TMPDIR/warpveil-1-2.log" | tail -4 | sed 's/^/    /'
if grep "outbound/socks\[xray-proxy\]: outbound connection to $IP:443" "$TMPDIR/warpveil-1-2.log" | tail -200 | grep -q .; then
    log "LOOP: the wrapper handed the server dial back to xray"; exit 1
fi
log "named server OK through the real TUN"
exit 0   # the EXIT trap restores and relaunches
EOF
chmod +x "$TMPDIR/hostname-live-check.sh" && "$TMPDIR/hostname-live-check.sh"
```

Expect, in order: `[literal] wrapper rules: ['route', 'hijack-dns', 'sniff'] … ip_cidr …/32` and
`xray config untouched: ok`; then on the named server `[named] wrapper rule0: {… 'ip_cidr':
['203.0.113.20/32'] …}`, `[named] xray pinned: {'hosts': {'203-0-113-20.sslip.io':
['203.0.113.20']}} {'domainStrategy': 'UseIP'}`, socket lines pairing `172.19.0.1.<port>`
(`xray:<pid>`) with `192.168.1.86.<port>` (`sing-box:<pid>`), wrapper log lines
`outbound/direct[direct]: outbound connection to 203.0.113.20:443` and none through
`outbound/socks[xray-proxy]`, `named server OK through the real TUN`, then the restore and a last
`tunnel up, exit <VPN IP>`. The Logs page shows `[Resolving 203-0-113-20.sslip.io...]` (in-memory
only; the script cannot read it). Afterwards `defaults read com.warpveil.app selectedServerID`
is the original id and `subscriptions.json` has no "hostname check" subscription.

What this does not exercise, and why: a hostname whose answer differs between the app's lookup
and xray's (the pin makes it impossible to observe — xray never looks up); a resolver reached
through the TUN (every resolver here is the LAN router on en0); an IPv6 address in the rule (no
IPv6 on this host); the `[Error: … does not resolve]` path on the real app (select a server whose
name is bogus by editing the copy by hand — not automated here, the restore is the same).

### 5. Visual check (main session, optional)

With the named server selected during Verification 4, the Logs page shows `[Resolving
203-0-113-20.sslip.io...]` immediately followed by `[Connecting...]`; the Servers page lists
"🇺🇸 New Jersey (named)" under "hostname check" with the hostname as its address.

## Out of scope / found in passing

- **`hijack-dns` before `sniff` never fires** in either builder: `protocol: dns` matches the
  sniffed protocol only, and the TUN marks DNS before rules only for `dnsHijackAddress`, which
  the app does not set. A port-53 flow that enters the TUN goes to `final`. On this machine DNS
  never enters the TUN (LAN resolver on en0); on one where it does, every lookup currently rides
  the proxy as plain UDP. The parity plan's DNS item owns the order; this plan's choice is the
  one of the three that does not depend on it.
- **`process_path`/`process_name` on macOS 27**: see Engine facts; recorded in the canon by
  step 2. The owner's `com.warpveil.app` defaults still hold a legacy `singBoxConfig` key (a
  hand-written config from an earlier build) that relied on `process_name: ["xray", "xray.exe"]`
  → direct — unused by this app since the wrapper builder exists, and likely dead on this OS. To
  settle the root question once: `clang -o pcb pcb.c` from the C program in this run's scratch
  (`sysctlbyname("net.inet.tcp.pcblist_n")` walking `xgen_n` records) and run it with
  `osascript -e 'do shell script "…/pcb" with administrator privileges'` — one admin prompt, no
  engine touched. A record count > 0 as root means a root sing-box can match; 48 bytes means it
  cannot.
- **A trojan/shadowsocks/socks xray server had no server rule at all** (`extractServerIP` read
  `vnext` only) and looped even as an IP literal; `serverAddress` reads `servers[0].address` too,
  so step 1 closes it in passing. Reachable only through `?format=xray` feeds and pasted JSON;
  not live-tested (the owner has no such server).
- **A routing edit during the lookup** is captured by the parked connect the way the stop wait
  captures it: the change lands on the next reconnect, not this one. The window is one
  `getaddrinfo` (3 ms here, up to the resolver timeout on a bad network). Same shape as the
  existing stop wait; not changed.
- **xhttp `UdpHop`** (`splithttp/dialer.go:197`) dials addresses it resolved itself; the pin does
  not cover that path. Only with an `xhttpSettings.extra.downloadSettings` hop configuration,
  which the builders never emit.
- **Shared scratch directory**: the session scratchpad's `repo/` was being edited by another
  agent (DNS upstream) while this plan was written; the validation moved to a private
  `scratchpad/xhs/repo`. See the rebase note at the top.

## Validation of this plan

Done in this run, repo untouched except this file (`git status --porcelain` shows only
`plans/xray-hostname-server.md`), no engine of the app's started, stopped or reconfigured, no
network setting touched, `run.sh`/`stop.sh` strings unchanged:

- Baseline `xcodebuild … Debug` into a scratch derived-data dir: `BUILD SUCCEEDED`.
- Step 1 applied to a private scratch copy of the repo (the patch extracted from it is what the
  step text above quotes), `xcodebuild … Debug`: `BUILD SUCCEEDED`, no `Sources/` warnings.
- Verification 2's harness, extracted verbatim, against the proposed `BypassService.swift`:
  22/22 `ok`; `sing-box check` on its `wrapper.json` (v4 `/32` + v6 `/128` in one `ip_cidr`): ok.
- Verification 3 on the owner's real New Jersey config, address swapped to the sslip name:
  `pinned 203-0-113-20.sslip.io -> ["203.0.113.20"]`, `xray run -test` → `Configuration OK.`
  The same test on the harness's dummy-key shape fails only on the dummy REALITY key, as it should.
- Verification 4's `subscriptions.json` edit, run on a **copy** of the file, decoded through the
  real `Models.swift` with a `swiftc` harness: the manual subscription decodes as `xray`, the server
  address and config carry the hostname and no trace of the IP, all eight feed servers intact.
- xray `dns.hosts` + `sockopt.domainStrategy: UseIP` end to end in user space (a local HTTP
  server, `curl --socks5-hostname` through a user-space xray): dialed the pinned address, `Host`
  header kept the name; without the `dns` block the same name failed to resolve.
- sing-box's darwin process searcher: two user-space probes (curl through a `mixed` inbound; curl
  and the bundled xray connecting to the proxy itself so destination equals peer) → `process not
  found` every time; the sysctl behind it returns zero records to this user, sandboxed or not;
  `netstat`'s entitlement and the xnu source read as cited.
- Every symbol named above was read in the source at the cited lines; `203-0-113-20.sslip.io`
  resolved through the system resolver before anything depended on it.
