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
# Staged next to the target, on the same volume, so the swap is a rename.
STAGED_APP="/Applications/.${APP_NAME}.app.new"

# The engines belong to the version that started them — the installed copy's, not the one
# being built. After a version bump the new run.sh only looks at its own tag's PID files.
installed_tag() {
    local plist="$INSTALLED_APP/Contents/Info.plist" version
    [ -f "$plist" ] || return 0
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null) || return 0
    [ -n "$version" ] || return 0
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
    local f pid
    for f in "${PID_FILES[@]}"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null || true)
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # Mirrors kill_pid_file in ProcessManager: a PID is ours only while its executable is
        # one of our engines — PIDs are recycled, and a crash leaves the file behind. Not
        # kill -0: the engines are root's, and that says "not permitted" from here. case with
        # no match exits 0, so a stale PID cannot trip set -e through the caller's pipeline.
        case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
            *sing-box|*xray) echo "$pid" ;;
        esac
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
        # Unlike stop.sh, a bare kill returns before sing-box has released the TUN.
        sudo kill $leftovers || true
    fi
    for _ in $(seq 1 50); do
        [ -n "$(live_engine_pids)" ] || break
        sleep 0.1
    done
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
    echo "ERROR: no app produced at $BUILT_APP" >&2
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
rm -rf "$STAGED_APP"
ditto "$BUILT_APP" "$STAGED_APP"
rm -rf "$INSTALLED_APP"
mv "$STAGED_APP" "$INSTALLED_APP"
echo "installed: $INSTALLED_APP"

open -n "$INSTALLED_APP"
