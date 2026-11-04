#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Public Builder for OllamaTop (macOS Menu Bar App + CLI Monitor)

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
DIST_DIR="$REPO_ROOT/dist"
UNIVERSAL=false
PACKAGE=false
VERSION="1.0.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --package)
            PACKAGE=true
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--universal] [--package] [--version X.Y.Z]"
            exit 1
            ;;
    esac
done

APP_DIR="$DIST_DIR/OllamaTop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TMP_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD"' EXIT

echo "==> Cleaning and preparing $DIST_DIR (v$VERSION)..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Generating macOS squircle AppIcon.icns..."
swift "$REPO_ROOT/menubar/make_icon.swift" "$TMP_BUILD/AppIcon.iconset"
iconutil -c icns "$TMP_BUILD/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"

if [[ "$UNIVERSAL" == "true" ]]; then
    echo "==> Compiling arm64 slice (macOS 13.0+)..."
    swiftc -O -swift-version 5 -parse-as-library \
        -target arm64-apple-macos13.0 \
        -framework AppKit -framework SwiftUI \
        "$REPO_ROOT/menubar/OllamaTop.swift" \
        -o "$TMP_BUILD/OllamaTop-arm64"

    echo "==> Compiling x86_64 slice (macOS 13.0+)..."
    swiftc -O -swift-version 5 -parse-as-library \
        -target x86_64-apple-macos13.0 \
        -framework AppKit -framework SwiftUI \
        "$REPO_ROOT/menubar/OllamaTop.swift" \
        -o "$TMP_BUILD/OllamaTop-x86_64"

    echo "==> Merging Universal Binary via lipo..."
    lipo -create -output "$MACOS_DIR/OllamaTop" \
        "$TMP_BUILD/OllamaTop-arm64" \
        "$TMP_BUILD/OllamaTop-x86_64"
    lipo -info "$MACOS_DIR/OllamaTop"
else
    ARCH="$(uname -m)"
    echo "==> Compiling native $ARCH binary (macOS 13.0+)..."
    swiftc -O -swift-version 5 -parse-as-library \
        -target "${ARCH}-apple-macos13.0" \
        -framework AppKit -framework SwiftUI \
        "$REPO_ROOT/menubar/OllamaTop.swift" \
        -o "$MACOS_DIR/OllamaTop"
fi

sed "s/<string>1.0.0<\/string>/<string>${VERSION}<\/string>/g" \
    "$REPO_ROOT/menubar/Info.plist" > "$CONTENTS_DIR/Info.plist"

echo "==> Ad-hoc code signing $APP_DIR..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

cp "$REPO_ROOT/cli/ollama-top" "$DIST_DIR/ollama-top"
chmod +x "$DIST_DIR/ollama-top"

if [[ "$PACKAGE" == "true" ]]; then
    SUFFIX="macos-$(uname -m)"
    if [[ "$UNIVERSAL" == "true" ]]; then
        SUFFIX="macos-universal"
    fi
    ZIP_NAME="OllamaTop-v${VERSION}-${SUFFIX}.zip"
    TAR_NAME="ollama-top-cli-v${VERSION}.tar.gz"

    echo "==> Packaging release archives into $DIST_DIR..."
    rm -f "$DIST_DIR/$ZIP_NAME" "$DIST_DIR/$TAR_NAME" "$DIST_DIR/SHA256SUMS.txt"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$ZIP_NAME"
    tar -czf "$DIST_DIR/$TAR_NAME" -C "$DIST_DIR" ollama-top

    (
        cd "$DIST_DIR"
        shasum -a 256 "$ZIP_NAME" "$TAR_NAME" "ollama-top" > SHA256SUMS.txt
    )
    echo "==> SHA-256 Checksums:"
    cat "$DIST_DIR/SHA256SUMS.txt"
fi

echo "==> Build complete: $APP_DIR"
