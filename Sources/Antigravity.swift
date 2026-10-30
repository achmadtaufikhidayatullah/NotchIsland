import AppKit
import SwiftUI

// MARK: - Aktivitas (dari transcript Antigravity)
//
// Antigravity menulis transcript.jsonl per percakapan selama agent berjalan:
// ~/.gemini/antigravity*/brain/<id>/.system_generated/logs/transcript.jsonl
// Status dibaca dari baris terakhir (pendekatan dari Codenotch).

enum AgentState: String { case idle, busy, waiting }

struct AgentActivity: Equatable {
    var state: AgentState
    var waitingFor: String?
    /// Apa yang diminta saat menunggu: isi pertanyaan atau nama file yang perlu disetujui.
    var waitingDetail: String?
    var busySince: Date?
    var lastWrite: Date
    var conversation: String
    /// Status "busy" yang tidak bergerak terlalu lama — jangan dianggap selesai (tanpa bunyi).
    var stalled: Bool
}

final class AntigravityMonitor {
    private var cacheKey = ""
    private var parsed: (state: AgentState, waitingFor: String?, detail: String?) = (.idle, nil, nil)
    private var busySince: Date?
    private let stallAfter: TimeInterval = 10 * 60

    static var roots: [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: gemini, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.lastPathComponent.hasPrefix("antigravity") }
            .map { $0.appendingPathComponent("brain") }
    }

    func poll(now: Date = Date()) -> AgentActivity? {
        guard let (url, mtime) = newestTranscript() else { return nil }
        let key = "\(url.path)|\(mtime.timeIntervalSince1970)"
        if key != cacheKey, let tail = Self.tail(of: url) {
            cacheKey = key
            parsed = Self.parseState(tail)
        }

        var state = parsed.state
        let stalled = state != .idle && now.timeIntervalSince(mtime) > stallAfter
        if stalled { state = .idle }
        if state == .busy { busySince = busySince ?? now } else if state == .idle { busySince = nil }

        // .../brain/<conversation>/.system_generated/logs/transcript.jsonl
        let conversation = url.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        return AgentActivity(state: state, waitingFor: parsed.waitingFor, waitingDetail: parsed.detail,
                             busySince: busySince,
                             lastWrite: mtime, conversation: conversation, stalled: stalled)
    }

    private func newestTranscript() -> (URL, Date)? {
        let fm = FileManager.default
        var newest: (URL, Date)?
        for root in Self.roots {
            for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let file = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if newest == nil || mtime > newest!.1 { newest = (file, mtime) }
            }
        }
        return newest
    }

    static func tail(of url: URL, bytes: UInt64 = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        return try? handle.readToEnd()
    }

    /// Dibaca dari baris terbawah ke atas sampai USER_INPUT terakhir.
    /// PLANNER_RESPONSE tanpa tool call = giliran model selesai.
    static func parseState(_ data: Data) -> (state: AgentState, waitingFor: String?, detail: String?) {
        var turnOver = false
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String else { continue }   // baris pertama bisa terpotong
            switch type {
            case "USER_INPUT":
                return (turnOver ? .idle : .busy, nil, nil)
            case "PLANNER_RESPONSE":
                let calls = json["tool_calls"] as? [[String: Any]] ?? []
                if calls.isEmpty { turnOver = true; continue }
                for call in calls {
                    let name = call["name"] as? String ?? ""
                    let args = call["arguments"] as? [String: Any] ?? [:]
                    if name.contains("ask_question") { return (.waiting, "Pertanyaan", detail(args)) }
                    if name.contains("replace_file_content") || name.contains("write_to_file"),
                       let meta = args["ArtifactMetadata"] as? [String: Any],
                       meta["RequestFeedback"] as? Bool == true {
                        return (.waiting, "Persetujuan", detail(args))
                    }
                }
                if !turnOver { return (.busy, nil, nil) }
            case "EPHEMERAL_MESSAGE", "CONVERSATION_HISTORY", "KNOWLEDGE_ARTIFACTS", "CHECKPOINT":
                continue
            default:
                if !turnOver { return (.busy, nil, nil) }   // respons tool
            }
        }
        return (.idle, nil, nil)
    }

    /// Ringkasan argumen tool: pertanyaan, file target, atau command.
    private static func detail(_ args: [String: Any]) -> String? {
        for key in ["Question", "question", "TargetFile", "CommandLine", "Message", "message"] {
            guard let value = args[key] as? String, !value.isEmpty else { continue }
            let text = key == "TargetFile" ? URL(fileURLWithPath: value).lastPathComponent : value
            return String(text.split(separator: "\n").first ?? "").prefix(120).description
        }
        return nil
    }
}

// MARK: - Kuota (dari language server lokal Antigravity)
//
// Google menolak permintaan kuota dari klien lain, jadi — seperti panel Models & Usage
// milik Antigravity sendiri — kita bertanya ke language server yang berjalan di Mac ini.
// Hanya bisa saat Antigravity terbuka. Token CSRF lokal dibaca dari daftar proses dan
// hanya dikirim ke 127.0.0.1, tidak pernah disimpan.

enum AntigravityQuota {
    private static let service = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let csrfHeader = "x-codeium-csrf-token"

    static func isRunning() -> Bool { endpoint() != nil }

    /// Dipanggil di background: ps + lsof + request lokal.
    static func fetch() -> OfficialUsage? {
        guard let (ports, token) = endpoint() else { return nil }
        for port in ports {
            if let windows = request(port: port, token: token), !windows.isEmpty {
                return OfficialUsage(windows: windows, capturedAt: Date())
            }
        }
        return nil
    }

    private static func endpoint() -> (ports: [Int], token: String)? {
        // IDE lama: `language_server … --csrf_token X`; versi baru: `~/.gemini/bin/agy --hub --csrf_token=X`.
        for line in run("/bin/ps", ["-Ao", "pid,command"]).split(separator: "\n")
        where (line.contains("language_server") || line.contains("/agy ")) && line.contains("--csrf_token") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard let pid = Int(parts.first ?? ""), let token = flag("--csrf_token", in: parts) else { continue }
            // `-a` wajib: tanpa itu lsof meng-OR filter dan mengembalikan port proses lain.
            let lsof = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
            let ports = lsof.split(separator: "\n").compactMap { row -> Int? in
                guard let addr = row.split(separator: " ").last(where: { $0.contains(":") }) else { return nil }
                return Int(addr.split(separator: ":").last ?? "")
            }
            if !ports.isEmpty { return (ports, token) }
        }
        return nil
    }

    /// Nilai flag dalam bentuk `--name value` maupun `--name=value`.
    private static func flag(_ name: String, in parts: [Substring]) -> String? {
        if let i = parts.firstIndex(of: Substring(name)), i + 1 < parts.count { return String(parts[i + 1]) }
        return parts.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Sertifikat language server self-signed; hanya dipercaya untuk 127.0.0.1.
    private final class LocalhostTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               space.host == "127.0.0.1", let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: LocalhostTrust(), delegateQueue: nil)

    private static func request(port: Int, token: String) -> [LimitWindow]? {
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(service)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: csrfHeader)
        // forceRefresh: tanpa ini server menjawab dari cache-nya sendiri.
        req.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        req.timeoutInterval = 8

        let done = DispatchSemaphore(value: 0)
        var result: [LimitWindow]?
        session.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                result = parse(data)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return result
    }

    /// Bentuk response berbeda antar versi: `groups` (di `response`/`summary`/akar) atau `buckets`.
    static func parse(_ data: Data) -> [LimitWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var groups: [[String: Any]] = []
        for key in ["response", "summary"] {
            if let g = (obj[key] as? [String: Any])?["groups"] as? [[String: Any]] { groups = g; break }
        }
        if groups.isEmpty { groups = (obj["groups"] ?? obj["quotaGroups"]) as? [[String: Any]] ?? [] }

        var buckets: [(group: String?, bucket: [String: Any])] = groups.flatMap { g in
            (g["buckets"] as? [[String: Any]] ?? []).map { (g["displayName"] as? String, $0) }
        }
        if buckets.isEmpty { buckets = (obj["buckets"] as? [[String: Any]] ?? []).map { (nil, $0) } }

        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

        let windows: [LimitWindow] = buckets.compactMap { group, b in
            guard b["disabled"] as? Bool != true else { return nil }
            var remaining = num(b["remainingFraction"])
            if remaining == nil, let r = b["remaining"] as? [String: Any] {
                remaining = num(r["remainingFraction"]) ?? (r["case"] as? String == "remainingFraction" ? num(r["value"]) : nil)
            }
            let used: Double
            if let r = remaining, (0...1).contains(r) {
                used = (1 - r) * 100
            } else if let limit = num(b["limit"]), limit > 0, let u = num(b["used"]) {
                used = u / limit * 100
            } else {
                return nil
            }
            let label = (b["displayName"] ?? b["name"] ?? b["modelId"] ?? b["bucketId"]) as? String ?? "Kuota"
            let title = [group.map(shortGroup), shortLabel(label)].compactMap { $0 }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: " · ")
            let id = (b["bucketId"] ?? b["modelId"]) as? String ?? title
            return LimitWindow(id: id, title: title, percent: used,
                               resetsAt: ClaudeDesktopUsage.date(b["resetTime"]))
        }
        return windows.sorted { $0.percent > $1.percent }
    }

    // Label asli berbunyi "Weekly Limit Remaining", padahal yang kita tampilkan persen terpakai.
    private static func shortLabel(_ label: String) -> String {
        let l = label.replacingOccurrences(of: " Remaining", with: "")
        switch l.lowercased() {
        case "five hour limit", "5-hour limit": return "5 jam"
        case "weekly limit": return "Mingguan"
        default: return l
        }
    }

    private static func shortGroup(_ group: String) -> String {
        switch group.lowercased() {
        case "gemini models": return "Gemini"
        case "claude and gpt models": return "Claude & GPT"
        default: return group
        }
    }
}

// MARK: - Membuka app

enum AntigravityApp {
    /// Bawa Antigravity ke depan (atau buka bila belum jalan).
    static func open() {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.first {
            $0.bundleURL?.lastPathComponent.hasPrefix("Antigravity") == true
        }
        let candidates = [running?.bundleURL, URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
                          URL(fileURLWithPath: "/Applications/Antigravity.app")].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - UI

enum AntigravityStyle {
    static let gradient = LinearGradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96),
                                                  Color(red: 0.62, green: 0.40, blue: 0.95)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Tanda Antigravity; berdenyut saat agent bekerja.
struct AntigravityMark: View {
    var size: CGFloat = 14
    var active = false
    var tint: Color? = nil

    var body: some View {
        TimelineView(.animation(paused: !active)) { ctx in
            let pulse = active ? 0.85 + 0.15 * sin(ctx.date.timeIntervalSinceReferenceDate * 4) : 1
            Image(systemName: "a.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(AntigravityStyle.gradient))
                .scaleEffect(pulse)
        }
        .frame(width: size + 2, height: size + 2)
    }
}

struct AntigravityCard: View {
    let activity: AgentActivity?
    let running: Bool
    let now: Date
    var onOpen: (() -> Void)? = nil

    private var status: (String, Color) {
        switch activity?.state {
        case .busy: return ("Bekerja", Color(red: 0.45, green: 0.6, blue: 1))
        case .waiting: return ("Menunggu kamu", .orange)
        default: return (running ? "Diam" : "Tertutup", Palette.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AntigravityMark(size: 12, active: activity?.state == .busy)
                Text("Antigravity")
                    .font(.system(size: 12, weight: .semibold))
                Text(status.0)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status.1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(status.1.opacity(0.15), in: Capsule())
                Spacer(minLength: 0)
                if let since = activity?.busySince {
                    Text(ClaudeStyle.duration(now.timeIntervalSince(since)))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                if let onOpen {
                    OpenAppButton(help: "Buka Antigravity", action: onOpen)
                }
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            ClaudeProgressBar(fraction: activity?.state == .idle ? 1 : nil, color: status.1,
                              animating: activity?.state == .busy)
            if let a = activity {
                Text("#\(a.conversation.prefix(8)) · \(UsageStyle.ageText(a.lastWrite, now: now))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    private var detail: String {
        guard let a = activity else { return "Belum ada percakapan Antigravity di Mac ini." }
        switch a.state {
        case .waiting:
            let what = a.waitingFor?.lowercased() ?? "tindakanmu"
            return a.waitingDetail.map { "Agent menunggu \(what): \($0)" } ?? "Agent menunggu \(what)."
        case .busy: return "Agent sedang mengerjakan prompt…"
        case .idle: return a.stalled ? "Tidak ada aktivitas baru — mungkin terhenti." : "Prompt terakhir sudah selesai."
        }
    }
}
