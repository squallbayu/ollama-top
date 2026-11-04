# SPDX-License-Identifier: GPL-3.0-or-later
# OllamaTop — Public Builder & Developer Makefile

VERSION ?= 1.0.0
APP_INSTALL_DIR ?= $(HOME)/Applications
BIN_INSTALL_DIR ?= $(HOME)/.local/bin

.PHONY: all build universal package install uninstall test clean

all: build

build:
	@chmod +x scripts/build.sh scripts/install.sh cli/ollama-top
	@./scripts/build.sh --version $(VERSION)

universal:
	@chmod +x scripts/build.sh
	@./scripts/build.sh --universal --version $(VERSION)

package:
	@chmod +x scripts/build.sh
	@./scripts/build.sh --universal --package --version $(VERSION)

install: build
	@mkdir -p "$(APP_INSTALL_DIR)" "$(BIN_INSTALL_DIR)"
	@rm -rf "$(APP_INSTALL_DIR)/OllamaTop.app"
	@cp -R dist/OllamaTop.app "$(APP_INSTALL_DIR)/OllamaTop.app"
	@cp dist/ollama-top "$(BIN_INSTALL_DIR)/ollama-top"
	@chmod +x "$(BIN_INSTALL_DIR)/ollama-top"
	@pkill -x OllamaTop 2>/dev/null || true
	@sleep 0.3
	@open "$(APP_INSTALL_DIR)/OllamaTop.app"
	@echo "Installed & launched $(APP_INSTALL_DIR)/OllamaTop.app and $(BIN_INSTALL_DIR)/ollama-top"

uninstall:
	@pkill -x OllamaTop 2>/dev/null || true
	@rm -rf "$(APP_INSTALL_DIR)/OllamaTop.app"
	@rm -f "$(BIN_INSTALL_DIR)/ollama-top" "$(BIN_INSTALL_DIR)/ollama-bar"
	@rm -f "$(HOME)/Library/LaunchAgents/io.github.squallbayu.ollamatop.plist"
	@echo "Uninstalled OllamaTop."

test: build
	@python3 -m py_compile cli/ollama-top
	@./dist/ollama-top --help >/dev/null
	@./dist/ollama-top --once >/dev/null
	@codesign --verify --deep --strict dist/OllamaTop.app
	@echo "All verification checks passed."

clean:
	@rm -rf dist build
