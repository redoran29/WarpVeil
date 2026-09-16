# Client feature parity: fifteen gaps, one build order

Status: proposed. Written against `52ea455`, macOS 26.6 (Darwin 25.6), Xcode 26.5 SDK, bundled
sing-box 1.14.0 and Xray 26.3.27, deployment target 14.0.

## Owner's ask

"What is a VPN client expected to have in 2026?" — the research is done; this plan turns the
resulting list into work that fits this codebase. All fifteen items are taken. They are numbered
below in **build order**, not in the order they were listed; the original number is in brackets.

Every item is independently shippable and independently committable. Each item names the files,
types and symbols it touches, what it does in each of the two topologies, what it does to a user
config that already carries the key it injects, its failure modes, and an S/M/L effort with the
specific risk. Items 1–8 in build order carry the depth; 9–15 are tighter.

## Verified facts the plan relies on

Checked in this run, not recalled:

- `Binaries/sing-box check` on a synthetic config accepts every key this plan injects:
  `route.rules[].clash_mode`, `process_name`, `process_path_regex`, `route.find_process`,
  `experimental.clash_api.{external_controller,secret,default_mode}`, `dns.final`,
  `dns.strategy`, `inbounds[tun].{interface_name,mtu,stack,route_address,dns_mode}`. The check is
  strict: one unknown key (`bogus_key`) fails it, and the legacy DNS `address` form is rejected
  with the 1.12 migration message. Rule actions: `route`, `reject`, `hijack-dns` and `bypass`
  terminate evaluation; `sniff`, `resolve`, `route-options` do not (rule_action docs).
- `clash_mode` rules match with `strings.EqualFold` (`route/rule/rule_item_clash_mode.go:36`);
  `PATCH /configs` takes `{"mode": "..."}` and calls `SetMode` (`experimental/clashapi/configs.go:62`);
  auth is `Authorization: Bearer <secret>` (`server.go:208-212`), which `PingService.api` already
  sends. `GET /connections` returns `{downloadTotal, uploadTotal, memory, connections: [{id,
  metadata: {network, type, sourceIP, destinationIP, sourcePort, destinationPort, host, dnsMode,
  processPath}, upload, download, start, chains, rule, rulePayload}]}`; `DELETE /connections/{id}`
  closes one, `DELETE /connections` closes all (`connections.go:26-28, 84-104`). The GET is a plain
  HTTP answer unless the request carries `Upgrade: websocket`.
- Process rules: "Only supported on Linux, Windows, and macOS"; `find_process` is only for
  logging "when no process_name/process_path … rules exist" — process lookup is on whenever a
  process rule is present (route docs). `process_path_regex` since 1.10.
- TUN: `stack` is **deprecated since 1.15.0** (tun docs) — the next binary bump removes the knob.
  `strict_route` documents Linux and Windows behaviour only; nothing for macOS. `interface_name` on
  darwin must be `utun<N>` (`sing-tun/tun_darwin.go:99-101`, "bad tun name" otherwise).
  `dns_mode` (1.14) — `native`/`hijack` "set the platform's native interface DNS where possible …
  Apple platforms" — is **not implemented for the CLI**: SagerNet/sing-box#4183 (macOS CLI keeps
  the DHCP resolver on en0 with `dns_mode: hijack`) is closed "not planned", and
  `sing-tun/tun_darwin.go` `setRoutes()` only adds routes (`BuildAutoRouteRanges`) and calls
  `flushDNSCache()`; it never writes a resolver.
- This Mac right now (`scutil --dns`): global resolver `100.100.100.100` on `utun6`
  (Tailscale), en0's scoped resolver `192.168.1.111`. Both are reached through routes more
  specific than sing-box's two `/1` halves, so **system DNS does not enter the tunnel** on this
  machine today; the canon's Key Decision "Ping is a user-space measurement" sentence "which the
  tunnel's hijack-dns catches while it is up" holds only when the global resolver's address is
  routed into the TUN. Item 2 fixes this; its probe re-checks the canon sentence.
- Both builders — `SubscriptionService.buildSingBoxConfigFromOutbound` and
  `ProcessManager.buildTunWrapperConfig` — put `fdfe:dcba:9876::1/126` on the TUN. The project
  memory (`singbox_tun_ipv6_trap.md`, debugged 2026-06-15) records exactly this address as the
  cause of `no route to host` on direct-routed AAAA destinations. Item 2's IPv6 policy defaults
  to removing it.
- pf on macOS: `/etc/pf.conf` carries `anchor "com.apple/*"` and says every component "is
  responsible for enabling and disabling PF via -E and -X" (reference-counted; `pfctl -E` prints
  `Token : <n>`, `pfctl -X <token>` releases it; `pfctl -s References` lists enablers). `pf.conf(5)`
  on this OS documents `user <user>`: "packets of sockets owned by the specified user … For
  outgoing connections initiated from the firewall, this is the user that opened the connection
  … Only TCP and UDP packets can be associated with users". `/bin/bash` is 3.2.57 — no `wait -n`.
  The item-3 ruleset below parses as written: `pfctl -nvf` (dry run, as the user) exits 0 and
  echoes every rule back with `keep state`, `user root` as `user = 0`.
- Subscription headers (3x-ui docs, v2RayTun docs, Xray-core discussion #4877):
  `subscription-userinfo: upload=<bytes>; download=<bytes>; total=<bytes>; expire=<unix>` (each
  field optional), `profile-update-interval: <hours>`, `profile-web-page-url`, `profile-title`.
- Link formats: SIP002 `ss://base64url(method:password)@host:port[/?plugin=…]#tag` (percent-encoded
  userinfo for 2022 ciphers); Hysteria 2 `hysteria2://` or `hy2://auth@host:port/?sni=&insecure=&
  obfs=salamander&obfs-password=&pinSHA256=#name` (v2.hysteria.network URI scheme); TUIC
  `tuic://uuid:password@host:port?congestion_control=&udp_relay_mode=&alpn=&sni=&allow_insecure=#name`
  (v2rayN convention, sing-box outbound fields match 1:1). Xray 26.3 implements ss, trojan,
  vless, vmess — not hysteria2 or tuic; sing-box 1.14 implements all of them
  (`SubscriptionService.vpnTypesSingBox` already lists them).
- SDK: `SMAppService.mainApp` / `register()` / `unregister()` / `status` (`.notRegistered`,
  `.enabled`, `.requiresApproval`, `.notFound`) — macOS 13; `UTType.application` and
  `.applicationBundle`; Carbon `RegisterEventHotKey` present; `Charts.framework` and
  `UserNotifications.framework` present. None are external packages.
- bash.ws DNS-leak API (macvk/dnsleaktest.sh): `GET https://bash.ws/id` → id; resolve
  `<1..10>.<id>.bash.ws`; `GET https://bash.ws/dnsleak/test/<id>?json` → entries with `ip`,
  `country_name`, `asn`, `type` ∈ {`ip`, `dns`, `conclusion`}.

## Already there, or already decided

- **Reconnect after sleep/wake** exists (`ProcessManager.handleWake`, 5 s). The watchdog in item 3
  extends the same `reconnectTask`/`reconnectCount` machinery to engine exits.
- **Domain bypass** exists and is what "Rule" mode routes by; item 1 wraps it, not replaces it.
- **Profiles [10]**: a `Subscription` already is a profile — several configs, each one tap away,
  add/remove/refresh per profile. What is missing is only the *quick switch*: today tapping a
  server while connected changes `selectedServerID` and nothing else — the power button names the
  new server while the tunnel runs the old one. Item 9 is that switch, nothing more.
- **Ping infrastructure** exists; item 6 consumes `PingService.results`.
- **`urltest` in the production config** for auto-select: rejected. It needs every server as an
  outbound of the live engine; the xray servers would need the N-socks-inbound xray that
  `PingService` builds — a third topology under root. Item 6 selects in the app instead.
- **`strict_route` as a kill switch**: cannot be — no macOS behaviour is documented, and it stops
  nothing once the process is gone.
- **In-app updater**: canon, "Binary upgrades ship with the app"; an updater is also an external
  package (Sparkle) which the canon excludes.

## Out of scope

- **Multi-hop**: a second topology per engine (`detour` / `proxySettings` chains) for a feature no
  owner subscription offers.
- **Router configuration**: this is a desktop client; the panel side owns the router.
- **SmartDNS**: needs a resolver service the owner does not run.
- **Simultaneous-device counts**: a panel feature; the client has nothing to show but a number the
  panel does not send.

## Decisions

### D1. The production engine gets a Clash API

Items 1, 7 and 8 (modes, per-app rules' live view, connections) want to see and steer the live
tunnel. The alternative — rewrite the config and reconnect — is what bypass domains do today and
it costs a tunnel bounce plus, without passwordless mode, an admin prompt **per mode switch**; and
the connections view cannot be built by rewriting anything. So the injected sing-box config gets
`experimental.clash_api`:

- **Which process**: in the sing-box topology, the user's config; in the xray topology, the TUN
  wrapper — the only sing-box there, and where all routing already lives (canon). xray itself gets
  nothing.
- **Port**: a free localhost port picked at connect time the way `PingService.freePorts` does,
  never a fixed one (9090 is every Clash client's default and collides). `external_controller:
  "127.0.0.1:<port>"`.
- **Secret**: a fresh `UUID().uuidString` per connect, sent as `Authorization: Bearer`.
- **Security consequence**: a root process listens on loopback. The secret sits in the injected
  config at `$TMPDIR/warpveil-singbox-<pid>.json` (0600, owned by the user) — a process running as
  the same user can read it and then switch modes or close connections, which is no more than that
  process can already do by editing `~/.config/warpveil/subscriptions.json`. Other local users
  cannot read it. Without the secret every request is 401, so a web page in the browser cannot
  drive it either. The API is not exposed beyond loopback.
- **Conflict**: a user config that already has `experimental.clash_api` keeps every key except
  `external_controller` and `secret`, which are replaced; the log says
  `[Clash API: config's external_controller replaced with 127.0.0.1:<port>]`. `external_ui` and
  friends are left alone; `cache_file` is left alone.
- **Effect on ping**: none. `PingService` keeps its own user-space engines; it only shares the
  client type.

Not chosen: config rewrite + reconnect for modes. Not presented as an option beyond this line.

### D2. Kill switch = pf anchor armed by `run.sh`, lifted by `stop.sh`, plus a watchdog

Detailed in item 3. The one-paragraph version: the tunnel's root shell (`run.sh`) loads a
`block out` ruleset into anchor `com.apple/warpveil` before it starts the engines; the rules pass
loopback, packets whose source is the TUN address, everything root opens (the engines run as root),
DHCP, ND, link-local multicast and — toggle, default on — RFC1918. Tunnel up: everything works as
today. Engine dies: the rules stay, user traffic on the physical interface is dropped, the app's
watchdog reconnects. Deliberate disconnect, quit, toggle-off, `stop.sh` from `dev-run.sh`/
`install.sh`, next app launch, or reboot: lifted. A pf enable reference token is taken with
`pfctl -E` and released with `pfctl -X`, so pf state is exactly what it was.

### D3. One injection pass, one settings value, one rule block, both topologies

`BypassService` grows from "domains" to "everything WarpVeil says about routing" and the TUN
wrapper builder moves into it, so both topologies get their rules from one function. The
parameters travel as one `TunnelSettings` struct (value type, no protocol) that replaces the
5-tuple `lastConnection`. Every injection keeps the user's own keys and rules; where WarpVeil's
intent and the config's collide, the rule is per key (stated per item) and always logged.

### D4. System DNS is routed into the TUN, not rewritten

Because the CLI does not set the resolver (facts above), WarpVeil adds a `/32` route into the TUN
for each address in `State:/Network/Global/DNS` → `ServerAddresses` via `route_address`, and a
`hijack-dns` in the tunnel answers them. Nothing on the system is modified, nothing has to be
restored after a crash, and the routes vanish with the TUN. The alternative — writing
`State:/Network/Service/<id>/DNS` from `run.sh` — needs a restore path on every exit including
the ones this plan exists to survive. Item 2.

### D5. Rule order inside the injected block

Top to bottom, first match wins:

1. `sniff` (inserted at the top only when the config has none — today `injectSingBox` appends it
   *after* the bypass rule, where a preceding `route` already terminated evaluation)
2. the config's own `hijack-dns` (never added, never moved)
3. resolver addresses → `direct` (item 2; non-DNS traffic to the router keeps working)
4. per-app rules (item 7): proxy list → proxy tag, direct list → `direct`
5. `clash_mode: Global` → proxy tag; `clash_mode: Direct` → `direct` (item 1)
6. bypass domains → `direct` (today's rule)
7. …the config's own rules…, then `route.final`

App rules above mode rules means: an app pinned direct stays direct in Global, an app pinned to
the proxy stays proxied in Direct — "only these apps through the VPN" is Direct + a proxy list.
The mode governs everything not pinned. The block is inserted at the first index whose rule is
terminal (`action` absent, `route`, `reject`, `bypass`, `hijack-dns`) — after the config's leading
`sniff`/`resolve`/`route-options` actions — so those keep running first.

## Build order and dependencies

| # | Item | Effort | Depends on |
|---|------|--------|------------|
| 1 | Routing modes + Clash API foundation [3] | M | — |
| 2 | DNS through the tunnel, custom upstream, IPv6 policy [8] | M | 1 (`TunnelSettings`) |
| 3 | Kill switch + watchdog [1] | L | 2 (else LAN DNS relies on Allow-LAN); 1 for the settings struct |
| 4 | Launch at login + drop notification [9] | S | 3's crash hook (adds it itself if 3 is dropped) |
| 5 | Subscription auto-update + userinfo [2] | S/M | — |
| 6 | Auto-select fastest server [5] | M | — |
| 7 | Per-app split tunneling [4] | M | 1 |
| 8 | Active connections page [6] | M | 1 |
| 9 | Server quick switch (the "profiles" gap) [10] | S | — |
| 10 | TUN MTU [13] | S | 1 |
| 11 | More link formats, clipboard and QR import [7] | M (links) / L (Clash YAML) | — |
| 12 | Traffic chart [11] | S/M | 2's `SystemNetwork` for the interface fix (optional) |
| 13 | Leak check [15] | M | more meaningful after 2 and 3 |
| 14 | Global hotkey [12] | S | — |
| 15 | Backup / export / import [14] | S/M | last: it enumerates every key the others add |

`@AppStorage` keys added, all listed here so item 15 has one source: `routingMode`, `dnsUpstream`,
`dnsCustomAddress`, `ipv6Policy`, `killSwitch`, `killSwitchAllowLAN`, `autoReconnect`,
`launchAtLogin` (mirror only), `notifyOnDrop`, `subscriptionRefreshHours`, `proxyApps`,
`directApps`, `tunMTU`, `globalHotkeyEnabled`. Existing: `autoConnect`, `bypassDomains`,
`bypassEnabled`, `selectedServerID`, `sidebarExpanded`.

Canon rule that every item obeys: a key `AppState` reads straight from `UserDefaults` is edited by
the one view that also holds its `@AppStorage`; anything two views display is an observable on
`AppState` or a service.

---

## 1. Routing modes Global / Rule / Direct, and the Clash API foundation [3] — M

**Risk**: the injection restructure touches every connect; a wrong insertion index silently
reorders a user's rules. Mitigated by the probe list and by leaving the config's rules untouched
in count and order.

### Files and symbols

- `Sources/Models.swift`: add
  ```swift
  enum RoutingMode: String, CaseIterable { case global = "Global", rule = "Rule", direct = "Direct" }
  ```
  and
  ```swift
  struct TunnelSettings {
      var bypassDomains: [String] = []
      var mode: RoutingMode = .rule
      var apiPort: UInt16
      var apiSecret: String
  }
  ```
  (later items append fields; the struct is a parameter bag, not an abstraction).
- New `Sources/ClashAPI.swift`:
  ```swift
  struct ClashAPI {
      let port: UInt16
      let secret: String
      let session: URLSession
      func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async -> (Data, Int)?
  }
  enum LocalPort {
      static func free(_ count: Int) -> [UInt16]   // moved from PingService.freePorts
      static func isListening(_ port: UInt16) -> Bool  // moved from PingService.isListening
  }
  ```
  `PingService.api(_:query:apiPort:)` becomes a call on a `ClashAPI(port:secret:session:)` value
  built in `measure`; `PingService.freePorts`/`isListening` are deleted in favour of `LocalPort`.
  Two users now, a third in item 8 — the canon's 3-uses bar is met by the time the plan closes.
- `Sources/BypassService.swift`:
  - `injectSingBox(_ json: String, settings: TunnelSettings) -> String` replaces
    `injectSingBox(_:domains:)`; `injectXray(_ json: String, domains: [String])` stays as is (xray
    receives only what the wrapper forwarded; its domain rule is dead weight but harmless — not
    touched, per "don't refactor what wasn't asked for").
  - `buildTunWrapper(serverIP: String?, settings: TunnelSettings) -> String` — moved verbatim from
    `ProcessManager.buildTunWrapperConfig`, then its `rules` come from the shared builder below;
    `extractServerIP(from:)` moves with it.
  - `private static func ruleBlock(_ settings: TunnelSettings, proxyTag: String) -> [[String: Any]]`
    — D5's list; `private static func insert(_ block:, into rules:)` — the insertion index.
  - `private static func proxyTag(of root: [String: Any]) -> String` — `route.final` if present,
    else the first outbound's `tag` (the invariant `PingService.proxyOutbound` already relies on),
    else `"proxy"`.
  - `private static func injectClashAPI(into root: inout [String: Any], settings:)` — D1's
    conflict policy; returns the log line when it replaced something.
  - DNS side of the mode: prepend to `dns.rules` `{"clash_mode": "Direct", "server": "<local tag>"}`
    where the local tag is the config's `type: "local"` server if any, else the wrapper's `local`;
    skipped with a log line when the config has no such server. Global mode resolves through the
    default (`dns.final`).
  - **Conflict**: a config whose `route.rules` already contain a `clash_mode` key gets no mode
    rules from WarpVeil (the user manages modes) and the log says
    `[Routing: config carries its own clash_mode rules — mode switch still applies to them]`;
    the API and `default_mode` are injected regardless, so the picker still drives the user's
    rules.
- `Sources/ProcessManager.swift`:
  - `connect(config:engine:binaryPath:singBoxPath:settings: TunnelSettings)`; `lastConnection`
    becomes `(config: String, engine: Engine, binaryPath: String, singBoxPath: String, settings:
    TunnelSettings)`; `reconnect(settings:)`; `handleWake` passes `params.settings`.
  - `private(set) var api: ClashAPI?` — set in `connect` from `settings`, cleared in `disconnect`
    and in the termination handler.
  - `func setMode(_ mode: RoutingMode) async -> Bool` — `PATCH /configs` with
    `{"mode": mode.rawValue}`; logs `[Routing: mode → Global]` or the failure.
  - `buildTunWrapperConfig` and `extractServerIP` deleted here (moved).
- `Sources/AppState.swift`:
  - `var tunnelSettings: TunnelSettings` computed at connect time: `activeBypassDomains`,
    `RoutingMode(rawValue: defaults.string(forKey: "routingMode") ?? "") ?? .rule`,
    `LocalPort.free(1).first ?? 0` (0 → `pm.connect` logs `[Error: no free local port]` and
    returns), `UUID().uuidString`.
  - `routingChanged()` → `tunnelSettingsChanged()`; the 2 s debounce moves here from
    `RoutingView.scheduleReconnect` as `private var settingsReconnectTask` so item 2's Advanced
    controls share it.
  - `func setRoutingMode(_ mode: RoutingMode)`: `defaults.set`, then if `pm.isRunning` →
    `Task { await pm.setMode(mode) }` — **no reconnect**; the next connect injects
    `default_mode`.
- `Sources/RoutingView.swift`: a first `Section` with `Picker("Mode", selection:)` segmented over
  `RoutingMode.allCases` bound to `@AppStorage("routingMode")` (string) → `onChange` calls
  `app.setRoutingMode`. Footer text under the Domains section when the mode is not Rule:
  "Applies in Rule mode". The domains section stays visible so the list is never hidden state.
- Canon: Architecture line for `BypassService` ("JSON config injection for domain bypass routing"
  → "…for every routing setting; builds the xray TUN wrapper"), a new Key Decision "Clash API on
  the production engine" (D1 text), Gotcha for the insertion index.

### Both topologies

- sing-box: `injectSingBox` inserts the block and the API into the user's config.
- xray: `buildTunWrapper` builds its base as today, then runs the same `ruleBlock` with
  `proxyTag = "xray-proxy"` and the same `injectClashAPI`. The xray config is unchanged.

### Steps (each compiles, each a commit)

1. `TunnelSettings` + `RoutingMode`; thread `settings` through `ProcessManager.connect/reconnect/
   handleWake`, `AppState.connect/tunnelSettingsChanged`, `BypassService.injectSingBox`; move the
   wrapper builder and `extractServerIP` into `BypassService`. Behaviour identical.
2. `ClashAPI.swift`; `PingService` adopts it; `LocalPort` replaces the two private statics.
3. API injection in both topologies; `ProcessManager.api`; `setMode`.
4. Mode rules + DNS rule + `default_mode`; `RoutingView` picker; `AppState.setRoutingMode`.

### Failure modes

- Port taken between `LocalPort.free` and sing-box's bind: sing-box exits with its own bind
  error in Logs; `[Disconnected (exit 1)]`; the next connect picks another port.
- `PATCH` before the API is up (user flips the picker within ~100 ms of connecting): the request
  fails, the log says so, the persisted mode is still injected next connect; the picker shows the
  persisted value. Acceptable — no retry loop.
- A config whose first outbound is a `selector`/`urltest`: `proxyTag` picks it, which is what the
  user's `final` would have done anyway.

### Probes

`sing-box check` on the injected file (add a `[Config check]` step? no — sing-box does it at
start; read the log). With the owner's xray feed: Global → `curl ifconfig.me` shows the exit IP,
Direct → home IP, Rule → exit IP and a bypass domain direct; `GET /configs` shows the mode;
`sing-box` log shows `clash_mode` rule hits. A user config with its own `experimental.clash_api`
on port 9090: the log line, and 9090 is not listening.

---

## 2. DNS through the tunnel, custom upstream, IPv6 policy [8] — M

**Risk**: routing the global resolver into the TUN steals it from another tunnel that owns it. On
this Mac that is Tailscale's MagicDNS (`100.100.100.100` on `utun6`): while connected, `*.ts.net`
names stop resolving (sing-box forwards them upstream, which does not know them). Documented
limitation; the owner decides whether a later exclusion for `100.64.0.0/10` is wanted. Everything
else in this item is additive to today's behaviour.

### Files and symbols

- New `Sources/SystemNetwork.swift` — `enum SystemNetwork` with
  `static func primaryInterface() -> String?` (moved from `PingService.primaryInterface`, same
  `SCDynamicStore` read of `State:/Network/Global/IPv4`) and
  `static func globalResolvers() -> [String]` (`State:/Network/Global/DNS` → `ServerAddresses`,
  IPv4 and IPv6 literals as given). Third user arrives in item 12 (`NetworkMonitor`).
- `Sources/Models.swift`: `TunnelSettings` gains `resolvers: [String]`,
  `dns: DNSUpstream?` (`enum DNSUpstream { case cloudflare, google, quad9, custom(String) }` with
  `var serverEntry: [String: Any]` — presets are DoT `{"type": "tls", "server": ip}`; custom is
  `{"type": "udp", "server": ip}` for a bare IP, `{"type": "https", "server": host, "path": path}`
  (plus `server_port` when the URL has one) for an `https://` URL — sing-box's `https` server
  takes host and path, not a URL — and `{"type": "tls", "server": host}` for `tls://`),
  `ipv6: IPv6Policy`
  (`enum IPv6Policy: String { case off = "off", configDefault = "default" }`).
- `Sources/BypassService.swift`:
  - **Resolver routing** (both topologies, on the `type: "tun"` inbound): `route_address` — if
    absent, set `["0.0.0.0/1", "128.0.0.0/1"] + resolvers.map { "\($0)/32" or "/128" }` (the
    halves are what `auto_route` installs when the key is absent, `BuildAutoRouteRanges`); if
    present (or the deprecated `inet4_route_address`), append the resolver prefixes to the user's
    list and log `[DNS: appended N resolver route(s) to the config's route_address]`. Rule D5-3:
    `{"ip_cidr": [resolver/32…], "outbound": "direct"}` right after the config's `hijack-dns`,
    so port-53 traffic is hijacked and everything else to the router still reaches it.
    Resolvers inside the TUN's own prefix or `127.0.0.0/8` are skipped.
  - **Custom upstream**: add a server `{"tag": "warpveil-dns", "type": <type>, "server": <addr>,
    "detour": <proxyTag>}` to `dns.servers` and set `dns.final = "warpveil-dns"`; the previous
    `final` (or the implicit first server) is logged. The config's servers and rules are kept —
    rules that name their own servers keep working; only the default changes. Off = touch
    nothing.
  - **IPv6 policy** `off` (default): remove IPv6 entries from the tun `address` list and set
    `dns.strategy = "ipv4_only"` when the config has no `strategy`; log when an address was
    removed. `configDefault`: touch nothing. The wrapper builder and
    `SubscriptionService.buildSingBoxConfigFromOutbound` keep writing the v6 address so a
    `configDefault` user gets today's behaviour; the removal is the policy's job.
- `Sources/AppState.swift`: `tunnelSettings` reads `SystemNetwork.globalResolvers()` at connect
  time and the three keys; `NWPathMonitor` (`import Network`, already imported in
  `ProcessManager`) on `AppState` → on a path change while connected, if `globalResolvers()`
  differs from `pm.lastConnection.settings.resolvers`, `tunnelSettingsChanged()`. Without this a
  Wi-Fi hop to a network with another router leaks DNS until the next connect — the wake
  reconnect is the precedent for "reconnect when the network moved".
- `Sources/AdvancedView.swift`: a `Section("DNS")` — `Picker` Config default / Cloudflare /
  Google / Quad9 / Custom (`@AppStorage("dnsUpstream")`), a `TextField` shown for Custom
  (`@AppStorage("dnsCustomAddress")`), `Toggle("IPv6", …)` over `@AppStorage("ipv6Policy")` with
  the subtitle "Off: IPv4 only on the tunnel; the safe default"; `onChange` →
  `app.tunnelSettingsChanged()` (debounced, reconnects).
- Canon: Gotchas — "the CLI never sets the system resolver on macOS; DNS enters the tunnel only
  because WarpVeil routes the resolvers into it" and the Tailscale note; Key Decision "IPv4-only
  TUN by default" citing the recorded trap; fix the ping sentence per the probe's outcome.

### Both topologies

Identical: both configs have a `tun` inbound WarpVeil edits and a `dns` block with a proxy
detour (`xray-proxy` in the wrapper, `proxyTag` in the user's config).

### Steps

1. `SystemNetwork.swift`; `PingService` uses it. 2. Resolver routing + direct rule.
3. IPv6 policy. 4. Custom upstream + Advanced section. 5. Path monitor reconnect.

### Failure modes

- A config with no `tun` inbound (a user JSON that only has outbounds): no routing to edit; the
  log says `[DNS: no tun inbound — resolvers are not routed]`.
- A resolver that is the LAN router: DNS hijacked, the router's admin page still direct (D5-3).
- Custom address unparsable: the picker's row shows red text, the setting is ignored at connect,
  logged.

### Probes

With the tunnel up: `scutil --dns` unchanged; `dig example.com` (system resolver) appears in the
sing-box log as a DNS exchange; `netstat -rn | grep 192.168.1.111` shows a host route on the
utun; `curl http://192.168.1.1` (router) works; leak check (item 13) shows the exit resolver.
IPv6 off: `ifconfig utunN` has no inet6 line; a `no route to host` grep on the log stays empty.

---

## 3. Kill switch + watchdog [1] — L

**Risk**: the highest in the plan — a rule set that is one line wrong blocks the machine, and
`run.sh`/`stop.sh` changes flip passwordless to "off" until re-installed (canon: one prompt).
Mitigated by: the pf ruleset is syntax-checked with `pfctl -nf` before the engines start, the
anchor is lifted on every deliberate path, `pfctl -X` restores pf's enable state, a reboot clears
everything, and the manual escape is one command.

### Mechanism (both parts, and why both)

- **Watchdog** alone leaves a gap: between the engine's death and the new TUN, traffic goes
  direct. That is the leak a kill switch exists to close.
- **pf anchor** alone strands the machine when nobody reconnects. So the anchor blocks, the
  watchdog restores; a deliberate disconnect lifts.

### The ruleset

Written by the app at `$TMPDIR/warpveil-<tag>-pf.conf` (0600) per connect, from the TUN's IPv4
address(es) parsed out of the injected config's `tun.address` (host part of each IPv4 prefix;
`172.19.0.1` for both builders). If no IPv4 address can be parsed, the switch is not armed and the
log says so — never a blind ruleset.

```
# WarpVeil kill switch — anchor com.apple/warpveil. Loaded by run.sh, flushed by stop.sh.
pass out quick on lo0 all
pass out quick from { 172.19.0.1 } to any                 # packets entering the tunnel
pass out quick all user root                               # the engines (and root daemons)
pass out quick proto udp from any port 68 to any port 67   # DHCP
pass out quick inet6 proto ipv6-icmp all                   # neighbour discovery
pass out quick to 224.0.0.0/4                              # link-local multicast (mDNS, SSDP)
pass out quick inet6 to ff00::/8
pass out quick to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }  # Allow LAN, when on
block drop out quick all
```

Why `user root`: sing-box and xray run as root; their dials to the server, the wrapper's `local`
DoT to 8.8.8.8, and direct-routed bypass traffic all come from root sockets, so they pass without
knowing the server address (which for a hostname would need a table). The cost, stated: any root
daemon (`configd`, `apsd`) is not blocked; user apps are. Why source-address, not interface: the
TUN's `utunN` is chosen at start and pinning `interface_name` fails when the unit is taken; the
TUN address is known at injection. Why `quick` everywhere: pf is last-match-wins, and Apple's
anchors evaluate after ours — without `quick` a later `pass` in another anchor could override the
block. Why loopback first: the wrapper reaches xray on `127.0.0.1:10808` and the Clash API lives
there. Known limitations, stated in the toggle's subtitle: other tunnels (Tailscale) are cut while
armed; local servers the user runs (a dev server on :3000) cannot answer LAN clients unless Allow
LAN is on; ICMPv4 is blocked.

### Scripts (`ProcessManager.runShContent`, `stopShContent`, `buildNonPrivilegedShellCommand`, the inline stop in `killVPNProcesses`)

`run.sh` argv becomes `run.sh <singbox> <singbox_cfg> [<xray> <xray_cfg>] [--kill-switch <pf_conf>]`
(argc 2, 3+1… — concretely: accept 2, 4, and either plus the two-token flag at the end;
`validate_arg` the pf file like the configs). Shared shell, in `killPidFileFunction`'s sibling
constant `killSwitchFunctions`:

```bash
KS_TOKEN=/tmp/warpveil-<tag>-pf.token
KS_MARK=/tmp/warpveil-<tag>-killswitch
arm_kill_switch() {   # $1 = rules file
    pfctl -nf "$1" || { echo '[kill switch] rules rejected — not armed'; return 1; }
    if [[ ! -f "$KS_TOKEN" ]]; then
        pfctl -E 2>&1 | sed -n 's/.*Token : \([0-9]*\).*/\1/p' > "$KS_TOKEN"
    fi
    pfctl -a com.apple/warpveil -f "$1" && : > "$KS_MARK" && echo '[kill switch] armed'
}
lift_kill_switch() {
    pfctl -a com.apple/warpveil -F all 2>/dev/null || true
    if [[ -f "$KS_TOKEN" ]]; then pfctl -X "$(cat "$KS_TOKEN")" 2>/dev/null || true; rm -f "$KS_TOKEN"; fi
    rm -f "$KS_MARK"
    echo '[kill switch] lifted'
}
```

- `run.sh`: after the PID-file kills and before the engines, `arm_kill_switch` when the flag is
  present (a rejected ruleset is fatal: exit 1, the app logs `[Disconnected (exit 1)]`, nothing
  armed). The `cleanup` trap (SIGTERM from `helperProcess.terminate()` relayed by sudo) calls
  `lift_kill_switch` — that is a deliberate stop. After `wait` returns on its own — the engine
  died — it does **not** lift; it echoes `[kill switch] engaged — traffic blocked until reconnect
  or disconnect` and exits with the engine's status, which the app's termination handler sees.
- xray branch: `wait` waits for both, so a dead xray under a live wrapper is invisible today
  (traffic blackholes into a socks port nobody answers). bash 3.2 has no `wait -n`; replace the
  `wait` with `while kill -0 $XRAY_PID 2>/dev/null && kill -0 $SINGBOX_PID 2>/dev/null; do sleep 1;
  done; kill $XRAY_PID $SINGBOX_PID 2>/dev/null; wait` so a half-dead topology becomes a full exit
  the watchdog restarts. This is an improvement independent of the switch.
- `stop.sh`: after the two `kill_pid_file` lines, `lift_kill_switch` — always, whether armed or
  not (idempotent). Both osascript fallbacks mirror both scripts exactly (canon).
- The marker `/tmp/warpveil-<tag>-killswitch` is world-readable and is the app's only view of pf
  state (`pfctl -s` needs root).

### App side

- `Sources/ProcessManager.swift`:
  - `var killSwitchEngaged: Bool` — `fileExists(marker)`, refreshed after `connect`, in the
    termination handler, and in `teardownProcess`'s termination (a `terminationHandler` on the
    stop process, new) — that is how the "Lift" button's effect reaches the UI.
  - `connect` writes the pf file when `settings.killSwitch` and passes the flag; the log says
    `[Kill switch on]`.
  - Termination handler (unexpected exit, `self.isRunning` still true): after
    `[Disconnected (exit N)]`, `unexpectedExitCount += 1` (item 4 observes it) and, when
    `settings.autoReconnect`: schedule `reconnectTask` with delays `[2, 5, 10, 30, 60, 60…]`,
    logging `[Reconnecting in N s (attempt K)]`, calling `connect(...)` with `lastConnection`,
    `reconnectCount += 1` on a start (AppState's `observeReconnects` restarts the location timer
    as today). **Passwordless off: one attempt only** — a loop of admin prompts is hostile; after
    it the switch stays engaged with the banner. `disconnect()` cancels the task (existing line).
  - `func liftKillSwitch()` — runs the same stop path as `killVPNProcesses()` (which now lifts);
    used by the banner and by toggle-off while disconnected.
- `Sources/AppState.swift`: `TunnelSettings` gains `killSwitch: Bool`, `allowLAN: Bool`,
  `autoReconnect: Bool` (keys `killSwitch` default false, `killSwitchAllowLAN` default true,
  `autoReconnect` default true). `bootstrap()`: if `pm.killSwitchEngaged` and not running — the
  app was killed or crashed with the switch armed — `connect()` when a server is selected
  (restoring the tunnel is the intent the marker records), else leave the banner up.
- `Sources/ConnectionView.swift` `statusSection`: when `app.pm.killSwitchEngaged && !app.pm.isRunning`
  a red line "Kill switch engaged — traffic is blocked" with a `Button("Lift")` →
  `app.pm.liftKillSwitch()`; `locationSection` shows "Blocked by kill switch" instead of
  "Detection failed" in that state.
- `Sources/AdvancedView.swift` `Section("Connection")`: `Toggle("Kill switch")` with the
  limitation subtitle; `Toggle("Allow local network")` indented under it; `Toggle("Reconnect
  automatically")`. Turning the kill switch off while connected → `tunnelSettingsChanged()`
  (reconnect without the flag → `stop.sh` lifts on the way); while disconnected with the marker
  present → `liftKillSwitch()`.
- `dev-run.sh` `stop_dev` and `install.sh`'s sweep: the `sudo "$DEV_STOP_SH"` path lifts by
  itself; the bare `sudo kill` fallback (no stop.sh installed) must also run
  `sudo pfctl -a com.apple/warpveil -F all` and release the token file the same way — one shared
  shell snippet in each script, mirrored from `lift_kill_switch`.
- Canon: Key Decision "Kill switch" (this section's mechanism, the `user root` cost, the lift
  paths), Runtime Files: `$TMPDIR/warpveil-<tag>-pf.conf`, `/tmp/warpveil-<tag>-pf.token`,
  `/tmp/warpveil-<tag>-killswitch`; Gotcha: manual escape `sudo pfctl -a com.apple/warpveil -F all`.

### What happens, exactly

| Event | pf anchor | Engines | App |
|---|---|---|---|
| Connect with switch on | armed before engines start | started | `[Kill switch on]` |
| Deliberate disconnect / quit / `dev-run.sh --stop` / `install.sh` | lifted by `stop.sh` and by `cleanup` | killed by PID file | `killSwitchEngaged = false` |
| Engine crash, app alive | stays | gone | `[Disconnected (exit N)]`, `[kill switch] engaged`, watchdog reconnects (re-arms idempotently) |
| App killed (SIGKILL), engines alive | stays | keep running, tunnel up | next launch: `run.sh` replaces them via PID files, tunnel restored |
| App killed, engines die later | stays — machine offline for user apps | gone | next launch: `bootstrap` reconnects, or the banner; reboot also clears |
| Toggle off while disconnected | lifted | — | banner gone |
| Ruleset rejected by `pfctl -nf` | never loaded | never started | `[Disconnected (exit 1)]` with the pf error in Logs |

### Steps

1. Scripts: `arm/lift` functions, argv, xray poll loop, `stop.sh` lift, both fallbacks;
   `dev-run.sh`/`install.sh` fallback lift. Passwordless reads as off until re-installed — the
   canon already covers that. 2. `killSwitchEngaged`, pf file writing, the flag, the marker
   plumbing, the banner and toggles. 3. Watchdog with backoff and the passwordless gate.
   4. `bootstrap` reconcile.

### Probes (each on the dev build, passwordless on)

`sudo pfctl -a com.apple/warpveil -sr` shows the rules; `sudo pfctl -s References` lists one
WarpVeil token; `curl --interface en0 https://example.com` fails as the user while connected,
succeeds as root; `sudo kill -9 <sing-box pid>` → all user traffic fails, the log lines above,
reconnect within 2 s, traffic back; disconnect → `pfctl -s References` no longer lists us and
`pfctl -s info` shows the pre-connect state; `kill -9` the app → tunnel still carries traffic;
then kill the engine → offline; relaunch → tunnel back. Then the Tailscale and LAN-printer
cases, so the limitation text is true.

---

## 4. Launch at login and a notification when the tunnel drops [9] — S

**Risk**: none structural. `UNUserNotificationCenter` needs a bundle (it has one) and prompts
once for permission; ad-hoc signed dev builds work.

- `Sources/AdvancedView.swift` `Section("Connection")`: `Toggle("Launch at login")` bound to a
  `Binding(get: { SMAppService.mainApp.status == .enabled }, set: { $0 ? try? register() : try?
  unregister() })` (`import ServiceManagement`); when `status == .requiresApproval` the subtitle
  says "Approve in System Settings" and the row's trailing button calls
  `SMAppService.openSystemSettingsLoginItems()`. No `@AppStorage`: the system is the source of
  truth. The dev build registers its own bundle id — harmless, note it in `dev-run.sh`'s header.
- `Toggle("Notify when the tunnel drops")` over `@AppStorage("notifyOnDrop")` default true.
- `Sources/AppState.swift`: observe `pm.unexpectedExitCount` the way `observeReconnects` observes
  `reconnectCount` (item 3 adds the counter; if item 3 is not built, add it here — three lines in
  the termination handler). On change, when `notifyOnDrop`: `import UserNotifications`,
  `requestAuthorization(options: [.alert, .sound])` lazily, then a `UNNotificationRequest` with
  title "Tunnel dropped", body "<server name> exited (code N)" plus " — kill switch engaged" when
  `pm.killSwitchEngaged`. The wake and routing reconnects do not count as drops (they go through
  `reconnect`/`handleWake`, which set `isRunning = false` before terminating).
- Canon: Tech Conventions — `ServiceManagement` and `UserNotifications` are Apple frameworks
  used from `AppState`/`AdvancedView`, not AppKit.

---

## 5. Subscription auto-update, `subscription-userinfo`, `profile-update-interval` [2] — S/M

**Risk**: `fetchData` is the one fetch path; threading headers through it is mechanical. The
timer's refresh competes with a manual one only through the existing `refreshingIDs` guard.

- `Sources/Models.swift`:
  ```swift
  struct SubscriptionUserInfo: Codable, Equatable { var upload: Int64?; var download: Int64?; var total: Int64?; var expire: Date? }
  ```
  `Subscription` gains `var userInfo: SubscriptionUserInfo?` and `var updateIntervalHours: Int?`.
  `Subscription` uses synthesized `Codable` (only `Server` has a custom decoder), so files that
  predate the fields decode with `nil` — no migration.
- `Sources/SubscriptionService.swift`:
  - `private struct Feed { let data: Data; let headers: [String: String] }`; `fetchData(from:)`
    returns `Feed?` (lower-cased header names from `HTTPURLResponse.allHeaderFields`);
    `fetchAndParseURIs` and `fetchFormattedConfig` return `([Server], [String: String])?`;
    `refreshSubscription` passes the headers to `store(_:engine:in:headers:)`, which parses
    `subscription-userinfo` (split on `;`, then `=`, trimmed; `expire` → `Date(timeIntervalSince1970:)`)
    and `profile-update-interval` (`Int`, hours) into the subscription. A feed that stops sending
    the header clears the value (it is the feed's, not ours).
  - `func refreshDue(defaultHours: Int) async` — every non-manual subscription whose
    `lastUpdated + (updateIntervalHours ?? defaultHours) h` has passed; `defaultHours == 0` means
    only feeds that name an interval refresh.
- `Sources/AppState.swift`: `subscriptionTimer` (`Timer`, 15 min) → `Task { await
  subs.refreshDue(defaultHours: defaults.integer(forKey: "subscriptionRefreshHours")) }`; the key
  is written by `AdvancedView` with default 24 (`defaults.register` is not used anywhere — read as
  `object(forKey:) as? Int ?? 24`, the `bypassEnabled` precedent). `bootstrap` already refreshes
  everything at launch; unchanged.
- `Sources/ServersView.swift` `subscriptionHeader`: a second 11 pt secondary line under the name
  when `userInfo` is present — `"\(used) of \(total) used · expires \(date)"` with
  `ByteCountFormatter` (`.file` style), each part only when its field exists; red when `expire`
  has passed or less than 5 % remains. The header is already a `VStack` per the uniform-pages
  plan, so a second line fits.
- `Sources/AdvancedView.swift`: `Section("Subscriptions")` with a `Picker("Refresh every")`
  Off / 6 h / 12 h / 24 h / 48 h over `@AppStorage("subscriptionRefreshHours")`, subtitle "Feeds
  that send profile-update-interval use their own".
- Steps: 1. headers + model + header line. 2. timer + picker.
- Failure modes: a refresh through an engaged kill switch fails and is retried next tick; a
  refresh that fails leaves the previous servers (existing contract).
- Canon: none beyond the Architecture description of `SubscriptionService`.

---

## 6. Auto-select the fastest server [5] — M

**Risk**: `connect()` becomes async when a measurement is needed; the power button and the
status-menu item must tolerate a few seconds of "Measuring…". No topology change.

- `Sources/AppState.swift`:
  - `static let autoServerID = "auto"`; `var isAutoSelected: Bool { selectedServerID == Self.autoServerID }`.
  - `var selectedServer: Server?` — for auto, the server with the lowest `.delay` in
    `ping.results` across all subscriptions (`.failed` and unmeasured excluded; ties → first);
    `nil` when nothing is measured. `selectedSubscription` derives from that server.
  - `var canConnect: Bool` — `selectedServer != nil || (isAutoSelected && !subs.subscriptions.flatMap(\.servers).isEmpty)`.
    `ConnectionView.powerButton` uses it instead of `selectedServer == nil`; `WarpVeilApp`'s
    status menu enables Connect on it.
  - `connect()`: when auto and `selectedServer == nil`, `Task { await ping.measure(all); connect() }`
    once — `isMeasuringForConnect` (observable) shows "Measuring servers…" in `statusSection`.
    Re-evaluation happens on every fresh connect; the wake/watchdog reconnects reuse
    `lastConnection` (same server) — v1, stated in the row's subtitle. No failover on a failing
    best server in v1: the watchdog reconnects the same one.
- `Sources/PingService.swift`: `func measure(_ servers:) async` = `start(servers)` then
  `await task?.value` — `task` is already the run's handle.
- `Sources/ServersView.swift`: a first `Section` with one row — "Fastest server" with the
  resolved name and ping as its subtitle ("picks the lowest ping at connect") — selectable like a
  server row (`app.selectedServerID = AppState.autoServerID`). The page header rides on this
  section's header now (it is never empty), so `index == 0` in the subscription loop drops; the
  empty-state section stays for the no-subscriptions case.
- `Sources/ConnectionView.swift` `statusSection`: "Auto → <name>" when auto.
- Failure modes: no server measured at all (all `--`): `connect()` logs `[Auto: no reachable
  server]` and stays disconnected; the ping error line on the Servers page already explains why.
- Steps: 1. `measure`, `selectedServer` resolution, `canConnect`. 2. The row and the labels.

---

## 7. Per-app split tunneling [4] — M

**Risk**: attribution. A `.app` is several executables (helpers, XPC services), and background
downloads run in `nsurlsessiond`, which no rule can attribute to the app — stated in the section
footer. Regex on the bundle path catches every executable inside the bundle.

- `Sources/Models.swift`: `struct AppRule: Codable, Identifiable, Hashable { var bundlePath: String;
  var name: String; var id: String { bundlePath } }`; `TunnelSettings` gains `proxyApps`,
  `directApps: [AppRule]`.
- `Sources/RoutingView.swift`: two sections, "Always through the tunnel" and "Always direct",
  each listing its rules (`LabeledContent(name) { path caption + xmark }`) and an "Add app…"
  button → `.fileImporter(isPresented:allowedContentTypes: [.applicationBundle, .application])`
  (`import UniformTypeIdentifiers`) with the panel opened at `/Applications`. The name comes from
  `Bundle(url:)?.infoDictionary` (`CFBundleDisplayName`, else `CFBundleName`, else the file name)
  — Foundation only, so no `NSWorkspace`; no icon (that would need AppKit). Stored as JSON in
  `@AppStorage("proxyApps")` / `("directApps")` strings — the `bypassDomains` pattern: this view
  edits them and holds the `@AppStorage`; `AppState` decodes them at connect time. Change →
  `app.tunnelSettingsChanged()` (debounced reconnect — rules cannot be changed over the API).
- `Sources/BypassService.swift` `ruleBlock`: D5-4 —
  `{"process_path_regex": ["^" + NSRegularExpression.escapedPattern(for: path) + "/"], "outbound": tag}`
  per list (one rule per list, all paths in the array). No `find_process` needed (facts). The
  config's own process rules are kept below ours.
- Both topologies: identical; the wrapper sees the app's socket owner because the app's packets
  enter the TUN directly.
- Failure modes: an app moved after being added — the regex no longer matches; the row shows a
  "not found" caption when `FileManager.fileExists` fails at render. Chrome-style browsers whose
  network process is inside the bundle: fine; apps that route through a system daemon: not
  attributable, footer says so.
- Steps: 1. model + rule injection. 2. The two sections + picker.

---

## 8. Active connections page [6] — M

**Risk**: a grouped `Form` with several hundred rows refreshing every second is the LogView
problem again. Cap at 200 rows (most recent first) and poll only while the page is visible; if the
probe shows >30 ms per refresh at 200 rows, fall back to the `LogView` shape — which would be the
third copy of the Form metrics and the moment to extract them (canon: 3 uses).

- `Sources/ContentView.swift`: `Page.connections = "Connections"`, icon `"network"`, between
  Routing and Advanced.
- New `Sources/ConnectionsView.swift`: grouped `Form`; header "Connections · N" with "Close all"
  (`DELETE /connections`); rows: `host` (or `destinationIP`) `:port` at 14 pt, second line
  `processPath`'s last component · `chains.first` · `↓ bytes ↑ bytes` at 11 pt secondary, trailing
  xmark → `DELETE /connections/{id}`. Not connected → one row "Not connected" (non-empty section,
  canon). `.task(id: app.pm.isRunning)` loop: `while !Task.isCancelled { await refresh();
  try? await Task.sleep(for: .seconds(1)) }`.
- Decoding: `private struct ConnectionsResponse: Decodable { let connections: [TunnelConnection] }`,
  `struct TunnelConnection: Decodable, Identifiable { let id: String; let metadata: Metadata; let
  upload, download: Int64; let start: Date; let chains: [String]; let rule: String }` with
  `.iso8601` dates — typed `Codable` is right here: this is our API response, not a user config
  (the canon's `JSONSerialization` decision is about user configs).
- `Sources/ProcessManager.swift`: `func connections() async -> Data?` and `func closeConnection(_
  id: String?)` over `api` — the third and fourth `ClashAPI` users.
- Both topologies: the wrapper's connections in the xray case (chains `xray-proxy`), which is the
  view that matters — xray's own socks sessions are the same connections one hop later.
- Failure modes: API not ready in the first second — empty list, no error row; `sourceIP` is the
  TUN address for everything — omitted from the row.

---

## 9. Server quick switch — the actual "profiles" gap [10] — S

- `Sources/AppState.swift`: `func selectServer(_ id: String)` — sets `selectedServerID` and, when
  `pm.isRunning`, runs the debounced reconnect (2 s, same task as settings) so a burst of taps costs
  one bounce. `ServersView`'s `onTapGesture` and the auto row call it. The reconnect for a
  *different* server cannot reuse `pm.reconnect` (it replays `lastConnection`): add
  `AppState.reconnect()` = `pm.disconnect()` then, after 1 s (the `pm.reconnect` precedent —
  `run.sh`'s `kill_pid_file` waits for the old engine anyway), `connect()`.
- `Sources/WarpVeilApp.swift` `menuNeedsUpdate`: a "Server" submenu — one item per server grouped
  by subscription (section-style disabled items for names), checkmark on the selection, "Fastest"
  first when item 6 exists — target `selectServerAction(_:)` with `representedObject = id`. Menu
  is rebuilt on open, so nothing is observed.
- Failure modes: switching without passwordless mode costs one prompt — the subtitle under the
  power button already says which server; nothing hidden.

---

## 10. TUN MTU [13] — S

- `stack` is not exposed: deprecated upstream in 1.15, gone on the next binary bump.
- `Sources/Models.swift`: `TunnelSettings.mtu: Int?` (nil = config default).
- `Sources/AdvancedView.swift`: `Section("Tunnel")` with `Picker("MTU")` Default / 1280 / 1400 /
  1500 / 9000 over `@AppStorage("tunMTU")` (0 = default) → `tunnelSettingsChanged()`.
- `Sources/BypassService.swift`: on the `tun` inbound, set `mtu` when the setting is explicit —
  the setting overrides a config value and logs `[TUN: mtu 1500 → 1400]`; Default leaves the
  config's value or absence alone. Both topologies identical.
- Risk: none; sing-box rejects an out-of-range value at start with its own message.

---

## 11. More link formats, clipboard and QR import [7] — M for links, L for Clash YAML

**Risk**: Clash YAML — Foundation has no YAML parser and the canon allows no package. A hand
parser that covers flow-style `- {name: …, type: ss, …}` and block-style scalar keys with one
nested level (`ws-opts:`) is ~150 lines of code with an unbounded tail of panel-specific
formatting. Ship the links first; YAML is its own commit the owner can drop.

- `Sources/SubscriptionService.swift`:
  - `private func parseLink(_ line: String) -> Server?` dispatching on scheme; `addFromURL` and
    `fetchAndParseURIs` call it (the `hasPrefix("vless://") || …` check becomes "parseLink
    returned something").
  - `parseShadowsocksURI` (SIP002 both userinfo forms plus the legacy fully-base64 body;
    `plugin=` → `plugin` / `plugin_opts` split at the first `;`), `parseTrojanURI` (password,
    `sni`, `alpn`, `fp`, `allowInsecure` → `tls.insecure`, transport via the same `ws`/`grpc`
    switch as vless — extract that switch into `transportBlock(_ params:)`, two users;
    `type=xhttp` → xray with `settings.servers[{address, port, password}]`, so `buildXrayConfig`
    gets a protocol switch for `vnext` vs `servers`), `parseHysteria2URI` (`hysteria2://` and
    `hy2://`, `password` = userinfo, `obfs`/`obfs-password` → `obfs {type, password}`, `sni`,
    `insecure`; `mport` port hopping ignored with a log line), `parseTuicURI` (`uuid:password`,
    `congestion_control`, `udp_relay_mode`, `alpn`, `sni`, `allow_insecure`). All sing-box; the
    `protocolType` is the sing-box type name so `ServerRowView.protocolLabel` shows it.
  - `parseFeedBody(_ text: String) -> [Server]` extracted from `fetchAndParseURIs` so a pasted
    multi-link blob or base64 body goes through the same code.
  - Clash YAML (separate commit): detect a body whose first non-comment line is `proxies:` or that
    contains `\nproxies:`; parse only the `proxies` list; map `type: ss|trojan|vless|vmess|
    hysteria2|tuic` fields to the same outbound builders; anything unmapped → skipped with a count
    in the log.
- `Sources/ServersView.swift` `AddSubscriptionSheet`: a "Paste" button that reads
  `NSPasteboard.general.string(forType: .string)` into the field (LogView already writes
  `NSPasteboard` — the canon's AppKit line is already bent for the pasteboard; amend it to say so)
  and, when the text holds several links or a base64 body, adds them as one manual subscription
  "Pasted (N)"; an "Import QR image…" button → `.fileImporter(allowedContentTypes: [.image])` →
  `CIImage(contentsOf:)` + `CIDetector(ofType: CIDetectorTypeQRCode, …)` (`import CoreImage`, not
  AppKit) → `messageString` into the same path. Screen QR scanning is out (Screen Recording
  permission).
- Optional last step: `CFBundleURLTypes` in `Info.plist` for `vless`, `vmess`, `ss`, `trojan`,
  `hysteria2`, `hy2`, `tuic`, and `application(_:open:)` in `AppDelegate` → `subs.addFromURL`,
  so a link click in a browser lands in the app.
- Canon/README: the Features line "add via URL (`vless://`, `vmess://`)" grows.

---

## 12. Traffic chart [11] — S/M

- `Sources/NetworkMonitor.swift`: `struct Sample { let time: Date; let download, upload: Double }`,
  `var history: [Sample]` capped at 60, appended in `tick()`'s main-queue block; `stop()` clears
  it. Also — same file, its own commit — `readBytes` counts every `AF_LINK` interface, so tunnel
  traffic is counted twice (plaintext on utun, ciphertext on en0) and VM bridges add theirs;
  restrict it to `SystemNetwork.primaryInterface()` (item 2's third user), which is what the
  ipwho.is number and the user's mental model refer to.
- `Sources/ConnectionView.swift` `statsSection`: under the two boxes, `Chart(app.net.history)`
  (`import Charts`) with an `AreaMark` + `LineMark` per direction, 56 pt tall, axes hidden,
  `.chartYScale(domain: 0...max(peak, 1024))`, lavender for download, secondary for upload.
  Redraws once per second — the monitor's tick; no extra timer.
- Risk: none; Charts is macOS 13+.

---

## 13. Leak check [15] — M

**Risk**: third-party endpoints. bash.ws is the only DNS-leak API with a documented client
(facts); if it goes away the DNS row shows "unavailable", the IP rows still work. The check runs
as the user, so with the kill switch engaged everything fails — the sheet says "blocked by kill
switch" then.

- New `Sources/LeakCheckService.swift` (`@Observable @MainActor`): `func run() async` filling
  `ipv4: String?` (reuse `LocationService.detect()` → `loc.ip`, `loc.location`), `ipv6: String?`
  (`GET https://api6.ipify.org?format=json`, 5 s; a `nil` answer is the good answer while the
  policy is IPv4-only), `resolvers: [(ip: String, country: String, asn: String)]` and
  `conclusion: String` (bash.ws: `GET /id`, ten `GET https://<n>.<id>.bash.ws/` fired
  concurrently with a 2 s timeout — the lookups are the point, the responses are discarded —
  then `GET /dnsleak/test/<id>?json`, entries typed `dns` → resolvers, `conclusion` → text).
  Verdicts: IPv4 differs from the server's address when `Server.address` is an IP literal and the
  tunnel is up → "IPv4 leaks"; any IPv6 answer while `ipv6Policy == off` → "IPv6 leaks"; the
  conclusion text is shown verbatim.
- `Sources/ConnectionView.swift` `locationSection`: a "Check for leaks" plain button → a sheet
  `LeakCheckSheet` (three `LabeledContent` rows with green/red glyphs, the resolver list, a
  re-run button). `AppState` owns `let leaks = LeakCheckService()` like the other services.
- Both topologies: the check is external; nothing engine-specific.

---

## 14. Global hotkey [12] — S

- `Sources/WarpVeilApp.swift` (the AppKit/Carbon boundary): `import Carbon.HIToolbox`;
  `RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(
  signature: OSType("WVLT"), id: 1), GetApplicationEventTarget(), 0, &ref)` and an
  `InstallEventHandler(GetApplicationEventTarget(), …, [EventTypeSpec(eventClass:
  OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], …)` whose handler toggles
  `app.connect()`/`app.disconnect()`. Registered only while `@AppStorage("globalHotkeyEnabled")`
  is true: `AppDelegate` observes `UserDefaults.didChangeNotification` and (un)registers on the
  flag's edge — a hotkey the user has not asked for must not steal ⌃⌥⌘V from other apps.
- `Sources/AdvancedView.swift`: `Toggle("Global shortcut ⌃⌥⌘V")`. Fixed combination in v1; a
  recorder control is its own later item.
- Risk: none; Carbon hotkeys need no permission (unlike `NSEvent` global monitors).

---

## 15. Backup / export / import [14] — S/M

- New `Sources/BackupDocument.swift`: `struct BackupDocument: FileDocument` (`import
  UniformTypeIdentifiers`, `readableContentTypes = [.json]`) wrapping
  `{"version": 1, "settings": {key: value}, "subscriptions": [Subscription]}` — settings from
  `UserDefaults.standard` filtered to `AppState.settingsKeys` (the list at the top of this plan,
  one `static let` in `AppState`), subscriptions via `JSONEncoder` (already `Codable`).
- `Sources/AdvancedView.swift`: `Section("Backup")` with "Export…" (`.fileExporter(isPresented:
  document:contentType: .json, defaultFilename: "WarpVeil-backup.json")`) and "Import…"
  (`.fileImporter`) → `app.importBackup(_:)`: writes each known key (`defaults.set`), assigns
  `subs.subscriptions` and `subs.save()`, re-reads `selectedServerID`; `@AppStorage` views update
  themselves from the defaults change. The section's footer: "Contains your subscription URLs and
  server credentials".
- Risk: a backup from a newer build with keys this build does not know — ignored, counted in the
  log. Import replaces subscriptions rather than merging: stated in a confirmation dialog.

---

## Closing

Per item: move nothing until every step is in; when an item's reality contradicts this file, fix
this file in the same commit; `/code-review` per item, since each is a shippable unit. The canon
lines named per item are part of the item, not of the close.
