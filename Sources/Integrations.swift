import Foundation

/// Memasang / melepas hook Claude Code (~/.claude/settings.json) dan hook terminal (~/.zshrc).
/// Semua perubahan membuat backup `*.bak-notchisland` lebih dulu dan hanya menyentuh entri milik NotchIsland.
enum Integrations {
    enum IntegrationError: LocalizedError {
        case invalidSettings(String)
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let path): return "\(path) bukan JSON yang valid — tidak diubah."
            case .missingResource(let name): return "File \(name) tidak ada di dalam app. Build ulang NotchIsland."
            }
        }
    }

    private static let fm = FileManager.default
    private static let home = fm.homeDirectoryForCurrentUser
    static let supportDir = home.appendingPathComponent("Library/Application Support/NotchIsland")

    /// Path biner app ini — dipakai sebagai perintah hook.
    static var executablePath: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// App dijalankan dari lokasi sementara (DMG atau karantina Gatekeeper) — jangan tulis path ini ke hook.
    static var isRunningFromTemporaryLocation: Bool {
        executablePath.hasPrefix("/Volumes/") || executablePath.contains("/AppTranslocation/")
    }

    private static func backup(_ url: URL) {
        guard fm.fileExists(atPath: url.path) else { return }
        let bak = URL(fileURLWithPath: url.path + ".bak-notchisland")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: url, to: bak)
    }

    // MARK: - Claude Code

    static let claudeEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var claudeHookCommand: String { "\"\(executablePath)\" --claude-hook" }

    enum HookStatus { case notInstalled, current, outdated }

    /// Entri hook milik NotchIsland: versi lama (skrip Python) maupun versi app.
    private static func isOurs(_ command: String) -> Bool {
        command.contains("claude-island-hook.py") || command.contains("--claude-hook")
    }

    private static func readClaudeSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.invalidSettings(claudeSettingsURL.path)
        }
        return obj
    }

    static func claudeHookStatus() -> HookStatus {
        guard let settings = try? readClaudeSettings(), let hooks = settings["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        var oursByEvent: [String: [String]] = [:]
        for (event, groups) in hooks {
            for group in groups as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    if let cmd = hook["command"] as? String, isOurs(cmd) { oursByEvent[event, default: []].append(cmd) }
                }
            }
        }
        if oursByEvent.isEmpty { return .notInstalled }
        let upToDate = claudeEvents.allSatisfy { oursByEvent[$0] == [claudeHookCommand] }
        return upToDate && oursByEvent.count == claudeEvents.count ? .current : .outdated
    }

    static func installClaudeHook() throws { try writeClaudeHook(install: true) }
    static func uninstallClaudeHook() throws { try writeClaudeHook(install: false) }

    private static func writeClaudeHook(install: Bool) throws {
        var settings = try readClaudeSettings()   // JSON rusak → berhenti, jangan ditimpa
        backup(claudeSettingsURL)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Set(claudeEvents).union(hooks.keys) {
            // Buang entri milik kita dulu supaya pasang ulang tidak dobel; entri lain dibiarkan.
            var groups: [[String: Any]] = (hooks[event] as? [[String: Any]] ?? []).compactMap { group in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String ?? "") }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
            if install, claudeEvents.contains(event) {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": claudeHookCommand, "timeout": 5]]]
                if event == "PreToolUse" || event == "PostToolUse" { entry["matcher"] = "*" }
                groups.append(entry)
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try fm.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: claudeSettingsURL, options: .atomic)
        // Sisa versi Python tidak dipakai lagi.
        try? fm.removeItem(at: supportDir.appendingPathComponent("claude-island-hook.py"))
    }

    // MARK: - Terminal (zsh)

    private static let zshMarker = "# NotchIsland terminal hook"
    static var zshrcURL: URL {
        let dir = ProcessInfo.processInfo.environment["ZDOTDIR"].map { URL(fileURLWithPath: $0) } ?? home
        return dir.appendingPathComponent(".zshrc")
    }
    static var zshScriptURL: URL { supportDir.appendingPathComponent("notch-terminal.zsh") }

    static func isTerminalHookInstalled() -> Bool {
        (try? String(contentsOf: zshrcURL, encoding: .utf8))?.contains(zshMarker) ?? false
    }

    /// Salin skrip zsh dari dalam app supaya selalu versi terbaru.
    static func refreshTerminalScript() throws {
        guard let source = Bundle.main.url(forResource: "notch-terminal", withExtension: "zsh") else {
            throw IntegrationError.missingResource("notch-terminal.zsh")
        }
        try fm.createDirectory(at: supportDir.appendingPathComponent("terminal"), withIntermediateDirectories: true)
        try? fm.removeItem(at: zshScriptURL)
        try fm.copyItem(at: source, to: zshScriptURL)
    }

    static func installTerminalHook() throws {
        try refreshTerminalScript()
        let line = "[[ -f \"\(zshScriptURL.path)\" ]] && source \"\(zshScriptURL.path)\"  \(zshMarker)"
        try writeZshrc { $0 + [line] }
    }

    static func uninstallTerminalHook() throws {
        guard isTerminalHookInstalled() else { return }
        try writeZshrc { $0 }
    }

    /// Tulis ulang ~/.zshrc tanpa baris milik kita, lalu `transform` menambah baris baru bila perlu.
    private static func writeZshrc(_ transform: ([String]) -> [String]) throws {
        let text = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        backup(zshrcURL)
        var lines = text.components(separatedBy: "\n").filter { !$0.contains(zshMarker) }
        while lines.last == "" { lines.removeLast() }
        try (transform(lines).joined(separator: "\n") + "\n").write(to: zshrcURL, atomically: true, encoding: .utf8)
    }
}
