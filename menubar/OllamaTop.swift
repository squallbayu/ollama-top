// SPDX-License-Identifier: GPL-3.0-or-later
// OllamaTop — Native macOS Menu Bar Monitor for Ollama & Apple Silicon Unified Memory
// Copyright (C) 2026 Bayu Sanjaya <https://github.com/squallbayu/ollama-top>

import AppKit
import Darwin
import Foundation
import SQLite3
import SwiftUI

// MARK: - Ollama HTTP API Models

struct OllamaVersionResponse: Codable {
    let version: String
}

struct OllamaModelDetails: Codable {
    let parameter_size: String?
    let quantization_level: String?
    let context_length: Int?
}

struct OllamaActiveModel: Codable, Identifiable {
    var id: String { name }
    let name: String
    let size: Int64?
    let size_vram: Int64?
    let expires_at: String?
    let context_length: Int?
    let details: OllamaModelDetails?
}

struct OllamaPSResponse: Codable {
    let models: [OllamaActiveModel]?
}

struct OllamaInstalledModel: Codable, Identifiable {
    var id: String { name }
    let name: String
    let size: Int64?
    let details: OllamaModelDetails?
}

struct OllamaTagsResponse: Codable {
    let models: [OllamaInstalledModel]?
}

// MARK: - Portable System Hardware & Mach Telemetry

enum SystemTelemetry {
    static func sysctlString(_ key: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlUInt64(_ key: String) -> UInt64? {
        var val: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &val, &size, nil, 0) == 0 else { return nil }
        return val
    }

    static func sysctlInt32(_ key: String) -> Int32? {
        var val: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &val, &size, nil, 0) == 0 else { return nil }
        return val
    }

    static func detectGPUDescription() -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        proc.arguments = ["-rc", "AGXAccelerator", "-d", "1"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let out = String(data: data, encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #""gpu-core-count"\s*=\s*(\d+)"#),
               let match = regex.firstMatch(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out)),
               let r1 = Range(match.range(at: 1), in: out) {
                return "\(out[r1])-Core Metal GPU"
            }
        } catch {}
        return "Metal Hardware GPU"
    }

    static func getStaticHardware() -> (chip: String, cores: String, gpu: String, os: String) {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let ncpu = sysctlInt32("hw.ncpu") ?? Int32(ProcessInfo.processInfo.processorCount)
        let pCores = sysctlInt32("hw.perflevel0.physicalcpu")
        let eCores = sysctlInt32("hw.perflevel1.physicalcpu")

        let cores: String
        if let p = pCores, let e = eCores, (p + e) == ncpu {
            cores = "\(ncpu) Cores (\(p)P + \(e)E)"
        } else {
            cores = "\(ncpu) CPU Cores"
        }

        let gpu = detectGPUDescription()
        let ver = sysctlString("kern.osproductversion") ?? ""
        let os = ver.isEmpty ? "macOS" : "macOS \(ver)"
        return (chip, cores, gpu, os)
    }

    static func getMemoryStats() -> (totalGB: Double, usedGB: Double, freeGB: Double, pressure: String) {
        let totalBytes = sysctlUInt64("hw.memsize") ?? UInt64(ProcessInfo.processInfo.physicalMemory)
        let totalGB = Double(totalBytes) / 1_073_741_824.0

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        var usedGB = 0.0
        if result == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            usedGB = Double(usedPages * pageSize) / 1_073_741_824.0
        }
        let freeGB = max(0.0, totalGB - usedGB)

        let pLevel = sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1
        let pressure: String
        if pLevel >= 4 {
            pressure = "Critical"
        } else if pLevel >= 2 {
            pressure = "Warning"
        } else {
            pressure = "Normal"
        }

        return (
            (totalGB * 10).rounded() / 10,
            (usedGB * 10).rounded() / 10,
            (freeGB * 10).rounded() / 10,
            pressure
        )
    }

    static func getDiskSpace() -> String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let free = attrs[.systemFreeSize] as? NSNumber,
               let total = attrs[.systemSize] as? NSNumber {
                let freeTB = free.doubleValue / 1_000_000_000_000.0
                let totalTB = total.doubleValue / 1_000_000_000_000.0
                if totalTB >= 1.0 {
                    return String(format: "%.2f TB free / %.1f TB", freeTB, totalTB)
                } else {
                    let freeGB = free.doubleValue / 1_000_000_000.0
                    let totalGB = total.doubleValue / 1_000_000_000.0
                    return String(format: "%.0f GB free / %.0f GB", freeGB, totalGB)
                }
            }
        } catch {}
        return "NVMe Ready"
    }

    static func resolveActiveLogFile() -> String? {
        if let custom = ProcessInfo.processInfo.environment["OLLAMA_LOG_PATH"],
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: (custom as NSString).expandingTildeInPath) {
            return (custom as NSString).expandingTildeInPath
        }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.ollama/logs/server.log",
            "\(home)/.gemini/ollama_daemon.log",
            "/opt/homebrew/var/log/ollama.log",
            "/usr/local/var/log/ollama.log"
        ]

        var bestPath: String? = nil
        var newestDate: Date = .distantPast

        for path in candidates {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date,
               mod > newestDate {
                newestDate = mod
                bestPath = path
            }
        }
        return bestPath
    }

    static func parseRecentLogMetrics() -> (genSpeed: String, promptSpeed: String, lastReq: String) {
        guard let path = resolveActiveLogFile(),
              let handle = FileHandle(forReadingAtPath: path) else {
            return ("-", "-", "-")
        }
        defer { try? handle.close() }

        let endPos = handle.seekToEndOfFile()
        let readLen: UInt64 = min(endPos, 65_536)
        handle.seek(toFileOffset: endPos - readLen)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return ("-", "-", "-")
        }

        var genSpeed = "-"
        var promptSpeed = "-"
        var lastReq = "-"

        let speedRegex = try? NSRegularExpression(pattern: #"([\d\.]+)\s+tokens per second"#)
        let ginRegex = try? NSRegularExpression(pattern: #"\|\s*(\d{3})\s*\|\s*([\d\.]+[a-zµ]+)\s*\|.*?(POST|GET)\s+"([^"]+)""#)

        let lines = text.components(separatedBy: .newlines)
        for line in lines.reversed() {
            if line.contains("tokens per second"), let regex = speedRegex {
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, range: nsRange),
                   let r1 = Range(match.range(at: 1), in: line) {
                    let val = "\(line[r1]) tok/s"
                    if line.contains("prompt eval time") {
                        if promptSpeed == "-" { promptSpeed = val }
                    } else {
                        if genSpeed == "-" { genSpeed = val }
                    }
                }
            }

            if lastReq == "-", line.contains("[GIN]"), let regex = ginRegex {
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if let match = regex.firstMatch(in: line, range: nsRange),
                   let rCode = Range(match.range(at: 1), in: line),
                   let rDur = Range(match.range(at: 2), in: line),
                   let rMethod = Range(match.range(at: 3), in: line),
                   let rPath = Range(match.range(at: 4), in: line) {
                    let pathStr = String(line[rPath])
                    if pathStr != "/api/ps" && pathStr != "/api/version" && pathStr != "/api/tags" {
                        lastReq = "\(line[rMethod]) \(pathStr) (\(line[rCode]), \(line[rDur]))"
                    }
                }
            }

            if genSpeed != "-" && promptSpeed != "-" && lastReq != "-" {
                break
            }
        }

        return (genSpeed, promptSpeed, lastReq)
    }

    static func parseOllamaDate(_ raw: String?) -> Date? {
        guard var s = raw, !s.isEmpty else { return nil }
        if let dotRange = s.range(of: #"\.\d+"#, options: .regularExpression) {
            s.removeSubrange(dotRange)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}

// MARK: - Antigravity Telemetry Models & Reader

struct AntigravityStats: Equatable {
    var isInstalled: Bool = false
    var isActive: Bool = false
    var activePID: String = "-"
    var workspace: String = "-"
    var convoCount: Int = 0
    var stepCount: Int = 0
    var lastTitle: String = "-"
    var todayIn: Int64 = 0
    var todayOut: Int64 = 0
    var todayCache: Int64 = 0
    var todayTurns: Int = 0
    var allTurns: Int = 0

    var formattedTodayTokens: String {
        let total = Double(todayIn + todayOut)
        if total >= 1_000_000 {
            return String(format: "%.2fM", total / 1_000_000.0)
        } else if total >= 1_000 {
            return String(format: "%.1fK", total / 1_000.0)
        }
        return "\(todayIn + todayOut)"
    }

    var formattedTodayIn: String {
        let n = Double(todayIn)
        if n >= 1_000_000 { return String(format: "%.2fM in", n / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK in", n / 1_000.0) }
        return "\(todayIn) in"
    }

    var formattedTodayOut: String {
        let n = Double(todayOut)
        if n >= 1_000_000 { return String(format: "%.2fM out", n / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK out", n / 1_000.0) }
        return "\(todayOut) out"
    }

    var formattedTodayCache: String {
        let n = Double(todayCache)
        if n >= 1_000_000 { return String(format: "%.2fM cache", n / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK cache", n / 1_000.0) }
        return "\(todayCache) cache"
    }

    var formattedLifetimeSummary: String {
        let stepsStr = stepCount >= 1_000 ? String(format: "%.1fK", Double(stepCount) / 1_000.0) : "\(stepCount)"
        let convoWord = convoCount == 1 ? "session" : "sessions"
        return "\(convoCount) \(convoWord) • \(stepsStr) steps"
    }
}

enum AntigravityTelemetryReader {
    static func read() -> AntigravityStats {
        var stats = AntigravityStats()
        let home = NSHomeDirectory()
        let geminiDir = "\(home)/.gemini/antigravity-cli"
        let fm = FileManager.default

        guard fm.fileExists(atPath: geminiDir) else {
            return stats
        }
        stats.isInstalled = true

        // 1. Process probe
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-fl", "agy"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.components(separatedBy: .newlines) {
                    if line.contains("--hub") || line.contains("bin/agy") {
                        stats.isActive = true
                        let parts = line.split(separator: " ").map(String.init)
                        if let pid = parts.first { stats.activePID = pid }
                        for part in parts {
                            if part.hasPrefix("--add-dir=") {
                                let dir = String(part.dropFirst("--add-dir=".count))
                                stats.workspace = (dir as NSString).lastPathComponent
                            }
                        }
                        break
                    }
                }
            }
        } catch {}

        // 2. Read SQLite summaries
        let dbPath = "\(geminiDir)/conversation_summaries.db"
        if fm.fileExists(atPath: dbPath) {
            var db: OpaquePointer?
            if sqlite3_open_v2("file:\(dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = db {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT count(*), coalesce(sum(step_count), 0) FROM conversation_summaries", -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        stats.convoCount = Int(sqlite3_column_int(stmt, 0))
                        stats.stepCount = Int(sqlite3_column_int(stmt, 1))
                    }
                    sqlite3_finalize(stmt)
                }

                var stmtLast: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT title, workspace_uris FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 1", -1, &stmtLast, nil) == SQLITE_OK {
                    if sqlite3_step(stmtLast) == SQLITE_ROW {
                        if let cTitle = sqlite3_column_text(stmtLast, 0) {
                            stats.lastTitle = String(cString: cTitle)
                        }
                        if stats.workspace == "-", let cUris = sqlite3_column_text(stmtLast, 1) {
                            let urisStr = String(cString: cUris).trimmingCharacters(in: CharacterSet(charactersIn: "[]'\" "))
                            stats.workspace = (urisStr as NSString).lastPathComponent
                        }
                    }
                    sqlite3_finalize(stmtLast)
                }
                sqlite3_close(db)
            }
        }

        // 3. Scan transcripts (mtime < 30 days)
        let brainDir = "\(geminiDir)/brain"
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let todayComponents = utcCal.dateComponents([.year, .month, .day], from: Date())
        let todayStr: String
        if let y = todayComponents.year, let m = todayComponents.month, let d = todayComponents.day {
            todayStr = String(format: "%04d-%02d-%02d", y, m, d)
        } else {
            todayStr = ""
        }

        if let brainContents = try? fm.contentsOfDirectory(atPath: brainDir) {
            for convoId in brainContents {
                let transPath = "\(brainDir)/\(convoId)/.system_generated/logs/transcript.jsonl"
                guard fm.fileExists(atPath: transPath) else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: transPath),
                      let mdate = attrs[.modificationDate] as? Date,
                      Date().timeIntervalSince(mdate) < 30 * 86400 else { continue }

                guard let handle = FileHandle(forReadingAtPath: transPath) else { continue }
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                guard let text = String(data: data, encoding: .utf8) else { continue }

                for line in text.components(separatedBy: .newlines) {
                    guard line.contains("\"PLANNER_RESPONSE\""),
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                    let inp = json["input_tokens"] as? Int64 ?? 0
                    let out = json["output_tokens"] as? Int64 ?? 0
                    let cache = json["cache_read_tokens"] as? Int64 ?? 0
                    stats.allTurns += 1

                    if !todayStr.isEmpty, let createdAt = json["created_at"] as? String, createdAt.hasPrefix(todayStr) {
                        stats.todayIn += inp
                        stats.todayOut += out
                        stats.todayCache += cache
                        stats.todayTurns += 1
                    }
                }
            }
        }

        return stats
    }
}

// MARK: - Monitor ViewModel

enum MenuBarVisualState: Equatable {
    case stopped
    case idle
    case active(shortLabel: String)
}

@MainActor
final class OllamaMonitor: ObservableObject {
    @Published var isDaemonRunning: Bool = false
    @Published var daemonVersion: String = "-"
    @Published var activeModels: [OllamaActiveModel] = []
    @Published var installedModels: [OllamaInstalledModel] = []

    @Published var totalRAM: Double = 24.0
    @Published var usedRAM: Double = 0.0
    @Published var freeRAM: Double = 24.0
    @Published var ramPressure: String = "Normal"
    @Published var diskInfo: String = "-"

    @Published var genSpeed: String = "-"
    @Published var promptSpeed: String = "-"
    @Published var lastRequest: String = "-"

    @Published var antigravity: AntigravityStats = AntigravityStats()

    @Published var busyModelName: String? = nil
    @Published var isTogglingDaemon: Bool = false
    @Published var statusBanner: String? = nil
    @Published var launchAtLogin: Bool = false
    @Published var now: Date = Date()

    let hwSpecs = SystemTelemetry.getStaticHardware()
    let apiBase: String
    let launchAgentMenuBarPath: String

    var isPopoverVisible: Bool = false {
        didSet {
            if isPopoverVisible {
                Task { await refreshAll(includeHeavy: true) }
            }
        }
    }

    var onMenuBarChange: ((MenuBarVisualState) -> Void)?

    private var backgroundTimer: Timer?
    private var tickTimer: Timer?
    private let urlSession: URLSession

    init() {
        let rawHost = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
        let trimmed = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiBase = trimmed.hasPrefix("http") ? trimmed : "http://\(trimmed)"

        let home = NSHomeDirectory()
        self.launchAgentMenuBarPath = "\(home)/Library/LaunchAgents/io.github.squallbayu.ollamatop.plist"

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.8
        cfg.timeoutIntervalForResource = 3.0
        self.urlSession = URLSession(configuration: cfg)

        let legacyPlist = "\(home)/Library/LaunchAgents/com.ollama.menubar.plist"
        self.launchAtLogin = FileManager.default.fileExists(atPath: launchAgentMenuBarPath)
            || FileManager.default.fileExists(atPath: legacyPlist)
        self.diskInfo = SystemTelemetry.getDiskSpace()

        startTimers()
        Task { await refreshAll(includeHeavy: true) }
    }

    private func startTimers() {
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refreshAll(includeHeavy: self.isPopoverVisible)
            }
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isPopoverVisible {
                    self.now = Date()
                }
            }
        }
    }

    func showBanner(_ message: String) {
        statusBanner = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.statusBanner == message {
                self.statusBanner = nil
            }
        }
    }

    static func shortModelTag(_ fullName: String) -> String {
        let lower = fullName.lowercased()
        if lower.contains("qwen") && lower.contains("32k") { return "Qwen32k" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("deepseek-r1") && lower.contains("32k") { return "R1-32k" }
        if lower.contains("deepseek-r1") { return "R1" }
        if lower.contains("llama") { return "Llama" }
        if lower.contains("mistral") { return "Mistral" }
        if lower.contains("gemma") { return "Gemma" }
        if lower.contains("codestral") || lower.contains("devstral") { return "Codestral" }
        let base = fullName.split(separator: ":").first.map(String.init) ?? fullName
        return String(base.prefix(10))
    }

    static func formatGiB(_ bytes: Int64?) -> Double {
        guard let b = bytes, b > 0 else { return 0.0 }
        return (Double(b) / 1_073_741_824.0 * 100).rounded() / 100
    }

    static func modelFootprintHint(_ item: OllamaInstalledModel) -> String {
        let diskGiB = formatGiB(item.size)
        let lower = item.name.lowercased()
        let params = item.details?.parameter_size ?? ""
        let quant = item.details?.quantization_level ?? ""
        let is32k = lower.contains("32k")

        let estVRAM = is32k ? (diskGiB + 1.9) : (diskGiB + 0.5)
        var role = ""
        if lower.contains("coder") || lower.contains("codestral") || lower.contains("starcoder") {
            role = is32k ? "32K Repo Audits" : "Coding & Tools"
        } else if lower.contains("r1") || lower.contains("qwq") || lower.contains("reason") {
            role = is32k ? "32K Deep Logic" : "CoT Reasoning"
        } else {
            role = [params, quant].filter { !$0.isEmpty }.joined(separator: " • ")
        }

        if role.isEmpty {
            return String(format: "~%.1f GB VRAM", estVRAM)
        }
        return String(format: "~%.1f GB VRAM • %@", estVRAM, role)
    }

    func refreshAll(includeHeavy: Bool) async {
        let mem = SystemTelemetry.getMemoryStats()
        self.totalRAM = mem.totalGB
        self.usedRAM = mem.usedGB
        self.freeRAM = mem.freeGB
        self.ramPressure = mem.pressure
        self.now = Date()

        async let verFetch: OllamaVersionResponse? = fetchJSON("/api/version")
        async let psFetch: OllamaPSResponse? = fetchJSON("/api/ps")

        let (verResp, psResp) = await (verFetch, psFetch)

        if let ver = verResp {
            self.isDaemonRunning = true
            self.daemonVersion = ver.version
            self.activeModels = psResp?.models ?? []
        } else {
            self.isDaemonRunning = false
            self.daemonVersion = "-"
            self.activeModels = []
        }

        let newState: MenuBarVisualState
        if !isDaemonRunning {
            newState = .stopped
        } else if let first = activeModels.first {
            let vramGiB = Self.formatGiB(first.size_vram ?? first.size)
            let short = Self.shortModelTag(first.name)
            newState = .active(shortLabel: String(format: "%@ %.1fG", short, vramGiB))
        } else {
            newState = .idle
        }
        onMenuBarChange?(newState)

        if includeHeavy {
            if isDaemonRunning, let tagsResp: OllamaTagsResponse = await fetchJSON("/api/tags") {
                self.installedModels = tagsResp.models ?? []
            }
            let metrics = await Task.detached(priority: .utility) {
                SystemTelemetry.parseRecentLogMetrics()
            }.value
            self.genSpeed = metrics.genSpeed
            self.promptSpeed = metrics.promptSpeed
            self.lastRequest = metrics.lastReq
            self.diskInfo = SystemTelemetry.getDiskSpace()

            let agStats = await Task.detached(priority: .utility) {
                AntigravityTelemetryReader.read()
            }.value
            self.antigravity = agStats
        }
    }

    private func fetchJSON<T: Decodable>(_ endpoint: String) async -> T? {
        guard let url = URL(string: "\(apiBase)\(endpoint)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("OllamaTop-MenuBar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - User Actions

    func unloadModel(_ modelName: String) async {
        busyModelName = modelName
        defer { busyModelName = nil }

        guard let url = URL(string: "\(apiBase)/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": modelName, "keep_alive": 0]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                showBanner("Unloaded \(Self.shortModelTag(modelName)) — VRAM freed")
            }
        } catch {
            showBanner("Failed to unload \(modelName)")
        }
        await refreshAll(includeHeavy: true)
    }

    func warmLoadModel(_ modelName: String) async {
        busyModelName = modelName
        defer { busyModelName = nil }

        guard let url = URL(string: "\(apiBase)/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": modelName, "prompt": "", "keep_alive": "5m"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                showBanner("Loaded \(Self.shortModelTag(modelName)) into Metal VRAM")
            }
        } catch {
            showBanner("Failed to load \(modelName)")
        }
        await refreshAll(includeHeavy: true)
    }

    func toggleDaemon() async {
        isTogglingDaemon = true
        defer { isTogglingDaemon = false }

        let uid = getuid()
        let home = NSHomeDirectory()
        let userPlist = "\(home)/Library/LaunchAgents/com.ollama.user.plist"
        let brewPlist = "\(home)/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
        let running = isDaemonRunning

        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: userPlist) {
                Self.runCmd("/bin/launchctl", running
                    ? ["bootout", "gui/\(uid)/com.ollama.user"]
                    : ["bootstrap", "gui/\(uid)", userPlist])
            } else if fm.fileExists(atPath: brewPlist) {
                Self.runCmd("/bin/launchctl", running
                    ? ["bootout", "gui/\(uid)/homebrew.mxcl.ollama"]
                    : ["bootstrap", "gui/\(uid)", brewPlist])
            } else if fm.fileExists(atPath: "/Applications/Ollama.app") {
                if running {
                    Self.runCmd("/usr/bin/pkill", ["-x", "Ollama"])
                    Self.runCmd("/usr/bin/pkill", ["-f", "ollama serve"])
                } else {
                    Self.runCmd("/usr/bin/open", ["-a", "/Applications/Ollama.app"])
                }
            } else {
                if running {
                    Self.runCmd("/usr/bin/pkill", ["-f", "ollama serve"])
                } else {
                    let bins = ["\(home)/.local/bin/ollama", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
                    if let ollamaBin = bins.first(where: { fm.isExecutableFile(atPath: $0) }) {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: ollamaBin)
                        p.arguments = ["serve"]
                        p.standardOutput = FileHandle.nullDevice
                        p.standardError = FileHandle.nullDevice
                        try? p.run()
                    }
                }
            }
        }.value

        try? await Task.sleep(nanoseconds: 900_000_000)
        await refreshAll(includeHeavy: true)
        showBanner(isDaemonRunning ? "Ollama background service started" : "Ollama background service stopped")
    }

    nonisolated private static func runCmd(_ exec: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let legacyPlist = "\(NSHomeDirectory())/Library/LaunchAgents/com.ollama.menubar.plist"
        if enabled {
            let bundleExec = Bundle.main.executablePath
                ?? "\(NSHomeDirectory())/Applications/OllamaTop.app/Contents/MacOS/OllamaTop"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>io.github.squallbayu.ollamatop</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(bundleExec)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            do {
                let dir = (launchAgentMenuBarPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try plist.write(toFile: launchAgentMenuBarPath, atomically: true, encoding: .utf8)
                launchAtLogin = true
                showBanner("Enabled Launch at Login")
            } catch {
                showBanner("Could not write LaunchAgent")
            }
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentMenuBarPath)
            try? FileManager.default.removeItem(atPath: legacyPlist)
            launchAtLogin = false
            showBanner("Disabled Launch at Login")
        }
    }

    func openCLIDashboard() {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/ollama-top",
            "/opt/homebrew/bin/ollama-top",
            "/usr/local/bin/ollama-top"
        ]
        let cliCmd = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "ollama-top"
        let script = """
        tell application "Terminal"
            activate
            do script "\(cliCmd)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

// MARK: - SwiftUI Popover Dashboard

// Modern Apple Glass/Vibrancy Card Style
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 11.0
    var tintColor: Color? = nil
    var tintOpacity: Double = 0.07

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                    if let tint = tintColor {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(tintOpacity))
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.04),
                                    Color.black.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 11.0, tint: Color? = nil, tintOpacity: Double = 0.07) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tintColor: tint, tintOpacity: tintOpacity))
    }
}

// MARK: - Animated Sprites: Active Agent at Desk vs Model Inventory Bed

// 1. Used in ACTIVE GPU/VRAM section: Working agent typing at desk with glowing display (no bed)
struct AgentDeskWorkingView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate * 2.2) % 4
            let typingToggle = step % 2 == 0

            ZStack(alignment: .bottom) {
                // Ambient monitor glow
                Circle()
                    .fill(Color.teal.opacity(typingToggle ? 0.35 : 0.15))
                    .frame(width: 22, height: 22)
                    .offset(y: -4)

                // Computer screen
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Color.teal, Color.cyan], startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                    )
                    .offset(x: 5, y: -4)

                // Desk table
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 16, height: 2.5)
                    .offset(x: 3, y: 1.5)

                // Desk legs
                Rectangle()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 1.5, height: 6)
                    .offset(x: 9, y: 5)

                // Agent sitting and typing
                ZStack {
                    // Head with bobbing
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(Color.orange.opacity(0.6), lineWidth: 0.5)
                        )
                        .offset(x: -3, y: typingToggle ? -7.5 : -6.5)

                    // Torso
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.teal)
                        .frame(width: 6, height: 6.5)
                        .offset(x: -3, y: 0)

                    // Hands
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 2.5, height: 2.5)
                        .offset(x: typingToggle ? 1.5 : 0.5, y: typingToggle ? -1.0 : -0.2)
                }
            }
            .frame(width: 22, height: 22)
            .padding(.horizontal, 2)
        }
    }
}

// 2. Used in INSTALLED LLM INVENTORY: Empty Bed when running, Bed with Sleeping Agent when idle (no desk)
struct ModelBedStateView: View {
    let isRunning: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate * 2.2) % 4
            let typingToggle = step % 2 == 0

            ZStack(alignment: .bottomLeading) {
                // Headboard
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.brown)
                    .frame(width: 3.5, height: 12)
                    .offset(x: 0, y: 0)

                // Bed Mattress
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(Color.white)
                    .frame(width: 15, height: 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.2)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .offset(x: 2.5, y: 0)

                // Pillow
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: 4.5, height: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 0.5)
                    )
                    .offset(x: 3.5, y: -3.5)

                if isRunning {
                    // EMPTY BED: Agent woke up and left bed to compute!
                    // Rumpled blanket at bottom of bed
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(LinearGradient(colors: [Color.cyan, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 7.5, height: 5)
                        .offset(x: 9.5, y: -0.5)
                } else {
                    // SLEEPING AGENT IN BED
                    // Head resting on pillow
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 6, height: 6)
                        .offset(x: 3.5, y: -3.5)

                    // Sleeping closed eyes
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .frame(width: 3, height: 0.9)
                        .offset(x: 4.5, y: -3.5)

                    // Breathing Blanket
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [Color.indigo, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 10.5, height: typingToggle ? 6.2 : 5.0)
                        .offset(x: 6.8, y: typingToggle ? -1.0 : 0)

                    // Animated Floating Zzz
                    let zOffset = CGFloat(step)
                    Text(step % 2 == 0 ? "z" : "Z")
                        .font(.system(size: 8 + zOffset * 0.8, weight: .black, design: .rounded))
                        .foregroundStyle(Color.indigo.opacity(1.0 - Double(step) * 0.18))
                        .offset(x: 10 + zOffset * 2.0, y: -9 - zOffset * 2.5)
                }
            }
            .frame(width: 22, height: 22)
            .padding(.horizontal, 2)
        }
    }
}

struct PopoverDashboardView: View {
    @ObservedObject var monitor: OllamaMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerSection
            Divider().opacity(0.5)
            activeVRAMSection
            memoryAndHardwareSection
            telemetrySection
            antigravitySection
            installedModelsSection

            if let banner = monitor.statusBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                    Text(banner)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            }

            Divider().opacity(0.5)
            footerSection
        }
        .padding(12)
        .frame(width: 380)
    }

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [Color.teal.opacity(0.25), Color.blue.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(monitor.isDaemonRunning ? Color.teal : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Ollama Top")
                        .font(.system(size: 14, weight: .bold))
                    if monitor.isDaemonRunning {
                        Text("v\(monitor.daemonVersion)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(monitor.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(monitor.isDaemonRunning ? "Engine Running (\(monitor.apiBase.replacingOccurrences(of: "http://", with: "")))" : "Daemon Stopped")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await monitor.toggleDaemon() }
            } label: {
                if monitor.isTogglingDaemon {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: monitor.isDaemonRunning ? "power.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(monitor.isDaemonRunning ? Color.green : Color.orange)
                }
            }
            .buttonStyle(.plain)
            .help(monitor.isDaemonRunning ? "Stop Ollama background service" : "Start Ollama background service")

            Button {
                Task { await monitor.refreshAll(includeHeavy: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh metrics now")
        }
    }

    private var activeVRAMSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("ACTIVE GPU / VRAM", systemImage: "memorychip.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Unified Metal Memory")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !monitor.isDaemonRunning {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.secondary)
                    Text("Ollama service is offline. 0.00 GB VRAM used.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .glassCard(cornerRadius: 10)
            } else if monitor.activeModels.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idle — 0.00 GB VRAM Consumed")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Auto-sleep active. Hot-loads from NVMe on demand.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .glassCard(cornerRadius: 10, tint: .green, tintOpacity: 0.09)
            } else {
                ForEach(monitor.activeModels) { m in
                    let vramGiB = OllamaMonitor.formatGiB(m.size_vram ?? m.size)
                    let ratio = min(1.0, max(0.0, vramGiB / max(1.0, monitor.totalRAM)))
                    let countdown = formatCountdown(m.expires_at, now: monitor.now)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                AgentDeskWorkingView()
                                Text(m.name)
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(String(format: "%.2f GB VRAM", vramGiB))
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.purple)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.10))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.purple, .pink],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(6, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 7)

                        HStack {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 10))
                                Text("\(countdown) • 100% Metal GPU")
                                    .font(.system(size: 10.5))
                            }
                            .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                Task { await monitor.unloadModel(m.name) }
                            } label: {
                                HStack(spacing: 4) {
                                    if monitor.busyModelName == m.name {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "bolt.slash.fill")
                                            .font(.system(size: 10))
                                    }
                                    Text("Unload VRAM")
                                        .font(.system(size: 10.5, weight: .semibold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Color.red.opacity(0.14), in: Capsule())
                                .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .glassCard(cornerRadius: 10, tint: .purple, tintOpacity: 0.10)
                }
            }
        }
    }

    private var memoryAndHardwareSection: some View {
        let ratio = min(1.0, max(0.0, monitor.usedRAM / max(1.0, monitor.totalRAM)))
        let barColor: Color = monitor.ramPressure == "Critical" ? .red : (monitor.ramPressure == "Warning" ? .orange : .teal)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("UNIFIED MEMORY & HOST", systemImage: "cpu")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Pressure: \(monitor.ramPressure)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(barColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(barColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: "Used: %.1f GB / %.1f GB", monitor.usedRAM, monitor.totalRAM))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(String(format: "Free Buffer: ~%.1f GB", monitor.freeRAM))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(6, geo.size.width * ratio))
                    }
                }
                .frame(height: 7)

                HStack(spacing: 6) {
                    specBadge(icon: "cpu.fill", text: "\(monitor.hwSpecs.chip) • \(monitor.hwSpecs.cores)")
                    Spacer()
                    specBadge(icon: "internaldrive.fill", text: monitor.diskInfo)
                }
                .padding(.top, 2)

                HStack(spacing: 6) {
                    specBadge(icon: "sparkles.tv.fill", text: monitor.hwSpecs.gpu)
                    Spacer()
                    specBadge(icon: "desktopcomputer", text: monitor.hwSpecs.os)
                }
            }
            .padding(10)
            .glassCard(cornerRadius: 10)
        }
    }

    private func specBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("INFERENCE TELEMETRY", systemImage: "speedometer")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                metricTile(title: "Eval Speed", value: monitor.genSpeed, color: .cyan)
                metricTile(title: "Prompt Ingest", value: monitor.promptSpeed, color: .blue)
            }

            if monitor.lastRequest != "-" {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Text("Last LLM Call: \(monitor.lastRequest)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func metricTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(value == "-" ? .secondary : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCard(cornerRadius: 8)
    }

    // 5. Antigravity Usage Card
    @ViewBuilder
    private var antigravitySection: some View {
        if monitor.antigravity.isInstalled {
            let ag = monitor.antigravity
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("ANTIGRAVITY TELEMETRY", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if ag.isActive {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("Active (\(ag.workspace))")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    } else {
                        Text("Standby")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Today's Tokens:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(ag.formattedTodayTokens) (\(ag.todayTurns) turns)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 8) {
                        Text("├─ \(ag.formattedTodayIn)")
                        Text("•")
                        Text("\(ag.formattedTodayOut)")
                        Text("•")
                        Text("\(ag.formattedTodayCache)")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                    Divider().opacity(0.3).padding(.vertical, 1)

                    HStack {
                        specBadge(icon: "archivebox.fill", text: ag.formattedLifetimeSummary)
                        Spacer()
                        if ag.lastTitle != "-" {
                            specBadge(icon: "text.bubble.fill", text: ag.lastTitle)
                        }
                    }
                }
                .padding(10)
                .glassCard(cornerRadius: 10)
            }
        }
    }

    // 6. Installed LLM Inventory
    private var installedModelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("INSTALLED LLM INVENTORY (\(monitor.installedModels.count))", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Local GGUF Models")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            if monitor.installedModels.isEmpty {
                Text(monitor.isDaemonRunning ? "No models installed yet (`ollama pull ...`)." : "Start engine to inspect models.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.vertical, showsIndicators: monitor.installedModels.count > 5) {
                    VStack(spacing: 5) {
                        ForEach(monitor.installedModels) { item in
                            let isActive = monitor.activeModels.contains(where: { $0.name == item.name })
                            let hint = OllamaMonitor.modelFootprintHint(item)

                            HStack(spacing: 8) {
                                ModelBedStateView(isRunning: isActive)

                                VStack(alignment: .leading, spacing: 1.5) {
                                    Text(item.name)
                                        .font(.system(size: 11.5, weight: isActive ? .bold : .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Text(hint)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if monitor.busyModelName == item.name {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(.horizontal, 8)
                                } else if isActive {
                                    Button("Unload") {
                                        Task { await monitor.unloadModel(item.name) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.red)
                                } else {
                                    Button("Load") {
                                        Task { await monitor.warmLoadModel(item.name) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                    .foregroundStyle(.primary)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5.5)
                            .glassCard(
                                cornerRadius: 8,
                                tint: isActive ? .green : nil,
                                tintOpacity: isActive ? 0.08 : 0.0
                            )
                        }
                    }
                }
                .frame(maxHeight: monitor.installedModels.count > 5 ? 215 : nil)
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { monitor.launchAtLogin },
                set: { monitor.setLaunchAtLogin($0) }
            )) {
                Text("Launch at Login")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)

            Spacer()

            Button {
                monitor.openCLIDashboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text("CLI")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Open terminal ollama-top")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    private func formatCountdown(_ rawISO: String?, now: Date) -> String {
        guard let exp = SystemTelemetry.parseOllamaDate(rawISO) else { return "Active" }
        let diff = Int(exp.timeIntervalSince(now))
        if diff <= 0 { return "Unloading..." }
        let mins = diff / 60
        let secs = diff % 60
        return String(format: "Sleep in %dm %02ds", mins, secs)
    }
}

// MARK: - Custom Control-Center Style Panel & Hosting View

final class PinnedTopHostingView<Content: View>: NSHostingView<Content> {
    var onSizeInvalidated: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeInvalidated?()
    }
}

final class MenuBarPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - AppKit Menu Bar Controller

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var hostingView: PinnedTopHostingView<PopoverDashboardView>!
    private var effectView: NSVisualEffectView!
    private var monitor: OllamaMonitor!
    private var lastVisualState: MenuBarVisualState?

    private var lockedTopY: CGFloat = 0
    private var lockedCenterX: CGFloat = 0
    private var lockedScreenFrame: NSRect = .zero
    private var globalClickMonitor: Any?
    private var lastAutoDismissTime: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        monitor = OllamaMonitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.toolTip = "Ollama Top — Click to monitor VRAM & LLMs"
        }

        setupFloatingPanel()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(togglePanel(_:)),
            name: NSNotification.Name("io.github.squallbayu.ollamatop.togglePanel"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(captureScreenshotNotification(_:)),
            name: NSNotification.Name("io.github.squallbayu.ollamatop.captureScreenshot"),
            object: nil
        )

        monitor.onMenuBarChange = { [weak self] state in
            self?.applyMenuBarState(state)
        }
        applyMenuBarState(.idle)
    }

    private func setupFloatingPanel() {
        hostingView = PinnedTopHostingView(rootView: PopoverDashboardView(monitor: monitor))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.onSizeInvalidated = { [weak self] in
            DispatchQueue.main.async {
                self?.relayoutPanelPinnedToTop()
            }
        }

        effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16.0
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1.0
        effectView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor

        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.delegate = self
        panel.contentView = effectView
        panel.onEscape = { [weak self] in
            self?.closePanel(autoDismissed: false)
        }
    }

    private func applyMenuBarState(_ state: MenuBarVisualState) {
        guard state != lastVisualState, let button = statusItem.button else { return }
        lastVisualState = state

        switch state {
        case .stopped:
            let img = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Ollama Stopped")
            img?.isTemplate = true
            button.image = img?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .regular))
            button.title = " Off"

        case .idle:
            let img = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Ollama Idle")
            img?.isTemplate = true
            button.image = img?.withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium))
            button.title = " Idle"

        case .active(let shortLabel):
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
                .applying(.init(paletteColors: [NSColor.systemGreen]))
            let img = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Model Active")?.withSymbolConfiguration(cfg)
            img?.isTemplate = false
            button.image = img
            button.title = " \(shortLabel)"
        }
    }

    @objc private func captureScreenshotNotification(_ sender: AnyObject?) {
        guard let targetView = effectView else { return }
        if !panel.isVisible {
            openPanelBelowMenuBar()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, let cv = self.effectView else { return }
            let bounds = cv.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let rep = cv.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            cv.cacheDisplay(in: bounds, to: rep)

            let home = NSHomeDirectory()
            let destPaths = [
                "\(home)/programs/ollama/ollama-top/docs/assets/ollama-top-menubar.jpg",
                "/tmp/ollama-top-menubar.jpg"
            ]

            if let jpgData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                for dest in destPaths {
                    try? jpgData.write(to: URL(fileURLWithPath: dest), options: .atomic)
                }
                print("==> Saved popover screenshot (\(Int(bounds.width))x\(Int(bounds.height))) to docs/assets/ollama-top-menubar.jpg")
            }
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible {
            closePanel(autoDismissed: false)
            return
        }
        if Date().timeIntervalSince(lastAutoDismissTime) < 0.18 {
            return
        }
        openPanelBelowMenuBar()
    }

    private func openPanelBelowMenuBar() {
        let mouseLoc = NSEvent.mouseLocation
        let clickWindow = NSApp.currentEvent?.window ?? statusItem.button?.window
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? clickWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let sFrame = screen.frame
        let menuBarBottomY: CGFloat
        if let cw = clickWindow, sFrame.intersects(cw.frame) {
            menuBarBottomY = cw.frame.minY
            lockedCenterX = cw.frame.midX
        } else {
            let fallbackTop = sFrame.maxY - max(25.0, NSStatusBar.system.thickness)
            menuBarBottomY = min(screen.visibleFrame.maxY, fallbackTop)
            lockedCenterX = mouseLoc.x
        }

        // Align directly flush against the bottom edge of the menu bar, exactly matching Apple's built-in popovers (Battery, Wi-Fi, Control Center)
        lockedTopY = menuBarBottomY
        lockedScreenFrame = sFrame

        monitor.isPopoverVisible = true
        hostingView.layoutSubtreeIfNeeded()
        relayoutPanelPinnedToTop()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitors()
    }

    private func relayoutPanelPinnedToTop() {
        guard lockedScreenFrame.width > 0 else { return }
        let fitting = hostingView.fittingSize
        let width = max(360.0, fitting.width)
        let maxAllowedHeight = max(300.0, lockedTopY - lockedScreenFrame.minY - 12.0)
        let height = min(max(200.0, fitting.height), maxAllowedHeight)

        let minX = lockedScreenFrame.minX + 8.0
        let maxX = lockedScreenFrame.maxX - width - 8.0
        let originX = min(max(minX, lockedCenterX - width / 2.0), maxX)
        let originY = lockedTopY - height

        let targetFrame = NSRect(x: originX.rounded(), y: originY.rounded(), width: width.rounded(), height: height.rounded())
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func closePanel(autoDismissed: Bool) {
        guard panel.isVisible else { return }
        if autoDismissed {
            lastAutoDismissTime = Date()
        }
        stopOutsideClickMonitors()
        panel.orderOut(nil)
        monitor.isPopoverVisible = false
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let loc = NSEvent.mouseLocation
                if let bw = self.statusItem.button?.window, NSMouseInRect(loc, bw.frame, false) {
                    return
                }
                if !NSMouseInRect(loc, self.panel.frame, false) {
                    self.closePanel(autoDismissed: true)
                }
            }
        }
    }

    private func stopOutsideClickMonitors() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel(autoDismissed: true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel(autoDismissed: true)
    }
}

// MARK: - Main Entrypoint

@main
struct OllamaTopMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
