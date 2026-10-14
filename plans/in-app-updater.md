# In-app updater: over-the-air releases from GitHub, authenticated by our own ed25519 key

Status: planned. Written against `c32a050` on 2026-10-14, macOS 27.0.1 (Darwin 27.0.0), Xcode 27.0
(Swift 6.4 toolchain, language mode 5), deployment target 14.0, `CFBundleShortVersionString` =
`1.2`, installed app ad-hoc signed, `gh` logged in as `redoran29`, releases v1.0 / v1.1 / v1.2 with
one asset each (`WarpVeil-<version>-macOS.zip`).

> **Owner's go-ahead needed before step 3.** This plan reverses a Key Decision in `CLAUDE.md`:
> *"Binary upgrades ship with the app: no in-app updater; bump the pinned tags in
> `fetch-binaries.sh` and cut a release."* The new wording is in "Canon updates" below. Steps 1–2
> are independent fixes and need no decision; steps 3–5 are the updater and do.

## Owner's ask

Can the app update itself from GitHub without an Apple Developer ID? The accepted shape: a small
homegrown updater — no Sparkle, the canon forbids external Swift packages — that checks
`https://api.github.com/repos/redoran29/WarpVeil/releases/latest`, compares with
`CFBundleShortVersionString`, downloads the release zip with `URLSession`, verifies it with an
ed25519 signature of our own (CryptoKit, public key in the app, private key outside the repo),
unpacks it with `ditto`, checks the bundle, stages it the way `install.sh` does and relaunches
through the app's own quit path. One control, an automatic check, no feature creep. The brief
also asks for the privilege model after an update, proof that the updater opens no root path, the
macOS policy questions verified rather than guessed, the GitHub API's limits, and `release.sh`
changes that keep both the ad-hoc and the Developer ID paths.

Out of scope and untouched: `install.sh`, `fetch-binaries.sh`, `PingService`, `BypassService`,
`SubscriptionService`, the engines, the sudoers/libexec install (`installPasswordless` is called
by nothing new).

## Verified facts

Checked in this run on this machine, not recalled. Line numbers are against `c32a050`.

### Code

- `Sources/WarpVeilApp.swift:88-98` `applicationShouldTerminate`: `ping.cancel()`, then
  `.terminateNow` unless `pm.isRunning`, else `disconnect()` + `awaitTeardown(timeout: 30)` +
  `reply(toApplicationShouldTerminate: true)`. `:103-127` `menuNeedsUpdate` rebuilds the status
  menu on every open: status line, Connect/Disconnect, Open WarpVeil, separator, Quit.
- `Sources/ProcessManager.swift:17-54` every privileged path carries `versionTag`
  (`1.2` → `1-2`); `:191-199` `passwordlessInstalled()` reads **this tag's** sudoers file, scripts
  and manifest — after a version bump none exist, so a fresh build reads passwordless as off;
  `:321-324` `init` logs the stale line only when **this tag's** sudoers file exists, so after a
  bump nothing is logged; `:249-261` `installPasswordless` first removes every
  `/etc/sudoers.d/warpveil*` and `/usr/local/libexec/warpveil*` (hardening plan D6); `:719-726`
  `tearDownEngines` terminates the helper and xray and runs `killVPNProcesses`, which stores the
  stop in `teardownProcess` (`:730`); `:732-738` `awaitTeardown` waits for that process to exit
  and returns nothing — a cancelled password dialog exits osascript non-zero within a second,
  which today reads the same as a finished stop; `:557-583` xray runs as the user and is
  `terminate()`d by `tearDownEngines`; `:807-811` `findBinary` is bundle-only.
- `Sources/AppState.swift:72-83` `bootstrap` awaits location + feeds, then auto-connects, then
  `isBootstrapped = true`; `:103-110` `disconnect()`. `Sources/AdvancedView.swift:9-46` two
  sections, Connection and Components; `Sources/ContentView.swift:7-21` the `Page` enum (no new
  page needed). `Sources/SetupService.swift:28-41` runs blocking work in `Task.detached` — the
  pattern reused for `ditto`.
- `Info.plist` has `CFBundleShortVersionString` `1.2`, `CFBundleVersion` `3`,
  `NSAllowsArbitraryLoads` true, no `*UsageDescription` keys. `WarpVeil.entitlements` only turns
  the sandbox off. `WarpVeil.xcodeproj/project.pbxproj` lists sources explicitly (`AA…`/`BB…`
  ids, four places per file) — a new file has to be registered there; `SWIFT_VERSION = 5.0`,
  `ARCHS = arm64`, `PRODUCT_BUNDLE_IDENTIFIER = com.warpveil.app`.
- `release.sh:103-124` packages with `ditto -c -k --sequesterRsrc --keepParent WarpVeil.app
  WarpVeil-<version>-macOS.zip`, and **re-packages after stapling** in the Developer ID path, so
  a signature has to be taken after that; `:173-176` `gh release create "$TAG" "$zip"`.
  `install.sh:169-177` stages as `/Applications/.WarpVeil.app.new`, `rm -rf` the old, `mv`, `open
  -n`. `dev-run.sh:113-133` builds Debug with `PRODUCT_BUNDLE_IDENTIFIER=com.warpveil.app.dev`,
  sets the version to `<v>-dev` and the name with `PlistBuddy`, re-signs ad-hoc.
- `.gitignore` already excludes `*.key` and `*.pem`. `README.md` lists features and a Release
  section that will both need a line.

### GitHub (`curl`, `gh`, this run)

- `GET /repos/redoran29/WarpVeil/releases/latest` → 200, `x-ratelimit-limit: 60` (per IP,
  unauthenticated), `etag: W/"…"`, `cache-control: public, max-age=60`. Fields used: `tag_name`
  (`v1.2`), `assets[].name`, `assets[].browser_download_url`; also present: `draft`,
  `prerelease`, `assets[].digest` (`sha256:…`, GitHub's own — not authenticity), `size`.
- GitHub's docs: the endpoint returns "the most recent non-prerelease, non-draft release, sorted
  by the `created_at` attribute" — so drafts and prereleases never reach the app.
- `If-None-Match` with the ETag → 304, **and the 304 counted against the limit** (`remaining`
  went 59 → 58 → 57 over GET, HEAD, conditional GET; `/rate_limit` then said `used: 3`). An ETag
  buys nothing here.
- The asset URL is a 302 to `release-assets.githubusercontent.com` (signed, time-limited);
  `URLSession` follows it. The website's `/releases/latest` is a 302 to `/releases/tag/v1.2`
  (an undocumented alternative to the API, recorded in D6).
- The exit IP during the checks was the VPN's (`203.0.113.20`), with `remaining: 59` at the
  first call: nobody else on that exit had used the API that hour.

### macOS: quarantine, launch, App Management, TCC, tampering

- A file downloaded by a Swift binary with `URLSession.shared.download(from:)` (temp file in
  `$TMPDIR/CFNetworkDownload_*.tmp`, moved with `FileManager`) and one written from
  `data(from:)` both carry only `com.apple.provenance`, **no `com.apple.quarantine`** (`xattr -l`).
  The installed `/Applications/WarpVeil.app` carries only `com.apple.provenance` too; `spctl
  --assess --type execute` says `rejected` for it (ad-hoc), and it runs anyway — Gatekeeper only
  assesses quarantined files.
- A `ditto -c -k --sequesterRsrc --keepParent` / `ditto -x -k` round trip of the installed app
  keeps the ad-hoc seal valid (`codesign --verify --deep --strict`: `valid on disk`, `satisfies
  its Designated Requirement`) and introduces no symlinks; the zip is 40 MB.
- **`ditto -x -k` neutralises path traversal**: an entry named `../target/escaped.txt` lands in
  `<dest>/target/escaped.txt`, `/tmp/abs-escaped.txt` in `<dest>/tmp/abs-escaped.txt`. It
  **does recreate a symlink entry** (`WarpVeil.app -> /Applications` at the top level), and a
  file entry through a symlinked directory aborts the extraction (`Not a directory`, rc 1). So
  the unpacked top level has to be checked for "real directory, not a symlink" — done.
- **An ad-hoc signed app can replace its own bundle and relaunch with no prompt**, tested with a
  throwaway app in a scratch directory: it spawned the helper of D4 (`/bin/sh -c` with the
  bundle paths and its pid as arguments), exited, the helper renamed the bundles and `open
  -n`ed the new one; the log shows `launched v1` → `mv old aside: ok` → `mv new in: ok` → `rm
  old: ok` → `open: ok` → `launched v2`, and `log show` had no `com.apple.TCC` event for it. The
  same probe **inside `/Applications` was not run here** — this session is not allowed to write
  there; `update-live.sh apps-probe` below runs it for the main session. What is known about
  App Management (macOS 13+): Apple's rule blocks a modification by code "not signed by the same
  development team" unless `NSUpdateSecurityPolicy` allows it, and "notifies the user that an
  app wants to manage other apps" (mjtsai.com's quote of Apple); an ad-hoc app has no team; a
  2026 report (Mysk, "Silent Replacement of Trusted macOS App Executables", macOS 26.0–26.5.2 and
  27 betas) replaced a Developer ID app's bundle as the user by deleting and re-extracting it
  with no elevated privileges, and Apple closed it as not a bypass; a GitHub spike (fc445
  unrot-your-brain PR 14) replaced an ad-hoc app in `/Applications` with Sparkle, "no prompts".
  The helper's three renames plus one `rm -rf` are the operations `install.sh` already does from
  a Terminal every deploy.
- **WarpVeil holds no TCC grant to lose.** `/Library/Application Support/com.apple.TCC/TCC.db`
  has one `warpveil` row: `kTCCServiceSystemPolicyAllFiles`, `auth_value 0` (denied), for an old
  Xcode DerivedData path. The user database is unreadable from this shell. `Info.plist` declares
  no usage keys; the app uses `osascript … with administrator privileges` (Authorization
  Services, not TCC), `SCDynamicStore`, `URLSession` to public hosts. External reports say TCC
  grants for ad-hoc apps do not survive a new cdhash — nothing here depends on one.
- **Tampering with an ad-hoc app**: editing a string in `Contents/MacOS/<exe>` → the app does
  not launch (killed, no log line); editing `Info.plist` → `codesign --verify` says `invalid
  Info.plist (plist or signature have been modified)` **but the app launches and reads the
  edited value**. So a key held in `Info.plist` is not tamper-evident at launch, a key in the
  binary is. Weighed in D1.

### Tooling

- `/usr/bin/openssl` is LibreSSL 3.3.6 and has **no ed25519** (`Algorithm ed25519 not found`),
  so the signer is Swift. `swift -e '<code>'` runs a one-liner in 0.28 s; `swift - args <<EOF`
  runs a script from stdin with `CommandLine.arguments` = the args; `swift -e` does not accept
  `import A, B` (one `import` per statement). CryptoKit: `Curve25519.Signing.PrivateKey()` /
  `.rawRepresentation` (32-byte seed) / `.publicKey.rawRepresentation` (32 bytes, 44 chars
  base64) / `.signature(for:)` (64 bytes, 88 chars base64 + newline = 89); a 31-byte public key
  throws; `isValidSignature` over a 41 MB mapped `Data` takes 27–41 ms; a one-bit change fails
  it; a trailing newline in the base64 is dropped by `.ignoreUnknownCharacters`. No PEM for
  Curve25519 in CryptoKit — the key file is the base64 seed.
- `"1.2".compare("1.10", options: .numeric)` → ascending, `"1.2-dev"` < `"1.3"`, `"1.2"` <
  `"1.2-dev"` (a dev build is "newer" than its base, so a real release is never offered to the
  same-version dev copy, and is offered to an older one — hence `dev-run.sh` removes the feed),
  `"1.2.1"` > `"1.2"`, `"1.10"` > `"1.9"`.
- `Bundle(url:)` on an unlaunched bundle gives `bundleIdentifier`, `infoDictionary` and
  `executableArchitectures` (`[16777228]` = `NSBundleExecutableArchitectureARM64`);
  `URL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])` tells a real app from a
  symlink. `/etc/sudoers.d` is `755` — listable by the user (`warpveil-1-2` is the only entry
  today). The user is in `admin`; `/Applications` is `root:admin 775`; the installed bundle is
  `lortan29:staff`. `$TMPDIR` and `/Applications` are on the same volume, so the stage is a
  rename. macOS has no `timeout`.
- A `@MainActor` task never runs while the main thread blocks in a semaphore — a harness has to
  `dispatchMain()`. (A trap of this plan's harness, not of the app.)
- Baseline `xcodebuild … Debug` into a scratch derived-data dir: `BUILD SUCCEEDED` in 12 s.

## Design

### D1. The feed URL and the public key are `Info.plist` keys, not Swift constants

`WVUpdateFeed` = `https://api.github.com/repos/redoran29/WarpVeil/releases/latest`,
`WVUpdatePublicKey` = the base64 raw ed25519 public key. This is Sparkle's convention
(`SUFeedURL`, `SUPublicEDKey`) and it gives the live check its whole seam for free: `dev-run.sh`
already rewrites the dev copy's `Info.plist` with `PlistBuddy` and re-signs, and the live script
does the same with a feed on `127.0.0.1` and a throwaway key — **no test-only code**, no build
setting, no `#if DEBUG`, no environment variable. Weighed against a compiled-in key: the
tampering probe shows an edited `Info.plist` still launches while an edited binary does not, so
the plist key is less tamper-evident. That buys nothing here: whoever can edit the installed
bundle's `Info.plist` runs as the user and can replace the whole bundle (ad-hoc apps launch
either way), edit `~/.config/warpveil/subscriptions.json`, or write the defaults — the updater's
trust boundary is the user account, same as everything else in a user-owned `.app`. Rejected:
`#if DEBUG` + a `UserDefaults` override (test code in the source, and Xcode's Cmd+R copy is a
Debug build with the real bundle id, so the seam would be live there); a build setting threaded
through `project.pbxproj` (two configurations to edit by hand for one key).

### D2. One ed25519 signature over the release zip; the key file is the base64 seed under `~/.config/warpveil/`

`release.sh` signs the **final** zip (after the stapling re-pack) with
`~/.config/warpveil/release-signing.key` (0600, one line: the base64 32-byte seed) through a
`swift -` heredoc — LibreSSL cannot do ed25519, CryptoKit can, and the release machine has
Xcode — and uploads `<zip>.sig` (base64 of the 64-byte signature) next to the zip. The app
verifies the zip's bytes against `WVUpdatePublicKey` **before** anything unpacks it, so `ditto`
only ever sees an archive `release.sh` made. One file, one signature, no manifest: the zip is
what `release.sh` already produces and what GitHub already stores. The signer refuses a key
whose public half is not the one in `Info.plist`, so a release can never go out that every
installed app would refuse. `release.sh` exits before building when the key file or the plist
key is missing: an unsigned release would show up as "available" in every installed app and
fail to install.

Where the private key lives — a file, not the login keychain: `security` prompts for ACL access
on each release unless "Always allow" is clicked, which makes the keychain the same boundary as
a 0600 file with more friction; `*.key` is already gitignored; the directory is the project's
own. **Bootstrap**: the owner generates the key once, puts the public key into `Info.plist`
(a commit of its own), and ships the first release carrying the updater (1.3) **by hand** —
1.2 has no updater, so that release is installed with `install.sh` or a download, as today.
From then on every release is signed and installs itself. **Rotation**: generate the new pair,
put the new public key into `Info.plist`, sign *that* release with the **old** key (installed
apps verify with the old public key, and after installing it carry the new one), then switch
the key file. **Loss or compromise** of the private key: no installed app can be updated OTA
again with that key — generate a new pair, put the public key in, and the next release is a
by-hand install once (a repeat of the bootstrap); a compromised key means revoking by the same
by-hand release, since there is no revocation channel. Recorded in the canon.

### D3. What is refused before anything touches the running bundle

In order, each a `Failure` with the text the Updates row shows: no `WVUpdateFeed` / no
`WVUpdatePublicKey`; the feed not HTTP 200 (a rate limit is a 403 and reads "The update feed
answered HTTP 403"); a body that does not decode as a release; a release whose assets lack
`WarpVeil-<tag minus v>-macOS.zip` or its `.sig` (the `.sig` is mandatory — nothing unsigned is
ever unpacked); either download not HTTP 200; a signature that does not verify over the zip;
`ditto` exiting non-zero; a top-level `WarpVeil.app` that is not a real directory (a symlink
entry, see the facts) or not a bundle; a bundle id other than `Bundle.main.bundleIdentifier`
(the real feed cannot replace a `com.warpveil.app.dev` copy, and vice versa); a bundle version
that is not the tag's version **or** not strictly greater than the running one (a signed older
release replayed under a newer tag is refused on the first condition, a plain downgrade on the
second); an executable without arm64. Only after all of that does the bundle move from the
0700 work directory in `$TMPDIR` to `.WarpVeil.app.new` next to the running one. Zip-slip is
covered twice: by the signature, and by `ditto`'s own path sanitising. Not checked: symlinks
*inside* the bundle — the signature covers the bytes `release.sh` zipped from our build, which
has none; and `codesign --verify` of the unpacked bundle — same reason, and the ad-hoc seal is
not what authenticates it.

### D4. The engines stop first, then a shell outlives the app and swaps the bundles

`AppState.installUpdate` hands `Updater.install` a closure: if `pm.isRunning`, `disconnect()`
then `await pm.awaitTeardown(timeout: 30)`. `awaitTeardown` now returns `true` only when the
stop process exited **0** and xray is gone (step 2): a cancelled password dialog, a `kill_pid_file`
that gave up after 5 s, or 30 s of nothing all cancel the update, remove the staged bundle and
say so in the row. So the new app never starts with the old app's root sing-box holding the
TUN — the failure mode the canon describes for a version bump (the new tag cannot see the old
tag's PID file). Then the helper is spawned and the app calls `NSApp.terminate(nil)`, which goes
through `applicationShouldTerminate` like every quit (`.terminateNow`, the engines are down).
The helper, `/bin/sh -c '<script>' sh <bundle> <staged> <aside> <pid>` — paths as arguments,
nothing interpolated, so no quoting:

```sh
export PATH=/usr/bin:/bin
while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
rm -rf "$3"
mv "$1" "$3" && { mv "$2" "$1" || mv "$3" "$1"; }
rm -rf "$2" "$3"
open -n "$1"
```

Every path ends with an app at `$1`: if the old bundle cannot be moved aside, nothing has
changed and the old app reopens; if the new one cannot be moved in, the old one comes back and
reopens; the staged and the aside copies are removed either way (a leftover `.old` a blocked
`rm -rf` left behind is removed again by the next update's `removeItem` and `rm -rf` before the
renames, so it can never make the `mv` aside fail). A swap that did not happen is visible as the
old version still running and the row offering the update again — the helper has no channel
back into the app, and none was added. The staging path is derived from `Bundle.main.bundleURL`,
not hard-coded to `/Applications`: the dev copy updates itself in its own directory, a copy on
a read-only or translocated path fails at the stage move with the system's error in the row.
Rejected: swapping inside `applicationShouldTerminate` (would put update logic into the quit
path every quit runs); copying with `ditto` into the stage (the work directory and the bundle's
parent are on one volume — a rename is enough, and `FileManager.moveItem` copies across volumes
by itself); an `.old` kept for rollback (nothing would ever use it, and 40 MB hidden in
`/Applications` forever).

### D5. One control in Advanced, one conditional item in the status menu, a daily check

`Section("Updates")` at the bottom of Advanced: the label is `WarpVeil <version>` with a status
line under it, the trailing control is **Check for Updates** (manual check) or, once a newer
release is known, **Install**; disabled while checking or installing. The status line is the
`Updater.State`: "Checked once a day" / "Checking..." / "Up to date" / "Version X is available" /
"Downloading and installing — the app relaunches when done" / the failure text. The status menu
gets `Update to X…` after Open WarpVeil only while an update is known — the window is usually
closed and the status menu is where the user looks; it is the same action. Automatic checks:
15 s after `bootstrap` finishes (the TUN of an auto-connect is up by then; the first check used
to race it) and every 24 h after, in `AppState`, the app lives in the menu bar for weeks. An
automatic check that fails leaves the row as it was (`.idle`): it has no one to report to and
"could not check" at launch is noise; a manual check reports its failure. No notification, no
dialog, no "remind me later", no toggle to turn the check off — one control.

### D6. The GitHub REST API, matched by exact asset name; no ETag; a rate limit is a visible failure

`releases/latest` is documented (non-draft, non-prerelease, newest by `created_at`), returns the
asset list so a missing `.sig` is known before any 40 MB download, and decodes in three fields.
The zip asset is matched by the exact name `release.sh` produces, derived from `tag_name` with
a leading `v` dropped (a tag without `v` works too — verified). No `If-None-Match`: a 304 counts
against the 60/h limit anyway (verified), and two requests a day cannot approach it; the only way
to hit the limit is other users of the same VPN exit — then the manual check shows "HTTP 403"
and the automatic one tries again next day. Rejected: the website's `releases/latest` redirect
(no limit, no JSON, two lines shorter — but undocumented behaviour whose change would break every
installed app until a by-hand release) and authenticating the request (a token in the app).

### D7. The privilege model after an update: two prompts, not reduced; the log now says why

What the user sees on the first launch after an update, with passwordless on in the old version
and auto-connect on:

1. The new build's tag has no sudoers file, so `isPasswordless` is false and the toggle shows
   off. **New in step 1**: Logs shows `[Passwordless install is from another build — turn
   Passwordless on again in Advanced]` (today the line fires only for the same tag with changed
   scripts, so a version bump logs nothing).
2. The auto-connect goes through the osascript path: **password dialog 1**, then the tunnel is
   up through the bundled sing-box, with the config policy applied as in both modes.
3. Advanced → Passwordless on: **password dialog 2**; the install removes the old tag's sudoers
   entry and libexec directory and installs this tag's. Every later connect is silent.

Reducing that to one prompt was considered and is **not done**. The small version — on the
first connect of a build that sees another build's sudoers entry, run `installPasswordless()`
first and connect through `sudo run.sh` once it finishes — is ~16 lines inside
`ProcessManager.connect`, with a re-entry after an asynchronous osascript and a once-per-launch
flag so a cancelled dialog does not loop. Two reasons: `connect` is the function the hardening
plan just rebuilt and reviewed four times — the canon's third-fix signal — and under hardening
D6 it would make *any* build, including a `dev-run.sh` copy, take the passwordless install away
from the installed one at its first connect, behind a prompt that looks like the connect's own
prompt; today only an explicit toggle does that. The gain is one dialog per release. The
alternative of doing both in the connect's single osascript command was rejected outright: it
would put sudoers writes into the connect shell. If the owner wants it later, it is its own
plan, after the parity plan's kill-switch item has settled what `run.sh` looks like.

### D8. Nothing in the update runs as root, and nothing new reaches root

The updater calls `URLSession`, `FileManager`, `/usr/bin/ditto` and `/bin/sh` as the user.
The staged and installed bundle is `lortan29:staff`, exactly what `install.sh` leaves today. The
only way bundle bytes become root's is unchanged: `installPasswordless` copying the bundled
sing-box into `/usr/local/libexec` at an admin prompt the user answers, and `run.sh` running that
copy; the non-passwordless path runs the bundle's sing-box as root only behind the same
dialog. A hostile zip without a valid signature is refused before unpacking; with a valid
signature it is one of ours. A hostile *feed* (a GitHub account takeover) can at most serve one
of our signed releases under a wrong tag, which D3 refuses, or a newer signed release, which is
the owner's. Nothing here reads or writes `/etc/sudoers.d` or `/usr/local/libexec` (step 1 only
**lists** `/etc/sudoers.d`, which is 755).

### D9. Argued away

- **Notarization or a stable self-signed certificate** to keep TCC grants across updates: there
  are no grants (facts). When the parity plan's item 4 adds `UNUserNotificationCenter`, its
  permission will be re-asked after each update as long as the app is ad-hoc signed — noted in
  "Rebasing".
- **A progress bar**: the row says "Downloading and installing"; 40 MB on a tunnel is seconds.
- **Deleting the old tag's sudoers/libexec in the updater**: root, by definition; the next
  passwordless toggle does it (hardening D6).
- **`CFBundleVersion`**: stays `3`; the updater compares `CFBundleShortVersionString`, the tag's
  source of truth in `release.sh`.

## Steps

Each step compiles on its own and is one commit. The diffs below are the scratch copy's diffs,
built with `xcodebuild` after steps 1+2 alone (`repoA`) and after everything (`repo1`, Debug and
Release) — see "Validation of this plan". Steps 1 and 2 are independent of the owner's decision.

### 1. Report a stale passwordless install from any other build

Commit: `Report a stale passwordless install from any other build`.

`Sources/ProcessManager.swift`, before `init()` (`:321`):

```swift
    // Any warpveil sudoers entry that is not this build's working install: this tag with
    // changed scripts or a bumped engine, or the tag of the version an update replaced.
    private static var otherInstallExists: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/etc/sudoers.d")) ?? [])
            .contains { $0.hasPrefix("warpveil") }
    }

    init() {
        if !isPasswordless, Self.otherInstallExists {
            logs.append("[Passwordless install is from another build — turn Passwordless on again in Advanced]")
        }
```

(The `if FileManager.default.fileExists(atPath: Self.sudoersFile), !isPasswordless` line is
replaced; the message is unchanged.)

### 2. `awaitTeardown` reports whether the engines stopped

Commit: `Make awaitTeardown report whether the engines stopped`.

`Sources/ProcessManager.swift:728-738` becomes:

```swift
    // Quit, connect and update need to know when the engines are actually gone. The
    // non-passwordless path puts up a password dialog, so the wait is however long the user
    // takes. True once the stop has exited 0 — a cancelled dialog or a sing-box that outlived
    // kill_pid_file's wait exits 1 — and xray is gone.
    private var teardownProcess: Process?

    @discardableResult
    func awaitTeardown(timeout: TimeInterval) async -> Bool {
        let engines = [teardownProcess, xrayProcess].compactMap { $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while engines.contains(where: \.isRunning), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !engines.contains(where: \.isRunning) && teardownProcess?.terminationStatus == 0
    }
```

The quit path in `WarpVeilApp.swift:94` keeps `await app.pm.awaitTeardown(timeout: 30)` and
ignores the result; `xrayProcess` is captured at entry because its termination handler nils it
asynchronously.

### 3. The updater

Commit: `Add an in-app updater fed by GitHub releases`.

**`Sources/Updater.swift`** (new, 202 lines):

```swift
import AppKit
import CryptoKit

// Over-the-air updates from the GitHub release feed named in Info.plist. Authenticity is our
// own ed25519 signature over the release zip, checked against WVUpdatePublicKey — not Apple's:
// the app is ad-hoc signed. Nothing here runs as root. The new bundle is the user's, like the
// one it replaces, and becomes root's only through the passwordless install at its own prompt.
@Observable
@MainActor
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), installing, failed(String)
    }

    var state: State = .idle

    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    nonisolated static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    private struct Failure: Error {
        let reason: String
    }

    private var release: Release?

    private static let feed = (Bundle.main.object(forInfoDictionaryKey: "WVUpdateFeed") as? String).flatMap(URL.init)
    private static let publicKey = (Bundle.main.object(forInfoDictionaryKey: "WVUpdatePublicKey") as? String)
        .flatMap { Data(base64Encoded: $0) }
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }

    // MARK: - Check

    // An automatic check has no one to report to, so its failure leaves the row as it was.
    func check(manual: Bool = false) async {
        guard state != .checking, state != .installing else { return }
        state = .checking
        do {
            let latest = try await Self.latestRelease()
            release = latest
            state = latest.version.compare(Self.currentVersion, options: .numeric) == .orderedDescending
                ? .available(latest.version) : .upToDate
        } catch {
            release = nil
            state = manual ? .failed(Self.describe(error)) : .idle
        }
    }

    // GitHub's releases/latest is the newest release that is neither a draft nor a prerelease.
    private static func latestRelease() async throws -> Release {
        guard let feed else { throw Failure(reason: "No update feed in Info.plist") }
        guard publicKey != nil else { throw Failure(reason: "No update key in Info.plist") }
        let (data, response) = try await URLSession.shared.data(from: feed)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reason: "The update feed answered HTTP \(status)") }
        guard let release = try? JSONDecoder().decode(Release.self, from: data)
        else { throw Failure(reason: "The update feed is not a GitHub release") }
        return release
    }

    // MARK: - Install

    // Downloads, verifies and unpacks into $TMPDIR, stages the bundle next to the running one,
    // lets the caller stop the engines, then hands the swap to a shell that outlives this
    // process: it waits for the app to exit, renames the bundles and opens the new one. The
    // engines go down before the swap so the new app never finds the old one's TUN, and a
    // teardown that does not finish — a password dialog left unanswered — cancels the update.
    func install(stopEngines: () async -> Bool) async {
        guard let release, let key = Self.publicKey else {
            state = .failed("No update checked")
            return
        }
        state = .installing
        let bundle = Bundle.main.bundleURL
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).new")
        let aside = bundle.deletingLastPathComponent().appendingPathComponent(".\(bundle.lastPathComponent).old")
        try? FileManager.default.removeItem(at: aside)
        do {
            try await Self.download(release, key: key, into: staged)
        } catch {
            state = .failed(Self.describe(error))
            return
        }
        guard await stopEngines() else {
            try? FileManager.default.removeItem(at: staged)
            state = .failed("The tunnel did not stop — update cancelled")
            return
        }
        // Whatever the renames do, "$1" is an app at the end: the new one, or the old one back.
        let script = """
            export PATH=/usr/bin:/bin
            while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
            rm -rf "$3"
            mv "$1" "$3" && { mv "$2" "$1" || mv "$3" "$1"; }
            rm -rf "$2" "$3"
            open -n "$1"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", bundle.path, staged.path, aside.path,
                            String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try helper.run()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            state = .failed(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    // The signature is checked over the zip's bytes before anything unpacks it, so ditto only
    // ever sees an archive release.sh made.
    private nonisolated static func download(_ release: Release, key: Curve25519.Signing.PublicKey, into staged: URL) async throws {
        let zipName = "WarpVeil-\(release.version)-macOS.zip"  // release.sh's ZIP_NAME
        guard let zip = release.assets.first(where: { $0.name == zipName }),
              let sig = release.assets.first(where: { $0.name == zipName + ".sig" })
        else { throw Failure(reason: "Release \(release.version) has no signed \(zipName)") }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("warpveil-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent(zipName)
        try FileManager.default.moveItem(at: try await fetch(zip.url), to: archive)
        let encoded = try Data(contentsOf: try await fetch(sig.url))
        guard let signature = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              key.isValidSignature(signature, for: try Data(contentsOf: archive, options: .mappedIfSafe))
        else { throw Failure(reason: "The signature does not match — not installed") }

        let unpacked = work.appendingPathComponent("unpacked")
        try unzip(archive, into: unpacked)
        let bundle = unpacked.appendingPathComponent("WarpVeil.app")
        try verify(bundle: bundle, version: release.version)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: bundle, to: staged)
    }

    // A download gets no quarantine attribute: the file is the app's own, not Finder's.
    private nonisolated static func fetch(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reason: "\(url.lastPathComponent): HTTP \(status)") }
        return file
    }

    private nonisolated static func unzip(_ archive: URL, into dir: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(reason: "Could not unpack the archive") }
    }

    // What release.sh zipped and nothing else: a real WarpVeil.app with this bundle id, the
    // version the tag names and newer than this one, an arm64 executable.
    private nonisolated static func verify(bundle: URL, version: String) throws {
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false, let new = Bundle(url: bundle)
        else { throw Failure(reason: "The archive holds no app") }
        guard new.bundleIdentifier == Bundle.main.bundleIdentifier
        else { throw Failure(reason: "The app in the archive is not \(Bundle.main.bundleIdentifier ?? "this app")") }
        guard new.infoDictionary?["CFBundleShortVersionString"] as? String == version,
              version.compare(currentVersion, options: .numeric) == .orderedDescending
        else { throw Failure(reason: "The archive is not version \(version), newer than \(currentVersion)") }
        guard new.executableArchitectures?.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true
        else { throw Failure(reason: "The app in the archive is not arm64") }
    }

    private static func describe(_ error: Error) -> String {
        (error as? Failure)?.reason ?? error.localizedDescription
    }
}
```

`download`, `fetch`, `unzip` and `verify` are `nonisolated static` so the 40 MB download, the
signature check and `ditto` (`waitUntilExit`, ~0.5 s) run off the main actor; `currentVersion`
is `nonisolated` because `verify` reads it (a main-actor `static let` there is a warning today
and an error in Swift 6).

**`WarpVeil.xcodeproj/project.pbxproj`** — the file registered in the four places, ids
`AA000000000000000000001D` / `BB000000000000000000001D` (unused today; `plutil -lint` passes):

```
 		AA000000000000000000001C /* PingService.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB000000000000000000001C /* PingService.swift */; };
+		AA000000000000000000001D /* Updater.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB000000000000000000001D /* Updater.swift */; };
…
 		BB000000000000000000001C /* PingService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PingService.swift; sourceTree = "<group>"; };
+		BB000000000000000000001D /* Updater.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Updater.swift; sourceTree = "<group>"; };
…
 				BB000000000000000000001C /* PingService.swift */,
+				BB000000000000000000001D /* Updater.swift */,
 			);
 			path = Sources;
…
 				AA000000000000000000001C /* PingService.swift in Sources */,
+				AA000000000000000000001D /* Updater.swift in Sources */,
 			);
 			runOnlyForDeploymentPostprocessing = 0;
```

**`Info.plist`**, after `LSMinimumSystemVersion` — the public key stays empty in this commit;
the owner's key commit fills it (see "After the steps"); until then the row says "No update key
in Info.plist" and nothing else changes:

```xml
	<key>WVUpdateFeed</key>
	<string>https://api.github.com/repos/redoran29/WarpVeil/releases/latest</string>
	<key>WVUpdatePublicKey</key>
	<string></string>
```

**`Sources/AppState.swift`**:

```swift
     let ping = PingService()
+    let updater = Updater()
…
     private var locationTask: Task<Void, Never>?
+    private var updateTimer: Timer?
…
         isBootstrapped = true
+        startUpdateChecks()
     }
…
     func routingChanged() {
         pm.reconnect(bypassDomains: activeBypassDomains)
     }

+    // MARK: - Updates
+
+    // Once after launch, then daily: the app lives in the menu bar for weeks at a time. The
+    // first check waits out the TUN coming up under an auto-connect.
+    private func startUpdateChecks() {
+        Task {
+            try? await Task.sleep(for: .seconds(15))
+            await updater.check()
+        }
+        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
+            Task { @MainActor in await self?.updater.check() }
+        }
+    }
+
+    func installUpdate() {
+        Task {
+            await updater.install {
+                guard pm.isRunning else { return true }
+                disconnect()
+                return await pm.awaitTeardown(timeout: 30)
+            }
+        }
+    }
+
     // MARK: - Location polling
```

**`Sources/AdvancedView.swift`** — after `Section("Components")`'s closing brace, inside the
`Form`, and a computed property after `body`:

```swift
            Section("Updates") {
                LabeledContent {
                    if app.updater.availableVersion != nil {
                        Button("Install") { app.installUpdate() }
                    } else {
                        Button("Check for Updates") { Task { await app.updater.check(manual: true) } }
                    }
                } label: {
                    Text("WarpVeil \(Updater.currentVersion)")
                    Text(updateStatus)
                }
                .disabled(app.updater.state == .checking || app.updater.state == .installing)
            }
        }
        .formStyle(.grouped)
    }

    private var updateStatus: String {
        switch app.updater.state {
        case .idle: "Checked once a day"
        case .checking: "Checking..."
        case .upToDate: "Up to date"
        case .available(let version): "Version \(version) is available"
        case .installing: "Downloading and installing — the app relaunches when done"
        case .failed(let reason): reason
        }
    }
```

**`Sources/WarpVeilApp.swift`** `menuNeedsUpdate`, after the Open WarpVeil item, and the
action next to `openAction`:

```swift
        if let version = app.updater.availableVersion {
            let update = NSMenuItem(title: "Update to \(version)…", action: #selector(updateAction), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(.separator())
…
    @objc private func openAction() { showWindow() }
    @objc private func updateAction() { app.installUpdate() }
```

**`dev-run.sh`** `build_dev`, after the `CFBundleName` line:

```bash
    # The dev copy never checks GitHub: a release is always newer than "<version>-dev" and
    # would be offered, then refused for its bundle id after a 40 MB download.
    /usr/libexec/PlistBuddy -c "Delete :WVUpdateFeed" "$plist"
```

Behaviour after the step: Advanced shows an Updates section reading `WarpVeil 1.2` / "No update
key in Info.plist" after a manual check (the key is empty); nothing else changes. With the key
in: 15 s after launch the row reads "Up to date" (v1.2 is the latest release and not newer)
until the first signed release exists.

### 4. `release.sh` signs the zip and uploads the signature

Commit: `Sign release zips for the in-app updater`.

Header comment, after the notarization paragraph:

```bash
#
# The zip is signed with the ed25519 release key (see CLAUDE.md, "In-app updates") and the
# signature is uploaded next to it: an installed app updates itself only from a release that
# carries a signature its WVUpdatePublicKey accepts.
```

After `TAG="v${VERSION}"`:

```bash
# --- Release signing key: refuse early, an unsigned release is one no installed app accepts ---
SIGNING_KEY="${HOME}/.config/warpveil/release-signing.key"
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :WVUpdatePublicKey" Info.plist)
if [ ! -f "$SIGNING_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: release signing needs $SIGNING_KEY and WVUpdatePublicKey in Info.plist" >&2
    echo "       see CLAUDE.md, \"In-app updates\"" >&2
    exit 1
fi

# Prints the base64 ed25519 signature of $1. The key file is the base64 32-byte seed; it must
# be the pair of the public key the app carries, or every installed app would refuse the release.
sign_zip() {
    swift - "$SIGNING_KEY" "$1" "$PUBLIC_KEY" <<'EOF'
import CryptoKit
import Foundation
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
let args = CommandLine.arguments
guard let seed = Data(base64Encoded: try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else { fail("ERROR: \(args[1]) is not a base64 ed25519 seed") }
guard key.publicKey.rawRepresentation.base64EncodedString() == args[3]
else { fail("ERROR: the key is not the pair of WVUpdatePublicKey in Info.plist") }
let data = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
print(try key.signature(for: data).base64EncodedString())
EOF
}
```

After `echo "Packaged ${ZIP_NAME} (${ZIP_SIZE})"` — i.e. after the notarization block, whose
stapling re-packages the zip:

```bash
# --- Sign the final zip (after stapling, which repackages it) ---
SIG_NAME="${ZIP_NAME}.sig"
sign_zip "$BUILD_DIR/$ZIP_NAME" > "$BUILD_DIR/$SIG_NAME"
echo "Signed ${SIG_NAME}"
```

The release notes gain a line after the Install list: `An installed ${APP_NAME} 1.3 or newer
updates itself from here (Advanced → Updates).`, and the upload becomes:

```bash
gh release create "$TAG" \
    "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$SIG_NAME" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"
```

Both signing paths are kept: ad-hoc builds and Developer ID builds get the same `.sig`; with
`NOTARY_PROFILE` the signature is of the stapled zip. `bash -n` passes. `fail` prints one line
and exits 1 (a `fatalError` printed a 40-line stack dump); under `set -e` that aborts the
release before the tag is pushed.

### 5. Canon and README

Commit: `Record the in-app updater in the canon`. The wording is in "Canon updates". Then move
this file to `plans/done/` and run `/code-review` (canon workflow, step 3).

### After the steps: the owner's part

Not commits of this plan, but the updater does nothing until they are done:

1. Generate the key once (0600, outside the repo):

   ```bash
   mkdir -p ~/.config/warpveil && (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > ~/.config/warpveil/release-signing.key)
   swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' ~/.config/warpveil/release-signing.key
   ```

   The second line prints the 44-character public key. (Both lines ran here with a throwaway
   path.)
2. Paste it into `Info.plist`'s `WVUpdatePublicKey`; commit `Carry the release signing public
   key`.
3. Bump `CFBundleShortVersionString` to `1.3`, `./release.sh`. This first updater release is
   installed **by hand** (`./install.sh`, or the zip) — 1.2 cannot update itself. From 1.4 on,
   the installed app offers the release.

## Canon updates

`CLAUDE.md` — replacements, by section:

- Architecture tree, after `BypassService.swift`:
  `├── Updater.swift              # In-app updates: GitHub release feed, ed25519 check, swap and relaunch`.
- "Build & Run", item 3: `` `./release.sh` for a signed + notarized build (`NOTARY_PROFILE`
  required for notarization); it also signs the zip with the release key (below) and uploads
  `<zip>.sig` — without the key it refuses to run ``.
- "Build & Run", new subsection after `install.sh`:

```
### Release signing key

The updater trusts only a zip signed with the project's ed25519 key. Private half:
`~/.config/warpveil/release-signing.key`, 0600, one line, the base64 32-byte seed; public half:
`WVUpdatePublicKey` in `Info.plist`. One-time setup:

    mkdir -p ~/.config/warpveil && (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > ~/.config/warpveil/release-signing.key)
    swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' ~/.config/warpveil/release-signing.key

The second line prints the public key to paste into `Info.plist`. `release.sh` checks that the
file is the pair of that key and signs through `swift -` (LibreSSL has no ed25519). Rotation:
put the new public key into `Info.plist` and sign that one release with the old key; installed
apps verify it with the key they carry and then carry the new one. A lost or leaked key cannot
be revoked: generate a new pair, and the next release is installed by hand once — the same as
the first updater release, which 1.2 could not install itself.
```

- "dev-run.sh" section, after the isolation paragraph: `The dev copy has no `WVUpdateFeed`
  (`build_dev` deletes it): a real release is always newer than `<version>-dev` and would be
  offered, then refused for its bundle id. The live check of an updater change adds its own feed
  and key with `PlistBuddy`, the way `build_dev` sets the version.`
- Key Decisions, replace `**Binary upgrades ship with the app**: no in-app updater; bump the
  pinned tags in `fetch-binaries.sh` and cut a release` with:

```
- **In-app updates** (owner's decision of 2026-10-14, reversing "no in-app updater"):
  `Updater` reads `WVUpdateFeed` (GitHub's `releases/latest` for `redoran29/WarpVeil`: newest
  non-draft, non-prerelease) 15 s after bootstrap, daily, and on Check for Updates in Advanced;
  a `CFBundleShortVersionString` numerically newer than the running one shows Install there and
  `Update to X…` in the status menu. Authenticity is our own ed25519 signature over the release
  zip, checked with CryptoKit against `WVUpdatePublicKey` **before** the zip is unpacked —
  Apple's signature is ad-hoc and proves nothing. The unpacked `WarpVeil.app` must be a real
  directory with our bundle id, the tag's version, newer than the running one, arm64; anything
  else is refused with its reason in the row. It is staged as `.WarpVeil.app.new` next to the
  running bundle (wherever that is — not hard-coded to `/Applications`), the engines are stopped
  first (`awaitTeardown` false — a cancelled dialog, a stop that exited 1 — cancels the update),
  and a `/bin/sh` helper spawned before `NSApp.terminate` waits for the process to exit, renames
  old → `.old`, new → in place (or the old back), removes the rest and `open -n`s the result. No
  root anywhere: the new bundle is the user's, as before. A download by the app carries no
  quarantine attribute, and the ad-hoc swap in a scratch directory raised no App Management
  prompt; `/Applications` itself is checked by `update-live.sh apps-probe`. No ETag (a 304 counts
  against GitHub's 60/h anyway), no notification, no toggle. Engine upgrades still ship with the
  app: bump the pinned tags in `fetch-binaries.sh` and cut a release
```

- Key Decisions, "Version-tagged privileged paths", after "every version bump re-asks for the
  password once": `— after an in-app update that is the first connect's dialog, then the
  Passwordless toggle's (the install for the new tag); the log says `[Passwordless install is
  from another build…]` at launch when any other tag's sudoers entry exists`.
- Runtime Files: add `` `$TMPDIR/warpveil-update-<pid>/` — an update's download and unpack
  directory, 0700, removed when the update is staged or refused `` and `` `<bundle dir>/.WarpVeil.app.new`,
  `.WarpVeil.app.old` — the update being swapped in, and the old bundle on its way out; both
  gone after the relaunch ``.
- Gotchas, add:

```
- A file the app downloads with `URLSession` gets `com.apple.provenance` only, never
  `com.apple.quarantine`; Gatekeeper assesses quarantined files only, so a bundle the app
  unpacked launches like one `install.sh` copied
- `ditto -x -k` strips `..` and leading `/` from entry names but recreates a symlink entry —
  check the unpacked top level is a real directory
- Editing an ad-hoc app's `Info.plist` breaks `codesign --verify` and the app still launches
  with the edited value; editing its executable keeps it from launching
- A conditional GitHub API request that returns 304 still counts against the unauthenticated
  60/h limit (observed), so an ETag saves nothing
- `swift - args <<'EOF'` runs a Swift script from stdin with the args in `CommandLine.arguments`;
  `swift -e` takes one `import` per statement. LibreSSL's `openssl` has no ed25519
- A `@MainActor` task cannot run while the main thread waits in a semaphore — a command-line
  harness that drives a main-actor class ends in `dispatchMain()`
```

`README.md`: Features gains `- **In-app updates** — checks GitHub releases daily and installs
only a release signed with the project's ed25519 key`; the Release section gains `The zip is
signed with `~/.config/warpveil/release-signing.key` (see CLAUDE.md, "Release signing key") and
the signature is uploaded with it; installed apps update themselves from Advanced → Updates.`;
the Architecture tree gains `Updater.swift`.

## Rebasing the queued plans

- `plans/client-feature-parity.md` — "Already there, or already decided" (`:209-210`) lists
  "In-app updater: canon, 'Binary upgrades ship with the app'; an updater is also an external
  package (Sparkle) which the canon excludes" — that bullet is stale once step 5 lands; it should
  read "In-app updater: built (plans/done/in-app-updater.md); engine upgrades still ship with
  the app". Item 4 (`:1761-1784`, `UNUserNotificationCenter`): the notification permission is a
  TCC grant tied to the cdhash, and every in-app update produces a new ad-hoc cdhash — expect the
  permission to be asked again after each update; item 4 should say so (or the owner gets a
  Developer ID). Items 3, 4, 10, 14, 15 add rows and sections to `AdvancedView`'s `Form`: the
  Updates section stays **last**. Item 9 (`:1931`) adds a Server submenu to `menuNeedsUpdate`:
  the `Update to X…` item stays after Open WarpVeil, before the separator. Item 9 also says
  `pm.connect` "parks itself until the stop it finds in `teardownProcess` has exited" — still
  true; `awaitTeardown`'s new return value does not change that. Item 3 (kill switch) changes
  `run.sh`, so its deploy re-asks the Passwordless toggle like any `run.sh` change — unrelated to
  updates, but every later release that touches `run.sh` costs the same two dialogs D7 describes.
- `plans/xray-hostname-server.md` — touches `ProcessManager.connect`, the `.xray` branch and
  `buildTunWrapperConfig`, none of which this plan edits; its live check installs with
  `install.sh`, unaffected. Applies as written.

## Verification

### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
```

Expect `BUILD SUCCEEDED` after each step and no `Sources/` warnings (clean here after steps 1+2
and after all steps, Debug and Release). Never `swift build`.

### 2. Pipeline harness: the real `Updater.swift` against a local feed, no app launched

Compiles `Sources/Updater.swift` (with `private` stripped from a copy, nothing else changed) and
a `main.swift` into a throwaway `Harness.app` whose `Info.plist` carries the app's bundle id,
version `1.2`, a throwaway public key and a feed on `127.0.0.1:8766`, then runs the download →
verify → unpack → verify → stage pipeline over a good release and twelve hostile ones, and
`check()` over good, missing, not-a-release, empty-key and no-feed feeds. This exact harness ran
green in this run (results under "Validation of this plan").

```bash
H="$TMPDIR/updater-harness"; REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"; mkdir -p "$H/feed" "$H/Harness.app/Contents/MacOS" "$H/staged" "$H/apps"; cd "$H"
(umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > key)
PUB=$(swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' key)
SIGNING_KEY="$H/key"; PUBLIC_KEY="$PUB"; eval "$(sed -n '/^sign_zip() {/,/^}/p' "$REPO/release.sh")"
# a Release build to cut releases from (any built WarpVeil.app works; this one is the repo's)
(cd "$REPO" && xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Release -derivedDataPath "$H/dd" CONFIGURATION_BUILD_DIR="$H/rel" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build)
mk_release() {  # $1 label, $2 version, $3 bundle id, $4 zip name
    rm -rf "apps/$1"; mkdir -p "apps/$1"; ditto "$H/rel/WarpVeil.app" "apps/$1/WarpVeil.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleIdentifier $3" "apps/$1/WarpVeil.app/Contents/Info.plist"
    codesign --force --sign - "apps/$1/WarpVeil.app" 2>/dev/null
    (cd "apps/$1" && ditto -c -k --sequesterRsrc --keepParent WarpVeil.app "$H/feed/$4"); sign_zip "feed/$4" > "feed/$4.sig"
}
mk_release good 1.3 com.warpveil.app WarpVeil-1.3-macOS.zip
mk_release wrongid 1.3 com.warpveil.app.dev WarpVeil-1.3-macOS-wrongid.zip
mk_release old 1.1 com.warpveil.app WarpVeil-1.1-macOS.zip
mk_release same 1.2 com.warpveil.app WarpVeil-1.2-macOS.zip
rm -rf apps/noarch; mkdir -p apps/noarch; ditto apps/good/WarpVeil.app apps/noarch/WarpVeil.app; printf '#!/bin/sh\n' > apps/noarch/WarpVeil.app/Contents/MacOS/WarpVeil
(cd apps/noarch && ditto -c -k --keepParent WarpVeil.app "$H/feed/WarpVeil-1.3-macOS-noarch.zip"); sign_zip feed/WarpVeil-1.3-macOS-noarch.zip > feed/WarpVeil-1.3-macOS-noarch.zip.sig
python3 -I - "$H/feed" <<'PY'
import zipfile, sys, os
base = sys.argv[1]
with zipfile.ZipFile(os.path.join(base, "WarpVeil-1.3-macOS-slip.zip"), "w") as z:   # zip-slip entries
    z.writestr("WarpVeil.app/Contents/Info.plist", "ok"); z.writestr("../target/escaped.txt", "ESCAPED"); z.writestr("/tmp/abs-escaped.txt", "ABS")
with zipfile.ZipFile(os.path.join(base, "WarpVeil-1.3-macOS-toplink.zip"), "w") as z:  # WarpVeil.app is a symlink to /Applications
    zi = zipfile.ZipInfo("WarpVeil.app"); zi.create_system = 3; zi.external_attr = (0o120777 << 16); z.writestr(zi, "/Applications")
PY
for z in slip toplink; do sign_zip "feed/WarpVeil-1.3-macOS-$z.zip" > "feed/WarpVeil-1.3-macOS-$z.zip.sig"; done
head -c 100000 feed/WarpVeil-1.3-macOS.zip > feed/WarpVeil-1.3-macOS-trunc.zip; sign_zip feed/WarpVeil-1.3-macOS-trunc.zip > feed/WarpVeil-1.3-macOS-trunc.zip.sig
sign_zip feed/WarpVeil-1.1-macOS.zip > feed/other.sig
feed() { local f="$1" tag="$2"; shift 2; local a=""; for p in "$@"; do a="$a{\"name\":\"${p%%=*}\",\"browser_download_url\":\"http://127.0.0.1:8766/${p#*=}\"},"; done; printf '{"tag_name":"%s","draft":false,"prerelease":false,"assets":[%s]}' "$tag" "${a%,}" > "feed/$f"; }
Z=WarpVeil-1.3-macOS.zip
feed good.json v1.3 "$Z=$Z" "$Z.sig=$Z.sig";                 feed badsig.json v1.3 "$Z=$Z" "$Z.sig=other.sig"
feed nosig.json v1.3 "$Z=$Z";                                feed wrongid.json v1.3 "$Z=WarpVeil-1.3-macOS-wrongid.zip" "$Z.sig=WarpVeil-1.3-macOS-wrongid.zip.sig"
feed tagmismatch.json v1.4 "WarpVeil-1.4-macOS.zip=$Z" "WarpVeil-1.4-macOS.zip.sig=$Z.sig"
feed downgrade.json v1.1 "WarpVeil-1.1-macOS.zip=WarpVeil-1.1-macOS.zip" "WarpVeil-1.1-macOS.zip.sig=WarpVeil-1.1-macOS.zip.sig"
feed same.json v1.2 "WarpVeil-1.2-macOS.zip=WarpVeil-1.2-macOS.zip" "WarpVeil-1.2-macOS.zip.sig=WarpVeil-1.2-macOS.zip.sig"
for v in noarch toplink slip trunc; do feed $v.json v1.3 "$Z=WarpVeil-1.3-macOS-$v.zip" "$Z.sig=WarpVeil-1.3-macOS-$v.zip.sig"; done
feed missing.json v1.3 "$Z=nope.zip" "$Z.sig=$Z.sig";        feed notag.json 1.3 "$Z=$Z" "$Z.sig=$Z.sig"
echo '{"message":"API rate limit exceeded"}' > feed/ratelimit.json
sed 's/private //g' "$REPO/Sources/Updater.swift" > Updater.swift
cat > main.swift <<'EOF'
import AppKit
import CryptoKit
let args = CommandLine.arguments
let pub = Bundle.main.object(forInfoDictionaryKey: "WVUpdatePublicKey") as? String ?? ""
let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: pub) ?? Data())
let staged = URL(fileURLWithPath: args[2])
Task { @MainActor in
    if args[1] == "check" {
        let u = Updater(); await u.check(manual: args[3] == "manual"); print("check(\(args[3])) -> \(u.state)"); exit(0)
    }
    do {
        let (data, _) = try await URLSession.shared.data(from: URL(string: args[1])!)
        let release = try JSONDecoder().decode(Updater.Release.self, from: data)
        try await Updater.download(release, key: key!, into: staged)
        let b = Bundle(url: staged)!
        print("OK staged \(b.bundleIdentifier ?? "nil") \(b.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
    } catch { print("REFUSED: \((error as? Updater.Failure)?.reason ?? error.localizedDescription)") }
    exit(0)
}
dispatchMain()
EOF
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Harness</string><key>CFBundleIdentifier</key><string>com.warpveil.app</string><key>CFBundleShortVersionString</key><string>1.2</string><key>CFBundlePackageType</key><string>APPL</string><key>WVUpdateFeed</key><string>http://127.0.0.1:8766/good.json</string><key>WVUpdatePublicKey</key><string>%s</string></dict></plist>\n' "$PUB" > Harness.app/Contents/Info.plist
swiftc -O -target arm64-apple-macosx14.0 -o Harness.app/Contents/MacOS/Harness Updater.swift main.swift 2>&1 | rg -v "warning: "
(cd feed && python3 -m http.server 8766 --bind 127.0.0.1 > "$H/http.log" 2>&1 &); sleep 1
run() { rm -rf "$H/staged/WarpVeil.app"; printf '%-12s ' "$1"; Harness.app/Contents/MacOS/Harness "http://127.0.0.1:8766/$1.json" "$H/staged/WarpVeil.app"; }
for c in good badsig nosig wrongid tagmismatch downgrade same noarch toplink slip trunc missing notag; do run "$c"; done
echo "escaped by slip: $(ls "$TMPDIR/target" 2>&1 | head -1)"; echo "work dirs left: $(ls -d "$TMPDIR"/warpveil-update-* 2>/dev/null | wc -l | tr -d ' ')"
run good > /dev/null; echo "staged: $(xattr -l "$H/staged/WarpVeil.app" | tr '\n' ' ') codesign: $(codesign --verify --deep --strict "$H/staged/WarpVeil.app" 2>&1 && echo valid)"
P=Harness.app/Contents/MacOS/Harness; $P check x auto; $P check x manual
sed -i '' 's#good.json#missing-feed.json#' Harness.app/Contents/Info.plist; $P check x auto; $P check x manual
sed -i '' 's#missing-feed.json#same.json#' Harness.app/Contents/Info.plist; $P check x manual
sed -i '' 's#same.json#ratelimit.json#' Harness.app/Contents/Info.plist; $P check x manual
/usr/libexec/PlistBuddy -c "Set :WVUpdatePublicKey " Harness.app/Contents/Info.plist; $P check x manual
/usr/libexec/PlistBuddy -c "Delete :WVUpdateFeed" Harness.app/Contents/Info.plist; $P check x manual
pkill -f "http.server 8766"
```

Expect, exactly: `good OK staged com.warpveil.app 1.3` · `badsig REFUSED: The signature does
not match — not installed` · `nosig REFUSED: Release 1.3 has no signed WarpVeil-1.3-macOS.zip`
· `wrongid REFUSED: The app in the archive is not com.warpveil.app` · `tagmismatch REFUSED: The
archive is not version 1.4, newer than 1.2` · `downgrade … not version 1.1, newer than 1.2` ·
`same … not version 1.2, newer than 1.2` · `noarch REFUSED: The app in the archive is not arm64`
· `toplink REFUSED: The archive holds no app` · `slip REFUSED: The app in the archive is not
com.warpveil.app` · `trunc` two `ditto:` lines then `REFUSED: Could not unpack the archive` ·
`missing REFUSED: nope.zip: HTTP 404` · `notag OK staged com.warpveil.app 1.3`; nothing escaped
to `$TMPDIR/target`, 0 work dirs left; the staged bundle has `com.apple.provenance` only and a
valid seal; then `available("1.3")` twice, `idle` and `failed("The update feed answered HTTP
404")`, `upToDate`, `failed("The update feed is not a GitHub release")`, `failed("No update key
in Info.plist")`, `failed("No update feed in Info.plist")`.

### 3. Live check (main session, one script, interactive at two points)

Everything happens on a dev copy built from the working tree into `$TMPDIR/update-live/app`
(bundle id `com.warpveil.app.dev`, version `1.2-dev`), pointed at a feed on `127.0.0.1:8767`
signed with a throwaway key, whose "release" is the same build at `1.2-dev-updated`. The dev
copy's `autoConnect` is forced off for the run and restored at `stop`, so no engine starts and
the installed app and its tunnel are never touched. **Two clicks are the user's** (or the main
session's through computer use): the script says what to click and waits for Enter, then
checks the result on disk and in `ps` — it never reads the UI. `apps-probe` is the
`/Applications` App Management probe this session could not run (write access to
`/Applications` was refused here): a throwaway ad-hoc app that replaces itself there with the
updater's helper and is removed again.

```bash
cat > "$TMPDIR/update-live.sh" <<'EOF'
#!/bin/bash
# Live check for plans/in-app-updater.md. Everything happens on a dev copy (bundle id
# com.warpveil.app.dev, version <v>-dev) built from the working tree into $W/app and pointed at
# a feed on 127.0.0.1 signed with a throwaway key; the "release" it installs is the same build
# at version <v>-dev-updated. /Applications/WarpVeil.app and the tunnel are never touched: the
# dev copy's autoConnect is forced off for the run and restored at stop.
#
#   update-live.sh setup   build, key, feed, server, launch the dev copy (window appears)
#   update-live.sh bad     feed serves a wrong signature — click Install, then Enter: refused
#   update-live.sh good    feed serves the real one — click Install, then Enter: installed
#   update-live.sh stop    quit the dev copy, stop the server, restore the dev defaults
#   update-live.sh apps-probe   optional: a throwaway ad-hoc app replaces itself in
#                               /Applications the way the updater does; cleaned up after
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
W="${TMPDIR%/}/update-live"; mkdir -p "$W"
APP="$W/app/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"; PLIST="$APP/Contents/Info.plist"
DEV_ID="com.warpveil.app.dev"; PORT=8767; FEED="http://127.0.0.1:$PORT"
fails=0
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
ok()  { log "ok   $*"; }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
dev_pid() { pgrep -f "^${BIN}$" | head -1; }
dev_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null; }
serve() { # $1: json to serve as latest.json
    cp "$W/feed/$1" "$W/feed/latest.json"
    if ! { [ -f "$W/http.pid" ] && kill -0 "$(cat "$W/http.pid")" 2>/dev/null; }; then
        (cd "$W/feed" && python3 -m http.server "$PORT" --bind 127.0.0.1 > "$W/http.log" 2>&1 & echo $! > "$W/http.pid")
        sleep 1
    fi
    curl -sf -o /dev/null "$FEED/latest.json" && ok "feed serves $1" || bad "feed not reachable on $PORT"
}
wait_click() { # $1 what to expect
    echo ""
    echo ">>> In the dev copy: Advanced → Updates → Check for Updates if that is what the button says, then Install (or the status menu's \"Update to …\")."
    echo ">>> Expected: $1"
    read -r -p ">>> Press Enter when done. "
}

case "${1:-}" in
setup)
    [ -z "$(dev_pid)" ] || { bad "a dev copy from $W is already running — run: $0 stop"; exit 1; }
    pgrep -f "^${REPO}/build-dev/WarpVeil.app/Contents/MacOS/WarpVeil$" >/dev/null && { bad "a dev-run.sh copy is running — ./dev-run.sh --stop first (same bundle id)"; exit 1; }
    mkdir -p "$W/feed"
    defaults read "$DEV_ID" autoConnect > "$W/autoConnect.prev" 2>/dev/null || echo none > "$W/autoConnect.prev"
    defaults write "$DEV_ID" autoConnect -bool false
    BASE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$REPO/Info.plist")
    CUR="${BASE}-dev"; NEXT="${BASE}-dev-updated"
    echo "$CUR" > "$W/cur"; echo "$NEXT" > "$W/next"

    log "throwaway signing key"
    (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > "$W/key")
    PUB=$(swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' "$W/key")
    [ ${#PUB} -eq 44 ] && ok "public key $PUB" || { bad "no public key"; exit 1; }

    log "building the dev copy from the working tree (Debug, $DEV_ID)"
    rm -rf "$W/app" "$W/next"; mkdir -p "$W/app" "$W/next"
    (cd "$REPO" && xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
        -derivedDataPath "$W/derived" CONFIGURATION_BUILD_DIR="$W/build" \
        PRODUCT_BUNDLE_IDENTIFIER="$DEV_ID" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build) || { bad "build failed"; exit 1; }
    ditto "$W/build/WarpVeil.app" "$APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CUR" -c "Set :CFBundleName WarpVeil Dev" \
        -c "Set :WVUpdateFeed $FEED/latest.json" -c "Set :WVUpdatePublicKey $PUB" "$PLIST"
    codesign --force --sign - "$APP" 2>/dev/null
    ok "dev copy $CUR at $APP, feed $FEED/latest.json"

    log "the release: the same build at $NEXT, zipped and signed the way release.sh does"
    ditto "$APP" "$W/next/WarpVeil.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$W/next/WarpVeil.app/Contents/Info.plist"
    codesign --force --sign - "$W/next/WarpVeil.app" 2>/dev/null
    ZIP="WarpVeil-${NEXT}-macOS.zip"
    (cd "$W/next" && ditto -c -k --sequesterRsrc --keepParent WarpVeil.app "$W/feed/$ZIP")
    SIGNING_KEY="$W/key"; PUBLIC_KEY="$PUB"
    eval "$(sed -n '/^sign_zip() {/,/^}/p' "$REPO/release.sh")"
    sign_zip "$W/feed/$ZIP" > "$W/feed/$ZIP.sig" || { bad "sign_zip failed"; exit 1; }
    head -c 1000 /dev/urandom > "$W/feed/other.bin"; sign_zip "$W/feed/other.bin" > "$W/feed/other.sig"
    printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s/%s"},{"name":"%s.sig","browser_download_url":"%s/%s.sig"}]}\n' \
        "$NEXT" "$ZIP" "$FEED" "$ZIP" "$ZIP" "$FEED" "$ZIP" > "$W/feed/good.json"
    printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s/%s"},{"name":"%s.sig","browser_download_url":"%s/other.sig"}]}\n' \
        "$NEXT" "$ZIP" "$FEED" "$ZIP" "$ZIP" "$FEED" > "$W/feed/bad.json"
    ok "release $ZIP ($(du -h "$W/feed/$ZIP" | cut -f1)) + .sig, feeds good.json / bad.json"
    serve good.json
    stat -f '%m' /Applications/WarpVeil.app/Contents/Info.plist > "$W/installed.mtime" 2>/dev/null || echo 0 > "$W/installed.mtime"

    open -n "$APP"
    sleep 3
    [ -n "$(dev_pid)" ] && ok "dev copy running, pid $(dev_pid)" || { bad "dev copy did not start"; exit 1; }
    log "the launch check runs ~15 s after bootstrap; the Updates row should then say \"Version $NEXT is available\""
    log "next: $0 bad   (or straight to: $0 good)"
    ;;
bad)
    [ -n "$(dev_pid)" ] || { bad "dev copy not running — $0 setup"; exit 1; }
    serve bad.json
    PID_BEFORE=$(dev_pid); CUR=$(cat "$W/cur")
    wait_click "the row says \"The signature does not match — not installed\"; the app stays open"
    [ "$(dev_pid)" = "$PID_BEFORE" ] && ok "same process, pid $PID_BEFORE" || bad "the process changed or exited (pid $(dev_pid))"
    [ "$(dev_version)" = "$CUR" ] && ok "bundle still $CUR" || bad "bundle version is $(dev_version)"
    [ -e "$W/app/.WarpVeil.app.new" ] && bad ".WarpVeil.app.new left behind" || ok "nothing staged"
    ls -d "$TMPDIR"/warpveil-update-* >/dev/null 2>&1 && bad "work dir left in \$TMPDIR" || ok "no work dir left in \$TMPDIR"
    rg -q "GET /other.sig" "$W/http.log" && ok "the wrong signature was fetched and refused" || bad "other.sig never fetched"
    serve good.json
    log "next: $0 good"
    ;;
good)
    [ -n "$(dev_pid)" ] || { bad "dev copy not running — $0 setup"; exit 1; }
    serve good.json
    PID_BEFORE=$(dev_pid); NEXT=$(cat "$W/next"); ZIP="WarpVeil-${NEXT}-macOS.zip"
    wait_click "the row says \"Downloading and installing…\", the app quits and comes back"
    for _ in $(seq 1 100); do [ "$(dev_pid)" != "$PID_BEFORE" ] && [ -n "$(dev_pid)" ] && break; sleep 0.2; done
    NEW_PID=$(dev_pid)
    [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$PID_BEFORE" ] && ok "relaunched: pid $PID_BEFORE -> $NEW_PID" || bad "no relaunched process (pid: '$NEW_PID', was $PID_BEFORE)"
    [ "$(dev_version)" = "$NEXT" ] && ok "bundle at the same path is now $NEXT" || bad "bundle version is $(dev_version), expected $NEXT"
    [ "$(ps -o comm= -p "$NEW_PID" 2>/dev/null)" = "$BIN" ] && ok "the new process runs from $APP" || bad "new process path: $(ps -o comm= -p "$NEW_PID")"
    [ -e "$W/app/.WarpVeil.app.new" ] || [ -e "$W/app/.WarpVeil.app.old" ] && bad "staging leftovers in $W/app" || ok "no .new/.old left next to the app"
    ls -d "$TMPDIR"/warpveil-update-* >/dev/null 2>&1 && bad "work dir left in \$TMPDIR" || ok "no work dir left in \$TMPDIR"
    xattr -l "$APP" | rg -q quarantine && bad "new bundle is quarantined" || ok "new bundle carries no quarantine attribute"
    codesign --verify --deep --strict "$APP" 2>/dev/null && ok "new bundle's ad-hoc seal is valid" || bad "codesign --verify failed on the new bundle"
    rg -q "GET /$ZIP " "$W/http.log" && rg -q "GET /$ZIP.sig" "$W/http.log" && ok "zip and signature were fetched from the local feed" || bad "feed log lacks the zip/sig fetches"
    [ "$(stat -f '%m' /Applications/WarpVeil.app/Contents/Info.plist 2>/dev/null || echo 0)" = "$(cat "$W/installed.mtime")" ] && ok "/Applications/WarpVeil.app untouched" || bad "/Applications/WarpVeil.app changed"
    log "in the relaunched copy, Advanced → Updates should read \"WarpVeil $NEXT\" and, after Check for Updates, \"Up to date\""
    log "next: $0 stop"
    ;;
stop)
    [ -n "$(dev_pid)" ] && { osascript -e "tell application id \"$DEV_ID\" to quit" >/dev/null 2>&1; for _ in $(seq 1 50); do [ -z "$(dev_pid)" ] && break; sleep 0.2; done; }
    [ -z "$(dev_pid)" ] && ok "dev copy stopped" || { pkill -f "^${BIN}$"; bad "dev copy had to be killed"; }
    [ -f "$W/http.pid" ] && { kill "$(cat "$W/http.pid")" 2>/dev/null; rm -f "$W/http.pid"; ok "feed server stopped"; }
    prev=$(cat "$W/autoConnect.prev" 2>/dev/null || echo none)
    if [ "$prev" = none ]; then defaults delete "$DEV_ID" autoConnect 2>/dev/null; else defaults write "$DEV_ID" autoConnect -int "$prev"; fi
    ok "dev autoConnect restored ($prev)"
    ;;
apps-probe)
    # A throwaway ad-hoc app that, when launched, spawns the updater's helper against a staged
    # copy of itself and exits. Answers whether /Applications lets an ad-hoc app replace itself.
    P="/Applications/WVUpdateProbe.app"; D="$W/probe"; rm -rf "$D"; mkdir -p "$D"
    cat > "$D/probe.swift" <<'SWIFT'
import AppKit
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
let app = Bundle.main.bundlePath, dir = (app as NSString).deletingLastPathComponent
let logFile = dir + "/wvprobe.log"
func log(_ s: String) { let h = FileHandle(forWritingAtPath: logFile) ?? { FileManager.default.createFile(atPath: logFile, contents: nil); return FileHandle(forWritingAtPath: logFile)! }(); h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile() }
log("launched v\(version) pid=\(ProcessInfo.processInfo.processIdentifier)")
guard version == "1" else { exit(0) }
let script = """
    export PATH=/usr/bin:/bin
    exec >> "$5" 2>&1
    while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
    rm -rf "$3"
    mv "$1" "$3" && echo "mv old aside: ok" || echo "mv old aside: FAILED"
    mv "$2" "$1" && echo "mv new in: ok" || { echo "mv new in: FAILED"; mv "$3" "$1"; }
    rm -rf "$2" "$3" && echo "rm old: ok" || echo "rm old: FAILED"
    open -n "$1" && echo "open: ok" || echo "open: FAILED"
    """
let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
p.arguments = ["-c", script, "sh", app, dir + "/.WVUpdateProbe.app.new", dir + "/.WVUpdateProbe.app.old", String(ProcessInfo.processInfo.processIdentifier), logFile]
try! p.run()
exit(0)
SWIFT
    swiftc -O -o "$D/probe" "$D/probe.swift" 2>/dev/null || { bad "probe did not compile"; exit 1; }
    mkapp() { mkdir -p "$1/Contents/MacOS"; cp "$D/probe" "$1/Contents/MacOS/Probe"; printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string><key>CFBundleIdentifier</key><string>com.warpveil.updprobe</string><key>CFBundleName</key><string>WVUpdateProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>%s</string><key>LSUIElement</key><true/></dict></plist>\n' "$2" > "$1/Contents/Info.plist"; codesign --force --sign - "$1" 2>/dev/null; }
    rm -rf "$P" "/Applications/.WVUpdateProbe.app.new" "/Applications/.WVUpdateProbe.app.old" /Applications/wvprobe.log
    mkapp "$P" 1 && mkapp "/Applications/.WVUpdateProbe.app.new" 2 || { bad "cannot write to /Applications"; exit 1; }
    open -n "$P"; sleep 5
    echo "--- /Applications/wvprobe.log"; cat /Applications/wvprobe.log
    rg -q "launched v2" /Applications/wvprobe.log && ok "an ad-hoc app replaced itself in /Applications and relaunched (no App Management block)" || bad "the swap in /Applications did not complete — see the log above"
    log show --last 2m --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "updprobe"' 2>/dev/null | rg -v "^Timestamp|^Filtering" | tail -5
    pkill -f WVUpdateProbe 2>/dev/null; rm -rf "$P" "/Applications/.WVUpdateProbe.app.new" "/Applications/.WVUpdateProbe.app.old" /Applications/wvprobe.log
    ls /Applications | rg -q "WVUpdateProbe|wvprobe" && bad "probe leftovers in /Applications" || ok "/Applications cleaned up"
    ;;
*)
    echo "usage: $0 setup | bad | good | stop | apps-probe" >&2; exit 1 ;;
esac
log "finished with $fails failure(s)"; exit $((fails > 0))
EOF
chmod +x "$TMPDIR/update-live.sh"
"$TMPDIR/update-live.sh" apps-probe   # optional, first: the /Applications question
"$TMPDIR/update-live.sh" setup        # a "WarpVeil Dev" window appears; wait ~20 s for the row
"$TMPDIR/update-live.sh" bad          # click Install, Enter
"$TMPDIR/update-live.sh" good         # click Install, Enter — the dev copy quits and comes back
"$TMPDIR/update-live.sh" stop
```

Expect every line `ok` and `finished with 0 failure(s)` in each phase. In `bad`: the row shows
"The signature does not match — not installed", same pid, bundle still `1.2-dev`, nothing
staged, `other.sig` fetched. In `good`: a new pid at the same path, `1.2-dev-updated` on disk,
no `.new`/`.old`, no work dir, no quarantine, a valid seal, `/Applications/WarpVeil.app`
untouched; the relaunched copy's row reads `WarpVeil 1.2-dev-updated`. In `apps-probe`:
`launched v1` → four `ok` lines → `launched v2` in `/Applications/wvprobe.log`, no TCC event
(if `rm old: FAILED` appears alone, the swap still happened and D4's `rm -rf "$3"` before the
next swap is what handles the leftover — record it in the canon's Gotchas). What the script
cannot see: the row's text and the status menu item — the clicker reads those.

The build/package part of `setup` (key, dev copy, `PlistBuddy`, the next bundle, `ditto`,
`sign_zip` from the patched `release.sh`, the feeds) was run in this session against the scratch
copy without launching anything, and the resulting feed and zip drove the harness of section 2
to `check(manual) -> available("1.2-dev-updated")` and `OK staged com.warpveil.app.dev
1.2-dev-updated`; the launch, clicks and relaunch are the main session's.

## Risks and what is not verified

- **App Management in `/Applications`** is the one policy question answered by evidence rather
  than by this machine: the self-replacement ran clean in a scratch directory, the operations
  are the ones `install.sh` runs from Terminal every deploy, and the external reports agree; the
  `/Applications` probe is in the live script because this session was refused write access
  there. If it blocks, the failure is silent in the app (old version comes back, update offered
  again) and the remedy is a `log show` for `kTCCServiceSystemPolicyAppBundles`.
- **The helper has no channel back**: a swap that did not happen is only visible as the old
  version relaunching. Accepted (D4).
- **A rate-limited exit IP** makes the manual check say "HTTP 403" until the hour turns; the
  automatic one retries daily. Accepted (D6).
- **The first signed release is a by-hand install** (bootstrap, D2); the first OTA install is
  1.3 → 1.4, when the whole path runs for real in `/Applications` for the first time. Until
  then the end-to-end evidence is the dev copy in its own directory.
- **`awaitTeardown` now returns false for a cancelled stop dialog**; only the update reads it,
  the quit path ignores it. A stop that exits 0 while sing-box somehow survives (the scripts
  return 1 in that case) would let the update proceed — same as the quit path today.
- **`ditto`'s `waitUntilExit` blocks a cooperative thread** for ~0.5 s. Accepted; the pool has
  one thread per core.
- **The dev copy's TCC**: none. **Keychain**: none. So a new cdhash per update costs nothing
  today; the parity plan's notification permission will (Rebasing).
- Not run live here: the actual app's click → quit → relaunch (the harness stops at the staged
  bundle; the shell helper was exercised by the probe app, which is the same script with echoes).
- Not tested: an update while a restart is pending (`reconnectTask` armed, `isRunning` false):
  the closure returns true without a stop — the engines are already down — and the pending
  restart dies with the process. If `killVPNProcesses` could not even start the stop
  (`run()` threw), `teardownProcess` is the previous stop's and the update proceeds on that one's
  status — the same gap the quit path has today.

## Validation of this plan

Done in this run; repo untouched except this file (`git status --porcelain` shows the already
modified `plans/done/privileged-helper-hardening.md` and this file); no engine of the app's
started, stopped or reconfigured; `/Applications`, `/usr/local/libexec`, `/etc/sudoers.d` and
`/var/run` untouched; no sudo; no `dev-run.sh`, `install.sh` or `release.sh` run; no GitHub
release created or uploaded; the subscriptions file never read:

- Baseline `xcodebuild … Debug` of `git archive HEAD` into a scratch derived-data dir: `BUILD
  SUCCEEDED` (12 s).
- Steps 1+2 alone (`ProcessManager.swift` only) on a second clean copy: `BUILD SUCCEEDED`, no
  `Sources/` warnings. All steps on a third copy: `BUILD SUCCEEDED` in Debug and in Release, no
  `Sources/` warnings; `plutil -lint` passes on `project.pbxproj` and `Info.plist`; `bash -n`
  passes on `release.sh`, `dev-run.sh` and `update-live.sh`. The diffs quoted in "Steps" are that
  copy's diffs. Two compile errors were hit and fixed on the way (`await` on `fetch`, and
  `currentVersion` read from a `nonisolated` context) — they are not in the quoted code.
- The harness of Verification 2 ran exactly as quoted with the throwaway key: every expected
  line, nothing escaped from the zip-slip archive, no work directory left, the staged bundle with
  `com.apple.provenance` only and a valid seal; the five `check()` outcomes.
- `sign_zip` extracted from the patched `release.sh` signed the 41 MB zip in 0.2 s; the
  harness's `misc` probe verified it in 27 ms and refused a one-bit change; with a public key that
  is not the file's pair it printed one `ERROR:` line and exited 1; with a non-base64 key file
  likewise. The two key one-liners of "After the steps" ran (throwaway path) and produced a
  45-byte seed file (0600) and a 44-character public key.
- The build/package part of `update-live.sh setup` ran against the scratch copy and fed the
  harness (see the end of Verification 3).
- Machine probes, each with `xattr -l` / `ls` / `codesign` / `log show` output read: the
  `URLSession` quarantine probe (both APIs), the `ditto` zip-slip and symlink archives, the
  self-replacing ad-hoc probe app in a scratch directory, the `Info.plist` and executable
  tampering probe, `Bundle(url:)` and `resourceValues` on the unpacked bundle, the seven version
  comparisons, LibreSSL's missing ed25519, `swift -` with arguments, `/etc/sudoers.d` listing,
  the system `TCC.db` query.
- GitHub: the `releases/latest` headers and body, the conditional request, the asset redirect,
  the website redirect, `/rate_limit`; the docs page for the endpoint's draft/prerelease rule.
  Web sources for App Management: mjtsai.com's Ventura App Management post (Apple's rule, quoted),
  the Mysk 2026 report, the Sparkle-on-ad-hoc spike (fc445/unrot-your-brain PR 14), the Apple
  developer forum thread 715220 (no rules stated there).
- Every symbol named above was read in the source at the cited lines; the parity and hostname
  plans were read for the `AdvancedView`, `menuNeedsUpdate`, `awaitTeardown` and
  `ProcessManager.connect` regions they touch.

## Rebase note (2026-10-14, main session)

The first `/code-review` of the privileged helper hardening, run while this plan was being
written, changes `ProcessManager` again: the root PID file moves out of `/tmp`, `run.sh` takes
its config on stdin, the xray start becomes asynchronous, and `passwordlessInstalled()` compares
the root copy with `contentsEqual` instead of a manifest. Rebase the `ProcessManager`,
`awaitTeardown` and stale-install steps on that code before implementing them. The deployment
target may also move to 15.0.
