# Three-column window: sidebar, page column, connection panel

Status: plan, not yet implemented. Written against `bedae21` (clean tree).

## What this replaces

This is a **replacement of the window shell**, not an addition to it. The shell built by
`plans/done/window-refactor.md` earlier today is a fixed 620-wide, non-resizable `NSWindow`
whose height animates to fit the active page: `ContentHeightKey` measures the page,
`AppDelegate.fitWindow` animates the frame, and a hand-written `PageTabBar` switches pages. That
machinery exists only because the window could not be resized. A three-column layout needs a wide,
resizable window, and once the window is resizable the content must stop driving its size — so the
measurement, the animation, the height caps and the tab bar all go, together with the two
`CLAUDE.md` Key Decisions that describe them ("Window model", "Height fitting").

Window-refactor decisions 3, 4 and 5 (five pages behind tabs, hand-written tab header, fixed width
with animated height) are overturned by this plan. Its decisions 1, 2, 6, 7, 8 (regular app,
hidden-on-close `NSWindow` from `AppDelegate`, `AppState`, bootstrap at launch, grouped `Form`s)
stand and are relied on below.

The canon's newest rule applies here in spirit: the height-fitting shell carried three documented
traps (`sizingOptions`, the `max` reduce, the per-page caps) and a probe-verified mechanism, and it
was still the wrong shape for the layout the owner wants. Replacing it deletes all three traps;
nothing in this plan re-measures content or animates a frame.

## Owner decisions this plan takes as fixed

1. Three columns: sidebar on the left, the server list in the middle, the connect button with its
   status on the right (the Happ layout).
2. The window stays an AppKit `NSWindow` built in `AppDelegate`; everything inside it is SwiftUI
   (`CLAUDE.md`, Tech Conventions).
3. Out of scope: `ProcessManager`, routing/bypass logic, `SubscriptionService` and the server
   identity model, subscription formats.
4. Must survive unchanged: the status item and its menu, hide-on-close, the
   `applicationShouldTerminate` teardown wait, `applicationShouldHandleReopen`, auto-connect at
   launch.
5. Zero warnings.

## What the code does today (facts the plan relies on)

- `Sources/WarpVeilApp.swift` — `window: NSWindow!` (`:23`), `windowWidth = 620` (`:27`).
  `makeWindow()` (`:45-69`): style `[.titled, .closable, .miniaturizable]` (`:48`),
  `isReleasedWhenClosed = false` (`:54`), `ContentView(app:) { height in fitWindow(...) }`
  (`:58-60`), `host.sizingOptions = []` (`:63`), `autoresizingMask` (`:64`), `setContentSize`
  (`:67`), `center()` (`:68`). `fitWindow(toContentHeight:)` (`:71-93`, comment `:71-72`).
  `showWindow()` (`:95-98`), reopen (`:102-105`), last-window-closed (`:107-109`),
  `applicationShouldTerminate` with `awaitTeardown(timeout: 30)` (`:114-122`), status menu
  (`:127-155`), `observeState` / `updateStatusIcon` (`:159-183`). Only `makeWindow`, `fitWindow`
  and `windowWidth` change.
- `Sources/ContentView.swift` — `Color.lavender` (`:3-5`, used by `ConnectionView.swift:43-56`
  and `ServersView.swift:151`, stays). `Page` (`:7-21`): `connection` / `routing` / `advanced` /
  `logs` with `icon` (`:13-20`). `ContentHeightKey` (`:23-31`). `ContentView` (`:33-78`):
  `onHeightChange` (`:35`), `page` state (`:37`), body (`:39-63`) with `PageTabBar`, `Divider`,
  the single `.frame(maxHeight: 700)` cap (`:47-48`), `.frame(width: 620)` (`:50`), `fixedSize`
  + `GeometryReader` + `onPreferenceChange` (`:51-59`), the top-pinning frame and background
  (`:61-62`); `pageView` switch (`:65-77`). `PageTabBar` (`:80-109`).
- `Sources/ConnectionView.swift` — `@AppStorage("selectedServerID")` (`:6`), body (`:8-33`):
  `powerButton` with `.padding(.top, 28)` (`:10-12`), `statusSection` (`:14-15`), `statsSection`
  under `.frame(maxWidth: 360)` when running (`:17-21`), `locationSection` (`:23-24`), then the
  embedded list — `Divider()` and `ScrollView { ServersView(app:selectedServerID:) }` (`:26-31`).
  `powerButton` (`:37-61`) is disabled while `!app.pm.isRunning && app.selectedServer == nil`
  (`:60`); `app.selectedServer` reads `UserDefaults` (`AppState.swift:32-34, 43-45`), which
  `@Observable` does not track — the view re-renders on selection only because it holds the
  `@AppStorage` (contract at `AppState.swift:26-30`, repeated in `CLAUDE.md`).
- `Sources/ServersView.swift` — `@Binding var selectedServerID` (`:6`), body is
  `serverListSection` with `.sheet` and `.confirmationDialog` (`:10-25`); the section (`:29-75`)
  carries its own "SERVERS / + Add" header (`:31-43`), the empty state with `server.rack` (`:47`),
  the grouped rows (`:61-72`) that read and write `selectedServerID` (`:66, :68`). No scrolling
  container of its own since servers-page Step 4 — `ConnectionView` provides it.
- `Sources/RoutingView.swift`, `Sources/AdvancedView.swift` — grouped `Form`s, no height caps
  (`rg maxHeight Sources/` finds only `ContentView.swift:48`).
- `Sources/LogView.swift` — header row + `ScrollView { LazyVStack }` (`:39-50`); the comment at
  `:51-52` ("Fixed viewport: … a cap on the scroll view is not enough here") describes a
  `.frame(height:)` that no longer exists. Stale today; deleted here because it is about the
  height mechanism.
- `Sources/SubscriptionService.swift:97-101` — `removeSubscription` clears the `selectedServerID`
  default directly when the deleted subscription held the selection. Any view holding that
  `@AppStorage` re-renders on it.
- `WarpVeil.xcodeproj/project.pbxproj` — no file is added or renamed by this plan, so the
  hand-maintained project file is not touched.
- Toolchain: Xcode 26.5, Swift 6.3.2 compiler, project in Swift 5 mode, deployment target
  macOS 14.0, this machine runs macOS 26 (Darwin 25.6).

## Verified facts (throwaway probes, not project code)

A stand-alone AppKit app (`swiftc -swift-version 5 -target arm64-apple-macosx14.0`, no warnings)
built an `NSWindow` exactly the way `AppDelegate` does — `[.titled, .closable, .miniaturizable,
.resizable]`, `isReleasedWhenClosed = false`, `NSHostingController` as `contentViewController` —
hosting a three-column `NavigationSplitView` whose sidebar is `List(selection:)` over the four
`Page` cases with `.listStyle(.sidebar)`, whose middle column switches on the selection
(`ScrollView` of 40 rows / grouped `Form` / 300-line monospaced log) and whose detail column is a
fixed-size stand-in for the power button. Column widths: sidebar 150/180/220, content
min 280 ideal 360, detail 280/320/400. Sizes were read back through `GeometryReader`s and
screenshots were taken with `CGWindowListCreateImage`.

1. **The split view works in a hosted window.** Sidebar labels, icons and the selection highlight
   render natively; the window gets an `NSToolbar` with the sidebar-toggle button and the window
   title, installed by the split view itself — `window.toolbar != nil` without any
   `sceneBridgingOptions`, and setting `sceneBridgingOptions = [.toolbars, .title]` changed
   nothing (byte-identical screenshots). `.toolbar(removing: .sidebarToggle)` on the split view
   had no effect either; the toggle stays, and it is the native control.
2. **Do not add `.fullSizeContentView`.** With it (plus `titlebarAppearsTransparent`) the toolbar
   collapses into an overflow chevron and the sidebar toggle disappears.
3. **Assigning the controller still zeroes the window** — frame 1×32 right after
   `window.contentViewController = host`, with every `sizingOptions` value tried (`[]`,
   `[.minSize]`, the default). `window.setContentSize(...)` right after the assignment restores
   it and it stays through page switches. Window-refactor fact 2 survives; its fact 1 (the default
   pins `minSize == maxSize`) does not apply to a split view: with the default options
   `maxSize` came back `(inf, inf)`. Still, `[.minSize]` is what the plan uses — it is the one
   option whose effect is wanted and nothing else.
4. **`sizingOptions = [.minSize]` gives the right minimum for free.** `window.minSize` became
   719×172 = the three column minimums plus separators; `.frame(minHeight: 480)` on the root
   raised `contentMinSize` to 719×480. A `setFrame` to 500×300 was clamped to 719×532 (frame,
   with toolbar). With `[]` instead, the window shrank to 500 while the root view stayed at 719 —
   clipped content. So `[]` is wrong here.
5. **Widths on resize.** At 1300 wide: sidebar 180 (ideal), detail 400 (its max), content 711 —
   the column without a max absorbs everything. At 960: content 371, detail 400. At the minimum:
   150 / 280 / 280. Dragging the window never pushes a column under its minimum.
6. **The middle column cannot be hidden while the sidebar stays.** `columnVisibility =
   .doubleColumn` on a three-column split view hides the *sidebar* (min width dropped to 561,
   toggle moved to the content column's edge, screenshot shows list + detail). This is the
   documented meaning of `.doubleColumn` and it settles the "pages without a list" question
   below.
7. **Selection survives hide/show.** With `page == .routing`, `window.close()` then
   `makeKeyAndOrderFront(nil)`: the same graph came back, the sidebar still showed Routing, and
   `.onChange(of: page)` fired exactly once for the whole run (the deliberate change). Column
   widths were unchanged across the hide.
8. **Frame autosave.** `window.center()` followed by `window.setFrameAutosaveName("…")`: on the
   first launch the frame stays centred; on the next launch the name restores the saved frame
   (1111×700 at 200,200 came back by itself, no `setFrameUsingName` needed).
9. **`.searchable` in a hosted window** puts the field in the toolbar, at the trailing end over the
   detail column, for both `.automatic` and `.toolbar` placement. It does not appear above the
   list.
10. **Column content fills the column height**: a `ScrollView` / grouped `Form` / `LazyVStack` log
    each scroll inside the column with no cap anywhere. The 300-line log at 371 wide wraps its
    lines and stays readable; widening the window gives the log the extra width (fact 5).

Not probed: the real `ConnectionView` at 300–400 wide; the look on macOS 14/15 (the probe ran on
macOS 26, whose sidebar is the inset "Tahoe" panel — on 14/15 it is the classic full-height
material); `@AppStorage` cross-view re-render (reasoned from AppKit's `UserDefaults` KVO, see
Step 1).

---

## Decisions

### The container: three-column `NavigationSplitView`, the connection panel always on the right

`NavigationSplitView(sidebar:content:detail:)` is the stock three-column container on macOS 13+
and it behaves in the hosted window (facts 1–5). Two shapes fit the owner's sentence; the probe
rules out a third.

**A — recommended, what this plan builds.** Sidebar = the four pages. Middle column = whatever
the sidebar selects: the server list, the Routing form, the Advanced form, the log. Detail column =
`ConnectionView` (power button, status, uptime, speeds, IP/location) **on every page**. The
connection panel is what the owner asked to see on the right; making it permanent means it needs
no page of its own, every sidebar item has natural middle-column content, and the split view is
used exactly as designed — no per-page layout switching, no custom container. Side benefits that
are real for a VPN client: Routing edits reconnect the tunnel and the status is in view while you
edit; the log sits next to the button that produces it.

Consequence: the sidebar item that today is "Connection" becomes **"Servers"** (`server.rack`,
the symbol the empty state already uses at `ServersView.swift:47`). Its middle column is the
server list; the button it used to sit above is now always visible. `ConnectionView` keeps its
name and content minus the embedded list.

**B — priced alternative.** Two-column `NavigationSplitView(sidebar:detail:)`; the Servers page's
detail is `HSplitView { ServersView; ConnectionView }`, every other page's detail is the page
alone at full width. Three columns on one page, two on the rest. Cost: the same deletions plus an
`HSplitView` with hand-set widths (`.frame(minWidth:idealWidth:)` on each pane, ~10 lines) and a
switch in the detail closure that swaps between the split pane and a full-width page. It gives
Routing/Advanced/Logs the whole width but hides the power button on three of four pages and adds a
second layout idiom. I would not ship it; it is one commit's worth of difference if the owner
prefers it (the sidebar, the window and the deletions are identical).

**Ruled out — "three columns, but hide the middle one on pages without a list".** The container
cannot do it: `.doubleColumn` hides the sidebar, not the content column (fact 6). The only way to
get there is two different split views swapped on selection, which rebuilds the sidebar on every
switch.

### `AppDelegate.makeWindow` becomes

```swift
private func makeWindow() {
    window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "WarpVeil"
    // Turns close() into orderOut, so the SwiftUI graph and its @State survive hiding.
    window.isReleasedWhenClosed = false

    let host = NSHostingController(rootView: ContentView(app: app))
    // The window owns its size; SwiftUI only contributes the minimum the columns need.
    host.sizingOptions = [.minSize]
    window.contentViewController = host
    // Assigning the controller collapses the content size to zero, whatever the sizing options.
    window.setContentSize(NSSize(width: 960, height: 640))
    window.center()
    // Restores the last frame on later launches; the first launch keeps the centred one.
    window.setFrameAutosaveName("MainWindow")
}
```

- Style mask gains `.resizable`; nothing else. No `.fullSizeContentView` (fact 2), no
  `titlebarAppearsTransparent`, no `toolbarStyle` — the split view installs the toolbar (fact 1).
- Minimum size: not set on the window. It comes from `sizingOptions = [.minSize]` plus the column
  minimums and the root's `.frame(minHeight: 480)` (fact 4). To change the minimum later, change
  the column widths, not the window.
- `sizingOptions = []` → `[.minSize]`. `[]` let the window shrink under the content (fact 4).
- Frame remembered: yes, `setFrameAutosaveName` (fact 8). One line, and a resizable window that
  forgets its size on every launch is worse than one that remembers it. `dev-run.sh` builds use
  their own bundle id, hence their own defaults domain, so the dev copy remembers its own frame —
  the `CLAUDE.md` dev-run note about recentring changes (Step 3). Column widths are **not**
  persisted — SwiftUI restores them only inside a `WindowGroup`; every launch starts at the ideal
  widths. Accepted; not worth an AppKit split-view autosave hack.
- `host.view.autoresizingMask` goes: the window sizes its `contentViewController`'s view itself
  (the probe never set it and resizing worked).
- Deleted: `fitWindow`, `windowWidth`, the closure argument to `ContentView`, the two comments
  about sizing options and the first measurement (`:56-57`, `:61-62`, `:66`).

### The sidebar: native `List(.sidebar)` with icon and label — recommended

```swift
List(selection: $page) {
    ForEach(Page.allCases, id: \.self) { page in
        Label(page.rawValue, systemImage: page.icon).tag(page)
    }
}
.listStyle(.sidebar)
.navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
```

Nine lines, stock look (screenshots: icon + label rows, native selection, the material and the
toggle button for free), keyboard navigation, VoiceOver, and the sidebar toggle collapses it to a
two-column layout when the user wants width. `Page.icon` stays in use. A non-optional
`Binding<Page>` compiles and works (probe); the user cannot deselect by clicking empty space,
which is what we want.

**Priced alternative — the 60-pt icon-only rail from the Electron screenshot.** It is
`PageTabBar` turned vertical: a `VStack` of plain `Button`s with `Image(systemName:)` in a fixed
`.frame(width: 60)` column (`.navigationSplitViewColumnWidth(60)`), custom selection fill,
`.help(page.rawValue)` for the tooltip. About 25 lines — the tab bar it replaces is 30 — and it
loses the label, the sidebar material, the native selection, keyboard focus, and it fights the
sidebar toggle (a collapsible 60-pt column looks broken either way, so the toggle would have to be
hidden, which the probe could not do). It is the Electron idiom, not the macOS one; I would ship
the list. If the owner wants the rail anyway, it is a one-file change to `ContentView` and the
column width — nothing else in this plan moves.

### Where today's pages go

| Sidebar item | Middle column | Detail column |
|---|---|---|
| Servers (`server.rack`) | `ServersView` — the subscription-grouped list with its own "SERVERS / + Add" header, add sheet, delete confirmation | `ConnectionView` |
| Routing (`arrow.triangle.branch`) | `RoutingView` — grouped `Form` | `ConnectionView` |
| Advanced (`gearshape`) | `AdvancedView` — grouped `Form` | `ConnectionView` |
| Logs (`doc.text`) | `LogView` — header + scrolling log | `ConnectionView` |

The Connection page splits along the line the prompt describes: its list is the middle column of
the Servers item, its power button / status / stats / location are the detail column — of every
item. `Page.connection` is renamed to `Page.servers`; `power` is no longer a page icon.

Column widths: sidebar 150 / 180 / 220; middle `min: 300, ideal: 380`, no max — it absorbs the
window's extra width (fact 5), which is what a list and a log want; detail `min: 300,
ideal: 340, max: 400` — the power button is 130 pt, the stat boxes are capped at 360, nothing in
it benefits from more. Window minimum ≈ 760 × 480 + toolbar; initial 960 × 640.

### Search: out of scope

Not asked for, and not a one-liner here: in the hosted window `.searchable` lands in the toolbar
over the *detail* column (fact 9), not above the list, so it would need its own `TextField` row in
`ServersView`; the filter has to keep a subscription's header visible when all its servers are
filtered out (otherwise refresh/delete vanish), and it interacts with the selection highlight.
That is ~15 lines inside the file that has just been through six review rounds, for a list that
holds ten rows today. Leave it out. If wanted later: `@State searchText` in `ServersView`, a
`TextField` under the "SERVERS" header, `sub.servers.filter { searchText.isEmpty ||
$0.name.localizedCaseInsensitiveContains(searchText) }` in the inner `ForEach`, headers always
shown. No plan change needed.

### What is deleted, and what replaces the caps

| Deleted | Where | Replaced by |
|---|---|---|
| `ContentHeightKey` | `ContentView.swift:23-31` | nothing — no measurement |
| `ContentView.onHeightChange` and the measuring modifiers | `ContentView.swift:35, :50-62` | the split view fills the window |
| `AppDelegate.fitWindow`, `windowWidth`, the closure in `makeWindow` | `WarpVeilApp.swift:27, :56-60, :71-93` | AppKit resizing + `setFrameAutosaveName` |
| `PageTabBar` | `ContentView.swift:80-109` | the sidebar `List` |
| `Page.icon` | `ContentView.swift:13-20` | **kept** — the sidebar `Label` uses it |
| `.frame(maxHeight: 700)` | `ContentView.swift:47-48` | nothing — the only cap left in the tree; each column scrolls to the window height (fact 10) |
| the stale "Fixed viewport" comment | `LogView.swift:51-52` | nothing |
| `sizingOptions = []`, `autoresizingMask`, `setContentSize` comment | `WarpVeilApp.swift:61-67` | `[.minSize]`; `setContentSize` itself stays (fact 3) |
| `Divider()` + `ScrollView { ServersView }` inside `ConnectionView` | `ConnectionView.swift:26-31` | `ServersView` in the middle column with its own `ScrollView` |

There are no other caps: `RoutingView` and `AdvancedView` lost theirs when `ContentView` took the
single cap, and `LogView` never had a frame, only the comment.

---

## Step 1 — `ServersView` owns its selection again

**Commit:** `Store the server selection in ServersView itself`

Behaviour-preserving preparation that shrinks Step 2's diff. Once the list and the power button
live in different columns, both views need the `selectedServerID` key: `ServersView` to write it,
`ConnectionView` to re-render on it.

### Changes

`Sources/ServersView.swift:6`: `@Binding var selectedServerID: String` →
`@AppStorage("selectedServerID") private var selectedServerID = ""`. Lines `:66` and `:68`
compile unchanged.

`Sources/ConnectionView.swift:29`: `ServersView(app: app, selectedServerID: $selectedServerID)` →
`ServersView(app: app)`. The `@AppStorage` at `:6` **stays** with a comment:

```swift
// Not read here, but it must stay: the power button's disabled state comes from
// app.selectedServer, which reads UserDefaults untracked — this is what re-renders it.
```

(Step 2 turns that into a real read.)

### Compiles because

`ServersView` has one call site (`ConnectionView.swift:29`), changed in the same commit.

### What could go wrong

- Two `@AppStorage`s on one key: each is backed by `UserDefaults` KVO, so a write through either
  one — or `removeSubscription`'s direct `removeObject` (`SubscriptionService.swift:101`) —
  re-renders both views. Standard SwiftUI behaviour; reasoned, not probed in this run. Test: tap a
  row, the power button enables; delete the selected subscription, it disables.

---

## Step 2 — The three-column shell

**Commit:** `Replace the paged window with a three-column split view`

One commit, because the pieces cannot compile apart: `ContentView` loses the closure parameter
`makeWindow` passes, `makeWindow` must become resizable the moment the height fitting goes, and
the split view needs the resizable window.

### `Sources/ContentView.swift`

Keep `Color.lavender` (`:3-5`). `Page` becomes:

```swift
enum Page: String, CaseIterable {
    case servers = "Servers"
    case routing = "Routing"
    case advanced = "Advanced"
    case logs = "Logs"

    var icon: String {
        switch self {
        case .servers: "server.rack"
        case .routing: "arrow.triangle.branch"
        case .advanced: "gearshape"
        case .logs: "doc.text"
        }
    }
}
```

Delete `ContentHeightKey` (`:23-31`) and `PageTabBar` (`:80-109`). `ContentView` becomes:

```swift
struct ContentView: View {
    var app: AppState

    @State private var page: Page = .servers

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Label(page.rawValue, systemImage: page.icon).tag(page)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } content: {
            pageView
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            ConnectionView(app: app)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        }
        .frame(minHeight: 480)
    }

    @ViewBuilder
    private var pageView: some View {
        switch page {
        case .servers: ServersView(app: app)
        case .routing: RoutingView(app: app)
        case .advanced: AdvancedView(app: app)
        case .logs: LogView(app: app)
        }
    }
}
```

`.frame(minHeight: 480)` is the window's minimum height via `sizingOptions = [.minSize]`
(fact 4); the width minimum falls out of the column minimums. `@State page` survives hide/show
(fact 7) and is not persisted — same as today.

### `Sources/ConnectionView.swift`

- Body (`:8-33`): delete `Divider()` and the `ScrollView { ServersView … }` (`:26-31`). Drop
  `.padding(.top, 28)` (`:11`) and give the `VStack` `.frame(maxWidth: .infinity,
  maxHeight: .infinity)` so the panel centres in the column (Happ centres its button too).
  Add `.padding(.horizontal, 20)` on `statsSection` so the boxes clear the column edges at the
  300-pt minimum. Paddings are taste; the frame is required (without it the column shows the
  content top-left).
- `statusSection` (`:65-79`) gains one line under the "Connected / Disconnected" text:
  `Text(app.selectedServer?.name ?? "No server selected").font(.system(size: 12)).foregroundStyle(.secondary)`.
  **Judgement call, flagged.** The list used to sit right under the button, so the button never
  had to say what it would connect to; in its own column it should. This also gives the
  `@AppStorage` from Step 1 a reason to exist beyond re-rendering. If the owner does not want the
  line, keep the property and the comment from Step 1 instead.
- Everything else (`powerButton`, `statsSection`, `statBox`, `locationSection`, `uptimeString`)
  unchanged.

### `Sources/ServersView.swift`

Body (`:10-25`): wrap the section in its own scroller —
`ScrollView { serverListSection.padding(.vertical, 12) }` with `.sheet` and
`.confirmationDialog` attached to the `ScrollView`. This is the wrapper `ConnectionView` provided
until now (`ConnectionView.swift:28-31`), moved back. Nothing else in the file changes.

### `Sources/WarpVeilApp.swift`

`makeWindow()` as written under Decisions. Delete `windowWidth` (`:27`) and `fitWindow` with its
comment (`:71-93`). `showWindow`, the lifecycle hooks, the status menu and `observeState` are
untouched.

### `Sources/LogView.swift`

Delete the comment at `:51-52`.

### Compiles because

`ContentView(app:)` is the only initializer `makeWindow` calls; `fitWindow` has no other caller
(`rg fitWindow Sources/` → `WarpVeilApp.swift:57, :59, :73` only); `Page.connection` is used only
inside `ContentView.swift` (`:15, :37, :68`); `PageTabBar` and `ContentHeightKey` are `private` /
file-local to `ContentView.swift`; `ServersView(app:)` already exists after Step 1. The split-view
API surface, the non-optional `List(selection:)`, `navigationSplitViewColumnWidth`, `Label` with
`systemImage`, `.frame(minHeight:)` and the `makeWindow` calls all compiled warning-free in Swift 5
mode against the 26.5 SDK at the macOS 14 target in the probes.

### What could go wrong

- **Look at the minimum width.** `ConnectionView` was laid out for 620; at 300 the stat boxes
  (`maxWidth: 360`) fill the column minus padding and the uptime text (30 pt monospaced) fits.
  `ServerRowView` at 300 truncates long names with `lineLimit(1)` — fine. `LogView` at 380 wraps
  (fact 10). If something looks cramped, raise the column minimums; do not add caps.
- **Toolbar.** The split view's toolbar shows the window title and the sidebar toggle. Nothing in
  the app adds toolbar items; `.searchable` is out of scope. If a future page adds `.toolbar`
  items they land in this toolbar — no bridging option is needed.
- **macOS 14/15 appearance.** The sidebar is the classic full-height material there instead of the
  inset panel seen in the macOS 26 probe. Same API, different chrome; nothing to do.
- **Detail column is never empty.** SwiftUI shows a placeholder in an empty detail; ours always
  has `ConnectionView`, so no `NavigationStack` / placeholder handling is needed.
- **The unified toolbar adds ≈ 52 pt** above the content: a 640-pt content rect gives a 724-pt
  frame (probe). The autosaved frame carries whatever the user ends up with.
- **Hidden window.** `app.pm.isRunning` and friends still drive `ConnectionView` while the window
  is hidden; the graph stays alive (window-refactor fact 6, re-confirmed by fact 7). Nothing to
  measure any more, so the "height changes while hidden" hazard from the old plan is gone.

---

## Step 3 — Documentation

**Commit:** `Document the three-column window`

`CLAUDE.md`:

- `:4` "A paged main window plus a menu-bar status item" → "A three-column main window plus a
  menu-bar status item".
- Architecture tree: `:60` `ContentView.swift` → "Page enum, the split view: sidebar, page column,
  connection panel"; `:61` `ConnectionView.swift` → "Power button, status, stats, location — the
  right column on every page"; `:62` `ServersView.swift` → "Server list grouped by subscription,
  add sheet — the Servers page".
- `:75` "Four pages: Connection, Routing, Advanced, Logs." → "Sidebar: Servers, Routing, Advanced,
  Logs. The connection panel is the right column on every page."
- `:123-124` "Each relaunch activates the app and recentres the window — there is no frame
  autosave" → "Each relaunch activates the app; the window comes back at its saved frame (the dev
  bundle id has its own defaults, so its frame is separate)".
- Key Decisions `:159-168`: replace "Window model" and "Height fitting" with one bullet:
  **Window model** — one resizable `NSWindow` from `AppDelegate`, hidden on close
  (`isReleasedWhenClosed = false`) so the graph survives; content is a three-column
  `NavigationSplitView`, the window owns its size. Traps: `NSHostingController.sizingOptions` is
  `[.minSize]` (the window minimum comes from the column minimums and the root's `minHeight`; `[]`
  lets the window shrink under the content); assigning the controller zeroes the content size, so
  `setContentSize` follows it; the split view installs its own toolbar — no `sceneBridgingOptions`,
  and `.fullSizeContentView` breaks the sidebar toggle; `.doubleColumn` hides the sidebar, not the
  middle column, so every sidebar item must have middle-column content. Frame is autosaved under
  `MainWindow`; column widths are not.

`README.md`: `:18-20` screenshot table → one row per column or per sidebar item (Servers /
Routing / Advanced / Logs, plus the connection panel); `:59-61` the three one-liners as above.

`plans/done/window-refactor.md`: prepend a two-line note (the way `servers-page.md` carries one)
saying that decisions 3–5 and the height fitting were replaced by this plan on the same day, so
nobody reads its verified facts 1–5 as current.

Then move this file to `plans/done/`, run `/code-review`, fix what it surfaces.

---

## Risks, ranked

1. **`ConnectionView` re-render after the split** (Steps 1–2). If the `@AppStorage` is ever
   removed from `ConnectionView` "because it is unused", the power button's disabled state and
   the selected-server line go stale. The comment and the visible use are the guard.
2. **Look and proportions** — column minimums and the centred panel are starting points; the
   probe used stand-ins for the real views.
3. **Sidebar toggle collapsing the sidebar** leaves two columns (page + panel) with no visible
   way back except the toggle in the toolbar — the same as every native app. Fine, but new.
4. **Owner prefers shape B or the icon rail.** Both are isolated changes (`ContentView` only, plus
   an `HSplitView` for B); the window, the deletions and the docs are the same.
5. **macOS 14/15 chrome** unverified on this machine.

## Out of scope, deliberately left alone

- Search / filtering of the server list (recipe above).
- Persisting the selected page or the column widths.
- Turning `ServersView`'s custom rows into a `List` with `Section`s — it would fit the middle
  column better, but it rewrites the file that just settled; separate plan if wanted.
- Toolbar items (add subscription, refresh all) — the header row inside `ServersView` keeps them.
- Reconnecting when the selection changes while connected.

## Validation record

Checked in this run:

- All 15 `Sources/*.swift` files, `project.pbxproj`, `Info.plist`, `dev-run.sh`, `README.md`,
  `CLAUDE.md` and all five `plans/done/*.md` read in full at `bedae21`; every line reference
  above re-checked with `rg -n` / `sed -n` before writing: `fitWindow` (`WarpVeilApp.swift:57,
  59, 73`), `windowWidth` (`:27, 47, 67, 74`), `sizingOptions` (`:63`), `setContentSize` (`:67`),
  `ContentHeightKey` / `onHeightChange` / `PageTabBar` (`ContentView.swift` only), `maxHeight`
  (`ContentView.swift:48, 61` only), `.connection` (`ContentView.swift:15, 37, 68`; the
  `LocationService.swift:39` hit is `info.connection`, unrelated), `selectedServerID`
  (`ConnectionView.swift:6, 29`; `ServersView.swift:6, 66, 68`; `AppState.swift:33, 43-48`;
  `SubscriptionService.swift:99-101`), `server.rack` (`ServersView.swift:47`), `lavender`
  (`ContentView.swift:4`, `ConnectionView.swift:43-56`, `ServersView.swift:151`), the `LogView`
  comment (`:51-52`), the `CLAUDE.md` lines (`:4, 60-62, 75, 123-124, 159-168`) and `README.md`
  lines (`:18-20, 59-61`).
- Probes (facts 1–10): two throwaway AppKit apps outside the repo, compiled warning-free in Swift 5
  mode at the macOS 14 target, exercising the hosted three-column split view for sizing options,
  minimum size, resize distribution, `.doubleColumn`, hide/show selection survival, frame
  autosave across two launches, `.searchable` placement, `.toolbar(removing:)`,
  `sceneBridgingOptions`, `.fullSizeContentView`, and screenshots of every state.
- Compile story per step walked against the call sites: Step 1 changes both ends of the one
  `ServersView` call; Step 2 deletes symbols that have no callers outside the files it edits and
  changes the one `ContentView` call.
- Canon: SwiftUI only inside the window, AppKit only in `WarpVeilApp.swift`; no packages; no
  protocol / generic / wrapper; `@Observable` and `@AppStorage` used as before, with the editing
  views holding the `@AppStorage`; net code goes down (≈ 90 lines deleted, ≈ 35 added). Scope
  additions, all flagged: the selected-server line in `ConnectionView`, frame autosave.
- The surviving behaviours (status item + menu, hide-on-close, terminate wait, reopen,
  auto-connect) live in code this plan does not touch (`WarpVeilApp.swift:95-183`,
  `AppState.bootstrap`).

Not verifiable without building the real target (do these first when implementing):

- The real `ConnectionView` and `ServersView` inside 300–400-pt columns; paddings and minimums
  may need a nudge.
- Two `@AppStorage` views re-rendering on one key (reasoned from KVO, not probed).
- Appearance on macOS 14 and 15.
