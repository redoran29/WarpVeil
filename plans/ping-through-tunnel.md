# Ping through the tunnel: bind the probe to the physical interface

Status: plan, not yet implemented. Written against `82bc6c7` (clean tree). Second draft: the
first one kept the ping's engines out of `run.sh`'s `pkill -f` by spelling their argv differently;
the owner rejected that and chose the root fix — `run.sh` kills by the PID files it already
writes. `ProcessManager` is therefore in scope.

`plans/server-ping.md` shipped a ping that refuses to run while the tunnel is up
(`AppState.pingAll()` guards on `!pm.isRunning`; the header button is disabled with "Disconnect
to measure"). The owner runs the VPN globally, always on, so the feature has never run for him:
the Servers page shows no values and a dead button. The restriction rests on that plan's fact 6 —
"nothing here measures the proxy while the tunnel is up" — which is false. That fact is corrected
in place in `plans/server-ping.md` (history kept, see its fact 6); this plan builds on the
corrected one.

Out of scope and untouched: routing/bypass, `SubscriptionService`, `Models.swift`, the window
shell, `project.pbxproj`, `dev-run.sh`, the sudoers entry and the libexec paths.

## Owner decisions this plan takes as fixed

1. The ping works with the tunnel up, and the button is never disabled for that reason.
2. Still no sudo, no TUN for the ping itself: the pin lives in `PingService`.
3. **`run.sh` stops using `pkill -f` and kills by PID file** — the root fix, not a fourth
   workaround (canon, "The third fix is a signal"). Same for the osascript fallback.
4. The three UX decisions of `plans/server-ping.md` stand (button, automatic run on appear,
   per-row spinner / value / `--`).

## What the code does today (facts the plan relies on)

- `Sources/PingService.swift` — imports `Foundation` and `Darwin` only (`:1-2`); no file in
  `Sources/` imports `SystemConfiguration`. `measure` (`:82-109`) builds `xrayPorts` (`:93-94`),
  calls `launchXray(_:ports:)` (`:97`) and `launchSingBox(_:xrayPorts:apiPort:)` (`:101`).
  `delay(of:)`'s comment (`:131-132`) names "run.sh's pkill on connect" as one reason for a
  missing answer. `launchXray` (`:176-201`) takes the **first** tag's port (`:178`) and returns
  once that one port accepts a connection (`:194`). `singBoxConfig` (`:247-274`) emits the proxy
  outbound as parsed (`:256`) and a `socks` outbound to `127.0.0.1:<port>` per xray server
  (`:258-260`); `xrayConfig` (`:276-298`) emits the xray outbound as parsed (`:283`).
  `proxyOutbound` (`:302-314`) strips `detour` / `proxySettings` only. Helpers start at `:316`;
  `isListening(_:)` is `:337-351`.
- `Sources/AppState.swift` — `isBootstrapped` and its comment (`:19-22`; the last clause is
  "under auto-connect the run would be killed seconds later for nothing"). `bootstrap()`
  (`:70-83`) connects at `:77` and sets the flag last with the comment at `:80-81`. `connect()`
  (`:85-104`) calls `ping.cancel()` at `:92` with the pkill comment at `:91`. `pingAll()`
  (`:123-129`): comment `:123`, guard `:125`.
- `Sources/ServersView.swift` — the header button (`:43-52`): `.disabled(app.pm.isRunning)` at
  `:50`, the two-way `.help` at `:51`. `.onDisappear { app.ping.cancel() }` (`:17`) stays.
- `Sources/ProcessManager.swift`:
  - PID file paths and their comment (`:35-37`). `runShContent` (`:41-112`): `validate_arg`
    (`:45-51`), the argv check (`:53-56`), then `pkill -f 'sing-box run'; pkill -f 'xray run';
    sleep 1` (`:62-64`); each engine's PID is written right after its `&` (`:74`, `:81`, `:98`);
    `trap cleanup TERM INT` is installed only after both starts (`:92`, `:109`). `stopShContent`
    (`:115-128`) defines `kill_pid_file` (`:117-125`: file exists → numeric check → `kill` →
    `rm -f`; no wait, no identity check) and calls it for both files.
  - `isPasswordless = FileManager.default.fileExists(atPath: sudoersFile)` (`:139`);
    `isPasswordlessBusy` (`:140`). `installPasswordless()` (`:142-212`) writes both scripts to
    `/private/tmp`, then one osascript with admin rights `install -m 0755 -o root -g wheel`s them
    into `libexecDir` and installs the sudoers entry (`:179-189`) — the **only** place the scripts
    reach disk. `removePasswordless()` (`:214-239`). `passwordlessOperationFinished()`
    (`:243-246`) recomputes `isPasswordless` from the sudoers file. There is no
    `syncPasswordlessState` in the source; this is the function meant.
  - `init()` (`:248-264`) calls `cleanupStalePidFiles()` (`:249`; body `:268-277`), which deletes
    both PID files plus the v1.0 unversioned ones at every launch.
  - `connect` (`:301-387`) builds the sudo argv (`:352-362`) or the osascript command (`:364-366`).
    `buildNonPrivilegedShellCommand` (`:392-430`) opens with the same pkill line (`:394`).
    `handleWake` (`:279-297`) and `reconnect` (`:527-545`): `killVPNProcesses()`, `isRunning =
    false`, 5 s / 1 s, `connect`. `disconnect()` (`:547-557`). `awaitTeardown` (`:563-570`) polls
    `teardownProcess.isRunning`. `killVPNProcesses` (`:572-600`): sudo `stop.sh`, or an osascript
    with an inline POSIX `kill_pid` one-liner (`:585-589`, no wait, no identity check).
- `Sources/AdvancedView.swift` — the toggle (`:16-23`) reads `pm.isPasswordless`, calls
  `installPasswordless()` / `removePasswordless()`, subtitle from `isPasswordlessBusy` (`:21`).
- `Sources/WarpVeilApp.swift` — `applicationShouldTerminate` (`:88-98`) cancels the ping, then
  `awaitTeardown(timeout: 30)` (`:94`).
- `dev-run.sh` — its own tag (`:31-35`), kills the app binary by exact path (`:40`, `:63`) and
  reads its own PID files (`:45-52`); no `sing-box run` pattern anywhere.
- `WarpVeil.xcodeproj/project.pbxproj` — `PBXFrameworksBuildPhase` (`:52-60`) has an empty
  `files` list; `AppKit`, `Network`, `Observation` are all linked by Swift's autolink.
- `CLAUDE.md`: dev-run "only one build can hold a tunnel at a time" (`:126`); Key Decisions —
  version-tagged paths (`:181`), passwordless (`:182`), PID files with the pkill side effect
  (`:183`), the ping bullet (`:187-193`); Runtime Files `:195-203`; Gotchas `:206-216`.
  `README.md:12`, `:14`, `:73` need no change.
- **The owner's machine, read and not modified:** version `1.2`; `/etc/sudoers.d/warpveil-1-2`
  present; `/usr/local/libexec/warpveil-1-2/run.sh` and `stop.sh` (root:wheel 0755, Apr 22)
  are **byte-identical** to `runShContent` / `stopShContent` rendered from the source — the
  installed `run.sh` carries the pkill. `/tmp/warpveil-1-2-singbox.pid` names the live tunnel.
  `/var/select/sh → /bin/bash` (3.2.57), so `do shell script` runs bash: `[[ … =~ … ]]` and
  `local` work there (probed).
- The real subscriptions file: 1 subscription, 9 `vless` servers — 7 `xhttp` (`engine: xray`),
  2 `grpc` (sing-box), all IP literals.
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2 compiler, project in Swift 5 mode, target macOS
  14.0. Binaries: sing-box 1.14.0, Xray 26.3.27.

## Verified facts (probes on this machine, tunnel up throughout)

The owner's tunnel — root `sing-box run`, a grpc node, `utun7` — was up for every probe and was
not touched. Engine probes ran the binaries from `Binaries/` as the normal user on scratch
configs in the scratchpad; the ping probes used the owner's real outbounds read from
`subscriptions.json`. Nothing privileged was installed or run.

1. **Network state.** `scutil`: `State:/Network/Global/IPv4` = `{PrimaryInterface: en0,
   PrimaryService: 5649C6AF…, Router: 192.168.1.1}`; `State:/Network/Global/IPv6` does not exist.
   Routing table: `default → en0`; the TUN holds half routes `1, 2/7, 4/6, 8/5, 16/4, 32/3,
   64/2 → utun7` (`172.19.0.1`). `route -n get 1.1.1.1` answers `interface: utun7` — useless for
   finding the physical interface. configd services: `en0` (`Router 192.168.1.1`) and `utun6`
   (Tailscale, `Router 100.124.162.59`) each have a `State:/Network/Service/<id>/IPv4` entry;
   `utun7` has only `State:/Network/Interface/utun7/IPv4` and **no service**, so it can never be
   the primary — configd elects the primary among services, not kernel routes.
2. **`SystemConfiguration` from Swift, no explicit link.** A throwaway compiled with `swiftc
   -swift-version 5 -target arm64-apple-macosx14.0 -warnings-as-errors` and no `-framework` flag:
   `SCDynamicStoreCreate(nil, "WarpVeil" as CFString, nil, nil)` +
   `SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]`
   → `["PrimaryInterface"] == "en0"`; the IPv6 key → `nil`. The object file carries an
   `LC_LINKER_OPTION -framework SystemConfiguration` autolink entry, and the full `xcodebuild`
   with `import SystemConfiguration` in `PingService.swift` and the empty Frameworks phase
   succeeded (fact 13). **No `project.pbxproj` change.**
3. **The pin works; nothing else does.** A Python probe rebuilt `PingService`'s two configs
   from the real file, launched both engines and fired nine delay tests at once
   (`https://cp.cloudflare.com/generate_204`, `timeout=5000`):
   - *proposed* — `bind_interface: "en0"` on the two vless outbounds, `streamSettings.sockopt.
     interface = "en0"` on the seven xray outbounds, socks outbounds untouched: **9/9**,
     651–844 ms, 847 ms wall clock.
   - *unpinned* (the shipped shape): **0/9** — six xray rows `503` in ~200 ms with
     `transport/internet/reality: REALITY: received real certificate (potential MITM or
     redirection)` on xray's stdout, three rows `504 Timeout` at 5.002 s.
   - *socks pinned too* (`bind_interface` also on the socks outbounds): 9/9 — only because
     sing-box skips the bind for loopback, fact 4.
   - *`route.default_interface: "en0"`* instead of per-outbound pins: 9/9, same caveat.
   - *wrong name* (`en99`): 0/9, exactly the unpinned picture. Neither engine refuses to start
     or logs the bad name at these levels. **A wrong interface fails silently, per row.**
4. **Loopback cannot be bound to a physical interface.** Python: `IP_BOUND_IF = en0` on a socket,
   then `connect(127.0.0.1:<listening port>)` → `[Errno 49] Can't assign requested address`.
   sing v0.9.0-beta.4 (what sing-box 1.14.0 vendors, `go.mod:48`) — `common/control/bind.go`
   `BindToInterface0`: `if addr.IsValid() && N.IsVirtual(addr) { return nil }`, with
   `IsVirtual = IsLoopback || IsMulticast || IsInterfaceLocalMulticast` (`common/network/addr.go:28`);
   `bind_darwin.go` then sets `IP_BOUND_IF` / `IPV6_BOUND_IF`. sing-box's `common/dialer/default.go`
   `:77-83` applies `bind_interface` through exactly that function, `:100-104` applies
   `route.default_interface` through the same one. xray `transport/internet/sockopt_darwin.go:136-148`
   sets `IP_BOUND_IF` with no loopback exemption — irrelevant here, xray pins only its own outbounds.
5. **xray starts inbounds in map order.** `app/proxyman/inbound/inbound.go:108-123` (v26.3.27):
   `Manager.Start` ranges over `taggedHandlers map[string]inbound.Handler`; `core/xray.go:384-398`
   logs `started` after every feature's `Start`. Observed over six launches of the seven-inbound
   config, polling every port: start index varied (`0…6`, `1…6,0`, `3…6,0,1,2`, `4…6,0…3`), all
   seven up within the same millisecond, 9–69 ms after `Popen`.
6. **The Swift file as written below runs end to end.** `PingService.swift` with Steps 1–2
   applied, compiled by `swiftc` (Swift 5 mode, macOS 14 target, `-warnings-as-errors`) with
   `Models.swift` and two stubs (`ProcessManager.findBinary`, the two type sets), run against the
   real `subscriptions.json`, tunnel up: `isRunning` false after 966–1203 ms, `error == nil`,
   **nine `.delay(…)` results, 723–917 ms**, no `warpveil-ping-*` file left in `$TMPDIR`, no
   engine left behind (`ps`: only the root tunnel).
7. **The new `run.sh` replaces a running pair by PID file.** `runShContent` and `stopShContent`
   of Step 4, rendered from the scratch-copy source by a script (indentation stripped, the three
   interpolations substituted with scratchpad paths) — `diff` against the hand-written files
   the probes ran: **identical**; `bash -n`: clean. As the normal user, with a no-TUN sing-box
   config (Clash API on `127.0.0.1:24995`) and a loopback-socks xray config: first `run.sh` →
   both PIDs written, `ps -o comm=` on them ends in `…/sing-box` and `…/xray`, API `200`. Second
   `run.sh` 3 s later → its log shows no start until the old pair is gone; old PIDs dead, new
   pair up, **API `200` again on the same port** — the old sing-box had released it before the
   new one bound. `stop.sh` → both dead, no PID file left, returned in 33 ms.
8. **The helper's edge cases**, sourced into `bash` with `set -euo pipefail` (run.sh's mode) and
   into `/bin/sh -c` (the osascript path): a PID file naming a dead PID → nothing killed, file
   removed, exit 0; a missing file → exit 0; a file with `abc; rm -rf /` → removed, nothing run;
   a file naming a live `sleep` with name `sing-box` → **not killed** (identity check), file
   removed; a live engine with a non-matching name → left alone, file removed. `ps -o comm=` on
   macOS prints the executable path as invoked (`./fake/sing-box`, `/…/Binaries/xray`), so the
   `*"$name"` glob matches our engines and nothing else.
9. **The wait is bounded.** A C program that ignores `SIGTERM`, built as `fake/sing-box`: the
   helper returned after 5 690 ms, the process still alive, the PID file removed. A process that
   honours `SIGTERM` is gone in ~20 ms.
10. **The literal round-trips.** `swiftc` throwaway: a multi-line literal written with
    `write(toFile:atomically:encoding:)` reads back `==` the literal via
    `String(contentsOfFile:encoding:)`; a missing path gives `nil`, which `== content` is `false`.
    `installPasswordless()` writes the scripts exactly that way (`:169-170`) and `install`
    copies bytes, so the comparison in Step 3 is exact. The installed `run.sh` has no trailing
    newline, like the literal (`xxd`).
11. **Trapped by the old shape, kept out of the new one.** In the first probe of fact 7 the
    second `run.sh` was started 1.5 s after the first — inside the first one's `sleep 1` between
    the xray start and the sing-box start — and read the sing-box PID file before it was written;
    its own sing-box then failed with `external controller listen error: … address already in
    use`. In the app that window is closed by `ProcessManager.connect`'s `guard !isRunning` and
    by `helperProcess?.terminate()` killing `run.sh`'s bash (no trap yet, default `SIGTERM`)
    before a second `run.sh` can start; the probe's timing does not occur. Recorded because it
    is the one way an engine can run without its PID file for a second.
12. **`dev-run.sh`, `stop.sh`, and the quit path** never used the pkill: `stop.sh` and
    `killVPNProcesses` kill by PID file today (facts), `dev-run.sh` by app path and its own PID
    files. Dropping the pkill changes only `run.sh` and the osascript connect.
13. **Every step builds.** The repository copied to the scratchpad; `xcodebuild` (Debug, arm64,
    `CODE_SIGNING_ALLOWED=NO`): baseline `BUILD SUCCEEDED`; then Steps 1+2, Step 3 on top, Step 4
    on top, Step 5 on top — each `BUILD SUCCEEDED` with zero Swift warnings (the only `warning:`
    in every log is `appintentsmetadataprocessor`'s, present at baseline). The real repository
    was not modified (`git status`: only the two plan files).

Not probed — needs root or the owner's tunnel down: the new `run.sh` under `sudo` with a real
TUN; a second sing-box against a surviving TUN; a ping with the tunnel down; a ping overlapping
the TUN coming up; an IPv6 or hostname-addressed server; macOS 14/15. All under Validation.

---

## Decisions

### Pin per outbound, on both engines; never the socks hop

The sing-box proxy outbound gets `"bind_interface": "<primary>"`, the xray outbound gets
`streamSettings.sockopt.interface = "<primary>"`. Both are the engines' own dial-level fields, both
verified on the owner's nodes (fact 3), and both land in the one function each engine's config is
built in.

The `socks` outbounds that chain sing-box to xray dial `127.0.0.1` and are **not** pinned. The
kernel refuses a loopback connect on a socket bound to `en0` — `EADDRNOTAVAIL` (fact 4). That the
pinned variant still measured 9/9 is sing-box quietly dropping the bind for loopback addresses
(fact 4), an upstream courtesy the config should not lean on: loopback is not routed through the
TUN in the first place (`route get 127.0.0.1` → `lo0`), so there is nothing to bypass there.

Rejected — **`route.default_interface`**: one key instead of two injections, verified 9/9, but it
binds *every* outbound, socks hops included, and so is correct only by way of the same exemption.

### The interface is configd's `PrimaryInterface`

`SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4")["PrimaryInterface"]` — the interface
of the service that owns the system's default route. It is `en0` with the tunnel up (fact 1), and
it will stay so under sing-box's TUN for a structural reason: sing-box's `auto_route` adds raw
kernel routes on a `utun` and registers no network service, and configd elects the primary among
services (fact 1). One synchronous call, no framework to link (fact 2), no parsing.

Rejected — **`route get`**: answers `utun7` (fact 1). **`NWPathMonitor`**: asynchronous, lists
the `utun` first, and needs a "which type counts as physical" heuristic. **Parsing `netstat`/
`route`**: text scraping of what configd already publishes.

**When the value is a `utun`** (a third-party VPN that *does* register a service and takes the
default — Tailscale exit node, WireGuard app): the pin sends the probe through that VPN. That is
the path every other program on the machine gets, so the number is honest for the machine as
configured; nothing special-cases it. **If sing-box's TUN ever became the primary** (it would
take an upstream change to register a service on darwin): the pin would point into the tunnel and
every row would read `--` the way the unpinned run does (fact 3) — visible, never a wrong number.
The fix then is to walk `Setup:/Network/Global/IPv4` → `ServiceOrder` and take the first service
whose `InterfaceName` is not a `utun`; not built until the symptom exists.

**When the value is absent** (`nil`): measure **unpinned**. `nil` means configd has no primary
IPv4 service — no IPv4 network at all (an IPv6-only uplink is the one case this misreads, Risks 4).
Unpinned is exactly the shipped shape and is right whenever there is no tunnel; with no network,
every row reads `--` in five seconds either way. A refusal would add an error string and a branch
for a state whose symptom is already visible.

### Always pin, not only while connected

The pin goes in whether or not `pm.isRunning`. One code path instead of two; with the tunnel down
the primary interface is the one the kernel would pick anyway, so the pinned dial is the same
dial; and the pinned path is the only one ever observed succeeding (fact 6 here, facts 3/5/12 of
the ping plan).

### Wait for every xray inbound

`launchXray` returns when **all** its ports accept a connection, not the first. xray starts
tagged inbounds in map order (fact 5), and a delay test against a port nobody listens on is a
`503` in 14 ms (ping plan, fact 2) — a wrong `--` with no way to tell it from a dead node. Never
seen to fail (the seven come up within a millisecond of each other), closed on the source.

### `run.sh` kills by PID file, and waits — the root fix

`run.sh` and the osascript connect open with `pkill -f 'sing-box run'; pkill -f 'xray run';
sleep 1` (facts). Everything the ping plan had to do around that — cancel on `connect()`, the
accepted wake gap — and the launch race this plan would add (under auto-connect, `bootstrap()`
connects and raises `isBootstrapped` in one tick; the ping's engines are up in milliseconds and
`run.sh`'s pkill lands tens of milliseconds later, in exactly the owner's configuration) are the
same thing patched three times. The owner chose the root fix.

**Shape.** One bash function, `kill_pid_file <file> <engine>`, in one Swift constant
(`killPidFileFunction`), interpolated into all four places that kill engines: `run.sh`,
`stop.sh`, the osascript connect, the osascript stop. It is `stop.sh`'s existing `kill_pid_file`
with two additions and a name check, and the osascript stop's POSIX one-liner is replaced by it
(`/bin/sh` is bash here, and that one-liner already used `local`):

- **Identity check** — `[[ "$(ps -o comm= -p "$pid")" == *"$name" ]]` before `kill`. A PID file
  outlives a crash and a reboot recycles PIDs; without the check a stale file would `kill` an
  unrelated process as root. `comm` is the executable path as invoked (fact 8), so `*sing-box` /
  `*xray` match our engines, started by absolute path from `Contents/Resources/`, and a `sleep`
  named the same in a file does not get killed (fact 8).
- **Wait** — after `kill`, poll `kill -0` every 100 ms for up to 5 s. This is what the blanket
  `sleep 1` was for: the old sing-box must release the TUN and its routes before the new one binds
  (fact 7: the API port came back `200` on the same port after the swap; fact 11: what happens
  when it does not wait). The bound keeps a wedged engine from hanging every connect (fact 9);
  after 5 s the file is removed and the start proceeds — into the TUN error described below,
  visible in Logs.
- **The PID file is removed after the wait, not before.** So it doubles as a lock: `handleWake` /
  `reconnect` run `stop.sh` asynchronously and call `connect` 5 s / 1 s later; if `stop.sh` is
  still waiting on a slow engine, `run.sh` finds the file, waits on the same PID itself, and the
  TUN is never bound twice. `disconnect()` then an immediate connect works the same way.
- `cat "$f" … || true` — `run.sh` runs under `set -euo pipefail` and a vanished file must not
  abort the start (fact 8 ran under the same flags).

**`sleep 1` goes.** The wait on the real PID replaces it. The other `sleep 1` — between the xray
start and the sing-box start in the xray topology — is unrelated and stays.

**`cleanupStalePidFiles()` goes.** It deletes both PID files at every launch. With the pkill
gone the PID file is the only handle on an engine orphaned by an app crash (the `sudo`/`bash`
chain keeps running), and deleting it at the next launch throws that handle away right before
`run.sh` needs it. A stale file is harmless to keep: the helper drops it on a dead or foreign PID
(fact 8). The v1.0 unversioned paths it also removed are dead; nothing reads them.

**`awaitTeardown` becomes real.** `stop.sh` now returns after the engines are gone, so the quit
path's 30 s wait is on the engines, not on `kill` returning. No code change there.

**What is lost, plainly.** `CLAUDE.md:183` documents the pkill as a deliberate side effect:
"starting a tunnel does kill any other one on the machine". After this, an engine **without a
PID file at our path** survives a connect: a tunnel held by another build (a `dev-run.sh` copy
and the installed build carry different tags), a hand-started `sing-box`, or an engine whose file
was deleted by an *older* build's `cleanupStalePidFiles` before this one ran. Such an engine keeps
its TUN and routes; the new sing-box then fails at start — expected to be a FATAL on the TUN or
route setup, **not observed** (needs root) — the Logs page shows it and `[Disconnected (exit 1)]`,
and the fix is by hand (`sudo pkill sing-box`, or `dev-run.sh --stop` for the dev case). The
canon's "only one build can hold a tunnel at a time" changes meaning: the second build no longer
steals the tunnel, it fails to connect. Priced, accepted by the owner's choice.

### The installed scripts can be stale — and the owner's are

`isPasswordless` is `fileExists(sudoersFile)` (`:139`), and the scripts reach
`/usr/local/libexec/` only through an explicit `installPasswordless()` (facts). Ship Step 4 alone
and an existing install keeps running the old `run.sh`, pkill and all, forever — the owner's
install is exactly that (facts: byte-identical to today's literal).

**The app compares the installed scripts with what it would install.** `isPasswordless` becomes
`passwordlessInstalled()`: the sudoers file exists **and** `run.sh` **and** `stop.sh` on disk
read back byte-equal to `runShContent` / `stopShContent` (fact 10; the files are 0755, readable
without privileges). A stale install reads as **off**. `init()` logs why when the sudoers file is
there but the scripts are not current. `passwordlessOperationFinished()` uses the same function,
so the toggle reconciles the same way after an install or a decline. `isPasswordlessBusy` and the
`AdvancedView` toggle are untouched: the toggle already calls `installPasswordless()` when
switched on, and that install overwrites the scripts in place (`install -m 0755`, `:183-184`).

**What the owner sees**, passwordless installed today: the first launch of a build with Step 4 —
the Passwordless toggle reads **off**; the Logs page starts with `[Passwordless scripts are from an
older build — turn Passwordless on again in Advanced]`; if auto-connect is on, that connect and
every connect until re-enabled go through the osascript path and **ask for the password** (the
osascript path also carries the new kill — Step 4 changes both). Switching the toggle on asks for
admin rights **once**; from then on no prompt, on this launch or any later one. Declining the
prompt leaves the toggle off and the password on every connect; the log line repeats at each
launch until the scripts are current. This is the same experience the canon already documents
for a version bump (`CLAUDE.md:181`, "every version bump re-asks for the password once") — a
version bump alone would also have flipped the toggle, since the sudoers path carries the tag —
except that here the log says why. Rejected: a silent re-install at launch (an admin dialog with
no user action behind it); re-installing inside `connect()` (chains an async osascript in front of
another). Rejected: relying on a version bump instead of the content check — it works only as
long as everyone remembers.

### The ping side, after the root fix

- `AppState.connect()`'s `ping.cancel()` was there for the pkill and only for it (`:91`); it goes.
  A ping in flight while the tunnel starts keeps running: its sockets are bound to `en0` and the
  TUN's routes do not reach them.
- The wake / reconnect gap of the ping plan — `run.sh` pkilling a ping mid-run — no longer
  exists; nothing in `ProcessManager` touches a ping's engines. `delay(of:)`'s `nil` → unmeasured
  mapping stays: it is still the right answer for a cancel.
- `ServersView.onDisappear` and `applicationShouldTerminate` keep their cancels — leaving the
  page or quitting still has to stop two user-space processes.
- `isBootstrapped` stays for the stale-set reason; its "killed seconds later" clause and the
  "Last, so …" comment in `bootstrap()` describe the pkill and go.

### The restriction goes

`pingAll()` guards on `isBootstrapped` only. The header button is never disabled; its tooltip is
"Measure every server". The automatic run on the page's appearance now fires while connected
too — two user-space engines for about a second and nine HEAD requests per visit; cheap.

---

## Step 1 — Wait for every xray inbound

**Commit:** `Wait for every xray inbound before measuring`

### `Sources/PingService.swift`

`launchXray` (`:173-201`) — the comment, the port lookup and the readiness test:

```swift
    // Reports whether the xray leg is usable; the caller drops the xray rows rather than the run.
    // Readiness is every socks inbound accepting a connection, not a log line: a log line is
    // upstream's wording, and waiting for one that never comes hangs the whole service. Every
    // inbound, because xray starts tagged inbounds in map order — the first one listed is not
    // the first one up, and a delay test against a port nobody listens on fails in 14 ms.
    private func launchXray(_ servers: [Server], ports: [String: UInt16]) async -> Bool {
        let (config, tags) = Self.xrayConfig(servers, ports: ports)
        let listeningPorts = tags.compactMap { ports[$0] }
        guard !listeningPorts.isEmpty else { return false }
```

and at `:194`:

```swift
            if listeningPorts.allSatisfy(Self.isListening) {
```

### Compiles because

`isListening` is `private static func (UInt16) -> Bool` (`:337`), a valid `allSatisfy` argument;
`port` had one use. Built (fact 13).

### What could go wrong

- An xray inbound that never listens (port taken between `freePorts` and xray's bind) now holds
  the whole xray leg to the 3 s cap and then "xray did not start" — before, it would have passed
  if it was not the first one and produced `--` rows. Correct: the error names the problem.

---

## Step 2 — Bind the probe to the primary interface

**Commit:** `Bind the ping's outbounds to the primary interface`

### `Sources/PingService.swift`

Imports (`:1-2`):

```swift
import Foundation
import Darwin
import SystemConfiguration
```

Header comment (`:10-14`) gains two lines after "No sudo, no TUN.":

```swift
// Every outbound that leaves the machine is bound to the primary interface, so a tunnel that
// is up does not swallow the probe: the number is the proxy, never tunnel + proxy.
```

`measure` (`:93-101`) — look the interface up once per run and hand it to both launches:

```swift
            var xrayPorts = Dictionary(zip(xrayServers.map(\.id), ports.dropFirst()),
                                       uniquingKeysWith: { first, _ in first })
            let interface = Self.primaryInterface()
            // An xray that will not start costs the xray rows their value, not the whole run:
            // the sing-box servers in the same list never needed it.
            if !xrayServers.isEmpty, await !launchXray(xrayServers, ports: xrayPorts, interface: interface) {
                xrayPorts = [:]
            }
            guard !Task.isCancelled else { return }
            let tags = try await launchSingBox(servers, xrayPorts: xrayPorts, apiPort: apiPort, interface: interface)
```

`launchXray` signature and its first line (from Step 1's shape):

```swift
    private func launchXray(_ servers: [Server], ports: [String: UInt16], interface: String?) async -> Bool {
        let (config, tags) = Self.xrayConfig(servers, ports: ports, interface: interface)
```

`launchSingBox` signature and its first line (`:205-208`):

```swift
    private func launchSingBox(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16, interface: String?
    ) async throws -> [String] {
        let (config, tags) = singBoxConfig(servers, xrayPorts: xrayPorts, apiPort: apiPort, interface: interface)
```

`singBoxConfig` (`:247-261`) — a comment above it, the parameter, `let` → `var`, the pin:

```swift
    // The socks outbounds are not pinned: they dial loopback, which the kernel refuses to bind to
    // a physical interface (EADDRNOTAVAIL). sing-box happens to skip the bind for loopback, but
    // the config should not lean on that.
    private func singBoxConfig(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16, interface: String?
    ) -> (String, [String]) {
        var outbounds: [[String: Any]] = []
        var tags: [String] = []
        for entry in servers {
            var outbound: [String: Any]?
            switch entry.engine {
            case .singBox:
                outbound = Self.proxyOutbound(of: entry.server, types: Self.singBoxPingTypes, typeKey: "type")
                if let interface { outbound?["bind_interface"] = interface }
            case .xray:
```

The `.xray` case and the rest of the function are unchanged.

`xrayConfig` (`:276-285`) — the parameter, `let` → `var` on the outbound, the pin:

```swift
    private static func xrayConfig(_ servers: [Server], ports: [String: UInt16], interface: String?) -> (String, [String]) {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        var tags: [String] = []
        for server in servers {
            guard let port = ports[server.id],
                  var outbound = proxyOutbound(of: server, types: SubscriptionService.vpnTypesXray, typeKey: "protocol")
            else { continue }
            if let interface {
                var streamSettings = outbound["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = streamSettings["sockopt"] as? [String: Any] ?? [:]
                sockopt["interface"] = interface
                streamSettings["sockopt"] = sockopt
                outbound["streamSettings"] = streamSettings
            }
            let inboundTag = "in-\(server.id)"
```

Helpers (`:316`, before `serialize`):

```swift
    // The interface carrying the system's default route. sing-box's TUN adds half routes and
    // leaves the real default on the physical interface, so this stays physical while the
    // tunnel is up — `route get` would answer the TUN. nil means no IPv4 network at all.
    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "WarpVeil" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
```

Reading notes:

- `if let interface { … }` rather than `outbound["bind_interface"] = interface`: the explicit
  form cannot store a wrapped `Optional` inside `Any`, which `JSONSerialization` would reject.
- The sockopt merge keeps whatever `streamSettings` / `sockopt` the feed already carries (the
  owner's carry none — facts); a feed's own `interface` is overwritten, which is the point.
- `primaryInterface()` is a MainActor-isolated static called from `measure`; one local Mach call
  to configd, the same order of cost as writing the config file next to it.

### Compiles because

`SystemConfiguration` is a system framework module; `import` is enough and the Frameworks phase
stays empty (fact 2, fact 13). `SCDynamicStoreCopyValue` returns `CFPropertyList?`, bridged to
`[String: Any]` by the conditional cast. Every call site of the three functions is inside the file
and changed in the same edit. Built with `-warnings-as-errors` in the harness (fact 6) and with
`xcodebuild` (fact 13).

### What could go wrong

- **A wrong interface name fails silently, per row** (fact 3, `en99`): every row `--`, no error
  line. The name comes from configd, not from a guess; if the owner ever sees a full column of
  `--` with the tunnel up, `scutil` → `show State:/Network/Global/IPv4` is the first thing to look
  at.
- **IPv6 servers** go through `IPV6_BOUND_IF` in both engines (fact 4, source) — the same
  mechanism, not observed; the owner's nodes are IPv4 literals.
- **Hostname servers** resolve through `dns.servers: local` — the system resolver, which the
  tunnel's `hijack-dns` captures while it is up. Resolution then goes through the tunnel and the
  dial does not; expected to work, not observed (ping plan, same open item).

---

## Step 3 — Detect stale passwordless scripts

**Commit:** `Treat outdated passwordless scripts as not installed`

Lands before Step 4 so that the moment the script text changes, an existing install is already
recognised as stale. On its own it changes nothing for the owner: today's installed scripts equal
today's literals (facts), so `isPasswordless` stays true.

### `Sources/ProcessManager.swift`

`:139-140`:

```swift
    var isPasswordless = ProcessManager.passwordlessInstalled()
    var isPasswordlessBusy = false

    // Passwordless is on only while the installed scripts are the ones this build would install.
    // Only an explicit install writes to /usr/local/libexec, so after a script change an existing
    // install would keep running the old run.sh indefinitely; instead it reads as off, the log
    // says why, and the toggle re-installs.
    private static func passwordlessInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
            && (try? String(contentsOfFile: runScriptPath, encoding: .utf8)) == runShContent
            && (try? String(contentsOfFile: stopScriptPath, encoding: .utf8)) == stopShContent
    }
```

`passwordlessOperationFinished()` (`:244`): `isPasswordless = Self.passwordlessInstalled()`.

`init()` (`:248-249`), right after `Self.cleanupStalePidFiles()` (which Step 4 removes):

```swift
        if FileManager.default.fileExists(atPath: Self.sudoersFile), !isPasswordless {
            logs.append("[Passwordless scripts are from an older build — turn Passwordless on again in Advanced]")
        }
```

### Compiles because

`sudoersFile`, `runScriptPath`, `stopScriptPath`, `runShContent`, `stopShContent` are all
`private static let`s of the same type; a stored property's initial value may call a static
function of its own type (spelled `ProcessManager.` there, as `versionTag` is at `:14`);
`try? String(contentsOfFile:encoding:)` is `String?` and `== runShContent` compares optionals.
Built (fact 13, "s3"), no warnings; `init` is MainActor-isolated and reads the already
initialised stored property.

### What could go wrong

- **Every launch reads two small files** and compares ~2 KB. Nothing.
- **A hand-edited script** (someone tuning `run.sh` in place) now reads as "not installed" and
  is overwritten on the next toggle. That is the contract the sudoers entry was written for — the
  whitelist names exact paths whose content the app owns.
- **`isPasswordless` optimistic flip** in `installPasswordless()` (`:147`) still happens before
  the files are written; `passwordlessOperationFinished()` corrects it. Unchanged behaviour.

---

## Step 4 — Kill engines by PID file, and wait

**Commit:** `Kill engines by PID file instead of pkill`

### `Sources/ProcessManager.swift`

The PID-file comment (`:35`):

```swift
    // PID files: run.sh and stop.sh kill exactly our engines, nothing else on the machine
```

Before `runShContent`'s comment (`:39`), the shared helper:

```swift
    // Shared by run.sh, stop.sh and the osascript fallbacks. Kills only a process the PID file
    // names whose executable is the given engine, then waits for it to be gone — up to 5 s — so
    // the next sing-box never races the old one for the TUN. A stale or foreign PID is dropped.
    private static let killPidFileFunction = """
        kill_pid_file() {
            local f="$1" name="$2" pid
            [[ -f "$f" ]] || return 0
            pid=$(cat "$f" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$f"; return 0; }
            if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *"$name" ]]; then
                kill "$pid" 2>/dev/null || true
                for _ in $(seq 1 50); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.1
                done
            fi
            rm -f "$f"
        }
        """
```

`runShContent`: after the `validate_arg` block (`:51`) and its blank line, one line
`\(killPidFileFunction)` followed by a blank line; then `:62-64` become

```
        kill_pid_file \(singboxPidFile) sing-box
        kill_pid_file \(xrayPidFile) xray
```

(the two `pkill` lines and the `sleep 1` go; the blank line after them stays). Nothing else in
`run.sh` changes — the PID writes, the traps and `cleanup` are as they were.

`stopShContent` (`:115-128`) becomes

```swift
    // stop.sh: reads PID files and kills only our processes
    private static let stopShContent: String = """
        #!/bin/bash
        \(killPidFileFunction)
        kill_pid_file \(singboxPidFile) sing-box
        kill_pid_file \(xrayPidFile) xray
        """
```

`init()` (`:249`): delete `Self.cleanupStalePidFiles()`. Delete the function and its comment
(`:266-277`).

`buildNonPrivilegedShellCommand` (`:394`):

```swift
        cmds.append(Self.killPidFileFunction)
        cmds.append("kill_pid_file \(Self.shellEscape(Self.singboxPidFile)) sing-box")
        cmds.append("kill_pid_file \(Self.shellEscape(Self.xrayPidFile)) xray")
```

`killVPNProcesses`, the osascript branch (`:584-589`):

```swift
            // The helper stop.sh carries, inline: the libexec copy exists only in passwordless mode.
            let cmd = """
                \(Self.killPidFileFunction)
                kill_pid_file \(Self.shellEscape(Self.singboxPidFile)) sing-box
                kill_pid_file \(Self.shellEscape(Self.xrayPidFile)) xray
                """
```

### `Sources/AppState.swift`

`connect()` (`:91-93`): delete the comment, the `ping.cancel()` call and the blank line after it.
`isBootstrapped`'s comment (`:19-22`) loses its last clause:

```swift
    // Servers load synchronously in SubscriptionService.init, so the Servers page appears with a
    // stale set. Pinging it would measure ids that refreshAll is about to replace.
    private(set) var isBootstrapped = false
```

### `Sources/PingService.swift`

`delay(of:)`'s comment (`:131-132`):

```swift
        // No answer at all means the engine is gone — the run was cancelled — and the row goes
        // back to unmeasured rather than to a failure it did not have.
```

### Reading notes

- Interpolating one multi-line literal into another: the outer literal strips its own 8-space
  indentation from the line holding `\(killPidFileFunction)`, and the helper's lines come in with
  the indentation of *their* literal — the function lands at column 0 inside the script, as the
  rendered files show (fact 7).
- `run.sh` interpolates the PID paths raw (`\(singboxPidFile)`, as the existing `echo … >` lines
  do); the osascript commands go through `shellEscape` (as the existing `kill_pid` calls do).
  Each site keeps its convention.
- `appleScriptEscape` (`:649-654`) escapes `\` and `"`; the helper contains double quotes and no
  backslashes, the same characters the old one-liner carried.

### Compiles because

Static string literals referencing sibling `static let`s (`xrayPidFile` was already referenced
this way); one function deleted with its single call; `ping` keeps its other uses (`pingAll`, the
views, the quit path). Built (fact 13, "s4"), no warnings. The rendered scripts are the ones the
probes ran (fact 7) and pass `bash -n`.

### What could go wrong

- **A surviving engine holds the TUN** (Decisions, "What is lost"): the new sing-box fails,
  Logs shows its FATAL and `[Disconnected (exit 1)]`; fix by hand. Not observed — needs root.
- **A wedged engine** ignores `SIGTERM` for 5 s (fact 9). Corrected after the code review, which
  is what the code now does: `kill_pid_file` returns non-zero and **keeps** the PID file, and
  `run.sh` refuses with `[error] previous sing-box still running` instead of starting a second
  engine over a held TUN. As written first, it dropped the file and proceeded — throwing away the
  only handle left on the survivor now that the pkill is gone, so nothing could ever kill it
  again. `stop.sh` and the quit path still return after 5 s per engine. Still no `kill -9` —
  sing-box exits 0 on `SIGTERM` in every probe so far (ping plan, fact 8), and a forced kill
  would leave routes behind. Verified: a stand-in that ignores `SIGTERM` gives rc=1 after 5 s,
  file kept, process alive.

- **The cleanup traps removed the PID file before `wait`**, in all four of them, which silently
  defeated the lock the section above describes: the file vanished while sing-box was still
  tearing down the utun, so the next `run.sh` found nothing to wait on. Found by the code review,
  fixed by moving each `rm -f` after its `wait`.
- **PID reuse** across a crash and a reboot: the identity check compares the executable path's
  tail, so a recycled PID that happens to be *another* `sing-box` on the machine would be killed.
  Narrow, and strictly less than what the pkill did to every `sing-box` unconditionally.
- **`ps -o comm=` and `seq`** are `/bin/ps` and `/usr/bin/seq`, present on every macOS this app
  targets; `sleep 0.1` is BSD `sleep` with a fraction, probed.
- **The osascript connect path** now sends the helper through `do shell script`; probed through
  `/bin/sh -c` on this machine (fact 8), where `/bin/sh` is bash. If a user had switched
  `/var/select/sh` to zsh, `[[ =~ ]]` and `local` still parse; dash is not an option on macOS.

---

## Step 5 — Allow the ping while the tunnel is up

**Commit:** `Allow the ping while the tunnel is up`

### `Sources/AppState.swift`

`bootstrap()` (`:80-81`): delete the "Last, so a page watching this flag …" comment; the
assignment stays where it is. `pingAll()` (`:123-125`):

```swift
    func pingAll() {
        guard isBootstrapped else { return }
```

(the comment "Through the tunnel the probe would measure tunnel + proxy" goes).

### `Sources/ServersView.swift`

The header button (`:46-51`):

```swift
                    Button("Ping all") { app.pingAll() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.indigo)
                        .buttonStyle(.plain)
                        .help("Measure every server")
```

### Compiles because

Two deletions and a literal. Built (fact 13, "s5"). The ping plan's open look item — whether the
disabled button dimmed under `.foregroundStyle(.indigo)` — is moot.

### What could go wrong

- **Auto-connect at launch** now runs the ping and the tunnel start side by side. Nothing kills
  the ping any more (Step 4); its sockets are bound to `en0` before the TUN's routes land and are
  not affected by them — reasoned from `IP_BOUND_IF` scoping the route lookup, **not observed**
  (Validation).
- **The connected node measures like any other**: its outbound is pinned to `en0` and dials the
  node directly, the same path the tunnel's own `direct` rule for the server IP takes. Both grpc
  nodes measured while one of them carried the tunnel (facts 3, 6).

---

## Step 6 — Documentation and close

**Commit:** `Document ping through the tunnel and PID-file kills`

`CLAUDE.md`:

- dev-run (`:126`): "only one build can hold a tunnel at a time" → *only one build can hold a
  tunnel at a time — the second one's sing-box fails at the TUN, it does not take the tunnel over*.
- Key Decisions, passwordless (`:182`): append *The app compares the installed scripts
  byte-for-byte with what it would install; a stale install reads as off, the log says so, and
  switching the toggle on re-installs with one prompt.*
- Key Decisions, PID files (`:183`): replace with *`run.sh`, `stop.sh` and both osascript
  fallbacks kill by PID file only — one shared `kill_pid_file`, which checks that the PID's
  executable is the named engine, then waits up to 5 s for it to exit before the file is removed;
  nothing else on the machine is touched. An engine with no PID file at our path (another build's
  tag, a hand-started one) survives and the next connect fails with sing-box's own error in Logs.
  PID files are not deleted at launch: they are the handle on an engine a crash orphaned.*
- Key Decisions, the ping bullet (`:187-193`): replace the last two sentences with *Works with
  the tunnel up: every outbound that leaves the machine is bound to the primary interface
  (`bind_interface` / `streamSettings.sockopt.interface`), read from `SCDynamicStore`'s
  `State:/Network/Global/IPv4` → `PrimaryInterface`, which stays physical because sing-box's TUN
  registers no configd service. The socks hops to xray are not pinned — loopback cannot be bound
  to a NIC. Nothing in `ProcessManager` touches a ping's engines.*
- Gotchas (`:206-216`): add *`route get` answers the TUN while it is up; the physical interface is
  configd's `PrimaryInterface` (`scutil` → `show State:/Network/Global/IPv4`)* and *a wrong
  interface name in the ping fails silently — every row `--`, no error line*.

`README.md`: no change (`:12`, `:14`, `:73` stay true).

Then: move this file **and** `plans/server-ping.md` to `plans/done/` — its closing condition
("one run with the tunnel down") is replaced by this plan's Validation, which the owner completes
by re-enabling Passwordless once, opening the Servers page with the tunnel up and seeing nine
values — run `/code-review`, fix what it surfaces (canon, Workflow §3).

---

## Risks, ranked

1. **The new `run.sh` has not run as root.** Its logic — kill, identity check, wait, start — ran
   as the user with real engines on non-TUN configs (facts 7–9); the TUN swap itself, and what a
   surviving foreign TUN does to the new sing-box, need root. First thing after Step 4: re-enable
   Passwordless (one prompt), disconnect, connect, connect again while connected via a routing
   change — Logs must show the engines swapping without a FATAL.
2. **An engine without a PID file survives** and blocks the next connect (Decisions). Visible in
   Logs; manual fix; the price of the root fix, accepted.
3. **The stale-script flip surprises**: an off toggle and a password prompt after an update.
   Mitigated by the log line; one prompt fixes it. Same experience as a version bump.
4. **IPv6-only uplink**: `Global/IPv4` absent → unpinned → through the tunnel → `--` everywhere.
   A `Global/IPv6` fallback is one more line in `primaryInterface()` when there is a machine to
   test it on.
5. **A wrong `PrimaryInterface` is invisible** (fact 3, `en99`). Only a configd-level oddity can
   produce it; the symptom is a full column of `--` with the tunnel up.
6. **Not observed with the tunnel down or while the TUN comes up** — the pinned dial is the
   kernel's own default choice in the first case; reasoned, not run.

## Out of scope, deliberately left alone

- `kill -9` after the 5 s bound; `handleWake` / `reconnect` delays (5 s / 1 s could shrink now
  that `stop.sh` waits — not asked for).
- The argv spelling (`sing-box -c <file> run` / `xray -config <file>`) from the first draft —
  rejected by the owner; the PID-file kill makes it unnecessary.
- Per-row re-ping, sorting, persistence — as before.
- `route.default_interface`, `NWPathMonitor` (Decisions). An `IPv6` primary-interface fallback
  (Risks 4).

## Validation record

Checked in this run:

- Read in full: `CLAUDE.md`, `plans/server-ping.md`, all six `plans/done/*.md`,
  `Sources/PingService.swift`, `AppState.swift`, `ServersView.swift`, `ProcessManager.swift`,
  `Models.swift`, `AdvancedView.swift`, `WarpVeilApp.swift` (`applicationShouldTerminate`),
  `SubscriptionService.swift` (`:480-760`, the builders and parsers), `project.pbxproj` (`:45-62`),
  `dev-run.sh` (`:25-75`), `README.md` (`rg`), `Info.plist` (version). Every line reference above
  re-checked with `rg -n` / `sed -n` before writing.
- The owner's install, read only: `/usr/local/libexec/warpveil-1-2/{run.sh,stop.sh}` diffed
  against the literals rendered from the source (identical), `/etc/sudoers.d/` listing,
  `/tmp/warpveil-1-2-singbox.pid`, `/var/select/sh`.
- Upstream, at the bundled tags: sing-box `v1.14.0` `common/dialer/default.go`, `docs/…/dial.md`,
  `docs/…/route/index.md`, `go.mod`; sing `v0.9.0-beta.4` `common/control/bind.go`,
  `bind_darwin.go`, `common/network/addr.go`; Xray `v26.3.27` `app/proxyman/inbound/inbound.go`,
  `core/xray.go`, `transport/internet/sockopt_darwin.go`.
- Probes (facts 1–11): `scutil`, `netstat -rn`, `route get`; a `swiftc` throwaway for
  `SystemConfiguration`; a Python raw-socket `IP_BOUND_IF` test; a Python rebuild of the two ping
  configs in five pin modes with both engines and nine parallel delay tests; six xray launches
  polling every inbound; the harness — Steps 1–2 `PingService.swift` verbatim, `Models.swift`,
  two stubs — twice; the new `run.sh` / `stop.sh` / helper as the user against real engines on
  non-TUN configs and against fake, stale, foreign, garbage and `SIGTERM`-ignoring PID files,
  under `bash -euo pipefail` and `/bin/sh -c`; the literal round-trip in `swiftc`.
- Builds (fact 13): five `xcodebuild` runs on a scratch copy, one per state.
- Canon: no AppKit outside the window file; no package; no protocol, generic or wrapper; one new
  `private static func` in each of `PingService` and `ProcessManager`, one new `private static
  let`; `@Observable` / `@MainActor` untouched; fewer lines in `AppState`, one function deleted in
  `ProcessManager`. Additions beyond the owner's ask, all flagged: the wait-for-all fix (Step 1),
  the identity check and the wait in the helper (Step 4), the removal of `cleanupStalePidFiles`
  (Step 4), the stale-script detection (Step 3).

Not verified:

- **Anything that needs root**: the new `run.sh` and `stop.sh` under `sudo`; a sing-box TUN
  handed over between two `run.sh` runs; what sing-box prints when a foreign TUN already holds
  the routes; the osascript path end to end (`do shell script … with administrator privileges`
  was not invoked).
- A ping with the tunnel **down** through the pinned config; a ping overlapping the TUN coming
  up (Step 5, "What could go wrong").
- IPv6 or hostname-addressed servers (Step 2, "What could go wrong").
- macOS 14/15 — probes and builds ran on macOS 26.
- The look of the Advanced toggle and Logs after the stale-script flip — reasoned from
  `AdvancedView.swift:16-23` and the log line, not run.
