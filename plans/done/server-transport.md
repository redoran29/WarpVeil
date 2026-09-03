# Server transport: tell ws from grpc, keep UI copy in the view

Status: implemented. Written against commit `4da5436` (clean tree; the `gitStatus`
snapshot handed to the planning agent named files that do not exist and was ignored).

Two code-review findings on the server identity work (`plans/done/server-identity.md`). Out of
scope and untouched: `ProcessManager`, routing/bypass, the window shell and height fitting,
subscription formats and protocols, `project.pbxproj` (no file is added or removed).

---

## Review claims, checked against the source

### 1. `Server.id` collapses servers that differ in transport — confirmed, one example corrected

`Models.swift:17`: `var id: String { "\(protocolType)|\(address)|\(name)" }`. `uniqueByID`
(`SubscriptionService.swift:184-188`) keeps the first of any two equal ids and runs in `store()`
(`:193`), `addManualConfig()` (`:745`) and `load()` (`:63`). The paste guard in `addFromURL`
(`:123`) refuses a `vless://` whose id is already present anywhere.

So a feed listing one node as `…?type=ws…#Chicago` and `…?type=grpc…#Chicago` at one `host:port`
yields two `Server`s with one id; the second is dropped in `store()` on every refresh, and pasting
it by hand is refused as "already in the list". `ServerRowView.detectTransport`
(`ServersView.swift:169-186`) would have labelled them `VLESS · WS` and `VLESS · GRPC` — the row
can tell them apart, the id cannot. **Confirmed.** Such pairs are real: a reverse proxy on 443
routes ws and grpc backends by path, and panels export both.

**Correction — "reality versus plain TLS" is not a second example.** Security is a property of
the listener: one `host:port` speaks either TLS or Reality. A Reality inbound forwards a plain-TLS
ClientHello to its camouflage `dest`, and a TLS inbound fails a Reality client's key check, so of
two entries that differ only in security at one address, at most one works. Nothing usable is
lost by giving them one id, and the row label does not show security either. Transport is the
one axis on which two working servers can share name and address; that is what the id gets.

**The real file** (`~/.config/warpveil/subscriptions.json`, read, not modified — SHA-1
`45d9cba5…` before and after this run): 1 subscription, 9 servers, 7 `xhttp` (xray) and 2 `grpc`
(sing-box), all distinct by name. It does not trigger the bug today; it is the upgrade case for
the `Codable` story below.

### 2. The service returns English sentences — confirmed

`addFromURL` (`:114-155`) returns six literal messages (`:116, :121, :124, :138, :141, :152`),
`addManualConfig` (`:726-729`) one more; `AddSubscriptionSheet` renders `message` as-is
(`ServersView.swift:293-298`). Every other user-facing string is in a view. **Confirmed.** One
caller per function (`ServersView.swift:328, :334`), nothing else reads the strings.

---

## Decisions

### Identity = what the row shows: `protocol | address | transport | name`

`transport` becomes a stored `String?` on `Server`, and the id becomes
`"\(protocolType)|\(address)|\(transport ?? "")|\(name)"`. The rule that follows from it: **two
entries the list cannot show apart are one server.** Same name, address and transport but a
different `path`, `sni` or uuid still collapse to one id — the second is dropped, exactly as today,
and the user could not have told the rows apart anyway. Stated so nobody expects more.

Where the value comes from — each construction site already holds it in a local:

| Site | Has | Passes |
|---|---|---|
| `parseVlessURI` `:331` | `transportType = params["type"] ?? "tcp"` | `transportType` |
| `parseVmessURI` `:360` | `net = obj["net"] ?? "tcp"` | `net` |
| `parseSingBox` `:652-665` | `ob["transport"]?["type"]` | that, or `"tcp"` |
| `parseXray` `:692-718` | `ob["streamSettings"]?["network"]` | that, or `"tcp"` |
| `addManualConfig` custom fallback `:742` | nothing to inspect | `""` |

`"tcp"` for the bare case and `""` for "no outbound to read" are both hidden by the label and
both fine in the id; the two are kept distinct so the fallback never looks like a parsed value.

**Why this is not the plumbing the previous plan rejected.** That plan refused a stored
`subscriptionID` because the parsers do not know the subscription — the value would have had to
be threaded in from `store()`, `addManualConfig()` and the paste branch after construction, and it
would not have fixed the within-subscription duplicate. Here the value is born in the parser,
travels one argument, and is the very thing that makes the duplicate distinct. Same shape of
change, opposite cost/benefit.

Rejected:

- **Digest of `config`** — genuinely unique, but `config` is the app's own template around the
  outbound (`buildSingBoxConfigFromOutbound` `:482-518`, the xray skeleton `:599-624`); any edit
  to the template changes every id on the next refresh and drops the selection on upgrade, which
  is the failure `0c1e1ec` fixed. Unmigratable, since the old digest is not derivable after the
  file is rewritten.
- **Digest of the source (URI line / outbound dict)** — survives template changes, not key
  rotation (a panel that rotates `sid` or the uuid renames the server), and cannot be recomputed
  for servers already on disk, so the migration would need a second formula anyway.
- **A `Transport` enum** — the feed vocabulary is open (`ws`, `grpc`, `xhttp`, `splithttp`,
  `httpupgrade`, `http`, `quic`, `kcp`); an enum needs an `unknown(String)` case to be honest,
  at which point it is a `String` with ceremony.
- **Adding `security` as a fifth segment** — see the correction above; no working pair needs it.

### `Codable`: optional field, filled in `load()`

The on-disk file has no `transport`. A non-optional property, even with a default, makes the
synthesized `init(from:)` throw on the missing key, `load()`'s `try?` swallows it, and the user's
subscriptions vanish. `String?` decodes to `nil` — the precedent is `engine: Engine?`
(`Models.swift:13`), optional for the same reason.

`nil` cannot be allowed to reach the id, though: a legacy `grpc` server would carry the id
`vless|addr||Name` until `bootstrap()` → `refreshAll()` rebuilt it as `vless|addr|grpc|Name`, and
the selection would die on the first refresh after upgrade — the servers-page bug again, once. So
`load()` fills the field before anything reads it, from the one place the transport still lives:
the stored `config`. `parseSingBox(config).first ?? parseXray(config).first` returns a `Server`
whose `transport` the new parsers set; every stored config has exactly one VPN outbound (`[ob] +
serviceOutbounds`, `:662, :715`, and the URI builders emit one), and a custom blob makes both
parsers return `[]` (that is why it was stored as custom), which maps to `""`. The file is saved
once with the field; the next launch finds nothing `nil` and does not rewrite (probed).

An older build reading the new file ignores the extra key; if it saves, it drops the key and the
next new-build launch fills it again. `dev-run.sh` coexistence is safe in both directions.

### Migration: one function, three stored shapes, one-shot by construction

`migrateSelection` (`:70-89`) today runs only while `selectedSubscriptionID` is unset and maps a
`≤ v1.2` UUID by position. It gains the third shape — a three-segment id from builds
`0c1e1ec`…`4da5436` — and changes its guard from "subscription key unset" to "the stored id names
no server in scope", where scope is the selected subscription if one is stored, else all. A
stored value that matches a current id returns at the top, so a healthy launch writes nothing.

| Written by | `selectedServerID` | `selectedSubscriptionID` | Result |
|---|---|---|---|
| nothing | absent | any | untouched |
| `≤ v1.2`, file still has server `id` keys | UUID | unset | mapped by position; both keys written |
| `≤ v1.2`, file rewritten since | UUID | unset | key removed (unchanged) |
| `0c1e1ec`…`5ebd709` | `proto\|addr\|name` | unset | first subscription holding it; both keys written |
| `c7f6687`…`4da5436` | `proto\|addr\|name` | set | mapped inside that subscription; server key rewritten |
| any | id of a server that is gone | any | untouched, retried next launch |
| this plan | `proto\|addr\|transport\|name` | set | skipped at the first guard |

The three-segment match compares whole strings — `"\(protocolType)|\(address)|\(name)" ==
stored` — never splits on `|`, because names can contain it. The UUID path is byte-for-byte
today's, and its `match.1.id` is already the four-segment id because the fill runs on `decoded`
before the zip.

**Owner's install, checked:** `defaults read com.warpveil.app` still holds
`selectedServerID = DCA9BA1E-…` and no `selectedSubscriptionID`, while the file has no server
`id` keys — row three of the table, unchanged from the previous plan: the key is removed, one tap.
The `.dev` domain has no selection.

### `uniqueByID` stays

Ids are unique per what the user can see, not per byte. A feed that lists a byte-identical entry
twice still produces two equal ids, and `ForEach` on equal ids is undefined behaviour in SwiftUI.
Keep the first; the rows would have been indistinguishable. The comment changes to say what the
filter no longer drops.

### `detectTransport` goes

It exists to recover the transport from `config` by `JSONSerialization` on every row, every
render — 18 lines of parsing that the stored field makes redundant. `protocolLabel` reads the
field; `tcp`, `""` and `nil` render as no suffix, which is what the function returned for them
(sing-box configs never carry a `tcp` transport block; xray `network == "tcp"` was filtered at
`:181`). One visible difference, flagged: a `vmess://` with `net=grpc` was labelled `VMESS`
because `parseVmessURI` only builds a transport block for `ws` (`:374-382`); it will now read
`VMESS · GRPC`, which is what the feed said. The config gap is pre-existing and not touched.

### Finding 2: a result enum, narrowly worth it

Weighed against "no premature abstractions" and "no over-engineering": an enum is not a protocol,
generic or wrapper, so the 3+ rule does not apply; the honest cost is about +19 net lines for one
caller. What buys them:

- **Copy leaves the service.** Seven strings become one `switch` in `ServersView.swift`, next to
  every other string the sheet shows.
- **Two messages become one case.** `:137-141` tell "X is refreshing now" from "refreshing X"
  by checking `refreshingIDs` — but `refreshSubscription` (`:158-161`) already makes the second
  call a no-op, and "X is refreshing now" is true in both cases. `.refreshing(name)` replaces
  both, and the guard at `:137-139` goes.
- **`addManualConfig` sheds `@discardableResult`** (`:725`): its one caller reads the result.

The smaller alternative — leave `String?` and accept the leak with a comment — keeps the
boundary only on paper. `throws` with an error enum was considered and rejected: "already added,
refreshing" is not an error, and Swift 5.10 has no typed throws, so the sheet would cast the
error back. The enum lives at the top of `SubscriptionService.swift`, next to its producer and
outside the `@MainActor` class, so the view's extension has nothing to say about isolation. The
`String?` `message` state in the sheet and the "`nil` means dismiss" flow are unchanged.

---

## Step 1 — Tell servers apart by transport

**Commit:** `Store the transport on each server and put it in the id`

### `Sources/Models.swift`

`:8-18` becomes:

```swift
struct Server: Codable, Identifiable {
    var name: String
    var protocolType: String
    var address: String
    // Optional only so files written before it existed still decode; load() fills it in.
    var transport: String?
    var config: String
    var engine: Engine?

    // Derived, not stored: refreshing a subscription rebuilds every Server, and a fresh UUID
    // each time would drop the user's selection on every launch. The transport is part of it
    // because a feed can list one node under one name and address over ws and again over grpc.
    var id: String { "\(protocolType)|\(address)|\(transport ?? "")|\(name)" }
}
```

Declaration order sets the memberwise init: `transport:` sits between `address:` and `config:`.
The implicit `nil` default means call sites may omit it, but every site in this step passes it.

### `Sources/SubscriptionService.swift`

Four construction sites:

- `:344` → `Server(name: name, protocolType: "vless", address: "\(host):\(port)", transport: transportType, config: config, engine: engine)` (wrap after `transportType,`).
- `:392` → `Server(name: name, protocolType: "vmess", address: "\(host):\(port)", transport: net, config: config)`.
- `parseSingBox`, after `let address` at `:659`:
  `let transport = (ob["transport"] as? [String: Any])?["type"] as? String ?? "tcp"`, passed at `:665`.
- `parseXray`, after the `address` `if/else` closes at `:712`:
  `let transport = (ob["streamSettings"] as? [String: Any])?["network"] as? String ?? "tcp"`, passed at `:718`.
- `:742` → `Server(name: name, protocolType: "custom", address: "—", transport: "", config: json)`.

`load()` (`:49-66`): rename the decoded binding and fill before anything reads ids:

```swift
guard let data = try? Data(contentsOf: filePath),
      let stored = try? JSONDecoder().decode([Subscription].self, from: data)
else { return }
let needsTransport = stored.contains { $0.servers.contains { $0.transport == nil } }
let decoded = stored.map { var sub = $0; sub.servers = sub.servers.map(fillingTransport); return sub }
```

The URL-dedupe block (`:53-63`) is unchanged and keeps reading `decoded`. `:64` becomes
`if needsTransport || subscriptions.count != decoded.count { save() }`.

Below `load()`, before `migrateSelection`:

```swift
// Files written before the transport was stored still carry it inside the config.
private func fillingTransport(_ server: Server) -> Server {
    guard server.transport == nil else { return server }
    var filled = server
    filled.transport = (parseSingBox(server.config).first ?? parseXray(server.config).first)?.transport ?? ""
    return filled
}
```

`migrateSelection` (`:68-89`) becomes:

```swift
// Two earlier shapes of the stored selection are mapped here: builds up to 1.2 kept a UUID
// per server, which survives only in a file those builds wrote; builds before the transport
// joined the id derived it from protocol, address and name alone. A value that already names
// a server in the selected subscription is left alone.
private func migrateSelection(decoded: [Subscription], data: Data) {
    let defaults = UserDefaults.standard
    guard var serverID = defaults.string(forKey: "selectedServerID") else { return }
    let subscriptionID = defaults.string(forKey: "selectedSubscriptionID")
    let scope = subscriptions.filter { subscriptionID == nil || $0.id.uuidString == subscriptionID }
    guard !scope.contains(where: { $0.servers.contains { $0.id == serverID } }) else { return }

    if UUID(uuidString: serverID) != nil {
        let legacyIDs = (try? JSONDecoder().decode([LegacySubscription].self, from: data))?
            .flatMap(\.servers).map(\.id) ?? []
        guard let match = zip(legacyIDs, decoded.flatMap(\.servers)).first(where: { $0.0 == serverID }) else {
            defaults.removeObject(forKey: "selectedServerID")
            return
        }
        serverID = match.1.id
    }
    for sub in scope {
        guard let server = sub.servers.first(where: {
            $0.id == serverID || "\($0.protocolType)|\($0.address)|\($0.name)" == serverID
        }) else { continue }
        defaults.set(sub.id.uuidString, forKey: "selectedSubscriptionID")
        defaults.set(server.id, forKey: "selectedServerID")
        return
    }
}
```

`LegacySubscription` (`:91-94`) is unchanged. The `uniqueByID` comment (`:184`) becomes:

```swift
// A feed can list one entry twice; ForEach needs the derived ids unique. Two entries that
// differ in transport are two ids and both stay.
```

### Compiles because

`transport` is optional, so no other file's `Server(...)` call breaks — and there are none
outside this file (`rg "Server\(" Sources` → the five sites above). `fillingTransport` calls the
two private parsers declared later in the same class; Swift does not care about order.
`ServersView`, `AppState` and `ConnectionView` read `server.id` and never spell the formula. Built
with `xcodebuild` in a scratch copy (see Validation).

### What could go wrong

- **`load()` now parses every server's config once, on the upgrade launch only.** Nine servers,
  two `JSONSerialization` passes each; the file is then saved with the field and the next launch
  skips the work (probed: the file's mtime does not change on a second load).
- **Selection continuity across a refresh.** The transport a parser writes must equal the one
  the fill recovers from that parser's own output. Both go through the same two config parsers
  (`parseSingBox`/`parseXray`), and the URI builders write the transport type unchanged into the
  config (`buildSingBoxConfig` `:414-441`, `buildXrayConfig` `:546`). Probed on the real file:
  fill → `xhttp`/`grpc`; a refresh from the same feed rebuilds the same ids. One known
  exception, flagged: a `vless://…type=splithttp` line is stored as `splithttp` while a feed that
  later renames it to `xhttp` changes the id. Same node, same renamed feed; one tap. Not
  normalized — it would be a fifth spelling rule for a case nobody has hit.
- **The paste guard now admits a transport variant of a node already present.** Intended; that
  is finding 1's "cannot select it".
- **Two builds sharing `com.warpveil.app`** (Xcode Debug of `4da5436` and of this plan) hand a
  three- and a four-segment id back and forth: the older build finds no match and disables the
  power button until a tap; the newer one migrates it back. Only affects a developer switching
  commits; `dev-run.sh` builds are in their own domain.
- **Migration code grows by ~8 lines** and now has three retirement conditions instead of two.
  Same lifetime note as before: live while a `≤ v1.2` or unreleased-build install can upgrade.

---

## Step 2 — Label the row from the stored transport

**Commit:** `Show the transport from the stored field`

### `Sources/ServersView.swift` only

`:163-186` (`protocolLabel` and `detectTransport`) become:

```swift
private var protocolLabel: String {
    let proto = server.protocolType.uppercased()
    guard let transport = server.transport, !transport.isEmpty, transport != "tcp" else { return proto }
    return "\(proto) \u{00B7} \(transport.uppercased())"
}
```

### Compiles because

`detectTransport` has one caller, `protocolLabel` (`:165`), which is rewritten. Nothing else in
the file uses `JSONSerialization`; `import SwiftUI` stays. Built.

### What could go wrong

- **A row for a server that is still `nil`.** Cannot happen after Step 1: `load()` fills every
  server before `subscriptions` is assigned, and all five constructors pass a value. The `guard`
  handles it anyway because the type is optional — no force unwrap.
- **`VMESS · GRPC` on a vmess whose config has no grpc block** — see Decisions; label now
  reflects the feed. The connection was already broken for that server; the label no longer
  hides it.

---

## Step 3 — Move the add sheet's wording into the sheet

**Commit:** `Report add outcomes as a result type, word them in the sheet`

### `Sources/SubscriptionService.swift`

Above the class, after `import Foundation`:

```swift
// What an add reports back. The wording lives in the sheet, with the rest of the UI copy.
enum AddResult {
    case added
    case emptyInput
    case unparsableLink
    case duplicateServer
    case refreshing(String)
    case emptyFeed
    case invalidJSON
}
```

`addFromURL` (`:113-155`): drop the comment at `:113`; signature `async -> AddResult`; `:116` →
`.emptyInput`, `:121` → `.unparsableLink`, `:124` → `.duplicateServer`, `:131` and `:154` →
`.added`, `:152` → `.emptyFeed`. The known-feed block `:134-142` becomes:

```swift
// Re-adding a known feed means "update it", not "add a second copy". Not awaited: a
// refresh can take up to 45s and the sheet would sit frozen for it. A refresh already in
// flight makes this a no-op, and the outcome reads the same either way.
if let existing = subscriptions.first(where: { $0.url == trimmed }) {
    Task { await refreshSubscription(existing.id) }
    return .refreshing(existing.name)
}
```

`addManualConfig` (`:725-750`): remove `@discardableResult`; signature `-> AddResult`; `:729` →
`.invalidJSON`, `:749` → `.added`.

### `Sources/ServersView.swift`

`:328` → `message = subs.addManualConfig(name: manualName, json: manualJSON).message`;
`:334` → `message = await subs.addFromURL(url).message`. At the end of the file:

```swift
private extension AddResult {
    var message: String? {
        switch self {
        case .added: nil
        case .emptyInput: "Enter a link or a subscription URL"
        case .unparsableLink: "Could not parse this link"
        case .duplicateServer: "This server is already in the list"
        case .refreshing(let name): "Already added — \(name) is refreshing now"
        case .emptyFeed: "Could not load a subscription from this link"
        case .invalidJSON: "This is not valid JSON"
        }
    }
}
```

### Compiles because

Both functions have exactly one caller each, changed in the same commit. The `switch`
expression with a `nil` branch under a `String?` return type is Swift 5.9+ (SE-0380) and
compiled clean under `-warnings-as-errors` in the probe; the whole tree built with `xcodebuild`.
`refreshingIDs` keeps its other readers (`:137` goes; `:160, :164-165` and the header spinner
`ServersView.swift:102` stay), so nothing becomes dead.

### What could go wrong

- **Scope addition, flagged:** the two "already added" messages merge into one. The second
  review added the split so the notice would not lie when the refresh was a no-op; "X is
  refreshing now" is true in both branches, so the merge keeps that fix with less code. If the
  owner wants the distinction back, it is a second case and one more line in the `switch`.
- **Scope addition, flagged:** `@discardableResult` removed — no caller discards.
- `AddResult` has no `Equatable`; the sheet never compares cases, it reads `.message`. Add the
  conformance only when a comparison appears.
- One enum, one caller, seven cases: this is the kind of type the canon warns against
  multiplying. It is justified above; do not add a second result enum for a future feature
  without the same argument.

---

## Close

Move this file to `plans/done/`, run `/code-review`, fix what it surfaces (canon, Workflow §3).
No documentation change: `CLAUDE.md` names `Models.swift` as "Server, Subscription, Engine
types" and `SubscriptionService.swift` as "Subscription fetch, … parsing, config building", both
still true; the transport field's reason is in its comment in the source.

Noticed, not in scope, not touched: `buildSingBoxConfig`'s `case "xhttp", "splithttp"`
(`:425-434`) is unreachable — `parseVlessURI` routes both to `buildXrayConfig` (`:332-338`).

---

## Risks, ranked

1. **A legacy file whose stored config the two parsers cannot read back** (Step 1 fill) gets
   `""` and the id `proto|addr||name`; if that server's parser later produces a real transport,
   the selection moves once. Not seen: every stored config comes from the four sites, and the
   real file's nine all recover. Custom blobs are `""` on both sides by construction.
2. **`splithttp` vs `xhttp` spelling** (Step 1) — a feed that renames the transport renames the
   server. One tap; noted, not normalized.
3. **Migration lifetime** — three shapes now, ~30 lines, same retirement condition as before.
4. **Label drift on `vmess` non-ws transports** (Step 2) — more truthful, not less; the config
   gap it exposes is pre-existing.
5. **The enum** (Step 3) — +19 lines for a boundary; the owner asked for the boundary.

---

## Validation record

Checked in this run:

- Read: `CLAUDE.md`; all 15 `Sources/*.swift` in full; `project.pbxproj` (399 lines — no file
  added, no `SWIFT_TREAT_WARNINGS_AS_ERRORS`, `SWIFT_VERSION = 5.0`, deployment 14.0); all three
  plans in `plans/done/`; `git show 0c1e1ec` (the derived-id commit); `defaults read` for
  `com.warpveil.app` and `com.warpveil.app.dev`; the real `subscriptions.json` (structure and
  per-server transport, via a read-only script; SHA-1 unchanged after the run).
- Every line reference re-checked with `rg`/`sed -n` after drafting; the four construction
  sites are the only `Server(` calls in the tree; `selectedServerID` readers are AppState 33/44/74,
  ConnectionView 7/32, ServersView 7/70/75 and the service's migration — none spell the formula.
- **Per-step build:** the tree was copied to the scratchpad (never the working tree), each step's
  edits applied cumulatively by script, and `xcodebuild -scheme WarpVeil -configuration Debug`
  run four times — baseline, Step 1, Step 2, Step 3. All four: `BUILD SUCCEEDED`, and the only
  `warning:` line in each log is the `appintentsmetadataprocessor` tool notice that the baseline
  emits too. Zero compiler warnings before and after.
- **Runtime probe:** the Step 3 `Models.swift` + `SubscriptionService.swift` compiled with
  `swiftc -swift-version 5 -target arm64-apple-macos14.0 -warnings-as-errors`, with only the
  config directory and the `UserDefaults` suite redirected to the scratchpad, driven against a
  **copy** of the real file. All pass: 9 servers decode and fill to `xhttp`×7/`grpc`×2, ids
  unique, file rewritten with the key once and not again; the migration table's rows (no
  selection; owner's UUID → removed; three-segment id with and without a subscription → mapped
  to the four-segment id; current id → untouched; unknown id → untouched; no file → empty and
  untouched); `ws`, `grpc` and `tcp` pastes of one node → three servers, the same paste twice →
  `.duplicateServer`; manual custom/sing-box/xray JSON → `""`/`httpupgrade`/`xhttp`, invalid
  JSON → `.invalidJSON`; transports round-trip through `Codable`.
- Canon: no protocol, generic or wrapper; one new enum and one optional field; `@AppStorage`
  keys and their owning views untouched; `JSONSerialization` for the untyped config, `Codable`
  for the file, as today; no new dependency; nothing under `ProcessManager`, routing, the window
  or the formats changed. Net: +25 lines across the three steps.

Not verified:

- No launch of the built app — the label, the sheet and the selection highlight were reasoned
  from the code, not looked at. `ForEach` over the new ids is the same `String` identity as today.
- A real feed that lists a ws/grpc pair. The pair was exercised by pasting the two URIs, not by
  fetching a subscription; `store()` runs the same `uniqueByID` on parser output either way.
- Whether `defaults read com.warpveil.app` reflects a stale cache: it shows the legacy UUID,
  which means the current build has not yet run in that domain. Either way the table covers it.
- Behaviour of a `≤ v1.2` file with server `id` keys under the new fill — reasoned (the zip is
  positional over `decoded`, whose count and order the fill preserves), not probed, because no
  such file exists on this machine.
