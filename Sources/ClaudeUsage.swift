import Foundation
import SwiftUI

// MARK: - Usage resmi dari cache Claude Desktop
//
// Claude Desktop (Chromium) menyimpan response `GET /api/organizations/<id>/usage` —
// data yang sama dengan panel Usage-nya — di HTTP cache. Kita membaca entry itu:
// tanpa token, tanpa keychain, tanpa request ke Anthropic, dan tanpa menulis apa pun.
// Dari entry lain hanya header (URL) yang dibaca. Pendekatan dari Codenotch.

struct LimitWindow: Equatable, Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?

    var isSession: Bool { id.hasPrefix("session") || id.hasPrefix("five_hour") }

    /// Setelah lewat waktu reset, jendela ini sudah kosong lagi walau cache belum diperbarui.
    func percent(at now: Date) -> Double {
        if let r = resetsAt, r < now { return 0 }
        return percent
    }
}

struct OfficialUsage: Equatable {
    let windows: [LimitWindow]
    let capturedAt: Date

    var session: LimitWindow? { windows.first(where: \.isSession) ?? windows.first }
    /// Jendela dengan pemakaian tertinggi — angka utama di notch.
    var headline: LimitWindow? { windows.max { $0.percent < $1.percent } }
}

enum ClaudeDesktopUsage {
    static let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")

    // Batas kerja untuk direktori yang bukan milik kita dan bisa berisi ribuan entry.
    private static let headerBytes = 24
    private static let maxKeyBytes = 8 * 1024
    private static let maxEntryBytes = 512 * 1024
    private static let maxEntriesExamined = 400
    private static let maxBodyBytes = 256 * 1024
    private static let entryMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    private static let zstdMagic: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd]

    static func read() -> OfficialUsage? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }

        // `_0` = stream berisi body. Entry usage ditulis ulang tiap Desktop refresh,
        // jadi selalu ada di antara yang terbaru.
        let candidates: [(URL, Date)] = urls.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, size > headerBytes, size <= maxEntryBytes,
                  let mtime = v.contentModificationDate else { return nil }
            return (url, mtime)
        }
        for (url, mtime) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(maxEntriesExamined) {
            if let windows = windows(in: url), !windows.isEmpty {
                return OfficialUsage(windows: windows, capturedAt: mtime)
            }
        }
        return nil
    }

    private static func windows(in url: URL) -> [LimitWindow]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Tolak berdasarkan URL dulu; body hanya dibaca untuk endpoint usage.
        guard let head = try? handle.read(upToCount: headerBytes + maxKeyBytes),
              let key = key(in: [UInt8](head)), isUsageKey(key) else { return nil }
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.read(upToCount: maxEntryBytes) else { return nil }

        let bytes = [UInt8](data)
        let bodyStart = headerBytes + key.utf8.count
        guard bytes.count > bodyStart + zstdMagic.count,
              Array(bytes[bodyStart..<bodyStart + zstdMagic.count]) == zstdMagic,
              let body = decompress(Array(bytes[bodyStart...])) else { return nil }
        return parse(body)
    }

    private static func key(in bytes: [UInt8]) -> String? {
        guard bytes.count > headerBytes, readLE(bytes, 0, 8) == entryMagic else { return nil }
        let length = Int(readLE(bytes, 12, 4))
        guard length > 0, length <= maxKeyBytes, headerBytes + length <= bytes.count else { return nil }
        return String(bytes: bytes[headerBytes..<headerBytes + length], encoding: .utf8)
    }

    /// Persis `/api/organizations/<id>/usage` (query apa pun diabaikan).
    private static func isUsageKey(_ key: String) -> Bool {
        guard key.contains("claude.ai") || key.contains("anthropic.com"),
              let r = key.range(of: "/api/organizations/") else { return false }
        let path = key[r.upperBound...].prefix { $0 != "?" && $0 != "#" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.count == 2 && !segments[0].isEmpty && segments[1] == "usage"
    }

    private static func readLE(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reversed().reduce(0) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func decompress(_ frame: [UInt8]) -> Data? {
        frame.withUnsafeBytes { src -> Data? in
            let size = ZSTD_findFrameCompressedSize(src.baseAddress, src.count)
            guard ZSTD_isError(size) == 0, size > 0, size <= src.count else { return nil }
            var out = [UInt8](repeating: 0, count: maxBodyBytes)
            let written = out.withUnsafeMutableBytes { dst in
                ZSTD_decompress(dst.baseAddress, dst.count, src.baseAddress, size)
            }
            guard ZSTD_isError(written) == 0, written > 0 else { return nil }
            return Data(out[0..<written])
        }
    }

    // MARK: JSON

    private static func parse(_ body: Data) -> [LimitWindow]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        var windows: [LimitWindow] = []

        // Bentuk baru: array `limits` generik.
        for l in obj["limits"] as? [[String: Any]] ?? [] {
            guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
            let kind = l["kind"] as? String ?? "limit"
            let scope = l["scope"] as? String
            windows.append(LimitWindow(id: [kind, scope].compactMap { $0 }.joined(separator: ":"),
                                       title: title(kind: kind, scope: scope),
                                       percent: pct, resetsAt: date(l["resets_at"])))
        }

        // Bentuk lama: objek per jendela dengan `utilization`.
        if windows.isEmpty {
            let named = [("five_hour", "Sesi saat ini"), ("seven_day", "Mingguan · semua model"),
                         ("seven_day_opus", "Mingguan · Opus"), ("seven_day_sonnet", "Mingguan · Sonnet")]
            for (key, title) in named {
                guard let w = obj[key] as? [String: Any],
                      let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows.append(LimitWindow(id: key, title: title, percent: u, resetsAt: date(w["resets_at"])))
            }
        }
        return windows
    }

    private static func title(kind: String, scope: String?) -> String {
        let base: String
        switch kind {
        case "session": base = "Sesi saat ini"
        case "weekly", "seven_day": base = "Mingguan"
        default: base = kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
        guard let scope, !scope.isEmpty else { return base }
        return "\(base) · \(scope.capitalized)"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `2026-10-29T12:49:59.556661+00:00` — pecahan detik 6 digit dibuang dulu.
    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: trimmed)
    }
}

// MARK: - UI

enum UsageStyle {
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.31, blue: 0.12)

    /// Hijau → kuning → merah, seperti ring Codenotch.
    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return Palette.green
        case ..<80: return yellow
        default: return red
        }
    }

    static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "Sudah reset" }
        if s < 3600 { return "Reset \(max(1, s / 60)) mnt" }
        if s < 24 * 3600 { return "Reset \(s / 3600) j \(s / 60 % 60) mnt" }
        return "Reset " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func ageText(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 120 { return "live" }
        if s < 3600 { return "\(s / 60) mnt lalu" }
        return "\(s / 3600) j lalu"
    }
}

/// Ring persentase limit. `busy`: arc putih berputar di dalam; `waiting`: ring oranye berdenyut.
struct UsageRing: View {
    let percent: Double
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var busy = false
    var waiting = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                .stroke(UsageStyle.color(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: percent)
            if busy || waiting {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    if waiting {
                        Circle()
                            .stroke(Color.orange.opacity(0.35 + 0.65 * abs(sin(t * 2.5))), lineWidth: lineWidth)
                    } else {
                        Circle()
                            .trim(from: 0, to: 0.28)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .padding(lineWidth + 1.5)
                            .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Kartu usage (Claude, Antigravity, …): bar per jendela limit + waktu reset.
struct UsageTile<Icon: View>: View {
    let title: String
    let icon: Icon
    let usage: OfficialUsage?
    /// Dua baris yang tampil bila belum ada data limit.
    let placeholder: (String, String)
    let now: Date
    /// Judul berbentuk "Grup · Jendela" ditampilkan per grup, semua jendela dalam bar ringkas.
    var grouped = false
    /// Perkiraan limit habis per jendela; bila ada, menggantikan teks reset.
    var eta: ((LimitWindow) -> Date?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                icon
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if let u = usage {
                    let age = UsageStyle.ageText(u.capturedAt, now: now)
                    Text(age)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(age == "live" ? Palette.green : Palette.secondary)
                }
            }
            if let u = usage, grouped {
                groupedRows(u.windows)
            } else if let u = usage {
                ForEach(u.windows.prefix(2)) { row($0) }
            } else {
                Text(placeholder.0)
                    .font(.system(size: 10, weight: .medium))
                Text(placeholder.1)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    private func split(_ title: String) -> (group: String, label: String) {
        let parts = title.components(separatedBy: " · ")
        return parts.count > 1 ? (parts[0], parts.dropFirst().joined(separator: " · ")) : ("", title)
    }

    /// Per grup: nama grup, lalu jendela-jendelanya berdampingan (urut: 5 jam dulu).
    private func groupedRows(_ windows: [LimitWindow]) -> some View {
        var order: [String] = []
        var byGroup: [String: [LimitWindow]] = [:]
        for w in windows {
            let g = split(w.title).group
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(w)
        }
        let rank: (LimitWindow) -> TimeInterval = { $0.resetsAt?.timeIntervalSince1970 ?? .infinity }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(order.sorted { ($0.hasPrefix("Gemini") ? 0 : 1, $0) < ($1.hasPrefix("Gemini") ? 0 : 1, $1) },
                    id: \.self) { g in
                VStack(alignment: .leading, spacing: 3) {
                    if !g.isEmpty {
                        Text(g)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.secondary)
                    }
                    HStack(spacing: 10) {
                        ForEach(byGroup[g]!.sorted { rank($0) < rank($1) }) { miniBar($0) }
                    }
                }
            }
        }
    }

    private func miniBar(_ w: LimitWindow) -> some View {
        let p = w.percent(at: now)
        return HStack(spacing: 4) {
            Text(split(w.title).label)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(UsageStyle.color(p))
                        .frame(width: max(3, geo.size.width * min(1, p / 100)))
                }
            }
            .frame(height: 4)
            Text("\(Int(p.rounded()))%")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
        }
        .help("\(w.title) · \(UsageStyle.resetText(w.resetsAt, now: now))"
              + (eta?(w).map { " · habis ±" + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
    }

    private func row(_ w: LimitWindow) -> some View {
        let p = w.percent(at: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(w.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let e = eta?(w) {
                    Text("Habis ±" + e.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UsageStyle.color(p))
                        .lineLimit(1)
                        .help(UsageStyle.resetText(w.resetsAt, now: now))
                } else {
                    Text(UsageStyle.resetText(w.resetsAt, now: now))
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(UsageStyle.color(p))
                            .frame(width: max(4, geo.size.width * min(1, p / 100)))
                    }
                }
                .frame(height: 4)
                Text("\(Int(p.rounded()))%")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }
}
