#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# --- Config ---
PROJECT="WarpVeil.xcodeproj"
SCHEME="WarpVeil"
APP_NAME="WarpVeil"
SCRIPT_DIR="$(pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

# --- Get version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v${VERSION}"

echo "=== ${APP_NAME} Release ==="
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo ""

# --- Check: are there new commits since this tag? ---
if git rev-parse "$TAG" >/dev/null 2>&1; then
    TAG_COMMIT=$(git rev-list -n 1 "$TAG")
    HEAD_COMMIT=$(git rev-parse HEAD)

    if [ "$TAG_COMMIT" = "$HEAD_COMMIT" ] && git diff --quiet HEAD 2>/dev/null; then
        echo "No changes since ${TAG} — skipping"
        exit 0
    fi

    echo "New changes found — updating release ${TAG}..."

    # Delete old tag & release
    git tag -d "$TAG" 2>/dev/null || true
    git push origin ":refs/tags/$TAG" 2>/dev/null || true
    gh release delete "$TAG" --yes 2>/dev/null || true
else
    echo "First release ${TAG}"
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

# --- Package ---
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
cd "$SCRIPT_DIR"

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

# --- Create tag & release ---
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
