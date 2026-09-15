# Local install command: `./install.sh`

Status: implemented in `03489c9` (install.sh), `eef7317` (dev-run.sh sweep), `ab7b5ca` (docs).
Written against `8327604`, macOS 26.6 (Darwin 25.6.0), Xcode 26.5,
Info.plist `CFBundleShortVersionString` = `1.2`.

## Owner's ask

A console command that builds the Release configuration without opening Xcode and installs the
result into `/Applications`, replacing the installed `WarpVeil.app`. Local only: build → sign →
replace `/Applications/WarpVeil.app` → relaunch. Tagging, notarization and the GitHub release stay
in `release.sh`.

## Verified facts

Every fact below was checked on this machine in this run.

### Repo

- `release.sh:14-20` config; `:23` version via `PlistBuddy`; `:47-51` binaries check; `:58-65`
  the Release `xcodebuild` (`-derivedDataPath build/derived`, `CONFIGURATION_BUILD_DIR=build`);
  `:75-81` bundled-binaries check; `:83-101` identity detection and the two signing branches
  (Developer ID with `--options runtime --timestamp --entitlements`, else `--sign -`).
- `dev-run.sh:39-41` `dev_is_running` anchored on the binary path; `:44-53` `live_engine_pids`;
  `:55-87` `stop_dev` (AppleScript quit → 3 s wait → `pkill` → sweep by PID file with
  `sudo stop.sh` or `sudo kill`); `:107` `open -n`; `:149-156` "build before stopping".
- `WarpVeil.xcodeproj/project.pbxproj:351,372` `PRODUCT_BUNDLE_IDENTIFIER = com.warpveil.app`;
  `:341,362` `CODE_SIGN_STYLE = Automatic`, no `DEVELOPMENT_TEAM`, no `CODE_SIGN_IDENTITY`;
  `:119-137` "Bundle VPN Binaries" phase, `alwaysOutOfDate = 1`, input `Binaries/{xray,sing-box}`,
  output `Contents/Resources/{xray,sing-box}`. `xcodebuild -list` shows one scheme, `WarpVeil`,
  and configurations `Debug`, `Release`. No `xcshareddata` — the scheme is auto-created.
- `Sources/ProcessManager.swift:24-27` `versionTag` = `CFBundleShortVersionString` with `.` → `-`;
  `:30-37` libexec, `run.sh`, `stop.sh`, sudoers and both PID files all carry the tag;
  `:163-167` `passwordlessInstalled()` compares the installed scripts byte-for-byte;
  `:277` the "scripts are from an older build" log line; `:207-208` only v1.0 leftovers are
  purged; `:46-60` `kill_pid_file` drops a stale PID file itself (dead PID → `rm -f`);
  `:88-89` `run.sh` runs `kill_pid_file` on both files before starting an engine.
- `Sources/WarpVeilApp.swift:88-98` `applicationShouldTerminate`: `.terminateNow` when no VPN
  is running, otherwise `disconnect()` + `awaitTeardown(timeout: 30)` + `.terminateLater`.
  `ProcessManager.swift:578-620`: the passwordless teardown is `sudo stop.sh`; the other one is
  an `osascript … with administrator privileges` password dialog.
- `.gitignore` already has `build/`, `build-dev/` and `*.app`.
- `README.md:37-42` "Build from Source", `:44-54` "Release". `CLAUDE.md:104-111` "Build & Run"
  list, `:113-133` `### dev-run.sh`, `:135` `## Code Style`.

### Machine

- `/Applications` is `drwxrwxr-x root admin`; the user is in `admin`. `/Applications/WarpVeil.app`
  is `lortan29:staff`. `touch` of a file inside the bundle succeeded and was removed — neither
  ownership nor the App Management TCC rule blocks a rewrite. **No sudo is needed to replace
  the bundle.**
- `security find-identity -v -p codesigning` → `0 valid identities found`. The installed app and
  the Release build are both ad-hoc (`Signature=adhoc`, `TeamIdentifier=not set`, no quarantine
  xattr). **Signing is ad-hoc on this machine**; the Developer ID branch stays for parity with
  `release.sh` and is not exercisable here.
- Installed copy: `com.warpveil.app`, version `1.2`, build `3` — the same tag `1-2` the source
  produces today. Not running. What *is* running: an Xcode-launched Debug copy from
  `~/Library/Developer/Xcode/DerivedData/…/Debug/WarpVeil.app` (pid 66137) with the same bundle
  id and tag, and its root `sing-box` (pid 29805) recorded in `/tmp/warpveil-1-2-singbox.pid`
  (`root:wheel 644`). `/etc/sudoers.d/warpveil-1-2` and `/usr/local/libexec/warpveil-1-2/`
  exist; the installed `stop.sh` is the old one (no executable check, no wait), so the current
  source reads passwordless as off — the `:277` state, live.
- `sudo -n true` → password required; the sudoers entry whitelists only the two script paths.
- AppleScript: `running of application "/Applications/WarpVeil.app"` → `false` while
  `running of application id "com.warpveil.app"` → `true`. **A POSIX-path specifier resolves to
  the bundle at that path, not to whichever process carries the id** — so a quit sent by path
  cannot land on the Xcode copy. `dev-run.sh` quits by id; it can, because its id is its own.
- `PlistBuddy -c Print` on a missing plist prints `File Doesn't Exist, Will Create: …` to
  **stdout** and exits 1 — a `$(… || true)` capture would hold that text. Guard with `-f` first.
- `kill -0 <pid>` on a root-owned process from the user's shell exits 1 with "operation not
  permitted" — checked against the live root `sing-box` (pid 29805, `ps` shows it) and against
  `launchd`. `ps -p <pid>` exits 0 for it and 1 for a dead PID. **`dev-run.sh:51` uses
  `kill -0`, so its `live_engine_pids` never reports a root engine and its sweep never runs** —
  the engines are always root. Same bug in the same shape; the fix is one primitive.
- `readlink -f` exists (macOS ≥ 12.3). `shellcheck` is not installed.
- The Release build from `release.sh`'s invocation into a scratch dir: 12.4 s clean, 1.3 s
  incremental, `Contents/Resources/{sing-box,xray,AppIcon.icns}` present, already ad-hoc signed
  by Xcode. `codesign --force --sign -` on the two engines and the app, then `ditto` to another
  dir, then `codesign --verify --deep --strict` → `valid on disk`, `satisfies its Designated
  Requirement`. The bundle is 113 MB. The repo stayed clean.
- `$PATH` contains `/usr/local/bin` (`root:wheel 755`, **not writable**), `/opt/homebrew/bin`
  (writable, Homebrew's), `~/.local/bin` (`lortan29:staff`, 43 entries, **on PATH, writable**),
  `~/bin` (on PATH, **does not exist**). Shell: zsh.

## Answers

1. **Sudo for the replacement: no.** `/Applications` is group-writable by `admin`, the bundle is
   user-owned, and a write inside it went through. The script does `rm -rf` + `ditto` as the user.
   `sudo` appears only in the engine sweep, and only when engines are actually still alive. A
   root-owned bundle (an installer's) would make `rm -rf` fail and `set -e` stop the script with
   `rm`'s own message; that case is not handled and not expected.

2. **Stopping the installed copy — `dev-run.sh`'s `stop_dev`, four differences, each verified
   above:**
   - liveness by `ps -p`, not `kill -0`: the engines are root's, and `kill -0` from the user
     says "not permitted", which the `dev-run.sh` shape reads as "dead" (see the fact above;
     step 2 carries the same one-line fix back into `dev-run.sh`);
   - match and quit by the installed binary path
     (`/Applications/WarpVeil.app/Contents/MacOS/WarpVeil`), and quit through
     `tell application "/Applications/WarpVeil.app"`, not `application id` — the id is shared
     with every Xcode-launched copy;
   - wait up to 35 s, not 3 s, before the `pkill` fallback: the app's own quit path waits up to
     30 s for its teardown (`awaitTeardown(timeout: 30)`), which is a password dialog when
     passwordless is off. `pkill` at 3 s would kill the app under the dialog every time;
   - sweep by the **installed copy's** tag, read from `/Applications/WarpVeil.app/Contents/Info.plist`,
     not the tag being built. The engines belong to the version that started them. On an upgrade
     (`1.2` → `1.3`) the new build's `run.sh` runs `kill_pid_file` on `warpveil-1-3-*.pid` only;
     an engine left under `warpveil-1-2-*.pid` would hold the TUN with nothing left that can
     find it. With the same version the sweep is redundant with `run.sh:88-89` at the next
     connect, but it still turns a ghost tunnel into a clean state.

   What happens if the engines survive: after the quit (or the `pkill` fallback, or a teardown
   that ran past the app's 30 s), `live_engine_pids` reads the two PID files; every live PID is
   killed by `sudo <installed tag>/stop.sh` when that file is executable (NOPASSWD while the
   sudoers entry exists — even a stale `stop.sh` kills by PID), otherwise by `sudo kill <pids>`
   with a terminal password prompt. No `rm -f` of the PID files by the user: they are
   `root:wheel` in sticky `/tmp`, the `rm` in `dev-run.sh:84` is a silent no-op there, and
   `kill_pid_file` removes a stale file itself on the next connect. `stop.sh` removes them too.

   Side effect to know: an Xcode-launched copy of the *same version* shares the installed tag's
   PID files, so its tunnel is swept as well. That is right: only one build can hold the TUN, and
   the copy being installed is the one about to be launched. The Xcode copy's `run.sh` exits with
   its engine and the copy logs `[Disconnected (exit …)]` (`ProcessManager.swift:391`). The
   `dev-run.sh` copy is untouched — its tag is `<version>-dev`.

3. **Signing:** `release.sh:83-101` copied as is — `IDENTITY` from `security find-identity`,
   Developer ID branch with hardened runtime, timestamp, entitlements and `--verify`, else
   ad-hoc for the two engines and the app. No `ditto -c`, no `notarytool`, no `stapler`.
   `--timestamp` needs network, same as in `release.sh`. The engines are signed before the app
   because the app's seal covers them.

4. **Shared helper: no — duplicate.** The overlap with `release.sh` is the version line, the
   binaries check, the `xcodebuild` call, the bundled check and the signing block, ~35 lines.
   That is two uses; the canon's threshold for an abstraction is three, and `dev-run.sh`'s build
   is not a third — different configuration, overridden bundle id and version, forced ad-hoc.
   A `build-lib.sh` with parameters for all three would be the wrapper the rule forbids. If a
   third script ever needs "build Release and sign it", factor it then, with three real callers
   in front of you.

5. **Flags: none.** `./install.sh` and nothing else. Any argument is a usage error, as in
   `dev-run.sh:169-172`. Considered and rejected: `--no-launch` (quit it from the menu),
   `--stop` (that is the app's own quit), `--clean` (`rm -rf build/` by hand is one command).

6. **Docs: yes, both**, exact text under "Documentation" below. README gets one step in
   "Build from Source" and the symlink line; CLAUDE.md gets `install.sh` in the "Build & Run"
   sentence and list, plus a `### install.sh` subsection mirroring `### dev-run.sh`.

7. **Console command:** a symlink into `~/.local/bin`, which exists, is user-owned and is on
   PATH. `/usr/local/bin` needs sudo; `/opt/homebrew/bin` is Homebrew's; a zsh alias works only
   in interactive zsh. Cost: the script resolves its own path with `readlink -f` so the symlink
   lands in the repo — one line, verified available. One-time, by hand, not committed:

   ```bash
   ln -sf "/Users/lortan29/Documents/Home Projects/vpn-swift/install.sh" ~/.local/bin/warpveil-install
   ```

## Design

Order: validate `Binaries/` → build → verify bundled engines → sign → stop the installed copy →
replace → launch. Build before stop, as `dev-run.sh:149-150` puts it: a failed build leaves the
installed copy alone.

Build dir: `build/`, the same one `release.sh` uses, already gitignored. `install.sh` does not
wipe it, so a rebuild is incremental (1.3 s measured); `release.sh` wipes it at both ends, so the
first install after a release is a clean 12 s build. `-quiet` instead of `release.sh`'s
`| tail -3`: `tail` hides compile errors behind the destination warnings, `-quiet` shows only
errors and warnings.

Launch: `open -n`, as `dev-run.sh:107`. The installed path is guaranteed not running by then, so
`-n` is a deterministic "launch this bundle" — plain `open` would consult LaunchServices about the
bundle id, which the Xcode copy may hold.

No Swift changes. No new runtime files. No new `.gitignore` entries.

### `install.sh`

The draft below is the pre-review shape. `install.sh` in the repo is the source of truth —
`/code-review` changed five things in it after implementation, listed under "Review fixes".

```bash
#!/bin/bash
set -euo pipefail
#
# Builds WarpVeil in Release without opening Xcode and installs it into /Applications,
# replacing the copy that is there. Local only — no notarization, no tag, no GitHub
# release; that is release.sh.
#
#   ./install.sh    build → sign → quit the installed copy → replace it → relaunch
#
# Signing follows release.sh: Developer ID Application when the keychain has one, ad-hoc
# otherwise. The installed copy is quit through its own quit path (AppleScript quit →
# applicationShouldTerminate → disconnect), so its root engines come down with it; whatever
# still holds the installed version's PID files afterwards is swept with sudo, the way
# dev-run.sh sweeps the dev copy's engines.

[ $# -eq 0 ] || { echo "usage: $0" >&2; exit 1; }

# readlink -f: the script is meant to be symlinked into PATH.
cd "$(dirname "$(readlink -f "$0")")"

PROJECT="WarpVeil.xcodeproj"
SCHEME="WarpVeil"
APP_NAME="WarpVeil"
BUILD_DIR="$PWD/build"
ENTITLEMENTS="$PWD/WarpVeil.entitlements"
BUILT_APP="$BUILD_DIR/${APP_NAME}.app"
RESOURCES_DIR="$BUILT_APP/Contents/Resources"
INSTALLED_APP="/Applications/${APP_NAME}.app"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/${APP_NAME}"

# The engines belong to the version that started them — the installed copy's, not the one
# being built. After a version bump the new run.sh only looks at its own tag's PID files.
installed_tag() {
    local plist="$INSTALLED_APP/Contents/Info.plist" version
    [ -f "$plist" ] || return 0
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
    echo "${version//./-}"
}

INSTALLED_TAG=$(installed_tag)
STOP_SH="/usr/local/libexec/warpveil-${INSTALLED_TAG}/stop.sh"
PID_FILES=("/tmp/warpveil-${INSTALLED_TAG}-singbox.pid" "/tmp/warpveil-${INSTALLED_TAG}-xray.pid")

# Anchored to the installed binary path, so a dev-run.sh copy and an Xcode-launched copy are
# never quit. The quit goes by path too: the bundle id is shared with every Xcode-launched copy.
installed_is_running() {
    pgrep -f "^${INSTALLED_BIN}$" >/dev/null 2>&1
}

# PIDs from the installed version's PID files that are still alive.
live_engine_pids() {
    local pid
    for f in "${PID_FILES[@]}"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null || true)
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # Not kill -0: the engines are root's, and that says "not permitted" from here.
        ps -p "$pid" >/dev/null 2>&1 && echo "$pid"
    done
}

stop_installed() {
    if installed_is_running; then
        # Quit properly first — that path lets the app tear down its own engines. The app
        # waits up to 30 s for that teardown (a password dialog when passwordless is off),
        # so this wait is longer than that.
        osascript -e "tell application \"$INSTALLED_APP\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 175); do
            installed_is_running || break
            sleep 0.2
        done
        if installed_is_running; then
            pkill -f "^${INSTALLED_BIN}$" 2>/dev/null || true
            sleep 0.5
        fi
        echo "stopped: installed app"
    fi

    # Engines run as root. Their PID files are root-owned too, and a stale one is removed by
    # the next connect's kill_pid_file — nothing to rm here.
    local leftovers
    leftovers=$(live_engine_pids | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$leftovers" ] || return 0

    echo "VPN engines still up (pid: $leftovers) — needs admin"
    if [ -x "$STOP_SH" ]; then
        sudo "$STOP_SH" || true
    else
        sudo kill $leftovers || true
    fi
    echo "stopped: VPN engines"
}

# --- Validate binaries exist (Xcode build phase bundles them) ---
if [ ! -f "$PWD/Binaries/xray" ] || [ ! -f "$PWD/Binaries/sing-box" ]; then
    echo "Binaries not found. Run ./fetch-binaries.sh first"
    exit 1
fi

# --- Build Release ---
echo "Building Release..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    -quiet

if [ ! -d "$BUILT_APP" ]; then
    echo "Build failed"
    exit 1
fi

# --- Verify the Xcode build phase actually bundled the binaries ---
if [ ! -f "$RESOURCES_DIR/xray" ] || [ ! -f "$RESOURCES_DIR/sing-box" ]; then
    echo "Build did not bundle binaries into $RESOURCES_DIR"
    echo "Check the 'Bundle VPN Binaries' build phase."
    exit 1
fi

# --- Code sign ---
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)

if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application identity found — signing ad-hoc."
    codesign --force --sign - "$RESOURCES_DIR/xray" "$RESOURCES_DIR/sing-box"
    codesign --force --sign - "$BUILT_APP"
else
    echo "Signing with identity ${IDENTITY}..."
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" \
        "$RESOURCES_DIR/xray" "$RESOURCES_DIR/sing-box"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" \
        "$BUILT_APP"
    codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
fi

# --- Replace the installed copy ---
stop_installed
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
echo "installed: $INSTALLED_APP"

open -n "$INSTALLED_APP"
```

Notes on the draft, so the implementer does not "fix" them:

- `sudo kill $leftovers` is unquoted on purpose — one argument per PID, as in `dev-run.sh:82`.
- `installed_tag` returning nothing (no installed copy) makes `STOP_SH` and `PID_FILES` point
  at names that cannot exist (`warpveil--…`); the sweep then finds nothing. No special case.
- The `osascript` quit blocks until the app replies to the event, i.e. until `terminateLater`
  is resolved; the loop after it is the safety net, not the wait.
- The signing block and the two checks are `release.sh`'s lines, so a future change to one
  should be made to the other — the same rule the canon states for the two page chromes.

## Documentation

### README.md

In "Build from Source" (after line 40, before the `swift build` note at 42), add step 3:

```
3. Or skip Xcode: `./install.sh` builds Release, signs it (Developer ID when the keychain has one, ad-hoc otherwise), quits the installed copy, replaces `/Applications/WarpVeil.app` and relaunches it. To call it from anywhere: `ln -sf "$PWD/install.sh" ~/.local/bin/warpveil-install`.
```

### CLAUDE.md

Line 106: `Build through Xcode, or through `./dev-run.sh` — never …` →
`Build through Xcode, `./dev-run.sh` or `./install.sh` — never …`.

After list item 3 (line 111), add:

```
4. `./install.sh` to build Release without Xcode and replace `/Applications/WarpVeil.app`.
```

After the `### dev-run.sh` subsection (after line 133, before `## Code Style`), add:

```
### install.sh

Builds Release into `build/` (shared with `release.sh`, which wipes it; otherwise incremental),
signs the way `release.sh` does (Developer ID if present, ad-hoc otherwise, no notarization),
quits the installed copy, replaces `/Applications/WarpVeil.app` and relaunches it. No flags.
`/Applications` is admin-writable, so the replacement itself needs no sudo.

The quit goes to `application "/Applications/WarpVeil.app"` by path, because the bundle id is
shared with any Xcode-launched copy, and waits up to 35 s — the app's own quit path waits 30 s
for its teardown, a password dialog when passwordless is off. Engines still alive afterwards are
swept by the **installed** copy's version tag (read from its `Info.plist`), not the one being
built: after a version bump the new `run.sh` cannot see the old tag's PID files. An
Xcode-launched copy of the same version shares those files and loses its tunnel too. The sweep
is `sudo stop.sh` of that tag when installed, else `sudo kill`. Stale root-owned PID files are
left for `kill_pid_file` at the next connect.

Callable from anywhere via `ln -sf "$PWD/install.sh" ~/.local/bin/warpveil-install`; the script
resolves its own path with `readlink -f`.
```

In `## Gotchas` (line 223; the list starts at 225), add one item:

```
- `kill -0` on a root-owned engine from the user's shell fails with "not permitted", which reads
  as "dead" — the scripts check liveness with `ps -p`
```

## Steps

Each step leaves the repo working; `install.sh` is not wired into anything, so a half-done
script cannot break a build.

1. **`install.sh`** — write the file above at the repo root, `chmod +x`. Check: `bash -n
   install.sh`; `./install.sh` on this machine (expected: 1–12 s build, "No Developer ID …
   signing ad-hoc.", then — because the Xcode copy's `sing-box` holds
   `/tmp/warpveil-1-2-singbox.pid` — "VPN engines still up (pid: …) — needs admin",
   `sudo /usr/local/libexec/warpveil-1-2/stop.sh` without a prompt, "installed: …", the app
   window opens). Then `codesign --verify --deep --strict /Applications/WarpVeil.app`,
   `pgrep -fl MacOS/WarpVeil` shows the `/Applications` path. Quit the Xcode copy first if its
   tunnel matters at that moment.
   Commit: `Add install.sh: build Release and replace the installed app`.
2. **`dev-run.sh:51`** — `kill -0 "$pid" 2>/dev/null && echo "$pid"` →
   `ps -p "$pid" >/dev/null 2>&1 && echo "$pid"`, with the same one-line comment as in
   `install.sh`. Found while planning, reproduced on a live root engine; without it
   `./dev-run.sh --stop` leaves the dev copy's engines up every time.
   Commit: `Sweep root-owned engines in dev-run.sh`.
3. **Docs** — the README and CLAUDE.md edits above.
   Commit: `Document install.sh`.
4. **Close** — `git mv plans/local-install-command.md plans/done/`, set `Status:` to implemented
   with the three hashes, commit `Close the local-install plan`; then `/code-review` and fix what
   it finds.
5. **Owner, once, by hand:** the `ln -sf … ~/.local/bin/warpveil-install` line; then
   `warpveil-install` from any directory.

## Same version vs. upgrade

- **Same `CFBundleShortVersionString` (today: `1.2` over `1.2`).** Tag `1-2` on both sides:
  the same `/etc/sudoers.d/warpveil-1-2`, `/usr/local/libexec/warpveil-1-2/`, PID files and
  `$TMPDIR/warpveil-1-2.log`. `install.sh` touches none of them. Passwordless stays on iff the
  `run.sh`/`stop.sh` the new build would install are byte-identical to the installed ones
  (`passwordlessInstalled()`); if the source changed them, the app logs the `:277` line and the
  toggle re-installs with one prompt — the state this machine is in right now. `@AppStorage`
  and `~/.config/warpveil/subscriptions.json` are untouched.
- **Version bump (`1.2` → `1.3`).** The sweep runs under `1-2` — the only tag that can reach
  engines the `1.2` copy started. The new copy uses `1-3` paths: first connect asks for the
  password once (canon: every bump re-asks), passwordless has to be switched on again.
  `warpveil-1-2` sudoers and libexec are left behind — the app purges only v1.0's, and
  `install.sh` does not clean old tags either. Out of scope; say so if the owner asks.

## Not verified

- The Developer ID branch — no identity on this machine. It is `release.sh`'s text unchanged.
- The `pkill` fallback and the `sudo kill` fallback — there was no hung installed copy and no
  tag without `stop.sh` to exercise them. Same code as `dev-run.sh:73-75,82`.
- `sudo stop.sh` itself — not run: the only live engine is the Xcode copy's tunnel. The
  detection in front of it was: `installed_tag` → `1-2`, `STOP_SH` executable,
  `live_engine_pids` → `29805` with `ps -p` (and nothing with `kill -0`).
- `open -n` against a running same-id Xcode copy — not launched during planning to keep the
  owner's session as it was. `dev-run.sh` launches this way every run.
- The `pkill` and `sudo kill` fallbacks, and the Developer ID branch — see above.

Verified at implementation time: a full `./install.sh` run, 2.5 s on an incremental build —
ad-hoc signing, the sweep of the Xcode copy's `sing-box` (pid 29805) through
`sudo /usr/local/libexec/warpveil-1-2/stop.sh` with no prompt, the replacement of
`/Applications/WarpVeil.app`, and the launch (pid 22821). Afterwards:
`codesign --verify --deep --strict` valid, both engines in `Contents/Resources/`, no engine left
running. The installed copy was not running beforehand, so the quit path was exercised only by
its detection (`installed_is_running` → false).

## Review fixes

`/code-review` over `03489c9^..HEAD` found 13 items. Applied in `19a184f` (install.sh),
`8811c72` (dev-run.sh) and `cb67922` (canon):

- **`live_engine_pids` aborted the script.** A PID file holding a dead PID made the function
  return the failing `ps`, and `leftovers=$(… | …)` under `set -euo pipefail` exited the script
  silently — after the app was quit and before anything was installed. Reproduced in isolation
  (rc=1, the line after the call never ran). The engine test is now a `case`, which exits 0 when
  nothing matches. The same shape was in `dev-run.sh`, with `kill -0`, since before this plan.
- **A PID was signalled without checking whose it is**, against the canon's "nothing else on the
  machine is touched". Now mirrors `kill_pid_file`: `ps -o comm=` must end in `sing-box` or
  `xray`. That is also the liveness test, so `ps -p` is gone.
- **The replacement was not staged.** `rm -rf` before `ditto` meant a full disk or a Ctrl+C left
  `/Applications` with no app. Now `ditto` to `/Applications/.WarpVeil.app.new`, then rename.
- **Nothing waited for the TUN.** `sudo kill` returns before sing-box releases `utun`, and
  `open -n` followed two lines later. Both scripts now poll `live_engine_pids` for up to 5 s.
- **`dev-run.sh` pkilled the dev copy 3 s into a 30 s teardown**, i.e. under the password dialog
  that teardown opens when passwordless is off — the same defect this plan fixed in `install.sh`
  and did not carry back. Its wait is 35 s now, and the sweep's own lines go to stderr, because
  both callers run `stop_dev >/dev/null` and the `sudo` prompt arrived with no explanation.
- **The canon said the quit path waits 0.5 s**; `WarpVeilApp.swift:94` is
  `awaitTeardown(timeout: 30)`. Every script's kill timer is sized against that number.
- `installed_tag` now survives a broken installed `Info.plist`; the unreachable "Build failed"
  message says what it actually checks; `local f`; `dev-run.sh`'s `rm -f` of root-owned PID files
  in sticky `/tmp` is deleted — it never removed anything.

Declined: extracting the sweep into a shared shell helper. Two shell callers, and the canon's
threshold is three — `ProcessManager.killPidFileFunction` is not a third caller of a bash
function. The duplication is now identical in both files, comment for comment.
