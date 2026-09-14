# Ping: report a warm delay, not the cold handshake

Status: implemented. Written against `d79c56a`; the Design and step 1 below were rewritten after
the first shape was built and measured worse than what it replaced — see the first Design bullet.

Owner's symptom: "ping does not update, always the same numbers". Diagnosed empirically with the
bundled engines and the exact configs `PingService` builds, so this plan does not re-derive it:

- Every run launches fresh engines and asks the Clash API for **one** delay per tag. That first
  request pays the full REALITY/TLS handshake to the proxy, and the handshake swamps the servers'
  real differences: pass 1 over the owner's 9 servers is 779–1124 ms for every row, run after run.
- The same engines asked again answer 419–947 ms on pass 2 and 336–371 ms on pass 3 — values that
  differ per server and move between runs.
- Not DNS: an IP-host test URL (`https://1.1.1.1/`) shows the same gap (717, then 365, 368, 363).
- The UI is fine: `ServerRowView` re-renders on every new value; `generation` / `isRunning` behave.
- "Luxury - Atlanta" (xhttp+reality) fails its test because the server is unreachable — verified
  with curl through a standalone xray. Out of scope.

Fix: measure every tag in several passes over the already-running engines and report the minimum
of what those passes measured.

Out of scope and untouched: `ServersView`, `AppState.pingAll()`, `ProcessManager`, the engine
configs, `concurrency`, `timeoutMilliseconds`, `Models.swift`.

## What the code does today (facts the plan relies on)

All in `Sources/PingService.swift`:

- `PingResult` (`:5-9`): `.measuring`, `.delay(Int)`, `.failed`. `results: [String: PingResult]`
  (`:23`); `ServerRowView.pingLabel` (`Sources/ServersView.swift:188-203`) renders a spinner,
  `N ms`, `--`, or nothing for `nil`.
- Constants (`:32-37`): `testURL`, `timeoutMilliseconds = 5000`, `concurrency = 10`,
  `readinessAttempts`, `readinessInterval`.
- `measureAll(_:apiPort:)` (`:117-130`): a task group throttled to `concurrency`, one child per
  tag, each child `await self.delay(of: tag, apiPort: apiPort)`; the parent writes
  `results[tag] = result` as each child finishes. `results[tag] = nil` removes the key, so a `nil`
  answer leaves the row unmeasured; `start()` (`:71`) then drops whatever is still `.measuring`.
- `delay(of:apiPort:)` (`:132-147`): one `GET /proxies/<tag>/delay?url=&timeout=`. `nil` from
  `api` (`:149-163`) means the engine is gone (the run was cancelled) → returns `nil`; a non-200
  or unparsable body → `.failed`; otherwise `.delay(ms)`.
- Cancellation: `cancel()` (`:79-83`) cancels the task **and** terminates the engines
  synchronously, so an in-flight request fails and returns `nil`. `measure` (`:87-115`) checks
  `Task.isCancelled` before each launch and before `measureAll`; `measureAll.addNext` (`:121`)
  checks it before adding a child. Task-group children inherit the parent's cancellation, so
  `Task.isCancelled` read inside a child (and inside the `@MainActor` methods it awaits) is the
  child's flag. Nothing checks it between two requests on one tag today, because there is no
  second request.
- `session.timeoutIntervalForRequest = 10` (`:46`) caps a request that the API itself does not
  answer; the API's own `timeout` is `timeoutMilliseconds`.
- Header comment (`:11-19`) describes the number as "the real round trip through each proxy" and
  says the delay test "sends one HEAD request through that outbound".
- Canon, `CLAUDE.md`: Key Decisions bullet "Ping is a user-space measurement" (`:188-197`) ends
  its first sentence with "No sudo, no TUN, one request per tag." (`:191`). Gotcha `:219`:
  "Two delay tests on one outbound tag at once time each other out — one request per tag".

## Design

- **Passes over every tag, not repeats inside one.** The first draft looped three requests inside
  each tag with the tags concurrent; measured on the owner's feed it was worse than the single
  request it replaced — only the two sing-box servers warmed up (362, 314 ms), every xray-backed
  row stayed at 670-750 ms, and three of them timed out. Three synchronized passes over the same
  engines, in the same conditions, brought every row to 323-372 ms with no failure beyond the dead
  Atlanta server. Nine cold handshakes at once is itself what makes requests time out, and a pass
  boundary spaces them apart.
- A tag that failed is retried by the next pass instead of being written off — the failures above
  were cold-pass casualties, not dead servers. Only a tag that fails every pass reads `--`.
- Report the **minimum** across the passes: it is the value the handshake cannot inflate.
- Every pass publishes as it goes, so the rows fill at today's speed with today's ~800 ms and then
  refine to ~350 ms, instead of showing a spinner three times as long.
- `nil` from a request means the engines are gone — `cancel()` terminates them synchronously — so
  the row keeps whatever it already shows; a tag no pass ever measured is dropped by `start()`'s
  existing `.measuring` filter.

## Steps

Each step compiles on its own.

### 1. `Sources/PingService.swift` — the passes

Add next to `concurrency` (`:35`):

```swift
private static let passes = 3
```

Split `measureAll` (`:117-130`) in two. The loop over passes:

```swift
private func measureAll(_ tags: [String], apiPort: UInt16) async {
    for _ in 0..<Self.passes {
        guard !Task.isCancelled else { return }
        await measurePass(tags, apiPort: apiPort)
    }
}
```

and today's task group as `measurePass`, unchanged except that it hands each answer to `record`
instead of assigning `results[tag]`:

```swift
private func record(_ result: PingResult?, for tag: String) {
    switch (result, results[tag]) {
    case (nil, _): return
    case (.delay(let measured), .delay(let best)): results[tag] = .delay(min(measured, best))
    case (.failed, .delay): return
    default: results[tag] = result
    }
}
```

`delay(of:apiPort:)` (`:132-147`) stays as it is — one request per call. Its comment about `nil`
moves the explanation to `record`, which is what now keeps a cancel apart from a failure.

### 2. `Sources/PingService.swift` — the header comment

Replace `:11-19` with a block that still says what the number is and adds why it is warm:

```
// The real round trip through each proxy, not a TCP handshake: a CDN front completes a
// handshake instantly while the node behind it is dead. A user-space sing-box carries every
// server as an outbound behind its Clash API, whose delay test sends one HEAD request through
// that outbound. xray servers sit behind a user-space xray with a SOCKS inbound each and are
// chained in as socks outbounds — the shape the tunnel already uses for them. No sudo, no TUN.
// Each tag is tested a few times in a row on the same engines and the minimum is reported: the
// first request pays the REALITY/TLS handshake to the proxy, which puts every server at ~800 ms
// and hides the ~50 ms that actually separate them.
// Every outbound's dial is bound to the primary interface, so a tunnel that is up does not
// swallow the probe. The bind covers the dial, not name resolution: a server given as a
// hostname is still resolved by the system resolver, which the tunnel's hijack-dns catches
// while it is up, and that lookup lands inside the measured time.
```

### 3. `CLAUDE.md`

- `:191` — replace `No sudo, no TUN, one request per tag.` with
  `No sudo, no TUN. Each tag is tested three times in a row on the same engines and the minimum is reported: the first request carries the REALITY/TLS handshake, which puts every server at the same ~800 ms and hides the real differences.`
  (rewrap the bullet; nothing else in it changes).
- `:219` — replace with
  `- Two delay tests on one outbound tag at once time each other out — the ping's repeats on a tag are sequential, tags run concurrently`.
- Add after `:222`:
  `- A single Clash delay test is a cold one: it pays the handshake to the proxy, so one request per tag reads ~800 ms for every server and never moves between runs`.

### 4. Close

Move this file to `plans/done/`, run `/code-review`, fix what it finds.

## Cost and what changes for the user

- Today: ~1.5 s engine start + ~2 s measuring for 9 servers. After: the same start plus three
  passes, the later ones faster — 5.6 s and 8.8 s for a whole run in the standalone measurement,
  including the dead server that costs one failure per pass.
- The rows show ~350 ms instead of ~800 ms, they differ per server and they move between runs. A
  server that loses the cold pass recovers in a later one instead of reading `--`.
- Nothing changes in the Servers page, the button, the spinner, or `--` for a dead server.

## Verification

1. `./dev-run.sh`, open Servers, wait for the automatic run: rows must show values that differ
   from each other (not all within a few ms of ~800), and "Luxury - Atlanta" stays `--`. If every
   row reads `--` at once, check that the bundled engines still run
   (`build-dev/WarpVeil.app/Contents/Resources/sing-box version`) — a dev build can leave them
   with a signature the kernel kills, which `codesign --force --sign -` on each of them repairs.
2. Press "Ping all" twice more: numbers must move between runs.
3. Press "Ping all" and leave the page at once (`onDisappear` → `cancel()`): no error line, no
   lingering `sing-box`/`xray` processes (`pgrep -fl warpveil-ping`). A cancel during the first
   pass leaves the rows blank; from the second pass on they keep what the earlier passes measured,
   because `record` treats no answer as "the engines are gone", not as a new verdict.
4. Disconnect the network mid-run: every row ends `--` or blank. A network that refuses
   connections ends the run in about the same time as before (a refusal comes back in ~14 ms); a
   network that swallows them costs `timeoutMilliseconds` per pass, so up to ~15 s of spinner
   instead of ~5 s. Accepted: the passes exist precisely to give a tag that failed another try, and
   stopping early would take that away from a one-server list, where a cold-pass failure is common.

## Validation of this plan (done against `d79c56a`)

- `PingService`, `PingResult`, `results`, `start`, `cancel`, `measure`, `measureAll`,
  `delay(of:apiPort:)`, `api(_:query:apiPort:)`, `timeoutMilliseconds`, `concurrency`,
  `session.timeoutIntervalForRequest` — all at the lines cited in `Sources/PingService.swift`.
- `measureAll` calls `self.delay(of:apiPort:)` (`:122`); that call moves to `measurePass`
  unchanged, and `delay(of:apiPort:)` itself keeps its signature and body.
- `ServerRowView.pingLabel` at `Sources/ServersView.swift:188-203`; `AppState.pingAll()` at
  `Sources/AppState.swift:118-122`; `onDisappear { app.ping.cancel() }` at
  `Sources/ServersView.swift:17`.
- `record`'s switch over `(PingResult?, PingResult?)` was compiled and run against all six
  transitions before it went in: minimum across passes, `.failed` never overwriting a `.delay`,
  `nil` a no-op.
- `CLAUDE.md` lines `:188-197`, `:191`, `:219`, `:222` read back as quoted above.
