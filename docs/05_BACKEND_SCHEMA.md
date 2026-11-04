# 5. Telemetry, API & Kernel Data Schema

> **Spec-Driven Development Doc #5 — Backend & Telemetry Schema**
> Defines every external HTTP payload, Darwin Mach kernel struct, LaunchAgent property list, and log regex contract consumed or written by `OllamaTop`.

---

## 🔌 1. Ollama Local HTTP REST Contracts

Default base URL: `http://127.0.0.1:11434` (overridable via `OLLAMA_HOST` environment variable).

### 1.1 `GET /api/version` — Engine Health & Version
```json
{
  "version": "0.40.13"
}
```
- **Timeout**: `1.8s` (Menu Bar) / `1.5s` (CLI). Non-200 or connection refusal transitions engine state to `Stopped`.

### 1.2 `GET /api/ps` — Active VRAM Residency
```json
{
  "models": [
    {
      "name": "deepseek-r1:14b",
      "size": 9103181085,
      "size_vram": 9103181085,
      "expires_at": "2026-11-04T14:45:05.408789+07:00",
      "context_length": 4096,
      "details": {
        "parameter_size": "14.8B",
        "quantization_level": "Q4_K_M"
      }
    }
  ]
}
```
- **Schema Notes**: `expires_at` may contain 3, 6, or 9 fractional second digits or `Z` / numeric timezone offsets; parsers strip `\.\d+` fractional sub-seconds prior to ISO-8601 parsing.

### 1.3 `GET /api/tags` — On-Disk GGUF Model Catalog
```json
{
  "models": [
    {
      "name": "qwen2.5-coder-32k:latest",
      "size": 8988123975,
      "details": {
        "parameter_size": "14.8B",
        "quantization_level": "Q4_K_M",
        "context_length": 32768
      }
    }
  ]
}
```

### 1.4 `POST /api/generate` — VRAM Control Mutation
- **Immediate VRAM Eviction (`Unload`)**:
  ```json
  { "model": "qwen2.5-coder:14b", "keep_alive": 0 }
  ```
- **On-Demand Warm Preload (`Load`)**:
  ```json
  { "model": "qwen2.5-coder:14b", "prompt": "", "keep_alive": "5m" }
  ```

---

## 🧠 2. Darwin Kernel & IOKit Schemas

| Source Interface | Key / Struct | Data Type | Interpretation |
| :--- | :--- | :--- | :--- |
| `sysctlbyname` | `hw.memsize` | `UInt64` | Total physical Unified Memory in bytes (e.g., `25769803776` = `24.0 GiB`). |
| `sysctlbyname` | `kern.memorystatus_vm_pressure_level` | `Int32` | `1` = `Normal`, `2` = `Warning`, `4` = `Critical`. |
| `sysctlbyname` | `machdep.cpu.brand_string` | `CString` | SoC identifier (e.g., `Apple M5 Pro`). |
| `sysctlbyname` | `hw.ncpu`, `hw.perflevel0.physicalcpu`, `hw.perflevel1.physicalcpu` | `Int32` | Total logical cores and Performance / Efficiency physical core split. |
| `host_statistics64` | `vm_statistics64_data_t` | Mach Struct | `active_count + wire_count + compressor_page_count` multiplied by `vm_kernel_page_size` (`16384` bytes on arm64). |
| `IOKit` (`ioreg`) | `AGXAccelerator` $\rightarrow$ `"gpu-core-count"` | `Int` | Exact hardware Metal GPU core count (e.g., `20`). |

---

## 📜 3. Server Log Regex Contracts

Read window: Tail `65,536` bytes (`64 KB`) of the active Ollama log file.

| Metric | Regular Expression | Filter Rule |
| :--- | :--- | :--- |
| **Prompt Ingest Speed** | `([\d\.]+)\s+tokens per second` | Line contains `"prompt eval time"` |
| **Eval Generation Speed** | `([\d\.]+)\s+tokens per second` | Line does **not** contain `"prompt eval time"` |
| **Last LLM HTTP Call** | `\|\s*(\d{3})\s*\|\s*([\d\.]+[a-zµ]+)\s*\|.*?(POST\|GET)\s+"([^"]+)"` | Line contains `"[GIN]"` and path $\notin$ `{/api/ps, /api/version, /api/tags}` |

---

## ⚙️ 4. Local Persistence & LaunchAgent Files

| File Path | Owner | Purpose |
| :--- | :--- | :--- |
| `~/Applications/OllamaTop.app` | User | Self-contained signed macOS application bundle. |
| `~/.local/bin/ollama-top` | User | Executable Python 3 terminal TUI dashboard. |
| `~/.local/bin/ollama-bar` | User | CLI lifecycle wrapper (`start`, `stop`, `restart`, `status`) for `OllamaTop.app`. |
| `~/Library/LaunchAgents/io.github.squallbayu.ollamatop.plist` | User | Optional Launch-at-Login descriptor toggled from widget footer (`RunAtLoad = true`). |
