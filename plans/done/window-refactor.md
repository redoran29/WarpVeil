# Window refactor: menu-bar popover → regular app with a paged main window

Status: plan, not yet implemented. Written against commit `83a8ef4` (clean tree).

## Owner decisions (fixed, not up for redesign)

1. Regular app: `LSUIElement` removed, Dock icon, real main menu.
2. `NSPopover` replaced by an `NSWindow` owned by `AppDelegate`, content via `NSHostingController`.
   Style `.titled | .closable | .miniaturizable`, not resizable. Close hides (`orderOut`), never
   destroys. `applicationShouldTerminateAfterLastWindowClosed` → `false`;
   `applicationShouldHandleReopen` brings the window back.
3. Five pages behind a row of icon+label tabs: Connection, Servers, Routing, Advanced, Logs.
4. Tab header is hand-written SwiftUI. No `NSToolbar`, no `TabView`.
5. Width fixed at 620; height animates to fit the active page (PreferenceKey → `AppDelegate`
   animates `setFrame`, keeping the title bar in place).
6. `AppState` — one `@Observable @MainActor` class owning the services plus `connectedAt`,
   exposing `bootstrap()`, `connect()`, `disconnect()`. **Owner-approved exception to
   "no premature abstractions"** — the connect logic cannot live in a view once it is split across
   five pages, and the menu-bar menu needs to call it too. Do not revert this to per-view service
   parameters.
7. Bootstrap moves from `ContentView.task` to `applicationDidFinishLaunching`.
8. Settings-shaped pages use stock `Form` + `.formStyle(.grouped)`; the hand-rolled row builders
   in `SettingsView` go away.
9. Out of scope: launch-at-login / `SMAppService`, new VPN features, any change to
   `ProcessManager` sudo / PID / sleep-wake / passwordless logic. Also deferred and untouched:
   the passwordless path-unification refactor recorded in memory (`warpveil-passwordless-unify`).

Note on "six services": there are **five** stateful service instances in `AppDelegate`
(`Sources/WarpVeilApp.swift:16-20` — `ProcessManager`, `LocationService`, `NetworkMonitor`,
`SetupService`, `SubscriptionService`). `BypassService` (`Sources/BypassService.swift:3`) is a
stateless `enum` called only from `ProcessManager.connect`; there is nothing to own. `AppState`
owns five.

## What the code does today (facts the plan relies on)

- `WarpVeilApp.swift:8` — the only scene is `Settings { EmptyView() }`, present just to satisfy
  `App.body`. `AppDelegate` (`:13`) creates the services (`:16-20`), a `ContentView` framed
  400×640 (`:33-34`), and an `NSPopover` (`:36-39`). Left click toggles the popover
  (`:55-62`), right click builds a one-item Quit menu on the fly (`:64-72`). `quitApp` (`:74-79`)
  disconnects, waits 0.5 s, then terminates. `observeState()` (`:83-99`) is a
  `withObservationTracking` loop that updates the status icon and starts/stops `NetworkMonitor`
  when `pm.isRunning` flips.
- `ContentView.swift` — `Tab` enum (`:3-6`), five service parameters (`:9-13`),
  `connectedAt` / `locationTimer` / `locationTask` as `@State` (`:16-18`), six `@AppStorage`
  keys (`:19-24`). `.task` (`:63-77`) runs `loc.detect()`, `setup.checkAll()`, resets the
  `singBoxPath` / `xrayPath` keys from `ProcessManager.findBinary`, `subs.refreshAll()`, then the
  autoConnect branch. `.onChange(of: setup.singBoxPath / xrayPath)` (`:78-83`) copies
  `SetupService` paths into `@AppStorage`. `.onChange(of: pm.reconnectCount)` (`:84-87`) resets
  `connectedAt` and restarts the location timer. `.onDisappear` (`:88-92`) kills the timer.
  `doConnect` (`:119-142`), `doDisconnect` (`:144-159`) and `startLocationTimer` (`:161-176`)
  hold the connect logic; the 3/5/10 s re-detect loop is duplicated verbatim at `:150-158` and
  `:164-172`.
- `ServersView.swift` — takes the five services plus `connectedAt` binding and two closures
  (`:6-13`). `setup` (`:9`) and `selectedServer` (`:24-26`) are declared and never used. The
  body is a `ZStack` (`:29-67`) with the log overlay (`:55-57`, `logOverlay :258-312`) and the
  add-subscription overlay with hand-made dimming + transition (`:59-66`). Sections:
  `powerButton :77-102`, `statusSection :106-120` (uptime via `TimelineView`),
  `statsSection :124-129` + `statBox :131-162`, `serverListSection :166-224`,
  `bottomBar :228-254` (IP + "Show log"). Ping: `measurePings :316-326`, `tcpPing :328-363`,
  fired from `.task` (`:70-72`). `ServerRowView` (`:381-501`) and `AddSubscriptionSheet`
  (`:505-586`) are `private` structs in the same file. `loc.location` (city / country / ISP,
  `LocationService.swift:6`) is never displayed anywhere today — only `loc.ip`.
- `SettingsView.swift` — `pm` + `setup` (`:4-5`), three `@AppStorage` keys (`:7-9`), its own copy
  of the domain parser (`:13-15`). `.onChange` on domains / enabled (`:26-33`) calls
  `pm.reconnect(bypassDomains:)`. Sections: `connectionSection :38-63` (auto-connect,
  passwordless), `bypassSection :67-115`, `componentsSection :119-144`. Hand-rolled row builders:
  `sectionHeader :148-156`, `settingsToggle :158-177` (switch style, lavender tint),
  `settingsDivider :179-182`, `domainRow :184-200`. Helpers `addDomain :204-210`,
  `removeDomain :212-214`, `depStatusIcon :216-226`, `depStatusLabel :228-242`.
- `SetupService.swift:22-23` — `singBoxPath` / `xrayPath` exist only to feed the `onChange`
  above; nothing else reads them.
- `ProcessManager.swift` — `findBinary` (`:625-629`) resolves from the bundle only.
  `connect(config:engine:binaryPath:singBoxPath:bypassDomains:)` (`:301-305`).
  `reconnectCount` (`:135`) is bumped by `handleWake` (`:279-297`) and `reconnect` (`:528-546`).
  `init` (`:248-264`) registers a `willTerminateNotification` observer that disconnects inside a
  `Task` — asynchronous, so on a plain `NSApp.terminate` the process can exit before it runs
  (this is why `dev-run.sh:71-84` sweeps leftover engines). Not touched by this plan.
- `Info.plist:25-26` — `LSUIElement = true`.
- `WarpVeil.xcodeproj/project.pbxproj` is hand-maintained with synthetic ids: build files
  `AA…` (`:10-21`), file refs `BB…` (`:25-39`), the `Sources` group (`:64-81`), the Sources
  build phase (`:178-195`). Every new `.swift` file needs all four entries or it is not compiled.
  Free ids used below: `…0018`, `…0019`, `…001A`, `…001B` (both `AA` and `BB` series).
- `dev-run.sh` launches with `open -n "$APP"` (`:109-111`); `--watch` (`:129-158`) rebuilds on
  every change to `Sources/`, `Info.plist`, the entitlements or the pbxproj, then quits the dev copy
  via AppleScript `quit` (`:57`) and relaunches. Nothing in it depends on `LSUIElement`.
- Toolchain on this machine: Xcode 26.5, Swift 6.3.2 compiler, project in Swift 5 language mode
  (`SWIFT_VERSION = 5.0`), deployment target macOS 14.0.

## Verified facts (throwaway SwiftUI probes, not project code)

Run with `swiftc` against macOS 14.0 target on this machine; the probe sources are not part of the
repo.

1. `NSHostingController.sizingOptions` defaults to `.standardBounds` (raw 7). With it the window
   auto-fits the hosting view's intrinsic size **instantly** and pins `minSize == maxSize`, so any
   `NSAnimationContext` animation of the frame is clamped. A `withAnimation` on the root's
   `.frame(height:)` does **not** animate the window either — it jumps to the final height.
   Conclusion: the AppKit-driven animation the owner expects is required, and it needs
   `sizingOptions = []`.
2. With `sizingOptions = []` the hosting view has no size of its own; assigning
   `window.contentViewController = host` shrinks the window to 620×0 content. Calling
   `window.setContentSize(...)` right after the assignment restores it and it stays. Give the
   hosting view `autoresizingMask = [.width, .height]` so it follows the window frame.
3. Measuring the root with `.fixedSize(horizontal: false, vertical: true)` +
   `.background(GeometryReader { … .preference(...) })` works and yields:
   plain `VStack` of texts → real height; `Form { … }.formStyle(.grouped)` → real content height
   (355 pt for 2 sections / 5 rows, **reported twice**: 363 then 355 as the form settles);
   `ScrollView { LazyVStack(200 rows) }.frame(maxHeight: 400)` → 400;
   `ScrollView { 3 rows }.frame(maxHeight: 400)` → 48. So `.frame(maxHeight:)` on a scrolling
   page gives `min(content, cap)`.
4. The PreferenceKey **must reduce with `max`**, not `value = nextValue()`: the root has two
   children (content + the measuring background) and with the overwrite reduce the default `0`
   won, silently. My first three probes "collapsed" the window for exactly that reason.
5. `NSAnimationContext.runAnimationGroup { window.animator().setFrame(frame, display: true) }`
   with `frame.origin.y += oldHeight - newHeight` produces real intermediate heights
   (353 → 368 → 379 → 385 → 387 over 250 ms) and `frame.maxY` stays constant — the title bar
   does not move.
6. `isReleasedWhenClosed = false`; `window.close()` then `makeKeyAndOrderFront(nil)`: the same
   SwiftUI graph comes back, `@State` (a timestamp captured at creation) is unchanged,
   `onDisappear` does **not** fire on close and `onAppear` does not re-fire on reopen.
7. The whole API surface below typechecks in Swift 5 mode against the 26.5 SDK with no
   warnings: `Settings {}` + `.commands { CommandGroup(replacing: .appSettings) { … } }`,
   `NSMenuDelegate.menuNeedsUpdate`, `NSApp.activate()` (macOS 14; the `ignoringOtherApps:`
   variant is deprecated), `applicationShouldTerminate` returning `.terminateLater`,
   `withObservationTracking` loop inside an `@Observable @MainActor` class, `Form` grouped +
   `LabeledContent`, `.onPreferenceChange { Task { @MainActor in … } }`.

Not verified (see Risks): SwiftUI's delegate proxy forwarding for `applicationShouldTerminate` and
`applicationShouldHandleReopen`; whether a hidden (`orderOut`) window still receives layout /
preference updates; Cmd+V in the current popover build; `Form` under `.frame(maxHeight:)`.

## Target shape

```
Sources/
├── WarpVeilApp.swift      @main + AppDelegate: status item + menu, NSWindow, height fitting, quit
├── AppState.swift         NEW — owns pm/loc/net/setup/subs, connectedAt, bootstrap/connect/disconnect
├── ContentView.swift      Page enum, PageTabBar, page switch, height measurement
├── ConnectionView.swift   NEW — power button, status, uptime, IP/location, speeds, server picker
├── ServersView.swift      server list, ping, add sheet, ServerRowView, AddSubscriptionSheet
├── RoutingView.swift      NEW — Form: bypass toggle + domain list
├── AdvancedView.swift     RENAMED from SettingsView.swift — Form: auto-connect, passwordless, components
├── LogView.swift          NEW — the former log overlay as a page
└── (services unchanged)
```

Views receive a single `var app: AppState`. `@AppStorage` stays in the views for the keys they edit
(`selectedServerID`, `bypassEnabled`, `bypassDomains`, `autoConnect`); `AppState` reads the same
keys through `UserDefaults.standard` when it needs them. The `xrayPath` / `singBoxPath` keys are
dropped (see Step 1).

---

## Step 1 — `AppState` and bootstrap at launch (popover unchanged)

**Commit:** `Move connect logic and bootstrap into AppState`

### Changes

`Sources/AppState.swift` (new):

```swift
@Observable @MainActor
final class AppState {
    let pm = ProcessManager()
    let loc = LocationService()
    let net = NetworkMonitor()
    let setup = SetupService()
    let subs = SubscriptionService()
    var connectedAt: Date?

    private var locationTimer: Timer?
    private var locationTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() { observeReconnects() }

    var selectedServer: Server?              // subs.subscriptions.flatMap(\.servers) matched to UserDefaults "selectedServerID"
    var bypassDomains: [String]              // the one parser; replaces ContentView:26-28 and SettingsView:13-15
    private var activeBypassDomains: [String] // bypassEnabled ? bypassDomains : []

    func bootstrap() async                   // ContentView:64-76 minus the path juggling
    func connect()                           // ContentView:119-142
    func disconnect()                        // ContentView:144-159
    func routingChanged()                    // SettingsView:26-33 body: guard pm.isRunning; pm.reconnect(bypassDomains: activeBypassDomains)
    private func startLocationTimer()        // ContentView:161-176
    private func redetectLocation() -> Task<Void, Never>  // the 3/5/10 s loop, used by both disconnect() and startLocationTimer()
    private func observeReconnects()         // withObservationTracking on pm.reconnectCount → connectedAt = Date(); startLocationTimer(); re-register
}
```

Details that matter:

- `connect()` resolves binaries directly: `ProcessManager.findBinary(engine.rawValue)` —
  `Engine.rawValue` is `"sing-box"` / `"xray"` (`Models.swift:3-6`), exactly the names
  `findBinary` takes — and `singBoxPath: ProcessManager.findBinary("sing-box") ?? ""`.
  Consequently the `xrayPath` / `singBoxPath` `@AppStorage` keys (`ContentView.swift:20-21`), the
  reset logic (`:66-71`), the `onChange` copies (`:78-83`) and `SetupService.singBoxPath` /
  `xrayPath` (`SetupService.swift:22-23,32,36`) are deleted. **Judgment call, flagged:** this is
  the one place the plan removes something the move does not literally force. Justification:
  "Bundled binaries only" (`CLAUDE.md`, Key Decisions) makes a persisted path meaningless, and
  the current guard (`isExecutableFile`) would happily keep a stale path into an old
  DerivedData bundle. Alternative if the owner disagrees: keep the keys and read them via
  `UserDefaults` in `AppState` — ~8 more lines, no other change to the plan.
- `bypassEnabled` default is `true` in `@AppStorage` (`SettingsView.swift:9`), so `AppState`
  must read it as `defaults.object(forKey: "bypassEnabled") as? Bool ?? true` —
  `bool(forKey:)` returns `false` when unset and would silently disable bypass on first run.
- `bypassDomains` / `selectedServer` are computed from `UserDefaults`, which `@Observable` does not
  track. That is fine only because the view that edits the key holds the matching `@AppStorage`
  and re-renders itself; `AppState` is read fresh on that render. Keep the `@AppStorage` in the
  editing view, always.
- `observeReconnects()` follows the pattern already in `WarpVeilApp.swift:83-99`
  (`onChange` fires once, re-register inside the `Task`). Needed because
  `.onChange(of: pm.reconnectCount)` cannot live in a view once views come and go with the
  window.
- `bootstrap()`: `await loc.detect(); setup.checkAll(); await subs.refreshAll(); if
  defaults.bool(forKey: "autoConnect"), !pm.isRunning, selectedServer != nil { connect() }` —
  same order as today (`ContentView.swift:64-76`) so behaviour does not change beyond *when* it
  runs.

`Sources/WarpVeilApp.swift`: replace the five service properties (`:16-20`) with
`private let app = AppState()`; `ContentView(app: app)` (`:33`); add `Task { await app.bootstrap() }`
in `applicationDidFinishLaunching`; `quitApp` (`:74-79`) and `observeState` (`:83-99`) read
`app.pm` / `app.loc` / `app.net`. `observeState` itself stays as is (icon + `net.start/stop`).

`Sources/ContentView.swift`: keep `Tab` and the tab bar; parameters become `var app: AppState`;
delete `:16-38`, `:63-92`, `:119-176`. Pass `ServersView(app: app)` and `SettingsView(app: app)`.

`Sources/ServersView.swift`: `var app: AppState` replaces `:6-13`; `pm/loc/net/subs` → `app.*`;
`connectedAt` → `app.connectedAt`; `onConnect/onDisconnect` → `app.connect()/app.disconnect()`.
Delete the unused `selectedServer` (`:24-26`).

`Sources/SettingsView.swift`: `var app: AppState`; `pm` → `app.pm`, `setup` → `app.setup`;
delete the parser (`:13-15`) in favour of `app.bypassDomains`; the two `.onChange` bodies
(`:26-33`) become `app.routingChanged()`.

`WarpVeil.xcodeproj/project.pbxproj`: add `AppState.swift` — `BB…0018` file ref,
`AA…0018` build file, group child, Sources phase entry.

`CLAUDE.md`: delete the last Gotchas bullet ("The bootstrap … hangs off `ContentView.task` …") —
it stops being true in this commit, and the canon must not lie between commits. The Architecture
tree is updated in Step 6 together with everything else.

### Why first

Behaviour-preserving except for the intended fix: autoConnect now works without opening the UI.
Everything later builds on `AppState`; doing it while the popover is still in place keeps the
diff reviewable.

### Compiles because

All call sites move in the same commit; no view still references a removed parameter. The pbxproj
entry is in the same commit.

### What could go wrong

- `LocationService` / `NetworkMonitor` are `@Observable` but not `@MainActor`
  (`LocationService.swift:3-4`, `NetworkMonitor.swift:4-5`); holding them in a `@MainActor` class
  is what `AppDelegate` already does — no new isolation issue.
- Forgetting `observeReconnects()` → after sleep/wake the uptime keeps counting from the old
  `connectedAt` and the 30 s location poll is not restarted. Test: connect, sleep, wake.
- `bootstrap()` now runs at launch while the popover is closed; `setup.checkAll()` spawns two
  `Process` calls for versions — same as before, just earlier.

---

## Step 2 — Popover → hidden-on-close `NSWindow`, regular app, short status menu

**Commit:** `Replace the popover with a main window and make WarpVeil a regular app`

### Changes

`Info.plist`: remove `LSUIElement` (`:25-26`).

`Sources/WarpVeilApp.swift`:

- Scene stays `Settings { EmptyView() }` (macOS 14 has no way to declare an `App` with zero
  scenes; `Window` + `.defaultLaunchBehavior(.suppressed)` is macOS 15). Once the main menu is
  visible that scene contributes a "Settings…" item that opens an empty window, so add
  `.commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { delegate.showWindow() }.keyboardShortcut(",") } }`.
  Cmd+, now opens our window; the empty one is unreachable.
- `AppDelegate`: `private var window: NSWindow!` (same IUO style as `statusItem`, `:14`);
  `makeWindow()`:

  ```swift
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
                        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  window.title = "WarpVeil"
  window.isReleasedWhenClosed = false          // close() == orderOut; also avoids the ARC double-release crash
  let host = NSHostingController(rootView: ContentView(app: app))
  host.sizingOptions = []                       // window owns its size (verified fact 1-2)
  host.view.autoresizingMask = [.width, .height]
  window.contentViewController = host
  window.setContentSize(NSSize(width: 400, height: 640))   // assignment above zeroes the content size
  window.center()
  ```

  400×640 keeps this commit visually identical to the popover; Step 3 moves to 620.
- `showWindow()`: `window.makeKeyAndOrderFront(nil); NSApp.activate()`. Called at the end of
  `applicationDidFinishLaunching` (a regular app shows its window on launch — one line to drop
  if the owner prefers a silent start).
- Delete `popover` (`:15,36-39`), `statusBarAction` (`:46-53`), `togglePopover` (`:55-62`),
  `showContextMenu` (`:64-72`), `quitApp` (`:74-79`), and the `button.action/target/sendAction`
  wiring (`:28-30`).
- Status item gets a persistent `NSMenu` with `delegate = self`; `AppDelegate` adopts
  `NSMenuDelegate` and rebuilds the menu in `menuNeedsUpdate(_:)` from live state, so no
  observation is needed for it: a disabled status line ("Connected 🇩🇪 1.2.3.4" /
  "Disconnected"), "Connect"/"Disconnect" → `app.connect()/disconnect()`, "Open WarpVeil" →
  `showWindow()`, separator, "Quit WarpVeil" (Cmd+Q, `#selector(NSApplication.terminate(_:))`).
  Left and right click both open it — that is what a status item with `menu` set does.
  `observeState()` / `updateStatusIcon()` (`:83-114`) stay unchanged.
- `applicationShouldHandleReopen(_:hasVisibleWindows:)` → `showWindow(); return false`.
- `applicationShouldTerminateAfterLastWindowClosed` → `false`.
- `applicationShouldTerminate(_:)`: `guard app.pm.isRunning else { return .terminateNow }`;
  `app.disconnect()`; reply `true` after 0.5 s; return `.terminateLater`. This is the old
  `quitApp` (`:74-79`) moved to the one place every quit path goes through — the app menu's
  Cmd+Q, the status menu, and `dev-run.sh`'s AppleScript `quit` (`dev-run.sh:57`). Without it,
  Cmd+Q from the new main menu would exit before `ProcessManager`'s asynchronous
  `willTerminateNotification` handler (`ProcessManager.swift:255-263`) runs, leaving root
  engines up. `ProcessManager` is not modified; its observer becomes a no-op on that path
  (`disconnect()` guards on `isRunning`, `:549`).

### Compiles because

`ContentView` already takes only `app` after Step 1; nothing else references the popover.

### What could go wrong

- SwiftUI's `@NSApplicationDelegateAdaptor` installs its own delegate and forwards to ours.
  `applicationShouldHandleReopen`, `applicationShouldTerminate` and
  `applicationShouldTerminateAfterLastWindowClosed` are commonly implemented this way and known
  to be forwarded; not verified in this run. If reopen does not fire, Dock click → nothing;
  check first thing after this commit. If `applicationShouldTerminate` is not forwarded the
  fallback is the old asyncAfter-then-terminate in the status-menu action (loses Cmd+Q
  correctness).
- `hasVisibleWindows` is `false` for a miniaturized window; `makeKeyAndOrderFront` is expected
  to deminiaturize — verify with the yellow button.
- `dev-run.sh --watch`: every rebuild quits and relaunches with `open -n`; as a regular app it
  now activates and bounces the Dock on each relaunch and the window reappears centred
  (no frame autosave — `setFrameAutosaveName` is one line if that gets annoying, but it is not
  asked for). In-memory state resets per relaunch exactly as documented in `CLAUDE.md`
  (dev-run section). Quit now waits 0.5 s for `disconnect()`; `stop_dev` polls up to 3 s
  (`dev-run.sh:58-61`), so it is within budget.
- Cmd+V in the subscription `TextField` (`ServersView.swift:546`): an AppKit-only agent app has no
  Edit menu and therefore no `paste:` key equivalent — but this app uses the SwiftUI `App`
  lifecycle, which builds the standard main menu (including Edit) even for `LSUIElement` apps, so
  Cmd+V most likely works today. Not verified at runtime. After this commit the menu is visible
  and standard, so it works regardless.
- The dev copy's app menu shows "WarpVeil Dev" (`dev-run.sh:103`) — fine, helps tell copies
  apart.

---

## Step 3 — Paged shell: `Page` enum, `PageTabBar`, 620 width, animated height fitting

**Commit:** `Add tab header and fit the window height to the active page`

### Changes

`Sources/ContentView.swift`:

- `Tab` (`:3-6`) → `Page: String, CaseIterable` with `var icon: String` (SF Symbols). In this
  commit only two cases exist, `.servers` (`server.rack`, already used at `ServersView.swift:184`)
  and `.settings` (`gearshape`); Steps 4-5 grow it to five.
- `tabBar` (`:97-115`) → `PageTabBar(selection: $page)`: `HStack` of plain `Button`s, each an
  `Image(systemName:)` over a caption `Text` in a 72×52 rounded rect, active one filled
  `Color.secondary.opacity(0.15)` and `.primary`, others `.secondary`. ~25 lines, typechecked.
- Body:

  ```swift
  VStack(spacing: 0) { PageTabBar(selection: $page); Divider(); pageView }
      .frame(width: 620)
      .fixedSize(horizontal: false, vertical: true)
      .background(GeometryReader { geometry in
          Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
      })
      .onPreferenceChange(ContentHeightKey.self) { height in Task { @MainActor in onHeightChange(height) } }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(nsColor: .windowBackgroundColor))
  ```

  `ContentHeightKey.reduce` is `value = max(value, nextValue())` (verified fact 4 — the obvious
  overwrite reduce reports 0). The outer `.frame(maxHeight:, alignment: .top)` pins the content
  to the title bar while the window animates underneath; the outer `.background` paints the
  strip that is exposed while growing. `onHeightChange: @MainActor (CGFloat) -> Void` is a plain
  stored closure; the `Task { @MainActor in }` hop is what keeps `onPreferenceChange`'s
  `@Sendable` closure warning-free.
- Drop `.transition(.opacity)` / `.animation(value: tab)` (`:59-60`): during a crossfade both
  pages sit in the `VStack` and the measured height briefly becomes old + new; System Settings
  does not crossfade either.
- The two existing pages are scrolling containers, so each gets a cap in this commit:
  `ServersView` root `ScrollView` (`ServersView.swift:31`) → `.frame(maxHeight: 560)`;
  `SettingsView` root `ScrollView` (`SettingsView.swift:18`) → `.frame(maxHeight: 560)`.
  Without a cap a `ScrollView` reports its full content height (verified fact 3).

`Sources/WarpVeilApp.swift`:

- `makeWindow()` passes the closure: `ContentView(app: app) { [weak self] in self?.fitWindow(toContentHeight: $0) }`;
  contentRect / `setContentSize` become 620 wide.
- `fitWindow(toContentHeight:)`:

  ```swift
  let targetHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 620, height: height)).height
  var frame = window.frame
  guard abs(frame.height - targetHeight) > 0.5 else { return }
  frame.origin.y += frame.height - targetHeight        // NSWindow origin is bottom-left; keep the title bar put
  frame.size.height = targetHeight
  guard window.isVisible else { window.setFrame(frame, display: false); return }   // first measurement arrives before showWindow()
  NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      window.animator().setFrame(frame, display: true)
  }
  ```

  Verified end to end (facts 2, 5). `frameRect(forContentRect:)` accounts for the title bar, so the
  content height is what SwiftUI measured.

### Compiles because

`Page` replaces `Tab` in the same file; `ServersView`/`SettingsView` signatures are unchanged.

### What could go wrong (this is the fragile step)

- **Feedback loop.** The measured height must never depend on the window height. It does not, as
  long as every page has an ideal height under `fixedSize(vertical: true)`: fixed content, or a
  scrolling container with `.frame(maxHeight:)` / `.frame(height:)`. A page that fills
  `maxHeight: .infinity` without a cap would measure 0 or the current window height — if the
  window ever "sticks" at a wrong size, look for a page without a cap.
- **Double report.** Grouped `Form` reports twice as it settles (363 → 355 in the probe); the
  second call retargets the running animation. Cosmetic at worst. Make sure the guard
  `abs(...) > 0.5` stays, or every re-render animates.
- **Hidden window.** Page height can change while the window is hidden (e.g. autoConnect
  finishes → Connection page shows stats). If SwiftUI does not lay out a hidden window, the
  update arrives on show and the window animates right after appearing — unverified, minor.
- `fitWindow` before `window` exists: the closure is created inside `makeWindow()`, and the first
  preference change happens during `contentViewController` assignment, which is after `window`
  is constructed but before `self.window` is assigned. Either use the local `window` via a `lazy
  var window: NSWindow = makeWindow()` or build the controller after assigning `self.window`.
  Pick one deliberately; an IUO nil here crashes at launch.
- `TimelineView` (uptime, `ServersView.swift:113`) re-renders every second; measurement runs
  every second too but the guard filters identical heights. Fine.

---

## Step 4 — Split `ServersView` into Connection, Servers and Logs pages

**Commit:** `Split the servers screen into Connection, Servers and Logs pages`

### Changes

`Sources/ConnectionView.swift` (new): `var app: AppState`,
`@AppStorage("selectedServerID")`. Moves from `ServersView.swift`: `lavender` (`:77`),
`powerButton` (`:79-102`), `statusSection` (`:106-120`), `statsSection` + `statBox`
(`:124-162`), `uptimeString` (`:373-376`). New: an IP/location line (`app.loc.ip` +
`app.loc.location`, the latter unused until now), and the current-server picker —
`Picker("Server", selection: $selectedServerID) { ForEach(servers) { Text($0.name).tag($0.id.uuidString) } }`
over `app.subs.subscriptions.flatMap(\.servers)`, `.pickerStyle(.menu)`, with a "No servers — add
one on the Servers page" text when empty. Changing the picker while connected does **not**
reconnect — same as tapping a row today; not adding that. Fixed-height content, no cap needed.
Stats boxes at 620 wide get broad; a `.frame(maxWidth: 360)` on `statsSection` is a taste call
for implementation.

`Sources/LogView.swift` (new): `var app: AppState`; the `logOverlay` body (`:258-312`) minus the
close button; Copy/Clear stay. Body `ScrollView { LazyVStack … }.frame(height: 440)` — a fixed
viewport, because a `LazyVStack` under `fixedSize` lays out all rows (probe: 200 rows → 3232 pt).

`Sources/ServersView.swift` (kept): what remains is `serverListSection` (`:166-224`),
`measurePings`/`tcpPing` (`:316-363`), `subscriptionFor` (`:367-371`), `ServerRowView`,
`AddSubscriptionSheet`. Delete `showLog` (`:17`), the log branch (`:55-57`), `bottomBar`
(`:228-254`), `logOverlay`, `uptimeString`, the power/status/stats sections, and the
`.animation(value: showLog)` (`:69`). Root becomes `ScrollView { serverListSection }.frame(maxHeight: 560)`.
Recommended (net code down, stock component): present `AddSubscriptionSheet` with
`.sheet(isPresented: $showAddSheet)` instead of the `ZStack` dimming layer + transition
(`:59-68`, `:568-570`); the sheet's own close button then uses `@Environment(\.dismiss)`. A real
window can host sheets; the popover could not. If kept as an overlay it still works.

`Sources/ContentView.swift`: `Page` gains `.connection` (`power`) and `.logs` (`doc.text`),
order Connection, Servers, Settings, Logs; default `.connection`; switch adds the two views.

`project.pbxproj`: `ConnectionView.swift` (`…0019`), `LogView.swift` (`…001A`).

### Compiles because

Every moved symbol has exactly one new home; `ServersView` no longer references `connectedAt`,
`net`, `loc`. Grep `uptimeString`, `statBox`, `logOverlay` after the move — each must appear
in one file.

### What could go wrong

- `pings` are `@State` in `ServersView` and re-measured by `.task` (`:70-72`) every time the
  page is entered — the `switch` recreates the page view. Same as switching tabs today; noted,
  not changed.
- Page-local `@State` (`showAddSheet`, `newDomain`, typed text) is lost when switching pages;
  it survives hide/show of the window (verified fact 6). Expected.
- `.sheet` on a non-resizable, height-animating window: sheets attach to the window frame and
  do not enter the measured content — no interaction with fitting. If the sheet appears
  detached after a resize, fall back to the overlay.

---

## Step 5 — Routing and Advanced pages as grouped `Form`s

**Commit:** `Replace the settings screen with Routing and Advanced Form pages`

### Changes

`git mv Sources/SettingsView.swift Sources/AdvancedView.swift` and update the pbxproj `path` +
comments (`BB…0013` at `:36`, `AA…000B` at `:18`, `:71`, `:183`). Add `RoutingView.swift`
(`…001B`).

`Sources/RoutingView.swift` (new):

```swift
Form {
    Section { Toggle("Enable bypass", isOn: $bypassEnabled) }
    if bypassEnabled {
        Section("Domains") {
            ForEach(app.bypassDomains, id: \.self) { domain in
                LabeledContent(domain) { Button { removeDomain(domain) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            }
            TextField("example.com", text: $newDomain).onSubmit(addDomain)
        }
    }
}
.formStyle(.grouped)
.frame(maxHeight: 520)
.onChange(of: bypassDomainsRaw) { app.routingChanged() }
.onChange(of: bypassEnabled) { app.routingChanged() }
```

`addDomain` / `removeDomain` (`SettingsView.swift:204-214`) move here; the
`showNewDomainField` toggle (`:11`, `:82-112`) goes — an always-present text field row is the
stock Form idiom and drops the OK / cancel buttons.

`Sources/AdvancedView.swift` (renamed): `Form { Section("Connection") { Toggle("Auto-connect", …); Toggle("Passwordless", …).disabled(app.pm.isPasswordlessBusy) } Section("Components") { ForEach(Dependency.allCases) { LabeledContent(dep.rawValue) { version or status } } } }.formStyle(.grouped)`.
Subtitles ("Connect on app launch", the passwordless busy text) become `Text(...).font(.caption)`
under the toggle label via `Toggle { VStack(alignment: .leading) { … } }` — or are dropped;
owner's taste. Keep `depStatusIcon` / `depStatusLabel` (`:216-242`) as they are.

Delete: `sectionHeader`, `settingsToggle`, `settingsDivider`, `domainRow`
(`SettingsView.swift:148-200`), the custom `.toggleStyle(.switch).tint(lavender)` (`:171-172`)
— grouped Forms render switches natively. `bypassSection` and `componentsSection` as such
disappear into the two Forms.

`Sources/ContentView.swift`: `Page` becomes Connection, Servers, Routing
(`arrow.triangle.branch`), Advanced (`gearshape`), Logs; `.settings` removed.

### Compiles because

`SettingsView` is referenced only from `ContentView`'s switch, which changes in the same commit.

### What could go wrong

- `Form` under `.frame(maxHeight: 520)` is *expected* to measure `min(content, 520)` like
  `ScrollView` did (fact 3), but only `ScrollView` was probed. If the Routing page measures the
  full list height with many domains, switch the cap to a fixed `.frame(height:)`.
- `ForEach(app.bypassDomains, id: \.self)` inside a Form re-renders because the page owns
  `@AppStorage("bypassDomains")` — if the list ever stops updating after add/remove, that
  `@AppStorage` was removed from the page. It must stay.
- Look: grouped Forms bring their own paddings; the lavender accent disappears from the toggles.
  That is the point of decision 8.

---

## Step 6 — Documentation

**Commit:** `Document the main window architecture`

`CLAUDE.md`: header line ("Runs entirely in the menu bar (no Dock icon)" → regular app with a
menu-bar status item and a paged main window); Architecture tree (new files, one-liners per
file, `AppState` noted as the owner-approved exception with the reason); "All services use
`@Observable`. They are created in `AppDelegate` and passed down through `ContentView`" →
created in `AppState`, views take `app`; Key Decisions: replace "LSUIElement = true" with the
window model (hidden on close, `isReleasedWhenClosed = false`, height fitted from a
`PreferenceKey`, `sizingOptions = []` and why, `max` reduce and why); add the quit path
(`applicationShouldTerminate` waits 0.5 s for `disconnect()`); dev-run section: relaunch
activates the app and recentres the window.

`README.md`: `:3`, `:7` (menu bar widget → status menu + window), `:19-21` screenshot table
(five pages), `:33` ("runs in the menu bar (no Dock icon). Right-click the tray icon to quit" →
quit from the app menu or the status menu), Architecture tree `:56-69`.

`release.sh:156` release-notes text: "Launch — the icon appears in the menu bar" → "Launch — the
window opens and the icon appears in the menu bar".

Then move this file to `plans/done/` and run `/code-review` (canon, step 3 of the workflow).

---

## Risks, ranked

1. **Height fitting** (Step 3). Mechanism verified in isolation, including animation and
   title-bar anchoring; the remaining hazards are a page without a height cap (feedback / full
   content height), the `max` reduce, and the `window` IUO ordering in `makeWindow()`.
   Fallback if it misbehaves in the real app: per-page fixed heights on `Page` (`var height:
   CGFloat`) fed to the same `fitWindow` from `.onChange(of: page)` — ten lines, no
   `GeometryReader`, loses the "fits content" behaviour on the Connection page.
2. **Delegate forwarding** (Step 2). Reopen and terminate hooks are assumed forwarded by
   SwiftUI's adaptor. Cheap to check right after the commit; both have fallbacks noted above.
3. **Hidden vs closed**. There is no "closed" any more: `close()` on a
   `isReleasedWhenClosed = false` window is `orderOut` (fact 6). All view `@State` survives
   hide/show; timers never lived in views after Step 1 (`locationTimer` in `AppState`,
   `NetworkMonitor.timer` driven by `AppDelegate.observeState`, `logDebounceTimer` in
   `ProcessManager`). `onDisappear` does not fire on hide — which is exactly why the old
   `ContentView.onDisappear` had to go rather than be ported.
4. **Cmd+V** — probably fine today, certainly fine after Step 2; unverified before.
5. **Quit timing** — 0.5 s wait before `NSApp.reply(toApplicationShouldTerminate: true)` is
   inherited from `quitApp`; `dev-run.sh` tolerates it.
6. **Form measurement under a cap** (Step 5) — one unverified assumption, with a one-line
   fallback.

## Out of scope, deliberately left alone

- `ProcessManager` in full, including its asynchronous `willTerminateNotification` handler.
- Reconnecting when the server picker changes while connected.
- Persisting the selected page or the window frame.
- Launch at login.
- The Russian placeholder string at `ServersView.swift:546`.

## Validation record

Checked in this run:

- Every file, type, function and line reference above was taken from a full read of all 11
  `Sources/*.swift` files, `Info.plist`, `project.pbxproj`, `dev-run.sh`, `release.sh`, `README.md`
  and `CLAUDE.md` at `83a8ef4`, then re-grepped: `selectedServer` (only ContentView + the dead
  ServersView copy), `loc.location` (no UI use), `setup` in ServersView (declared only),
  `setup.singBoxPath/xrayPath` (only `ContentView:78-83`), all `@AppStorage` keys,
  `withObservationTracking` (only `WarpVeilApp:84`), `Tab`, `toggleStyle`/`tint`, `.task` /
  `onDisappear`, `popover`.
- The API surface of Steps 2-3 and the `Form` shape of Step 5 typecheck with no warnings in
  Swift 5 mode against the installed SDK (`swiftc -typecheck -parse-as-library -swift-version 5
  -target arm64-apple-macosx14.0`).
- Window sizing, animation, top-edge anchoring, `Form`/`ScrollView` measurement, and
  close/reopen state survival were exercised in throwaway probe apps (facts 1-6).
- Each step's compile story was walked through against the symbol moves; no step references a
  symbol from a later step.
- Canon cross-check: no AppKit *views* (the window, status item and menu are AppKit objects the
  code already uses; the hosted content is SwiftUI); no packages; no protocols/generics
  introduced; the only new abstraction is the owner-mandated `AppState`; every step deletes more
  than it adds except Step 3 (tab bar + fitting, ~60 lines net).
- Scope: nothing outside items 1-8 except the flagged binary-path key removal (Step 1) and the
  `applicationShouldTerminate` quit path (Step 2), both consequences of the move and both
  called out with alternatives.

Not verifiable without building the real target (do these first when implementing):

- `applicationShouldHandleReopen` / `applicationShouldTerminate` forwarding through
  `@NSApplicationDelegateAdaptor`.
- Whether the SwiftUI main menu is present (and Cmd+V works) in the current `LSUIElement` build.
- Layout / preference delivery while the window is hidden.
- Grouped `Form` measured height under `.frame(maxHeight:)`.
- Exact page heights and the 620-wide look of the Connection page; numbers above (560, 520, 440)
  are starting points.
