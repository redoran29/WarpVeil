# WarpVeil

macOS app for managing VPN connections via sing-box and xray.
Swift 5.10, SwiftUI, macOS 15+, Apple Silicon. A three-column main window plus a menu-bar status item.

This file is the whole canon: workflow, architecture, conventions, decisions. Read it before
changing anything.

---

## Workflow

Every feature and every non-trivial change follows the same three steps. Never go straight
to code.

Work comes from `BACKLOG.md`, the owner's list: one numbered line per item, in Russian, untracked
(`.git/info/exclude` — the repository is public). Numbers are never reused. A tag in brackets
names an old plan, dropped on 2026-10-15 to be planned again: `git show 975f8b4:plans/<tag>.md`
is its research, read by the item's new plan, not copied into it. Never delete the file.

### 1. Plan

The plan is written with the global `stage-plan` skill, in the main session — it audits the
owner one question at a time — and goes to `plans/<n>-<slug>.md`, `<n>` being its backlog
item's number. It says what and why, never which files: that is read from the code when the
work starts.

### 2. Implement

Follow the plan; every step leaves the project compiling. When reality contradicts it, correct
the plan file in the same commit as the deviation — the file must never describe something that
was not built.

### 3. Close

- Once every step is implemented, run `/code-review` over the finished work and fix everything
  it surfaces; each round is recorded in the plan. Work on a plan is not over while review
  findings are open.
- A finding that would undo what an earlier pass asked for is not fixed: it goes to the owner
  with both positions. Two passes that disagree mark a question the plan never settled, and
  fixing each in turn is a loop.
- Then delete the plan. `plans/` holds only work that is ahead or under way; a finished plan
  lives in git history. Whatever has to outlive the work — a decision, a convention, a gotcha —
  is written into this file before the plan goes.

### The third fix is a signal

When the same place is fixed a third time, the problem is not the fix. Stop and ask whether the
construction is right — that is cheaper than a fourth correct fix on a wrong shape. Probes and a
green build confirm the step, never the shape: a design can be verified end to end and still
guarantee the next bug.

---

## Architecture

```
Sources/
├── WarpVeilApp.swift          # @main + AppDelegate: the window, the status item and its menu
├── AppState.swift             # Owns every service, the connect/disconnect logic and bootstrap
├── ContentView.swift          # Page enum, the split view and its collapsible icon rail
├── ConnectionView.swift       # Power button, status, stats, location — the right column
├── ServersView.swift          # Grouped Form, one section per subscription, add sheet
├── RoutingView.swift          # Domain bypass, grouped Form
├── AdvancedView.swift         # Auto-connect, passwordless, components, grouped Form
├── LogView.swift              # VPN log with copy and clear, drawn as a grouped-Form card
├── ProcessManager.swift       # VPN process lifecycle, sudo/passwordless, config policy, log tailing, sleep/wake
├── SubscriptionService.swift  # Subscription fetch, vless:// and vmess:// parsing, xray config building
├── SetupService.swift         # Bundled-binary detection & version reporting
├── LocationService.swift      # Public IP & geolocation via ipwho.is (HTTPS)
├── NetworkMonitor.swift       # Real-time upload/download speed
├── PingService.swift          # Proxy delay via user-space xray behind a sing-box Clash API
├── BypassService.swift        # Connect-time fitting: bypass rule, TUN IP families, xray server pin; domain input
└── Models.swift               # Server, Subscription, Engine types
```

Sidebar: Servers, Routing, Advanced, Logs. It is an icon rail, collapsed to 60 pt by default and
expanded to 180 pt with labels by its own arrow — the built-in sidebar toggle is removed so there
is one control, not two. The connection panel is the right column on every page.

Every service is created and owned by `AppState`, which `AppDelegate` holds and every view
takes as its single `app` parameter. `AppState` is a deliberate exception to "no premature
abstractions": five pages cannot each carry six service parameters, and the bootstrap has to
run at launch rather than when some view happens to appear. User settings persist via
`@AppStorage` (UserDefaults).

The selected server is an observable property on `AppState`, persisted on write. It used to be
read straight from `UserDefaults`, which `@Observable` does not track — then every view that
merely displayed the selection had to carry an `@AppStorage` for a key it never edited, just to
be invalidated. The bypass keys still work that way, and it is safe only because `RoutingView`
both edits them and holds the matching `@AppStorage`: keep that `@AppStorage` where the editing
is, or make the value observable the way the selection is.

`sing-box` and `xray` ship inside the `.app` at `Contents/Resources/` (arm64). They are
committed to `Binaries/` and copied in by the Xcode "Bundle VPN Binaries" build phase.
`./fetch-binaries.sh` refreshes them — pinned tags, SHA-256 verified.

**One connection topology.** Every server runs on xray: a SOCKS proxy on port 10808, run as the
user and started by the app, with a sing-box TUN wrapper in front of it that holds every routing
decision. Only that wrapper runs as root, and for an IP-literal server its server rule is by
address alone, so it does not care who dialed. The bypass rule goes into it through `BypassService.injectSingBox`. xray's own
connection to its server enters the TUN as well and is routed `direct` by address (`ip_cidr`),
never by name. A server given as a hostname is resolved by the app at connect, inside the
session and off the main actor, retried for half a minute while a network settles
(`BypassService.resolveAddresses`); every address goes into the wrapper's rule, and the xray
config gets the same addresses pinned in xray's own DNS (`dns.hosts` +
`sockopt.domainStrategy: ForceIP`, `BypassService.pinXrayServer`), so xray dials only addresses
the wrapper routes direct. A name the pin misses would go to xray's localhost DNS client — the
system resolver — so the pin is written under every spelling xray may look the name up by (as
written, without a trailing dot, lowercased); ForceIP fails a dial whose lookup fails outright.
A name can resolve to a CDN's shared edge, so for a server given by name the wrapper's rule needs
xray's process path as well as the address (a `logical` and) — other sites on that edge stay in
the tunnel, and if macOS stops serving root the socket list such a server loops rather than
leaks (owner, 2026-10-15). The address is read from `vnext` (vless, vmess), `servers` (trojan,
shadowsocks, socks) or flat in `settings`, and a config without one is refused. Every xray config
— built from a link, taken from a panel's `?format=xray`, pasted, or stored by an earlier build
(moved at load) — runs in the app's frame: one socks inbound on 10808, the proxy, a freedom
outbound it dials through if it names one (`sockopt.dialerProxy`; a `proxySettings` dialer is
rewritten into one, since xray hands that dial to the sibling by name, past the pin), a freedom
`direct`, no routing rules, which would send "direct" traffic back through the TUN. A session
counts as Connected (`ProcessManager.isTunnelUp`) once the engine shell's own `[sing-box]
started` line has reached the log the app tails — not when the helper launches, which without
passwordless is a password dialog — and the TUN's address, 172.19.0.1, is on an interface, which
sing-box does only after reading its config and making the TUN. The status, the uptime, the
menu-bar shield, the speed monitor and the location polling wait for it, and the window says
Connecting until then.

---

## Build & Run

Build through Xcode, `./dev-run.sh` or `./install.sh` — never `swift build`, the app needs a
real bundle with `Info.plist`.

1. `./fetch-binaries.sh` once, to populate `Binaries/`.
2. `WarpVeil.xcodeproj` → Cmd+R.
3. `./release.sh` for a signed + notarized build (`NOTARY_PROFILE` required for notarization).
4. `./install.sh` to build Release without Xcode and replace `/Applications/WarpVeil.app`.

### dev-run.sh

Builds and runs a dev copy that coexists with an installed or Xcode-launched build:

```bash
./dev-run.sh          # build and launch
./dev-run.sh --watch  # rebuild and relaunch on every source change; Ctrl+C stops the copy
./dev-run.sh --stop   # stop the copy and its VPN engines
```

Isolation comes from overriding the bundle id (separate `UserDefaults` domain) and suffixing
the version (`ProcessManager` derives its sudoers, libexec, PID and log paths from
`CFBundleShortVersionString`). Not isolated: `~/.config/warpveil/subscriptions.json`; the
TUN interface — only one build can hold a tunnel at a time; the second one's sing-box fails at
the TUN, it does not take the tunnel over; and passwordless — enabling or disabling it in one
build removes every other build's sudoers entry and libexec directory (they are the same hole),
so the other copy's next connect or disconnect goes through the password dialog and its toggle
reads off until it is switched on again.

`--watch` is a rebuild-and-relaunch loop, not hot reload: in-memory state resets on every
change, `@AppStorage` survives. Each relaunch activates the app; the window comes back at its
saved frame, and the dev bundle id has its own defaults so its frame is separate.

### install.sh

Builds Release into `build/` (shared with `release.sh`, which wipes it; otherwise incremental),
signs the way `release.sh` does (Developer ID if present, ad-hoc otherwise, no notarization),
quits the installed copy, replaces `/Applications/WarpVeil.app` and relaunches it. No flags.
`/Applications` is admin-writable, so the replacement itself needs no sudo. The new bundle is
staged as `/Applications/.WarpVeil.app.new` and renamed in — a failed copy must not leave
`/Applications` with no app after the old one is already quit.

The quit goes to `application "/Applications/WarpVeil.app"` by path, because the bundle id is
shared with any Xcode-launched copy, and waits up to 35 s — the app's own quit path waits 30 s
for its teardown, a password dialog when passwordless is off. Engines still alive afterwards are
swept by the **installed** copy's version tag (read from its `Info.plist`), not the one being
built: after a version bump the new `run.sh` cannot see the old tag's PID file. An xray is the
user's — its PID file is `$TMPDIR/warpveil-<tag>-xray.pid` and it is killed without sudo; a
sing-box is swept with `sudo stop.sh` of that tag when installed, else `sudo kill`, and a PID is
signalled only while its executable is one of our engines. An Xcode-launched copy of the same
version shares those files and loses its tunnel too. Under the same version a stale PID file is
dropped by `kill_pid_file` at the next connect; after a bump the old tag's PID file stays behind
— the sudoers entry and libexec directory are removed by the next passwordless toggle in any
build.

Callable from anywhere via `ln -sf "$PWD/install.sh" ~/.local/bin/warpveil-install`; the script
resolves its own path with `readlink -f`.

---

## Code Style

Write the simplest code that works. Prioritize readability over cleverness.

- Keep functions short and focused — one function does one thing
- Flat is better than nested: use `guard` for early returns instead of deep `if/else`
- No premature abstractions — don't create protocols, generics, or wrappers until there are 3+ concrete uses
- No over-engineering: if a task takes 5 lines, don't write 20
- No unnecessary comments — code should be self-explanatory. Comment only the "why", never the "what"
- No dead code — delete unused functions, variables, imports. Don't comment them out
- Name things clearly: `isConnected` not `flag`, `retryDelay` not `d`
- Avoid force unwraps (`!`) — use `guard let` or `if let`
- Don't add error handling for scenarios that can't happen
- Don't add features or refactor code that wasn't asked for

## Tech Conventions

- Swift concurrency (async/await, Task)
- `@Observable` for reactive state, not ObservableObject/Published
- `@AppStorage` for persistent user settings
- `Process` + pipes for shell commands, `osascript` for privilege escalation
- All UI in SwiftUI. AppKit appears only in `WarpVeilApp.swift`, which owns the window, the
  status item and its menu — everything hosted inside is SwiftUI
- No external Swift package dependencies
- `ProcessManager.logs` is trimmed to the last 500 entries once it passes 600

---

## Key Decisions

- **Few settings** (owner, 2026-10-15): the app decides by itself wherever it can. A setting is
  added only for a problem it solves that no default can — a TUN MTU picker, a DNS upstream, a
  watchdog switch and a refresh-interval picker were all turned down on this ground
- **No sandbox**: the app runs sing-box as a root child process (sudo in passwordless mode, osascript otherwise), which needs full system access for the TUN; xray runs as the user
- **Window model**: one resizable `NSWindow` built in `AppDelegate`, hidden on close rather than
  destroyed (`isReleasedWhenClosed = false`), so the SwiftUI graph and its `@State` survive. The
  content is a three-column `NavigationSplitView` and the window owns its size. Traps:
  `NSHostingController.sizingOptions` is `[.minSize]`, so the window minimum comes from the column
  minimums and the root's `minHeight` (`[]` lets the window shrink under its content); assigning
  the controller zeroes the content size, so `setContentSize` has to follow it;
  `.toolbar(removing: .sidebarToggle)` only works on the sidebar column's content — on the split
  view it compiles and does nothing; `.doubleColumn` hides the sidebar, not the middle column, so
  every sidebar item needs middle-column content. The frame is autosaved as `MainWindow`; the
  column widths are not
- **Page chrome**: every middle-column page wears the grouped-`Form` look. Servers, Routing and
  Advanced are real `Form { Section }`s. Logs is not: a grouped `Form` on macOS builds all 500 log
  rows at once, its row separators and insets cannot be removed, and one `Text` of every line
  costs ~110 ms per log update against ~11 ms for the `LazyVStack` — so `LogView` keeps
  `ScrollView { LazyVStack }` and copies the Form's metrics by hand (13 pt semibold header at
  30 pt, card 20 pt from the edges, corner radius 10, row inset 10, `quaternarySystemFill`).
  A change to one of the two has to be made to the other. Servers' page header ("Servers", Ping
  all, + Add) rides on the first subscription's section header, because a section with no rows
  renders its header alone and drops the next header to footer style
- **Quit path**: `applicationShouldTerminate` disconnects and replies `.terminateLater`, waiting
  up to 30 s for the teardown — with passwordless off that teardown is a password dialog, so
  anything that kills the app on a timer has to outwait it. Every quit goes through it — Cmd+Q,
  the status menu, `dev-run.sh`, `install.sh`. `ProcessManager`'s
  `willTerminateNotification` observer disconnects inside a `Task`, so a plain terminate can exit
  before the root engines are stopped
- **Apple Silicon only**: `ARCHS = arm64`, and `fetch-binaries.sh` pulls arm64 assets. Intel support, if ever needed, is a separate piece of work
- **NSAllowsArbitraryLoads**: user-provided subscription URLs may be HTTP; the app's own calls (`LocationService` → `ipwho.is`) use HTTPS
- **Version-tagged privileged paths**: sudoers, libexec, PID files and the log all carry the app version (`1.2` → `warpveil-1-2`), because `.` is illegal in a `/etc/sudoers.d/` filename. Side effect: every version bump re-asks for the password once
- **Passwordless mode**: installs into `/usr/local/libexec/warpveil-<tag>/` (root:wheel) a copy
  of the bundled `sing-box` plus `run.sh`/`stop.sh` (0755), and a sudoers entry whitelisting
  those two exact script paths — no wildcards. `run.sh` takes no arguments and reads the config
  on stdin; the binary it runs is its own root-owned copy, never a path it was given, because
  the `.app` is the user's and a bundled binary can be swapped by anyone running as the user.
  The copy is taken at the password prompt: code running as the user before that rides the
  prompt, as it can ride any admin prompt — a pin kept in the user's own bundle would not stop
  it. Enabling or disabling in any build first removes every `/etc/sudoers.d/warpveil*` and
  `/etc/sudoers.d/vpnswift` and every `/usr/local/libexec/warpveil*` — an older tag's `run.sh`
  is the old hole for as long as its entry exists. The install reads as on only while the two
  scripts match byte-for-byte what this build would install and the root copy is byte-for-byte
  the bundled sing-box (mapped pages compared at launch and after an install or removal — the
  83 MB comparison is too slow for every call); a script change or an engine bump reads as off,
  the log says so, and switching the toggle on re-installs with one prompt. The sudoers entry and
  the scripts are re-read before every connect and disconnect, because another build's toggle
  removes them while this one runs
- **Config policy**: every root sing-box — passwordless or not — runs a copy of its config that
  `run.sh` (or the osascript command) made from stdin — at most 4 MiB — in the root-owned 0700
  `/var/run/warpveil-<tag>/stage/`, removed by an EXIT trap however the shell ends, and only
  after `/usr/bin/jq` (macOS 15+, run under `env -i`) accepted that copy. Root never opens a
  path a caller chose: `run.sh` gets the config on stdin from the app, and the osascript command
  reads the app's file with a `cat` running as the user (`sudo -u '#<uid>'`). The policy: top-level keys limited to `log`,
  `dns`, `ntp`, `inbounds`, `outbounds`, `endpoints`, `route`, `experimental`; any key ending in
  `_path`/`_directory`/`_file` (except `process_path`) or starting with `output`, `external_ui`,
  `cache_file`, `acme`, `write_to_system`, `download_url`, `geoip`, `geosite` refused; `path`
  refused under a `local` rule-set or a `hosts` server; `tor` and `tailscale` refused; keys
  compared lowercased, non-ASCII keys refused. The check runs before `kill_pid_file`, so a
  refused connect never takes a tunnel down. It is a denylist of sing-box's file, directory,
  exec and system-state keys (`ProcessManager.configPolicy`), so a sing-box bump is reviewed for
  new ones. `PATH` and `HOME` are pinned in every root shell: macOS's sudoers has no
  `secure_path` and keeps the caller's `HOME`. The only config the app hands root is the wrapper
  it builds, which names no file; the policy is what holds when something else feeds `run.sh`
- **PID files**: `run.sh`, `stop.sh` and the osascript fallbacks kill by PID file only — one
  shared `kill_pid_file`, which checks that the PID's executable is sing-box, then waits up to
  5 s for it to exit before the file is removed; nothing else on the machine is touched. The
  file is `/var/run/warpveil-<tag>/singbox.pid`, in a root-owned directory: in `/tmp` root's
  write would follow a symlink planted at its name. xray's file is the app's own
  (`$TMPDIR/warpveil-<tag>-xray.pid`), read by `ProcessManager.stopOrphanedXray` at the next
  connect under the same rule (`proc_pidpath` ends in `/xray`; one that outlives the wait keeps
  its file and stops the connect) and by `install.sh`/`dev-run.sh`. A connect is a session from
  its first line: `isRunning` is true while the server's name resolves and xray starts, so
  disconnect, restart, wake and quit tear a pending start down, and a cancelled start touches nothing. A port 10808 that is
  already taken is refused before xray starts; the wrapper starts only once xray's port accepts
  connections; a session that never reached the helper skips the root stop; and an xray that
  exits while connected disconnects. A sing-box with no PID file at our path (another build's tag, a
  hand-started one) survives, and the next connect fails with sing-box's own error in Logs. PID
  files are not deleted at launch: they are the handle on an engine a crash orphaned
- **JSONSerialization, not Codable**: the server pin rewrites arbitrary xray configs from feeds and needs untyped JSON
- **Bundled binaries only**: `ProcessManager.findBinary` resolves engines from `Bundle.main.resourcePath` and nowhere else — Homebrew, MacPorts and `$PATH` are ignored. The bundle is what xray, the ping and the non-passwordless path run; the passwordless `run.sh` runs the root-owned copy made from it at install
- **Binary upgrades ship with the app**: no in-app updater; bump the pinned tags in `fetch-binaries.sh` and cut a release
- **No routing modes, no Clash API in the tunnel** (owner, 2026-10-15): Global and Rule are the
  bypass toggle off and on, and Direct is a disconnect. An active connections page was the one
  other user of a production Clash API and was dropped too — debugging goes through Logs
- **xray for every server, sing-box only as the TUN** (owner, 2026-10-15): Xray servers from
  v26.7.11 default to `minClientVer: 26.3.27` for REALITY, and sing-box (1.14.3 too) announces
  1.8.1, so such a server answers it as its camouflage target; from v26.9.8 they also require an
  `X25519MLKEM768` key share (SagerNet/sing-box#4520). The bundled xray is 26.3.27, the last stable
  release, which meets that default exactly — a server that raises it needs a newer xray, which
  runs as the user. Feeds are read as links, then as `?format=xray`; a pasted sing-box JSON is
  refused. A sing-box config an earlier build stored stays listed and is refused at connect,
  which is why `Engine` keeps its sing-box case. xray's own TUN, which would retire sing-box, sets
  no routes on macOS before Xray 26.7.11, and every release since is a prerelease
- **Ping is a user-space measurement**: `PingService` runs a user-space xray with a socks inbound
  per server, chained into a user-space sing-box as socks outbounds behind
  `experimental.clash_api` on a free localhost port, and asks `/proxies/<Server.id>/delay` per
  server. No sudo, no TUN. A server's freedom dialers come along under per-server tags, so the
  probe goes the way the connection does. A server xray refuses at config load would take the
  merged xray down with every row, so after a refused merge each server's config is checked
  alone with `xray run -test`, the refused ones show as failed and are named, and the merge runs
  again without them. Every tag is measured in three passes over the same engines and the
  minimum is reported: the first request through a
  proxy carries its REALITY/TLS handshake, which puts every server at the same ~800 ms and hides
  the real differences. Passes over all tags, not three requests in a row on one tag — that shape
  was built and measured worse: only the sing-box rows warmed up, the xray rows stayed at ~700 ms
  and three of them timed out, because simultaneous cold handshakes are themselves what makes a
  request time out. Works with the tunnel up: every outbound that leaves the machine is bound to the
  primary interface (`streamSettings.sockopt.interface`), read from `SCDynamicStore`'s
  `State:/Network/Global/IPv4` → `PrimaryInterface`, which stays physical because sing-box's TUN
  registers no configd service. The socks hops to xray are not pinned — loopback cannot be bound
  to a NIC. Nothing in `ProcessManager` touches a ping's engines

## Runtime Files

`<tag>` is the app version with dots replaced by dashes.

- `$TMPDIR/warpveil-<tag>.log` — VPN process log, tailed by a 0.25s polling timer
- `$TMPDIR/warpveil-singbox-<pid>.json` — the TUN wrapper's sing-box config
- `$TMPDIR/warpveil-xray-<pid>.json` — xray config; a server given by name has it pinned to the resolved addresses
- `$TMPDIR/warpveil-ping-{singbox,xray,xray-test-<n>}-<pid>.json` — ping configs, present only during a run
- `/var/run/warpveil-<tag>/singbox.pid` — sing-box's PID, root's (directory 0755)
- `$TMPDIR/warpveil-<tag>-xray.pid` — xray's PID, the user's
- `/usr/local/libexec/warpveil-<tag>/{run.sh,stop.sh,sing-box}` — the passwordless install,
  root-owned
- `/var/run/warpveil-<tag>/stage/singbox.XXXXXX` — the root-owned copy of the sing-box config the
  engine runs (directory 0700), removed when its shell ends
- `~/.config/warpveil/subscriptions.json` — subscriptions, shared across all builds; written with
  sorted keys, so a load that changes nothing writes nothing

## Gotchas

- TUN comes up with a delay — location detection retries at 3, 5 and 10 seconds after the tunnel
  comes up (`isTunnelUp`), not after the connect: a name lookup can come first
- `which` is unreliable inside `.app` bundles (no shell profile) — resolve paths explicitly
- Sleep/wake reconnects after a 5 second delay to let the network settle
- A domain rule placed before `sniff` never matches a TUN connection: it arrives as an IP
  destination and the domain exists only after the sniff action. `injectSingBox` puts the bypass
  rule right after the first `sniff` with no condition — nothing but `type`, `action`, `timeout` —
  inserting one at the top when the config has none
- A sniffed SNI is lowercase punycode, so bypass domains are stored that way
  (`BypassService.normalizeDomain`); `domain_suffix` covers subdomains and never an IP literal.
  A whole TLD is typed and stored as `.ru` — a bare word is rejected, or pasted text would bypass
  zones. Each stored row is normalized again on its way to the engine — older builds stored rows
  as typed — and a row that does not normalize is flagged on the Routing page and left out
- The Clash API silently drops a test URL that starts with `http://` and substitutes its own
  default, and it rejects a delay request with no `timeout` — the URL must be HTTPS
- sing-box prints nothing at `log.level: warn`, so a ping's readiness is `GET /` answering,
  not a log line
- Two delay tests on one outbound tag at once time each other out — a ping pass measures each tag
  once, tags run concurrently
- `route get` answers the TUN while it is up; the physical interface is configd's
  `PrimaryInterface` (`scutil` → `show State:/Network/Global/IPv4`)
- A wrong interface name in the ping fails silently — every row `--`, no error line
- Inside a grouped `Form` on macOS, `listRowBackground`, `listRowSeparator` and `listRowInsets`
  are no-ops and `listSectionSpacing` does not exist — draw row state on the row's own content
- A grouped `Section` with a header and no rows renders the header alone and the next section's
  header in footer style — keep every section non-empty
- In a grouped `Form` a `TextField` title renders as the row's label, not as a placeholder — put
  the example in `prompt:` and hide the label
- A `Text` literal is a `LocalizedStringKey`, and a bare `www.` domain in it renders as a clickable
  link — UI copy that names a domain is `Text(verbatim:)`
- A single Clash delay test is a cold one: it pays the handshake to the proxy, so one request per
  tag reads ~800 ms for every server and never moves between runs
- `kill -0` on a root-owned engine from the user's shell fails with "not permitted", which reads
  as "dead" — the scripts read `ps -o comm=` instead, which also keeps them off a recycled PID
- The TUN's IP families follow the host's, set at connect time (`BypassService.fitTunToHost`,
  configd's `State:/Network/Global/IPv6`). While connected, a change of that key schedules one
  comparison 5 s later; if the host has gained or lost global IPv6 by then, the engines restart.
  A ULA on the TUN of a host with no global IPv6 makes macOS hand out AAAA records, and a
  bypassed destination dials direct over IPv6 into `no route to host` — `dns.strategy` does not
  help, apps with their own DoH never pass through sing-box. No IPv6 on the TUN of a dual-stack
  host leaks every IPv6 connection past the VPN: sing-tun routes IPv6 only for a TUN with an IPv6
  address, and `strict_route` does nothing on macOS
- `dscacheutil -q host` prints AAAA records the system resolver will not hand to apps; what an
  app gets is `getaddrinfo` — check IPv6 behaviour with that
- System DNS stays outside the tunnel, by the owner's decision (2026-10-15): the CLI sing-box
  cannot bring it in. mDNSResponder sends every query bound to its resolver's interface
  (`if_index` in `scutil --dns`) — a side TUN holding a `/32` to the LAN resolver caught
  `dig @resolver` but no `getaddrinfo` lookup, even after `killall -HUP mDNSResponder` — and
  `tun.dns_mode: native` does nothing outside the SFM app (SagerNet/sing-box#4183). Only
  NetworkExtension sets a resolver safely; a root script rewriting configd's DNS leaves the
  network broken when it dies. A resolver outside the LAN is reached through the TUN, but the
  wrapper's `hijack-dns` sits before `sniff` and never fires: those queries ride the proxy as UDP
- The wrapper's server rule is `ip_cidr`, never `domain_suffix`: xray's dial to its server arrives
  as an IP, and what a sniff would read is the REALITY camouflage SNI, not the server's name — a
  domain rule for the server never matches and the dial loops back into xray
- The TUN's stack completes every TCP handshake itself, so a dial through it "connects" to any
  address, dead or alive: xray's `happyEyeballs` races nothing there (measured: a dead pinned
  address won every race), and a TCP connect is no reachability check
- sing-box's `process_path`/`process_name` rules read `net.inet.tcp.pcblist_n`, which macOS 27
  answers with the header alone for a process without `com.apple.private.network.statistics`
  (`netstat` has it, the bundled engines do not) and in full for root — measured 2026-10-15, 48
  bytes against 548 KB. Process rules work only in the root wrapper; the rule for a server given
  by name relies on it
- sing-box's JSON decoder matches field names case-insensitively with Unicode folding: `OUTPUT`
  and `timeſtamp` reach `output` and `timestamp`. Anything that filters config keys compares
  them lowercased and refuses non-ASCII keys
- macOS's sudoers has `env_reset` but no `secure_path`, and `env_keep` holds `HOME`: a
  `NOPASSWD` script inherits the caller's `PATH` and `HOME`. Every root shell here pins both,
  and jq runs under `env -i` — it loads `~/.jq` on start, which can redefine its builtins
- A `sudo -u user cmd` from a root script keeps sudo as the parent — `$!` is sudo's PID and
  `ps -o comm=` says `sudo`, so it cannot be tracked by PID file. xray is started by the app
- Two `FileHandle(forWritingAtPath:)` on one log overwrite each other: they are separate open
  file descriptions at offset 0. Writers that share a log get one handle opened `O_APPEND`
- `/usr/bin/jq` exists from macOS 15, and every root connect needs it for the config policy —
  that is why the deployment target is 15

---

## Communication

- Always respond in Russian, but keep internal reasoning in English
- Code, comments, commit messages, plan files and variable names stay in English

## Git Workflow

- Single `main` branch
- Commit messages in English, imperative mood
- Atomic commits — one logical change each, never bundle unrelated work
- Every commit must leave the project compiling
- Do not commit: `.app` bundles, build output, certificates, `.env` files
- The repository is public. The owner's addresses, server IPs and hostnames, subscription URLs and
  credentials never go into a commit — not in a plan, a script or a log pasted into one. A live
  script reads them from the environment (`WARPVEIL_HOME_IP`, `WARPVEIL_SERVER_IP`); a plan quotes
  results with documentation addresses (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`).
  Taking one out of history means rewriting it and a force-push the owner runs by hand
