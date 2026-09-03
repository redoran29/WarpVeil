# Server ping: the real delay through each proxy

Status: plan, not yet implemented. Written against `6da3f4d` (clean tree).

Greenfield: the TCP-handshake ping was removed in `58cd4b6` ("With the tunnel up, sing-box's TUN
stack accepts the TCP connection locally … the list showed 0ms across the board"). Nothing of it
survives in `Sources/`, and nothing below reuses it.

Out of scope and untouched: `ProcessManager` (every line of it — the privileged path, `run.sh`,
`stop.sh`, PID files, sleep/wake), routing/bypass, the window shell, subscription formats,
`Models.swift`.

## Owner decisions this plan takes as fixed

1. **Real proxy delay, not a TCP handshake.** The number is a round trip *through* the proxy to
   a test URL, so a CDN-fronted node with a dead backend reads as a timeout.
2. **No sudo, no TUN.** Engines run in user space; the privileged path is not touched or reused.
3. **UX:** a "Ping all" button in the SERVERS header, one automatic run when the Servers page
   appears; per row a spinner while measuring, the value in ms right-aligned, colour-graded
   green / yellow / red, `--` for timeout or failure. Results in memory only, keyed by
   `Server.id`, never persisted.

## What the code does today (facts the plan relies on)

- `Sources/Models.swift` — `Server` (`:8-27`): `id` is an opaque UUID string minted once and
  carried across refreshes by `SubscriptionService.keepingIDs` (`:177-196`); `config` is a complete
  standalone engine config as a JSON string; `engine: Engine?`. `Subscription.engine` (`:52`) is the
  fallback engine. Names are not identity (`isSameNode`, `:23-26`).
- `Sources/SubscriptionService.swift` — every site that builds a `Server.config` puts the proxy
  outbound **first**: `buildSingBoxConfigFromOutbound` (`:492-527`, `outbounds: [outbound, direct]`),
  `buildXrayConfig` (`:531-636`, `outbounds: [outbound, freedom]`), `parseSingBox` (`:672`,
  `[ob] + serviceOutbounds`), `parseXray` (`:727`, same). The exception is the `custom` fallback in
  `addManualConfig` (`:754`), which stores the pasted JSON as is. `vpnTypesSingBox` (`:640-643`) and
  `vpnTypesXray` (`:683-685`) are the sets those parsers accept; both are `private static`.
  `parseVlessURI` (`:339-350`) sends `xhttp`/`splithttp` to xray and everything else to sing-box.
- `Sources/AppState.swift` — services are `let` properties created inline (`:10-14`).
  `connect()` (`:75-92`) resolves `server.engine ?? sub.engine` (`:81`) and calls `pm.connect`
  (`:82`). `routingChanged()` (`:110`). `bootstrap()` (`:64-72`) refreshes feeds, then auto-connects.
- `Sources/ProcessManager.swift` — `findBinary` (`:639-643`) is `nonisolated static`, bundle only.
  `run.sh` (`:41-112`, the pkill at `:62-63`) and the osascript fallback (`:394`) both open with
  `pkill -f 'sing-box run'; pkill -f 'xray run'`. `stop.sh` (`:115-128`) and the osascript stop
  (`killVPNProcesses`, `:572-600`) kill by PID file only. `handleWake` (`:279-297`) and `reconnect`
  (`:527-545`) go through `connect` again after 5 s / 1 s with `isRunning` false in between.
  Config files are `$TMPDIR/warpveil-{singbox,xray}-<pid>.json`, written 0600 (`:318-337`).
- `Sources/ServersView.swift` — body (`:9-27`): `ScrollView { serverListSection }` with `.sheet`
  (`:14`) and `.confirmationDialog`. Header `HStack` (`:33-45`): `SERVERS`, `Spacer()` (`:38`),
  `+ Add` (`:39-42`). Rows: `ServerRowView(server:isSelected:)` (`:68`). `ServerRowView`
  (`:128-224`): `HStack { flag; VStack { name; protocolLabel }; Spacer() }` (`:132-148`),
  `protocolLabel` (`:157`). Subscription refresh shows `ProgressView().controlSize(.small)`
  in place of its button while running (`:96-107`) — the idiom the header reuses.
- `Sources/WarpVeilApp.swift` — `applicationShouldTerminate` (`:88-96`) returns `.terminateNow`
  when not connected; every quit goes through it (`CLAUDE.md`, Quit path).
- `WarpVeil.xcodeproj/project.pbxproj` — hand-maintained; a new source file needs four entries:
  `PBXBuildFile` (`:24` is `ConnectionView`'s), `PBXFileReference` (`:46`), the `Sources` group
  child (`:89`) and the `PBXSourcesBuildPhase` entry (`:208`). Ids `AA…1C` / `BB…1C` are unused.
- The real file (`~/.config/warpveil/subscriptions.json`, read, not modified): 1 subscription,
  9 servers — 7 `vless` over `xhttp` (`engine: xray`), 2 `vless` over `grpc` (sing-box). All
  addresses are IP literals. **xray servers are the majority; "not measurable" for them would
  leave seven of nine rows blank.**
- Toolchain: Xcode 26.5, Swift 6.3.2 compiler, project in Swift 5 mode, target macOS 14.0.
  Binaries: sing-box 1.14.0 (`with_clash_api` in its tags), Xray 26.3.27.

## Verified facts (probes against the bundled binaries, not project code)

Every probe ran the binaries from `Binaries/` on scratch configs in the scratchpad. The owner's
tunnel was **up for the whole run** (root `sing-box run`, Chicago 3), which is stated per fact
where it matters; it was not touched.

1. **A sing-box config with no inbounds runs.** `check` and `run` accept
   `{log, dns, outbounds, route, experimental.clash_api}` with no `inbounds`, no `route.final`
   and no `direct` outbound (probed with a single VLESS outbound: process alive, API answering,
   delay test running). `route.default_domain_resolver` accepts the plain string `"local"` with
   `dns.servers: [{"type": "local", "tag": "local"}]`.
2. **Clash API, 1.14.0, from `experimental/clashapi/proxies.go` at tag `v1.14.0` and the binary:**
   `external_controller: "127.0.0.1:<port>"`, `secret` → `Authorization: Bearer <secret>`; without
   it every route is `401 {"message":"Unauthorized"}`. `GET /` → `200 {"hello":"clash"}` — the
   readiness probe; it answered 48 ms after launch with 5 outbounds, ~50 ms with 9.
   `GET /proxies/<tag>/delay?url=…&timeout=<ms>`:
   - `timeout` is **required** (`strconv.ParseInt(…, 10, 16)`; missing → `400 {"message":"Body invalid"}`), so ≤ 32767 ms.
   - `url` starting with `http://` is **discarded** (`if strings.HasPrefix(url, "http://") { url = "" }`) and the default `https://www.gstatic.com/generate_204` is used. The test URL must be HTTPS.
   - success → `200 {"delay": <uint16 ms>}`; context timeout → `504 {"message":"Timeout"}` exactly at the timeout (5.002 s observed); any other error or `delay == 0` → `503 {"message":"An error occurred in the delay test"}` (a socks outbound whose port nobody listens on: 503 in 14 ms); unknown tag → `404 {"message":"Resource not found"}`.
   - `/proxies` lists every outbound except `direct`/`block`/`dns` types plus a synthetic `GLOBAL`; delay works on any listed tag. Tags are looked up verbatim — `Server.id` (UUID string) is URL-safe.
3. **What the number is** (`common/urltest/urltest.go`): `start = time.Now()`, `DialContext` through the outbound, then — for outbounds whose proxy handshake is lazy (`NeedHandshakeForWrite`) — `start` is reset just before the request is written, so the handshake lands inside the timed part; one `HEAD` to the URL over that connection (TLS included, `CheckRedirect` disabled); `time.Since(start)` in ms. It is one full HTTPS request through the proxy. Observed on the owner's nodes with outbounds bound to `en0` (see fact 6): 324–761 ms per server, all nine in parallel in under a second; `https://cp.cloudflare.com/generate_204` ≈ 350 ms vs the gstatic default ≈ 715 ms from the same node.
4. **xhttp/splithttp are not in sing-box 1.14**: `check` fails with `outbounds[0].transport: unknown transport type: splithttp` (and `xhttp`). The canon's "xray for xhttp" holds; the `case "xhttp", "splithttp"` branch in `buildSingBoxConfig` (`:435-444`) is unreachable from `parseVlessURI` and is not this plan's business.
5. **The xray chain works.** xray config: one `socks` inbound per server on `127.0.0.1:<port>` tagged `in-<id>`, the server's outbound tagged `<id>`, a `routing.rules` entry `{"type":"field","inboundTag":["in-<id>"],"outboundTag":"<id>"}` each; `xray run -test` says `Configuration OK`. sing-box side: `{"type":"socks","tag":"<id>","server":"127.0.0.1","server_port":<port>}`. The delay test through the chain returned 200 with the values in fact 3 for all seven xhttp servers; a chain to a dead node (`203.0.113.1`) → 504 at the timeout.
6. **The tunnel swallows a user-space engine's traffic.** With the tunnel up, macOS shows the TUN's half routes (`1/8, 2/7, … 64/2 → utun4`) while `default` stays on `en0`. A user-space sing-box with `route.auto_detect_interface: true` reported the tunnel's public IP; so did one with `auto_detect_interface: false`, and so did a `direct` outbound with `bind_interface: "en0"`. Through the tunnel the sing-box node's delay was 385–744 ms on some runs and a 5 s timeout on others; the xhttp servers failed every time with `REALITY: received real certificate (potential MITM or redirection)` on the xray side. Binding xray's outbounds with `streamSettings.sockopt.interface = "en0"` made the same servers answer in ~350 ms — the only thing that changed the path, and only for xray. **Nothing here measures the proxy while the tunnel is up.**
7. **Readiness and output.** xray at `loglevel: "warning"` prints `[Warning] core: Xray 26.3.27 started` once its inbounds listen (35 ms after `Process.run()` in Swift); at `"none"` it prints nothing; `"access": "none"` silences the per-connection `accepted …` lines that otherwise go to stdout. sing-box at `log.level: "warn"` printed **nothing** in any run, dead servers and timeouts included — readiness has to be the API answering. Startup failures are `FATAL …` on stderr regardless of level, wrapped in ANSI colour codes that `NO_COLOR=1`, `TERM=dumb` and `log.output` do not remove; `log.disable_color` is not a field in 1.14 (`unknown field`). Examples seen: `duplicate outbound/endpoint tag: <tag>`, `outbounds[1].bogus_field: json: unknown field "bogus_field"`, `start service: dependency[missing-outbound] not found for outbound[B]` (a `detour` or a `selector` member that is not in the config — `check` passes, `run` exits 1), `external controller listen error: … bind: address already in use`. An outbound `domain_resolver` naming a DNS tag that does not exist is **not** fatal (process alive), and the deprecated `domain_strategy` is accepted.
8. **Termination.** `SIGTERM` → sing-box exits 0, xray exits 15; both leave nothing behind. `Process.terminate()` on a process that has already exited is a no-op (probed).
9. **Concurrency.** Nine different tags fired at once all returned 200. Eight requests at **one** tag at once: two answered, six timed out (5 s) — the chain serialises per outbound. One request per tag, never two.
10. **Swift side (throwaway `swiftc` probes and a harness, Swift 5 mode, macOS 14 target, `-warnings-as-errors`):** `bind()` to `127.0.0.1:0` on a batch of sockets held open until all are read back gives distinct ports; `FileHandle.bytes.lines` on a `Pipe` yields lines until the process exits, then ends (the error path for a bad config: `Failed to start: main: failed to load config files …`); `URLSession` against a closed port throws `URLError.cannotConnectToHost`. The harness (fact 12) exercised the full service.
11. **The two commits build.** A scratch copy of the repository with Step 1 applied, then Step 2 applied, built with `xcodebuild` (Debug, arm64): `BUILD SUCCEEDED`, no Swift warnings either time.
12. **The service runs end to end.** `PingService.swift` exactly as in Step 1, compiled with `Models.swift` and two stubs (`ProcessManager.findBinary`, the two type sets) against the owner's real `subscriptions.json`: `start` → both engines and both config files exist at 0.4 s → `cancel()` → `isRunning` false, no `.measuring` left, no engines, no files, no error; a full run through the live tunnel ends at 5.08 s with every row `failed` (fact 6); `start(); start()` back to back runs two engines once, not four, and finishes clean. A copy of the same file with `bind_interface`/`sockopt.interface = "en0"` injected into `proxyOutbound` (harness only, not the plan) finished all nine in 892 ms with `.delay(653…756)`.

Not probed: the app itself running a ping with the tunnel **down** — the owner's tunnel was up and
is not something a planning run may drop. Facts 3, 5 and 12 stand on outbounds pinned to `en0`,
which the shipped code does not do; the first thing to do when implementing is one run
disconnected (see Validation).

---

## Decisions

### One measurement path: sing-box's Clash API, with xray chained in as socks outbounds

A single user-space `sing-box run` holds every server as an outbound, tag = `Server.id`, behind
`experimental.clash_api` on `127.0.0.1:<free port>` with a per-launch random `secret`. One
`GET /proxies/<id>/delay` per server (fact 2) is the whole measurement; sing-box does the timing
(fact 3). xray servers get one user-space `xray run` with a socks inbound each and are reached
through `socks` outbounds in that same sing-box config (fact 5) — the shape the tunnel already uses
for them (`CLAUDE.md`, Two connection topologies), so the Swift side has exactly one client: plain
HTTP to localhost. Two processes at most, regardless of server count.

Rejected — **URLSession over SOCKS per server** (`ProxyConfiguration(socksv5Proxy:)`, macOS 14):
a second timing implementation next to sing-box's, N listening ports instead of 1 + xray count,
and the number would be Swift's, not the one Happ/Clash users know. Rejected — **one process per
server**: fifty 80 MB binaries. Rejected — **`/group/<selector>/delay`** (one request, all
members): results land all at once when the slowest times out; per-row progress is the UX.

### Test URL: `https://cp.cloudflare.com/generate_204`, timeout 5000 ms

HTTPS because the API drops `http://` (fact 2). Cloudflare anycast rather than the gstatic default:
half the number from the same node (fact 3), and passing it explicitly means a change of default
upstream cannot move every value silently. 5 s is Clash's convention and bounds a dead row.

### Colour bands: green < 300 ms, yellow < 800 ms, red above

The number is a full HTTPS request through a proxy (fact 3), 320–760 ms on the owner's US nodes
from here, so the TCP-handshake bands of the old code (60/150) would paint everything red. Two
constants in `ServerRowView`; taste, owner may move them.

### Ping is unavailable while the tunnel is up

`AppState.pingAll()` refuses while `pm.isRunning`; the header button is disabled with the tooltip
"Disconnect to measure". Fact 6: a user-space engine's traffic goes through the TUN, so the number
would be tunnel + proxy — for the connected node a loop back through itself, for the others a
detour — and the xhttp rows would read `--` for a reason that has nothing to do with the node.
That is the failure mode `58cd4b6` removed the last ping for; a disabled button is the honest
version. Priced alternative, **unverified**: pin the engines' outbounds to the physical interface
(`sockopt.interface` did change xray's path, fact 6; `bind_interface` did not change sing-box's).
It needs the physical default interface found from Swift while `utun` holds the half routes and a
verified answer for sing-box; if the owner wants it, that is its own plan.

### The pkill in `run.sh`, both directions

`run.sh` and the osascript fallback open with `pkill -f 'sing-box run'; pkill -f 'xray run'`
(facts). A ping's engines are `sing-box run` / `xray run` too, so:

- **Connect during a ping:** `AppState.connect()` calls `ping.cancel()` before `pm.connect` —
  the engines are gone before `run.sh` looks for them, rows in flight go back to unmeasured,
  finished values stay. The app does not lean on the pkill as a side effect.
- **Ping during a tunnel:** cannot start (`pingAll` guard). The tunnel's stop path kills by PID
  file only, never a ping.
- **The gap:** `handleWake` / `reconnect` set `isRunning = false` for 5 s / 1 s and then
  `connect` again inside `ProcessManager`, which this plan does not touch. A ping started in that
  window is pkilled by `run.sh`. Its requests then fail at the transport level, and that case is
  mapped to "unmeasured", not `--`: the API answering 5xx is a proxy failure, the API not answering
  at all is the engine being gone. No wrong number is shown.

### Readiness, errors and what the user sees

xray is ready at its `started` line; sing-box is ready when `GET /` answers (fact 7), polled every
30 ms for up to 3 s. If either exits first, the last line of its output (ANSI stripped by a
regex — nothing else removes it, fact 7) becomes `PingService.error`, shown in red under the
SERVERS header. That is where a duplicate tag, an unknown field, a missing `detour`, or a port
collision surfaces (fact 7 has the exact strings). One bad outbound does take the whole run down —
sing-box rejects the config as a unit — which is why servers whose first outbound is not a proxy
type (the `custom` fallback) are left out of the config instead of being merged: the API then
returns 404 for them and the row shows `--`.

### Teardown is synchronous, runs never overlap

`cancel()` terminates the engines and deletes the config files on the spot, then cancels the
task. It is called from four places: the page disappearing (`onDisappear`), `connect()`, a new
`start()`, and `applicationShouldTerminate` — the quit path returns `.terminateNow` without
waiting when the tunnel is down, so an asynchronous cancel would orphan two processes. A new
`start()` awaits the previous task before touching anything, so `engines`, the config files and
the `.measuring` marks always belong to one run. Not covered: the app dying by SIGKILL or crash
leaves the two user-space engines running until the next ping or reboot — same class as the
tunnel's orphan case that `dev-run.sh` sweeps; noted, not mitigated.

### Concurrency: 10 in flight, bounded by `ceil(N / 10) × 5 s`

A `TaskGroup` window of 10 plus `httpMaximumConnectionsPerHost = 10` on a private session (the
default is 6 on macOS and would queue requests below the window with an unclear timeout clock).
Each request is bounded server-side by `timeout=5000` and client-side by
`timeoutIntervalForRequest = 10`. Fifty servers: at most 25 s, typically a few seconds, spinners
the whole time, the UI never blocked. One request per tag (fact 9).

### Ports and files

`freePorts(1 + xrayCount)`: bind `127.0.0.1:0` per port, read them all back, then close them
all (fact 10). The window between close and the engine's bind is accepted; a collision surfaces
as the `address already in use` error line. Config files:
`$TMPDIR/warpveil-ping-singbox-<pid>.json`, `$TMPDIR/warpveil-ping-xray-<pid>.json`, 0600
(they carry credentials), deleted on every teardown — the `warpveil-*-<pid>` convention of the
Runtime Files section.

### Automatic run on appear, keyed by `Server.id`

`.onAppear { app.pingAll() }` on the Servers page: fires at launch (before `refreshAll` lands —
ids survive the refresh via `keepingIDs`, so results stay attached) and on every return to the
page. Servers that first appear after a refresh have no value until "Ping all" or the next visit.
`results: [String: PingResult]` on the service, cleared of `.measuring` on every run end; never
written to disk.

---

## Step 1 — `PingService` and its wiring

**Commit:** `Add PingService: proxy delay through user-space engines`

### `Sources/PingService.swift` — new file

```swift
import Foundation
import Darwin

enum PingResult: Equatable {
    case measuring
    case delay(Int)
    case failed
}

// The real round trip through each proxy, not a TCP handshake: a CDN front completes a
// handshake instantly while the node behind it is dead. A user-space sing-box carries every
// server as an outbound behind its Clash API, whose delay test sends one HEAD request through
// that outbound. xray servers sit behind a user-space xray with a SOCKS inbound each and are
// chained in as socks outbounds — the shape the tunnel already uses for them. No sudo, no TUN.
@Observable
@MainActor
final class PingService {
    var results: [String: PingResult] = [:]
    var error: String?
    private(set) var isRunning = false

    private var task: Task<Void, Never>?
    private var engines: [Process] = []
    private let secret = UUID().uuidString

    // Plain http:// is ignored by the API and replaced with its own default.
    private static let testURL = "https://cp.cloudflare.com/generate_204"
    private static let timeoutMilliseconds = 5000
    private static let concurrency = 10

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = PingService.concurrency
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private let singBoxConfigFile = FileManager.default.temporaryDirectory.path
        + "/warpveil-ping-singbox-\(ProcessInfo.processInfo.processIdentifier).json"
    private let xrayConfigFile = FileManager.default.temporaryDirectory.path
        + "/warpveil-ping-xray-\(ProcessInfo.processInfo.processIdentifier).json"

    func start(_ servers: [(server: Server, engine: Engine)]) {
        guard !servers.isEmpty else { return }
        let previous = task
        previous?.cancel()
        task = Task {
            // Runs never overlap: the engines and the config files are shared.
            await previous?.value
            isRunning = true
            error = nil
            for entry in servers { results[entry.server.id] = .measuring }
            await measure(servers)
            results = results.filter { $0.value != .measuring }
            isRunning = false
        }
    }

    // Synchronous on purpose: the quit path calls it and exits without waiting.
    func cancel() {
        task?.cancel()
        stopEngines()
    }

    // MARK: - Run

    private func measure(_ servers: [(server: Server, engine: Engine)]) async {
        defer { stopEngines() }
        do {
            let xrayServers = servers.filter { $0.engine == .xray }.map(\.server)
            let ports = Self.freePorts(1 + xrayServers.count)
            guard let apiPort = ports.first, ports.count == 1 + xrayServers.count else {
                throw PingError("no free local port")
            }
            let xrayPorts = Dictionary(zip(xrayServers.map(\.id), ports.dropFirst()), uniquingKeysWith: { first, _ in first })
            if !xrayServers.isEmpty {
                try await launchXray(xrayServers, ports: xrayPorts)
            }
            try await launchSingBox(servers, xrayPorts: xrayPorts, apiPort: apiPort)
            await measureAll(servers.map(\.server.id), apiPort: apiPort)
        } catch {
            // A cancel kills the engines, and the launch that was waiting on them reports it.
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func measureAll(_ tags: [String], apiPort: UInt16) async {
        var pending = tags[...]
        await withTaskGroup(of: (String, PingResult?).self) { group in
            func addNext() {
                guard !Task.isCancelled, let tag = pending.popFirst() else { return }
                group.addTask { (tag, await self.delay(of: tag, apiPort: apiPort)) }
            }
            for _ in 0..<Self.concurrency { addNext() }
            for await (tag, result) in group {
                results[tag] = result
                addNext()
            }
        }
    }

    private func delay(of tag: String, apiPort: UInt16) async -> PingResult? {
        let query = [
            URLQueryItem(name: "url", value: Self.testURL),
            URLQueryItem(name: "timeout", value: String(Self.timeoutMilliseconds))
        ]
        // No answer at all means the engine is gone — a cancel, or run.sh's pkill on connect —
        // and the row goes back to unmeasured rather than to a failure it did not have.
        guard let (data, status) = await api("/proxies/\(tag)/delay", query: query, apiPort: apiPort) else {
            return nil
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let milliseconds = json["delay"] as? Int
        else { return .failed }
        return .delay(milliseconds)
    }

    private func api(_ path: String, query: [URLQueryItem] = [], apiPort: UInt16) async -> (Data, Int)? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(apiPort)
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return nil }
        return (data, status)
    }

    // MARK: - Engines

    private func launch(_ path: String, _ arguments: [String]) throws -> (Process, Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        engines.append(process)
        return (process, output)
    }

    // xray announces its inbounds with a "started" line; an exit before it leaves the reason
    // as the last line.
    private func launchXray(_ servers: [Server], ports: [String: UInt16]) async throws {
        guard let xray = ProcessManager.findBinary("xray") else { throw PingError("xray is not bundled") }
        write(Self.xrayConfig(servers, ports: ports), to: xrayConfigFile)
        let (_, output) = try launch(xray, ["run", "-config", xrayConfigFile])
        var lastLine = ""
        for try await line in output.fileHandleForReading.bytes.lines {
            if line.contains("started") { return }
            lastLine = line
        }
        throw PingError("xray: \(lastLine)")
    }

    // sing-box prints nothing at the warn level, so readiness is the API answering; an exit
    // before that leaves the reason on the pipe.
    private func launchSingBox(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16
    ) async throws {
        guard let singBox = ProcessManager.findBinary("sing-box") else { throw PingError("sing-box is not bundled") }
        write(singBoxConfig(servers, xrayPorts: xrayPorts, apiPort: apiPort), to: singBoxConfigFile)
        let (process, output) = try launch(singBox, ["run", "-c", singBoxConfigFile])
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(30))
            if !process.isRunning {
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw PingError("sing-box: \(Self.lastLine(of: text))")
            }
            if await api("/", apiPort: apiPort) != nil { return }
        }
        throw PingError("sing-box did not start")
    }

    private func stopEngines() {
        engines.forEach { $0.terminate() }
        engines = []
        try? FileManager.default.removeItem(atPath: singBoxConfigFile)
        try? FileManager.default.removeItem(atPath: xrayConfigFile)
    }

    // MARK: - Configs

    private func singBoxConfig(
        _ servers: [(server: Server, engine: Engine)], xrayPorts: [String: UInt16], apiPort: UInt16
    ) -> String {
        let outbounds: [[String: Any]] = servers.compactMap { entry in
            switch entry.engine {
            case .singBox:
                return Self.proxyOutbound(of: entry.server, types: SubscriptionService.vpnTypesSingBox, typeKey: "type")
            case .xray:
                guard let port = xrayPorts[entry.server.id] else { return nil }
                return ["type": "socks", "tag": entry.server.id, "server": "127.0.0.1", "server_port": Int(port)]
            }
        }
        let config: [String: Any] = [
            "log": ["level": "warn"],
            "dns": ["servers": [["type": "local", "tag": "local"]]],
            "outbounds": outbounds,
            "route": ["default_domain_resolver": "local"],
            "experimental": ["clash_api": ["external_controller": "127.0.0.1:\(apiPort)", "secret": secret]]
        ]
        return Self.serialize(config)
    }

    private static func xrayConfig(_ servers: [Server], ports: [String: UInt16]) -> String {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for server in servers {
            guard let port = ports[server.id],
                  let outbound = proxyOutbound(of: server, types: SubscriptionService.vpnTypesXray, typeKey: "protocol")
            else { continue }
            let inboundTag = "in-\(server.id)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": Int(port), "protocol": "socks"])
            outbounds.append(outbound)
            rules.append(["type": "field", "inboundTag": [inboundTag], "outboundTag": server.id])
        }
        let config: [String: Any] = [
            "log": ["loglevel": "warning", "access": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["rules": rules]
        ]
        return serialize(config)
    }

    // Every builder and parser puts the proxy first. Anything else — a pasted config whose first
    // outbound is a selector — would take the whole merged config down, so it is left out.
    private static func proxyOutbound(of server: Server, types: Set<String>, typeKey: String) -> [String: Any]? {
        guard let data = server.config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var outbound = (root["outbounds"] as? [[String: Any]])?.first,
              let type = outbound[typeKey] as? String, types.contains(type)
        else { return nil }
        outbound["tag"] = server.id
        return outbound
    }

    // MARK: - Helpers

    private static func serialize(_ config: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // 0600: the configs carry the servers' credentials.
    private func write(_ config: String, to path: String) {
        FileManager.default.createFile(atPath: path, contents: config.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func lastLine(of text: String) -> String {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return plain.split(separator: "\n").last.map(String.init) ?? "exited"
    }

    // Binds port 0 once per port and keeps every socket open until all are read back, so no
    // two calls hand out the same number.
    private static func freePorts(_ count: Int) -> [UInt16] {
        var sockets: [Int32] = []
        var ports: [UInt16] = []
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, length) == 0 && getsockname(fd, sockaddrPointer, &length) == 0
                }
            }
            guard bound else { close(fd); break }
            sockets.append(fd)
            ports.append(UInt16(bigEndian: address.sin_port))
        }
        sockets.forEach { close($0) }
        return ports
    }
}

private struct PingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
```

Reading notes, so nobody "fixes" them:

- `isRunning` and the `.measuring` marks are set inside the task, one tick after `start()`,
  because the previous run's completion clears both; serialising through `await previous?.value`
  keeps every run's state its own. Invisible in the UI.
- `delay(of:)` maps *no HTTP answer* to `nil` (row unmeasured) and *any HTTP answer but 200* to
  `.failed` (row `--`). The distinction is the pkill case above.
- `engines.append` sits right after `process.run()` with nothing between them that yields, so
  `cancel()` can never miss a process that has been launched.
- `catch` after a cancel: `Task.sleep` throws `CancellationError`, the pipe hits EOF (engines
  terminated) and `launchXray` throws its last line, `session.data` throws — all land in the same
  `catch`, and `Task.isCancelled` keeps them off `error`.
- `results[tag] = result` with `result == nil` **removes** the key. Intended.
- `SubscriptionService.vpnTypesSingBox` / `vpnTypesXray` are the parsers' own sets; the two
  `private` keywords go in this commit (below), nothing else in that file changes.

### `Sources/SubscriptionService.swift`

`:640` and `:683`: `private static let vpnTypesSingBox` → `static let vpnTypesSingBox`, same for
`vpnTypesXray`.

### `Sources/AppState.swift`

- `:14`, after `let subs = SubscriptionService()`: `let ping = PingService()`.
- `connect()` (`:75-92`), between the `guard` and `let engine`:

  ```swift
  // run.sh opens with pkill -f 'sing-box run', which would take a ping's engines with it.
  ping.cancel()
  ```

- Before `routingChanged()` (`:110`):

  ```swift
  // Through the tunnel the probe would measure tunnel + proxy, not the proxy.
  func pingAll() {
      guard !pm.isRunning else { return }
      ping.start(subs.subscriptions.flatMap { sub in
          sub.servers.map { (server: $0, engine: $0.engine ?? sub.engine) }
      })
  }
  ```

  The engine resolution is the one `connect()` uses at `:81`.

### `WarpVeil.xcodeproj/project.pbxproj`

Four lines, each after `ConnectionView.swift`'s in the same section (`:24`, `:46`, `:89`, `:208`):

```
AA000000000000000000001C /* PingService.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB000000000000000000001C /* PingService.swift */; };
BB000000000000000000001C /* PingService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PingService.swift; sourceTree = "<group>"; };
				BB000000000000000000001C /* PingService.swift */,
				AA000000000000000000001C /* PingService.swift in Sources */,
```

### Compiles because

A new file plus additions; `ping` and `pingAll` have no caller yet, which Swift does not mind.
`ProcessManager.findBinary` is `nonisolated static` and callable from the main actor. The two type
sets become internal in the same commit. Built with `xcodebuild` in a scratch copy (fact 11).

### What could go wrong

- **A feed's outbound sing-box 1.14 rejects** (unknown field, a `detour` to a tag that is not in
  the config): the whole run fails with that line under the header (fact 7). The same outbound
  would fail the tunnel too, with the same message in the Logs page. If it ever bites, the fix is
  to strip the offending key in `proxyOutbound` — one line, not planned until it is seen.
- **Same node in two subscriptions** has two ids and two rows; both are measured. Cheap and
  honest. Two *equal* ids (a hand-edited file) → `duplicate outbound/endpoint tag` under the header.
- **Hostname servers.** `dns.servers: local` + `default_domain_resolver` is what the config has;
  a hostname server ran, but its resolution was only seen through the tunnel and timed out there
  (fact 7). The owner's nodes are IP literals. First hostname feed the owner adds: check it.
- **The 3 s sing-box readiness cap.** 50 ms observed with 9 outbounds; a 50-outbound config is
  more parsing, not more network. If "sing-box did not start" ever shows, raise the loop count.
- **Orphans on a crash** — stated under Decisions.

---

## Step 2 — Ping in the server list

**Commit:** `Show proxy delay in the server list`

### `Sources/ServersView.swift`

Body (`:10-13`): after the `ScrollView { … }`, before `.sheet`:

```swift
.onAppear { app.pingAll() }
.onDisappear { app.ping.cancel() }
```

Header `HStack` (`:33-45`) becomes `HStack(spacing: 12)` and gains, between `Spacer()` (`:38`) and
`+ Add` (`:39`):

```swift
if app.ping.isRunning {
    ProgressView().controlSize(.small)
} else {
    Button("Ping all") { app.pingAll() }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.indigo)
        .buttonStyle(.plain)
        .disabled(app.pm.isRunning)
        .help(app.pm.isRunning ? "Disconnect to measure" : "Measure every server")
}
```

After the header's `.padding(.bottom, 8)` (`:45`), the error line:

```swift
if let error = app.ping.error {
    Text(error)
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
}
```

The row call (`:68`):

```swift
ServerRowView(
    server: server,
    isSelected: app.selectedServerID == server.id,
    ping: app.ping.results[server.id]
)
```

`ServerRowView` (`:128`): `let ping: PingResult?` after `isSelected` (`:130`); `pingLabel` after
`Spacer()` (`:147`); above `protocolLabel` (`:157`):

```swift
@ViewBuilder
private var pingLabel: some View {
    switch ping {
    case .measuring:
        ProgressView().controlSize(.small)
    case .delay(let milliseconds):
        Text("\(milliseconds) ms")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Self.color(forDelay: milliseconds))
    case .failed:
        Text("--")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    case nil:
        EmptyView()
    }
}

// A full HEAD request through the proxy, so the bands sit well above TCP-handshake numbers.
private static func color(forDelay milliseconds: Int) -> Color {
    if milliseconds < 300 { return .green }
    if milliseconds < 800 { return .yellow }
    return .red
}
```

### `Sources/WarpVeilApp.swift`

`applicationShouldTerminate` (`:88`): `app.ping.cancel()` as its first line, before the
`guard app.pm.isRunning`. Synchronous; the `.terminateNow` path needs nothing else.

### Compiles because

`ServerRowView` is `private` with one call site, changed in the same edit; `app.ping` and
`app.pingAll()` exist since Step 1; `PingResult` is internal; the `switch` over an optional enum
with a `nil` case, `.onAppear`/`.onDisappear` on a `ScrollView`, `.help` on a disabled button
and `.monospacedDigit()` typecheck at the macOS 14 target. Built with `xcodebuild` (fact 11).

### What could go wrong

- **The disabled "Ping all" may not dim**: `.foregroundStyle(.indigo)` is applied explicitly and a
  plain button's disabled look is not guaranteed under it. If it reads as enabled while
  connected, add `.opacity(app.pm.isRunning ? 0.4 : 1)`. Look, not logic.
- **Yellow on a light background** is faint; `.orange` is the one-word alternative. The owner
  named yellow, so yellow is what is written.
- **Row width at the 300-pt column minimum**: name + `ms` label + spinner; the name already has
  `lineLimit(1)`. Check visually.
- **The relative "updated N ago" text** already re-renders on every state change; each arriving
  result is one more. Harmless at tens of rows (the `VStack` is not lazy — existing shape).
- **Auto-connect at launch** cancels the launch ping half-way (`connect()` → `cancel()`): the
  rows that finished keep their values, the rest clear. Correct, and visible for a second.

---

## Step 3 — Documentation

**Commit:** `Document server ping`

`CLAUDE.md`:

- Architecture tree (`:70-72`): add
  `├── PingService.swift          # Proxy delay via a user-space sing-box and its Clash API`
  after `NetworkMonitor.swift`, keeping the tree's alignment.
- Key Decisions (`:161`): one bullet — **Ping is a user-space measurement**: `PingService` runs the
  bundled sing-box with every server as an outbound behind `experimental.clash_api` on a free
  localhost port and asks `/proxies/<Server.id>/delay` per server; xray servers run behind a
  user-space xray with a socks inbound each and are chained in as socks outbounds. No sudo, no
  TUN, one request per tag. Unavailable while the tunnel is up — the probe would go through it.
  `connect()` cancels a running ping first, because `run.sh` pkills every `sing-box run`.
- Runtime Files (`:187-195`): add `$TMPDIR/warpveil-ping-{singbox,xray}-<pid>.json` — ping
  configs, present only during a run.
- Gotchas (`:197-202`): the Clash API drops an `http://` test URL and needs `timeout`; sing-box
  says nothing at `warn` level, so readiness is `GET /`; two delay tests on one tag at once time out.

`README.md`: Features (`:14`) — add `- **Server ping** — real delay through each proxy, measured
by the bundled engines in user space`; Architecture tree (`:71-72`) — the `PingService.swift` line.

Then move this file to `plans/done/`, run `/code-review`, fix what it surfaces (canon, Workflow §3).

---

## Risks, ranked

1. **Not run disconnected.** Facts 3, 5 and 12 were obtained with outbounds pinned to `en0`
   because the owner's tunnel was up; the shipped config does not pin. The mechanism is the same
   one the tunnel-down case uses — but it was not run that way. First thing after Step 2:
   disconnect, open Servers, expect nine values.
2. **One bad outbound fails the whole run** (Step 1, "What could go wrong"). Visible, with the
   engine's own message; per-outbound tolerance is a later change if a real feed needs it.
3. **The wake/reconnect gap** can pkill a ping mid-run; the result is unmeasured rows, never a
   wrong number. Accepted rather than touching `ProcessManager`.
4. **Look**: disabled-button dimming, yellow, row width at 300 pt.
5. **Orphaned engines after a crash** — same class as the tunnel's, not new.

## Out of scope, deliberately left alone

- Measuring while connected via interface binding (priced under Decisions, unverified).
- Persisting results, sorting by delay, a per-row re-ping.
- A "Stop" control — leaving the page or connecting stops a run; a stop button is a few lines if
  wanted.
- `ProcessManager` awareness of the ping (the pkill collateral is handled from `AppState`).

## Validation record

Checked in this run:

- All 15 `Sources/*.swift` read in full, plus `project.pbxproj`, `CLAUDE.md`, `README.md`,
  `Info.plist`, `dev-run.sh`, `fetch-binaries.sh`, `.gitignore`, all six `plans/done/*.md`, and
  `git show 58cd4b6` (the removed ping). Every line reference re-checked with `rg -n` / `sed -n`
  before writing.
- Binaries: `Binaries/sing-box version` = 1.14.0 (`with_clash_api`), `Binaries/xray version`
  = 26.3.27. All engine facts (1–9) come from running these two on scratch configs in the
  scratchpad; sing-box source for the delay handler and `urlTest` fetched at tag `v1.14.0` and read
  verbatim. Configs used the owner's real outbounds (two sing-box, seven xray) read from
  `subscriptions.json` (not modified); no credential appears in this file.
- Build: the repository copied to the scratchpad, Step 1 applied → `xcodebuild` Debug arm64
  succeeded; Step 2 applied on top → succeeded; no Swift warnings in either log (the only
  `warning:` is `appintentsmetadataprocessor`'s, present on the unmodified tree). The real
  repository was not modified (`git status` clean at the end).
- Harness (fact 12): the Step 1 file compiled with `swiftc -swift-version 5 -target
  arm64-apple-macosx14.0 -warnings-as-errors` against `Models.swift` and two stubs; cancel
  mid-run, full run, double start, engine and temp-file cleanup all observed; the success path
  observed with `en0`-pinned outbounds.
- Canon: SwiftUI only in the window (`applicationShouldTerminate` gets one call, no AppKit view);
  no packages; no protocol, generic or wrapper (`PingError` is a private two-line `LocalizedError`
  so `localizedDescription` carries the message); `@Observable` + `@MainActor` like every service;
  `Process` + pipes; no `@AppStorage` — nothing is persisted; `Server.id` is the only key.
  Scope additions beyond the three owner decisions, all flagged: the error line under the header,
  `SubscriptionService`'s two `private` removals, the pbxproj entries.

Not verified:

- A ping with the tunnel down through the unmodified code (risk 1).
- The look of the header and rows (Step 2 "What could go wrong").
- Behaviour on macOS 14/15 (`FileHandle.bytes.lines`, `Task.sleep(for:)` are 12+/13+ APIs;
  probes ran on macOS 26).
- A hostname-addressed server resolving through `dns.servers: local` outside the tunnel.
