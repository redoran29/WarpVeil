#!/bin/bash
set -euo pipefail

# Builds, launches and stops a dev copy of WarpVeil that runs next to an already
# installed or Xcode-launched build without colliding with it.
#
#   ./dev-run.sh          build, then (re)launch the dev copy
#   ./dev-run.sh --watch  same, then rebuild and relaunch on every source change
#                         until Ctrl+C, which also stops the dev copy
#   ./dev-run.sh --stop   stop the dev copy and its VPN engines
#
# Isolation comes from two overrides:
#   - bundle id  -> separate UserDefaults domain (@AppStorage settings)
#   - version    -> ProcessManager derives its sudoers, libexec, PID and log
#                   paths from CFBundleShortVersionString, so "1.2-dev" keeps
#                   them apart from the production "1.2"
#
# Not isolated: ~/.config/warpveil/subscriptions.json (shared on purpose, same
# servers) and the TUN interface — only one build can hold a tunnel at a time.

cd "$(dirname "$0")"

APP_NAME="WarpVeil"
DEV_BUNDLE_ID="com.warpveil.app.dev"
DEV_SUFFIX="dev"
BUILD_DIR="$PWD/build-dev"
APP="$BUILD_DIR/${APP_NAME}.app"
APP_BIN="$APP/Contents/MacOS/${APP_NAME}"

BASE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DEV_VERSION="${BASE_VERSION}-${DEV_SUFFIX}"
DEV_TAG="${DEV_VERSION//./-}"

DEV_STOP_SH="/usr/local/libexec/warpveil-${DEV_TAG}/stop.sh"
DEV_PID_FILES=("/tmp/warpveil-${DEV_TAG}-singbox.pid" "/tmp/warpveil-${DEV_TAG}-xray.pid")

# Every match is anchored to the dev binary path, so the production build and
# any Xcode-launched copy are never touched.
dev_is_running() {
    pgrep -f "^${APP_BIN}$" >/dev/null 2>&1
}

# PIDs from the dev PID files that are still alive.
live_engine_pids() {
    local pid
    for f in "${DEV_PID_FILES[@]}"; do
        [ -f "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null || true)
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # Not kill -0: the engines are root's, and that says "not permitted" from here.
        ps -p "$pid" >/dev/null 2>&1 && echo "$pid"
    done
}

stop_dev() {
    if dev_is_running; then
        # Quit properly first — that path lets the app tear down its own engines.
        osascript -e "tell application id \"$DEV_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 15); do
            dev_is_running || break
            sleep 0.2
        done
        if dev_is_running; then
            pkill -f "^${APP_BIN}$" 2>/dev/null || true
            sleep 0.5
        fi
        echo "stopped: dev app"
    else
        echo "dev app was not running"
    fi

    # The app does not wait for its teardown to finish before exiting, so sweep
    # anything still holding the dev PID files. Engines run as root.
    local leftovers
    leftovers=$(live_engine_pids | tr '\n' ' ' | sed 's/ *$//')
    [ -n "$leftovers" ] || return 0

    echo "dev VPN engines still up (pid: $leftovers) — needs admin"
    if [ -x "$DEV_STOP_SH" ]; then
        sudo "$DEV_STOP_SH" || true
    else
        sudo kill $leftovers || true
    fi
    rm -f "${DEV_PID_FILES[@]}" 2>/dev/null || true
    echo "stopped: dev VPN engines"
}

build_dev() {
    xcodebuild -project "${APP_NAME}.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR/derived" \
        CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
        PRODUCT_BUNDLE_IDENTIFIER="$DEV_BUNDLE_ID" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        -quiet \
        build

    [ -d "$APP" ] || { echo "ERROR: no app produced at $APP" >&2; return 1; }

    local plist="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${DEV_VERSION}" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME} Dev" "$plist"

    # Re-sign after touching Info.plist, otherwise the signature no longer matches.
    codesign --force --sign - "$APP"
}

launch_dev() {
    open -n "$APP"
}

print_paths() {
    echo ""
    echo "bundle id: $DEV_BUNDLE_ID"
    echo "version:   $DEV_VERSION"
    echo "sudoers:   /etc/sudoers.d/warpveil-${DEV_TAG}"
    echo "log:       ${TMPDIR}warpveil-${DEV_TAG}.log"
    echo "app:       $APP"
    echo ""
}

# Fingerprint of everything that should trigger a rebuild.
watch_signature() {
    find Sources Info.plist WarpVeil.entitlements "${APP_NAME}.xcodeproj/project.pbxproj" \
        -type f -not -name '.DS_Store' -exec stat -f '%m %N' {} + 2>/dev/null | sort | shasum -a 256
}

watch_loop() {
    local prev cur next
    prev=$(watch_signature)
    echo "watching Sources/, Info.plist and the project file — Ctrl+C stops the dev copy"
    while true; do
        sleep 1
        cur=$(watch_signature)
        [ "$cur" = "$prev" ] && continue

        # Let a burst of saves settle before spending a build on it.
        while true; do
            sleep 0.4
            next=$(watch_signature)
            [ "$next" = "$cur" ] && break
            cur=$next
        done
        prev=$cur

        echo ""
        echo "--- change detected, rebuilding ---"
        # Build before stopping: a failed build leaves the running copy alone.
        if build_dev; then
            stop_dev >/dev/null
            launch_dev
            echo "--- relaunched ---"
        else
            echo "--- build failed, previous copy left running ---"
        fi
    done
}

case "${1:-}" in
    --stop)
        stop_dev
        exit 0
        ;;
    --watch)
        stop_dev >/dev/null
        build_dev
        print_paths
        launch_dev
        # Only armed in watch mode — plain runs must leave the app alive on exit.
        trap 'echo ""; echo "--- stopping dev copy ---"; stop_dev; exit 0' INT TERM
        watch_loop
        ;;
    "")
        stop_dev >/dev/null
        build_dev
        print_paths
        launch_dev
        ;;
    *)
        echo "usage: $0 [--watch | --stop]" >&2
        exit 1
        ;;
esac
