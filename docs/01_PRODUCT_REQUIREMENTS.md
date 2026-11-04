# 1. Product Requirements Document (PRD)

> **Spec-Driven Development Doc #1 — Product Requirements (Feature by Feature)**
> Defines what `ollama-top` (`OllamaTop`) is, who it serves, every feature in scope across the macOS Menu Bar Widget and Terminal TUI, and explicit boundaries of what is out of scope.

---

## 🎯 1. Product Vision & Mission

**OllamaTop** (`ollama-top`) is a lightweight, zero-root, open-source (**GNU GPLv3**) monitoring and VRAM management suite built specifically for **macOS & Apple Silicon Unified Memory** users running local Large Language Models via [Ollama](https://ollama.com).

### Core Objectives
1. **Zero-Glance Menu Bar Visibility**: Show local LLM engineers whether GPU/Unified Memory is currently consumed (e.g., `🧠 R1 8.5G`, `🧠 Qwen32k 10.3G`) or cleanly idle (`Idle` — `0.00 GB`) right in the macOS top menu bar without switching windows.
2. **Instant VRAM Reclamation**: Empower developers on 16 GB, 24 GB, 36 GB, or 64 GB Unified Memory Macs to evict resident GGUF models from Metal GPU RAM in a single click (`Unload VRAM`) or single keystroke (`[u]`), without waiting for Ollama's default 5-minute `keep_alive` timeout.
3. **Zero-Overhead Native Telemetry (`0.0%` CPU)**: Query Apple Silicon Unified Memory, memory pressure (`Normal` / `Warning` / `Critical`), and GPU core topology directly via Darwin Mach kernel APIs (`host_statistics64`, `sysctlbyname`, `ioreg`) rather than heavy background polling scripts.
4. **Dual-Surface Workflow**: Provide both a **Control Center-style macOS Menu Bar Widget** (`OllamaTop.app`) for everyday GUI use and a **Zero-Dependency Terminal TUI** (`ollama-top`) for SSH sessions, tmux panes, and headless benchmarking.
5. **100% User-Space & Zero Root (`sudo`-Free)**: Operate strictly in user space (`~/Applications/OllamaTop.app` and `~/.local/bin/ollama-top`) with zero kernel extensions, zero privileged helper daemons, and zero cloud telemetry.

---

## 👥 2. Target User Personas

| Persona | Hardware Profile | Core Pain Point Solved |
| :--- | :--- | :--- |
| **Local AI Software Engineer** | MacBook Pro (M1–M5 Pro/Max, 16–36 GB RAM) | Runs IDEs, browsers, Docker, and local coding/reasoning LLMs (`qwen2.5-coder`, `deepseek-r1`). Needs instant awareness when a 9–20 GB model is holding Unified Memory and causing macOS swap pressure. |
| **Multi-Model Agent Builder** | Mac Studio / Mac mini / MacBook Air | Swaps between coding models, embedding models, and reasoning models via MCP or OpenAI-compatible endpoints (`/v1/chat/completions`) and wants real-time token/sec (`tok/s`) and auto-sleep countdown visibility. |
| **SSH / Terminal Power User** | Headless Mac mini LLM Server | Connects remotely via SSH/tmux and needs an `htop`/`nvtop`-equivalent terminal dashboard (`ollama-top`) tailored to Apple Silicon Unified Memory. |

---

## ✨ 3. Feature Matrix (In Scope)

### Surface A: Native macOS Menu Bar Widget (`OllamaTop.app`)
- **F-MB-01 — Live Menu Bar Status Pill**: Displays semantic SF Symbol icon + monospaced compact label (`Off`, `Idle`, or `<ShortModel> <VRAM>G` such as `Qwen 8.5G` / `R1 8.5G`).
- **F-MB-02 — Multi-Monitor Pinned Frosted Glass Panel**: Control Center-style `NSVisualEffectView` dropdown locked strictly `6pt` below the clicked display's menu bar (supports Notch MacBooks and external monitors without upward Cocoa coordinate drift).
- **F-MB-03 — Active GPU / VRAM Hero Card**: Displays active model identifier, exact Metal VRAM GiB allocation, proportional progress bar, live 1-second `keep_alive` auto-sleep countdown, and one-click **Unload VRAM** action (`keep_alive: 0`).
- **F-MB-04 — Unified Memory & Hardware Card**: Displays used vs. total Unified Memory, free RAM buffer, macOS kernel VM pressure badge (`Normal` / `Warning` / `Critical`), SoC brand, CPU P/E core topology, Metal GPU core count, NVMe free storage, and macOS version.
- **F-MB-05 — Live Inference Telemetry**: Parses the tail (`64 KB`) of the active Ollama server log to report recent evaluation speed (`tok/s`), prompt ingestion speed (`tok/s`), and last non-polling HTTP API call status/latency.
- **F-MB-06 — Installed Model Inventory & Warm Loader**: Lists all locally installed GGUF models from `/api/tags`, estimates active VRAM footprint (accounting for 4K vs. 32K KV cache), and provides one-click **Load** (warm-up into VRAM) and **Unload** controls.
- **F-MB-07 — Multi-Mode Daemon Lifecycle Control**: Starts or stops Ollama across custom user `LaunchAgent`, Homebrew `brew services` plist, official `/Applications/Ollama.app`, or standalone `ollama serve` binary.
- **F-MB-08 — User-Space Launch at Login**: Self-manages `~/Library/LaunchAgents/io.github.squallbayu.ollamatop.plist` via a single footer checkbox.

### Surface B: Terminal TUI Dashboard (`ollama-top`)
- **F-CLI-01 — Interactive Live Loop**: Full ANSI terminal dashboard refreshing every `1.5s` (configurable via `-i / --interval`).
- **F-CLI-02 — Single-Shot Snapshot Mode**: `ollama-top --once` prints a clean snapshot to stdout for scripts, CI logs, or AI agent tool calls.
- **F-CLI-03 — Single-Key Interactive Controls**: `[u]` unloads all active VRAM models immediately, `[r]` forces refresh, `[q]` / `Ctrl-C` restores terminal TTY cursor state cleanly.

### Surface C: Public Builder & Installer
- **F-BLD-01 — Universal macOS Binary Builder (`scripts/build.sh`)**: Compiles both `arm64` and `x86_64` slices targeting `macOS 13.0+`, merges via `lipo`, generates a custom `.icns` squircle icon, ad-hoc signs the `.app` bundle, and packages verifiable `.zip` + `.tar.gz` + `SHA256SUMS.txt` archives.
- **F-BLD-02 — Zero-Sudo One-Line Installer (`scripts/install.sh`)**: Installs prebuilt GitHub Release binaries (with automatic source-build fallback) into `~/Applications` and `~/.local/bin`.
- **F-BLD-03 — GitHub Actions Release Pipeline**: Automated CI verification and tag-driven GitHub Releases publishing.

---

## 🚫 4. Explicit Non-Goals (Out of Scope)

1. **No Root / `sudo` Power Metrics (`powermetrics`)**: Reading GPU wattage (`mW`) on macOS requires root `sudo powermetrics`. `OllamaTop` strictly refuses to request root privileges; all telemetry runs 100% unprivileged.
2. **No Chat UI or Prompt Playground**: `OllamaTop` is a dedicated systems monitor and VRAM controller, not a chat client.
3. **No Outbound Telemetry or Network Calls**: The app communicates exclusively with the configured `OLLAMA_HOST` (default `http://127.0.0.1:11434`). Zero analytics or external network requests are ever made.
