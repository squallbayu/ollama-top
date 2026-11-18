#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Public Builder for OllamaTop (macOS Menu Bar App + CLI Monitor)

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
DIST_DIR="$REPO_ROOT/dist"
UNIVERSAL=false
PACKAGE=false
VERSION="1.2.0"

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
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX27.2.sdk"
if [[ ! -d "$SDK_PATH" ]]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
fi

/Library/Developer/CommandLineTools/usr/bin/swift -sdk "$SDK_PATH" "$REPO_ROOT/menubar/make_icon.swift" "$TMP_BUILD/AppIcon.iconset"
iconutil -c icns "$TMP_BUILD/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"

ARCH="$(uname -m)"
echo "==> Compiling native $ARCH binary for Apple Silicon (macOS 13.0+)..."
/Library/Developer/CommandLineTools/usr/bin/swiftc -O -parse-as-library \
    -sdk "$SDK_PATH" \
    -framework AppKit -framework SwiftUI \
    "$REPO_ROOT/menubar/OllamaTop.swift" \
    -o "$MACOS_DIR/OllamaTop"

sed "s/<string>1.0.0<\/string>/<string>${VERSION}<\/string>/g" \
    "$REPO_ROOT/menubar/Info.plist" > "$CONTENTS_DIR/Info.plist"

echo "==> Ad-hoc code signing $APP_DIR..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

cp "$REPO_ROOT/cli/ollama-top" "$DIST_DIR/ollama-top"
chmod +x "$DIST_DIR/ollama-top"

if [[ "$PACKAGE" == "true" ]]; then
    SUFFIX="macos-$(uname -m)"
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
