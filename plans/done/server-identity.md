# Server identity: scope the selection, migrate it, report duplicate adds

Status: implemented in `c7f6687`..`2d5c0e6`. Written against commit `5ebd709` (clean tree; the `gitStatus`
snapshot handed to the planning agent listed files that do not exist — `AGENTS.md`,
`SettingsView.swift`, `BypassView.swift` — and was ignored. `CLAUDE.md` is the whole canon).

Three review findings on the servers-page work (`plans/done/servers-page.md`). Out of scope and
untouched: `ProcessManager`, routing/bypass, the window shell and height fitting, subscription
formats, `Models.swift`.

---

## Review claims, checked against the source

### 1. `Server.id` is not unique — confirmed, one correction

`Models.swift:17`: `var id: String { "\(protocolType)|\(address)|\(name)" }`. Nothing scopes it.

**Across subscriptions.** `AppState.selectedServer` (`AppState.swift:32-34`) is
`flatMap(\.servers).first`, `selectedSubscription` (`:47-51`) is `subscriptions.first { contains }`.
Both walk `subs.subscriptions` in order, so they always land on the **same** subscription — the
first one holding the id. `connect()` (`:73-89`) therefore never pairs one subscription's
`config` with another's `engine`; the pair at `:79` is consistent. **The review's "wrong engine on a
config the other engine wrote → parse error in the log" does not happen.** What does happen: the
user taps the row under subscription B, both rows highlight (`ServersView.swift:68` compares the
bare id), and `connect()` uses A's copy of the node. A's and B's configs for "the same" node can
differ (a hand-pasted `vless://` with other params, a feed served in `?format=xray` vs a
sing-box build), so the tunnel comes up through a config the user did not pick, with no UI hint.

How the pair arises today: the `vless://` guard at `SubscriptionService.swift:87` refuses a node
already present in any subscription, but only at paste time — a feed refreshed later can bring in
a node pasted earlier, two feeds can share nodes, and `addManualConfig` (`:671-689`) has no guard.
Rare, real, cheap to fix.

**Within one subscription.** `ForEach(sub.servers)` (`ServersView.swift:65`) with two equal ids
is SwiftUI's "the ID … occurs multiple times within the collection, this will give undefined
results!" — confirmed as a risk; the real file (one feed, 9 distinct ids) does not trigger it.

### 2. The stored selection does not survive the upgrade — confirmed, with a hard fact

`@AppStorage("selectedServerID")` (`ConnectionView.swift:6`) held `Server.id.uuidString` in every
build up to and including the `v1.2` tag (`4818461`; `git show v1.2:Sources/Models.swift` has
`let id: UUID`), and holds the derived id since `0c1e1ec` (unreleased). A `v1.2` install opening
the current build matches nothing: `powerButton` is disabled (`ConnectionView.swift:60`) and
`bootstrap()`'s auto-connect branch (`AppState.swift:68`) is skipped in silence.

The fact that shapes the migration: **the legacy server UUIDs exist only in
`~/.config/warpveil/subscriptions.json` as written by a `≤ v1.2` build.** `Server` no longer
decodes or encodes `id`, and `bootstrap()` → `refreshAll()` → `store()` → `save()`
(`SubscriptionService.swift:136-142`) rewrites the file on every launch with network. The owner's
own file (`~/.config/warpveil/subscriptions.json`, read structure-only, not modified) has already
been rewritten: 1 subscription, 9 servers, **no server `id` keys** — while
`defaults read com.warpveil.app selectedServerID` still returns `DCA9BA1E-…`. That value is
unrecoverable; only installs coming straight from `≤ v1.2` can be mapped, and only on the launch
that precedes their first `save()`. `load()` runs in `SubscriptionService.init()` (`:30-33`),
i.e. inside `AppState()` (`WarpVeilApp.swift:24`), before `bootstrap()` — so a migration in
`load()` does run before the first save. Good enough; the unrecoverable case is stated below.

### 3. Adding a duplicate is a silent no-op — confirmed, plus two more silent paths

`addFromURL` (`SubscriptionService.swift:78-107`) returns `Void`. Silent returns: unparsable
`vless://`/`vmess://` (`:86`), node already present (`:87`), known feed URL → refresh (`:96-100`).
The sheet (`ServersView.swift:303-315`) sets `isLoading = false` and `dismiss()`es regardless.

Also found: `TextField.onSubmit` (`:281`) bypasses the button's `.disabled` (`:295-296`). Enter on
a whitespace-only field passes `url.isEmpty` and reaches `addFromURL` with `trimmed == ""` —
`subscriptions.first(where: { $0.url == "" })` then matches a **manual** subscription (their `url`
is `""`, `Models.swift:29`) and "refreshes" it (guarded out at `:111`, silent), or, with no manual
subscription, appends a junk `Subscription(name: "Subscription", url: "")`. Enter while loading
starts a second concurrent add. Both are the same "silent path" family; both are one guard each.

---

## Decisions

### Selection = subscription UUID + server derived id, as two `@AppStorage` keys

`selectedSubscriptionID` (new, `Subscription.id.uuidString`) and `selectedServerID` (existing,
`Server.id`). `AppState` resolves the subscription by UUID, then the server inside it.

Why this and not the alternatives:

- **Composite `Server.id` that includes the subscription** — `Server` does not know its
  subscription; every parser builds servers before `store()` assigns them, so the id would need a
  stored `subscriptionID` field set in `store()`, `addManualConfig()` and the `vless://` branch,
  encoded into the file, and the within-subscription duplicate stays. More plumbing, less fixed.
- **Bare server id, resolve `(subscription, server)` in one pass** — the two lookups already
  agree (claim 1); a single pass changes nothing about which copy wins. Does not fix the bug.
- **Two keys vs one `"uuid|serverID"` key** — one key needs a compose site in `ServersView`, a
  parse site in `AppState` and a migration that renames the key; two keys need one extra
  `@AppStorage`, one extra `@Binding`, and `selectedServerID` keeps its name and its current
  shape, so values from the unreleased builds need only the subscription filled in.

The constraint that killed the UUID holds: `store()` (`:136-142`) replaces `servers` but never
`Subscription.id`, so a refresh changes neither key's target. What is given up: after deleting a
subscription and re-adding the same feed, the selection no longer comes back on its own (the
re-added subscription mints a new UUID at `Models.swift:30`). One extra tap; accepted.

### Within-subscription duplicates: drop them where `servers` is written

Two entries with one id are one server as far as the app can tell; keeping the first is the only
rule consistent with the id formula. Applied in `store()` and `addManualConfig()` — the only two
places that assign a multi-server array (`refreshSubscription` goes through `store`; the
`vless://` branch assigns exactly one). Not applied in `load()`: files written by the unreleased
derived-id builds self-heal at the next launch refresh, and the previous plan's URL-dedupe filter
there already carries the "older builds" safety net. Rejected: making ids unique with an ordinal
suffix — needs a stored id again and flips between rows when the feed reorders.

### Migration: in `load()`, one-shot by construction, four value shapes

Runs only while `selectedSubscriptionID` is unset; every successful tap sets it, so it can never
run again after that. Table of what a stored `selectedServerID` becomes:

| Written by | Value shape | File state | Result |
|---|---|---|---|
| nothing (first run) | absent | any | untouched |
| `≤ v1.2` | UUID string | still has server `id` keys | mapped by position to the derived id; both keys written; auto-connect works on that first launch |
| `≤ v1.2` | UUID string | rewritten by a derived-id build (the owner's install) | unmappable; the stale key is **removed**; user taps once |
| `0c1e1ec`…`5ebd709` (unreleased) | derived id | any | subscription = first one containing it (today's behaviour, frozen once); both keys written |
| `0c1e1ec`…`5ebd709` | derived id, server gone | any | untouched; retried next launch, heals if the node returns |
| this plan | derived id + subscription UUID | any | migration skipped |

The mapping is by position: legacy files carry the same servers in the same order as the decoded
array, so `zip(legacyIDs, decoded.flatMap(\.servers))` pairs each old UUID with the `Server` whose
derived id it now is. `decoded`, not `subscriptions`, keeps the zip aligned with the file; the
final lookup goes through `subscriptions` (the URL-deduped set) by "contains this server id", so a
selection that lived in a dropped duplicate copy lands on the surviving copy.

### Feedback: `addFromURL` returns `String?`

`nil` = added, close the sheet; a message = show it under the field, keep the sheet open. One
return type, one `@State`, one `Text`. The known-feed case returns a message too — "Already added
— refreshing <name>" — and starts the refresh in a `Task` instead of awaiting it: awaiting can
block the sheet for three 15 s fetches (`:122-133`, `:24`) before a message can appear, while the
header's spinner (`ServersView.swift:97-98`) already shows the refresh behind the sheet. Rejected:
an outcome enum with per-case colours — same information, more lines; can be added if the owner
wants red errors.

---

## Step 1 — Scope the selection to its subscription

**Commit:** `Scope the server selection to its subscription`

### `Sources/AppState.swift`

Replace `:32-34` and `:43-51`:

```swift
var selectedServer: Server? {
    selectedSubscription?.servers.first { $0.id == selectedServerID }
}

...

private var selectedServerID: String {
    defaults.string(forKey: "selectedServerID") ?? ""
}

private var selectedSubscription: Subscription? {
    let id = defaults.string(forKey: "selectedSubscriptionID") ?? ""
    return subs.subscriptions.first { $0.id.uuidString == id }
}
```

`bootstrap()` (`:68`) and `connect()` (`:74`) read the same two properties and do not change.

### `Sources/ConnectionView.swift`

`:6` gains a sibling, `:29` passes both:

```swift
@AppStorage("selectedSubscriptionID") private var selectedSubscriptionID = ""
@AppStorage("selectedServerID") private var selectedServerID = ""
...
ServersView(app: app, selectedSubscriptionID: $selectedSubscriptionID, selectedServerID: $selectedServerID)
```

Both keys stay in the view that edits them — the contract at `AppState.swift:26-30`; the
`powerButton` `disabled` (`:60`) re-evaluates on either write because the view owns both.

### `Sources/ServersView.swift`

`:6` gains `@Binding var selectedSubscriptionID: String` (declare it **before**
`selectedServerID` — the memberwise init follows declaration order, and the call above uses that
order). The row (`:66-71`):

```swift
ServerRowView(
    server: server,
    isSelected: selectedSubscriptionID == sub.id.uuidString && selectedServerID == server.id
)
.contentShape(Rectangle())
.onTapGesture {
    selectedSubscriptionID = sub.id.uuidString
    selectedServerID = server.id
}
```

### Compiles because

`ServersView` has one call site (`ConnectionView.swift:29`), updated in the same commit. Nothing
else reads the keys (`rg selectedServerID Sources` → AppState 33/43/44/49, ConnectionView 6/29,
ServersView 6/68/71 — all covered). Typechecked in a probe (see Validation).

### What could go wrong

- A `v1.2` install and the owner's current install both have `selectedSubscriptionID` unset
  after this commit: nothing selected until Step 3 lands or the user taps. Step 3 is the next
  commit; between them the behaviour equals today's.
- Two `UserDefaults` writes per tap. SwiftUI coalesces the invalidations within the gesture
  action; even an intermediate render would only mean no highlight for one frame — `connect()`
  is never triggered by a render.
- The same node under two subscriptions now highlights only the tapped row; nested `ForEach`
  identity is namespaced by the outer element, so equal server ids under different subscriptions
  are distinct views. Reasoned from SwiftUI's identity model, not probed.

---

## Step 2 — Drop duplicate servers within a subscription

**Commit:** `Drop duplicate servers within a subscription`

### `Sources/SubscriptionService.swift` only

Next to `store` (`:136-142`):

```swift
// A feed can list one node twice; ForEach needs the derived ids unique.
private func uniqueByID(_ servers: [Server]) -> [Server] {
    var seen = Set<String>()
    return servers.filter { seen.insert($0.id).inserted }
}
```

`store` `:139`: `subscriptions[idx].servers = uniqueByID(servers)`.

`addManualConfig`: after the `if/else if/else` (`:676-684`), before `sub.lastUpdated = Date()`
(`:686`): `sub.servers = uniqueByID(sub.servers)`. One call covers both parser branches; the
`custom` fallback (`:683`) is a single server and passes through unchanged.

### Compiles because

Pure additions; `Set<String>.insert(_:).inserted` is the idiom `load()` already used in the
previous plan. Probed.

### What could go wrong

- A feed that really carries two configs under one protocol/address/name (say `ws` and `grpc`
  with the same tag) loses the second. `ServerRowView.protocolLabel` (`:158-162`) would have
  shown them apart, so this is a visible loss for such a feed — but the app already treats them
  as one server everywhere else (selection, the paste guard). If that ever bites, the fix is the
  id formula, an owner decision, not this filter.
- Order is preserved (`filter`), so the migration's positional zip in Step 3 is unaffected —
  `load()` does not call `uniqueByID`.

---

## Step 3 — Migrate the stored selection from earlier builds

**Commit:** `Migrate the stored server selection from earlier builds`

### `Sources/SubscriptionService.swift` only

`load()` (`:49-64`) gets one line at its end, after the `save()` check:

```swift
migrateSelection(decoded: decoded, data: data)
```

Below `save()` (`:66-69`):

```swift
// Builds up to 1.2 stored a UUID per server and selected by it. The UUID survives only in a
// file those builds wrote, so this is the one place it can still be mapped to today's keys.
private func migrateSelection(decoded: [Subscription], data: Data) {
    let defaults = UserDefaults.standard
    guard defaults.string(forKey: "selectedSubscriptionID") == nil,
          let stored = defaults.string(forKey: "selectedServerID")
    else { return }

    var serverID = stored
    if UUID(uuidString: stored) != nil {
        let legacyIDs = (try? JSONDecoder().decode([LegacySubscription].self, from: data))?
            .flatMap(\.servers).map(\.id) ?? []
        guard let match = zip(legacyIDs, decoded.flatMap(\.servers)).first(where: { $0.0 == stored }) else {
            defaults.removeObject(forKey: "selectedServerID")
            return
        }
        serverID = match.1.id
    }
    guard let sub = subscriptions.first(where: { $0.servers.contains { $0.id == serverID } }) else { return }
    defaults.set(sub.id.uuidString, forKey: "selectedSubscriptionID")
    defaults.set(serverID, forKey: "selectedServerID")
}

private struct LegacySubscription: Decodable {
    struct LegacyServer: Decodable { let id: String? }
    let servers: [LegacyServer]
}
```

`LegacyServer.id` is `String?`, not `UUID?`: a file without the key decodes to `nil` and the
`zip` simply never matches, which is what routes the "rewritten file" row of the table to
`removeObject`. Comparing strings is exact — both sides came from `uuidString`.

### Compiles because

Pure additions in one file; `UserDefaults.standard` is the store `@AppStorage` uses by default.
The function was compiled with `-warnings-as-errors` and run through all six table rows in a
probe (see Validation).

### What could go wrong

- **The service now writes `UserDefaults`.** `AppState` reads these keys raw already; the
  alternative — doing it in `AppState.init` — would need the raw file, which only the service
  has. The writes happen inside `AppState()`'s initialiser, before `makeWindow()`
  (`WarpVeilApp.swift:37`) creates the first `@AppStorage`, so no view can observe a half-written
  pair.
- **This code stays until the owner retires it.** It is live as long as a `v1.2` install can
  upgrade; after the next release has been out for a while the function, the struct and the
  `load()` call can be deleted together (about 25 lines). Flagged; not scheduled.
- `dev-run.sh` copies use their own defaults domain (`com.warpveil.app.dev`, no selection stored)
  against the shared file: nothing to migrate there; the `≤ v1.2` mapping window closes for
  every domain the moment any build saves the file.
- A corrupt or missing file returns from `load()`'s first guard before the migration — right for
  a first run, and harmless otherwise (retried next launch).

---

## Step 4 — Report duplicate and invalid links in the add sheet

**Commit:** `Report duplicate and invalid links in the add sheet`

### `Sources/SubscriptionService.swift`

`addFromURL` (`:78-107`) becomes:

```swift
// Returns what to tell the user when nothing was added; nil means it was.
func addFromURL(_ urlString: String) async -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Enter a link or a subscription URL" }

    if trimmed.hasPrefix("vless://") || trimmed.hasPrefix("vmess://") {
        guard let server = parseVlessURI(trimmed) ?? parseVmessURI(trimmed) else {
            return "Could not parse this link"
        }
        guard !subscriptions.contains(where: { $0.servers.contains { $0.id == server.id } }) else {
            return "This server is already in the list"
        }
        var sub = Subscription(name: server.name, isManual: true, engine: .singBox)
        sub.servers = [server]
        sub.lastUpdated = Date()
        subscriptions.append(sub)
        save()
        return nil
    }

    // Re-adding a known feed means "update it", not "add a second copy".
    if let existing = subscriptions.first(where: { $0.url == trimmed }) {
        Task { await refreshSubscription(existing.id) }
        return "Already added — refreshing \(existing.name)"
    }

    let name = URLComponents(string: trimmed)?.host ?? "Subscription"
    let sub = Subscription(name: name, url: trimmed, engine: .singBox)
    subscriptions.append(sub)
    save()
    await refreshSubscription(sub.id)
    return nil
}
```

The `var server: Server?` dance at `:83-86` collapses into `parseVlessURI(trimmed) ??
parseVmessURI(trimmed)` — both parsers guard on their own prefix (`:233`, `:296`), so the pair is
safe. Optional; keep the original four lines if preferred. The empty-string guard is what stops
the manual-subscription "refresh" and the junk subscription from claim 3.

### `Sources/ServersView.swift`, `AddSubscriptionSheet` (`:236-316`)

- `@State private var message: String?` next to `isLoading` (`:245`).
- The URL field (`:278-281`) gets `.onChange(of: url) { message = nil }` after `.onSubmit`.
- Between the `if isManual { … } else { … }` block (`:268-282`) and the bottom `HStack` (`:284`):

  ```swift
  if let message {
      Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
  }
  ```

- `addSubscription()` (`:303-315`), URL branch:

  ```swift
  } else {
      // Enter in the field bypasses the button's disabled state.
      guard !isLoading, !url.isEmpty else { return }
      isLoading = true
      Task {
          message = await subs.addFromURL(url)
          isLoading = false
          if message == nil { dismiss() }
      }
  }
  ```

  The JSON branch (`:304-306`) is unchanged.

### Compiles because

`addFromURL` has exactly one caller (`ServersView.swift:310`), updated here. `Task { await … }`
as a statement needs no `_ =` — `Task.init` is `@discardableResult`. The sheet surface
(`@State String?`, `if let`, `.onChange(of:) { }` one-argument form on macOS 14) typechecked in
the probe.

### What could go wrong

- The known-feed message uses a present participle and the sheet stays open; the user closes it
  with the existing X (`:253`) or Esc. If the owner prefers the sheet to close on this case,
  change `if message == nil { dismiss() }` — but then the message is never seen, which is the
  finding being fixed.
- A refresh that yields nothing for a **new** URL still appends an empty subscription and returns
  `nil` (the sheet closes). The subscription is visible, refreshable and deletable from its
  header, so it is not silent; making it an error would mean not adding feeds that are down at
  paste time. Left as is, noted.
- Whitespace-only input: `url.isEmpty` is false, the button is enabled, `addFromURL` returns the
  "Enter a link" message. Correct, if slightly odd; trimming in the view would be a second copy
  of the same trim.
- `addManualConfig` (JSON tab) still has no guard and no feedback. Not in the findings; a pasted
  JSON blob has no natural duplicate key.
- The single `.secondary` style makes errors and the refresh notice look alike. Deliberate
  (see Decisions); an enum with two cases is the upgrade path.

---

## Close

Move this file to `plans/done/`, run `/code-review`, fix what it surfaces (canon, Workflow §3).
No documentation change: `CLAUDE.md` describes the keys only as "`@AppStorage` (UserDefaults)",
which stays true; the migration's lifetime note lives in its comment in the source.

---

## Risks, ranked

1. **The owner's own selection is gone** (Step 3, table row 3): the UUID cannot be mapped once
   the file has been rewritten, and it has. One tap. Every other `≤ v1.2` install that upgrades
   directly is mapped.
2. **Nested `ForEach` identity** (Step 1): reasoned, not probed. If SwiftUI did not namespace by
   the outer element, equal ids under two subscriptions would still warn — the previous plan
   assumed the same and the owner's data has no such pair.
3. **Feed with two configs under one id** (Step 2) loses one row. Data-dependent; not seen.
4. **Migration code lingers** (Step 3) — 25 lines with a stated retirement condition.

---

## Validation record

Checked in this run:

- All 15 `Sources/*.swift` files read in full; `project.pbxproj` (399 lines — no file is added,
  so it is not touched); `CLAUDE.md`; both plans in `plans/done/`; `git show 0c1e1ec`,
  `git show v1.2:Sources/Models.swift`, tag → commit mapping (`v1.0 3ee5777`, `v1.1 8b00c36`,
  `v1.2 4818461`, all before `0c1e1ec`), `defaults read` for `com.warpveil.app` and
  `com.warpveil.app.dev`, and the real `subscriptions.json` (structure only, not modified).
- Every line reference re-checked with `rg` / `sed -n` after drafting: `selectedServerID`
  (AppState 33/43/44/49, ConnectionView 6/29, ServersView 6/68/71), `addFromURL` (definition 78,
  caller ServersView 310), `store` 136-142, `addManualConfig` 671-689, `refreshSubscription`
  109-134 and its guard 110-113, `refreshingIDs` use in the header 97, `onSubmit` 281, button
  `disabled` 295-296, `isLoading` 245, sheet `addSubscription()` 303-315, `Subscription.init`
  29-37 (`url` default `""`), `Server.id` 17, `AppState.init` order vs `makeWindow`
  (`WarpVeilApp.swift:24,37`).
- **Migration probe** (`swiftc -swift-version 5 -target arm64-apple-macos14.0
  -warnings-as-errors`, real `Server`/`Subscription` shapes, an isolated `UserDefaults` suite):
  all six table rows behave as written — fresh install untouched; legacy UUID + old-shape file →
  both keys set to the right subscription UUID and derived id; legacy UUID + rewritten file →
  key removed; derived id present → both keys set; derived id missing → untouched; already
  migrated → skipped. `uniqueByID` returns one of two equal-id servers.
- **View typecheck probe** (same flags, `-typecheck`, SwiftUI): two `@AppStorage` + two
  `@Binding` passed through a memberwise init, the two-write tap, the `&&` highlight, `@State
  String?` with `if let`, `.onChange(of:) { }`, and the `Task { message = await … }` body compile
  with no warnings.
- Compile story per step: Step 1 changes all three files that name the keys in one commit;
  Steps 2 and 3 are additions inside one file; Step 4 changes the one caller with the signature.
  No step references a symbol introduced by a later step.
- Canon: SwiftUI only; no packages; no protocol, generic or wrapper (the one new type is a
  private `Decodable` for the legacy file shape); `@AppStorage` stays in the editing view;
  `@Observable` untouched; net additions ≈ 25 (Step 3) + 12 (Step 4) lines, the rest is
  edits in place. Scope additions beyond the three findings, all flagged: the empty-input and
  Enter-while-loading guards (claim 3's extra silent paths), the `??` parser collapse (optional).

Not verified:

- No `xcodebuild` run — the plan's compile claims rest on the two probes and the symbol walk,
  not on building the target. The current tree's "no warnings" baseline is taken on the owner's
  word.
- Nested `ForEach` identity namespacing (risk 2).
- The look of the message line inside the 360-pt sheet (`:300`) — one `Text`, caption size;
  nothing to measure.
- Whether SwiftUI ever renders between the two `UserDefaults` writes in the tap (risk-free either
  way, as argued in Step 1).
