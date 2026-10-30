import Foundation
import SwiftUI

// MARK: - Data dari hook (ditulis oleh hooks/claude-island-hook.py)

struct ClaudeSession: Decodable, Equatable {
    var session_id: String
    var project: String?
    var title: String?
    var state: String?
    var prompt: String?
    var started_at: Double?
    var finished_at: Double?
    var updated_at: Double?
    var tool: String?
    var tool_detail: String?
    var tool_count: Int?
    var plan: [String]?
    var message: String?
    var transcript_path: String?

    var isWorking: Bool { state == "working" }
    var isWaiting: Bool { state == "waiting" }
    var isActive: Bool { isWorking || isWaiting }
    var displayName: String { title ?? project ?? "Claude" }

    var planProgress: (done: Int, total: Int)? {
        guard let plan, !plan.isEmpty else { return nil }
        return (plan.filter { $0 == "completed" }.count, plan.count)
    }

    func elapsed(now: Date) -> TimeInterval? {
        guard let start = started_at else { return nil }
        let end = isActive ? now.timeIntervalSince1970 : (finished_at ?? updated_at ?? start)
        return max(0, end - start)
    }
}

struct ClaudeUsage: Equatable {
    var blockTokens: Int        // token di blok 5 jam yang sedang berjalan (estimasi)
    var resetAt: Date?          // perkiraan blok 5 jam berakhir
    var contextTokens: Int?     // ukuran konteks sesi utama
}

// MARK: - Monitor

final class ClaudeMonitor {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchIsland/claude")
    static let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// Sesi "working" tanpa event selama ini dianggap macet (mis. aplikasi ditutup paksa).
    private let staleAfter: TimeInterval = 30 * 60

    func readSessions() -> [ClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.stateDir, includingPropertiesForKeys: nil) else { return [] }
        let now = Date().timeIntervalSince1970
        var sessions: [ClaudeSession] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var s = try? JSONDecoder().decode(ClaudeSession.self, from: data) else { continue }
            let age = now - (s.updated_at ?? 0)
            if age > 24 * 3600 {                         // sesi lama yang tidak sempat SessionEnd
                try? fm.removeItem(at: url)
                continue
            }
            if s.isActive, age > staleAfter { s.state = "idle" }
            sessions.append(s)
        }
        return sessions.sorted { ($0.updated_at ?? 0) > ($1.updated_at ?? 0) }
    }

    // --- Estimasi usage dari transcript lokal ---

    private struct Entry { let time: Date; let tokens: Int }
    private struct ParsedFile { let stamp: String; let entries: [Entry]; let lastContext: Int? }
    private var cache: [String: ParsedFile] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Format transcript bersifat internal Claude Code, jadi semua parsing di sini toleran terhadap field yang hilang.
    private func parse(_ url: URL, stamp: String) -> ParsedFile {
        if let cached = cache[url.path], cached.stamp == stamp { return cached }
        var entries: [Entry] = []
        var seen = Set<String>()
        var lastContext: Int?
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                // Satu respons bisa tertulis di beberapa baris dengan usage yang sama.
                let key = "\(msg["id"] ?? "")|\(obj["requestId"] ?? "")"
                guard seen.insert(key).inserted else { continue }
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                if obj["isSidechain"] as? Bool != true { lastContext = input + cacheWrite + cacheRead }
                guard let ts = obj["timestamp"] as? String, let time = iso.date(from: ts) else { continue }
                entries.append(Entry(time: time, tokens: input + cacheWrite + output))
            }
        }
        let parsed = ParsedFile(stamp: stamp, entries: entries, lastContext: lastContext)
        cache[url.path] = parsed
        return parsed
    }

    func computeUsage(contextTranscript: String?) -> ClaudeUsage {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var entries: [Entry] = []
        var context: Int?
        var livePaths = Set<String>()

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let walker = fm.enumerator(at: Self.projectsDir, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = v.contentModificationDate, mtime > cutoff else { continue }
                let parsed = parse(url, stamp: "\(mtime.timeIntervalSince1970)-\(v.fileSize ?? 0)")
                livePaths.insert(url.path)
                entries += parsed.entries.filter { $0.time > cutoff }
                if url.path == contextTranscript { context = parsed.lastContext }
            }
        }
        cache = cache.filter { livePaths.contains($0.key) }

        // Blok 5 jam: dimulai pada jam bulat dari pesan pertama, berakhir 5 jam kemudian.
        let window: TimeInterval = 5 * 3600
        var blockStart: Date?
        var blockTokens = 0
        for e in entries.sorted(by: { $0.time < $1.time }) {
            if let start = blockStart, e.time < start.addingTimeInterval(window) {
                blockTokens += e.tokens
            } else {
                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: e.time)
                blockStart = Calendar.current.date(from: comps)
                blockTokens = e.tokens
            }
        }
        let resetAt = blockStart?.addingTimeInterval(window)
        if let resetAt, resetAt < Date() {
            return ClaudeUsage(blockTokens: 0, resetAt: nil, contextTokens: context)
        }
        return ClaudeUsage(blockTokens: blockTokens, resetAt: resetAt, contextTokens: context)
    }
}

// MARK: - Komponen UI

enum ClaudeStyle {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)   // terracotta khas Claude

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.0fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Logo bintang Claude; berputar pelan saat Claude sedang bekerja.
struct ClaudeMark: View {
    var size: CGFloat = 14
    var spinning = false
    var color: Color = ClaudeStyle.accent

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { ctx in
            let angle = spinning ? ctx.date.timeIntervalSinceReferenceDate * 60 : 0
            ZStack {
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: size * 0.15, height: size * 0.5)
                        .offset(y: -size * 0.23)
                        .rotationEffect(.degrees(Double(i) * 36))
                }
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    var color: Color = ClaudeStyle.accent

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
        .frame(width: 15, height: 15)
    }
}

/// Bar progress: determinate bila ada task list, selain itu shimmer yang bergerak.
struct ClaudeProgressBar: View {
    let fraction: Double?
    let color: Color
    let animating: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let fraction {
                    Capsule().fill(color)
                        .frame(width: max(5, w * fraction))
                        .animation(.smooth, value: fraction)
                } else if animating {
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: w * 0.35)
                            .offset(x: (w * 1.35) * t - w * 0.35)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

struct ClaudeCard: View {
    let session: ClaudeSession?
    let otherActive: Int
    let usage: ClaudeUsage?
    let now: Date

    private var statusText: String {
        guard let s = session else { return "Tidak ada sesi" }
        switch s.state {
        case "working": return "Bekerja"
        case "waiting": return "Menunggu kamu"
        case "done": return "Selesai"
        default: return "Diam"
        }
    }

    private var statusColor: Color {
        switch session?.state {
        case "working": return ClaudeStyle.accent
        case "waiting": return .orange
        case "done": return Palette.green
        default: return Palette.secondary
        }
    }

    private var progress: Double? {
        guard let s = session else { return nil }
        if s.state == "done" { return 1 }
        guard let p = s.planProgress else { return nil }
        return Double(p.done) / Double(p.total)
    }

    private var activityLine: String {
        guard let s = session else { return "Hook aktif · menunggu prompt berikutnya" }
        if s.isWaiting, let m = s.message, !m.isEmpty { return m }
        if s.isWorking, let tool = s.tool {
            return [tool, s.tool_detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var parts: [String] = []
        if let n = s.tool_count, n > 0 { parts.append("\(n) tool") }
        if let p = s.planProgress { parts.append("\(p.done)/\(p.total) langkah") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // Limit kini tampil di ClaudeUsageTile; di sini cukup ukuran konteks sesi.
    private var usageLine: String {
        guard let c = usage?.contextTokens else { return "" }
        return "ctx \(ClaudeStyle.tokens(c))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ClaudeMark(size: 13, spinning: session?.isWorking ?? false)
                Text(session?.displayName ?? "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.15), in: Capsule())
                if otherActive > 0 {
                    Text("+\(otherActive) sesi")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                if let e = session?.elapsed(now: now) {
                    Text(ClaudeStyle.duration(e))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }
            Text(session?.prompt?.isEmpty == false ? session!.prompt! : "Kirim prompt di Claude Code untuk mulai memantau.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
            ClaudeProgressBar(fraction: progress, color: statusColor,
                              animating: session?.isWorking ?? false)
            HStack {
                Text(activityLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(usageLine)
                    .lineLimit(1)
                    .help("Ukuran konteks sesi ini")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }
}
