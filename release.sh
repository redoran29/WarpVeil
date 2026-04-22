#!/bin/bash
set -euo pipefail
#
# Builds, signs, notarizes, and publishes a WarpVeil release.
#
# Notarization setup (one-time):
#   xcrun notarytool store-credentials NOTARY_PROFILE \
#       --apple-id <id> --team-id <team> --password <app-specific-password>
# Then export NOTARY_PROFILE=NOTARY_PROFILE before running this script.
# Without a Developer ID identity in the keychain, builds are signed ad-hoc
# and notarization is skipped (good enough for local dev).

cd "$(dirname "$0")"

# --- Config ---
PROJECT="WarpVeil.xcodeproj"
SCHEME="WarpVeil"
APP_NAME="WarpVeil"
SCRIPT_DIR="$(pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ENTITLEMENTS="${SCRIPT_DIR}/WarpVeil.entitlements"

# --- Get version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v${VERSION}"

echo "=== ${APP_NAME} Release ==="
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo ""

# --- Skip if nothing changed since last tag ---
TAG_EXISTS=0
if git rev-parse "$TAG" >/dev/null 2>&1; then
    TAG_EXISTS=1
    TAG_COMMIT=$(git rev-list -n 1 "$TAG")
    HEAD_COMMIT=$(git rev-parse HEAD)

    if [ "$TAG_COMMIT" = "$HEAD_COMMIT" ] && git diff --quiet HEAD 2>/dev/null; then
        echo "No changes since ${TAG} — skipping"
        exit 0
    fi
    echo "New changes found — will replace release ${TAG} after a successful build."
else
    echo "First release ${TAG}"
fi

# --- Validate binaries exist (Xcode build phase bundles them) ---
if [ ! -f "${SCRIPT_DIR}/Binaries/xray" ] || [ ! -f "${SCRIPT_DIR}/Binaries/sing-box" ]; then
    echo "Binaries not found. Run ./fetch-binaries.sh first"
    exit 1
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

if [ ! -d "$BUILD_DIR/${APP_NAME}.app" ]; then
    echo "Build failed"
    exit 1
fi

echo "Build succeeded"

# --- Verify the Xcode build phase actually bundled the binaries ---
RESOURCES_DIR="$BUILD_DIR/${APP_NAME}.app/Contents/Resources"
if [ ! -f "$RESOURCES_DIR/xray" ] || [ ! -f "$RESOURCES_DIR/sing-box" ]; then
    echo "Build did not bundle binaries into $RESOURCES_DIR"
    echo "Check the 'Bundle VPN Binaries' build phase."
    exit 1
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
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"
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

# --- Release notes from git log ---
LAST_TAGS=$(git tag --sort=-version:refname | head -5)
PREV_TAG=""
for t in $LAST_TAGS; do
    if [ "$t" != "$TAG" ]; then
        PREV_TAG="$t"
        break
    fi
done

if [ -n "$PREV_TAG" ]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" --no-merges 2>/dev/null)
else
    CHANGES=$(git log --pretty=format:"- %s" --no-merges -20 2>/dev/null)
fi

[ -z "$CHANGES" ] && CHANGES="- Update"

NOTES="## ${APP_NAME} ${VERSION}

### Changes
${CHANGES}

### Install
1. Download \`${ZIP_NAME}\`
2. Unzip
3. Drag ${APP_NAME}.app to /Applications
4. Launch — the icon appears in the menu bar

> Requires macOS 14+"

# --- Replace existing tag/release only after a successful build ---
if [ "$TAG_EXISTS" = "1" ]; then
    echo "Removing previous tag/release ${TAG}..."
    git tag -d "$TAG" 2>/dev/null || true
    git push origin ":refs/tags/$TAG" 2>/dev/null || true
    gh release delete "$TAG" --yes 2>/dev/null || true
fi

echo "Creating tag ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"
git push origin "$TAG"

echo "Uploading release..."
gh release create "$TAG" \
    "$BUILD_DIR/$ZIP_NAME" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)

# --- Cleanup ---
rm -rf "$BUILD_DIR"

echo ""
echo "Done: ${RELEASE_URL}"
