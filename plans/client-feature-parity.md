# Client feature parity: fifteen gaps, one build order

Status: proposed. Written against `5de6c1c` (rebased on 2026-10-13 from `52ea455`, after
`git show dfcdc31:plans/done/routing-bypass-fix.md`), macOS 27.0.1 (Darwin 27.0.0), Xcode 27.0, bundled sing-box
1.14.0 (pins sing-tun v0.9.0-beta.4) and Xray 26.3.27, deployment target 14.0,
`CFBundleShortVersionString` = `1.2`.

## Owner's ask

"What is a VPN client expected to have in 2026?" — the research is done; this plan turns the
resulting list into work that fits this codebase. All fifteen items are taken. They are numbered
below in **build order**, not in the order they were listed; the original number is in brackets.
The next item to build is **1 — DNS through the tunnel** (formerly item 2): it is the one leak
that exists on the owner's machine today, it needs nothing from the others, and items 2 and 3
lean on what it adds. It is written to be implemented without further research; the rest carry
less depth and are brought in line with the code as it is now.

Every item is independently shippable and independently committable. Each item names the files,
types and symbols it touches, what it does in each of the two topologies, what it does to a user
config that already carries the key it injects, its failure modes, and an S/M/L effort with the
specific risk.

## Verified facts the plan relies on

Checked in this run, not recalled. Line numbers are against `5de6c1c`.

### Code

- `Sources/ProcessManager.swift:148-150` `lastConnection` is the 5-tuple `(config, engine,
  binaryPath, singBoxPath, bypassDomains)`; `:353-367` `restart(_:after:)` is the one restart
  path (wake, routing change, IPv6 change): it logs, cancels `reconnectTask`, tears the engines
  down only while running, sleeps on the suspending clock and connects from `lastConnection` as it
  is when the delay ends; `:371-487` `connect` cancels a pending restart, parks itself in
  `reconnectTask` while `teardownProcess` is still running (`:384-395`), records
  `lastConnection` (`:405`), then runs the config of whichever sing-box holds the TUN through
  `prepareTunConfig` = `BypassService.injectSingBox` → `BypassService.fitTunToHost` (`:407-413`),
  the wrapper included (`:431-436`); `:311-328` `watchHostIPv6()` subscribes an `SCDynamicStore`
  on the main queue to `State:/Network/Global/IPv6`; `:340-348` `hostIPv6Changed()` arms one
  5 s check and restarts when the host's answer differs from `tunHasIPv6`; `:538-543`
  `hostIPv6State() -> Bool?` reads through the watcher's store; `:567-631`
  `buildTunWrapperConfig(serverIP:)` builds rules `[server-IP → direct, hijack-dns, sniff]`
  (`:568-589`) with an IPv4-only TUN (`:598`) and `dns.servers` `remote` (DoT 1.1.1.1 via
  `xray-proxy`) + `local` (DoT 8.8.8.8) (`:618-624`); `:636-641` `reconnect(bypassDomains:)`
  compares sets and restarts only while running; `:651-657` `tearDownEngines()`; `:661-669`
  `teardownProcess` / `awaitTeardown(timeout:)`; `:671-699` `killVPNProcesses()` runs `stop.sh`
  or the inline osascript stop and keeps the handle in `teardownProcess`; `:469-477` the
  termination handler reports only for `p === self.helperProcess`.
- `Sources/SubscriptionService.swift:492-529` `buildSingBoxConfigFromOutbound`: the same
  `[hijack-dns, sniff]` order (`:514-517`), IPv4-only TUN (`:501`), the same two DNS servers
  (`:519-525`), `default_domain_resolver: {"server": "local"}`, `auto_detect_interface: true`.
  `:650-680` `parseSingBox` stores the user's whole config with the outbounds reduced; `:739`
  `addManualConfig`. `:104-110` `addFromURL` accepts only `vless://`/`vmess://`; `:219-241`
  `fetchData(from:) -> Data?` drops the response headers; `:243-273` `fetchAndParseURIs`;
  `:275-292` `fetchFormattedConfig`; `:146` `refreshSubscription`, `:198-204` `store(_:engine:in:)`,
  `:206-216` `refreshAll`; `:641-644` `vpnTypesSingBox` lists `shadowsocks`, `trojan`,
  `hysteria2`, `tuic`; `:684-686` `vpnTypesXray`. `Server.address` is `"\(host):\(port)"`
  (`:352`, `:401`, `:676`).
- `Sources/BypassService.swift:12-42` `injectSingBox(_:domains:)` ensures a `direct` outbound and
  puts the bypass rule right after the first unconditional `sniff` (`:44-46`
  `isUnconditionalSniff`: keys ⊆ `type, action, timeout`), inserting one at index 0 when there is
  none; `:55-67` `fitTunToHost(_:hostHasIPv6:)` rewrites every `tun` inbound's `address`;
  `:77-95` `normalizeDomain`, `:100-112` `parseDomains`; the file imports Foundation only. There
  is no `injectXray`.
- `Sources/AppState.swift:49-54` `bypassDomains` is the raw key split on newlines; `:64-68`
  `activeBypassDomains` normalizes each row and deduplicates; `:85-101` `connect()` passes
  `bypassDomains: activeBypassDomains`; `:127-130` `routingChanged()` is not gated on
  `isRunning`; `:156-168` `observeReconnects()` watches `pm.reconnectCount`.
- `Sources/RoutingView.swift:8-9` holds the two bypass `@AppStorage`s; `:67-74`
  `scheduleReconnect()` is the 2 s debounce → `app.routingChanged()`; `:25-42` rows flag a row
  that does not normalize. `Sources/AdvancedView.swift` has `Section("Connection")` (auto-connect,
  passwordless) and `Section("Components")`, one `@AppStorage("autoConnect")`.
- `Sources/PingService.swift:174-188` `api(_:query:apiPort:)` sends `Authorization: Bearer
  <secret>`; `:366-371` `primaryInterface()` and `:392-432` `isListening`/`freePorts` are
  `private static`; `:33` one `secret` per service instance; `:30` `task` is the run's handle;
  `:347-359` `proxyOutbound` takes the first outbound.
- `Sources/ServersView.swift:19-45` the page header rides on `index == 0`'s section header;
  `:36` `onTapGesture { app.selectedServerID = server.id }`; `:114-154` `subscriptionHeader` is an
  **`HStack`** (name, "updated N ago", refresh, trash) — not a `VStack`; `:276` `AddSubscriptionSheet(subs:)`;
  `:217-221` `ServerRowView.protocolLabel`. `Sources/ContentView.swift:7-21` `Page` with four
  cases and SF Symbols. `Sources/WarpVeilApp.swift:95-118` `menuNeedsUpdate` rebuilds the status
  menu on open; `:81-91` `applicationShouldTerminate` waits `awaitTeardown(timeout: 30)`.
  `Sources/NetworkMonitor.swift:57-78` `readBytes` sums every `AF_LINK` interface.
  `Sources/LocationService.swift` exposes `ip`, `location`, `flag`, `detect()`.
- `WarpVeil.xcodeproj/project.pbxproj` is `objectVersion = 56` with explicit file references
  (no synchronized groups): a new Swift file needs four entries — `PBXBuildFile`,
  `PBXFileReference`, a child of the `Sources` group (`EE0000000000000000000002`) and a line in the
  Sources build phase (`CC0000000000000000000001`). Ids are hand-made 24-hex strings; the pair
  `AA/BB…1D` is free, `AA…20` is the icon's. Item 1 adds no file.
- The project builds clean under Xcode 27.0 with `xcodebuild … -configuration Debug` into a scratch
  derived-data dir (baseline and after each of item 1's steps, see "Validation of this plan").

### Engine (read at the pinned tags with `gh api`)

- **A `protocol: dns` rule before `sniff` never matches a TUN packet.** `route/route.go:582-700`
  `matchRule` walks the rules once; a `sniff` action sets `metadata.Protocol` and the walk
  continues with the *next* rule — earlier ones are not revisited. The only place a TUN packet
  gets `Protocol = dns` before the rules is `protocol/tun/inbound.go:523-528, 553-554, 572-576`:
  when its destination address is one of `dnsHijackAddress`, which is `dns_address` if set, else
  the TUN address's successor (`sing-tun/tun.go` `Inet4DNSAddress()` → `172.19.0.2` for
  `172.19.0.1/30`, confirmed by running it); `route.go:101, 240` then hijack it before any rule.
  `PreMatch` (`route.go:316-437`, the first-packet path for UDP flows) walks the same list with
  the same rule: `sniff` peeks the packet, a later `hijack-dns` returns `PreMatchHijackDNS`.
  Reproduced on the bundled binary, see "Validation of this plan".
- **`dns_address` is address-wide, not port-wide**: `JudgeFlow` hijacks every UDP flow to that
  address and `NewConnectionEx` marks every TCP connection to it as DNS, whatever the port — set
  to the LAN router it would turn the router's web page into a DNS stream. Not usable for a LAN
  resolver.
- **The CLI sets no resolver on macOS.** `sing-tun/tun_darwin.go` (v0.9.0-beta.4) only creates the
  utun, adds the routes from `BuildAutoRouteRanges` (`:457-500`) and runs `dscacheutil
  -flushcache` (`:572-574`); nothing reads `DNSMode`/`DNSAddress` there. The 1.14 doc's `dns_mode:
  native` ("per-interface DNS on … Apple platforms") is the NetworkExtension path;
  SagerNet/sing-box#4183 ("macOS CLI TUN dns_mode=native/hijack does not set Apple interface DNS")
  is closed `not_planned`. `tun_darwin.go` never reads `StrictRoute`.
- **`auto_route` on darwin installs eight sub-ranges, not two halves**: `sing-tun/tun_rules.go:109-215`
  `BuildAutoRouteRanges` — `1/8, 2/7, 4/6, 8/5, 16/4, 32/3, 64/2, 128/1` (so `0.0.0.0/8` is never
  routed); the live table on this Mac shows exactly those on `utun4`. With `route_address` set the
  list is **replaced** by the user's; with `route_exclude_address` set the ranges go through a
  `netipx.IPSetBuilder` (add, then remove) and come out canonical — a `/32` inside a wider range
  survives only if its neighbours are excluded. Run with the real package (Go program below):
  excluding the eight siblings of `192.168.1.1` inside `192.168.1.0/24` yields 31 routes including
  `192.168.1.1/32`; excluding the siblings of `.1` and of `.2` separately removes **both** (each
  one's `/31` sibling covers the other) — the carve has to be computed as a set.
- `inbounds[tun].route_exclude_address` with an IPv6 prefix and no IPv6 address, `dns.servers` of
  type `local`, `udp`, `tls`, `https` (by hostname, with only `route.default_domain_resolver`),
  `dns.rules[].{domain_suffix,clash_mode,action,server}`, `dns.final`, `experimental.clash_api.default_mode`,
  `inbounds[tun].{mtu,dns_mode,dns_address}`, `route.find_process`, `process_path_regex` all pass
  `Binaries/sing-box check`; one unknown key (`bogus_key`) fails it.
- `dns/transport/local` on darwin (`local_darwin.go`, `local_shared.go`, `systemconfig/source_darwin.go`):
  reads mDNSResponder's resolver config, picks the resolver scoped to the default interface (else
  the unscoped one), and dials it with `dns.NewLocalDialer` → `dialer.NewWithOptions(DialerOptions)`
  — `common/dialer/default.go:105` binds that dialer to the default interface under
  `route.auto_detect_interface`, the same bind the `direct` outbound gets. `.local` names go to
  mDNSResponder's socket. So a `local` server keeps working after its resolver is routed into
  the TUN, and so does a direct dial to the resolver address.
- `common/sniff/sniff.go:25-37` `Skip` only for ports 25, 465, 587, 143, 993, 110, 995 — port 53 is
  sniffed; `common/sniff/dns.go` sets only `metadata.Protocol`, never `Domain`.
- `dns/rule` `domain_suffix` matching is the route rule's: `.ru` covers the zone, `example.com`
  covers `www.example.com` (seen in the user-space run: `dns: match[0] domain_suffix=[ifconfig.me
  .ru] => route(warpveil-system)` for `ya.ru`).
- Clash API at v1.14.0: `experimental/clashapi/server.go:271-274` `Authorization: Bearer`;
  `configs.go:28, 62-63` `PATCH /configs` `{"mode": …}` → `SetMode`;
  `connections.go:26-28` `GET /`, `DELETE /`, `DELETE /{id}`, `:38-41, 86-103` the JSON shape
  (`downloadTotal`, `uploadTotal`, `connections[].{id, metadata, upload, download, start, chains,
  rule, rulePayload}`), `:109` plain HTTP unless `Upgrade: websocket`;
  `route/rule/rule_item_clash_mode.go:35` `strings.EqualFold`.
- TUN docs at v1.14.0: `interface_name` on darwin must be `utun<N>` (`tun_darwin.go:99-101` "bad
  tun name"); `process_path_regex` since 1.10; `find_process` is "for logging when no
  process_name/process_path … rules exist"; `stack` is listed under "Changes in sing-box 1.8.0"
  — the 1.14.0 docs do **not** deprecate it (the dev-branch docs seen on 2026-10-12 did, for
  1.15; not re-checked here). Item 10 still leaves it alone.

### This Mac (2026-10-13)

- `scutil --dns`: one resolver, `192.168.1.1`, `if_index 11 (en0)`, repeated in the scoped
  section; `State:/Network/Global/DNS` → `ServerAddresses: [192.168.1.1]`;
  `State:/Network/Global/IPv4` → `PrimaryService 5649C6AF-…`, `PrimaryInterface en0`, `Router
  192.168.1.1`; `State:/Network/Service/<id>/IPv4` → `Addresses: [192.168.1.86]`, `SubnetMasks:
  [255.255.255.0]`; no `…/IPv6` key, no `State:/Network/Global/IPv6`. `/etc/resolv.conf`:
  `nameserver 192.168.1.1`.
- `route -n get 192.168.1.1` → `en0`; `route -n get 8.8.8.8` → `utun4` via `172.19.0.1`. The
  live tunnel (installed 1.2, xray topology, `utun4`, `address ["172.19.0.1/30"]`) carries the
  eight sub-ranges and a host route for its own address; its 7303-line log has no `inbound
  packet connection to …:53` line — **every system DNS query goes to the ISP resolver in the
  clear**. `hijack-dns` never fires; the `dns` block is used only as `default_domain_resolver`.
- `defaults read com.warpveil.app`: `autoConnect = 1`, `bypassDomains = ""`, `selectedServerID`
  set; passwordless is installed (`/etc/sudoers.d/warpveil-1-2`, `/usr/local/libexec/warpveil-1-2`).
  Go 1.24 is at `/opt/homebrew/bin/go`; `/bin/bash` is 3.2.57 (no `wait -n`).

### Tooling, SDK, pf, external services

- `swiftc -target arm64-apple-macosx14.0` compiles a file that uses `SMAppService.mainApp.{status,
  register(), unregister()}`, `.notRegistered/.enabled/.requiresApproval/.notFound`,
  `SMAppService.openSystemSettingsLoginItems()`, `UTType.application/.applicationBundle/.image/.json`,
  `RegisterEventHotKey`/`EventHotKeyID`/`kVK_ANSI_V`, `UNUserNotificationCenter`, `NWPathMonitor`,
  `CIDetector`, `Chart`+`AreaMark` — none are external packages.
- pf on macOS 27: `/etc/pf.conf` carries `anchor "com.apple/*"` and says components enable and
  disable PF "via -E and -X" (reference-counted). The item-3 ruleset below parses as written:
  `pfctl -nvf` (dry run, as the user, loads nothing) echoes every rule back with `keep state` and
  `user root` as `user = 0`. `pf.conf(5)` `user <user>` ("packets of sockets owned by the specified
  user … only TCP and UDP") and `pfctl -s References` were verified on 2026-10-12 on macOS 26.6,
  not re-run here.
- bash.ws DNS-leak API (macvk/dnsleaktest.sh): `GET https://bash.ws/id` → id; resolve
  `<1..10>.<id>.bash.ws`; `GET https://bash.ws/dnsleak/test/<id>?json` → entries with `ip`,
  `country_name`, `asn`, `type` ∈ {`ip`, `dns`, `conclusion`}. Subscription headers
  (`subscription-userinfo`, `profile-update-interval`, `profile-web-page-url`, `profile-title`)
  and the SIP002 / Hysteria 2 / TUIC link formats: from the 3x-ui, v2RayTun, hysteria and v2rayN
  docs on 2026-10-12, unchanged since. Xray 26.3 implements ss, trojan, vless, vmess — not
  hysteria2 or tuic; sing-box 1.14 implements all of them.

## Already there, or already decided

- **IPv6 policy [8]** is done: `BypassService.fitTunToHost` gives the TUN the host's IP families at
  every connect (`State:/Network/Global/IPv6`), and `ProcessManager.watchHostIPv6` restarts the
  engines once a change of that key holds for 5 s. No setting is exposed — the host decides —
  and this plan adds none. Item 1 only widens that watcher to the DNS key.
- **Reconnect after sleep/wake** exists (`restart(_:after:)` from `handleWake`, 5 s). The watchdog
  in item 3 reuses `restart` for engine exits.
- **Domain bypass** exists and is what "Rule" mode routes by; item 2 wraps it, not replaces it.
- **Profiles [10]**: a `Subscription` already is a profile — several configs, each one tap away,
  add/remove/refresh per profile. What is missing is only the *quick switch*: today tapping a
  server while connected changes `selectedServerID` and nothing else — the power button names the
  new server while the tunnel runs the old one. Item 9 is that switch, nothing more.
- **Ping infrastructure** exists; item 6 consumes `PingService.results`.
- **`urltest` in the production config** for auto-select: rejected. It needs every server as an
  outbound of the live engine; the xray servers would need the N-socks-inbound xray that
  `PingService` builds — a third topology under root. Item 6 selects in the app instead.
- **`strict_route` as a kill switch**: cannot be — `tun_darwin.go` never reads it, and it stops
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
- **An xray server given by hostname loops in the wrapper** (bypass plan, found in passing): open
  with the owner; no current server is a hostname.

## Decisions

### D1. The production engine gets a Clash API

Items 2, 7 and 8 (modes, per-app rules' live view, connections) want to see and steer the live
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

### D2. Kill switch = pf anchor armed by `run.sh`, lifted by `stop.sh`, plus a watchdog

Detailed in item 3. The one-paragraph version: the tunnel's root shell (`run.sh`) loads a
`block out` ruleset into anchor `com.apple/warpveil` before it starts the engines; the rules pass
loopback, packets whose source is the TUN address, everything root opens (the engines run as root),
DHCP, ND, link-local multicast and — toggle, default on — RFC1918. Tunnel up: everything works as
today. Engine dies: the rules stay, user traffic on the physical interface is dropped, the app's
watchdog reconnects. Deliberate disconnect, quit, toggle-off, `stop.sh` from `dev-run.sh`/
`install.sh`, next app launch, or reboot: lifted. A pf enable reference token is taken with
`pfctl -E` and released with `pfctl -X`, so pf state is exactly what it was. This is the one item
that changes `run.sh`/`stop.sh`: the owner's installed passwordless scripts read as stale until
the toggle is flipped on again (one prompt).

### D3. One injection pass, one settings value, one rule block, both topologies

`BypassService` grows from "domains" to "everything WarpVeil says about routing" and the TUN
wrapper builder moves into it, so both topologies get their rules from one function. The
parameters travel as one `TunnelSettings` struct (value type, no protocol) that replaces the
`lastConnection` tuple, which item 1 has already grown to six fields. Every injection keeps the
user's own keys and rules; where WarpVeil's intent and the config's collide, the rule is per key
(stated per item) and always logged. The connect-time passes that already exist — `injectSingBox`,
`fitTunToHost`, item 1's `routeSystemDNS` and `setUpstream` — keep their shape (pure
`String → String` or `String → (config, notes)` statics) and are folded into the single pass by
item 2, not rewritten.

### D4. System DNS is routed into the TUN by carving the resolver out of its subnet — nothing on the system is set

Because the CLI sets no resolver on macOS and routes only its eight sub-ranges (facts above), a
LAN resolver such as `192.168.1.1` stays under the connected `192.168.1.0/24` route and its
queries never enter the tunnel. The fix is in the config, not in the system: the resolver's
siblings inside its subnet go into the TUN's `route_exclude_address`, so sing-tun's range builder
emits the resolver as a `/32` route of its own, which beats the connected route; the rule order
becomes `sniff` → `hijack-dns`, so the query is recognised and answered by sing-box's DNS module
through the tunnel; a rule routes any other traffic to the resolver address `direct` (bound to
the physical interface, as the server address already is). Bypassed domains are resolved by the
system resolver through a `local` DNS server. The routes vanish with the TUN, nothing needs
restoring after a crash, and `run.sh`/`stop.sh` do not change.

Rejected: `route_address` (replaces the default ranges, and a `/32` inside a wider range is
merged away as soon as any exclude exists); `dns_address` (hijacks every port to that address);
setting the system DNS to `172.19.0.2` with `networksetup`/`scutil` from `run.sh` (needs root in
the scripts → passwordless stale, and a restore path on every exit including the ones item 3
exists to survive; `networksetup` writes `Setup:` keys that persist across reboots). The one
assumption only a live tunnel can confirm is that mDNSResponder's unscoped queries follow the
host route rather than a socket bound to `en0`; item 1's live check tests exactly that, and the
fallback if it fails is the `run.sh` route above — the owner's call, stated there.

### D5. Rule order inside the injected block

Top to bottom, first match wins, after item 2:

1. the config's own rules up to and including its first unconditional `sniff` (one is inserted
   at the top when there is none — the wrapper's server-IP rule stays above it)
2. `hijack-dns` with `protocol: dns` (item 1 guarantees one right after the sniff; a dead one a
   stored config carries *before* the sniff is left in place)
3. resolver addresses → `direct` (item 1; non-DNS traffic to the router keeps working)
4. per-app rules (item 7): proxy list → proxy tag, direct list → `direct`
5. `clash_mode: Global` → proxy tag; `clash_mode: Direct` → `direct` (item 2)
6. bypass domains → `direct` (today's rule; item 1 leaves it where `injectSingBox` puts it,
   between the sniff and the hijack — a DNS packet has no `Domain`, so the order of 2 and 6 is
   immaterial; item 2 moves it into the block)
7. …the config's remaining rules…, then `route.final`

App rules above mode rules means: an app pinned direct stays direct in Global, an app pinned to
the proxy stays proxied in Direct — "only these apps through the VPN" is Direct + a proxy list.
The mode governs everything not pinned. Item 2's block is anchored right after the `hijack-dns`
that follows the first unconditional `sniff`, which item 1 makes certain exists.

## Build order and dependencies

| # | Item | Effort | Depends on |
|---|------|--------|------------|
| 1 | DNS through the tunnel + custom upstream [8] | M | — |
| 2 | Routing modes + Clash API foundation [3] | M | 1 (`proxyTag`, the `warpveil-system` server, the shared debounce, the six-field tuple it replaces) |
| 3 | Kill switch + watchdog [1] | L | 1 (LAN DNS enters the tunnel, so the ruleset needs no DNS hole); 2 for the settings struct |
| 4 | Launch at login + drop notification [9] | S | 3's crash hook (adds it itself if 3 is dropped) |
| 5 | Subscription auto-update + userinfo [2] | S/M | — |
| 6 | Auto-select fastest server [5] | M | — |
| 7 | Per-app split tunneling [4] | M | 2 |
| 8 | Active connections page [6] | M | 2 |
| 9 | Server quick switch (the "profiles" gap) [10] | S | — |
| 10 | TUN MTU [13] | S | 2 |
| 11 | More link formats, clipboard and QR import [7] | M (links) / L (Clash YAML) | — |
| 12 | Traffic chart [11] | S/M | — |
| 13 | Leak check [15] | M | more meaningful after 1 and 3 |
| 14 | Global hotkey [12] | S | — |
| 15 | Backup / export / import [14] | S/M | last: it enumerates every key the others add |

Why 1 moved ahead of the modes: it is the leak the owner has today; it threads two parameters
through `connect` that item 2 then folds into `TunnelSettings` (cheaper than building the struct
first and the DNS second, since the struct's shape is decided by what the DNS needs); item 2's
"Direct mode resolves locally" rule reuses the `warpveil-system` server item 1 adds; item 3's
ruleset has no DNS exception to design because item 1 puts DNS inside the tunnel.

`@AppStorage` keys added, all listed here so item 15 has one source: `dnsUpstream`,
`dnsCustomAddress` (item 1), `routingMode`, `killSwitch`, `killSwitchAllowLAN`, `autoReconnect`,
`launchAtLogin` (mirror only), `notifyOnDrop`, `subscriptionRefreshHours`, `proxyApps`,
`directApps`, `tunMTU`, `globalHotkeyEnabled`. Existing: `autoConnect`, `bypassDomains`,
`bypassEnabled`, `selectedServerID`, `sidebarExpanded`. (The defaults domain also carries
`singBoxConfig`, `xrayConfig`, `singBoxPath`, `xrayPath`, `geoAssetsLastUpdate`, `bypassCleanedV2`
from builds before 1.1 — nothing reads them; item 15 ignores them.)

Canon rule that every item obeys: a key `AppState` reads straight from `UserDefaults` is edited by
the one view that also holds its `@AppStorage`; anything two views display is an observable on
`AppState` or a service.

---

## 1. DNS through the tunnel and a custom upstream [8] — M

**Risk**: the engine side is verified down to the kernel route list (sing-tun's own builder, run
here) and the rule walk (the bundled binary, run here); the one thing only a live tunnel can show
is whether mDNSResponder's queries obey the new host route (D4). The live check below answers it
on the first deploy; the fallback is named. Everything else in the item is additive and logged.

### Mechanism, in the order a query travels

1. **The route.** `routeSystemDNS` reads, per `tun` inbound, the resolvers configd reports and
   the primary service's subnets. A resolver inside a local subnet is carved out:
   `route_exclude_address` gets the prefixes of *subnet minus resolver(s)* — for `192.168.1.1`
   in `192.168.1.0/24` the eight siblings `192.168.1.128/25 … 192.168.1.2/31, 192.168.1.0/32` —
   computed as a set over all routed resolvers of that subnet. sing-tun then installs
   `192.168.1.1/32 → 172.19.0.1 (utunN)` next to the usual ranges (31 routes instead of 8; the
   rest of the `/24` keeps its connected route, as it effectively did before). A public resolver
   (8.8.8.8) is already inside the ranges and gets no carve. Loopback, link-local (including
   `fe80::1%en0`, the usual RA resolver — unroutable by design), the TUN's own `172.19.0.2`, and
   an IPv6 resolver while the TUN has no IPv6 address are skipped, each with a log line.
2. **The rules.** `[…, sniff, hijack-dns (protocol: dns), route(ip_cidr: [resolver/32…]) →
   direct, …]`. Both builders flip to `sniff` first; for a stored config (manual server, failed
   refresh, `?format=singbox` feed, pasted JSON) `routeSystemDNS` inserts a live `hijack-dns` right
   after the first unconditional sniff when none follows it, and leaves a dead one above the sniff
   alone (never reorders a user's rules). `route.auto_detect_interface` is set when absent — a
   dial to the carved resolver that is not bound to the physical interface would re-enter the TUN.
3. **The answer.** The DNS module resolves through the config's default server (`remote`, DoT
   1.1.1.1 through the proxy — or the upstream the owner picks in Advanced, step 4), except for
   **bypassed domains**: `injectSingBox` prepends a DNS rule `{"domain_suffix": <bypass list>,
   "action": "route", "server": "warpveil-system"}` and adds `{"type": "local", "tag":
   "warpveil-system"}` — the system resolver, dialled bound to `en0`. A bypassed site is reached
   from here, so its name is resolved from here: the ISP-side answer is the geo-correct one, and a
   fakeip server in a user config would otherwise hand the direct dial an address nobody serves.
   That query leaves in the clear to the LAN resolver, as every query does today; the destination
   is reached directly anyway, so it reveals nothing the connection does not.
4. **The watcher.** `watchHostIPv6` becomes `watchHostNetwork`: `State:/Network/Global/DNS` joins
   the IPv6 key; the same 5 s single check compares `hostDNS()` with what the running TUN was
   given and restarts on a difference, so a Wi-Fi hop to another router does not leak until the
   next connect.

What a user config keeps: its `route_exclude_address` (ours are appended; if its own exclude
already covers the resolver, nothing is routed and the log says so), its `route_address` (if it
leaves the resolver out, nothing is routed and the log says so), its rules, its DNS servers and
rules (ours go first), its `dns.final` unless an upstream is chosen.

### Files and symbols

`Sources/Models.swift` — two value types at the end of the file:

```swift
// What the host resolves with, read from configd at connect time: its resolver list and the
// primary service's subnets, so a resolver on the LAN can be carved out of its subnet into
// the TUN.
struct HostDNS: Equatable {
    var resolvers: [String] = []
    var localSubnets: [String] = []
}

// Advanced → DNS. Presets are DNS over TLS by address; custom takes an address (plain UDP),
// `tls://host[:port]` or `https://host[:port][/path]`, read by BypassService.upstreamFields.
enum DNSUpstream: Equatable {
    case cloudflare, google, quad9
    case custom(String)

    static func stored(preset: String, custom: String) -> DNSUpstream? {
        switch preset {
        case "cloudflare": return .cloudflare
        case "google": return .google
        case "quad9": return .quad9
        case "custom":
            let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .custom(text)
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .quad9: "Quad9"
        case .custom(let text): text
        }
    }
}
```

`DNSUpstream` must not reach into `BypassService` (a first draft put the address parsing in
`Models.swift` and the compiler reported `BypassService` "has no member Address" — a member-lookup
cycle between the two files); the sing-box shape lives in `BypassService.upstreamFields`.

`Sources/BypassService.swift` — `injectSingBox` keeps its contract and shares two helpers; a new
`// MARK: - System DNS` section; a new `// MARK: - Upstream` section (step 4). The file still
imports only Foundation (`inet_pton`/`inet_ntop` come with it).

```swift
    static func injectSingBox(_ json: String, domains: [String]) -> String {
        guard !domains.isEmpty,
              var root = parseJSON(json) else { return json }

        ensureDirectOutbound(&root)

        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [[String: Any]] ?? []
        let sniffIndex = ensureSniff(&rules)
        let bypassRule: [String: Any] = [
            "action": "route",
            "outbound": "direct",
            "domain_suffix": domains
        ]
        rules.insert(bypassRule, at: sniffIndex + 1)
        route["rules"] = rules
        root["route"] = route

        // A bypassed destination is reached from here, so its name is resolved from here too:
        // the system resolver, through the DNS module's `local` server, gives the answer the
        // ISP's network expects — the tunnel's upstream would answer for the exit's location,
        // and a fakeip server would hand the direct dial an address nobody serves.
        var dns = root["dns"] as? [String: Any] ?? [:]
        var servers = dns["servers"] as? [[String: Any]] ?? []
        if !servers.contains(where: { ($0["tag"] as? String) == systemServerTag }) {
            servers.append(["type": "local", "tag": systemServerTag])
            dns["servers"] = servers
        }
        var dnsRules = dns["rules"] as? [[String: Any]] ?? []
        dnsRules.insert(["domain_suffix": domains, "action": "route", "server": systemServerTag], at: 0)
        dns["rules"] = dnsRules
        root["dns"] = dns

        return serializeJSON(root) ?? json
    }

    private static let systemServerTag = "warpveil-system"

    private static func ensureDirectOutbound(_ root: inout [String: Any]) {
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        guard !outbounds.contains(where: { ($0["tag"] as? String) == "direct" }) else { return }
        outbounds.append(["type": "direct", "tag": "direct"])
        root["outbounds"] = outbounds
    }

    // The index of the first unconditional sniff, inserting one at the top when there is none.
    private static func ensureSniff(_ rules: inout [[String: Any]]) -> Int {
        if let existing = rules.firstIndex(where: isUnconditionalSniff) { return existing }
        rules.insert(["action": "sniff"], at: 0)
        return 0
    }
```

(The DNS-rule half of `injectSingBox` is step 3; steps 1–2 ship it without the `dns` block.)

```swift
    // MARK: - System DNS

    // The system resolver's queries have to enter the TUN before hijack-dns can see them. On
    // macOS sing-box sets no resolver and routes only its split ranges, and a resolver on the
    // LAN sits under a connected route more specific than those ranges — so the resolver is
    // carved out of its subnet in `route_exclude_address`: with its neighbours excluded,
    // sing-tun's range builder emits the resolver as a host route of its own, which beats the
    // subnet route. `sniff` then marks the query as DNS and `hijack-dns` answers it — the rule
    // has to follow the sniff, a `protocol: dns` rule above it never matches a TUN packet.
    // Anything else sent to the resolver address (the router's admin page) goes direct, bound
    // to the physical interface the way the server address already is.
    static func routeSystemDNS(_ json: String, host: HostDNS) -> (config: String, notes: [String]) {
        guard var root = parseJSON(json),
              var inbounds = root["inbounds"] as? [[String: Any]],
              let tunIndex = inbounds.firstIndex(where: { ($0["type"] as? String) == "tun" })
        else { return (json, ["[DNS: no tun inbound — system DNS stays outside the tunnel]"]) }
        guard !host.resolvers.isEmpty else {
            return (json, ["[DNS: no system resolver — nothing to route]"])
        }

        var tun = inbounds[tunIndex]
        let tunPrefixes = (tun["address"] as? [String] ?? (tun["address"] as? String).map { [$0] } ?? [])
            .compactMap(Prefix.init)
        let tunHasIPv6 = tunPrefixes.contains { !$0.address.isIPv4 }
        let routeAddress = (tun["route_address"] as? [String] ?? []).compactMap(Prefix.init)
        var excludes = tun["route_exclude_address"] as? [String] ?? []
        let userExcludes = excludes.compactMap(Prefix.init)
        let subnets = host.localSubnets.compactMap(Prefix.init)
        var routed: [Address] = []
        var notes: [String] = []
        var seen = Set<String>()

        for text in host.resolvers where seen.insert(text).inserted {
            guard !text.contains("%"), let resolver = Address(text), !resolver.isLocalOnly else {
                notes.append("[DNS: resolver \(text) is link-local or loopback — not routed into the tunnel]")
                continue
            }
            if tunPrefixes.contains(where: resolver.isInside) { continue }
            if !resolver.isIPv4, !tunHasIPv6 {
                notes.append("[DNS: resolver \(text) is IPv6 and the tunnel has none — not routed]")
                continue
            }
            if let covering = userExcludes.first(where: resolver.isInside) {
                notes.append("[DNS: config's route_exclude_address \(covering.text) covers \(text) — stays outside the tunnel]")
                continue
            }
            if !routeAddress.isEmpty, !routeAddress.contains(where: resolver.isInside) {
                notes.append("[DNS: config's route_address leaves \(text) out — stays outside the tunnel]")
                continue
            }
            routed.append(resolver)
        }
        guard !routed.isEmpty else { return (json, notes) }

        for subnet in subnets {
            let inside = routed.filter { $0.isInside(subnet) }
            guard !inside.isEmpty else { continue }
            for prefix in carve(subnet, around: inside) where !excludes.contains(prefix) {
                excludes.append(prefix)
            }
        }

        if !excludes.isEmpty { tun["route_exclude_address"] = excludes }
        inbounds[tunIndex] = tun
        root["inbounds"] = inbounds
        ensureDirectOutbound(&root)

        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [[String: Any]] ?? []
        let sniffIndex = ensureSniff(&rules)
        var hijackIndex = sniffIndex + 1
        if let existing = rules[(sniffIndex + 1)...].firstIndex(where: { ($0["action"] as? String) == "hijack-dns" }) {
            hijackIndex = existing
        } else {
            rules.insert(["action": "hijack-dns", "protocol": "dns"], at: hijackIndex)
        }
        rules.insert([
            "action": "route",
            "outbound": "direct",
            "ip_cidr": routed.map { "\($0.text)/\($0.bitCount)" }
        ], at: hijackIndex + 1)
        route["rules"] = rules
        // A dial to the routed resolver has to leave by the physical interface, or it re-enters
        // the TUN it was just routed into.
        if route["auto_detect_interface"] == nil {
            route["auto_detect_interface"] = true
            notes.append("[DNS: auto_detect_interface enabled — the config had none]")
        }
        root["route"] = route
        notes.append("[DNS: system resolver \(routed.map(\.text).joined(separator: ", ")) routed into the tunnel]")
        return (serializeJSON(root) ?? json, notes)
    }

    // "192.168.1.86" + "255.255.255.0" → "192.168.1.0/24", as configd reports a service.
    static func subnet(address: String, mask: String) -> String? {
        guard let address = Address(address), let mask = Address(mask), mask.isIPv4 else { return nil }
        let bits = mask.bytes.reduce(0) { $0 + $1.nonzeroBitCount }
        return Prefix(address: address.masked(bits), bits: bits).text
    }

    // The subnet minus the addresses, as prefixes: a half with none of them is emitted whole,
    // a half with one is split further. Excluding the result leaves each address as a host
    // route of its own. Done as a set, not per address: with two resolvers in one subnet the
    // siblings of one cover the other.
    static func carve(_ subnet: Prefix, around addresses: [Address]) -> [String] {
        let inside = addresses.filter { $0.isInside(subnet) }
        if inside.isEmpty { return [subnet.text] }
        if subnet.bits == subnet.address.bitCount { return [] }
        let bits = subnet.bits + 1
        var upper = subnet.address.masked(bits).bytes
        upper[(bits - 1) / 8] |= 0x80 >> ((bits - 1) % 8)
        return carve(Prefix(address: subnet.address.masked(bits), bits: bits), around: inside)
            + carve(Prefix(address: Address(bytes: upper), bits: bits), around: inside)
    }

    struct Address: Equatable {
        let bytes: [UInt8]

        init(bytes: [UInt8]) { self.bytes = bytes }

        init?(_ text: String) {
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, text, &v4) == 1 {
                bytes = withUnsafeBytes(of: &v4) { Array($0) }
            } else if inet_pton(AF_INET6, text, &v6) == 1 {
                bytes = withUnsafeBytes(of: &v6) { Array($0) }
            } else {
                return nil
            }
        }

        var isIPv4: Bool { bytes.count == 4 }
        var bitCount: Int { bytes.count * 8 }

        // Loopback and link-local cannot be routed into a tunnel.
        var isLocalOnly: Bool {
            if isIPv4 { return bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254) }
            return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes == [UInt8](repeating: 0, count: 15) + [1]
        }

        var text: String {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return bytes.withUnsafeBufferPointer { pointer in
                inet_ntop(isIPv4 ? AF_INET : AF_INET6, pointer.baseAddress, &buffer, socklen_t(buffer.count))
                return String(cString: buffer)
            }
        }

        func masked(_ bits: Int) -> Address {
            Address(bytes: bytes.enumerated().map { index, byte in
                let keep = max(0, min(8, bits - index * 8))
                return keep == 0 ? 0 : byte & UInt8(truncatingIfNeeded: 0xff << (8 - keep))
            })
        }

        func isInside(_ prefix: Prefix) -> Bool {
            bytes.count == prefix.address.bytes.count && masked(prefix.bits) == prefix.address.masked(prefix.bits)
        }
    }

    struct Prefix {
        let address: Address
        let bits: Int

        init(address: Address, bits: Int) {
            self.address = address
            self.bits = bits
        }

        init?(_ text: String) {
            let parts = text.split(separator: "/", maxSplits: 1)
            guard let address = Address(String(parts[0])) else { return nil }
            let bits = parts.count == 2 ? Int(parts[1]) : address.bitCount
            guard let bits, (0...address.bitCount).contains(bits) else { return nil }
            self.init(address: address, bits: bits)
        }

        var text: String { "\(address.text)/\(bits)" }
    }
```

```swift
    // MARK: - Upstream

    // Advanced → DNS. The chosen server becomes the default for everything the DNS module
    // answers and is reached through the proxy; the config's own servers and rules stay, so a
    // rule that names its server keeps it, and bypassed domains keep the system resolver.
    static func setUpstream(_ json: String, upstream: DNSUpstream) -> (config: String, notes: [String]) {
        guard var root = parseJSON(json) else { return (json, []) }
        guard var fields = upstreamFields(upstream) else {
            return (json, ["[DNS: custom upstream \(upstream.label) is not an address — config default kept]"])
        }
        var dns = root["dns"] as? [String: Any] ?? [:]
        var servers = (dns["servers"] as? [[String: Any]] ?? []).filter { ($0["tag"] as? String) != upstreamServerTag }
        let previous = dns["final"] as? String ?? servers.first?["tag"] as? String ?? "none"
        fields["tag"] = upstreamServerTag
        fields["detour"] = proxyTag(of: root)
        servers.append(fields)
        dns["servers"] = servers
        dns["final"] = upstreamServerTag
        root["dns"] = dns
        return (serializeJSON(root) ?? json, ["[DNS: upstream \(upstream.label) through the proxy replaces \(previous)]"])
    }

    private static let upstreamServerTag = "warpveil-dns"

    // The sing-box server fields without tag and detour; nil when the custom text is not usable.
    static func upstreamFields(_ upstream: DNSUpstream) -> [String: Any]? {
        switch upstream {
        case .cloudflare: return ["type": "tls", "server": "1.1.1.1"]
        case .google: return ["type": "tls", "server": "8.8.8.8"]
        case .quad9: return ["type": "tls", "server": "9.9.9.9"]
        case .custom(let text):
            if Address(text) != nil { return ["type": "udp", "server": text] }
            guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
                  let scheme = components.scheme, ["https", "tls"].contains(scheme) else { return nil }
            var fields: [String: Any] = ["type": scheme, "server": host]
            if let port = components.port { fields["server_port"] = port }
            if scheme == "https", !components.path.isEmpty, components.path != "/" { fields["path"] = components.path }
            return fields
        }
    }

    // The outbound a config sends unmatched traffic to: `route.final`, else the first outbound.
    static func proxyTag(of root: [String: Any]) -> String {
        if let final = (root["route"] as? [String: Any])?["final"] as? String, !final.isEmpty { return final }
        return (root["outbounds"] as? [[String: Any]])?.first?["tag"] as? String ?? "proxy"
    }
```

`Sources/SubscriptionService.swift:514-517` and `Sources/ProcessManager.swift:568-571` — the
builders' rule literal becomes

```swift
                // sniff first: a `protocol: dns` rule matches only after the sniff has run.
                "rules": [
                    ["action": "sniff"] as [String: Any],
                    ["action": "hijack-dns", "protocol": "dns"] as [String: Any]
                ]
```

(the wrapper's `var rules` likewise, its server-IP rule still inserted at 0).

`Sources/ProcessManager.swift`:

- `:154-157` the stored state gains `private var tunDNS = HostDNS()` and `private static let
  globalDNSKey = "State:/Network/Global/DNS"`; `ipv6Watcher` → `hostWatcher`, `ipv6CheckTask` →
  `hostCheckTask` (step 2).
- `connect` (`:407-413`) — the passes, with the log lines collected and appended after the
  `[Bypass]` line (`:438-440`):

```swift
        // Whichever sing-box holds the TUN gets the bypass rule, the host's IP families, its
        // resolvers and the chosen upstream.
        let hostHasIPv6 = hostIPv6State() ?? true
        tunHasIPv6 = hostHasIPv6
        let host = hostDNS()
        tunDNS = host
        var notes: [String] = []
        func prepareTunConfig(_ json: String) -> String {
            let injected = BypassService.injectSingBox(json, domains: bypassDomains)
            let fitted = BypassService.fitTunToHost(injected, hostHasIPv6: hostHasIPv6)
            let routed = BypassService.routeSystemDNS(fitted, host: host)
            notes += routed.notes
            guard let dnsUpstream else { return routed.config }
            let upstream = BypassService.setUpstream(routed.config, upstream: dnsUpstream)
            notes += upstream.notes
            return upstream.config
        }
        …
        logs.append(contentsOf: notes)
```

  `routeSystemDNS` runs after `fitTunToHost` because it reads the TUN's address list to know
  whether an IPv6 resolver can be routed.

- new, next to `hostIPv6State()`:

```swift
    // configd's resolver list and the primary service's subnets. The TUN registers no configd
    // service, so both describe the physical network whether or not a tunnel is up.
    private func hostDNS() -> HostDNS {
        guard let store = hostWatcher ?? SCDynamicStoreCreate(nil, "WarpVeil" as CFString, nil, nil) else { return HostDNS() }
        func value(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let resolvers = value(Self.globalDNSKey)?["ServerAddresses"] as? [String] ?? []
        var subnets: [String] = []
        if let service = value("State:/Network/Global/IPv4")?["PrimaryService"] as? String {
            if let ipv4 = value("State:/Network/Service/\(service)/IPv4"),
               let addresses = ipv4["Addresses"] as? [String], let masks = ipv4["SubnetMasks"] as? [String] {
                subnets += zip(addresses, masks).compactMap { BypassService.subnet(address: $0, mask: $1) }
            }
            if let ipv6 = value("State:/Network/Service/\(service)/IPv6"),
               let addresses = ipv6["Addresses"] as? [String], let lengths = ipv6["PrefixLength"] as? [Int] {
                subnets += zip(addresses, lengths).map { "\($0)/\($1)" }
            }
        }
        return HostDNS(resolvers: resolvers, localSubnets: subnets)
    }
```

  (`PrefixLength` is `CFArray[CFNumber]` per `SCSchemaDefinitions`; no IPv6 service exists on
  this Mac to see it live. Step 1 reads the store through `ipv6Watcher`; step 2 renames it.)

- `watchHostIPv6` → `watchHostNetwork` with keys `[Self.globalIPv6Key, Self.globalDNSKey]`, the
  failure line `[Cannot watch the network's IPv6 and DNS — reconnect after switching networks]`,
  and `hostIPv6Changed` → `hostNetworkChanged`:

```swift
    private func hostNetworkChanged() {
        guard hostCheckTask == nil else { return }
        hostCheckTask = Task {
            try? await Task.sleep(for: .seconds(5), clock: .suspending)
            hostCheckTask = nil
            guard isRunning else { return }
            if let hostHasIPv6 = hostIPv6State(), hostHasIPv6 != tunHasIPv6 {
                restart("[Network IPv6 changed — reconnecting...]", after: .seconds(1))
            } else if hostDNS() != tunDNS {
                restart("[Network DNS changed — reconnecting...]", after: .seconds(1))
            }
        }
    }
```

- step 4: `lastConnection` gains `dnsUpstream: DNSUpstream?` (six fields); `connect(config:
  engine:binaryPath:singBoxPath:bypassDomains:dnsUpstream:)` with `dnsUpstream: DNSUpstream? =
  nil`, threaded through the parked connect (`:391-392`), `lastConnection = (…, bypassDomains,
  dnsUpstream)`, and `restart`'s connect (`:362-364`);
  `reconnect(bypassDomains:dnsUpstream:)`:

```swift
    func reconnect(bypassDomains: [String], dnsUpstream: DNSUpstream?) {
        guard let params = lastConnection,
              Set(bypassDomains) != Set(params.bypassDomains) || dnsUpstream != params.dnsUpstream
        else { return }
        lastConnection?.bypassDomains = bypassDomains
        lastConnection?.dnsUpstream = dnsUpstream
        guard isRunning else { return }
        restart("[Routing changed — reconnecting...]", after: .seconds(1))
    }
```

`Sources/AppState.swift` (step 4): `private var routingReconnectTask: Task<Void, Never>?`; a
computed `private var dnsUpstream: DNSUpstream?` = `DNSUpstream.stored(preset:
defaults.string(forKey: "dnsUpstream") ?? "", custom: defaults.string(forKey: "dnsCustomAddress")
?? "")` (AdvancedView edits both keys and holds their `@AppStorage` — the bypass precedent);
`connect()` passes `dnsUpstream: dnsUpstream`; `routingChanged()` calls
`pm.reconnect(bypassDomains: activeBypassDomains, dnsUpstream: dnsUpstream)`; the 2 s debounce
moves here from `RoutingView` as `func scheduleRoutingChange()` (it now has two callers):

```swift
    // Every routing change tears the tunnel down and back up, which without passwordless mode
    // means an admin prompt. Adding three domains should cost one, not three.
    func scheduleRoutingChange() {
        routingReconnectTask?.cancel()
        routingReconnectTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            routingChanged()
        }
    }
```

`Sources/RoutingView.swift` (step 4): `reconnectTask` and `scheduleReconnect()` go; both
`.onChange` call `app.scheduleRoutingChange()`.

`Sources/AdvancedView.swift` (step 4): `@AppStorage("dnsUpstream") private var dnsUpstream = ""`,
`@AppStorage("dnsCustomAddress") private var dnsCustomAddress = ""`, and between the Connection
and Components sections:

```swift
            Section {
                Picker("Upstream", selection: $dnsUpstream) {
                    Text("Config default").tag("")
                    Text("Cloudflare").tag("cloudflare")
                    Text("Google").tag("google")
                    Text("Quad9").tag("quad9")
                    Text("Custom").tag("custom")
                }
                if dnsUpstream == "custom" {
                    LabeledContent {
                        TextField("Address", text: $dnsCustomAddress,
                                  prompt: Text(verbatim: "1.1.1.1, tls://host or https://host/dns-query"))
                            .labelsHidden()
                    } label: {
                        Text("Address")
                        if BypassService.upstreamFields(.custom(dnsCustomAddress)) == nil {
                            Text("Not an address — the config's default is used")
                        }
                    }
                }
            } header: {
                Text("DNS")
            } footer: {
                Text("Queries from the system resolver are answered through the tunnel; bypassed domains keep the system resolver.")
            }
            .onChange(of: dnsUpstream) { app.scheduleRoutingChange() }
            .onChange(of: dnsCustomAddress) { app.scheduleRoutingChange() }
```

The footer is a literal with no bare domain in it, so `Text(verbatim:)` is not needed there; the
prompt names `host` only.

### Both topologies

Identical: both configs have one `tun` inbound, a `dns` block with a proxy detour (`xray-proxy` in
the wrapper, the server's tag in a built config) and `auto_detect_interface`. The wrapper's
server-IP rule stays at index 0, above the sniff. The xray config is untouched.

### Steps (each compiles, each a commit)

1. `Route the system resolver into the tunnel` — `HostDNS`; `routeSystemDNS` + `subnet` + `carve`
   + `Address`/`Prefix`; `ensureDirectOutbound`/`ensureSniff` extracted from `injectSingBox`; both
   builders flipped; `ProcessManager`: `tunDNS`, `globalDNSKey`, `hostDNS()`, the pass in
   `connect`, the notes in the log.
2. `Restart when the host's resolvers change` — `watchHostNetwork`, `hostNetworkChanged`, the
   renames.
3. `Resolve bypassed domains through the system resolver` — the `dns` half of `injectSingBox`,
   `systemServerTag`.
4. `Add a DNS upstream setting` — `DNSUpstream`, `setUpstream`/`upstreamFields`/`proxyTag`, the
   six-field tuple and `connect`/`reconnect` parameters, `AppState.scheduleRoutingChange` +
   `dnsUpstream`, `RoutingView` debounce removal, the Advanced section. The owner may drop this
   step; nothing above depends on it.
5. `Record DNS through the tunnel in the canon` — `CLAUDE.md`: Architecture lines
   (`AdvancedView.swift # Auto-connect, passwordless, DNS upstream, components, grouped Form`,
   `BypassService.swift # Connect-time sing-box fitting: bypass, TUN families, DNS; domain input`,
   `Models.swift # Server, Subscription, Engine, HostDNS, DNSUpstream`); a Key Decision "**System
   DNS enters the tunnel by route, not by resolver**" (D4's first paragraph, with the rejected
   alternatives in one line each); Gotchas: replace the "domain rule before `sniff`" entry with
   one that covers `protocol` rules too ("A rule with a `domain_*` or `protocol` condition placed
   before `sniff` never matches a TUN packet — `hijack-dns` with `protocol: dns` included; the
   builders put `sniff` first and `routeSystemDNS` adds a live `hijack-dns` after the sniff when a
   stored config has none there"), add "The CLI sing-box sets no resolver on macOS and `auto_route`
   installs `1/8 … 128/1`, so a LAN resolver stays under its connected route; `routeSystemDNS`
   carves it out with `route_exclude_address` — `route_address` would replace the ranges and lose
   a `/32` to the merge, `dns_address` hijacks every port to that address", add "Two resolvers in
   one subnet are carved as a set: each one's `/31` sibling covers the other", and extend the IPv6
   watcher entry to "a change of either key (IPv6, DNS)"; `README.md`: Features line "**DNS
   through the tunnel** — the system resolver's queries are answered through the VPN; bypassed
   domains keep the system resolver", the two Architecture lines. Then move this item's steps to
   done in this file and run `/code-review`.

### Failure modes

- mDNSResponder binds its queries to `en0` (D4's open assumption): the host route exists, `dig
  @192.168.1.1` is hijacked, but `dscacheutil -q host` queries still leave in the clear and the log
  shows no `dns: exchanged` for them. Then the route approach cannot work on macOS and the
  fallback is a resolver override from `run.sh` (`networksetup -setdnsservers <service>
  172.19.0.2`, restored by `stop.sh` and the `cleanup` trap) — a scripts change, hence a
  passwordless re-install, and a restore path on crash: the owner decides before any of that is
  built. Everything else in this item stays correct and harmless.
- A config with no `tun` inbound: `[DNS: no tun inbound — system DNS stays outside the tunnel]`.
- No resolver at all (no network): `[DNS: no system resolver — nothing to route]`; connect goes
  on as today.
- The config's own `route_exclude_address` covers the resolver, or its `route_address` leaves it
  out: the config is left alone and the log names the prefix.
- Only an IPv6 resolver and no IPv6 on the TUN, or a link-local one: not routed, logged; DNS is
  then where it is today. A dual-stack LAN whose first resolver is `fe80::1` keeps leaking
  through it — only the fallback above can catch link-local resolvers.
- Custom upstream text that is not an address or a `tls://`/`https://` URL: `[DNS: custom
  upstream … is not an address — config default kept]` and the red caption in Advanced. A DoH
  server given by hostname in a config without `route.default_domain_resolver` and with several
  DNS servers: sing-box refuses to start with its own message, `[Disconnected (exit 1)]` — the
  built configs always carry `default_domain_resolver`.
- The resolver's host route makes 31 kernel routes instead of 8; sing-tun removes them all at
  exit (`unsetRoutes` walks the same list).

### What happens to DNS, per query

| Query from | Resolver | Path | Answer comes from |
|---|---|---|---|
| any app, name not bypassed | system (192.168.1.1) | host route → TUN → sniff → hijack-dns → DNS module → `remote` (DoT 1.1.1.1 via proxy) or `warpveil-dns` | the exit side, encrypted |
| any app, bypassed name | system | same hijack → `dns.rules[0]` → `warpveil-system` (`local`, bound to en0) → 192.168.1.1 in the clear | the ISP side, as today |
| an app with its own DoH (browsers) | its own | TCP 443 through the tunnel like any connection | the app's provider |
| the engine resolving a server hostname | `default_domain_resolver` (`local`, DoT 8.8.8.8 direct) | unchanged | unchanged |
| `dig @192.168.1.1` | explicit | host route → TUN → hijacked the same way | sing-box answers in the resolver's name |
| anything else to 192.168.1.1 (router page) | — | host route → TUN → `ip_cidr → direct`, bound to en0 | the router |

### Verification

#### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
```

`BUILD SUCCEEDED` after every step; the two pre-existing `'weak' ownership of capture 'self'`
warnings (`AppState.swift`, `WarpVeilApp.swift`) are not from this plan. Never `swift build`.

#### 2. `swiftc` harness over the real `BypassService.swift` and `Models.swift`

After step 4 (steps 1–3 run the subset above the `// step 3` / `// step 4` marks). `main.swift`
carries copies of the two builders' literals, so a change to `buildSingBoxConfigFromOutbound` or
`buildTunWrapperConfig` has to be mirrored here. The file **must** be named `main.swift` — top-level
code compiles nowhere else.

```bash
mkdir -p "$TMPDIR/dns-harness" && cd "$TMPDIR/dns-harness"
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
func tun(of c: String) -> [String: Any] { (parse(c)["inbounds"] as! [[String: Any]]).first { $0["type"] as? String == "tun" }! }
func excludes(of c: String) -> [String] { tun(of: c)["route_exclude_address"] as? [String] ?? [] }

let tunInbound: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true]
let dns: [String: Any] = ["servers": [["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "proxy"] as [String: Any],
                                      ["tag": "local", "type": "tls", "server": "8.8.8.8"] as [String: Any]], "strategy": "prefer_ipv4"]

// Copy of SubscriptionService.buildSingBoxConfigFromOutbound's literal after step 1.
func serverConfig(rules: [[String: Any]] = [["action": "sniff"], ["action": "hijack-dns", "protocol": "dns"]], tun: [String: Any] = tunInbound) -> String {
    json(["log": ["level": "info"], "inbounds": [tun],
          "outbounds": [["type": "vless", "tag": "proxy", "server": "203.0.113.7", "server_port": 443, "uuid": "x"] as [String: Any],
                        ["type": "direct", "tag": "direct"] as [String: Any]],
          "route": ["auto_detect_interface": true, "default_domain_resolver": ["server": "local"] as [String: Any], "final": "proxy",
                    "rules": rules] as [String: Any],
          "dns": dns])
}
// Copy of ProcessManager.buildTunWrapperConfig's literal after step 1, IP server.
func wrapperConfig() -> String {
    json(["log": ["level": "info"], "inbounds": [tunInbound],
          "outbounds": [["type": "socks", "tag": "xray-proxy", "server": "127.0.0.1", "server_port": 10808] as [String: Any],
                        ["type": "direct", "tag": "direct"] as [String: Any]],
          "route": ["auto_detect_interface": true, "default_domain_resolver": ["server": "local"] as [String: Any], "final": "xray-proxy",
                    "rules": [["action": "route", "outbound": "direct", "ip_cidr": ["203.0.113.7/32"]] as [String: Any],
                              ["action": "sniff"] as [String: Any], ["action": "hijack-dns", "protocol": "dns"] as [String: Any]]] as [String: Any],
          "dns": dns])
}

let lan = HostDNS(resolvers: ["192.168.1.1"], localSubnets: ["192.168.1.0/24"])
let siblings = ["192.168.1.128/25", "192.168.1.64/26", "192.168.1.32/27", "192.168.1.16/28", "192.168.1.8/29", "192.168.1.4/30", "192.168.1.2/31", "192.168.1.0/32"]

// MARK: prefix helpers, against sing-tun's own range builder (Go run in the plan's validation)
check(BypassService.subnet(address: "192.168.1.86", mask: "255.255.255.0") == "192.168.1.0/24", "subnet /24")
check(BypassService.subnet(address: "10.20.30.40", mask: "255.255.0.0") == "10.20.0.0/16", "subnet /16")
check(BypassService.subnet(address: "nope", mask: "255.255.255.0") == nil, "subnet: bad address")
check(Set(BypassService.carve(BypassService.Prefix("192.168.1.0/24")!, around: [BypassService.Address("192.168.1.1")!])) == Set(siblings), "carve .1 out of /24: the eight siblings")
check(BypassService.carve(BypassService.Prefix("10.0.0.0/30")!, around: [BypassService.Address("10.0.0.1")!]) == ["10.0.0.0/32", "10.0.0.2/31"], "carve in a /30")
check(BypassService.carve(BypassService.Prefix("192.168.1.0/24")!, around: [BypassService.Address("192.168.1.1")!, BypassService.Address("192.168.1.2")!]) == ["192.168.1.0/32", "192.168.1.3/32", "192.168.1.4/30", "192.168.1.8/29", "192.168.1.16/28", "192.168.1.32/27", "192.168.1.64/26", "192.168.1.128/25"], "carve .1 and .2: neither is covered")
check(BypassService.carve(BypassService.Prefix("192.168.1.0/24")!, around: [BypassService.Address("10.0.0.1")!]) == ["192.168.1.0/24"], "carve with no address inside: the subnet whole")
check(BypassService.carve(BypassService.Prefix("2001:db8::/64")!, around: [BypassService.Address("2001:db8::1")!]).count == 64 && BypassService.carve(BypassService.Prefix("2001:db8::/64")!, around: [BypassService.Address("2001:db8::1")!]).first == "2001:db8::/128", "64 v6 prefixes, ::0/128 first")
check(BypassService.Address("fe80::1")!.isLocalOnly && BypassService.Address("127.0.0.1")!.isLocalOnly && BypassService.Address("169.254.1.1")!.isLocalOnly && BypassService.Address("::1")!.isLocalOnly, "local-only addresses")
check(!BypassService.Address("192.168.1.1")!.isLocalOnly && !BypassService.Address("2001:db8::1")!.isLocalOnly, "routable addresses")
check(BypassService.Address("192.168.1.77")!.isInside(BypassService.Prefix("192.168.1.0/24")!) && !BypassService.Address("192.168.2.1")!.isInside(BypassService.Prefix("192.168.1.0/24")!), "isInside")
check(BypassService.Address("8.8.8.8")!.isInside(BypassService.Prefix("0.0.0.0/0")!), "isInside /0")
check(BypassService.Prefix("2001:db8::1")?.bits == 128 && BypassService.Prefix("1.2.3.4/33") == nil, "prefix parsing")

// MARK: routeSystemDNS on the server shape
let server = BypassService.routeSystemDNS(serverConfig(), host: lan)
check(actions(of: server.config) == ["sniff", "hijack-dns", "route"], "server: sniff, hijack-dns, resolver→direct")
check((rules(of: server.config)[2]["ip_cidr"] as? [String]) == ["192.168.1.1/32"] && (rules(of: server.config)[2]["outbound"] as? String) == "direct", "server: resolver rule content")
check(Set(excludes(of: server.config)) == Set(siblings) && excludes(of: server.config).count == 8, "server: route_exclude_address carves the resolver out")
check(server.notes == ["[DNS: system resolver 192.168.1.1 routed into the tunnel]"], "server: note \(server.notes)")
check((parse(server.config)["outbounds"] as! [[String: Any]]).count == 2, "server: direct not duplicated")

// stored config from an older build: hijack-dns before sniff stays, a live one is added after the sniff
let stored = BypassService.routeSystemDNS(serverConfig(rules: [["action": "hijack-dns", "protocol": "dns"], ["action": "sniff"]]), host: lan)
check(actions(of: stored.config) == ["hijack-dns", "sniff", "hijack-dns", "route"], "stored order: live hijack-dns inserted after the sniff")

// wrapper shape with a bypass list, in connect's order: injectSingBox → fitTunToHost → routeSystemDNS
let domains = ["example.com", ".ru"]
let wrapper = BypassService.routeSystemDNS(BypassService.fitTunToHost(BypassService.injectSingBox(wrapperConfig(), domains: domains), hostHasIPv6: false), host: lan)
check(actions(of: wrapper.config) == ["route", "sniff", "route", "hijack-dns", "route"], "wrapper: server-IP, sniff, bypass, hijack-dns, resolver")
check((rules(of: wrapper.config)[2]["domain_suffix"] as? [String]) == domains && (rules(of: wrapper.config)[4]["ip_cidr"] as? [String]) == ["192.168.1.1/32"], "wrapper: bypass and resolver rules in place")
check((tun(of: wrapper.config)["address"] as? [String]) == ["172.19.0.1/30"], "wrapper: TUN address kept")

// no sniff at all: one is inserted at the top
let bare = BypassService.routeSystemDNS(serverConfig(rules: [["outbound": "direct", "ip_is_private": true]]), host: lan)
check(actions(of: bare.config) == ["sniff", "hijack-dns", "route", "-"], "no sniff: sniff, hijack-dns, resolver, then the user's rule")

// resolvers that are not routed
let skips = BypassService.routeSystemDNS(serverConfig(), host: HostDNS(resolvers: ["fe80::1%en0", "127.0.0.1", "172.19.0.2", "2001:db8::53"], localSubnets: ["192.168.1.0/24"]))
check(skips.config == serverConfig() && skips.notes.count == 3, "link-local, loopback, TUN-own and v6-without-v6-TUN: unchanged, \(skips.notes.count) notes")
check(skips.notes[0].contains("fe80::1%en0") && skips.notes[1].contains("127.0.0.1") && skips.notes[2].contains("2001:db8::53"), "skip notes name the resolver")
let none = BypassService.routeSystemDNS(serverConfig(), host: HostDNS())
check(none.config == serverConfig() && none.notes == ["[DNS: no system resolver — nothing to route]"], "no resolver: unchanged")
var noTun = parse(serverConfig()); noTun["inbounds"] = [["type": "mixed", "tag": "m", "listen_port": 1] as [String: Any]]
check(BypassService.routeSystemDNS(json(noTun), host: lan).notes == ["[DNS: no tun inbound — system DNS stays outside the tunnel]"], "no tun inbound: note")

// a public resolver: already inside the split ranges, no carve, direct rule only
let pub = BypassService.routeSystemDNS(serverConfig(), host: HostDNS(resolvers: ["8.8.8.8"], localSubnets: ["192.168.1.0/24"]))
check(excludes(of: pub.config).isEmpty && (rules(of: pub.config)[2]["ip_cidr"] as? [String]) == ["8.8.8.8/32"], "public resolver: no carve, direct rule")

// two LAN resolvers share one carve list; duplicates collapse
let two = BypassService.routeSystemDNS(serverConfig(), host: HostDNS(resolvers: ["192.168.1.1", "192.168.1.2", "192.168.1.1"], localSubnets: ["192.168.1.0/24"]))
check((rules(of: two.config)[2]["ip_cidr"] as? [String]) == ["192.168.1.1/32", "192.168.1.2/32"], "two resolvers: both in the rule")
check(excludes(of: two.config) == ["192.168.1.0/32", "192.168.1.3/32", "192.168.1.4/30", "192.168.1.8/29", "192.168.1.16/28", "192.168.1.32/27", "192.168.1.64/26", "192.168.1.128/25"], "two resolvers: one carve, both survive")

// the config's own excludes and route_address
var userEx = parse(serverConfig()); var ib = userEx["inbounds"] as! [[String: Any]]; ib[0]["route_exclude_address"] = ["192.168.0.0/16"]; userEx["inbounds"] = ib
let covered = BypassService.routeSystemDNS(json(userEx), host: lan)
check(covered.config == json(userEx) && covered.notes == ["[DNS: config's route_exclude_address 192.168.0.0/16 covers 192.168.1.1 — stays outside the tunnel]"], "user exclude covers the resolver: untouched, note")
var userRoute = parse(serverConfig()); ib = userRoute["inbounds"] as! [[String: Any]]; ib[0]["route_address"] = ["10.0.0.0/8"]; userRoute["inbounds"] = ib
let left = BypassService.routeSystemDNS(json(userRoute), host: lan)
check(left.config == json(userRoute) && left.notes == ["[DNS: config's route_address leaves 192.168.1.1 out — stays outside the tunnel]"], "user route_address without the resolver: untouched, note")
var userBoth = parse(serverConfig()); ib = userBoth["inbounds"] as! [[String: Any]]; ib[0]["route_exclude_address"] = ["10.0.0.0/8", "192.168.1.128/25"]; userBoth["inbounds"] = ib
let kept = BypassService.routeSystemDNS(json(userBoth), host: lan)
check(excludes(of: kept.config).count == 9 && excludes(of: kept.config).first == "10.0.0.0/8" && Set(excludes(of: kept.config)) == Set(["10.0.0.0/8"] + siblings), "user excludes kept, ours appended without duplicates")

// dual-stack: a global v6 resolver with a v6 TUN address
let dual: [String: Any] = ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "auto_route": true]
let v6 = BypassService.routeSystemDNS(serverConfig(tun: dual), host: HostDNS(resolvers: ["192.168.1.1", "2001:db8:1::1"], localSubnets: ["192.168.1.0/24", "2001:db8:1::/64"]))
check((rules(of: v6.config)[2]["ip_cidr"] as? [String]) == ["192.168.1.1/32", "2001:db8:1::1/128"], "dual-stack: both resolvers")
check(excludes(of: v6.config).count == 8 + 64, "dual-stack: v4 and v6 siblings")

// auto_detect_interface is ensured
var noAuto = parse(serverConfig()); var r = noAuto["route"] as! [String: Any]; r["auto_detect_interface"] = nil; noAuto["route"] = r
let ensured = BypassService.routeSystemDNS(json(noAuto), host: lan)
check((parse(ensured.config)["route"] as! [String: Any])["auto_detect_interface"] as? Bool == true && ensured.notes.first == "[DNS: auto_detect_interface enabled — the config had none]", "auto_detect_interface added when absent")

// step 3: bypassed domains resolve through the system resolver
func dnsRules(of c: String) -> [[String: Any]] { ((parse(c)["dns"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? [] }
func dnsServers(of c: String) -> [[String: Any]] { ((parse(c)["dns"] as? [String: Any])?["servers"] as? [[String: Any]]) ?? [] }
let bypassed = BypassService.injectSingBox(serverConfig(), domains: domains)
check(dnsServers(of: bypassed).count == 3 && dnsServers(of: bypassed).last?["type"] as? String == "local" && dnsServers(of: bypassed).last?["tag"] as? String == "warpveil-system", "bypass: local server appended")
check(dnsRules(of: bypassed).count == 1 && dnsRules(of: bypassed)[0]["domain_suffix"] as? [String] == domains && dnsRules(of: bypassed)[0]["server"] as? String == "warpveil-system" && dnsRules(of: bypassed)[0]["action"] as? String == "route", "bypass: DNS rule sends the domains to it")
var fake = parse(serverConfig()); var d = fake["dns"] as! [String: Any]
d["servers"] = (d["servers"] as! [[String: Any]]) + [["type": "fakeip", "tag": "fakeip", "inet4_range": "198.18.0.0/15"] as [String: Any], ["type": "local", "tag": "warpveil-system"] as [String: Any]]
d["rules"] = [["query_type": ["A", "AAAA"], "action": "route", "server": "fakeip"] as [String: Any]]; fake["dns"] = d
let fakeOut = BypassService.injectSingBox(json(fake), domains: domains)
check(dnsServers(of: fakeOut).count == 4 && dnsRules(of: fakeOut).count == 2 && dnsRules(of: fakeOut)[0]["server"] as? String == "warpveil-system" && dnsRules(of: fakeOut)[1]["server"] as? String == "fakeip", "bypass: rule goes before the user's fakeip rule, server not duplicated")
var noDNS = parse(serverConfig()); noDNS["dns"] = nil
let noDNSOut = BypassService.injectSingBox(json(noDNS), domains: domains)
check(dnsServers(of: noDNSOut).count == 1 && dnsRules(of: noDNSOut).count == 1, "bypass: a config with no dns block gets the server and the rule")
let fitted = BypassService.routeSystemDNS(BypassService.fitTunToHost(bypassed, hostHasIPv6: false), host: lan)
check(actions(of: fitted.config) == ["sniff", "route", "hijack-dns", "route"] && dnsRules(of: fitted.config).count == 1, "server shape through all three passes")

// step 4: upstream
func dnsFinal(of c: String) -> String? { (parse(c)["dns"] as? [String: Any])?["final"] as? String }
let cf = BypassService.setUpstream(serverConfig(), upstream: .cloudflare)
check(dnsFinal(of: cf.config) == "warpveil-dns" && dnsServers(of: cf.config).last?["server"] as? String == "1.1.1.1" && dnsServers(of: cf.config).last?["type"] as? String == "tls" && dnsServers(of: cf.config).last?["detour"] as? String == "proxy", "upstream: Cloudflare DoT via route.final's outbound")
check(cf.notes == ["[DNS: upstream Cloudflare through the proxy replaces remote]"], "upstream: note names the previous default \(cf.notes)")
let wrapperUp = BypassService.setUpstream(wrapperConfig(), upstream: .quad9)
check(dnsServers(of: wrapperUp.config).last?["detour"] as? String == "xray-proxy", "upstream: wrapper detours through xray-proxy")
let twice = BypassService.setUpstream(cf.config, upstream: .google)
check(dnsServers(of: twice.config).count == 3 && dnsServers(of: twice.config).last?["server"] as? String == "8.8.8.8" && twice.notes.first == "[DNS: upstream Google through the proxy replaces warpveil-dns]", "upstream: a second pass replaces the tag, not appends")
let bad = BypassService.setUpstream(serverConfig(), upstream: .custom("not an address"))
check(bad.config == serverConfig() && bad.notes == ["[DNS: custom upstream not an address is not an address — config default kept]"], "upstream: unusable custom text leaves the config alone")
let doh = BypassService.upstreamFields(.custom("https://dns.quad9.net:8443/dns-query"))
check(doh?["type"] as? String == "https" && doh?["server"] as? String == "dns.quad9.net" && doh?["server_port"] as? Int == 8443 && doh?["path"] as? String == "/dns-query", "custom: https URL with port and path")
let dohBare = BypassService.upstreamFields(.custom("https://dns.google/"))
check(dohBare?["path"] == nil && dohBare?["server_port"] == nil, "custom: https URL without path or port takes sing-box defaults")
check(BypassService.upstreamFields(.custom("tls://dns.adguard.com"))?["type"] as? String == "tls", "custom: tls:// host")
check(BypassService.upstreamFields(.custom("9.9.9.9"))?["type"] as? String == "udp" && BypassService.upstreamFields(.custom("2620:fe::fe"))?["type"] as? String == "udp", "custom: bare IPs are plain UDP")
check(BypassService.upstreamFields(.custom("http://x")) == nil && BypassService.upstreamFields(.custom("dns.google")) == nil && BypassService.upstreamFields(.custom("")) == nil, "custom: http, bare host and empty are rejected")
check(DNSUpstream.stored(preset: "custom", custom: "  ") == nil && DNSUpstream.stored(preset: "", custom: "1.1.1.1") == nil && DNSUpstream.stored(preset: "quad9", custom: "") == .quad9 && DNSUpstream.stored(preset: "custom", custom: " 1.1.1.1 ") == .custom("1.1.1.1"), "stored: preset keys")
let noDNSUp = BypassService.setUpstream(json(noDNS), upstream: .google)
check(dnsServers(of: noDNSUp.config).count == 1 && dnsFinal(of: noDNSUp.config) == "warpveil-dns" && noDNSUp.notes.first == "[DNS: upstream Google through the proxy replaces none]", "upstream: a config with no dns block")
var firstSelector = parse(serverConfig()); firstSelector["outbounds"] = [["type": "selector", "tag": "auto", "outbounds": ["proxy"]] as [String: Any]] + (firstSelector["outbounds"] as! [[String: Any]]); var rt = firstSelector["route"] as! [String: Any]; rt["final"] = nil; firstSelector["route"] = rt
check(BypassService.proxyTag(of: firstSelector) == "auto" && BypassService.proxyTag(of: parse(serverConfig())) == "proxy", "proxyTag: route.final, else the first outbound")
let full = BypassService.setUpstream(BypassService.routeSystemDNS(BypassService.fitTunToHost(BypassService.injectSingBox(serverConfig(), domains: domains), hostHasIPv6: false), host: lan).config, upstream: .cloudflare)
check(actions(of: full.config) == ["sniff", "route", "hijack-dns", "route"] && dnsRules(of: full.config)[0]["server"] as? String == "warpveil-system" && dnsFinal(of: full.config) == "warpveil-dns" && dnsServers(of: full.config).count == 4, "server shape through all four passes")

// sanity: the pre-existing injectSingBox contract still holds
check(actions(of: BypassService.injectSingBox(serverConfig(), domains: domains)) == ["sniff", "route", "hijack-dns"], "injectSingBox: bypass right after the sniff")
check(BypassService.injectSingBox(serverConfig(), domains: []) == serverConfig(), "injectSingBox: empty domains unchanged")

print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
EOF
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
swiftc -target arm64-apple-macosx14.0 main.swift "$REPO/Sources/BypassService.swift" "$REPO/Sources/Models.swift" -o harness && ./harness
```

Expect every line `ok` and `ALL OK` (57 checks). The `fitTunToHost` harness from
`git show dfcdc31:plans/done/routing-bypass-fix.md` (Verification 2) still applies unchanged.

#### 3. The kernel routes, from sing-tun's own builder (no root, no engine)

Confirms that the exclude lists the harness produces give the resolver its own route. Needs Go
(`/opt/homebrew/bin/go`); downloads sing-tun once through the live tunnel.

```bash
mkdir -p "$TMPDIR/rangecheck" && cd "$TMPDIR/rangecheck"
cat > go.mod <<'EOF'
module rangecheck

go 1.24

require github.com/sagernet/sing-tun v0.9.0-beta.4
EOF
cat > main.go <<'EOF'
package main

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"

	tun "github.com/sagernet/sing-tun"
)

// Reads {"tun": "172.19.0.1/30", "exclude": [...], "want": [...]} and prints whether every
// wanted host route comes out of sing-tun's own range builder.
func main() {
	var in struct {
		Tun     string   `json:"tun"`
		Tun6    string   `json:"tun6"`
		Exclude []string `json:"exclude"`
		Want    []string `json:"want"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	o := tun.Options{Inet4Address: []netip.Prefix{netip.MustParsePrefix(in.Tun)}, AutoRoute: true}
	if in.Tun6 != "" {
		o.Inet6Address = []netip.Prefix{netip.MustParsePrefix(in.Tun6)}
	}
	for _, e := range in.Exclude {
		p := netip.MustParsePrefix(e)
		if p.Addr().Is4() {
			o.Inet4RouteExcludeAddress = append(o.Inet4RouteExcludeAddress, p)
		} else {
			o.Inet6RouteExcludeAddress = append(o.Inet6RouteExcludeAddress, p)
		}
	}
	routes, err := o.BuildAutoRouteRanges(false)
	if err != nil {
		panic(err)
	}
	have := map[string]bool{}
	for _, r := range routes {
		have[r.String()] = true
	}
	ok := true
	for _, w := range in.Want {
		if !have[w] {
			ok = false
			fmt.Println("MISSING", w)
		}
	}
	fmt.Println("routes:", len(routes), "ok:", ok)
}
EOF
GOFLAGS=-mod=mod go mod tidy >/dev/null 2>&1 && GOFLAGS=-mod=mod go build -o rangecheck . && \
echo '{"tun":"172.19.0.1/30","exclude":["192.168.1.128/25","192.168.1.64/26","192.168.1.32/27","192.168.1.16/28","192.168.1.8/29","192.168.1.4/30","192.168.1.2/31","192.168.1.0/32"],"want":["192.168.1.1/32"]}' | ./rangecheck && \
echo '{"tun":"172.19.0.1/30","exclude":["192.168.1.0/32","192.168.1.3/32","192.168.1.4/30","192.168.1.8/29","192.168.1.16/28","192.168.1.32/27","192.168.1.64/26","192.168.1.128/25"],"want":["192.168.1.1/32","192.168.1.2/32"]}' | ./rangecheck && \
echo '{"tun":"172.19.0.1/30","exclude":["10.0.0.0/8","192.168.1.128/25","192.168.1.64/26","192.168.1.32/27","192.168.1.16/28","192.168.1.8/29","192.168.1.4/30","192.168.1.2/31","192.168.1.0/32"],"want":["192.168.1.1/32"]}' | ./rangecheck
```

Expect `routes: 31 ok: true`, `routes: 32 ok: true`, `routes: 33 ok: true`. (With no excludes the
builder gives the 8 ranges the live table shows; with the per-address sibling lists of `.1` and
`.2` *both* instead of the set carve, it gives 30 routes and neither host route — the bug the set
carve exists for.)

#### 4. User-space end to end: the real pipeline, the real engine, no TUN

Runs while the tunnel is up and touches no engine of the app's. Two parts: the pipeline on the
live wrapper config, then the rule walk fed with real DNS queries through sing-box's `direct`
inbound — a UDP listener that hands every packet to the router as a packet to `192.168.1.1:53`,
which is what a TUN packet from the system resolver looks like. The `fixed` case is the new
order, `control` the old builders' order.

```bash
W="$TMPDIR/dns-e2e"; mkdir -p "$W/cli"; cd "$W"
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
LIVE=$(ls -t "$TMPDIR"/warpveil-singbox-*.json | head -1)      # the live wrapper, written by the app

# the real pipeline as a CLI: prepare <in> <out> <resolvers,> <subnets,> <preset|-> <domain>...
cat > cli/main.swift <<'EOF'
import Foundation
let a = CommandLine.arguments
let input = try! String(contentsOfFile: a[1], encoding: .utf8)
let host = HostDNS(resolvers: a[3].split(separator: ",").map(String.init), localSubnets: a[4].split(separator: ",").map(String.init))
let injected = BypassService.injectSingBox(input, domains: Array(a[6...]))
let fitted = BypassService.fitTunToHost(injected, hostHasIPv6: false)
let routed = BypassService.routeSystemDNS(fitted, host: host)
var config = routed.config
var notes = routed.notes
if let upstream = DNSUpstream.stored(preset: a[5], custom: "") {
    let set = BypassService.setUpstream(config, upstream: upstream)
    config = set.config; notes += set.notes
}
try! config.write(toFile: a[2], atomically: true, encoding: .utf8)
notes.forEach { print($0) }
EOF
swiftc -target arm64-apple-macosx14.0 cli/main.swift "$REPO/Sources/BypassService.swift" "$REPO/Sources/Models.swift" -o cli/prepare
cli/prepare "$LIVE" prepared.json 192.168.1.1 192.168.1.0/24 cloudflare ifconfig.me .ru
"$REPO/Binaries/sing-box" check -c prepared.json && echo "CHECK OK"
python3 -I - prepared.json <<'EOF'
import json, sys
c = json.load(open(sys.argv[1])); t = c["inbounds"][0]
print("rules:", [(r.get("action"), r.get("ip_cidr") or r.get("domain_suffix") or r.get("protocol")) for r in c["route"]["rules"]])
print("excludes:", t["route_exclude_address"])
print("dns:", [(s["tag"], s["type"], s.get("server"), s.get("detour")) for s in c["dns"]["servers"]], "final:", c["dns"].get("final"), "rules:", c["dns"]["rules"])
EOF

# tun -> mixed + a direct UDP inbound aimed at the resolver; bind everything that leaves the machine
IFACE=$(scutil <<< "show State:/Network/Global/IPv4" | awk '/PrimaryInterface/ {print $3}')
PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1])")
P2=$(python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('127.0.0.1',0));print(s.getsockname()[1])")
python3 -I - prepared.json fixed.json control.json "$PORT" "$P2" "$IFACE" <<'EOF'
import json, sys, copy
c = json.load(open(sys.argv[1])); port, p2, iface = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
c["inbounds"] = [{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": port},
                 {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1", "listen_port": p2, "network": "udp", "override_address": "192.168.1.1", "override_port": 53}]
for ob in c["outbounds"]:
    if ob.get("server") not in ("127.0.0.1", "::1", "localhost", None): ob["bind_interface"] = iface
for s in c["dns"]["servers"]:
    if "detour" not in s: s["bind_interface"] = iface
c["log"] = {"level": "debug"}
rules = c["route"]["rules"]; sniff = next(i for i, r in enumerate(rules) if r.get("action") == "sniff")
fixed = copy.deepcopy(c); fixed["route"]["rules"] = [r for i, r in enumerate(rules) if not (r.get("action") == "hijack-dns" and i < sniff)]
control = copy.deepcopy(c); control["route"]["rules"] = [r for i, r in enumerate(rules) if not (r.get("action") == "hijack-dns" and i > sniff)]
json.dump(fixed, open(sys.argv[2], "w"), indent=2); json.dump(control, open(sys.argv[3], "w"), indent=2)
print("fixed:", [r.get("action") for r in fixed["route"]["rules"]]); print("control:", [r.get("action") for r in control["route"]["rules"]])
EOF
run_case() {
  "$REPO/Binaries/sing-box" check -c "$2" || return 1
  "$REPO/Binaries/sing-box" run -c "$2" > "$1.log" 2>&1 & local pid=$!
  for _ in $(seq 1 50); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
  echo "[$1] ya.ru (bypassed .ru)      -> $(dig +short +time=3 +tries=1 @127.0.0.1 -p $P2 ya.ru A | head -1)"
  echo "[$1] example.org (upstream)    -> $(dig +short +time=3 +tries=1 @127.0.0.1 -p $P2 example.org A | head -1)"
  echo "[$1] bypassed ifconfig.me      -> $(curl -s --max-time 20 --socks5-hostname 127.0.0.1:$PORT https://ifconfig.me/ip)"
  echo "[$1] not bypassed api.ipify.org -> $(curl -s --max-time 20 --socks5-hostname 127.0.0.1:$PORT https://api.ipify.org)"
  kill "$pid"; wait "$pid" 2>/dev/null
  sed 's/\x1b\[[0-9;]*m//g' "$1.log" | rg -n "router: match|dns: match|sniffed|outbound/" | head -12
}
run_case fixed fixed.json; echo; run_case control control.json
ps -axo pid,user,comm | rg sing-box | rg -v "root|rg" || echo "no user-space sing-box left"
```

Expect, `fixed`: `router: match[1] => sniff`, `sniffed packet protocol: dns`, `match[2]
protocol=dns => hijack-dns`, `dns: match[0] domain_suffix=[ifconfig.me .ru] =>
route(warpveil-system)` and an ISP-side answer for `ya.ru` (77.88.x.x), a Cloudflare-side answer
for `example.org`, the home IP for `ifconfig.me` via `outbound/direct`, the VPN exit for
`api.ipify.org` via `outbound/socks[xray-proxy]`. `control`: the `hijack-dns` above the sniff
is skipped and the query lands on `match[3] ip_cidr=192.168.1.1/32 => route(direct)` — out in the
clear (without the resolver rule it would reach `final`, the proxy). This ran in this run with
exactly that outcome. What it cannot show: the kernel's host route and mDNSResponder — the live
check does.

#### 5. Live check (the implementing session, after `./install.sh` on the new build)

One self-contained script. It restarts the tunnel twice through the app's own quit path and a
relaunch (`autoConnect` is on; the same sequence `install.sh` uses, ~10 s of tunnel downtime each),
writes the defaults only while the app is quit (an `@AppStorage` observes external writes and
would reconnect on its own), and restores the defaults and relaunches on any exit, so the session
is never left without the tunnel. Needs the implementing session to be on this Mac, connected,
with `.ru` not already in the bypass list.

```bash
#!/bin/bash
# DNS-through-the-tunnel live check on the installed build. Restores defaults and relaunches on exit.
set -u
APP=/Applications/WarpVeil.app; D=com.warpveil.app; LOG="$TMPDIR/warpveil-1-2.log"
[ "$(defaults read $D autoConnect 2>/dev/null)" = 1 ] || { echo "autoConnect is off — turn it on first"; exit 1; }
SAVED_UP=$(defaults read $D dnsUpstream 2>/dev/null || echo __none__)
SAVED_BYPASS=$(defaults read $D bypassDomains 2>/dev/null || echo __none__)
HOME_IP=$(curl -s --max-time 10 --interface en0 https://api.ipify.org); echo "home IP: $HOME_IP"

quit_app() {
  osascript -e "tell application \"$APP\" to quit" >/dev/null 2>&1
  for _ in $(seq 1 80); do pgrep -x sing-box >/dev/null || pgrep -x xray >/dev/null || break; sleep 0.5; done
}
launch_app() {
  open -a "$APP"
  for _ in $(seq 1 60); do
    ip=$(curl -s --max-time 5 https://api.ipify.org); [ -n "$ip" ] && [ "$ip" != "$HOME_IP" ] && { echo "tunnel up, exit $ip"; return 0; }
    sleep 1
  done
  echo "tunnel did not come back — check the app"; return 1
}
restore() {
  quit_app
  if [ "$SAVED_UP" = __none__ ]; then defaults delete $D dnsUpstream 2>/dev/null; else defaults write $D dnsUpstream -string "$SAVED_UP"; fi
  if [ "$SAVED_BYPASS" = __none__ ]; then defaults delete $D bypassDomains 2>/dev/null; else defaults write $D bypassDomains -string "$SAVED_BYPASS"; fi
  launch_app
}
trap restore EXIT

leak_test() {   # resolves through mDNSResponder, then asks bash.ws which resolvers it saw
  local id; id=$(curl -s --max-time 10 https://bash.ws/id) || return
  for i in $(seq 1 10); do dscacheutil -q host -a name "$i.$id.bash.ws" >/dev/null 2>&1; done
  curl -s --max-time 15 "https://bash.ws/dnsleak/test/$id?json" | python3 -I -c '
import json, sys
for e in json.load(sys.stdin):
    if e.get("type") in ("dns", "conclusion"): print("   ", e.get("type"), e.get("ip", ""), e.get("country_name", ""), e.get("asn", ""))'
}

echo "== 1. host route for the resolver"; netstat -rn -f inet | rg "^192\.168\.1\.1[ /].*utun" || echo "   MISSING — the carve did not take"
echo "== 2. the connect notes"; rg -n "\[DNS:" "$LOG" | tail -3
echo "== 3. system resolver queries reach the engine (mDNSResponder path — D4's assumption)"
before=$(rg -c "dns: exchanged" "$LOG" || echo 0); dscacheutil -flushcache; dscacheutil -q host -a name example.org >/dev/null
sleep 1; after=$(rg -c "dns: exchanged" "$LOG" || echo 0); echo "   dns: exchanged lines before/after: $before/$after (must grow)"
rg -n "inbound DNS packet|inbound packet connection to 192.168.1.1:53" "$LOG" | tail -2
echo "== 4. an explicit query to the resolver is hijacked too"; dig +short +time=3 @192.168.1.1 example.org A | head -2
echo "== 5. leak test (expect the exit-side resolver, not the ISP's)"; leak_test
echo "== 6. the router still answers direct"; curl -s -o /dev/null -w '   http://192.168.1.1 -> %{http_code}\n' --max-time 5 http://192.168.1.1/

echo "== 7. bypassed domains use the system resolver; upstream switch"
quit_app
defaults write $D bypassDomains -string ".ru"
defaults write $D dnsUpstream -string quad9
launch_app || exit 1
rg -n "\[DNS:" "$LOG" | tail -3
python3 -I -c 'import json,glob,os;f=max(glob.glob(os.environ["TMPDIR"]+"/warpveil-singbox-*.json"),key=os.path.getmtime);c=json.load(open(f));print("   dns final:",c["dns"].get("final"),"servers:",[(s["tag"],s.get("server")) for s in c["dns"]["servers"]],"rules:",c["dns"].get("rules"))'
dscacheutil -flushcache; dscacheutil -q host -a name ya.ru | rg ip_address | head -1
rg -n "dns: exchanged A ya.ru" "$LOG" | tail -1
echo "   ya.ru -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://ya.ru/) via $(rg -n 'outbound/direct\[direct\]: outbound connection to .*:443' "$LOG" | tail -1 | rg -o 'to [0-9.]+' )"
echo "   leak test with Quad9 (expect AS19281 resolvers):"; leak_test
echo "== restoring"
```

Expect: 1 a `192.168.1.1/32`-style line on the utun; 2 `[DNS: system resolver 192.168.1.1 routed
into the tunnel]`; 3 the count grows and an `inbound packet connection to 192.168.1.1:53` (or
`inbound DNS packet`) line appears — **if it does not while 4 does, mDNSResponder scopes its
sockets and the fallback in Failure modes is the owner's decision**; 5 resolvers outside Russia
(Cloudflare, AS13335, through New Jersey); 6 a status code; 7 `final: warpveil-dns` with `9.9.9.9`,
the `.ru` DNS rule, `ya.ru` answered with a Yandex 77.88.x.x address, reached via
`outbound/direct`, Quad9 resolvers in the leak test. The `scutil --dns` output must be unchanged
throughout (nothing on the system is set).

#### 6. Visual check (Advanced page)

The DNS section sits between Connection and Components; the picker shows "Config default"; choosing
Custom reveals the field with its grey prompt and a red caption until the text parses; changing the
picker while connected produces `[Routing changed — reconnecting...]` once, after 2 s.

### Validation of this plan

Done in this run on a scratch copy of `5de6c1c` (`git archive`), the repo untouched (`git status
--porcelain` empty afterwards), no engine of the app's started, stopped or reconfigured, no
network setting changed:

- Steps 1 → 2 → 3 → 4 applied in order by one script, `xcodebuild … Debug` after each: four times
  `BUILD SUCCEEDED`, no new warnings. (A first attempt with the address parsing inside
  `DNSUpstream` failed with "type 'BypassService' has no member 'Address'" — the cycle noted
  above; the shape in this file is the one that builds.)
- Verification 2's `main.swift`, verbatim, against the step-4 `BypassService.swift` and
  `Models.swift`: 57 checks, all `ok`.
- Verification 3's Go program against sing-tun v0.9.0-beta.4: the three expected lines; the
  per-address sibling variant for two resolvers gave 30 routes and no host route, which is why
  `carve` is a set operation.
- Verification 4, on the live wrapper config (`$TMPDIR/warpveil-singbox-61254.json`, xray
  topology): `sing-box check` accepts the prepared config; its excludes give 31 routes with
  `192.168.1.1/32`; `fixed` hijacked both queries (`ya.ru` → `warpveil-system` → 77.88.44.242,
  `example.org` → Cloudflare-side 104.20.26.136), bypassed `ifconfig.me` → the home IP via
  `outbound/direct`, `api.ipify.org` → the VPN exit via `outbound/socks[xray-proxy]`; `control`
  skipped the hijack and sent both queries out via the resolver rule. A separate user-space
  sing-box confirmed `type: local` (home IP via `ifconfig.me`) and `type: udp` to the router
  (`ya.ru` 302) both work on the CLI. Every user-space engine was killed by its own PID.
- Every file, type, symbol and line named in "Verified facts" was read in the source; the engine
  facts were read at the pinned tags.

---

## 2. Routing modes Global / Rule / Direct, and the Clash API foundation [3] — M

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
      var dnsUpstream: DNSUpstream?
      var mode: RoutingMode = .rule
      var apiPort: UInt16
      var apiSecret: String
  }
  ```
  (later items append fields; the struct is a parameter bag, not an abstraction).
- New `Sources/ClashAPI.swift` (four `project.pbxproj` entries, ids `…1D`):
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
    `injectSingBox(_:domains:)` and absorbs item 1's `setUpstream` call (`settings.dnsUpstream`);
    `routeSystemDNS` and `fitTunToHost` stay separate passes — they take host facts, not settings.
  - `buildTunWrapper(serverIP: String?, settings: TunnelSettings) -> String` — moved verbatim from
    `ProcessManager.buildTunWrapperConfig`, then its `rules` come from the shared builder below;
    `extractServerIP(from:)` moves with it.
  - `private static func ruleBlock(_ settings: TunnelSettings, proxyTag: String) -> [[String: Any]]`
    — D5's list 4–6; `private static func insert(_ block:, into rules:)` — right after the
    `hijack-dns` that follows the first unconditional `sniff` (`ensureSniff`, then the same search
    `routeSystemDNS` does; insert a `hijack-dns` there when none). The bypass rule moves into the
    block.
  - `proxyTag(of:)` is item 1's.
  - `private static func injectClashAPI(into root: inout [String: Any], settings:)` — D1's
    conflict policy; returns the log line when it replaced something.
  - DNS side of the mode: prepend to `dns.rules` `{"clash_mode": "Direct", "action": "route",
    "server": "warpveil-system"}` — item 1's `local` server, ensured by a shared
    `ensureSystemServer(&dns)` that `injectSingBox` extracts from its bypass half. Global mode
    resolves through the default (`dns.final`).
  - **Conflict**: a config whose `route.rules` already contain a `clash_mode` key gets no mode
    rules from WarpVeil (the user manages modes) and the log says
    `[Routing: config carries its own clash_mode rules — mode switch still applies to them]`;
    the API and `default_mode` are injected regardless, so the picker still drives the user's
    rules.
- `Sources/ProcessManager.swift`:
  - `connect(config:engine:binaryPath:singBoxPath:settings: TunnelSettings)`; `lastConnection`
    becomes `(config: String, engine: Engine, binaryPath: String, singBoxPath: String, settings:
    TunnelSettings)`; `reconnect(settings:)` compares `Set(bypassDomains)`, `dnsUpstream` and
    `mode`… no: `mode` changes never reconnect (below), so the guard compares the first two;
    `restart` replays `params.settings`.
  - `private(set) var api: ClashAPI?` — set in `connect` from `settings`, cleared in
    `tearDownEngines()` and in the termination handler.
  - `func setMode(_ mode: RoutingMode) async -> Bool` — `PATCH /configs` with
    `{"mode": mode.rawValue}`; logs `[Routing: mode → Global]` or the failure.
  - `buildTunWrapperConfig` and `extractServerIP` deleted here (moved).
- `Sources/AppState.swift`:
  - `var tunnelSettings: TunnelSettings` computed at connect time: `activeBypassDomains`,
    `dnsUpstream`, `RoutingMode(rawValue: defaults.string(forKey: "routingMode") ?? "") ?? .rule`,
    `LocalPort.free(1).first ?? 0` (0 → `pm.connect` logs `[Error: no free local port]` and
    returns), `UUID().uuidString`.
  - `routingChanged()` → `pm.reconnect(settings: tunnelSettings)`; `scheduleRoutingChange()`
    (item 1) is the debounce both pages use.
  - `func setRoutingMode(_ mode: RoutingMode)`: `defaults.set`, then if `pm.isRunning` →
    `Task { await pm.setMode(mode) }` — **no reconnect**; the next connect injects
    `default_mode`.
- `Sources/RoutingView.swift`: a first `Section` with `Picker("Mode", selection:)` segmented over
  `RoutingMode.allCases` bound to `@AppStorage("routingMode")` (string) → `onChange` calls
  `app.setRoutingMode`. Footer text under the Domains section when the mode is not Rule:
  "Applies in Rule mode". The domains section stays visible so the list is never hidden state.
- Canon: Architecture line for `BypassService` ("…builds the xray TUN wrapper"), a new Key
  Decision "Clash API on the production engine" (D1 text), Gotcha for the insertion anchor.

### Both topologies

- sing-box: `injectSingBox` inserts the block and the API into the user's config.
- xray: `buildTunWrapper` builds its base as today, then runs the same `ruleBlock` with
  `proxyTag = "xray-proxy"` and the same `injectClashAPI`. The xray config is unchanged.

### Steps (each compiles, each a commit)

1. `TunnelSettings` + `RoutingMode`; thread `settings` through `ProcessManager.connect/reconnect/
   restart`, `AppState.connect/routingChanged`, `BypassService.injectSingBox`; move the wrapper
   builder and `extractServerIP` into `BypassService`. Behaviour identical.
2. `ClashAPI.swift` (+ pbxproj); `PingService` adopts it; `LocalPort` replaces the two private statics.
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

With the owner's xray feed: Global → `curl ifconfig.me` shows the exit IP, Direct → home IP, Rule
→ exit IP and a bypass domain direct; `GET /configs` shows the mode; the sing-box log shows
`clash_mode` rule hits. A user config with its own `experimental.clash_api` on port 9090: the log
line, and 9090 is not listening.

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

Why `user root`: sing-box and xray run as root; their dials to the server, the `local` DoT to
8.8.8.8, the `warpveil-system` dial to the LAN resolver and direct-routed bypass traffic all come
from root sockets, so they pass without knowing the server address (which for a hostname would
need a table). The cost, stated: any root daemon (`configd`, `apsd`) is not blocked; user apps
are. Why source-address, not interface: the TUN's `utunN` is chosen at start and pinning
`interface_name` fails when the unit is taken; the TUN address is known at injection. System DNS
needs no exception: after item 1 it enters the tunnel with source `172.19.0.1`. Why `quick`
everywhere: pf is last-match-wins, and Apple's anchors evaluate after ours — without `quick` a
later `pass` in another anchor could override the block. Why loopback first: the wrapper reaches
xray on `127.0.0.1:10808` and the Clash API lives there. Known limitations, stated in the toggle's
subtitle: other tunnels (Tailscale) are cut while armed; local servers the user runs (a dev server
on :3000) cannot answer LAN clients unless Allow LAN is on; ICMPv4 is blocked.

### Scripts (`ProcessManager.runShContent`, `stopShContent`, `buildNonPrivilegedShellCommand`, the inline stop in `killVPNProcesses`)

`run.sh` argv becomes `run.sh <singbox> <singbox_cfg> [<xray> <xray_cfg>] [--kill-switch <pf_conf>]`
(accept 2, 4, and either plus the two-token flag at the end; `validate_arg` the pf file like the
configs). Shared shell, in `killPidFileFunction`'s sibling constant `killSwitchFunctions`:

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
    termination handler, and when `teardownProcess` exits (a `terminationHandler` on the stop
    process, new) — that is how the "Lift" button's effect reaches the UI.
  - `connect` writes the pf file when `settings.killSwitch` and passes the flag; the log says
    `[Kill switch on]`.
  - Termination handler (unexpected exit, `self.isRunning` still true and `p === helperProcess`):
    after `[Disconnected (exit N)]`, `unexpectedExitCount += 1` (item 4 observes it) and, when
    `settings.autoReconnect`: `restart("[Reconnecting in N s (attempt K)]", after: .seconds(N))`
    with N from `[2, 5, 10, 30, 60, 60…]` indexed by `reconnectAttempt` (reset in `disconnect()`
    and when a connect has stayed up 60 s) — `restart` already guards on `lastConnection`,
    skips the teardown when nothing runs, survives sleep and bumps `reconnectCount`, which
    `AppState.observeReconnects` already turns into a fresh location timer. **Passwordless off:
    one attempt only** — a loop of admin prompts is hostile; after it the switch stays engaged
    with the banner. `disconnect()` cancels the task (existing line).
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
  automatically")`. Turning the kill switch off while connected → `scheduleRoutingChange()`
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
cases, so the limitation text is true. With item 1 in: `dscacheutil -q host -a name example.org`
still resolves while armed (the query has source `172.19.0.1`).

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
  `pm.killSwitchEngaged`. The wake, routing, IPv6 and DNS restarts do not count as drops: they go
  through `restart`, which sets `isRunning = false` before terminating.
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
- `Sources/ServersView.swift` `subscriptionHeader`: it is an `HStack`; wrap its `Text(sub.name)`
  in a `VStack(alignment: .leading, spacing: 2)` and add an 11 pt secondary line when `userInfo`
  is present — `"\(used) of \(total) used · expires \(date)"` with `ByteCountFormatter` (`.file`
  style), each part only when its field exists; red when `expire` has passed or less than 5 %
  remains.
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
    status menu sets the Connect item's `isEnabled` from it (today the item is always enabled).
  - `connect()`: when auto and `selectedServer == nil`, `Task { await ping.runAndWait(all); connect() }`
    once — `isMeasuringForConnect` (observable) shows "Measuring servers…" in `statusSection`.
    Re-evaluation happens on every fresh connect; the restarts replay `lastConnection` (same
    server) — v1, stated in the row's subtitle. No failover on a failing best server in v1: the
    watchdog reconnects the same one.
- `Sources/PingService.swift`: `func runAndWait(_ servers:) async` = `start(servers)` then
  `await task?.value` — `task` is already the run's handle (`measure` is taken by the private
  worker).
- `Sources/ServersView.swift`: a first `Section` with one row — "Fastest server" with the
  resolved name and ping as its subtitle ("picks the lowest ping at connect") — selectable like a
  server row (`app.selectedServerID = AppState.autoServerID`). The page header rides on this
  section's header now (it is never empty), so `index == 0` in the subscription loop drops; the
  empty-state section stays for the no-subscriptions case.
- `Sources/ConnectionView.swift` `statusSection`: "Auto → <name>" when auto.
- Failure modes: no server measured at all (all `--`): `connect()` logs `[Auto: no reachable
  server]` and stays disconnected; the ping error line on the Servers page already explains why.
- Steps: 1. `runAndWait`, `selectedServer` resolution, `canConnect`. 2. The row and the labels.

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
  `app.scheduleRoutingChange()` (debounced reconnect — rules cannot be changed over the API).
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
- New `Sources/ConnectionsView.swift` (four pbxproj entries): grouped `Form`; header "Connections
  · N" with "Close all" (`DELETE /connections`); rows: `host` (or `destinationIP`) `:port` at
  14 pt, second line `processPath`'s last component · `chains.first` · `↓ bytes ↑ bytes` at 11 pt
  secondary, trailing xmark → `DELETE /connections/{id}`. Not connected → one row "Not connected"
  (non-empty section, canon). `.task(id: app.pm.isRunning)` loop: `while !Task.isCancelled {
  await refresh(); try? await Task.sleep(for: .seconds(1)) }`.
- Decoding: `private struct ConnectionsResponse: Decodable { let connections: [TunnelConnection] }`,
  `struct TunnelConnection: Decodable, Identifiable { let id: String; let metadata: Metadata; let
  upload, download: Int64; let start: Date; let chains: [String]; let rule: String }` with
  `.iso8601` dates — typed `Codable` is right here: this is our API response, not a user config
  (the canon's `JSONSerialization` decision is about user configs). DNS connections are already
  filtered out by the API (`OutboundType != dns`).
- `Sources/ProcessManager.swift`: `func connections() async -> Data?` and `func closeConnection(_
  id: String?)` over `api` — the third and fourth `ClashAPI` users.
- Both topologies: the wrapper's connections in the xray case (chains `xray-proxy`), which is the
  view that matters — xray's own socks sessions are the same connections one hop later.
- Failure modes: API not ready in the first second — empty list, no error row; `sourceIP` is the
  TUN address for everything — omitted from the row.

---

## 9. Server quick switch — the actual "profiles" gap [10] — S

- `Sources/AppState.swift`: `func selectServer(_ id: String)` — sets `selectedServerID` and, when
  `pm.isRunning`, arms a 2 s `serverSwitchTask` (a burst of taps costs one bounce) that runs
  `pm.disconnect()` followed immediately by `connect()`: `pm.connect` parks itself until the stop
  it finds in `teardownProcess` has exited, so no hand-rolled delay is needed (the earlier plan's
  "1 s after disconnect" predates that). `pm.restart` cannot be used — it replays
  `lastConnection`'s config. `ServersView`'s `onTapGesture` and the auto row call it.
- `Sources/WarpVeilApp.swift` `menuNeedsUpdate`: a "Server" submenu — one item per server grouped
  by subscription (section-style disabled items for names), checkmark on the selection, "Fastest"
  first when item 6 exists — target `selectServerAction(_:)` with `representedObject = id`. Menu
  is rebuilt on open, so nothing is observed.
- Failure modes: switching without passwordless mode costs two prompts (stop, then run) — the
  subtitle under the power button already says which server; nothing hidden.

---

## 10. TUN MTU [13] — S

- `stack` is not exposed: not deprecated in the 1.14.0 docs, but the dev docs deprecate it for
  1.15 and the next binary bump would strand the knob.
- `Sources/Models.swift`: `TunnelSettings.mtu: Int?` (nil = config default).
- `Sources/AdvancedView.swift`: `Section("Tunnel")` with `Picker("MTU")` Default / 1280 / 1400 /
  1500 / 9000 over `@AppStorage("tunMTU")` (0 = default) → `scheduleRoutingChange()`.
- `Sources/BypassService.swift`: on the `tun` inbound, set `mtu` when the setting is explicit —
  the setting overrides a config value and logs `[TUN: mtu 1500 → 1400]`; Default leaves the
  config's value or absence alone. Both topologies identical. `mtu: 1400` passes `sing-box check`.
- Risk: none; sing-box rejects an out-of-range value at start with its own message.

---

## 11. More link formats, clipboard and QR import [7] — M for links, L for Clash YAML

**Risk**: Clash YAML — Foundation has no YAML parser and the canon allows no package. A hand
parser that covers flow-style `- {name: …, type: ss, …}` and block-style scalar keys with one
nested level (`ws-opts:`) is ~150 lines of code with an unbounded tail of panel-specific
formatting. Ship the links first; YAML is its own commit the owner can drop.

- `Sources/SubscriptionService.swift`:
  - `private func parseLink(_ line: String) -> Server?` dispatching on scheme; `addFromURL`
    (`:109`'s `hasPrefix("vless://") || hasPrefix("vmess://")`) and `fetchAndParseURIs`
    (`:262-268`) call it.
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
  traffic is counted twice (plaintext on utun, ciphertext on en0) and the VM bridges
  (`bridge100-103` on this Mac) add theirs; restrict it to the primary interface: make
  `PingService.primaryInterface()` internal (`static`, not `private static`) and call it — the
  second user of that one-liner; no new file.
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

- New `Sources/LeakCheckService.swift` (four pbxproj entries; `@Observable @MainActor`): `func
  run() async` filling `ipv4: String?` (reuse `LocationService.detect()` → `loc.ip`,
  `loc.location`), `ipv6: String?` (`GET https://api6.ipify.org?format=json`, 5 s; a `nil` answer
  is the good answer on a host with no global IPv6), `resolvers: [(ip: String, country: String,
  asn: String)]` and `conclusion: String` (bash.ws: `GET /id`, ten
  `GET https://<n>.<id>.bash.ws/` fired concurrently with a 2 s timeout — the lookups are the
  point, the responses are discarded — then `GET /dnsleak/test/<id>?json`, entries typed `dns` →
  resolvers, `conclusion` → text). Verdicts: IPv4 equals the host part of `Server.address` when
  that is an IP literal and the tunnel is up → fine, differs → "IPv4 leaks"; any IPv6 answer while
  the TUN has no IPv6 (`fitTunToHost` gave it none) → "IPv6 leaks"; the conclusion text is shown
  verbatim.
- `Sources/ConnectionView.swift` `locationSection`: a "Check for leaks" plain button → a sheet
  `LeakCheckSheet` (three `LabeledContent` rows with green/red glyphs, the resolver list, a
  re-run button). `AppState` owns `let leaks = LeakCheckService()` like the other services.
- Both topologies: the check is external; nothing engine-specific. After item 1 the DNS row is
  the exit's resolver; before it, the ISP's — which is the point of building 1 first.

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

- New `Sources/BackupDocument.swift` (four pbxproj entries): `struct BackupDocument: FileDocument`
  (`import UniformTypeIdentifiers`, `readableContentTypes = [.json]`) wrapping
  `{"version": 1, "settings": {key: value}, "subscriptions": [Subscription]}` — settings from
  `UserDefaults.standard` filtered to `AppState.settingsKeys` (the list under "Build order", one
  `static let` in `AppState`), subscriptions via `JSONEncoder` (already `Codable`).
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
