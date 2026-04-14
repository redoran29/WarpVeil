#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# --- Config ---
PROJECT="WarpVeil.xcodeproj"
SCHEME="WarpVeil"
APP_NAME="WarpVeil"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

# --- Get version from Info.plist ---
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
TAG="v${VERSION}"

echo "=== ${APP_NAME} Release ==="
echo "Version: ${VERSION} (build ${BUILD})"
echo "Tag: ${TAG}"
echo ""

# --- Check for uncommitted changes ---
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "⚠️  Есть незакоммиченные изменения!"
    read -p "Продолжить? (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# --- Check if tag already exists ---
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "⚠️  Тег $TAG уже существует!"
    read -p "Удалить и пересоздать? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git tag -d "$TAG"
        gh release delete "$TAG" --yes 2>/dev/null || true
        git push origin ":refs/tags/$TAG" 2>/dev/null || true
    else
        exit 1
    fi
fi

# --- Clean & build Release ---
echo "🔨 Сборка Release..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    build \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    2>&1 | tail -5

if [ ! -d "$BUILD_DIR/${APP_NAME}.app" ]; then
    echo "❌ Сборка не удалась — .app не найден"
    exit 1
fi

echo "✅ Сборка успешна"

# --- Package ---
echo "📦 Упаковка..."
ZIP_NAME="${APP_NAME}-${VERSION}-macOS.zip"
cd "$BUILD_DIR"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
cd ..

echo "✅ ${ZIP_NAME} (${ZIP_SIZE})"

# --- Generate release notes from git log ---
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    CHANGES=$(git log "${LAST_TAG}..HEAD" --pretty=format:"- %s" --no-merges 2>/dev/null || echo "- Initial release")
else
    CHANGES=$(git log --pretty=format:"- %s" --no-merges -20 2>/dev/null || echo "- Initial release")
fi

NOTES="## WarpVeil ${VERSION}

### Изменения
${CHANGES}

### Установка
1. Скачать \`${ZIP_NAME}\`
2. Распаковать
3. Перетащить WarpVeil.app в /Applications
4. Запустить — иконка появится в menu bar

> Требуется macOS 14+"

echo ""
echo "--- Release Notes ---"
echo "$NOTES"
echo "---------------------"
echo ""

# --- Confirm ---
read -p "🚀 Создать релиз ${TAG} на GitHub? (y/n) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }

# --- Create tag & release ---
echo "🏷  Создание тега ${TAG}..."
git tag -a "$TAG" -m "Release ${VERSION}"
git push origin "$TAG"

echo "📤 Загрузка релиза..."
gh release create "$TAG" \
    "$BUILD_DIR/$ZIP_NAME" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo ""
echo "🎉 Релиз создан: ${RELEASE_URL}"

# --- Cleanup ---
rm -rf "$BUILD_DIR"
echo "🧹 Очищено"
