## 17. WarpVeil updates itself from GitHub, and anyone can install it
Owner, 2026-10-14: the app should update itself from GitHub releases without an Apple Developer ID,
and anyone should be able to download it. Owner, 2026-10-15: 1.3 ships as soon as the updater is
ready — what is in `main` plus the updater — and every later feature arrives through it. Backlog 17.

### Done when
- `release.sh` refuses, each in a throwaway repo: uncommitted tracked changes, an existing tag or
  release, a version not newer than the last tag, no `CHANGELOG.md` section for the version, no
  signing key or a key that does not match the app's public key.
- A dev copy offered a newer signed release from a local feed: Install stops the engines, swaps the
  bundle and relaunches into the new version; a bad signature, another bundle id, an older version
  and an unsigned zip are refused, with the reason in the Updates row.
- 1.3 is on GitHub with the zip, its signature and notes from `CHANGELOG.md`; the README has a
  Download section.
- On a clean macOS user account, the README's steps install 1.3 and the tunnel connects.
- The owner's Mac runs 1.3, and Check for Updates reads "Up to date".
- A connect while another tunnel already holds 172.19.0.1 never reads Connected.

### Decided
- A homegrown updater over the GitHub releases API; no Sparkle — the canon allows no packages
  (owner, 2026-10-14).
- Each release zip carries an ed25519 signature made with our own key; the app checks it before
  anything is unpacked (owner, 2026-10-14).
- One row in Advanced — Check for Updates, or Install once a release is known — and an "Update to …"
  item in the menu-bar menu while one is known; a check once a day. No toggle, no notification, no
  dialog (owner, 2026-10-14).
- An update installs on a click, not by itself (owner, 2026-10-14).
- An update is loud: a banner with Install at the foot of the connection column, on every page,
  besides the Advanced row and the menu item — still no notification and no dialog (owner,
  2026-10-25).
- Ad-hoc signed releases: the README and the notes tell a stranger exactly what macOS will show
  and what to click (owner, 2026-10-14).
- `release.sh` refuses what cannot be released, and its notes come from a hand-written
  `CHANGELOG.md` (owner, 2026-10-14).
- 1.3 is the first release with the updater, installed by hand once; it ships before the other
  planned features (owner, 2026-10-15).
- The engine shell, not the app, says when the tunnel is up. It changes run.sh, which re-asks the
  password, so it lands with the 1.3 bump, which re-asks it anyway (owner, 2026-10-15; review
  round 5 of plans 18 and 19, `git show 18eded9:plans/18-xray-server-loop.md`). How it tells is
  round 2's decision below.
- Review round 2: the TUN is named (a free utun, the way sing-box would pick one) and the engine
  shell waits for the address on exactly that interface — no comparing interface lists (owner,
  2026-10-15). Since round 4 the shell picks the name itself, right before sing-box starts.
- Review round 4, replacing round 2's "a failed stop leaves the tunnel up": the engine shell stops
  its own sing-box and the session ends when the helper exits; the app runs no privileged stop and
  a disconnect asks no password (owner, 2026-10-15). Since round 6 only the passwordless helper
  runs the engine (plan 21), so the stop is run.sh's TERM alone.
- Review rounds 1–2: the root PID file keeps its version tag (CLAUDE.md, "Version-tagged
  privileged paths"); the update keeps stopping the engines before the swap (owner, 2026-10-15).

### Open for the owner
- A version bump asks for the password at its first connect, to install the new version's helper —
  once since plan 21. Default: accepted, and the 1.3 notes say so.
- The signing key is made by the builder and lives outside the repo. Default: the builder says
  where; the owner keeps a copy in a password manager — without it no installed copy can verify an
  update again.
- The 1.3 section of `CHANGELOG.md` is public text. Default: the builder drafts it, the owner edits.
- Publishing 1.3 is outward-facing. Default: the builder asks the owner before the release is
  created on GitHub.

### Depends on
- `gh` logged in to the repository's account — true on 2026-10-14.
- The release signing key — does not exist yet; step 1 makes it.

### Risk
- A lost signing key strands every installed copy: no update verifies, and the way out is a new key
  plus one install by hand everywhere. Guarded by the backup above.
- A broken updater in 1.3 cannot fix itself; the first real update is 1.3 → 1.4. Guarded by the
  local-feed check on a dev copy before 1.3 is published.
- An update must not leave root engines behind or the app gone from `/Applications`: the engines
  stop first, and the new bundle is staged next to the old one and renamed in, as `install.sh` does.
- The engines nested in a quarantined bundle may be blocked after Open Anyway; if the clean-account
  check shows it, the app clears the quarantine from its own bundle at launch.

### Steps
1. **Trusted releases.** The signing key, `release.sh`'s refusals and signature, and notes from
   `CHANGELOG.md`. Done when: the first check above, and a signed zip verifies.
2. **The updater.** The Updates row, the daily check, and Install. Done when: the second check above.
3. **Publish 1.3.** The engine shell's start line, the version bump, the README's Download
   section, the release on GitHub, the owner's Mac on 1.3. Done when: the last four checks above.

4. **A loud update, tried for real.** The banner, then 1.3.1 published and installed on the
   owner's Mac from the banner with the tunnel up. Done when: the banner offers 1.3.1, Install
   relaunches into 1.3.1, the first connect installs 1.3.1's helper with one password, and Advanced
   reads Up to date.

### Built (2026-10-25, step 4)
The banner (`1c5bbbc`, `f7d8aae`, `7791104`), the session's configs on stdin (`02326d9`), then
1.3.1 published and installed from the banner on the owner's Mac with the tunnel up: the swap and
relaunch worked, but the relaunched app could not install its helper — `visudo: command not found`,
the swap shell's `PATH=/usr/bin:/bin` reaching `do shell script` through `open`. Fixed in `e9af589`
(admin shells pin PATH, the swap shell exports the full one) and shipped as 1.3.2, installed from
1.3.1's banner: the relaunched app still has `/usr/bin:/bin`, and its helper installed with one
password, the sudoers entry and libexec of 1-3-2 are in place, no `.WarpVeil.app.new`/`.old` is
left, the tunnel connects, and `releases/latest` answers v1.3.2. Left of this plan: the
clean-account check and a live connect while another build holds 172.19.0.1.

### Review (2026-10-25, step 4)
`/code-review 601b248..1c5bbbc`, then `1c5bbbc..f7d8aae`, findings and what was done:
- The banner vanished at a failed install and for every daily check; the state's wording was
  written twice; Advanced and the status menu kept their own test (`f7d8aae`, then one source,
  `Updater.newerVersion`, an Install that waits out a check, a full failure reason).
- The session's configs were removed only at a clean end, so a crash left the server's
  credentials in `$TMPDIR` under a PID nothing looks for: both engines read them on stdin now
  (`02326d9`).
- Not changed: files an earlier build left are dirhelper's (3 days); a failed write into an
  engine's stdin shows as the engine's own error; the window's minimum grows with the banner
  (`sizingOptions` `[.minSize]`) rather than overlapping; a ping still writes its configs for the
  length of its run.

### Leaves out
- Notarization and a Developer ID; Sparkle; delta updates; a progress bar.
- Installing an update without a click.
- Fewer password prompts after a version bump (see Open).

### What we know (2026-10-15)
- Releases v1.0, v1.1 and v1.2 exist on GitHub with one asset each, `WarpVeil-<version>-macOS.zip`,
  built by `release.sh`; the installed app is 1.2, ad-hoc signed.
- `release.sh` today replaces an existing tag and release instead of refusing.
- The old plan holds the verified facts — the GitHub API, quarantine and Gatekeeper on macOS 15–27,
  translocation, App Management — and the full design:
  `git show 975f8b4:plans/in-app-updater.md`.

### Built (2026-10-15)
- Step 1: `055d5a0`, `977b323`, `1859a07`. The key is `~/.config/warpveil/release-signing.key`
  (0600). Checked: `release.sh`'s guards in a throwaway repo with a fake `gh` — each refusal of the
  first check, a `gh` failure other than "release not found", a key that is not a seed; a clean tree
  passes. A 5 MB file signed with the real key verifies against `WVUpdatePublicKey`; with one byte
  changed it does not.
- Step 2: `b3e57f1`, `cb95b41`, `f0c7e41`. Checked: the real `Updater` against a local feed — a good
  release staged, eleven hostile ones refused with their reason, nothing escaped, no work directory
  left, eight check outcomes. A dev copy on a local feed: the launch check offered the release;
  a wrong signature, no signature, another bundle id and an older version inside a newer tag were
  refused with the reason in the row, an older tag read Up to date; the good one quit, swapped and
  relaunched into the new version at the same path — no quarantine, a valid seal, nothing left.
  An ad-hoc app replaced itself in `/Applications` and relaunched with no App Management prompt.
  Not checked: an install with the tunnel up — a dev copy cannot take the TUN while the installed
  app holds it; the first real one is 1.3 → 1.4.
- Step 3 so far: `b399876` (the engine shell's start line; checked with a stand-in `ifconfig` for a
  fresh start, a tunnel already held, a held one that goes, and a TERM before the TUN), `5f96111`
  (1.3), `9d4896a` (README). Left: the owner's word, the release, 1.3 on the owner's Mac, the
  clean-account check.
- Step 3, 2026-10-25: plans 21 and 22 landed in 1.3 first (owner). The owner's word, then
  `release.sh`: v1.3 on GitHub, neither draft nor prerelease, with the zip and its `.sig`, notes
  from `CHANGELOG.md`; `releases/latest` answers v1.3. The downloaded zip verifies against
  `WVUpdatePublicKey` and a one-byte change does not; it unpacks to a 1.3 arm64 bundle that passes
  `codesign --verify --deep`. The owner's Mac runs 1.3 (`install.sh` from the same tree) and
  Advanced reads "WarpVeil 1.3 — Up to date". Left: the clean-account check, and a connect while
  another build holds 172.19.0.1 — live, it needs a dev copy's helper install, which takes the
  installed copy's helper away and asks the owner's password twice.

### Review (2026-10-15, round 1)
`/code-review 3777f09..9d4896a`, findings and what was done:
- `Bundle(url:)` caches per path, so a second install checked the first archive: a directory per
  attempt (`39bea04`).
- A failed stop was forgotten at the next connect, and an update could swap past a live root
  engine: kept until a new engine shell shows the previous one gone (`ce1f85b`).
- A failed automatic check waited a day: asked hourly, due a day after the last answer (`5fbb331`).
- A second install, or a check finishing during one, could run two swaps (`c018e49`).
- A TUN name freed and reused after the snapshot left the session at Connecting; a held address
  cost 2 s with no word in the log (`b2e3e87`).
- The swap could delete both bundles when its rollback failed (`84bb9e0`); the bundle was staged
  before the engines stopped (`847ed6c`); download temp files stayed behind (`047af15`).
- The Terminal install merged into a running older copy (`6315016`).
- The quit moved out of the updater (`a8e2358`); a dead timer property (`5fbb331`); a wrong statement
  about `-dev` versions (`168600d`).
- Not changed: a cancelled stop throws the verified download away, so a retry downloads again — a
  rare path, and a staged copy kept across attempts is state to invalidate when the release changes.
- For the owner: the root PID file carries the version tag, so no other version can find a running
  engine — the root of the update's all-or-nothing teardown and of `install.sh`'s sweep by the old
  tag. Default: kept (CLAUDE.md, "Version-tagged privileged paths").

### Review (2026-10-15, round 2)
`/code-review 9d4896a..55346ab`, findings and what was done:
- Staging after the stop found an unwritable directory only after the tunnel was down: the
  directory is checked before anything (`e101b72`).
- The swap still deleted the new bundle when its rollback failed too (`712d12d`).
- A connect during the update's wait could start an engine the swap then left behind (`1548d33`).
- `NSApp.terminate` left the updater for AppState, which the canon also keeps AppKit out of: the
  delegate hands AppState its quit (`fa87f68`).
- An older check could write over a newer one (`69182d3`); an answer dated ahead held checks off
  (`9b5d05f`); the status rule existed twice (`895f075`); staging ran on the main actor
  (`99c9101`); the zip stayed until the end of the install (`9021d5d`); the Terminal install
  downloaded to a fixed name in `/tmp` (`48aeb32`).
- Connected, changed a fifth time: the app names the TUN and the shell waits on that interface
  (`f632ca3`, owner's decision above) — which also removes the loop's `set -e` trap and the 2 s wait.
- The failed-stop record, changed a fourth time: a session ends only once its root engine is gone,
  a failed stop leaves it up, and nothing is kept across sessions (`88ababe`, owner's decision
  above). Not run live: the stop's password dialog needs the owner — checked at the 1.3 install.
- The version-tagged PID path stays (owner's decision above).

### Review (2026-10-15, round 3)
`/code-review 55346ab..10731ac`, findings and what was done:
- A disconnect or a quit during the connect's own password dialog stacked a second dialog and left
  the first up: the helper goes before the stop again (`fd83cd1`).
- A skipped restart stayed pending for a later wake, and its line hid that the old settings run on
  (`98bbe14`).
- The TUN's name was picked before xray's start; a name taken before sing-box started could match
  for a few milliseconds; the warning about a held address was gone (`7c3c4eb`).
- The update's hold on connects covered only AppState's connect, not ProcessManager's restarts
  (`62285db`).
- `abandonStart` duplicated `endSession` (`68bb041`); the stop's launch was written twice
  (`ee94b41`); an empty branch in `awaitTeardown` (`6878df2`); the Terminal install left its
  download (`f542738`); this plan still described the replaced start-line mechanism.
- Not changed: a quit whose stop was cancelled leaves the tunnel to the next connect, which stops
  the old xray before it replaces the root sing-box — so a connect cancelled at its dialog leaves
  the state an engine a crash orphaned leaves, which the canon describes (PID files).
- Not changed: `awaitTeardown` polls every 100 ms for as long as a stop's password dialog stays
  open — a few property reads ten times a second while the user decides.

### Review (2026-10-15, round 4)
`/code-review 10731ac..bb46c51`, findings and what was done:
- Round 3's "helper before the stop" (`fd83cd1`) undid part of the owner's round-2 decision without
  asking — a breach of the canon's rule for findings that undo a pass. Each order of stop and
  helper lost a case: stacked dialogs, a session stuck at Connecting, Connected with no TUN. Taken
  to the owner as a construction question: the engine shell stops its own sing-box and the app's
  privileged stop is gone (`04b0fc4`).
- The TUN's name was still picked before the password dialog: the shell picks it (`04b0fc4`).
- The update's hold started after the download, a refused second install released the first's
  hold, and a restart the hold refused stayed pending for a wake (`380edc5`).
- The inline osascript stop duplicated stop.sh, and `awaitTeardown` leaned on short-circuiting: both
  went with the privileged stop (`04b0fc4`).
- Checked: the shell in both variants with a stand-in `ifconfig` and engine — the name past every
  utun, the start line, the stop on the session file's removal and on TERM, no start once the
  session file is gone, the warning for a held address, the engine exiting by itself, no staged
  file left. Not run live: the root path needs the owner's password — at the 1.3 install.

### Review (2026-10-15, round 5)
`/code-review bb46c51..db37c68`, findings and what was done:
- The session file sat in `$TMPDIR`, which `dirhelper` clears of files untouched for 3 days, so a
  session without passwordless would have stopped by itself: Application Support (`c1595ea`).
- Killing the osascript helper hung on the shell's starting line, read late from a log every copy
  of the version shares, and a late shell ran `kill_pid_file` before it looked at the session: the
  helper is left to exit by itself, and the shell checks the session first (`c98559b`).
- The shell's stop waited on sing-box without limit, and a TERM right after the start orphaned it:
  the trap comes first and ends with a KILL after 5 s (`5b09001`).
- A requested disconnect logged an exit code like a dead engine (`481771a`).
- The update's hold from the start of the download turned away a wake's or a routing edit's restart,
  undoing round 4's ask in part: the hold on engine starts begins at the stop again, a Connect click
  during the download is refused by AppState, and only the install that set the hold releases it —
  round 4's two cases still hold (`f1a11ba`).
- Leftovers: the xray wait (`e76fa03`); stale comments on the stop's password and on the copy that
  runs (`dd41624`).
- Process slips, history kept as it is: `04b0fc4` bundled the shell's naming of the TUN with the
  new stop, and the plan was corrected in `db37c68` rather than in `04b0fc4`.

### Review (2026-10-15, round 6)
`/code-review db37c68..f8548e4`. Its findings fell mostly on the mode without passwordless —
the osascript helper at its dialog during a teardown, a restart's dialog during an update, the
session file's crash leftovers and failures — and showed rounds 3–5 changing the same places in
turn, twice again without the owner (`c98559b` rewrote an owner-marked line, `f1a11ba` undid part
of round 4). Taken to the owner as the construction question: only the passwordless helper runs
the engine (plan 21, `54ffbb4`), which removes those cases. Also:
- The shell's cleanup read `${!:-}`, unbound under bash 3.2's `set -u`; it sent a SIGKILL against
  `kill_pid_file`'s rule; the EXIT trap missed the named copy (`2723b9d`).
- The disconnect line came before the engine's last lines (`3ee44f8`); the hold's message was
  written twice (`5e472d6`).
- The update hold, after rounds 4 and 5: engine starts held from the stop, Connect clicks refused
  from the download on, the hold released only by the install that set it — each round's case
  holds, and with one mode a restart during the download asks nothing.
- Not changed: `isTunnelUp` reads a start line from the log every copy of one version shares, so
  an Xcode-launched copy of the installed version could read the other's — the canon's one-build-
  per-tunnel rule; dev copies carry their own tag.
- Process slip: `dd41624` bundled two comment fixes.
