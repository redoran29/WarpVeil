# In-app updater and public releases: OTA from GitHub, authenticated by our own ed25519 key; 1.3 as the first public build

Status: planned, revised. Written against `0127c17` on 2026-10-14 — macOS 27.0.1 (Darwin 27.0.0),
Xcode 27.0 (Swift 6.4 toolchain, language mode 5), deployment target **15.0**,
`CFBundleShortVersionString` = `1.2`, `CFBundleVersion` = `3`, installed app ad-hoc signed,
passwordless on for tag `1-2` (`/etc/sudoers.d/` holds only `warpveil-1-2`), `gh` logged in as
`redoran29`, remote `https://github.com/redoran29/WarpVeil.git`, public repo, releases v1.0 /
v1.1 / v1.2 with one asset each (`WarpVeil-<version>-macOS.zip`, built by `release.sh`).

This revision replaces the plan written against `c32a050` (`git show a564a68:plans/in-app-updater.md`).
What moved since: the owner's go-ahead (the canon's "no in-app updater" is reversed below, no
gate left); every `ProcessManager` citation rebased on the two hardening review rounds
(`git show 0127c17:plans/done/privileged-helper-hardening.md`, "Review"); a new scope — public
distribution: the stranger's first install through Gatekeeper, a release-notes template,
`release.sh` guards, the 1.3 bump, the signing key made by the main session; and the canon's new
close step (a finished plan is deleted, not moved).

## Owner's ask

Can the app update itself from GitHub without an Apple Developer ID, and can anyone download it
from the releases page? The accepted shape: a small homegrown updater — no Sparkle, the canon
forbids external Swift packages — that checks
`https://api.github.com/repos/redoran29/WarpVeil/releases/latest`, compares with
`CFBundleShortVersionString`, downloads the release zip with `URLSession`, verifies it with an
ed25519 signature of our own (CryptoKit, public key in the app, private key outside the repo),
unpacks it with `ditto`, checks the bundle, stages it the way `install.sh` does, stops the
engines and relaunches through the app's own quit path. One control, an automatic check, no
feature creep. For strangers: the exact first-launch steps an ad-hoc signed app needs on macOS
15/26/27, a README "Download" section, release notes `release.sh` fills, a `release.sh` that
refuses to publish a dirty tree, an existing tag or an unbumped version, and 1.3 as the first
release that carries the updater and the hardening — 1.2's `run.sh` hole stays open for every
1.2 user until they install 1.3 by hand.

Out of scope and untouched: `install.sh`, `fetch-binaries.sh`, `PingService`, `BypassService`,
`SubscriptionService`, the engines, the sudoers/libexec install (`installPasswordless` is called
by nothing new).

## Verified facts

Checked in this run on this machine, not recalled. Line numbers are against `0127c17`.

### Code

- `Sources/ProcessManager.swift:26-29` `versionTag` (`1.2` → `1-2`); `:32-53` every privileged
  path carries it — libexec, `run.sh`/`stop.sh`, sudoers, the root copy `rootSingBoxPath`,
  `/var/run/warpveil-<tag>/singbox.pid`, `$TMPDIR/warpveil-<tag>-xray.pid`. `:205-222`
  passwordless is `rootCopyMatches` (mapped-page compare of the root sing-box with the bundle,
  computed at init and in `passwordlessOperationFinished`) `&& scriptsInstalled()` (this tag's
  sudoers file + both scripts byte-equal); `:332-335` `refreshPasswordless()` re-reads it, called
  in `connect` (`:514`) and `killVPNProcesses` (`:834`). After a version bump none of the new
  tag's files exist, so a fresh build reads passwordless as off. `:224-300` `installPasswordless`
  first removes every `/etc/sudoers.d/warpveil*`, `/etc/sudoers.d/vpnswift` and
  `/usr/local/libexec/warpveil*` (`:266-268`). `:345-349` `init` logs the stale line only when
  **this tag's** sudoers file exists — after a bump nothing is logged.
- `:437-550` `connect`: cancels a pending restart; parks in `reconnectTask` while
  `[teardownProcess, xrayProcess]` has a running member (`:451-463`); writes the configs; `:532`
  `isRunning = true` **before any engine is up**; a sing-box server starts the helper at once,
  an xray server starts xray in `reconnectTask` (`:540-549`) and the helper only once port 10808
  answers; `:553-557` `abandonStart()` for a start that failed before the helper (terminate
  xray, stop the tail, `isRunning = false`). `:559-594` `startHelper`: `sudo run.sh` with the
  config on stdin, or osascript; the termination handler (`:576-585`) ends the session only for
  the current helper. `:613-665` `startXray` is async; `:670-685` `stopOrphanedXray` is async.
- `:801-807` `disconnect()` cancels `reconnectTask` (the pending xray start included), then
  `tearDownEngines()` if running; `:809-819` `tearDownEngines` reads `helperStarted =
  helperProcess != nil`, terminates helper and xray, `stopLogTail()` (which drains the log,
  `:885-891`), and runs `killVPNProcesses()` **only when a helper started** — a session that never
  reached the helper has no root stop and no password dialog. `:823-831` `teardownProcess` /
  `awaitTeardown(timeout:)` returns nothing and waits only on `teardownProcess` (not on xray);
  it is **never cleared** — a stop from an earlier session stays in it. `:833-862`
  `killVPNProcesses` stores the stop in `teardownProcess`; a cancelled password dialog exits
  osascript non-zero within a second, `kill_pid_file` returns 1 for a sing-box that outlives
  5 s, and both read the same as a finished stop today.
- `Sources/WarpVeilApp.swift:88-98` `applicationShouldTerminate`: `ping.cancel()`, then
  `.terminateNow` unless `pm.isRunning`, else `disconnect()` + `awaitTeardown(timeout: 30)` +
  `reply(toApplicationShouldTerminate: true)`. `:103-127` `menuNeedsUpdate` rebuilds the status
  menu: status line, Connect/Disconnect, Open WarpVeil (`:119-121`), separator, Quit;
  `:129-131` the three actions. `Sources/AppState.swift:10-15` the services; `:72-83`
  `bootstrap` awaits location + feeds, auto-connects, `isBootstrapped = true`; `:103-110`
  `disconnect()`. `Sources/AdvancedView.swift:9-47` two sections, Connection and Components,
  closing with `.formStyle(.grouped)`. `Sources/SetupService.swift:28-41` `Task.detached` for
  blocking work. `Sources/PingService.swift:393` `static func isListening(_:)`.
- `Info.plist`: `CFBundleShortVersionString` `1.2`, `CFBundleVersion` `3` (v1.0 → 1, v1.1 → 2,
  v1.2 → 3: bumped with every release), `LSMinimumSystemVersion` from the build setting,
  `NSAllowsArbitraryLoads` true, no `*UsageDescription` keys. `project.pbxproj`:
  `MACOSX_DEPLOYMENT_TARGET = 15.0`, `SWIFT_VERSION = 5.0`, `ARCHS = arm64`,
  `PRODUCT_BUNDLE_IDENTIFIER = com.warpveil.app`, sources listed explicitly (ids `AA…`/`BB…`,
  four places per file; `…1D` unused).
- `release.sh:32-46` **replaces** an existing tag and release when HEAD moved (`git tag -d`,
  `push :refs/tags`, `gh release delete`) — the opposite of what the owner now wants; `:103-124`
  packages with `ditto -c -k --sequesterRsrc --keepParent` and re-packages after stapling;
  `:129-158` notes from `git log PREV_TAG..HEAD` — 157 commits since v1.2, most of them plan
  bookkeeping, unusable as public notes — with "Launch — the window opens and the icon appears
  in the menu bar" and "Requires macOS 15+"; `:173-176` uploads one asset. `install.sh:169-178`
  stages `.WarpVeil.app.new`, `rm -rf`, `mv`, `open -n`. `dev-run.sh:128-133` sets the dev
  version and name with `PlistBuddy` and re-signs ad-hoc. `.gitignore` excludes `*.key`,
  `*.pem`, `build/`, `build-dev/`, `*.app`. `README.md:31-35` "Install"; `:45-55` "Release".
- The working tree has one untracked file, `p.sh`, and nothing modified.
- `CLAUDE.md`: Workflow step 3 now deletes a finished plan (no `plans/done/`); the canon's
  "Binary upgrades ship with the app" line is `:284`; the lines this plan edits are quoted
  verbatim under "Canon updates" and every anchor matched once in the scratch copy.

### GitHub (`curl`, `gh`, this run)

- `GET /repos/redoran29/WarpVeil/releases/latest` → 200, `x-ratelimit-limit: 60` (per IP,
  unauthenticated; `remaining: 58` on this exit), `cache-control: public, max-age=60`, weak
  ETag. Body: `tag_name` `v1.2`, `draft` false, `prerelease` false, one asset
  (`WarpVeil-1.2-macOS.zip`, 31 058 148 bytes, `digest` `sha256:…` — GitHub's, not
  authenticity). `gh release view v1.2`: `immutable: false`; the notes say "Requires macOS 14+"
  and "the icon appears in the menu bar" — both stale.
- Kept from the first version of this plan, re-read there and unchanged by anything since:
  the endpoint is documented as "the most recent non-prerelease, non-draft release"; a
  conditional request that returns 304 counts against the limit; the asset URL is a 302 to
  `release-assets.githubusercontent.com` that `URLSession` follows; the website's
  `/releases/latest` redirects to `/releases/tag/v1.2`.

### macOS: quarantine, Gatekeeper, launch, App Management, TCC, tampering

- **What carries `com.apple.quarantine`** (probed): a file `curl` downloads — `com.apple.provenance`
  only, no quarantine; a file the app downloads with `URLSession` — the same (first version of
  this plan, both `download(from:)` and `data(from:)`). A zip given a browser's quarantine
  (`0083;<hex time>;Chrome;<uuid>`) and unpacked with **`ditto -x -k` or `unzip`** puts the
  attribute on **every** extracted file, the bundle's `Resources/sing-box` included; `cp` and
  **`install(1)`** copy the attribute along (so `installPasswordless`'s `install -m 0755` would
  carry it onto the root sing-box); `xattr -d` on the bundle directory leaves the nested files
  quarantined, `xattr -dr` strips all. `spctl -a -t execute` says `rejected` for an ad-hoc binary
  or bundle whether quarantined or not — that verdict is not what decides a launch; Gatekeeper
  acts on quarantined files only, and the installed `/Applications/WarpVeil.app` (no quarantine,
  `rejected`) runs. `syspolicy_check distribution` on an ad-hoc bundle: "Adhoc Signed App,
  Severity: Warning".
- **Gatekeeper on macOS 15, 26 and 27** (Apple's Mac User Guide "Open a Mac app from an
  unidentified developer", the 15.0, 26 and 27 editions; Apple's "Safely open apps on your Mac";
  macworld, osnews, Christian Tietze on Sequoia): a quarantined app that is not notarized is
  blocked on first launch; the dialog on Sequoia-generation screenshots reads "Apple cannot
  check “Example App” for malicious software" / users widely quote "Apple could not verify
  “X” is free of malware that may harm your Mac or compromise your privacy", with **Done** and
  **Move to Trash** and no Open button; **Control-click → Open no longer bypasses it** (gone in
  15.0, confirmed by every source; 15.1 briefly broke the override itself). The override: System
  Settings → Privacy & Security → scroll to **Security** → the line "“X” was blocked to protect
  your Mac" → **Open Anyway** → the login password → Open. Apple's page for all three versions
  says the button "is available for about an hour after you try to open the app". The three
  editions of the page are word-for-word the same; nothing found that macOS 27 changed the flow
  (two September-2026 CVEs fixed a Gatekeeper *bypass* in 27 / 26.6 / 15.8 — the policy got
  stricter, not looser). An app with a *broken* signature gets "is damaged and can't be opened"
  with no override; an ad-hoc signature is not broken (`codesign --verify` passes on the
  unpacked zip, probed), so it is the first dialog.
- **Nothing on the publishing side avoids the dialog** short of notarization (a Developer ID,
  which the owner does not have): the quarantine is set by the downloading browser, not by the
  zip; a `--sequesterRsrc --keepParent` zip, a dmg, a tarball all end the same. What avoids it is
  a download that sets no quarantine — `curl` in Terminal (probed) — so the notes and the README
  carry a one-line Terminal install.
- **Open question, settled only live**: whether the approval covers the bundle's nested
  engines. After Open Anyway the app runs; `Resources/sing-box` and `Resources/xray` are still
  quarantined files that the app `exec`s (the ping, xray as the user) and that root `exec`s
  (the osascript path runs the bundle's sing-box; `install(1)` carries the attribute onto the
  passwordless copy). Apple's documented rule is that Gatekeeper evaluates the *bundle* the
  user opened, and apps with ad-hoc helpers do run after Open Anyway in common experience; but
  the developer-forum threads found (767612, 812323) are about the *sandbox* consent flag
  (`qtn-flags` bit `0x04`), not this case, and no source states the nested rule outright. The
  live script's `stranger` phase answers it with the ping (user-space exec of both engines, no
  root, no TUN); the root exec is answered by the owner's own 1.3 install (Verification 5). If
  the nested exec is blocked, the remedy is in "Risks".
- **App Translocation**: a quarantined app launched from where it was unpacked (not moved to
  `/Applications` with Finder) runs from a read-only
  `/private/var/folders/…/AppTranslocation/<uuid>/d/` mount; `Bundle.main.bundleURL` is that
  path, so an update of a translocated copy fails at the stage move with the system's error in
  the row. The README says "drag to `/Applications`"; the live script matches the process by
  name, not by the unpacked path, because of this.
- Kept from the first version of this plan (probed then, nothing since touches them): `ditto -x
  -k` neutralises `../` and absolute entry names but recreates a symlink entry, and a file entry
  through a symlinked directory aborts the extraction; an ad-hoc app can replace its own bundle
  and relaunch with no prompt in a scratch directory (the same probe in `/Applications` is the
  live script's `apps-probe`); WarpVeil holds no TCC grant; editing an ad-hoc app's `Info.plist`
  breaks `codesign --verify` and the app still launches, editing its executable does not.

### Tooling

- `/usr/bin/openssl` is LibreSSL with no ed25519; the signer is `swift -` with CryptoKit
  (`Curve25519.Signing`, raw 32-byte seed / 32-byte public key / 64-byte signature, base64).
  Both key one-liners ran here with a throwaway path: a 45-byte 0600 seed file and a
  44-character public key.
- `sort -V` exists on this macOS (`v1.2 < v1.3 < v1.10`); `git tag --sort=-version:refname`
  works; `gh repo view --json url -q .url` → `https://github.com/redoran29/WarpVeil`; `git status
  --porcelain --untracked-files=no` is empty with `p.sh` untracked.
- `Process.terminationStatus` on a running process raises `NSInvalidArgumentException` ("task
  still running") — probed; the new `awaitTeardown` reads `isRunning` first.
- `"1.2".compare("1.10", options: .numeric)` ascending; `"1.2-dev"` < `"1.3"`; `"1.2"` <
  `"1.2-dev"` (first version of this plan).
- Baseline `xcodebuild … Debug` of `git archive HEAD` into a scratch derived-data dir under
  `/private/tmp/claude-501/`: `BUILD SUCCEEDED` in 10 s. (`xcodebuild` prints a CoreSimulator
  version mismatch on this machine; it is noise, the build is unaffected.)

## Design

### D1. The feed URL and the public key are `Info.plist` keys, not Swift constants

`WVUpdateFeed` = `https://api.github.com/repos/redoran29/WarpVeil/releases/latest`,
`WVUpdatePublicKey` = the base64 raw ed25519 public key. Sparkle's convention (`SUFeedURL`,
`SUPublicEDKey`), and it gives the live check its whole seam for free: `dev-run.sh` already
rewrites the dev copy's `Info.plist` with `PlistBuddy` and re-signs, and the live script does
the same with a feed on `127.0.0.1` and a throwaway key — no test-only code, no build setting,
no `#if DEBUG`. An edited `Info.plist` is less tamper-evident than a compiled-in key (facts),
and that buys nothing: whoever can edit the installed bundle runs as the user and can replace
the whole bundle — the updater's trust boundary is the user account, like everything in a
user-owned `.app`.

### D2. One ed25519 signature over the release zip; the key is the base64 seed under `~/.config/warpveil/`

`release.sh` signs the **final** zip (after the stapling re-pack) with
`~/.config/warpveil/release-signing.key` (0600, one line, the base64 32-byte seed) through a
`swift -` heredoc and uploads `<zip>.sig` next to it. The app verifies the zip's bytes against
`WVUpdatePublicKey` **before** anything unpacks it, so `ditto` only ever sees an archive
`release.sh` made. One file, one signature, no manifest. The signer refuses a key whose public
half is not the one in `Info.plist`, so a release can never go out that every installed app
would refuse; `release.sh` exits before building when the key file or the plist key is missing.

**The main session generates the key** (step 6), not the owner by hand; the file stays outside
the repo (`*.key` is gitignored), and the owner **must back it up**: without it no installed copy
can ever verify an update again, and the recovery is a new pair plus one by-hand install of the
next release on every machine — there is no revocation channel, so a leaked key is the same
procedure. Rotation: new public key into `Info.plist`, sign *that* release with the old key,
then switch the file. A file, not the login keychain: `security` prompts for ACL access on each
release unless "Always allow" is clicked, which makes the keychain the same boundary as a 0600
file with more friction.

### D3. What is refused before anything touches the running bundle

In order, each a `Failure` whose text the Updates row shows: no `WVUpdateFeed` / no
`WVUpdatePublicKey`; the feed not HTTP 200 (a rate limit is a 403 and reads "The update feed
answered HTTP 403"); a body that does not decode as a release; a release whose assets lack
`WarpVeil-<tag minus v>-macOS.zip` or its `.sig` (mandatory — nothing unsigned is ever
unpacked); either download not 200; a signature that does not verify over the zip; `ditto`
exiting non-zero; a top-level `WarpVeil.app` that is not a real directory or not a bundle; a
bundle id other than `Bundle.main.bundleIdentifier` (the real feed cannot replace a
`com.warpveil.app.dev` copy, and vice versa); a bundle version that is not the tag's **or** not
strictly greater than the running one (a signed older release replayed under a newer tag, and a
plain downgrade); an executable without arm64. Only then does the bundle move from the 0700
work directory in `$TMPDIR` to `.WarpVeil.app.new` next to the running one. Zip-slip is covered
twice: by the signature, and by `ditto`'s own path sanitising.

### D4. The engines stop first — the session's engines, whatever stage the session is at — then a shell outlives the app and swaps the bundles

Rebased on the hardened `ProcessManager`. The new build's tag cannot see the old tag's PID file,
so the new app must never start with the old app's root sing-box holding the TUN: the update
stops the engines **before** the swap and refuses to go on unless they are gone.

`AppState.installUpdate` hands `Updater.install` a closure that calls `disconnect()`
**unconditionally** and then `await pm.awaitTeardown(timeout: 30)`. Unconditional, because
`pm.disconnect()` is also what cancels `reconnectTask` — a pending xray start (the session is
`isRunning` from its first line and the start waits in that task), a restart pending after wake
or a routing edit (`isRunning` false, engines down, a `connect` armed on a timer that would
otherwise start engines while the app is on its way out). `tearDownEngines` then terminates
xray and the helper, and runs the root stop only if a helper had started — a session still
waiting for xray has no root engine and gets no password dialog (`:809-819`).

`awaitTeardown` (step 2) captures `[teardownProcess, xrayProcess]` at entry (xray's termination
handler nils the property asynchronously), waits for both, and returns **true** only when
nothing of them runs and the stop, **if one ran**, exited 0. A cancelled password dialog, a
`kill_pid_file` that gave up after 5 s, or 30 s of nothing all cancel the update: the staged
bundle is removed and the row says "The tunnel did not stop — update cancelled". For "if one
ran" to be true, `connect` clears `teardownProcess` once the previous stop has exited (it only
ever waited for it to finish; its status is nobody's business after that — `run.sh`'s
`kill_pid_file` deals with a sing-box it left behind). Without that line a session that never
reached the helper, or ended by the helper exiting on its own, would be judged by a stale stop
from two sessions ago. A stop that is still in flight when Install is clicked (a disconnect
whose dialog is still up, a restart's teardown) is waited for, not skipped.

Then the helper is spawned and the app calls `NSApp.terminate(nil)`, which goes through
`applicationShouldTerminate` like every quit (`.terminateNow`, the engines are down; a `connect`
the user managed to click in the meantime makes it `.terminateLater`, and the quit path's own
`awaitTeardown` handles that). The helper, `/bin/sh -c '<script>' sh <bundle> <staged> <aside>
<pid>` — paths as arguments, nothing interpolated:

```sh
export PATH=/usr/bin:/bin
while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
rm -rf "$3"
mv "$1" "$3" && { mv "$2" "$1" || mv "$3" "$1"; }
rm -rf "$2" "$3"
open -n "$1"
```

Every path ends with an app at `$1`: if the old bundle cannot be moved aside, nothing has
changed and the old app reopens; if the new one cannot be moved in, the old one comes back. A
swap that did not happen is visible as the old version still running and the row offering the
update again — the helper has no channel back into the app, and none was added. The staging
path is derived from `Bundle.main.bundleURL`, not hard-coded to `/Applications`: the dev copy
updates itself in its own directory; a translocated or read-only copy fails at the stage move
with the system's error in the row. Rejected: swapping inside `applicationShouldTerminate`
(update logic in every quit); copying into the stage with `ditto` (same volume, a rename is
enough); an `.old` kept for rollback (nothing would use it).

### D5. One control in Advanced, one conditional item in the status menu, a daily check

`Section("Updates")` at the bottom of Advanced: the label is `WarpVeil <version>` with a status
line under it, the trailing control is **Check for Updates** or, once a newer release is known,
**Install**; disabled while checking or installing. The status line is the `Updater.State`:
"Checked once a day" / "Checking..." / "Up to date" / "Version X is available" / "Downloading and
installing — the app relaunches when done" / the failure text. The status menu gets `Update to
X…` after Open WarpVeil only while an update is known. Automatic checks: 15 s after `bootstrap`
finishes (the TUN of an auto-connect is up by then) and every 24 h after. An automatic check
that fails leaves the row as it was; a manual check reports its failure. No notification, no
dialog, no toggle.

### D6. The GitHub REST API, matched by exact asset name; no ETag; a rate limit is a visible failure

`releases/latest` is documented (non-draft, non-prerelease, newest by `created_at`), returns
the asset list so a missing `.sig` is known before any 40 MB download, and decodes in three
fields. The zip asset is matched by the exact name `release.sh` produces, derived from
`tag_name` with a leading `v` dropped. No `If-None-Match`: a 304 counts against the 60/h limit
anyway, and two requests a day cannot approach it; a shared VPN exit that is rate-limited makes
the manual check say "HTTP 403" and the automatic one try again next day. Rejected: the
website's redirect (undocumented) and authenticating the request (a token in the app).

### D7. The privilege model after an update: two prompts, not reduced; the log now says why

On the first launch after an update, with passwordless on in the old version and auto-connect
on: (1) the new tag has no sudoers file, `isPasswordless` is false, the toggle shows off, and —
**new in step 1** — Logs shows `[Passwordless install is from another build — turn Passwordless
on again in Advanced]` (today the line fires only for the same tag, so a bump logs nothing);
(2) the auto-connect goes through the osascript path: **password dialog 1**, tunnel up through
the bundled sing-box; (3) Advanced → Passwordless on: **password dialog 2**; the install removes
the old tag's sudoers entry and libexec directory (hardening D6) and installs this tag's. Every
later connect is silent. The owner's own machine goes through exactly this once, at the 1.3
install (D11).

Reducing that to one prompt is **not done**: it would put an install behind the connect's own
prompt in the function the hardening reviewed four times (the canon's third-fix signal), and
under hardening D6 any build — a `dev-run.sh` copy included — would take the passwordless install
away from the installed one at its first connect. Its own plan, if the owner wants it.

### D8. Nothing in the update runs as root, and nothing new reaches root

The updater calls `URLSession`, `FileManager`, `/usr/bin/ditto` and `/bin/sh` as the user. The
staged and installed bundle is `lortan29:staff`, exactly what `install.sh` leaves. The only way
bundle bytes become root's is unchanged: `installPasswordless` copying the bundled sing-box
into `/usr/local/libexec` at an admin prompt, and the non-passwordless path running the bundle's
sing-box behind the same dialog. A hostile zip without a valid signature is refused before
unpacking; with one, it is ours. A hostile *feed* (an account takeover) can serve one of our
signed releases under a wrong tag, which D3 refuses, or a newer signed release, which is the
owner's. Step 1 only **lists** `/etc/sudoers.d` (755).

### D9. Public distribution: tell the stranger the truth, and offer the door that has no dialog

The release stays ad-hoc signed (no Developer ID), so the notes and the README say what macOS
will do and exactly what to click: Done, then System Settings → Privacy & Security → Security →
Open Anyway → password; the button is there for about an hour; Control-click → Open does not
work. Worded as "a dialog that Apple could not verify (or cannot check) the app" because Apple's
own screenshot and users' quotes differ by a word and the text may move again. The Terminal
alternative — `curl` + `ditto -x -k … /Applications` + `open` — has no dialog at all, because
`curl` sets no quarantine (facts); it is offered second, for the people who would rather type
than click, and for a first install only (`ditto` into an existing bundle would overwrite a
running app). Both say macOS 15+ on Apple Silicon. Later releases install themselves, so the
dialog is a first-install matter — a bundle the app unpacked carries no quarantine.

### D10. `release.sh` refuses what cannot be released, and its notes come from `CHANGELOG.md`

Before building: uncommitted **tracked** changes (`git status --porcelain --untracked-files=no`;
`p.sh` untracked does not block, nothing untracked can reach the build — sources are listed in
`project.pbxproj` and `Binaries/` is committed), an existing tag locally or on origin (after
`git fetch --tags`), an existing GitHub release, a version not newer than the latest `v*` tag
(`sort -V`), a `CHANGELOG.md` without a `## <version>` section, a missing key or plist key. The
old "replace the existing tag and release" behaviour is gone: a tag names what was built, once.
A failure after the tag was pushed leaves a tag with no release; the operator removes it and
runs again (canon, "release.sh").

The notes: the changelog section verbatim, then the install steps of D9 with the exact asset
name and download URL filled in, then "Requires macOS 15 or newer, Apple Silicon" and one line
about the `.sig`. `CHANGELOG.md` instead of `git log`: 157 commits since v1.2, most of them
"Record the review round in its plan", would be the notes otherwise; a hand-written section is
public text reviewed in a commit, and refusing to publish without it is one more guard. Its
1.3 section is drafted in step 4 and is the owner's to edit.

### D11. 1.3 is the bootstrap: the first release with the updater, installed by hand once

1.2 has no updater, so 1.3 is installed by `install.sh` (the owner) or by the download (anyone)
— from 1.4 on the installed app offers the release. `CFBundleShortVersionString` `1.3`,
`CFBundleVersion` `4` (every release so far bumped both). The bump changes the tag to `1-3`:
the first connect of 1.3 asks for the password (osascript path), the Passwordless toggle asks
once more and purges `warpveil-1-2` (D7). The 1.3 notes tell 1.2 users why they should update
(the `run.sh` hole) and that the toggle has to be turned on again. The key (step 6) goes in
**before** the bump, so 1.3 carries the public key that verifies 1.4; the 1.3 zip is signed too,
which nothing checks yet and costs nothing.

### D12. Argued away

- Notarization or a stable self-signed certificate to keep TCC grants: there are none (facts).
- A progress bar: the row says "Downloading and installing"; 40 MB on a tunnel is seconds.
- Deleting the old tag's sudoers/libexec in the updater: root, by definition; the next toggle
  does it (hardening D6).
- Having the app strip the quarantine from its own bundle at launch, so the nested engines can
  never be blocked: ~10 lines that may be solving a problem macOS does not have; decided by the
  `stranger` phase (Risks).
- A generic `releases/latest/download/<asset>` URL in the README: the asset name carries the
  version, so there is no version-free URL; the notes carry the exact one, the README a
  placeholder.

## Steps

Each step compiles on its own and is one commit. The diffs below are the scratch copy's diffs,
built with `xcodebuild` after steps 1+2 alone and after everything (Debug and Release) — see
"Validation of this plan". Steps 1–7 are the main session's; step 8 closes; step 9 publishes and
is outward-facing, last, after review.

### 1. Report a stale passwordless install from any other build

Commit: `Report a stale passwordless install from any other build`.

`Sources/ProcessManager.swift:345-349` — the `init()` head becomes:

```swift
    // Any warpveil sudoers entry that is not this build's working install: this tag with
    // changed scripts or a bumped engine, the tag of the version an update replaced, or the
    // pre-rename vpnswift entry. Each is the old hole until a toggle removes it.
    private static var otherInstallExists: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/etc/sudoers.d")) ?? [])
            .contains { $0.hasPrefix("warpveil") || $0 == "vpnswift" }
    }

    init() {
        refreshPasswordless()
        if !isPasswordless, Self.otherInstallExists {
            logs.append("[Passwordless install is from another build — turn Passwordless on again in Advanced]")
        }
```

(The `if FileManager.default.fileExists(atPath: Self.sudoersFile), !isPasswordless` line is
replaced; the message is unchanged. `vpnswift` is the entry `installPasswordless` already
removes — a 1.0/1.1 user with passwordless on has it, and it points at a script in
`/private/tmp`.)

### 2. `awaitTeardown` reports whether the engines stopped

Commit: `Make awaitTeardown report whether the engines stopped`.

`Sources/ProcessManager.swift`, in `connect`, right after the `if !exiting.isEmpty { … return }`
block (`:463`), before `guard !config.isEmpty`:

```swift
        // The previous stop has exited and its status is nobody's business now: a sing-box it
        // left behind is run.sh's kill_pid_file's to deal with.
        teardownProcess = nil
```

`:821-831` becomes:

```swift
    // Quit, connect and update need to know when the engines are actually gone. The
    // non-passwordless path puts up a password dialog, so the wait is however long the user
    // takes. True once nothing of the session runs and the stop, if one ran, exited 0 — a
    // cancelled dialog and a sing-box that outlived kill_pid_file's wait both exit 1. A session
    // that never reached the helper ran no stop, and connect drops the previous one.
    private var teardownProcess: Process?

    @discardableResult
    func awaitTeardown(timeout: TimeInterval) async -> Bool {
        let stop = teardownProcess
        let engines = [stop, xrayProcess].compactMap { $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while engines.contains(where: \.isRunning), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !engines.contains(where: \.isRunning) else { return false }
        return stop.map { $0.terminationStatus == 0 } ?? true
    }
```

The quit path in `WarpVeilApp.swift:94` keeps `await app.pm.awaitTeardown(timeout: 30)` and
ignores the result (`@discardableResult`). `terminationStatus` is read only after the guard —
on a running process it raises (facts). `connect`'s "exiting" wait is unaffected: it filters on
`isRunning`, and the nil comes after it.

### 3. The updater

Commit: `Add an in-app updater fed by GitHub releases`.

**`Sources/Updater.swift`** (new, 203 lines):

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
    // engines go down before the swap because the new build's tag cannot stop the old one's
    // sing-box, and a teardown that does not finish — a password dialog left unanswered —
    // cancels the update.
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
is `nonisolated` because `verify` reads it.

**`WarpVeil.xcodeproj/project.pbxproj`** — the file registered in the four places, ids
`AA000000000000000000001D` / `BB000000000000000000001D` (`plutil -lint` passes):

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

**`Info.plist`**, after `LSMinimumSystemVersion` — the public key stays empty in this commit
(step 6 fills it); until then a manual check says "No update key in Info.plist":

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
+    // disconnect() also cancels a restart pending after wake or a routing edit, which would
+    // otherwise start engines while the app is on its way out.
+    func installUpdate() {
+        Task {
+            await updater.install {
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
            }

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

**`Sources/WarpVeilApp.swift`** `menuNeedsUpdate`, after `menu.addItem(open)`, and the action
next to `openAction`:

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
key in Info.plist" after a manual check; nothing else changes.

### 4. `release.sh` refuses, signs and publishes two assets; `CHANGELOG.md` feeds its notes

Commit: `Guard release.sh and sign release zips for the in-app updater`.

**`CHANGELOG.md`** (new, repo root; the 1.3 section is a draft for the owner to edit — it is
public text):

```markdown
# Changelog

Each `## <version>` section is what `release.sh` publishes as that release's notes.

## 1.3

- In-app updates: the app checks GitHub releases once a day and installs a release signed with the project's key — Advanced → Updates, or "Update to …" in the menu-bar menu. This is the last release to install by hand.
- The privileged helper is hardened. 1.2's passwordless `run.sh` took a binary path from its caller, so any program running as the user could run anything as root: update, then turn Passwordless on again once. The root sing-box now runs only its own root-owned copy on a config it checked; xray runs as the user.
- The app is a window — servers, routing, advanced and logs in three columns — with the menu-bar item kept for status, connect/disconnect and opening it.
- Server ping: real delay through each server, measured by the bundled engines in user space, also while connected.
- Routing: bypass rules now match (they sit after sniff), domains are normalized, a whole TLD is written `.ru`, and the tunnel's IPv6 follows the network's.
- Reconnects after sleep/wake and when the network gains or loses IPv6; a routing edit applies live.
- Servers keep their identity across subscription refreshes; `xhttp` servers run through xray.
- Requires macOS 15 or newer on Apple Silicon.
```

**`release.sh`** — the whole file (192 lines; `bash -n` passes; the guards and `sign_zip` were
run, see Verification 3):

```bash
#!/bin/bash
set -euo pipefail
#
# Builds, signs, notarizes and publishes a WarpVeil release.
#
# Notarization setup (one-time):
#   xcrun notarytool store-credentials NOTARY_PROFILE \
#       --apple-id <id> --team-id <team> --password <app-specific-password>
# Then export NOTARY_PROFILE=NOTARY_PROFILE before running this script.
# Without a Developer ID identity in the keychain, builds are signed ad-hoc and notarization
# is skipped. A browser download of such a build is quarantined and its first launch goes
# through Gatekeeper's "Open Anyway" — the notes below say how; nothing a publisher does
# short of notarization avoids it.
#
# The zip is signed with the ed25519 release key (CLAUDE.md, "release.sh") and the signature
# is uploaded next to it: an installed app updates itself only from a release whose signature
# its WVUpdatePublicKey accepts. The notes come from CHANGELOG.md's "## <version>" section.
# The tag has to name exactly what was built, so the script refuses uncommitted changes, an
# existing tag or release, a version that is not newer than the latest tag, a missing
# changelog section and a missing key — before anything is built.

cd "$(dirname "$0")"

# --- Config ---
PROJECT="WarpVeil.xcodeproj"
SCHEME="WarpVeil"
APP_NAME="WarpVeil"
SCRIPT_DIR="$(pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ENTITLEMENTS="${SCRIPT_DIR}/WarpVeil.entitlements"
SIGNING_KEY="${HOME}/.config/warpveil/release-signing.key"

# --- Get version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v${VERSION}"
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"
SIG_NAME="${ZIP_NAME}.sig"

echo "=== ${APP_NAME} Release ==="
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo ""

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Refuse what cannot be released ---
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes — commit them first"
git fetch --quiet --tags origin
! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || fail "tag ${TAG} already exists — bump CFBundleShortVersionString in Info.plist"
! gh release view "$TAG" >/dev/null 2>&1 || fail "release ${TAG} already exists on GitHub"
LATEST=$(git tag --list 'v*' --sort=-version:refname | head -1)
if [ -n "$LATEST" ] && [ "$(printf '%s\n%s\n' "$LATEST" "$TAG" | sort -V | tail -1)" != "$TAG" ]; then
    fail "${VERSION} is not newer than the latest tag ${LATEST} — bump CFBundleShortVersionString in Info.plist"
fi

CHANGES=$(awk -v h="## ${VERSION}" '$0 == h { p = 1; next } /^## / { p = 0 } p' CHANGELOG.md)
[ -n "$(printf '%s' "$CHANGES" | tr -d '[:space:]')" ] || fail "CHANGELOG.md has no \"## ${VERSION}\" section"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :WVUpdatePublicKey" Info.plist 2>/dev/null || true)
{ [ -f "$SIGNING_KEY" ] && [ -n "$PUBLIC_KEY" ]; } || fail "release signing needs ${SIGNING_KEY} and WVUpdatePublicKey in Info.plist (CLAUDE.md, \"release.sh\")"

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

# --- Validate binaries exist (Xcode build phase bundles them) ---
if [ ! -f "${SCRIPT_DIR}/Binaries/xray" ] || [ ! -f "${SCRIPT_DIR}/Binaries/sing-box" ]; then
    fail "Binaries not found. Run ./fetch-binaries.sh first"
fi

# --- Build Release ---
echo "Building Release..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    2>&1 | tail -3

[ -d "$BUILD_DIR/${APP_NAME}.app" ] || fail "Build failed"
echo "Build succeeded"

# --- Verify the Xcode build phase actually bundled the binaries ---
RESOURCES_DIR="$BUILD_DIR/${APP_NAME}.app/Contents/Resources"
if [ ! -f "$RESOURCES_DIR/xray" ] || [ ! -f "$RESOURCES_DIR/sing-box" ]; then
    fail "Build did not bundle binaries into $RESOURCES_DIR — check the 'Bundle VPN Binaries' build phase"
fi

# --- Code sign ---
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)

if [ -z "$IDENTITY" ]; then
    echo "WARNING: no Developer ID Application identity found — signing ad-hoc."
    echo "         Notarization will be skipped."
    codesign --force --sign - "$RESOURCES_DIR/xray" "$RESOURCES_DIR/sing-box"
    codesign --force --sign - "$BUILD_DIR/${APP_NAME}.app"
else
    echo "Signing with identity ${IDENTITY}..."
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" \
        "$RESOURCES_DIR/xray" "$RESOURCES_DIR/sing-box"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$BUILD_DIR/${APP_NAME}.app"
    codesign --verify --deep --strict --verbose=2 "$BUILD_DIR/${APP_NAME}.app"
fi

# --- Package ---
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
cd "$SCRIPT_DIR"

# --- Notarize (only with real identity AND profile configured) ---
if [ -n "$IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Submitting for notarization (profile: ${NOTARY_PROFILE})..."
    xcrun notarytool submit "$BUILD_DIR/$ZIP_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "Stapling ticket..."
    xcrun stapler staple "$BUILD_DIR/${APP_NAME}.app"
    cd "$BUILD_DIR"
    rm -f "$ZIP_NAME"
    ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
    cd "$SCRIPT_DIR"
elif [ -n "$IDENTITY" ]; then
    echo "WARNING: NOTARY_PROFILE not set — skipping notarization."
    echo "         Run: xcrun notarytool store-credentials NOTARY_PROFILE"
fi

ZIP_SIZE=$(du -h "$BUILD_DIR/$ZIP_NAME" | cut -f1)
echo "Packaged ${ZIP_NAME} (${ZIP_SIZE})"

# --- Sign the final zip (after stapling, which repackages it) ---
sign_zip "$BUILD_DIR/$ZIP_NAME" > "$BUILD_DIR/$SIG_NAME"
echo "Signed ${SIG_NAME}"

# --- Release notes: the changelog section, then what a stranger needs to get it running ---
REPO_URL=$(gh repo view --json url -q .url)
NOTES="## ${APP_NAME} ${VERSION}

### Changes
${CHANGES}

### Install
1. Download \`${ZIP_NAME}\`, unzip it and drag \`${APP_NAME}.app\` to \`/Applications\`.
2. The first launch is blocked with a dialog that Apple could not verify (or cannot check) the app — it is not notarized. Click **Done**, open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the ${APP_NAME} line and enter your password. The button stays for about an hour after the blocked launch; Control-click → Open does not work.
3. Later releases install themselves: **Advanced → Updates** in the window, or **Update to …** in the menu-bar menu.

Or from Terminal, with no dialog — a \`curl\` download carries no quarantine:

    curl -L -o /tmp/${ZIP_NAME} ${REPO_URL}/releases/download/${TAG}/${ZIP_NAME} && ditto -x -k /tmp/${ZIP_NAME} /Applications && open /Applications/${APP_NAME}.app

Requires macOS 15 or newer, Apple Silicon. \`${SIG_NAME}\` is the signature installed copies check the zip with — nothing to do with it by hand."

# --- Tag and publish ---
echo "Creating tag ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"
git push origin "$TAG"

echo "Uploading release..."
gh release create "$TAG" \
    "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$SIG_NAME" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)

# --- Cleanup ---
rm -rf "$BUILD_DIR"

echo ""
echo "Done: ${RELEASE_URL}"
```

What changed against `0127c17`'s script: the "skip / replace the existing tag" block is
replaced by the guards; `ZIP_NAME`/`SIG_NAME` move up (the guards need them); `sign_zip`;
notes from `CHANGELOG.md` with the Gatekeeper steps, the Terminal line (the repo URL from `gh
repo view`, which also resolves the asset URL without hard-coding the owner) and the
requirement line; two assets uploaded. Both signing paths stay; with `NOTARY_PROFILE` the
signature is of the stapled zip.

### 5. Canon and README

Commit: `Record the in-app updater and public releases in the canon`. The wording is under
"Canon updates"; every anchor there matched once in the scratch copy and the README diff is
quoted with it.

### 6. The release signing key

Commit: `Carry the release signing public key`. The main session runs, verbatim:

```bash
mkdir -p ~/.config/warpveil && (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > ~/.config/warpveil/release-signing.key)
ls -l ~/.config/warpveil/release-signing.key    # -rw------- , 45 bytes
swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' ~/.config/warpveil/release-signing.key
```

The third line prints the 44-character public key; it goes into `Info.plist`'s
`WVUpdatePublicKey` (`PlistBuddy -c "Set :WVUpdatePublicKey <key>" Info.plist`, or by hand).
The private key is never printed, pasted into the chat, or committed (`*.key` is gitignored —
check `git status` shows only `Info.plist`). **Tell the owner, loudly, in the report**: back up
`~/.config/warpveil/release-signing.key` now (a password manager entry is enough — it is one
line); losing it means no installed copy can ever verify an update again, and the recovery is a
new key plus a by-hand reinstall of the next release on every machine. The key exists only once
step 6 runs; nothing before it needs it, and `release.sh` refuses to run without it.

### 7. Version 1.3

Commit: `Bump version to 1.3`. `Info.plist`: `CFBundleShortVersionString` `1.2` → `1.3`,
`CFBundleVersion` `3` → `4`. Nothing else: the tag, the sudoers/libexec/PID/log paths and the
dev copy's `1.3-dev` all follow from it. The 1.3 changelog section (step 4) is the owner's to
edit before step 9.

### 8. Close

Run `/code-review` over steps 1–7, fix what it surfaces, record each round in this file; then
**delete this file** (canon workflow, step 3 — a finished plan lives in git history). Before the
deletion, anything in it that has to outlive it is already in `CLAUDE.md` (step 5) — re-read
"Canon updates" against the review's changes.

### 9. Publish 1.3 — last, outward-facing, after review

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
git status --porcelain --untracked-files=no          # must be empty
git log origin/main..HEAD --oneline                  # push first if anything is listed
./release.sh                                         # ad-hoc path on this machine (no Developer ID); NOTARY_PROFILE=… ./release.sh with one
gh release view v1.3                                 # two assets: WarpVeil-1.3-macOS.zip, WarpVeil-1.3-macOS.zip.sig
```

The script refuses anything that is not ready (D10), and `git push origin v1.3` carries the
commits the tag reaches. Then the owner's own machine gets 1.3 (Verification 5, the fork). From
1.4 on, the release goes out with `./release.sh` alone and every installed copy offers it within
a day.

## Canon updates

`CLAUDE.md` — replacements, by section; each anchor is the current line and matched exactly once
in the scratch copy.

- Architecture tree, after
  `├── BypassService.swift        # Connect-time sing-box fitting: bypass rule, TUN IP families, file keys; domain input`:
  `├── Updater.swift              # In-app updates: GitHub release feed, ed25519 check, swap and relaunch`.
- "Build & Run", item 3 (`3. \`./release.sh\` for a signed + notarized build (\`NOTARY_PROFILE\` required for notarization).`) becomes:

```
3. `./release.sh` to publish a release: Developer ID + notarization when the keychain has an
   identity and `NOTARY_PROFILE` is set, ad-hoc otherwise; the zip signed with the release key;
   notes from `CHANGELOG.md` — see "release.sh" below.
```

- "dev-run.sh", after the paragraph ending `…so its frame is separate.`:

```
The dev copy has no `WVUpdateFeed` (`build_dev` deletes it): a real release is always newer
than `<version>-dev` and would be offered, then refused for its bundle id after a 40 MB
download. A live check of the updater adds its own feed and key with `PlistBuddy`, the way
`build_dev` sets the version.
```

- New subsection after "install.sh" (after `resolves its own path with \`readlink -f\`.`):

```
### release.sh

Publishes a release. The tag has to name exactly what was built, so before building it refuses
uncommitted tracked changes, an existing tag or GitHub release for the version, a version that is
not newer than the latest `v*` tag (`sort -V`), a `CHANGELOG.md` with no `## <version>` section,
and a missing signing key. Then: Release build, codesign (Developer ID + notarization with
`NOTARY_PROFILE` when the keychain has an identity, else ad-hoc), `ditto` zip, `<zip>.sig`, the
notes (the changelog section, then the install steps a stranger needs: Gatekeeper's Open Anyway,
the Terminal alternative, macOS 15+ on Apple Silicon), `git tag` + push, `gh release create` with
both assets. A failure after the tag was pushed leaves a tag without a release: remove it
(`git push origin :refs/tags/vX && git tag -d vX`) and run again. A release is cut by bumping
`CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, writing the changelog
section, committing, then running the script.

The release key: the updater trusts only a zip signed with the project's ed25519 key. Private
half: `~/.config/warpveil/release-signing.key`, 0600, one line, the base64 32-byte seed — outside
the repo, on the owner's machine, and **backed up by the owner**: without it no installed copy can
ever verify an update again, and the recovery is a new pair plus one by-hand install of the next
release on every machine. Public half: `WVUpdatePublicKey` in `Info.plist`. Generated once:

    mkdir -p ~/.config/warpveil && (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > ~/.config/warpveil/release-signing.key)
    swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' ~/.config/warpveil/release-signing.key

The second line prints the public key for `Info.plist`. `release.sh` checks that the file is the
pair of that key and signs through `swift -` (LibreSSL has no ed25519). Rotation: put the new
public key into `Info.plist` and sign that one release with the old key; installed apps verify it
with the key they carry and then carry the new one. A leaked key cannot be revoked — there is no
revocation channel — so it is the same new pair and one by-hand install.
```

- Key Decisions, "Version-tagged privileged paths": the line keeps its text and gains, after
  `…every version bump re-asks for the password once`:

```
 — after an in-app update that is the first connect's dialog, then the Passwordless toggle's (the install for the new tag, which also purges the old tag's). The log says `[Passwordless install is from another build…]` at launch while any other tag's sudoers entry, or the pre-rename `vpnswift` one, exists
```

- Key Decisions, replace `- **Binary upgrades ship with the app**: no in-app updater; bump the pinned tags in \`fetch-binaries.sh\` and cut a release` with two bullets:

```
- **In-app updates** (owner's decision of 2026-10-14, reversing "no in-app updater"): `Updater`
  reads `WVUpdateFeed` from `Info.plist` — GitHub's `releases/latest` for `redoran29/WarpVeil`,
  the newest release that is neither draft nor prerelease — 15 s after bootstrap, every 24 h,
  and on Check for Updates in Advanced; a `CFBundleShortVersionString` numerically newer than
  the running one shows Install there and `Update to X…` in the status menu. Authenticity is
  our own ed25519 signature over the release zip (`<zip>.sig`, made by `release.sh`), checked
  with CryptoKit against `WVUpdatePublicKey` **before** the zip is unpacked — Apple's signature
  is ad-hoc and proves nothing. The unpacked `WarpVeil.app` must be a real directory with our
  bundle id, the tag's version, newer than the running one, arm64; anything else is refused
  with its reason in the row. It is staged as `.WarpVeil.app.new` next to the running bundle
  (wherever that is — not hard-coded to `/Applications`). Then `disconnect()` and
  `awaitTeardown`: false — a stop that exited non-zero (a cancelled dialog, a sing-box that
  outlived `kill_pid_file`), or anything of the session still running after 30 s — cancels the
  update, because the new tag cannot stop the old tag's engine. Then a `/bin/sh` helper spawned
  before `NSApp.terminate` waits for the process to exit, renames old → `.old`, new → in place
  (or the old back), removes the rest and `open -n`s the result. Nothing in it runs as root:
  the new bundle is the user's, as before, and becomes root's only through the passwordless
  install at its own prompt. A download by the app carries no quarantine attribute. No ETag (a
  304 counts against GitHub's 60/h anyway), no notification, no toggle. Engine upgrades still
  ship with the app: bump the pinned tags in `fetch-binaries.sh` and cut a release
- **Public distribution without a Developer ID**: the release zip is ad-hoc signed, so a copy a
  browser downloaded is quarantined and its first launch is blocked — "Apple could not verify
  “WarpVeil” is free of malware…" (Apple's page words it "Apple cannot check … for malicious
  software"), Done / Move to Trash, on macOS 15, 26 and 27; Control-click → Open no longer
  bypasses it. The way in is System Settings → Privacy & Security → Security → Open
  Anyway (there for about an hour after the blocked launch), then the password. Nothing
  `release.sh` can do avoids that short of notarization; what avoids it is a Terminal install —
  `curl` sets no quarantine — which the notes and the README offer. The quarantine sits on every
  file of the bundle (`xattr -d` on the bundle alone leaves the engines quarantined; `-dr` strips
  all), and `install(1)` copies it onto the root sing-box. An update the app installed carries
  none, so Gatekeeper is a first-install matter
```

- Runtime Files, after the `subscriptions.json` line:

```
- `$TMPDIR/warpveil-update-<pid>/` — an update's download and unpack directory, 0700, removed
  when the update is staged or refused
- `<bundle dir>/.WarpVeil.app.new`, `.WarpVeil.app.old` — the update being swapped in and the
  old bundle on its way out; both gone after the relaunch
- `~/.config/warpveil/release-signing.key` — the release key's seed, 0600, the owner's machine only
```

- Gotchas, after `…that is why the deployment target is 15`:

```
- A file the app downloads with `URLSession`, or that `curl` downloads, gets `com.apple.provenance`
  only, never `com.apple.quarantine`; Gatekeeper assesses quarantined files only, so a bundle the
  app unpacked launches like one `install.sh` copied. A browser's quarantine on a zip follows it
  through `ditto -x -k` and `unzip` onto every extracted file, and `cp` and `install(1)` copy the
  attribute along
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
- `Process.terminationStatus` raises on a process that is still running — check `isRunning` first
```

The hardening's remaining "for the owner" items (an xray that dies while connected; a stale
same-tag install at launch) are untouched by this plan; step 1 widens the log line only.

`README.md` — Features gains `- **In-app updates** — checks GitHub releases daily and installs
only a release signed with the project's key`; "Install" becomes "Download"; "Release" is
rewritten; the Architecture tree gains `Updater.swift`:

```markdown
## Download

[Latest release](https://github.com/redoran29/WarpVeil/releases/latest) → `WarpVeil-<version>-macOS.zip`. Unzip it and drag `WarpVeil.app` to `/Applications`.

The app is not notarized by Apple, so the first launch is blocked with a dialog that Apple could not verify (or cannot check) it. Click **Done**, open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the WarpVeil line and enter your password. The button stays for about an hour after the blocked launch; Control-click → Open does not work since macOS 15.

Or from Terminal, with no dialog — a `curl` download carries no quarantine (the exact URL is on the release page):

```bash
curl -L -o /tmp/WarpVeil.zip https://github.com/redoran29/WarpVeil/releases/download/v<version>/WarpVeil-<version>-macOS.zip
ditto -x -k /tmp/WarpVeil.zip /Applications && open /Applications/WarpVeil.app
```

Later releases install themselves: Advanced → Updates in the window, or "Update to …" in the menu-bar menu. Quit from the app menu or from the menu-bar icon.
```

```markdown
## Release

```bash
NOTARY_PROFILE=NOTARY_PROFILE ./release.sh
```

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, add a `## <version>` section to `CHANGELOG.md`, commit, then run the script. It refuses uncommitted changes, an existing tag or release, a version that is not newer than the latest tag, a missing changelog section and a missing signing key. It builds Release, signs `xray`/`sing-box` and the `.app` (Developer ID + notarization when the keychain has one, ad-hoc otherwise), packages the `.zip`, signs it with `~/.config/warpveil/release-signing.key` (see `CLAUDE.md`, "release.sh") and creates the GitHub release with the zip and its `.sig`. Installed copies update themselves from Advanced → Updates.

One-time notary setup: `xcrun notarytool store-credentials NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific-password>`.
```

(The "To bump version, edit …" line goes; the tree line is
`├── Updater.swift              # In-app updates from GitHub releases, ed25519-verified`.)

## Rebasing the queued plans

- `plans/client-feature-parity.md:209-210` lists "In-app updater: canon, 'Binary upgrades ship
  with the app'; an updater is also an external package (Sparkle) which the canon excludes" —
  stale once step 5 lands; it should read "In-app updater: built (canon, 'In-app updates');
  engine upgrades still ship with the app". `:45` cites `teardownProcess` /
  `awaitTeardown(timeout:)` — it returns `Bool` after step 2, the quit path ignores it. `:1763`
  (`UNUserNotificationCenter`, "ad-hoc signed dev builds work"): the notification permission is
  a TCC grant tied to the cdhash, and every in-app update produces a new ad-hoc cdhash — expect
  it to be asked again after each update; item 4 should say so. Items that add rows to
  `AdvancedView`'s `Form`: the Updates section stays **last**. `:1931` (a Server submenu in
  `menuNeedsUpdate`): `Update to X…` stays after Open WarpVeil, before the separator. `:1928`
  ("`pm.connect` parks itself until the stop it finds in `teardownProcess` has exited") — still
  true; step 2's nil comes after that wait. Every later release that changes `run.sh` costs the
  two dialogs of D7 — unrelated to updates, worth saying in item 3 (kill switch).
- `plans/xray-hostname-server.md` — touches `connect`'s `.xray` branch and
  `buildTunWrapperConfig`, not step 2's lines; its live check (`:644`) installs with
  `install.sh`, which this plan does not change. Applies as written; after step 7 its dev copy
  is `1.3-dev`.

## Verification

### 1. Build

```bash
cd "/Users/lortan29/Documents/Home Projects/vpn-swift"
xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
  -derivedDataPath "$TMPDIR/warpveil-dd" build 2>&1 | rg -n "Sources/.*(error|warning):|BUILD (SUCCEEDED|FAILED)"
plutil -lint Info.plist WarpVeil.xcodeproj/project.pbxproj && bash -n release.sh dev-run.sh
```

Expect `BUILD SUCCEEDED` after each step and no `Sources/` line (clean here after steps 1+2 and
after all steps, Debug and Release). Never `swift build`.

### 2. Pipeline harness: the real `Updater.swift` against a local feed, no app launched

Compiles `Sources/Updater.swift` (with `private` stripped from a copy, nothing else changed) and
a `main.swift` into a throwaway `Harness.app` whose `Info.plist` carries the app's bundle id,
version `1.2`, a throwaway public key and a feed on `127.0.0.1:8766`, then runs the download →
verify → unpack → verify → stage pipeline over a good release and twelve hostile ones, and
`check()` over good, missing, not-a-release, empty-key and no-feed feeds; then `sign_zip`'s two
refusals. Needs a Release-built `WarpVeil.app` to cut releases from (any; the one below is a
scratch build). This exact harness ran green in this run.

```bash
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"; H="$TMPDIR/updater-harness"; mkdir -p "$H"
(cd "$REPO" && xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Release -derivedDataPath "$H/dd" CONFIGURATION_BUILD_DIR="$H/rel" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build)
cat > "$H/harness.sh" <<'HARNESS'
#!/bin/bash
#   harness.sh <repo> <Release-built WarpVeil.app> <workdir>
set -u
REPO="$1"; REL="$2"; H="$3"
mkdir -p "$H/feed" "$H/Harness.app/Contents/MacOS" "$H/staged" "$H/apps"; cd "$H" || exit 1
(umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > key)
PUB=$(swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' key)
SIGNING_KEY="$H/key"; PUBLIC_KEY="$PUB"; eval "$(sed -n '/^sign_zip() {/,/^}/p' "$REPO/release.sh")"
mk_release() {  # $1 label, $2 version, $3 bundle id, $4 zip name
    rm -rf "apps/$1"; mkdir -p "apps/$1"; ditto "$REL" "apps/$1/WarpVeil.app"
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
swiftc -O -target arm64-apple-macosx15.0 -o Harness.app/Contents/MacOS/Harness Updater.swift main.swift 2>&1 | rg -v "warning: "
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
echo "--- sign_zip refusals"
echo "wrongpub: $(PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= sign_zip feed/other.sig 2>&1; echo "rc=$?")"
printf 'not base64!!\n' > badkey; echo "badkey:   $(SIGNING_KEY=$H/badkey sign_zip feed/other.sig 2>&1; echo "rc=$?")"
HARNESS
chmod +x "$H/harness.sh"; "$H/harness.sh" "$REPO" "$H/rel/WarpVeil.app" "$H/run" 2>&1 | rg -v "^ditto: "
```

Expect, exactly: `good OK staged com.warpveil.app 1.3` · `badsig REFUSED: The signature does
not match — not installed` · `nosig REFUSED: Release 1.3 has no signed WarpVeil-1.3-macOS.zip`
· `wrongid REFUSED: The app in the archive is not com.warpveil.app` · `tagmismatch REFUSED: The
archive is not version 1.4, newer than 1.2` · `downgrade … not version 1.1, newer than 1.2` ·
`same … not version 1.2, newer than 1.2` · `noarch REFUSED: The app in the archive is not arm64`
· `toplink REFUSED: The archive holds no app` · `slip REFUSED: The app in the archive is not
com.warpveil.app` · `trunc REFUSED: Could not unpack the archive` · `missing REFUSED: nope.zip:
HTTP 404` · `notag OK staged com.warpveil.app 1.3`; nothing escaped to `$TMPDIR/target`, 0 work
dirs left; the staged bundle has `com.apple.provenance` only and a valid seal; then
`available("1.3")` twice, `idle` and `failed("The update feed answered HTTP 404")`, `upToDate`,
`failed("The update feed is not a GitHub release")`, `failed("No update key in Info.plist")`,
`failed("No update feed in Info.plist")`; `wrongpub` → `ERROR: the key is not the pair of
WVUpdatePublicKey in Info.plist` rc=1, `badkey` → `ERROR: … is not a base64 ed25519 seed` rc=1.

### 3. `release.sh`'s refusals, in a throwaway git repo (nothing published)

Cuts the script before its build and runs the guard section in a scratch repo with a local bare
`origin`, tags v1.0..v1.2, a scratch `HOME` holding a throwaway key. Ran green here.

```bash
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"; T="$TMPDIR/release-guards"; mkdir -p "$T/remote.git" "$T/work" "$T/home/.config/warpveil"
git -C "$T/remote.git" init --bare -q; cd "$T/work" && git init -q && git config user.email t@t && git config user.name t && git checkout -q -b main
cp "$REPO/Info.plist" "$REPO/CHANGELOG.md" .
sed -n '1,/^# --- Validate binaries exist/p' "$REPO/release.sh" | sed '$d' > release.sh
echo 'echo "GUARDS PASSED: version $VERSION, $(printf "%s" "$CHANGES" | grep -c "^- ") change lines, key pair ok"' >> release.sh; chmod +x release.sh
git add -A && git commit -qm init && git remote add origin "$T/remote.git" && git push -q origin main
for t in v1.0 v1.1 v1.2; do git tag "$t"; done; git push -q --tags origin
export HOME="$T/home"; (umask 077; swift -e 'import CryptoKit; print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())' > "$HOME/.config/warpveil/release-signing.key")
PUB=$(swift -e 'import CryptoKit; import Foundation; let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!; print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' "$HOME/.config/warpveil/release-signing.key")
/usr/libexec/PlistBuddy -c "Set :WVUpdatePublicKey $PUB" Info.plist; git commit -qam key
run() { echo "== $1"; ./release.sh 2>&1 | tail -1; }
run "clean tree, 1.3, latest v1.2, changelog, key -> pass"
echo x >> CHANGELOG.md; run "modified tracked file -> refuse"; git checkout -q CHANGELOG.md
echo x > untracked.txt; run "untracked file only -> pass"; rm untracked.txt
git tag v1.3; run "tag v1.3 exists locally -> refuse"; git tag -d v1.3 >/dev/null
git tag v1.3 && git push -q origin v1.3 && git tag -d v1.3 >/dev/null; run "tag v1.3 only on origin -> refuse"; git push -q origin :refs/tags/v1.3; git tag -d v1.3 >/dev/null 2>&1
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.5" Info.plist; git commit -qam v115; run "version 1.1.5, no tag, below v1.2 -> refuse as not newer"; git reset -q --hard HEAD~1
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.10" Info.plist; git commit -qam v110; run "version 1.10 (newer under sort -V) but no changelog section -> refuse on the changelog"; git reset -q --hard HEAD~1
mv "$HOME/.config/warpveil/release-signing.key" "$HOME/k"; run "no key file -> refuse"; mv "$HOME/k" "$HOME/.config/warpveil/release-signing.key"
/usr/libexec/PlistBuddy -c "Set :WVUpdatePublicKey " Info.plist; git commit -qam nokey; run "empty WVUpdatePublicKey -> refuse"; git reset -q --hard HEAD~1
```

Expect `GUARDS PASSED: version 1.3, 8 change lines, key pair ok` for the two "pass" cases and
one `ERROR: …` line naming the reason for each of the others. (`gh release view` in that repo
fails for want of a GitHub remote, which the guard reads as "no release" — the real repo's
remote is `github.com/redoran29/WarpVeil`, where the check is real.)

### 4. Live check (main session, one script, interactive)

Everything happens on a dev copy built from the working tree into `$TMPDIR/update-live/app`
(bundle id `com.warpveil.app.dev`, version `<v>-dev`), pointed at a feed on `127.0.0.1:8767`
signed with a throwaway key, whose "release" is the same build at `<v>-dev-updated`. The dev
copy's `autoConnect` is forced off for the run and restored at `stop`, and **no phase connects**:
the installed app and its tunnel are never touched, and the user is never without a tunnel.
**The clicks are the user's** (or the main session's through computer use): the script says what
to click and waits for Enter, then checks the result on disk and in `ps`. `stranger` is the
public-distribution check: a browser-style download of the dev copy, blocked, approved, then
Ping all — the nested-engine question of the facts. `apps-probe` is the `/Applications` App
Management probe (a throwaway ad-hoc app that replaces itself there with the updater's helper and
is removed again).

```bash
cat > "$TMPDIR/update-live.sh" <<'EOF'
#!/bin/bash
# Live check for plans/in-app-updater.md. Everything happens on a dev copy (bundle id
# com.warpveil.app.dev, version <v>-dev) built from the working tree into $W/app and pointed at
# a feed on 127.0.0.1 signed with a throwaway key; the "release" it installs is the same build
# at version <v>-dev-updated. /Applications/WarpVeil.app and the tunnel are never touched: the
# dev copy's autoConnect is forced off for the run and restored at stop, and no phase connects.
#
#   update-live.sh setup     build, key, feed, server, launch the dev copy (window appears)
#   update-live.sh bad       feed serves a wrong signature — click Install, then Enter: refused
#   update-live.sh good      feed serves the real one — click Install, then Enter: installed
#   update-live.sh stranger  a browser-style download of the dev copy: quarantined zip, unpacked,
#                            launched — Gatekeeper blocks it; Open Anyway; then Ping all runs the
#                            bundled engines from the quarantined bundle
#   update-live.sh stop      quit the dev copy, stop the server, restore the dev defaults
#   update-live.sh apps-probe   optional: a throwaway ad-hoc app replaces itself in
#                               /Applications the way the updater does; cleaned up after
set -uo pipefail
REPO="/Users/lortan29/Documents/Home Projects/vpn-swift"
W="$(getconf DARWIN_USER_TEMP_DIR)update-live"; mkdir -p "$W"
APP="$W/app/WarpVeil.app"; BIN="$APP/Contents/MacOS/WarpVeil"; PLIST="$APP/Contents/Info.plist"
DEV_ID="com.warpveil.app.dev"; PORT=8767; FEED="http://127.0.0.1:$PORT"
fails=0
log() { printf '%s %s\n' "$(date +%T)" "$*"; }
ok()  { log "ok   $*"; }
bad() { log "FAIL $*"; fails=$((fails + 1)); }
dev_pid() { pgrep -f "^${BIN}$" | head -1; }
# Any WarpVeil process that is not the installed one: a translocated quarantined copy runs from
# /private/var/folders/.../AppTranslocation/, not from where it was unpacked.
other_pid() { pgrep -fl "WarpVeil.app/Contents/MacOS/WarpVeil$" | grep -v " /Applications/" | awk '{print $1}' | head -1; }
dev_version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null; }
quit_dev() {
    [ -n "$(dev_pid)$(other_pid)" ] || return 0
    osascript -e "tell application id \"$DEV_ID\" to quit" >/dev/null 2>&1
    for _ in $(seq 1 50); do [ -z "$(dev_pid)$(other_pid)" ] && break; sleep 0.2; done
    [ -z "$(dev_pid)$(other_pid)" ] && ok "dev copy quit" || { pkill -f "WarpVeil.app/Contents/MacOS/WarpVeil$" -U "$(id -u)" 2>/dev/null; bad "dev copy had to be killed"; }
}
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
    rm -rf "$W/app" "$W/nextapp"; mkdir -p "$W/app" "$W/nextapp"
    (cd "$REPO" && xcodebuild -project WarpVeil.xcodeproj -scheme WarpVeil -configuration Debug \
        -derivedDataPath "$W/derived" CONFIGURATION_BUILD_DIR="$W/build" \
        PRODUCT_BUNDLE_IDENTIFIER="$DEV_ID" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build) || { bad "build failed"; exit 1; }
    ditto "$W/build/WarpVeil.app" "$APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CUR" -c "Set :CFBundleName WarpVeil Dev" \
        -c "Set :WVUpdateFeed $FEED/latest.json" -c "Set :WVUpdatePublicKey $PUB" "$PLIST"
    codesign --force --sign - "$APP" 2>/dev/null
    ok "dev copy $CUR at $APP, feed $FEED/latest.json"

    log "the release: the same build at $NEXT, zipped and signed the way release.sh does"
    ditto "$APP" "$W/nextapp/WarpVeil.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$W/nextapp/WarpVeil.app/Contents/Info.plist"
    codesign --force --sign - "$W/nextapp/WarpVeil.app" 2>/dev/null
    ZIP="WarpVeil-${NEXT}-macOS.zip"
    (cd "$W/nextapp" && ditto -c -k --sequesterRsrc --keepParent WarpVeil.app "$W/feed/$ZIP")
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
    log "next: $0 stranger   (then $0 stop)"
    ;;
stranger)
    # A stranger's first install, on the dev copy: the zip gets a browser's quarantine, is
    # unpacked the way Archive Utility would (ditto propagates the attribute — verified) and
    # launched. Gatekeeper blocks it; the clicker goes through Open Anyway. Then Ping all runs
    # the bundled engines from the quarantined bundle in user space — no root, no TUN — which is
    # the open question: whether the approval covers the nested binaries.
    [ -d "$APP" ] || { bad "no dev copy — $0 setup first"; exit 1; }
    quit_dev
    SDIR="$W/stranger"; rm -rf "$SDIR"; mkdir -p "$SDIR"; SAPP="$SDIR/WarpVeil.app"
    (cd "$W/app" && ditto -c -k --sequesterRsrc --keepParent WarpVeil.app "$SDIR/download.zip")
    xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Chrome;$(uuidgen | tr A-Z a-z)" "$SDIR/download.zip"
    ditto -x -k "$SDIR/download.zip" "$SDIR"
    xattr -p com.apple.quarantine "$SAPP/Contents/Resources/sing-box" >/dev/null 2>&1 && ok "the unpacked engines are quarantined, like a browser download" || bad "no quarantine on the unpacked engines — the probe would prove nothing"
    log "spctl: $(spctl -a -vv -t execute "$SAPP" 2>&1 | tr '\n' ' ')"
    open "$SAPP" 2>/dev/null || true
    echo ""
    echo ">>> Expected now: “WarpVeil Dev” Not Opened — Apple could not verify … Click Done (NOT Move to Trash)."
    echo ">>> Then System Settings → Privacy & Security → Security → Open Anyway → password → Open. Note the exact dialog texts."
    read -r -p ">>> Press Enter once the dev copy's window is up. "
    SPID=$(other_pid)
    [ -n "$SPID" ] && ok "the quarantined copy runs, pid $SPID, from $(ps -o comm= -p "$SPID")" || bad "no non-installed WarpVeil process is running"
    echo ">>> Now Servers → Ping all, then press Enter at once."; read -r
    seen=""
    for _ in $(seq 1 100); do
        ps -axo args= | grep "Contents/Resources/sing-box\|Contents/Resources/xray" | grep -v "^/Applications/" >/dev/null && { seen=yes; break; }
        sleep 0.2
    done
    [ -n "$seen" ] && ok "the bundled engines ran from the quarantined bundle after Open Anyway" || bad "no engine process from the quarantined bundle seen in 20 s — Gatekeeper may block the nested binaries; see the syspolicy lines below"
    log "syspolicy, last 5 min:"; log show --last 5m --predicate 'subsystem == "com.apple.syspolicy"' 2>/dev/null | rg -i "sing-box|xray|WarpVeil" | tail -8
    log "the rows should show numbers; a row of -- means the engines never ran"
    quit_dev
    log "next: $0 stop"
    ;;
stop)
    quit_dev
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
    echo "usage: $0 setup | bad | good | stranger | stop | apps-probe" >&2; exit 1 ;;
esac
log "finished with $fails failure(s)"; exit $((fails > 0))
EOF
chmod +x "$TMPDIR/update-live.sh"
"$TMPDIR/update-live.sh" apps-probe   # optional, first: the /Applications question
"$TMPDIR/update-live.sh" setup        # a "WarpVeil Dev" window appears; wait ~20 s for the row
"$TMPDIR/update-live.sh" bad          # click Install, Enter
"$TMPDIR/update-live.sh" good         # click Install, Enter — the dev copy quits and comes back
"$TMPDIR/update-live.sh" stranger     # Done → Open Anyway → password; Ping all; Enter
"$TMPDIR/update-live.sh" stop
```

Expect every line `ok` and `finished with 0 failure(s)` in each phase. In `bad`: the row shows
"The signature does not match — not installed", same pid, bundle still `<v>-dev`, nothing
staged, `other.sig` fetched. In `good`: a new pid at the same path, `<v>-dev-updated` on disk,
no `.new`/`.old`, no work dir, no quarantine, a valid seal, `/Applications/WarpVeil.app`
untouched. In `stranger`: the engines quarantined before launch; the Gatekeeper dialog (record
its exact text — it goes into the README if it differs from "could not verify / cannot check");
the copy running (from an `AppTranslocation` path is fine — that is what launching from the
unpack directory does); after Ping all, an engine process from the quarantined bundle and
numbers in the rows. If the engines never run, see "Risks". In `apps-probe`: `launched v1` →
four `ok` lines → `launched v2` in `/Applications/wvprobe.log`, no TCC event. What the script
cannot see: the row's text, the status menu item and the dialogs — the clicker reads those.

The build/package part of `setup` and the zip/quarantine part of `stranger` were run in this
session against the scratch copy without launching anything (a `1.3-dev` dev copy, a 41 MB
zip, an 89-byte signature, the engines quarantined after `ditto -x -k`, `codesign` valid); the
launches, clicks and relaunch are the main session's.

### 5. After publishing: the owner's machine gets 1.3 — a fork for the owner

1.2 cannot install 1.3 itself. Two ways, both end with the two dialogs of D7 (connect, then the
Passwordless toggle, which purges `warpveil-1-2`):

- **`./install.sh`** — no Gatekeeper (nothing is quarantined), the tunnel is down for the
  quit + relaunch (~15 s, the first connect's password dialog included). The stranger's root
  path (a quarantined sing-box run as root) stays unverified until a stranger reports.
- **The release zip through Chrome, the way a stranger would** — the exact public path end to
  end on this machine: Done → Open Anyway → password, then the first connect runs the
  quarantined bundle's sing-box as root through osascript. The tunnel is down for the download
  and the clicks (1–2 min). This is the only way to answer the root half of the nested-engine
  question before a stranger does; the Terminal line of the notes can be tried right after as
  the second install.

The main session asks the owner which, then runs it; afterwards `helper-live3.sh probe`-style
checks apply (`git show 0127c17:plans/done/privileged-helper-hardening.md`, "Review"): the tunnel
back, passwordless re-installed for `1-3`, `/etc/sudoers.d/` holding only `warpveil-1-3`,
`/usr/local/libexec/` only `warpveil-1-3`. Then Advanced → Updates on the installed 1.3 reads
"Up to date" after Check for Updates (v1.3 is the latest release and not newer than itself).

## Risks and what is not verified

- **The nested engines after Open Anyway** (the open question of the facts). If the `stranger`
  phase shows the engines blocked, the fix is ~10 lines, not in this plan's steps: at launch,
  when `Bundle.main.bundleURL` carries `com.apple.quarantine`, remove the attribute from every
  file under the bundle (`removexattr` over `FileManager.enumerator`) — the user has already
  approved the bundle, and the engines are the bundle's own bytes. It would be its own commit
  and a canon line; the README's `xattr -dr com.apple.quarantine /Applications/WarpVeil.app`
  is the by-hand equivalent in the meantime. If the ping works but the root exec does not
  (Verification 5, the Chrome way), the same fix applies — the passwordless copy is made by
  `install(1)`, which carries the attribute.
- **App Management in `/Applications`** is answered by the first version of this plan's scratch
  probe, the operations `install.sh` runs every deploy, and external reports; the
  `/Applications` probe is in the live script because this session was refused write access
  there. If it blocks, the failure is silent in the app (old version comes back, update offered
  again) and the remedy is a `log show` for `kTCCServiceSystemPolicyAppBundles`.
- **The helper has no channel back**: a swap that did not happen is only visible as the old
  version relaunching. Accepted (D4).
- **A rate-limited exit IP** makes the manual check say "HTTP 403" until the hour turns; the
  automatic one retries daily. Accepted (D6).
- **The first signed release is a by-hand install** (D11); the first OTA install is 1.3 → 1.4,
  when the whole path runs for real in `/Applications` for the first time. Until then the
  end-to-end evidence is the dev copy in its own directory.
- **`awaitTeardown` false cancels the update**, including for a stop that is still showing a
  password dialog after 30 s; the dialog stays up, the user may still answer it, and the next
  Install succeeds. A stop that exits 0 while sing-box survives (the scripts return 1 in that
  case) would let the update proceed — same as the quit path. If `killVPNProcesses` could not
  even start the stop (`run()` threw — `/usr/bin/sudo` and `/usr/bin/osascript` exist), the
  stop is nil after step 2's clearing and the update proceeds with a root engine possibly up:
  the new app's first connect then fails with sing-box's own TUN error in Logs, as the canon
  describes for any foreign engine. Accepted; noted, not handled.
- **A translocated copy cannot update itself** (facts). The README says drag to `/Applications`;
  a user who runs it from `~/Downloads` sees the stage move's error in the row and the fix is
  the drag.
- **`ditto`'s `waitUntilExit` blocks a cooperative thread** for ~0.5 s. Accepted.
- **The 1.3 changelog section is a draft**; the owner edits it before step 9. The notes'
  Gatekeeper wording hedges on the dialog's text on purpose (D9); `stranger` records the real
  one.
- Not run live here: any launch, click, quit or relaunch of any app; the Gatekeeper dialog; the
  root exec of a quarantined sing-box; `gh release create`; `git push`. Not tested: an update
  while a restart is pending — covered by design (the closure's unconditional `disconnect()`
  cancels it), not by a run.

## Validation of this plan

Done in this run; repo untouched except this file (`git status --porcelain` shows `?? p.sh` and
this file); no engine of the app's started, stopped or reconfigured; `/Applications`,
`/usr/local/libexec`, `/etc/sudoers.d` and `/var/run` untouched; no sudo; no `dev-run.sh`,
`install.sh` or `release.sh` run; no app launched; no tag, release, push or upload; no real key
generated (a throwaway seed in the scratch dir); the subscriptions file never read. Scratch
copies came from `git archive HEAD` (`0127c17`) under `/private/tmp/claude-501/`, built with
`xcodebuild` into scratch derived-data paths:

- Baseline Debug build: `BUILD SUCCEEDED` (10 s).
- Steps 1+2 alone (`ProcessManager.swift` only) on a clean copy: `BUILD SUCCEEDED`, no
  `Sources/` line; the diff quoted in "Steps" is that copy's.
- Steps 1–7 on a second clean copy, applied by a script that asserts every anchor matches
  exactly once (one anchor had drifted — the canon's `BypassService.swift` line gained "file
  keys" — and was corrected; every other anchor matched): `plutil -lint` passes on `Info.plist`
  and `project.pbxproj`, `bash -n` on `release.sh` and `dev-run.sh`, `BUILD SUCCEEDED` in Debug
  and in Release with no `Sources/` warnings; the built `Info.plist` reads `1.3` / `4` / the
  feed / the throwaway key. Re-applied to a third clean copy after the final wording changes:
  `BUILD SUCCEEDED`. The diffs quoted above are that copy's.
- Verification 2 ran exactly as quoted against the scratch copy's `Updater.swift` and its
  Release build: every expected line, nothing escaped, 0 work dirs, the staged bundle with
  `com.apple.provenance` only and a valid seal, the eight `check()` outcomes, both `sign_zip`
  refusals (rc 1, one `ERROR:` line each).
- Verification 3 ran as quoted: both passes print `GUARDS PASSED: version 1.3, 8 change lines,
  key pair ok`; each refusal prints its `ERROR:` line — a modified tracked file, a local tag, a
  tag only on origin (fetched first), `1.1.5` as not newer than `v1.2`, `1.10` passing the
  version check (`sort -V`) and failing on the missing changelog section, no key file, an empty
  plist key. The `awk` extraction yields the section's lines with the surrounding blank lines.
- `update-live.sh`: `bash -n` passes; its build/package part and the `stranger` zip/quarantine
  part ran against the scratch copy without launching anything (see the end of Verification 4).
- Machine probes, each with its output read: `curl` download (`provenance` only); `install(1)`,
  `cp`, `ditto -x -k`, `unzip` (quarantine carried / propagated); `xattr -d` vs `-dr`; `spctl -a
  -t execute` verdicts; `syspolicy_check distribution`; `codesign --verify` on the unpacked
  quarantined bundle; `sort -V`; `git tag --sort`; `gh repo view --json url`;
  `Process.terminationStatus` on a running task (raises); the key one-liners. The first
  version's probes (`URLSession` quarantine, `ditto` zip-slip and symlink, the scratch
  self-replacing app, `Info.plist`/executable tampering, `Bundle(url:)`, version comparisons,
  LibreSSL, `swift -`, the system `TCC.db`) are kept as recorded there.
- GitHub: `releases/latest` headers and body (one request), `gh release view v1.2`, `gh release
  list`, `gh auth status`, `git remote -v`.
- Web: Apple's Mac User Guide page for macOS 15, 26 and 27 (same steps, "about an hour"); Apple's
  "Safely open apps on your Mac" (alert wording, Done / Move to Trash); macworld, osnews and
  Christian Tietze on Sequoia (Control-click gone, 15.1's broken override); a Tahoe guide
  (stricter in 26.5, right-click gone, authentication required); two 2026 CVE entries naming
  macOS 27 (a bypass fixed, no policy change found); developer-forum threads 767612 and 812323
  (the sandbox consent flag — not this case). No source states the nested-engine rule; it is
  left to the live check.
- Every symbol named above was read in the source at the cited lines; the parity and hostname
  plans were read at the lines they cite.
