#!/bin/bash
set -euo pipefail

# Downloads xray and sing-box binaries for both macOS architectures (arm64 + x86_64),
# merges them into universal binaries via lipo, and ad-hoc signs them.
# Binaries are placed in ./Binaries/ and used by release.sh to bundle into the app.
# release.sh re-signs them with Developer ID later.
#
# Override pinned versions via env:
#   XRAY_TAG=v25.3.6 SB_TAG=v1.12.0 ./fetch-binaries.sh
# Set tag to literal "latest" to query GitHub for the latest release:
#   XRAY_TAG=latest SB_TAG=latest ./fetch-binaries.sh
#
# When updating pinned versions, also update CHECKSUMS below with values
# from the corresponding *.zip.dgst (Xray) or release "digest" field (sing-box).

cd "$(dirname "$0")"

XRAY_TAG="${XRAY_TAG:-v26.3.27}"
SB_TAG="${SB_TAG:-v1.13.8}"

# Expected SHA-256 checksums for pinned tag/arch combos.
# Format: "<tag> <asset-name> <sha256>" — one per line.
# Sources:
#   Xray:     https://github.com/XTLS/Xray-core/releases/download/<tag>/<asset>.dgst
#   sing-box: GitHub release API "digest" field on each asset
read -r -d '' CHECKSUMS <<'EOF' || true
v26.3.27 Xray-macos-arm64-v8a.zip 2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf
v26.3.27 Xray-macos-64.zip f5b0471d3459eff1b82e48af0aeac186abcc3298210070afbbbd8437a4e8b203
v1.13.8 sing-box-1.13.8-darwin-arm64.tar.gz e9e4c72a4a64c19d515b800b7191c50367522c8169654c569677b15873e08249
v1.13.8 sing-box-1.13.8-darwin-amd64.tar.gz 0db6aca503dcdd5a816e668669e79231f991cdbbd13fcbf6dd4f9bcb8a1c3b0e
EOF

BINARIES_DIR="Binaries"

# Look up actual tag name when env override is the literal "latest".
resolve_latest_tag() {
    local repo="$1"
    curl -sL "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"tag_name"' | head -1 \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

# Look up expected sha256 for a given tag + asset name.
expected_sha() {
    local tag="$1"
    local asset="$2"
    echo "$CHECKSUMS" | awk -v t="$tag" -v a="$asset" \
        '$1 == t && $2 == a { print $3; found=1; exit } END { if (!found) exit 1 }'
}

# Download $url to $out, verify sha256 matches expected for ($tag, $asset).
# Sets MISSING_CHECKSUMS=1 (global) if no expected checksum is recorded.
download_and_verify() {
    local url="$1"
    local out="$2"
    local tag="$3"
    local asset="$4"

    echo "  downloading $asset"
    curl -sL "$url" -o "$out"

    local actual
    actual=$(shasum -a 256 "$out" | awk '{print $1}')
    echo "  sha256: $actual"

    local expected
    if expected=$(expected_sha "$tag" "$asset"); then
        if [ "$actual" != "$expected" ]; then
            echo "ERROR: checksum mismatch for $asset ($tag)" >&2
            echo "  expected: $expected" >&2
            echo "  actual:   $actual" >&2
            exit 1
        fi
        echo "  checksum OK"
    else
        echo "  TODO: no expected checksum recorded for $tag $asset — add to CHECKSUMS"
        MISSING_CHECKSUMS=1
    fi
}

if [ "$XRAY_TAG" = "latest" ]; then
    XRAY_TAG=$(resolve_latest_tag XTLS/Xray-core)
    echo "Resolved XRAY_TAG=latest -> $XRAY_TAG"
fi
if [ "$SB_TAG" = "latest" ]; then
    SB_TAG=$(resolve_latest_tag SagerNet/sing-box)
    echo "Resolved SB_TAG=latest -> $SB_TAG"
fi

MISSING_CHECKSUMS=0

# Warn about existing binaries before wiping them.
if [ -f "$BINARIES_DIR/sing-box" ]; then
    echo "WARNING: existing $BINARIES_DIR/sing-box will be overwritten:"
    lipo -info "$BINARIES_DIR/sing-box" 2>/dev/null || file "$BINARIES_DIR/sing-box"
fi
if [ -f "$BINARIES_DIR/xray" ]; then
    echo "WARNING: existing $BINARIES_DIR/xray will be overwritten:"
    lipo -info "$BINARIES_DIR/xray" 2>/dev/null || file "$BINARIES_DIR/xray"
fi

rm -rf "$BINARIES_DIR"
mkdir -p "$BINARIES_DIR"

SB_VERSION="${SB_TAG#v}"

echo ""
echo "=== Fetching xray ${XRAY_TAG} (universal arm64 + x86_64) ==="

XRAY_TMP=$(mktemp -d)
trap 'rm -rf "$XRAY_TMP"' EXIT

XRAY_ARM_ASSET="Xray-macos-arm64-v8a.zip"
XRAY_X86_ASSET="Xray-macos-64.zip"
XRAY_BASE="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}"

mkdir -p "$XRAY_TMP/arm64" "$XRAY_TMP/x86_64"
download_and_verify "$XRAY_BASE/$XRAY_ARM_ASSET" "$XRAY_TMP/arm64.zip" "$XRAY_TAG" "$XRAY_ARM_ASSET"
download_and_verify "$XRAY_BASE/$XRAY_X86_ASSET" "$XRAY_TMP/x86_64.zip" "$XRAY_TAG" "$XRAY_X86_ASSET"

unzip -qo "$XRAY_TMP/arm64.zip" -d "$XRAY_TMP/arm64"
unzip -qo "$XRAY_TMP/x86_64.zip" -d "$XRAY_TMP/x86_64"

lipo -create \
    -output "$BINARIES_DIR/xray" \
    "$XRAY_TMP/arm64/xray" \
    "$XRAY_TMP/x86_64/xray"

XRAY_LIPO=$(lipo -info "$BINARIES_DIR/xray")
echo "  $XRAY_LIPO"
if ! echo "$XRAY_LIPO" | grep -q "arm64" || ! echo "$XRAY_LIPO" | grep -q "x86_64"; then
    echo "ERROR: xray is not a universal binary" >&2
    exit 1
fi

chmod +x "$BINARIES_DIR/xray"
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$BINARIES_DIR/xray"

echo ""
echo "=== Fetching sing-box ${SB_TAG} (universal arm64 + x86_64) ==="

SB_TMP=$(mktemp -d)
trap 'rm -rf "$XRAY_TMP" "$SB_TMP"' EXIT

SB_ARM_ASSET="sing-box-${SB_VERSION}-darwin-arm64.tar.gz"
SB_X86_ASSET="sing-box-${SB_VERSION}-darwin-amd64.tar.gz"
SB_BASE="https://github.com/SagerNet/sing-box/releases/download/${SB_TAG}"

mkdir -p "$SB_TMP/arm64" "$SB_TMP/x86_64"
download_and_verify "$SB_BASE/$SB_ARM_ASSET" "$SB_TMP/arm64.tar.gz" "$SB_TAG" "$SB_ARM_ASSET"
download_and_verify "$SB_BASE/$SB_X86_ASSET" "$SB_TMP/x86_64.tar.gz" "$SB_TAG" "$SB_X86_ASSET"

tar -xzf "$SB_TMP/arm64.tar.gz" -C "$SB_TMP/arm64"
tar -xzf "$SB_TMP/x86_64.tar.gz" -C "$SB_TMP/x86_64"

SB_ARM_BIN=$(ls "$SB_TMP"/arm64/sing-box-*/sing-box | head -1)
SB_X86_BIN=$(ls "$SB_TMP"/x86_64/sing-box-*/sing-box | head -1)

lipo -create \
    -output "$BINARIES_DIR/sing-box" \
    "$SB_ARM_BIN" \
    "$SB_X86_BIN"

SB_LIPO=$(lipo -info "$BINARIES_DIR/sing-box")
echo "  $SB_LIPO"
if ! echo "$SB_LIPO" | grep -q "arm64" || ! echo "$SB_LIPO" | grep -q "x86_64"; then
    echo "ERROR: sing-box is not a universal binary" >&2
    exit 1
fi

chmod +x "$BINARIES_DIR/sing-box"
codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$BINARIES_DIR/sing-box"

echo ""
echo "=== Done ==="
ls -lh "$BINARIES_DIR/"
echo ""
echo "xray:     $("$BINARIES_DIR/xray" version 2>/dev/null | head -1 || echo 'unknown')"
echo "sing-box: $("$BINARIES_DIR/sing-box" version 2>/dev/null | head -1 || echo 'unknown')"

if [ "$MISSING_CHECKSUMS" = "1" ]; then
    echo ""
    echo "TODO: add missing checksums to the CHECKSUMS heredoc near the top of this script."
fi
