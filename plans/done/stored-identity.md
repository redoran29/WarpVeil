# Stored server identity: a key that no formula can break

Status: implemented in `a9ccdae`..`4762627`, then corrected by a code review — see the commit that follows. Its Step 4 comment block and the name-based isSameNode did not survive review.

Fourth pass at server identity in one day. Out of scope and untouched: `ProcessManager`,
routing/bypass, the window shell, subscription formats and protocols, `project.pbxproj` (no file
is added or removed).

---

## The problem, checked against the source

`Server.id` (`Models.swift:20`) is `"\(protocolType)|\(address)|\(transport ?? "")|\(name)"`.
Five sites produce `transport`: `parseVlessURI` (`SubscriptionService.swift:374`), `parseVmessURI`
(`:404`), `parseSingBox` (`:705`), `parseXray` (`:760`), the custom fallback in `addManualConfig`
(`:790`) — and a sixth, `fillingTransport` (`:84-94`), reconstructs it from the stored `config` for
files that predate the field. The review's claim is that the sixth disagrees with the first two.
Confirmed, with two corrections that make it worse than stated:

- **`parseVmessURI` `net=grpc`.** The parser stores `grpc` (`:437`); the outbound it builds has a
  `transport` block only for `ws` (`:418-426`), so `fillingTransport` finds none. At HEAD that
  yields `""`, not `tcp` — `9b41b78` replaced the parser-based fill (which defaulted to `tcp`) with a
  direct read of the outbound (`singBox ?? xray ?? ""`). Either way it is not `grpc`.
- **Every plain-TCP sing-box server.** `parseVlessURI` stores `tcp` (`params["type"] ?? "tcp"`,
  `:374`); `buildSingBoxConfig` writes no transport block for it (`default: break`, `:487-488`);
  the fill recovers `""`. So on a `≤ v1.2` file the most common node type — Reality over TCP —
  gets the id `vless|host:port||Name`, the migration stores that, and the first `refreshAll()`
  rebuilds it as `vless|host:port|tcp|Name`. Selection dead, power button flat, auto-connect
  skipped in silence. Same for vless `h2`/`quic`/`kcp`/`http` (also `default: break`).

Probed (`fillingTransport`'s body on a sing-box outbound without a transport block → `""`).

**Who is affected.** Tags: `v1.0 3ee5777`, `v1.1 8b00c36`, `v1.2 4818461` — all before `0c1e1ec`.
Every released build stores a per-server UUID; the three-segment and four-segment derived ids exist
only in builds that never shipped, i.e. on the owner's machines. `defaults read com.warpveil.app`
still holds `selectedServerID = DCA9BA1E-…` (a v1.2 UUID) and no `selectedSubscriptionID`; the
`.dev` domain holds no selection. The real file (`~/.config/warpveil/subscriptions.json`, 1
subscription, 9 servers, SHA-1 `34f19960…` before and after this run) has `transport` on every server
and no server `id` keys — written by the HEAD build at 11:50.

**Why the four attempts failed, in one line each.** `0c1e1ec` derived the id so a refresh could not
mint a new one — and made every site that produces a field a co-owner of identity. `c7f6687`
added the subscription key because the derived id was not unique across subscriptions. `d36983b`
added transport to the id because it was not unique within one — and had to invent a fill for
old files, which is where the disagreement lives. `9b41b78` fixed what the review found in the
fill and the migration, and its rewrite of the fill introduced the TCP case above. Each step was
locally right; the shape guarantees the next one.

---

## The review's direction, evaluated

> Persist a key on each `Server` the first time that server is seen, match against the derived
> formula only on first sight, and match by the stored key from then on.

**Endorsed, with one correction.** "Match by the stored key from then on" cannot literally hold:
`refreshSubscription` (`:199-224`) → `store()` (`:233-239`) replaces `subscriptions[idx].servers`
with freshly parsed `Server`s that carry no key. The only way to link a fresh server to the
previous one is by content, on **every** refresh, not just the first. What the stored key actually
buys is narrower and still decisive: the *selection* stores an opaque key that no code ever
recomputes, so the shape of `@AppStorage("selectedServerID")` can never change again, and the
content match moves into one function whose two sides are both parser output.

### What survives a refresh, and how

`store()` matches each fresh server against the subscription's previous servers by
`Server.isSameNode(as:)` (protocol, address, name, transport) and copies the matched key over
before assigning. Each previous server is claimed at most once, so a feed that lists one node twice
keeps two keys. An unmatched fresh server keeps the key minted in its memberwise init. Keys reach
the disk through the `save()` in `store()`.

**A server that leaves a feed and comes back** gets a new key; a selection pointing at it is dead
and the user taps once. This is the one thing the derived id did better — same content, same id,
self-healing — and it is the price of an opaque key. Frequency: a panel that disables a node and
later re-enables it, while the app refreshes in between. A failed fetch does *not* trigger it:
`store()` runs only when the fetch yields servers (`:212, :219`), so a dead feed keeps its servers
and their keys. Rejected mitigation: tombstones for vanished servers — machinery for a rare case.

### What "first sight" matches on

Content, via `isSameNode` — but both sides now come from the same code. The previous server was
written by `store()` from parser output and read back by `load()` **without transformation**
(the fill is deleted; `Codable` round-trips the four fields byte-for-byte — probed on the real
file). The fresh server is parser output. So the match compares one build's parser to an earlier
run of the same or an earlier build's parser on the same feed line. It can miss only when (a) the
feed changed — a renamed or removed node, correctly a different one — or (b) a parser changed how
it spells a field between builds (as `canonicalTransport` did in `9b41b78`). Case (b) costs one tap
once, on the first refresh after that upgrade, and needs no code anywhere: nothing in
`UserDefaults` changes shape. The fill could disagree with the parser because it read a config a
*builder* wrote, and `buildSingBoxConfig` drops what it does not need. The match cannot, because it
never reads a config.

The one place the old side is allowed to know less than the new: a file from `≤ v1.2` has no
transport. `isSameNode` treats an empty transport as a wildcard — it declines to compare what the
file never stored, rather than inventing a value. After that first refresh the file holds parser
transports and the wildcard is never exercised again. That term is the only upgrade-specific code
left in the tree (see retirement below).

### The migration: none, and what makes this the last shape

Keys are stored as `UUID().uuidString`. Builds up to `v1.2` stored exactly that shape and wrote it
into the file as `"id"`, so a `v1.2` file decodes with its ids intact and a `v1.2` selection
matches a server on the first launch — before any refresh, before any network. No mapping code.

| `selectedServerID` written by | Value | File state | Outcome |
|---|---|---|---|
| nothing (first run) | absent | none | `load()` returns at its guard; nothing selected |
| `≤ v1.2` | UUID | still has server `id` keys | decodes verbatim; selection alive on the first launch, auto-connect works |
| `≤ v1.2` | UUID | rewritten by an unreleased build (the owner's install) | matches nothing; left dangling — invisible (no row highlights, power button flat); one tap. Today's code removes the key; same visible result |
| `0c1e1ec`…`4da5436` | `proto\|addr\|name` | any | never shipped; matches nothing; one tap |
| `d36983b`…`9b41b78` | `proto\|addr\|transport\|name` | any | never shipped; matches nothing; one tap |
| this plan | UUID string | any | matches; carried across refreshes |

The two derived shapes are not mapped. They exist on no released build, `defaults read` shows the
owner's own domain does not hold one, and mapping them would keep `legacyID`, a formula match and
~10 lines alive with a retirement condition of "the owner's dev machines". If the owner wants
them mapped anyway it is one function in `load()` matching `"\(protocolType)|\(address)|\(name)"`
and the four-segment spelling against the stored string and rewriting it as the key — flagged,
not planned.

**Why a fifth shape is not possible.** The stored value is an opaque key. Adding, removing,
renaming or re-spelling any `Server` field changes what `isSameNode` compares, never what the
selection stores. A mistaken `isSameNode` costs one tap once (a fresh key), and the fix is a line
in that function. The only way to a fifth shape is a deliberate decision to store something other
than the key — which this plan's comment on `id` argues against in place.

**The subscription half of the selection goes.** `selectedSubscriptionID` (`c7f6687`) exists
because derived ids were not unique across subscriptions. Keys are unique by construction, so the
key alone names the `(subscription, server)` pair: `AppState.selectedSubscription` becomes "the
subscription containing the key" — what it was before `c7f6687`. That deletes one `@AppStorage`,
one `@Binding`, the two-key tap, and the `removeSubscription` bookkeeping. It is also what makes
the `v1.2` row above work with no code: a `v1.2` install never had the subscription key. The stale
`selectedSubscriptionID` value on the owner's install is left in `UserDefaults` — nothing reads it,
and code to delete a key nobody reads is dead on arrival.

### What survives, what goes, what retires

| Today | Fate | Why |
|---|---|---|
| `fillingTransport` (`:83-94`) | deleted | the disagreement lives here; the wildcard in `isSameNode` replaces it with a comparison that says nothing rather than something wrong |
| `migrateSelection` + `LegacySubscription` (`:106-139`) | deleted | `v1.2` ids decode natively; derived shapes never shipped |
| `Server.legacyID` (`Models.swift:23`) | deleted | only the migration read it |
| `uniqueByID` (`:226-231`) and its three calls (`:76, :236, :793`) | deleted | ids are unique by construction; `ForEach` no longer needs it. Visible change: a feed that lists one entry twice shows two rows, with stable keys. If the owner wants the old collapse back it is a three-line filter over `isSameNode` in `store()` — not planned |
| `canonicalTransport` (`:96-104`) | stays | it makes the parsers agree with themselves across panel spellings; unrelated to the fill |
| `selectedSubscriptionID` (3 files) | deleted | above |
| `Server.init(from:)` (new) | live while any file lacks `id` (unreleased builds) or `transport` (`≤ v1.2`) | once no such file can exist, the synthesized init suffices and the extension (9 lines) goes |
| empty-transport wildcard in `isSameNode` (new) | live while a `≤ v1.2` file can be refreshed for the first time | one boolean term; drop it with the extension |

### `transport` becomes non-optional

Still matters, less than before. The id no longer contains it, so a parser that omits it cannot
break identity; it would make `isSameNode` wildcard-match that parser's servers and let ws/grpc
twins swap keys when the feed reorders — a degradation, not a silent loss. The fix is free: the
custom `init(from:)` exists anyway for `id`, and `decodeIfPresent … ?? ""` there makes the field
`String`, which removes the memberwise default so a forgetful parser fails to compile. `""` keeps
its one legitimate producer (`addManualConfig`'s custom blob, `:790`), which never refreshes
(`refreshSubscription` guards `isManual`, `:201`), so "empty means the file did not know" is
sound for every server the wildcard can see. Done as its own commit (Step 3) because it is the
review's separate finding and touches the row label.

### The known-feed add reports its refresh

`addFromURL` (`:178-184`) fires the refresh in a `Task` and returns `.refreshing(name)`; a dead
feed reassures. `refreshSubscription` gains a `Bool` result — "the feed yielded servers" — and the
known-feed path awaits it: `.added` (sheet closes; the header's "updated N ago" moves) or
`.emptyFeed` ("Could not load a subscription from this link", the same wording the first add uses
and still true — the old servers stay). The first-add path uses the same `Bool` instead of
re-finding the subscription and inspecting `servers.isEmpty`. `.refreshing` survives for the one
case it is honest in: a refresh already in flight (`refreshingIDs`), which the guard at `:202`
would otherwise turn into a false `.emptyFeed`.

Awaiting up to 45 s was rejected by the first plan because "the sheet would sit frozen" — it does
not: `isLoading` shows "Loading…" and disables the field (`ServersView.swift:268-269, :281-288`),
exactly as the first-add path already does for the same 45 s. Consistency wins.

### `load()` saves on every launch

Keys minted for a file that lacks them exist only in memory until something saves. Today that is
`store()` — which runs only for a feed that fetches — so a manual subscription's key, or every key
when the network is down at launch, would be re-minted next launch and the selection made in
between would die. Detecting "a key was minted" needs a flag the decoder cannot set or a second
decode of the raw file (what `LegacySubscription` was). One unconditional 16 KB atomic write at
launch is simpler; the previous plans' care to avoid it bought nothing the user can see.

### Rejected

- **Key = the derived formula frozen at first sight.** Heals a returning node (same parser, same
  string) and matches today's four-segment selection with no code. Rejected: a key that looks like
  a formula invites the next maintainer to recompute it — the exact trap; two byte-identical feed
  entries would mint one key and `uniqueByID` would have to come back; and the healing it adds is
  lost anyway across any formula change. One expression to switch to if the owner disagrees.
- **Fix the fill (parser-based again) and the vmess builder.** Treats the two known cases and
  leaves the class: every future field needs a fill and a migration shape.
- **Digest of `config` or of the feed line.** Rejected in the transport plan for the same reasons
  (template edits, key rotation); unchanged.
- **Keep `selectedSubscriptionID` and fill it for `v1.2` installs.** Five lines of migration with a
  retirement condition, to keep a key that unique server keys make redundant.

**Machinery added vs. removed.** Added: a stored `id` with a 9-line custom decoder, `isSameNode`
(4 lines), `keepingIDs` (8 lines), a `Bool` on `refreshSubscription`. Removed: the fill, the
migration and its legacy decoder, `legacyID`, `uniqueByID`, the subscription key in three files,
the two-key `removeSubscription`. Net −47 lines across five files (measured on the scratch tree).
This is machinery that closes the class, not machinery next to it.

---

## Step 1 — Store a key per server and carry it across refreshes

**Commit:** `Store a key per server and carry it across refreshes`

### `Sources/Models.swift`

`Server` (`:8-24`) becomes:

```swift
struct Server: Codable, Identifiable {
    // An opaque key, minted the first time a server is seen and carried across refreshes by
    // store(). Never derived from the fields: every formula so far broke the moment one site
    // spelled a field differently, and the stored selection had to be migrated each time.
    var id = UUID().uuidString
    var name: String
    var protocolType: String
    var address: String
    // Optional only so files written before it existed still decode.
    var transport: String?
    var config: String
    var engine: Engine?

    // What the row shows is what makes two servers one node. A transport the file never
    // stored matches any: the field is younger than the file.
    func isSameNode(as other: Server) -> Bool {
        protocolType == other.protocolType && address == other.address && name == other.name
            && (transport == nil || other.transport == nil || transport == other.transport)
    }
}

// Files from builds up to 1.2 carry an id per server; later builds wrote none. Declared in an
// extension so the memberwise init the parsers use survives.
extension Server {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        protocolType = try c.decode(String.self, forKey: .protocolType)
        address = try c.decode(String.self, forKey: .address)
        transport = try c.decodeIfPresent(String.self, forKey: .transport)
        config = try c.decode(String.self, forKey: .config)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine)
    }
}
```

`id` and `legacyID` (`:20, :23`) go. `Subscription` is untouched. Two facts the step rests on,
both probed with `-warnings-as-errors`: an initializer declared in an **extension** does not
suppress the memberwise init (one in the struct body would, and all five parser call sites use
it); the synthesized `CodingKeys` and `encode(to:)` remain available to that extension. `id` is a
`String`, not a `UUID`, so every reader (`$0.id == selectedServerID`, `selectedServerID =
server.id`) is untouched and a `v1.2` file's `"id"` decodes verbatim; a `v1.2` build reading our
file parses the string back into its `UUID` (probed).

### `Sources/SubscriptionService.swift`

`load()` (`:60-81`) becomes:

```swift
func load() {
    guard let data = try? Data(contentsOf: filePath),
          let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
    else { return }
    // Older builds appended a new subscription every time the same URL was added. Keep the
    // copy that actually holds servers — the first one may be a refresh that failed.
    var bestByURL: [String: Int] = [:]
    for (i, sub) in decoded.enumerated() where !sub.url.isEmpty {
        if let best = bestByURL[sub.url], decoded[best].servers.count >= sub.servers.count { continue }
        bestByURL[sub.url] = i
    }
    subscriptions = decoded.enumerated()
        .filter { i, sub in sub.url.isEmpty || bestByURL[sub.url] == i }
        .map(\.element)
    // Keys minted for a file that predates them must reach the disk before a selection can
    // point at one; writing every launch is simpler than telling that launch apart.
    save()
}
```

The URL de-duplication (`:66-75`) is unchanged; `needsTransport`, the fill map, the `uniqueByID`
map, the count comparison and the `migrateSelection` call (`:64-65, :76-80`) go. Delete
`fillingTransport` (`:83-94`), `migrateSelection` (`:106-134`), `LegacySubscription` (`:136-139`),
`uniqueByID` (`:226-231`) and the call in `addManualConfig` (`:793`). `canonicalTransport`
(`:96-104`) stays.

The paste guard (`:167`) compares nodes, not keys — a pasted server's fresh key would never match:

```swift
guard !subscriptions.contains(where: { $0.servers.contains { $0.isSameNode(as: server) } }) else {
```

`store()` (`:233-239`) carries keys, with the helper below it:

```swift
private func store(_ servers: [Server], engine: Engine, in id: UUID) {
    guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
    subscriptions[idx].engine = engine
    subscriptions[idx].servers = keepingIDs(from: subscriptions[idx].servers, servers)
    subscriptions[idx].lastUpdated = Date()
    save()
}

// A refresh rebuilds every Server; the key has to outlive the rebuild or the selection dies
// on every launch. Each previous server is claimed at most once, so a feed that lists one
// node twice keeps two keys.
private func keepingIDs(from previous: [Server], _ fresh: [Server]) -> [Server] {
    var unclaimed = previous
    return fresh.map { server in
        guard let i = unclaimed.firstIndex(where: { $0.isSameNode(as: server) }) else { return server }
        var kept = server
        kept.id = unclaimed.remove(at: i).id
        return kept
    }
}
```

`removeSubscription` (`:146-154`), `addFromURL`'s other paths and every parser are untouched in
this step — the parsers omit `id:` and take the minted default.

### Compiles because

No symbol outside these two files spells the id formula or `legacyID` (`rg legacyID Sources` →
`Models.swift:23` and the migration, `SubscriptionService.swift:117-128`, all removed). `AppState`, `ServersView` and
`ConnectionView` compare `server.id` as a `String`, which it still is. `Server(` has five call
sites, all in `SubscriptionService.swift`, all omitting `id:`. Built with `xcodebuild` in a scratch
copy: `BUILD SUCCEEDED`, no compiler warnings (Validation).

### What could go wrong

- **Between this commit and Step 2, a `v1.2` install has a live server key and no subscription
  key**, so `selectedSubscription` finds nothing and the power button stays flat. Step 2 is the
  next commit; the two land together.
- **A byte-identical feed entry listed twice now shows twice.** Stated in the table above; keys
  stay stable through `unclaimed.remove(at:)`. If a feed does this, the rows are indistinguishable
  and either connects to the same node.
- **`save()` on every launch** runs inside `AppState()`'s initializer, synchronously, before
  `makeWindow()` (`WarpVeilApp.swift:24, :37`). 16 KB atomic. A HEAD-era build sharing the file
  (Xcode Debug of an older commit) drops the `id` keys when it saves; the next launch of this build
  mints new ones and the selection made in between is one tap. Developer-only; `dev-run.sh` builds
  of this plan share keys correctly.
- **A `v1.2` file whose node is pasted by hand before the first refresh** is refused as
  `.duplicateServer` regardless of transport, because the stored side is a wildcard until then.
  Corner of a corner; correct after the first refresh.
- **`isSameNode` is symmetric on the wildcard** (`transport == nil || other.transport == nil`) so
  neither caller has to know which side is the file. The fresh side never carries `nil` in
  practice — every parser defaults to `"tcp"` — so symmetry costs one term and removes a trap.

---

## Step 2 — Drop the subscription half of the selection

**Commit:** `Select servers by key alone`

### `Sources/AppState.swift`

`selectedSubscription` (`:47-50`) becomes:

```swift
private var selectedSubscription: Subscription? {
    subs.subscriptions.first { $0.servers.contains { $0.id == selectedServerID } }
}
```

`selectedServer` (`:32-34`), `bootstrap()` (`:67`) and `connect()` (`:73-75, :80`) are unchanged:
they already resolve the subscription first and the server inside it, so `connect()` still pairs a
subscription's `engine` with its own server's `config`.

### `Sources/ConnectionView.swift`

Delete `:6`; `:30-32` becomes `ServersView(app: app, selectedServerID: $selectedServerID)`.

### `Sources/ServersView.swift`

Delete `:6`. The row (`:67-76`) becomes:

```swift
ServerRowView(server: server, isSelected: selectedServerID == server.id)
    .contentShape(Rectangle())
    .onTapGesture { selectedServerID = server.id }
```

### `Sources/SubscriptionService.swift`

`removeSubscription` (`:146-154`) loses its `UserDefaults` block:

```swift
func removeSubscription(_ id: UUID) {
    subscriptions.removeAll { $0.id == id }
    save()
}
```

A key naming no server selects nothing and highlights nothing; clearing it bought nothing.

### Compiles because

`selectedSubscriptionID` has exactly these readers (`rg selectedSubscriptionID Sources` →
AppState 48, ConnectionView 6/31, ServersView 6/69/74, SubscriptionService 111/121/130/148-149 —
the service ones went in Step 1). `ServersView` has one call site, changed in the same commit.
The `defaults` property in `AppState` keeps its other readers (`:37, :44, :55, :67`). Built.

### What could go wrong

- **The same node in two subscriptions** now highlights and connects through the row that was
  tapped — the case `c7f6687` fixed, fixed better: two copies are two keys.
- **The `AppState` contract** ("the view that edits a key holds the matching `@AppStorage`",
  `AppState.swift:26-30`) still holds for the one key left; `powerButton`'s `disabled`
  (`ConnectionView.swift:63`) re-evaluates on the tap because the view owns the key.
- **Stale `selectedSubscriptionID` values** stay in `UserDefaults` on the owner's installs. Unread.

---

## Step 3 — Make the transport non-optional

**Commit:** `Make the server transport non-optional`

### `Sources/Models.swift`

`var transport: String?` and its comment become `var transport: String`. In `isSameNode`:

```swift
&& (transport.isEmpty || other.transport.isEmpty || transport == other.transport)
```

In `init(from:)`: `transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""`. The
extension's comment becomes "Files from builds up to 1.2 carry an id per server and no transport;
later builds wrote the reverse."

### `Sources/ServersView.swift`

`protocolLabel` (`:163-167`):

```swift
private var protocolLabel: String {
    let proto = server.protocolType.uppercased()
    guard !server.transport.isEmpty, server.transport != "tcp" else { return proto }
    return "\(proto) \u{00B7} \(server.transport.uppercased())"
}
```

### Compiles because

`transport` is read in `Models.swift`, `ServersView.swift:165-166` and passed by the five
constructors in `SubscriptionService.swift` (`:388, :437, :712, :767, :790`), each with a
non-optional `String` already (`canonicalTransport` returns `String`; the fallback passes `""`).
`guard let` on a non-optional is the one compile error this step could cause, and `:165` is
rewritten. Built.

### What could go wrong

- A `v1.2` file now stores `"transport": ""` after the Step 1 save on the upgrade launch, and
  reads `""` back on the next launch until its first successful refresh. The wildcard treats
  `""` and "absent" alike, so nothing changes; the row shows no suffix, as it does for `tcp`.

---

## Step 4 — Report what a re-added feed's refresh came back with

**Commit:** `Report the refresh outcome when a known feed is re-added`

### `Sources/SubscriptionService.swift`

`addFromURL` from the known-feed comment (`:178`) to the end (`:197`) becomes:

```swift
// Re-adding a known feed means "update it", not "add a second copy". A refresh already
// in flight is left to finish; otherwise the outcome is reported like a first add.
if let existing = subscriptions.first(where: { $0.url == trimmed }) {
    guard !refreshingIDs.contains(existing.id) else { return .refreshing(existing.name) }
    return await refreshSubscription(existing.id) ? .added : .emptyFeed
}

let name = URLComponents(string: trimmed)?.host ?? "Subscription"
let sub = Subscription(name: name, url: trimmed, engine: .singBox)
subscriptions.append(sub)
save()
guard await refreshSubscription(sub.id) else {
    removeSubscription(sub.id)
    return .emptyFeed
}
return .added
```

`refreshSubscription` (`:199-224`):

```swift
// Reports whether the feed yielded servers; a failed fetch leaves the previous ones in place.
@discardableResult
func refreshSubscription(_ id: UUID) async -> Bool {
    guard let idx = subscriptions.firstIndex(where: { $0.id == id }),
          !subscriptions[idx].isManual,
          !refreshingIDs.contains(id)
    else { return false }
    …
    if let servers = await fetchAndParseURIs(urlString), !servers.isEmpty {
        store(servers, engine: .singBox, in: id)
        return true
    }
    for engine in [Engine.singBox, .xray] {
        if let servers = await fetchFormattedConfig(urlString, engine: engine), !servers.isEmpty {
            store(servers, engine: engine, in: id)
            return true
        }
    }
    return false
}
```

`AddResult` (`:4-12`) and the sheet's wording (`ServersView.swift:323-335`) are unchanged: every
case is still produced.

### Compiles because

The other two callers discard the result — the header button's `Task { await
app.subs.refreshSubscription(sub.id) }` (`ServersView.swift:106`) and `refreshAll`'s
`group.addTask { await self.refreshSubscription(id) }` (`:247`). `@discardableResult` covers the
first; a single-expression closure in a `Void` context discards its value, and both patterns were
compiled under `-warnings-as-errors` in the probe. Built.

### What could go wrong

- **The sheet now waits** up to 45 s on a re-paste of a dead feed, showing "Loading…", instead of
  closing on a reassurance. That is the finding.
- **`.added` on a known feed closes the sheet without saying "already added".** The list behind
  it updated and the header's relative time moved; the user pasted a URL and the URL's servers
  are there. If the owner wants the notice back, return a new case and one line in the `switch`.
- **`refreshAll`'s group** still ignores results — auto-connect at `bootstrap()` cares only that
  the selected server exists afterwards, which it does whether or not its feed fetched.

---

## Close

Move this file to `plans/done/`, run `/code-review`, fix what it surfaces (canon, Workflow §3).
No `CLAUDE.md` change: it names `Models.swift` as "Server, Subscription, Engine types" and the
selection only as "`@AppStorage` (UserDefaults)", both still true; the key's reason is in its
comment in the source.

Noticed, not in scope, not touched: `parseVmessURI` still builds a transport block only for `ws`
(`:418-426`), so a vmess `grpc` node is labelled `VMESS · GRPC` and connects over bare TCP. That
is a config-builder gap, pre-existing, no longer able to touch identity.

---

## Risks, ranked

1. **A node that leaves a feed and returns needs one tap** (Step 1). The derived id healed this;
   the key cannot. Rare, stated, no mitigation planned.
2. **Two identical feed entries show twice** (Step 1). Data-dependent; not seen in the real file.
3. **A parser spelling change between builds costs one tap once** — the residual of the class,
   with no migration possible or needed. `canonicalTransport` already absorbs the two known
   spellings.
4. **Unconditional `save()` at launch** (Step 1) — one small write; the only observable cost is to
   a developer switching between this and an older commit in one `UserDefaults` domain.
5. **The sheet waits on a dead known feed** (Step 4) — 45 s worst case, visibly loading.

---

## Validation record

Checked in this run:

- Read in full: `CLAUDE.md`; all 15 `Sources/*.swift`; `project.pbxproj` (no file added or
  removed; `SWIFT_VERSION = 5.0`, deployment 14.0, no warnings-as-errors flag); both plans in
  `plans/done/`; `git log 4818461..HEAD`; the diffs of `0c1e1ec`, `c7f6687`, `d36983b`, `9b41b78`;
  `git show v1.2:Sources/Models.swift` (`let id: UUID`, minted in `init`); tag → commit mapping and
  `merge-base --is-ancestor v1.2 0c1e1ec`; `defaults read` for `com.warpveil.app` and `.dev`.
- **The real file**, read through a copy and a read-only script: 1 subscription, 9 servers, all
  with `transport` (7 `xhttp`/xray, 2 `grpc`/sing-box), no server `id` keys, no `|` in any name.
  SHA-1 `34f1996025795b3cf0bf1cd276c4cd5f1e5ad4bb` before and after; not modified.
- **Per-step build:** the tree was copied to the scratchpad, each step applied cumulatively by
  script (exact-match replacements, each asserted to hit once), and `xcodebuild -scheme WarpVeil
  -configuration Debug` run five times — baseline and after each step. All five `BUILD SUCCEEDED`;
  the only `warning:` line in every log is the `appintentsmetadataprocessor` notice the baseline
  emits. The cumulative diff is −47 lines across the five files named above.
- **Model probe** (`swiftc -swift-version 5 -target arm64-apple-macos14.0 -warnings-as-errors`,
  the Step 3 `Server` verbatim): memberwise init survives the extension `init(from:)` and takes
  no `id:`; `CodingKeys` and `encode(to:)` synthesized; a `v1.2`-shaped record decodes its id
  verbatim and `""` transport; a HEAD-shaped record mints a UUID string and keeps its transport;
  round trip writes both keys; `keepingIDs` keeps ws/grpc twins on their own keys after a
  reorder, gives two identical entries two stable keys, carries a transport-less `v1.2` server's
  key and fills its transport from the parser, mints for an unmatched server, and treats a
  renamed node as new; a `Void` task group and a bare `Task` over the `Bool`-returning
  `@discardableResult` function compile clean; HEAD's `fillingTransport` body returns `""` for a
  sing-box outbound with no transport block.
- **Real-file probe** (same model, a copy of the file): 9 servers decode, 9 unique keys minted,
  transports untouched; a second decode of the re-encoded file returns the same keys; the
  re-encoded file decodes under HEAD's `Server` shape and under `v1.2`'s (`id` as `UUID`); a
  `v1.2`-shaped rewrite of it decodes with ids verbatim and empty transports, and one simulated
  refresh carries all 9 keys and fills all 9 transports; the owner's stored UUID matches none of
  the minted keys (dangling, one tap); a missing file fails `Data(contentsOf:)` and `load()`
  returns at its guard.
- **Selection shapes:** the six-row table above was walked against the probes: `v1.2` + intact
  file (decodes verbatim → matches); `v1.2` + rewritten file (owner: dangling); three- and
  four-segment (never shipped: dangling); this plan (matches); no selection (untouched).
- **Line references** re-checked with `rg`/`sed -n` after drafting against HEAD.
- **Canon:** no protocol, generic or wrapper; one method on a struct, one private helper, one
  extension holding a decoder; `@AppStorage` stays in the editing view; `@Observable` untouched;
  `Codable` for the file and `JSONSerialization` for configs, as today; no dependency; nothing
  under `ProcessManager`, routing, the window or the formats. Scope additions, all flagged:
  dropping `selectedSubscriptionID` (a consequence of unique keys, and what deletes the last
  migration), dropping the duplicate-row collapse, the unconditional save.

Not verified:

- No launch of the built app: the row highlight, the sheet's wait and the power button were
  reasoned from the code.
- A live feed refresh through `store()` → `keepingIDs`; the carry-over was exercised on parser-shaped
  values, not on a fetch.
- A `≤ v1.2` install upgrading in place — reasoned from a `v1.2`-shaped rewrite of the real file,
  since no such file exists on this machine.
- Whether `defaults read com.warpveil.app` reflects a stale cache; either way every row of the
  table ends in "matches" or "one tap".
