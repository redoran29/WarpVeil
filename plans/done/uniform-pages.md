# Uniform pages: one grouped look for Servers, Routing, Advanced and Logs

Status: implemented as written, in `07985ab`, `b98529c` and `4be5e10`. Written against `d9f2059`,
macOS 26.6.2, Xcode 26.5, Swift 5 mode, deployment target 14.0.

## Owner's ask

"Make all the tab interfaces uniform — the headers the same, the bodies more or less the same
too. Logs, for example, sticks out with its own look."

## What the four middle-column pages are today (verified)

- `Sources/RoutingView.swift:15-43` and `Sources/AdvancedView.swift:9-46` — `Form` +
  `.formStyle(.grouped)`; native `Section("Domains")` / `Section("Connection")` /
  `Section("Components")` headers; `Toggle` with a subtitle line; `LabeledContent` rows. This is
  the target look.
- `Sources/ServersView.swift:10-13` — `ScrollView { serverListSection.padding(.vertical, 12) }`.
  `serverListSection` (`:35-104`) is hand-rolled: a "SERVERS" caption at 11 pt medium, secondary,
  `tracking(1)` (`:38-41`); "Ping all" / `ProgressView` and "+ Add" as 13 pt medium indigo plain
  buttons (`:43-55`); the ping error as a red 11 pt line (`:60-68`); an empty state (`:70-84`);
  `subscriptionHeader` (`:106-149`) at 12 pt semibold + relative date + refresh/delete icon
  buttons, with its own paddings (`:146-148`); rows in a `VStack(spacing: 2)` under
  `.padding(.horizontal, 12)` (`:86-101`). `ServerRowView` (`:155-268`) draws its own selection
  as a `RoundedRectangle(cornerRadius: 10)` filled `Color.lavender.opacity(0.15)` behind
  `.padding(.horizontal, 12).padding(.vertical, 10)` (`:179-184`).
- `Sources/LogView.swift:7-51` — a 14 pt semibold "Log" title bar with copy/clear icon buttons
  (`:8-35`), a `Divider()` (`:37`), then `ScrollView { LazyVStack }` of 10 pt monospaced lines,
  newest first, `textSelection(.enabled)` (`:39-50`).
- `Sources/ContentView.swift:36-38` — the middle column is `pageView` under
  `.navigationSplitViewColumnWidth(min: 300, ideal: 380)`; `:45` pins the window to
  `minWidth: 180 + 300 + 300, minHeight: 480`. The right column (`ConnectionView`) is out of scope.

## Direction, and where the probes overruled it

Unify on the grouped look Routing and Advanced already have. Servers becomes a real grouped
`Form`. Logs does **not** — the probes below show a grouped `Form` is the wrong container for a
500-line log, so `LogView` keeps its `ScrollView`/`LazyVStack` and reproduces the grouped chrome
(header typography, card, insets) with measured numbers. Routing and Advanced do not change.

### Probe facts (all rendered in real `NSWindow`s from throwaway apps outside the repo)

1. **Grouped `Form` is eager on this OS.** `Form { Section { ForEach(0..<500) { Text.onAppear } } }`
   in a 380×620 window: `onAppear` fired **500** times. Every row exists at once.
2. **Row chrome cannot be removed.** `.listRowSeparator(.hidden)` and
   `.listRowInsets(EdgeInsets(0.5, 8, 0.5, 8))` on the rows produced a pixel-identical image to
   the defaults: one 10 pt monospaced line becomes a ~46 pt row with a separator.
3. **Update cost, 500 lines, two lines appended per update, 60 updates, layout + display
   forced each time** (median / max, main thread):
   - `Form` + one `Text` of all lines joined: **111 ms / 128 ms** (131 ms without `textSelection`;
     111 ms in a plain `ScrollView` — it is the 500-line `Text` layout, not the `Form`)
   - `Form` + one row per line: **66 ms / 160 ms**
   - today's `ScrollView { LazyVStack }`: **11 ms / 18 ms**
   `ProcessManager` polls the log every 0.25 s; a joined `Text` would spend ~45 % of the main
   thread on layout while the tunnel is chatty.
4. **`listRowBackground` is a no-op in a grouped `Form` on macOS** — `Color.lavender` at 0.15
   and 0.5 both rendered as the plain card. A `.background(RoundedRectangle)` on the row content
   renders (as an inset highlight inside the card), and so does a `.foregroundStyle` tint.
5. **A `Section` with a header and no rows renders the header only, with no card, and the next
   section's header drops to footer style** (regular weight, secondary colour). So every section
   must have at least one row.
6. **Grouped `Form` metrics** (column 380 wide, inside a `NavigationSplitView` shell like the app's):
   card inset 20 pt left/right, card top 46 pt below the column top, corner radius 10 (measured
   ≈12.5 px at 2× for both the reference and a `RoundedRectangle(cornerRadius: 10)`), row content
   inset 10 pt on every side inside the card, header text left edge at 30 pt, header text top at
   22.5 pt, header font = 13 pt **semibold** (`Text("Connection")` measured 70.5 pt wide; the same
   as `.system(size: 13, weight: .semibold)`; `.headline` is bold on macOS and measures 72.5).
   Card fill: `#F9F9F9` light / `#313131` dark on a `#FFFFFF` / `#282828` column.
   `Color(nsColor: .quaternarySystemFill)` measures `#F9F9F9` / `#303030` — the match.
   `.quaternary` is `#EBEBEB` / `#444444` (too dark), `.quinary` `#F5F5F5` / `#363636`,
   `.quinarySystemFill` `#FDFDFD` / `#2B2B2B`.
7. **A transparent page and a `Form` page sit on the same column background** (`#FFFFFF` /
   `#282828`), so `LogView` needs no background of its own.
8. **Custom section headers work as expected**: an `HStack { Text; Spacer(); buttons }` header
   spans the card width (30…350 at 380 wide), its `Text` inherits the header font, a
   `ProgressView().controlSize(.small)` fits, and explicit `.font(.system(size: 11))` on a child
   overrides the header font (the relative date renders regular, secondary).
9. **Width 300** (the column minimum): headers truncate with `lineLimit(1)`, the ping error wraps to
   two lines, rows truncate the name — nothing clips, nothing overflows. The shell's
   `contentMinSize` stayed 780×480 with grouped `Form`s in the middle column.
10. **`.toolbar` items on the content column** put the buttons in the window's title bar and bring
    the system sidebar toggle back — rejected: it changes the window chrome the canon fixed.
11. **`listSectionSpacing` is unavailable on macOS** (compile error), so section gaps cannot be
    tuned.
12. **Taps**: a synthetic `NSEvent` click fired a row's `onTapGesture` inside a grouped `Form`
    (once; a second synthetic run registered nothing, so the mechanism is flaky); accessibility
    "press" fired a `Button` inside a section header and a `Button` inside a row. A real mouse
    click on a header button was **not** verified — Orca could not target the probe window. First
    item of the eye check.

## Decisions

1. **Servers = grouped `Form`, one `Section` per subscription.** Section header: subscription name
   (inherits the header font — the explicit 12 pt semibold goes), relative date (11 pt, secondary,
   unchanged), `Spacer`, refresh / `ProgressView`, delete (unchanged).
2. **The page header rides on the first subscription's section header** (fact 5 forbids an empty
   top section; fact 10 rejects the toolbar). The first section's header is a
   `VStack(alignment: .leading, spacing: 10)` of the page header and that subscription's header.
   The page header is `HStack { Text("Servers"); Spacer(); Ping all | ProgressView; + Add }`
   plus the ping error line under it when `app.ping.error` is set. "Ping all" and "+ Add" drop
   their explicit 13 pt medium font and inherit the header font; they keep `.indigo`,
   `.buttonStyle(.plain)` and the `.help`.
3. **No subscriptions**: one `Section` whose header is the page header and whose single row is the
   existing empty state (icon, "No servers", "Add subscription"), unchanged inside.
4. **`ServerRowView` keeps its rounded selection background** — it is the only selection marker
   that renders inside a grouped section (fact 4). It becomes a highlight inside the card rather
   than a second card: `.padding(.horizontal, 8).padding(.vertical, 6)`, `cornerRadius: 6`. Flag,
   name, protocol line, ping label: untouched. The tap stays where it is
   (`.contentShape(Rectangle()).onTapGesture` in `ServersView`).
5. **Logs keeps `ScrollView { LazyVStack }`** (facts 1–3) and reproduces the grouped chrome with
   the numbers from fact 6: header `HStack` at 13 pt semibold, `.padding(.horizontal, 30)`,
   `.padding(.top, 20)`, `.padding(.bottom, 10)` (text top 22.5, card top 46 — matches the
   reference); the `ScrollView` gets `.background(RoundedRectangle(cornerRadius: 10)
   .fill(Color(nsColor: .quaternarySystemFill)))`, `.padding(.horizontal, 20)`,
   `.padding(.bottom, 20)`; the `LazyVStack` padding becomes 10 (the row inset). The copy and
   clear buttons move into the header row's trailing side unchanged (12 pt icons, secondary,
   plain, `.help`). The 14 pt title and the `Divider` go. One visible difference from a `Form`
   page: the card is fixed and its content scrolls, instead of the page scrolling — the right
   shape for a log that fills the column.
6. **Nothing else moves.** `RoutingView` and `AdvancedView` are already the target and stay
   byte-identical. `ContentView`, `ConnectionView`, the sidebar rail: untouched. No shared
   wrapper: the chrome is written once, in `LogView`, and `Form` does it for the other three.

## Behaviour that must survive unchanged (checked against the source)

- `ServersView`: `.onAppear { app.pingAll() }`, `.onChange(of: app.isBootstrapped)`,
  `.onDisappear { app.ping.cancel() }`, `.sheet(isPresented: $showAddSheet)`,
  `.confirmationDialog(... presenting: subscriptionToDelete)` (`:14-30`) — the same modifiers,
  now on the `Form`. `AddSubscriptionSheet` (`:272-371`) and `AddResult.message` (`:373-386`)
  untouched.
- `RoutingView`: `@AppStorage("bypassDomains")` / `@AppStorage("bypassEnabled")` (`:8-9`) and the
  reconnect debounce (`:50-57`) — file not touched.
- `AdvancedView`: passwordless toggle (`:16-23`) — file not touched.
- `LogView`: copy (`:13-15`) and clear (`:25`) actions, newest-first via
  `app.pm.logs.indices.reversed()` (`:41`), `textSelection(.enabled)` (`:44`) — same code, new
  chrome around it.

---

## Steps (each compiles on its own; one commit each)

### Step 1 — `Sources/LogView.swift`: grouped chrome around the existing log

Replace `body` (`:6-51`) with:

```swift
var body: some View {
    VStack(spacing: 0) {
        HStack {
            Text("Log")
            Spacer()
            Button {
                let text = app.pm.logs.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy")

            Button {
                app.pm.clearLogs()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear")
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, 10)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(app.pm.logs.indices.reversed(), id: \.self) { index in
                    Text(app.pm.logs[index])
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 0.5)
                }
            }
            .padding(10)
        }
        // A grouped Form cannot host the log (eager rows, fixed row chrome, ~110 ms per update
        // for a joined Text), so this copies its header and card metrics by hand.
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternarySystemFill)))
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}
```

The two buttons are the existing ones (`:12-32`), moved as-is; the `.font` on the `HStack`
does not reach the icons because their own `.font(.system(size: 12))` is inner. Deleted: the
`Text("Log").font(.system(size: 14, weight: .semibold))`, the `.padding(.horizontal, 12)
.padding(.vertical, 8)`, the `Divider()`, the `LazyVStack`'s `.padding(8)`.

Compile check: the shape typechecks in Swift 5 mode at the macOS 14 target
(`Color(nsColor: .quaternarySystemFill)` is macOS 14.0+).

### Step 2 — `Sources/ServersView.swift`: grouped `Form`, one section per subscription

Replace `body` (`:9-31`) and `serverListSection` (`:33-104`) with:

```swift
var body: some View {
    Form {
        if app.subs.subscriptions.isEmpty {
            Section {
                emptyState
            } header: {
                pageHeader
            }
        }

        ForEach(Array(app.subs.subscriptions.enumerated()), id: \.element.id) { index, sub in
            Section {
                ForEach(sub.servers) { server in
                    ServerRowView(
                        server: server,
                        isSelected: app.selectedServerID == server.id,
                        ping: app.ping.results[server.id]
                    )
                        .contentShape(Rectangle())
                        .onTapGesture { app.selectedServerID = server.id }
                }
            } header: {
                // A grouped section with no rows renders its header alone and drops the next
                // header to footer style, so the page header rides on the first subscription.
                VStack(alignment: .leading, spacing: 10) {
                    if index == 0 { pageHeader }
                    subscriptionHeader(sub)
                }
            }
        }
    }
    .formStyle(.grouped)
    .onAppear { app.pingAll() }
    // At launch the page appears before the feeds land, and pingAll() waits for them.
    .onChange(of: app.isBootstrapped) { app.pingAll() }
    .onDisappear { app.ping.cancel() }
    .sheet(isPresented: $showAddSheet) {
        AddSubscriptionSheet(subs: app.subs)
    }
    .confirmationDialog(
        "Delete \(subscriptionToDelete?.name ?? "")?",
        isPresented: Binding(
            get: { subscriptionToDelete != nil },
            set: { if !$0 { subscriptionToDelete = nil } }
        ),
        presenting: subscriptionToDelete
    ) { sub in
        Button("Delete", role: .destructive) { app.removeSubscription(sub.id) }
    }
}

// MARK: - Headers

private var pageHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
            Text("Servers")
            Spacer()
            if app.ping.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Ping all") { app.pingAll() }
                    .foregroundStyle(.indigo)
                    .buttonStyle(.plain)
                    .help("Measure every server")
            }
            Button("+ Add") { showAddSheet = true }
                .foregroundStyle(.indigo)
                .buttonStyle(.plain)
        }

        if let error = app.ping.error {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private var emptyState: some View {
    VStack(spacing: 8) {
        Image(systemName: "server.rack")
            .font(.system(size: 28))
            .foregroundStyle(.quaternary)
        Text("No servers")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        Button("Add subscription") { showAddSheet = true }
            .font(.system(size: 12))
            .foregroundStyle(.indigo)
            .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
}
```

`subscriptionHeader(_:)` (`:106-149`) keeps its `HStack(spacing: 6)` and every child, minus
`.font(.system(size: 12, weight: .semibold))` on the name (`:109`, the header font applies) and
minus the three trailing paddings (`:146-148`, the section supplies them). Its comment about
manual subscriptions (`:112-113`) stays.

`ServerRowView` (`:179-184`): `.padding(.horizontal, 12)` → `8`, `.padding(.vertical, 10)` → `6`,
`cornerRadius: 10` → `6`. Nothing else in the row changes.

Deleted: the "SERVERS" caption (`:38-41`), the buttons' explicit fonts (`:47, :53`), the error
line's frame and paddings (`:65-67`), the `VStack(spacing: 2)` and `.padding(.horizontal, 12)`
(`:86, :101`), `.padding(.vertical, 12)` on the old `ScrollView` (`:12`). `serverListSection`
and the `// MARK: - Server List` go; `// MARK: - Server Row` and `// MARK: - Add Subscription
Sheet` stay.

Compile check: the `Section { } header: { }` form, `ForEach(Array(...enumerated()),
id: \.element.id)` with an `(index, sub)` closure, `if index == 0 { … }` inside a `VStack`
header, `.contentShape(Rectangle()).onTapGesture` on a row, all typecheck in Swift 5 mode at
the macOS 14 target. Symbols used exist: `app.subs.subscriptions` (`SubscriptionService.swift`),
`app.subs.refreshingIDs` (`:19`), `app.ping.isRunning` / `.error` / `.results`
(`PingService.swift:26-28`), `app.selectedServerID` (`AppState.swift:26`), `app.pingAll()`
(`:117`), `app.isBootstrapped` (`:21`), `app.removeSubscription` (`:109`),
`Subscription.isManual` / `.lastUpdated` (`Models.swift:50, 53`).

### Step 3 — `CLAUDE.md`

- `:62` `├── ServersView.swift          # Server list grouped by subscription, add sheet — Servers page`
  → `├── ServersView.swift          # Grouped Form, one section per subscription, add sheet`
- `:65` `├── LogView.swift              # VPN log with copy and clear`
  → `├── LogView.swift              # VPN log with copy and clear, drawn as a grouped-Form card`
- Key Decisions, new bullet after **Window model** (`:166-175`):
  `- **Page chrome**: every middle-column page has the grouped-\`Form\` look. Servers, Routing
  and Advanced are real \`Form { Section }\`s. Logs is not: on macOS a grouped \`Form\` builds
  all 500 rows at once, its row separators and insets cannot be removed, and one \`Text\` of
  all lines costs ~110 ms per log update against ~11 ms for the \`LazyVStack\` — so \`LogView\`
  keeps \`ScrollView { LazyVStack }\` and copies the Form's metrics by hand: 13 pt semibold
  header at 30 pt, card 20 pt from the edges, corner radius 10, row inset 10,
  \`quaternarySystemFill\`. A change to one must be made to the other. Servers' page header
  ("Servers", Ping all, + Add) lives on the first subscription's section header because an
  empty section breaks the next header's style`
- Gotchas (`:214-228`), two new lines after `:228`:
  `- Inside a grouped \`Form\` on macOS, \`listRowBackground\`, \`listRowSeparator\` and
  \`listRowInsets\` are no-ops, and \`listSectionSpacing\` does not exist — draw row state on
  the row's own content`
  `- A grouped \`Section\` with a header and no rows renders the header alone and the next
  section's header in footer style — keep every section non-empty`

`README.md:64-67` and `:19-21` describe the pages at a level this change does not alter; no edit.

### Close

Move this file to `plans/done/`, run `/code-review`, fix what it surfaces.

---

## What the user will see change

- **Logs**: a "Log" header in the same face and position as "Connection" on Advanced, the copy
  and clear icons at its trailing edge, the log inside a rounded card with the Form's inset and
  fill. Lines, size, order, selection, copy, clear: as before. Empty log: header over an empty
  card.
- **Servers**: the "SERVERS" caption becomes a "Servers" header in the section-header face, with
  "Ping all" and "+ Add" at its trailing edge in that face (indigo); each subscription is a
  card under its own header (name in the header face, date, refresh, delete); the selected row
  is a tighter lavender highlight inside the card. The ping error sits under the page header,
  red 11 pt as before. Empty state: page header over one card with the icon, "No servers",
  "Add subscription".
- **Routing, Advanced, the connection panel, the sidebar**: pixel-identical.

## Eye check

`./dev-run.sh`, then, in order:

1. Servers: click "Ping all", "+ Add", a subscription's refresh and delete icons — all four are
   buttons inside section headers, the one thing the probes could not click with a real mouse.
   Then click two rows: the highlight moves, the connection panel follows.
2. Switch Advanced ↔ Logs and Advanced ↔ Servers: header baselines, header left edges (30 pt)
   and card left edges (20 pt) should not shift.
3. Logs while connected: lines arrive at the top, no lag; drag-select across lines, Cmd+C; the
   copy icon; the clear icon.
4. Drag the window to its minimum width: at 300 pt the Servers headers truncate with an
   ellipsis, the ping error wraps, nothing clips; the log card keeps its 20 pt margins.
5. System Settings → Appearance → Dark: the log card and a Servers card should read as the
   same grey (measured `#303030` vs `#313131`).

## Validation record

- Read in full: `CLAUDE.md`, `README.md:15-25, 60-70`, `Sources/ContentView.swift`,
  `Sources/LogView.swift`, `Sources/RoutingView.swift`, `Sources/AdvancedView.swift`,
  `Sources/ServersView.swift`, `Sources/WarpVeilApp.swift:40-75`, `plans/done/servers-page.md`,
  `plans/done/three-column.md` (its "Out of scope" item "Turning ServersView's custom rows into a
  List with Sections" is what this plan does). Symbols re-checked with `rg`: `AppState.swift`
  (`isBootstrapped :21`, `selectedServerID :26`, `pingAll :117`, `routingChanged :124`),
  `PingService.swift` (`results :26`, `error :27`, `isRunning :28`, `PingResult :5-8`),
  `SubscriptionService.swift` (`refreshingIDs :19`, `removeSubscription :97`),
  `Models.swift` (`isManual :50`, `lastUpdated :53`), `ProcessManager.swift` (`logs :8`,
  `clearLogs :620`, trim to 500 past 600 `:641-642`), project settings (`SWIFT_VERSION = 5.0`,
  `MACOSX_DEPLOYMENT_TARGET = 14.0`, `ARCHS = arm64`).
- Probes: seven throwaway apps in the session scratchpad (`probe`, `probe2`, `probe3`,
  `timing2`, `metrics3` + `scan`, `rowinset`, `tap2`/`live`), compiled with
  `swiftc -swift-version 5 -target arm64-apple-macosx14.0`, rendered into real `NSWindow`s and
  captured to PNG; the numbers in "Probe facts" are read from those captures by pixel scan.
  Step 1's and Step 2's view shapes typecheck under the same flags. `Sources/` was never
  modified; `git status` is clean.
- Checked in the built app (window captures, pixel-scanned): the header glyphs of Servers, Logs
  and Advanced start within 1-2 px of each other (x 437/438/437, y 110/112/111 at 2x), the cards
  share their left and right edges, and the hand-drawn log card reads `#F8F8F8` against the
  Form's `#F7F7F7`. The selected server row renders as a lavender highlight inside the card, and
  the connection panel follows the selection.
- Not verified: a real mouse click on a `Button` inside a section header (eye check 1); the
  look on macOS 14/15 — every probe ran on 26.6.2, and the grouped `Form` internals differ
  between releases (the eager-row finding in particular is an observation on this OS, not a
  contract).
