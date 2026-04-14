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
        echo "✅ Нет изменений с последнего релиза ${TAG} — пропуск"
        exit 0
    fi

    echo "📝 Найдены новые изменения — обновляю релиз ${TAG}..."

    # Delete old tag & release
    git tag -d "$TAG" 2>/dev/null || true
    git push origin ":refs/tags/$TAG" 2>/dev/null || true
    gh release delete "$TAG" --yes 2>/dev/null || true
else
    echo "🆕 Первый релиз ${TAG}"
fi

# --- Build Release ---
echo "🔨 Сборка Release..."
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
    echo "❌ Сборка не удалась"
    exit 1
fi

echo "✅ Сборка успешна"

# --- Package ---
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
cd "$SCRIPT_DIR"

echo "📦 ${ZIP_NAME} (${ZIP_SIZE})"

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

[ -z "$CHANGES" ] && CHANGES="- Обновление"

NOTES="## ${APP_NAME} ${VERSION}

### Изменения
${CHANGES}

### Установка
1. Скачать \`${ZIP_NAME}\`
2. Распаковать
3. Перетащить ${APP_NAME}.app в /Applications
4. Запустить — иконка появится в menu bar

> Требуется macOS 14+"

# --- Create tag & release ---
echo "🏷  Тег ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"
git push origin "$TAG"

echo "📤 Загрузка релиза..."
gh release create "$TAG" \
    "$BUILD_DIR/$ZIP_NAME" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)

# --- Cleanup ---
rm -rf "$BUILD_DIR"

echo ""
echo "🎉 ${RELEASE_URL}"
