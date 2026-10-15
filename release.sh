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
# The zip is signed with the release key (CLAUDE.md, "release.sh") and the signature is
# uploaded next to it: an installed app updates itself only from a release whose signature its
# WVUpdatePublicKey accepts. The notes come from CHANGELOG.md's "## <version>" section. A tag
# names exactly what was built, once, so everything that would make a release wrong is refused
# before anything is built.

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

# The key file is the base64 32-byte ed25519 seed. LibreSSL's openssl has no ed25519, so both
# helpers are Swift scripts on CryptoKit.
public_key_of() {
    swift - "$1" <<'EOF'
import CryptoKit
import Foundation
let text = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? ""
guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
}

# Prints the base64 signature of $1's bytes.
sign_zip() {
    swift - "$SIGNING_KEY" "$1" <<'EOF'
import CryptoKit
import Foundation
let args = CommandLine.arguments
let seed = Data(base64Encoded: try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)).base64EncodedString())
EOF
}

# --- Refuse what cannot be released ---
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes — commit them first"
git fetch --quiet --tags origin
! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || fail "tag ${TAG} already exists — bump CFBundleShortVersionString in Info.plist"
# "release not found" is the only answer that means there is none; any other failure is unknown.
if RELEASE_CHECK=$(gh release view "$TAG" 2>&1 >/dev/null); then
    fail "release ${TAG} already exists on GitHub"
elif [ "$RELEASE_CHECK" != "release not found" ]; then
    fail "cannot ask GitHub about release ${TAG}: ${RELEASE_CHECK}"
fi
LATEST=$(git tag --list 'v*' --sort=-version:refname | head -1)
if [ -n "$LATEST" ] && [ "$(printf '%s\n%s\n' "$LATEST" "$TAG" | sort -V | tail -1)" != "$TAG" ]; then
    fail "${VERSION} is not newer than the latest tag ${LATEST} — bump CFBundleShortVersionString in Info.plist"
fi

CHANGES=$(awk -v heading="## ${VERSION}" '$0 == heading { p = 1; next } /^## / { p = 0 } p' CHANGELOG.md 2>/dev/null || true)
[ -n "$(printf '%s' "$CHANGES" | tr -d '[:space:]')" ] || fail "CHANGELOG.md has no \"## ${VERSION}\" section"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :WVUpdatePublicKey" Info.plist 2>/dev/null || true)
[ -n "$PUBLIC_KEY" ] || fail "Info.plist has no WVUpdatePublicKey"
[ -f "$SIGNING_KEY" ] || fail "no release signing key at ${SIGNING_KEY} (CLAUDE.md, \"release.sh\")"
# A release signed with another key would be refused by every installed app.
[ "$(public_key_of "$SIGNING_KEY" || true)" = "$PUBLIC_KEY" ] \
    || fail "${SIGNING_KEY} is not the pair of WVUpdatePublicKey in Info.plist"

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
2. The first launch is blocked with a dialog saying Apple could not verify the app — it is not notarized. Click **Done**, open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the ${APP_NAME} line and enter your password. The button stays for about an hour after the blocked launch; Control-click → Open does not work.
3. Later releases install themselves: **Advanced → Updates** in the window, or **Update to …** in the menu-bar menu.

Or from Terminal, with no dialog — a \`curl\` download carries no quarantine. Quit ${APP_NAME} first if an older version runs; the command replaces it only once the download succeeded:

    curl -fL -o /tmp/${ZIP_NAME} ${REPO_URL}/releases/download/${TAG}/${ZIP_NAME} && rm -rf /Applications/${APP_NAME}.app && ditto -x -k /tmp/${ZIP_NAME} /Applications && open /Applications/${APP_NAME}.app

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
