#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Public Zero-Sudo Installer for OllamaTop (Menu Bar Widget + CLI)
# Usage: curl -fsSL https://raw.githubusercontent.com/squallbayu/ollama-top/main/scripts/install.sh | zsh

set -euo pipefail

REPO="squallbayu/ollama-top"
INSTALL_APP_DIR="${OLLAMA_TOP_APP_DIR:-$HOME/Applications}"
INSTALL_BIN_DIR="${OLLAMA_TOP_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_APP_DIR" "$INSTALL_BIN_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "======================================================"
echo "  Installing OllamaTop (Menu Bar Widget + CLI)"
echo "  Target App: $INSTALL_APP_DIR/OllamaTop.app"
echo "  Target CLI: $INSTALL_BIN_DIR/ollama-top"
echo "======================================================"

INSTALLED_FROM_RELEASE=false

# 1. Attempt fast prebuilt download from GitHub Releases
if RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)"; then
    ZIP_URL="$(echo "$RELEASE_JSON" | grep -Eo 'https://[^"]+OllamaTop-[^"]+\.zip' | head -n 1 || true)"
    if [[ -n "$ZIP_URL" ]]; then
        echo "==> Downloading prebuilt universal release: $ZIP_URL"
        curl -fsSL "$ZIP_URL" -o "$TMP_DIR/OllamaTop.zip"
        ditto -x -k "$TMP_DIR/OllamaTop.zip" "$TMP_DIR/extracted"
        rm -rf "$INSTALL_APP_DIR/OllamaTop.app"
        mv "$TMP_DIR/extracted/OllamaTop.app" "$INSTALL_APP_DIR/OllamaTop.app"
        xattr -cr "$INSTALL_APP_DIR/OllamaTop.app" 2>/dev/null || true

        curl -fsSL "https://raw.githubusercontent.com/$REPO/main/cli/ollama-top" -o "$INSTALL_BIN_DIR/ollama-top"
        chmod +x "$INSTALL_BIN_DIR/ollama-top"
        INSTALLED_FROM_RELEASE=true
    fi
fi

# 2. Fallback: Build natively from source via Swift compiler
if [[ "$INSTALLED_FROM_RELEASE" == "false" ]]; then
    echo "==> Building natively from source..."
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "Error: Xcode Command Line Tools (swiftc) are required to build from source."
        echo "Run: xcode-select --install"
        exit 1
    fi
    git clone --depth 1 "https://github.com/$REPO.git" "$TMP_DIR/repo"
    "$TMP_DIR/repo/scripts/build.sh"
    rm -rf "$INSTALL_APP_DIR/OllamaTop.app"
    cp -R "$TMP_DIR/repo/dist/OllamaTop.app" "$INSTALL_APP_DIR/OllamaTop.app"
    cp "$TMP_DIR/repo/dist/ollama-top" "$INSTALL_BIN_DIR/ollama-top"
    chmod +x "$INSTALL_BIN_DIR/ollama-top"
fi

# 3. Install ollama-bar helper CLI
cat << EOF > "$INSTALL_BIN_DIR/ollama-bar"
#!/bin/zsh
APP_PATH="$INSTALL_APP_DIR/OllamaTop.app"
CMD="\${1:-start}"

case "\$CMD" in
    start)
        if pgrep -x "OllamaTop" >/dev/null; then
            echo "OllamaTop menu bar widget is already running."
        else
            open "\$APP_PATH"
            echo "Launched OllamaTop in your macOS menu bar."
        fi
        ;;
    stop)
        pkill -x "OllamaTop" 2>/dev/null && echo "Stopped OllamaTop menu bar widget." || echo "OllamaTop was not running."
        ;;
    restart)
        pkill -x "OllamaTop" 2>/dev/null || true
        sleep 0.4
        open "\$APP_PATH"
        echo "Restarted OllamaTop menu bar widget."
        ;;
    status)
        if pgrep -x "OllamaTop" >/dev/null; then
            echo "OllamaTop is RUNNING (PID: \$(pgrep -x OllamaTop | tr '\n' ' '))."
        else
            echo "OllamaTop is STOPPED."
        fi
        ;;
    *)
        echo "Usage: ollama-bar [start|stop|restart|status]"
        exit 1
        ;;
esac
EOF
chmod +x "$INSTALL_BIN_DIR/ollama-bar"

echo "==> Launching OllamaTop Menu Bar Widget..."
pkill -x "OllamaTop" 2>/dev/null || true
sleep 0.3
open "$INSTALL_APP_DIR/OllamaTop.app"

echo ""
echo "Installation complete!"
echo "  • Menu Bar App: $INSTALL_APP_DIR/OllamaTop.app (Running now in top bar)"
echo "  • Terminal TUI: ollama-top"
echo "  • Bar Control:  ollama-bar [start|stop|restart|status]"
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
    echo "  Note: Add 'export PATH=\"$INSTALL_BIN_DIR:\$PATH\"' to your ~/.zshrc"
fi
