import AppKit
import SwiftUI

/// Satu command terminal yang lama lalu selesai (ditulis oleh hooks/notch-terminal.zsh).
struct TerminalEvent: Equatable, Identifiable {
    let id: String
    let command: String
    let exitCode: Int
    let duration: TimeInterval
    let cwd: String
    let termProgram: String
    let bundleID: String

    var succeeded: Bool { exitCode == 0 }

    /// Bundle app tempat command dijalankan (VS Code, Antigravity, iTerm, Terminal, …).
    var appBundleID: String? {
        if !bundleID.isEmpty { return bundleID }
        switch termProgram {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "WezTerm": return "com.github.wez.wezterm"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }
}

/// Membaca lalu menghapus file event dari folder antrean hook zsh.
enum TerminalWatcher {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchIsland/terminal")

    static func drain() -> [TerminalEvent] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> TerminalEvent? in
                defer { try? fm.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let command = o["command"] as? String else { return nil }
                return TerminalEvent(id: url.lastPathComponent,
                                     command: command.trimmingCharacters(in: .whitespaces),
                                     exitCode: (o["exit"] as? NSNumber)?.intValue ?? 0,
                                     duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
                                     cwd: o["cwd"] as? String ?? "",
                                     termProgram: o["term"] as? String ?? "",
                                     bundleID: o["bundle"] as? String ?? "")
            }
    }

    /// Bawa jendela app terminalnya ke depan.
    static func open(_ event: TerminalEvent) {
        guard let id = event.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
