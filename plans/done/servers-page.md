# Servers page: merge Connection + Servers, fix subscription management

> Implemented. One later change is not reflected below: server ping was removed entirely
> (commit `58cd4b6`), so the ping details in Steps 2-4 describe code that no longer exists.

Status: plan, not yet implemented. Written against the working tree at `bc5b1a2` (window-refactor
Steps 1-5 committed; its Step 6, documentation, still open and not part of this plan).

## Owner decisions (fixed)

1. One page instead of two: the power button on top, the server list underneath, **grouped by
   subscription** — subscription as section header, its servers nested below (Happ layout).
2. Subscription management (refresh one, delete one, last-updated time) lives on the subscription
   header, visible, not in a context menu.
3. Three bugs fixed: duplicate subscriptions, server identity lost on refresh, invisible management.

Out of scope and untouched: `ProcessManager` (sudo / PID / passwordless / sleep-wake), routing and
bypass, the engine split, new subscription formats, the window shell, `PageTabBar`, the
height-fitting mechanism (`ContentHeightKey`, `AppDelegate.fitWindow`).

---

## Bug claims, checked against the source

### 1. Duplicate subscriptions — confirmed

`SubscriptionService.addFromURL` (`Sources/SubscriptionService.swift:72-95`) appends
unconditionally: the direct-URI branch at `:84`, the URL branch at `:92`. `addManualConfig`
(`:663`) appends too, but a pasted JSON blob has no natural key, so it is left alone.

The real file `~/.config/warpveil/subscriptions.json` (52 KB, not modified) holds 4 subscriptions:
three with `url = https://sub-remnawave.comradeserver.com/gv-bQoTr3sCFXXcf` (ids `D3DA3D83…`,
`56B88F13…`, `73CF2A54…`, 9 servers each, identical names and addresses) and one manual
(`Luxury`, `url = ""`, `isManual = true`, 1 server). 28 rows on screen, 10 belong.

On-disk shape, per subscription: `id` (UUID string), `name`, `url`, `isManual`, `engine`,
`lastUpdated` (Double, seconds since reference date — `JSONEncoder` default), `servers`. Per server:
`id` (UUID string), `name`, `protocolType`, `address` (`host:port`), `engine` (may be absent —
`Server.engine` is optional), `config` (the full JSON as a string).

### 2. Server identity does not survive a refresh — confirmed

`Server.init` (`Sources/Models.swift:16-23`) does `self.id = UUID()` at `:17`; every parser
(`parseVlessURI :266`, `parseVmessURI :314`, `parseSingBox :587`, `parseXray :640`) goes through it.
`refreshSubscription` (`:97-123`) replaces the whole array at `:107` and `:117`.
`AppState.bootstrap()` (`Sources/AppState.swift:62-70`) awaits `subs.refreshAll()` at `:65` on every
launch, then checks `selectedServer != nil` at `:67`. `selectedServer` (`:32-34`) matches
`$0.id.uuidString` against the `selectedServerID` default, which still holds the UUID minted by the
previous launch. So: the window opens with the row highlighted (ids from disk), the refresh lands,
the highlight vanishes, autoConnect never fires. Also a side effect the report did not mention:
`ServersView.pings` (`Sources/ServersView.swift:10`) is keyed by the same UUID, so pings measured
before the launch refresh are orphaned too.

### 3. Subscription management is invisible — confirmed

Refresh and delete exist only in the `.contextMenu` at `ServersView.swift:73-84`, reachable by
right-clicking a **server** row. `Subscription.lastUpdated` (`Models.swift:33`) is written at
`Models.swift:42` and `SubscriptionService.swift:83,108,118,662` and read nowhere
(`rg lastUpdated Sources/` shows only writes).

One correction to the report's framing: `refreshSubscription` has no re-entrancy guard, so a
visible refresh button makes double-clicks spawn two concurrent fetches that both write the array.
Step 3 adds the guard together with the button.

---

## Decisions with reasons

**Server identity** = `"\(protocolType)|\(address)|\(name)"`, a computed `String`, not stored.
Intrinsic to what the provider sent, stable across refreshes, readable in `UserDefaults`.
Rejected: a hash of `config` — also deterministic (`serializeJSON` uses `.sortedKeys`), but any
change to the config builders in a future release would silently drop everyone's selection once;
`address` alone — one host:port can legitimately carry two transports. Cost of including `name`: a
provider that renames a node drops the selection for it. Acceptable.

**Codable compatibility** falls out of "computed, not stored": synthesized `Codable` covers stored
properties only, `JSONDecoder` ignores unknown keys, so old files decode unchanged and the stale
server `id` key is simply not read; the next `save()` writes files without it. `Subscription.id`
stays a stored UUID — it is what `refreshSubscription` / `removeSubscription` take, and it is
persisted. Verified on a copy of the real shape (see Validation).

**Migration** is a filter in `load()` that keeps the first subscription per non-empty `url` and
saves if anything was dropped. Idempotent, three lines, no version flag. It runs on every launch,
which is deliberate: the file is shared across builds (`dev-run.sh` copies included), so a
one-shot flag would have to be shared too. After the add-guard lands the filter is a no-op, and
it is also the cheapest safety net against a hand-edited file.

**Selected server when its subscription is deleted or a refresh drops it: leave the default
alone.** `AppState.selectedServer` is a lookup; a `selectedServerID` with no match is inert —
`connect()` refuses (`AppState.swift:73-76`), autoConnect refuses (`:67`), no row highlights. And
it self-heals: a node the provider dropped for a day comes back selected when it reappears, a
re-added subscription restores the selection. A running tunnel is unaffected either way —
`ProcessManager` reconnects from its own `lastConnection` (`ProcessManager.swift:316,528-546,279-297`),
never from the list. The one thing that changes: the power button is disabled while disconnected
with nothing selected (Step 4), because the picker that used to show "nothing selected" is gone
and `[Error: no server selected]` only reaches the Logs page.

**What happens to the current-server picker:** deleted. The grouped list *is* the picker; two
controls editing one key on one page would fight for the eye.

**Stats and logs:** uptime, speed boxes and IP/location stay in the page header under the power
button (Happ puts speed there too). Logs stay on the Logs page; `LogView.swift` is untouched.

**Delete confirmation:** yes, a `confirmationDialog`. Today delete is two clicks deep behind a
right-click; on a visible trash button one slip destroys a subscription whose URL is not
recoverable from the UI. Owner may drop it (about 8 lines).

**Height cap: `.frame(maxHeight: 700)` on the merged page's root `VStack`**, not on the list.
Capping the list alone would let the window grow past 880 pt when connected (header ≈ 400 pt with
uptime and stats). A page-level cap makes the header fixed and the list absorb the difference.
Measured in a probe (see Validation): with the cap on the VStack, the root reports
`min(content, cap)` and the inner `ScrollView` shrinks to `cap − header`. Numbers: window =
700 + tab bar 65 + title bar ≈ 793 pt, which fits a 900-pt display with the menu bar and Dock;
visible rows ≈ 8 disconnected, ≈ 5 connected. Every other page keeps its existing cap
(`RoutingView.swift:43`, `AdvancedView.swift:47`: 520; `LogView.swift:53`: fixed 440).

**File and type names:** `ServersView.swift` / `ServersView` stay. It stops being a page and
becomes the list section embedded in `ConnectionView`; the name still describes what it is, and
keeping it avoids touching `project.pbxproj` (hand-maintained, file refs at `:20,42,85,204`).

---

## Step order and why

Dedupe (Step 1) before identity (Step 2): with the real file, changing identity first would put 27
rows with 9 distinct ids into the flat `ForEach(allServers)` at `ServersView.swift:65` and the
picker at `ConnectionView.swift:103` — SwiftUI's undefined-results warning, wrong highlights.
Collapsing the file first means Step 2 lands on clean data. Model and service work (1-2) before UI
(3-4) so each UI commit builds on a stable `Server.id`. The grouped list (3) lands while the page is
still separate, so the merge (4) is a pure composition diff.

---

## Step 1 — Reject duplicate subscriptions, collapse existing ones

**Commit:** `Reject duplicate subscriptions and collapse duplicates on load`

### Changes — `Sources/SubscriptionService.swift` only

`load()` (`:48-53`):

```swift
func load() {
    guard let data = try? Data(contentsOf: filePath),
          let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
    else { return }
    var seenURLs = Set<String>()
    subscriptions = decoded.filter { $0.url.isEmpty || seenURLs.insert($0.url).inserted }
    if subscriptions.count != decoded.count { save() }
}
```

`addFromURL` (`:72-95`):

- URL branch (`:89-94`): before creating the subscription,
  `if let existing = subscriptions.first(where: { $0.url == trimmed }) { await refreshSubscription(existing.id); return }`.
  Re-adding a known URL refreshes it — that is what the user meant.
- Direct-URI branch (`:76-87`): after parsing, `guard !subscriptions.contains(where: { $0.servers.contains { $0.id == server.id } }) else { return }`.
  **Written for Step 2's id.** In Step 1 `Server.id` is still a fresh UUID, so this guard compiles
  but never matches; it starts working one commit later. Alternative: add it in Step 2 instead —
  either way; the plan puts all add-guards in one place.

Delete `addSubscription(_:)` (`:60-63`): no caller anywhere (`rg "addSubscription\("` finds only the
sheet's private `addSubscription()` at `ServersView.swift:321,333,343`). Dead code, same file, same
theme.

### Compiles because

Pure additions inside existing functions plus one deleted unused function.

### What could go wrong

- Exact-string match on `url`. `fetchData` (`:133-155`) prepends `https://` to a bare host, so
  `example.com/x` and `https://example.com/x` are the same feed but not the same string. Accepted;
  normalising URLs is more code than the bug is worth. Trailing whitespace is already trimmed.
- Which copy survives: the **first**. The real file's three copies were refreshed within half a
  second of each other and hold identical servers; order is what the user saw. Result on the real
  file: `D3DA3D83…` (remnawave) + `488E646A…` (Luxury). Verified in the probe.
- Absent file (first run, or `dev-run.sh` on a fresh machine): `try? Data(contentsOf:)` is nil,
  the guard returns, nothing is written. Corrupt file: decode fails, same. Verified.
- The sheet gives no feedback that a URL was a duplicate; it closes and the existing header shows
  its spinner (Step 3) and a fresh time. Acceptable.

---

## Step 2 — Stable server identity

**Commit:** `Derive server identity from protocol, address and name`

### Changes

`Sources/Models.swift`:

```swift
struct Server: Codable, Identifiable {
    var name: String
    var protocolType: String
    var address: String
    var config: String
    var engine: Engine?

    var id: String { "\(protocolType)|\(address)|\(name)" }
}
```

The explicit `init` (`:16-23`) goes: it existed only to mint the UUID, and the memberwise init has
the same labels in the same order with `engine` defaulting to `nil` — all four parser call sites
compile unchanged. Reorder nothing.

`Sources/AppState.swift`: `:33` and `:49` — `$0.id.uuidString == selectedServerID` →
`$0.id == selectedServerID`.

`Sources/ConnectionView.swift:104`: `.tag(server.id.uuidString)` → `.tag(server.id)`.

`Sources/ServersView.swift`: `:10` `pings: [UUID: Int]` → `[String: Int]`; `:68` and `:72` drop
`.uuidString`. `:101` (`pings[server.id] = ms`) and `:145` (`$0.id == server.id`) compile as they
are.

### Compiles because

Every `uuidString` on a `Server` is listed above; `rg uuidString Sources/` must come back empty
after the change (the only other UUIDs are `Subscription.id`, which never used `uuidString`).
`Picker` tags and `@AppStorage("selectedServerID")` were already `String`.

### What could go wrong

- **One-time loss of selection on upgrade.** The stored `selectedServerID` is an old UUID; it
  matches nothing until the user clicks a row once. autoConnect stays quiet for that one launch.
  Mapping old UUID → new id in `load()` is possible (decode the old key through a throwaway
  struct) and not worth it: the selection is lost on every launch today anyway.
- **Duplicate ids inside one subscription** (same protocol, address and name twice in one feed)
  would hit SwiftUI's duplicate-id warning in the nested `ForEach`. Not seen in the real data;
  a provider that does this has a broken feed. Not guarded.
- **Same server in two subscriptions** (e.g. a manual `vless://` that also appears in a feed):
  both rows highlight, `selectedServer` picks the first. Same server, same config — harmless.
  Until Step 4 removes the flat picker, this case would also trigger the duplicate-id warning
  there; the real file has no such pair (`Luxury` is `…:443`, the feed's `Luxury - Atlanta` is
  `…:8443`).
- Files written by this build lack the server `id` key. An **older** build reading them would
  fail to decode `Server` (its `id` is non-optional) and `load()` would leave `subscriptions`
  empty — not lost, just invisible until the newer build runs again. The file is shared across
  builds (`CLAUDE.md`, dev-run section); the owner runs one version at a time. Flagged, not
  mitigated.
- Pings now survive the launch refresh (keyed by the stable id) — a fix, listed so nobody
  "fixes" it back.

---

## Step 3 — Grouped list with subscription headers

**Commit:** `Group servers by subscription and show refresh, delete and last update`

Still its own page in this commit; only the list body changes.

### Changes

`Sources/SubscriptionService.swift`:

- `var refreshingIDs: Set<UUID> = []` next to `subscriptions` (`:6`).
- `refreshSubscription` (`:97-123`): extend the guard with `!refreshingIDs.contains(id)`, then
  `refreshingIDs.insert(id); defer { refreshingIDs.remove(id) }` before the first fetch. Both
  fetch strategies stay as they are. `refreshAll` (`:125-129`) picks the spinners up for free at
  launch.

`Sources/ServersView.swift`, `serverListSection` (`:32-90`):

- Keep the `SERVERS / + Add` header row (`:34-46`) and the empty state (`:48-62`). The empty test
  becomes `app.subs.subscriptions.isEmpty` — a subscription with zero servers (feed down at add
  time) must still show its header so it can be refreshed or deleted.
- Replace the flat `ForEach(allServers)` (`:64-87`) with

  ```swift
  VStack(spacing: 2) {
      ForEach(app.subs.subscriptions) { sub in
          subscriptionHeader(sub)
          ForEach(sub.servers) { server in
              ServerRowView(server: server,
                            isSelected: selectedServerID == server.id,
                            ping: pings[server.id])
                  .contentShape(Rectangle())
                  .onTapGesture { selectedServerID = server.id }
          }
      }
  }
  .padding(.horizontal, 12)
  ```

  The `.contextMenu` (`:73-84`) and `subscriptionFor` (`:143-147`) go — the header knows its
  subscription.
- New `subscriptionHeader(_ sub: Subscription) -> some View`: `HStack` with the name (12 pt
  semibold, `lineLimit(1)`), for non-manual subscriptions the time
  (`Text(updated.formatted(.relative(presentation: .named)))`, 11 pt secondary — renders
  "5 hours ago"), `Spacer()`, then for non-manual subscriptions either
  `ProgressView().controlSize(.small)` while `app.subs.refreshingIDs.contains(sub.id)` or a plain
  `arrow.clockwise` button calling `Task { await app.subs.refreshSubscription(sub.id) }`, and a
  plain `trash` button setting `subscriptionToDelete = sub`. Padding: horizontal 12, top 14,
  bottom 6. Manual subscriptions show name + trash only: they cannot refresh, and their
  `lastUpdated` is the add time, which "updated … ago" would misdescribe.
- `@State private var subscriptionToDelete: Subscription?` and, on the root, next to the existing
  `.sheet` (`:22-24`):

  ```swift
  .confirmationDialog(
      "Delete \(subscriptionToDelete?.name ?? "")?",
      isPresented: Binding(get: { subscriptionToDelete != nil },
                           set: { if !$0 { subscriptionToDelete = nil } }),
      presenting: subscriptionToDelete
  ) { sub in
      Button("Delete", role: .destructive) { app.subs.removeSubscription(sub.id) }
  }
  ```

- `measurePings` (`:94-104`) keeps iterating `allServers`; `allServers` (`:12-14`) stays for that
  one use.

### Compiles because

`ServersView(app:)` keeps its signature and its own `@AppStorage`; `ContentView` is unchanged.
`subscriptionFor` has no other caller. The header/dialog surface typechecks in Swift 5 mode against
the macOS 14 SDK (probe, see Validation).

### What could go wrong

- The relative time does not tick on its own; it re-renders with any state change on the page
  (refresh, selection, ping arrival). A stale "3 minutes ago" for a while is fine.
- A refresh that fails leaves `lastUpdated` untouched (both strategies `return` only on success,
  `:105-121`), so the time honestly says when data last arrived. There is still no error surface
  for a failed refresh — same as today, not added.
- `ForEach(app.subs.subscriptions)` re-renders on every `subscriptions` mutation, including the
  per-subscription `save()`s during `refreshAll`. The `VStack` is not lazy; at tens of rows that
  is nothing.

---

## Step 4 — Merge the Servers page into Connection

**Commit:** `Merge the Servers page into Connection`

### Changes

`Sources/ContentView.swift`: `Page` (`:3-19`) loses `case servers` (`:5`) and its icon (`:13`);
`pageView` (`:60-75`) loses the `.servers` case (`:65-66`). Four pages: Connection, Routing,
Advanced, Logs. `.connection` keeps its name and `power` icon.

`Sources/ConnectionView.swift`:

- Delete `allServers` (`:10-12`), `serverPicker` (`:95-109`) and its call (`:32-34`).
  `@AppStorage("selectedServerID")` (`:6`) **stays** — it is now the single owner of the key and is
  passed down as a binding.
- Body (`:14-36`) becomes

  ```swift
  VStack(spacing: 0) {
      powerButton.padding(.top, 28).padding(.bottom, 10)
      statusSection.padding(.bottom, 16)
      if app.pm.isRunning {
          statsSection.frame(maxWidth: 360).padding(.bottom, 20)
      }
      locationSection.padding(.bottom, 20)
      Divider()
      ScrollView {
          ServersView(app: app, selectedServerID: $selectedServerID)
              .padding(.vertical, 12)
      }
  }
  .frame(maxHeight: 700)
  ```

- `powerButton` (`:40-63`) gets `.disabled(!app.pm.isRunning && app.selectedServer == nil)` after
  `.buttonStyle(.plain)`. The view re-renders on selection because it owns the `@AppStorage`;
  `app.selectedServer` is read fresh on that render (the contract stated at `AppState.swift:26-30`).
  **Judgement call:** the only behavioural addition in this plan that no bug forces. Without it
  the failure is a log line on another page. Drop the one modifier if unwanted.

`Sources/ServersView.swift`:

- `@AppStorage("selectedServerID") private var selectedServerID = ""` (`:8`) →
  `@Binding var selectedServerID: String`.
- Root (`:16-28`): drop the `ScrollView` wrapper, the `.padding(.vertical, 12)` and
  `.frame(maxHeight: 560)`; the body is the `VStack` that was `serverListSection`, with `.sheet`,
  `.confirmationDialog` and `.task` attached to it. Modifiers on a view inside the parent's
  `ScrollView` present normally.

### Compiles because

`ServersView` has exactly one call site (`ContentView.swift:66`), which is deleted in this commit;
the new one in `ConnectionView` passes both arguments. `Page` is `CaseIterable`; `PageTabBar`
iterates `allCases` and needs no change.

### What could go wrong

- **Height.** The cap on the root `VStack` was probed with a stand-in header; the real header is
  ≈ 30 pt taller when connected (stat boxes), so the connected list viewport is ≈ 280 pt. If that
  feels cramped, tighten the header (28 → 20 top padding, 20 → 12 under location) before raising
  the cap; 700 already puts the window at ≈ 793 pt.
- **The 5→4 transition.** `@State private var page` defaults to `.connection`; no stored page
  selection exists, so nothing can point at the removed case.
- `.task` on `ServersView` fires when the view appears; the page is the default page, so pings
  start at launch, before `refreshAll` lands. With stable ids they stay valid. Servers that first
  appear after the refresh get no ping until the page is re-entered — existing behaviour, noted.
- Page-local `@State` (`showAddSheet`, `subscriptionToDelete`, `pings`) resets when switching
  pages, as for every page since the window refactor.

---

## Close

- Move this file to `plans/done/`; run `/code-review`; fix what it surfaces (canon, Workflow §3).
- Documentation: window-refactor Step 6 rewrites the `CLAUDE.md` Architecture tree and the README
  page table. Whichever lands second updates the other's text: after this plan `ConnectionView` =
  "power button, status, uptime, speeds, IP/location, embeds ServersView" and `ServersView` =
  "server list grouped by subscription, headers with refresh/delete/last update, ping, add
  sheet"; four pages, not five. No separate docs step here — one rewrite, not two.

---

## Risks, ranked

1. **Merged page height** (Step 4) — mechanism probed, exact numbers not; 700 is a starting
   point, and the fallback (tighten header paddings) is one-line.
2. **Identity change hits every existing selection once** (Step 2) — inherent; documented.
3. **Older builds cannot read files written after Step 2** — only matters if the owner runs an
   old build against the shared file; nothing is lost, the old build just shows no servers.
4. **Duplicate ids across subscriptions** — harmless after Step 4, a SwiftUI warning between
   Steps 2 and 4 for data the owner does not have.

---

## Validation record

Checked in this run:

- All 15 `Sources/*.swift` files read in full, plus `project.pbxproj`, `CLAUDE.md`,
  `plans/window-refactor.md`, and the real `~/.config/warpveil/subscriptions.json` (structure only;
  `config` strings elided; not modified). Every line reference above was taken from that read
  and re-checked with `rg` / `sed -n` before writing: `uuidString` (AppState 33, 49;
  ConnectionView 104; ServersView 68, 72), `subscriptionFor` (ServersView 74, 143), `contextMenu`
  (73), `lastUpdated` (Models 33, 42; SubscriptionService 83, 108, 118, 662 — writes only),
  `addSubscription(` (SubscriptionService 60; ServersView 321, 333, 343 — the sheet's private
  method), `maxHeight` (ServersView 21; RoutingView 43; AdvancedView 47; ContentView 56),
  `lastConnection` / `reconnect` / `handleWake` in ProcessManager.
- **Codable + migration probe** (`swiftc`, Swift 5 mode, macOS 14 target): decoded a copy of the
  real file's shape — three same-URL subscriptions, two manual ones, stored server `id` keys —
  with the Step 2 `Server`; the `load()` filter kept the first URL copy and both manual ones;
  re-encoding dropped the server `id` key and kept the subscription one; the re-encoded text
  round-tripped; an absent path yields `nil` from `try? Data(contentsOf:)`.
  `Date.formatted(.relative(presentation: .named))` prints "5 hours ago".
- **Layout probe** (real `NSWindow` + `NSHostingController`, `sizingOptions = []`, the app's
  `fixedSize` + `PreferenceKey` measurement): `VStack { header; Divider; ScrollView {…} }
  .frame(maxHeight: 680)` under a 65-pt tab-bar stand-in reported 745 for 40 rows in both header
  states, with the `ScrollView` at 425 (disconnected) / 310 (connected); 3 rows reported 456 / 571,
  i.e. content height. So a page-level cap yields `min(content, cap)` and the list absorbs the
  header. The plan's 700 differs from the probe's 680 only by the constant.
- **Typecheck probe**: the Step 3/4 view surface (`@Binding` from `@AppStorage`, nested `ForEach`
  with a header + rows tuple body, `confirmationDialog(presenting:)`, `ProgressView().controlSize`,
  `refreshingIDs` with `defer` inside an `async` `@MainActor` method, `Set.insert(...).inserted`
  in a `filter`) compiles with no warnings in Swift 5 mode against the installed SDK.
- Compile story per step walked against the symbol list; no step references a symbol introduced
  later (Step 1's URI guard uses `server.id`, which exists in both forms).
- Canon: SwiftUI only (no AppKit views added); no packages; no protocol/generic/wrapper; every
  step deletes at least as much as it adds except Step 3 (header + dialog, ≈ 40 lines net);
  `@Observable` for `refreshingIDs`; `@AppStorage` stays in the editing view and is passed as a
  binding, per the contract in `AppState.swift:26-30`. Scope additions beyond the three bugs and
  the merge, all flagged: the power-button `disabled`, the delete confirmation, the re-entrancy
  guard, the dead `addSubscription(_:)` removal.

Not verifiable without building the real target:

- The look of the header row and the exact page height with the real stat boxes; 700 and the
  paddings are starting points.
- Whether `.confirmationDialog` presents cleanly on the non-resizable, height-animating window
  (sheets already do, per the window-refactor's Step 4 notes).
- Behaviour of an older build against a file written after Step 2 (reasoned from the decoder,
  not run).
