import AppKit
import SwiftUI

// MARK: - Data

enum MediaApp: String, CaseIterable {
    case music, spotify

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var displayName: String { self == .music ? "Music" : "Spotify" }
}

/// Kapan notch melebar untuk media saat island tertutup.
enum MediaLiveMode: String, CaseIterable {
    case glance, always, off

    var title: String {
        switch self {
        case .glance: return "Sekilas saat mulai / berganti"
        case .always: return "Selama diputar"
        case .off: return "Mati"
        }
    }
}

enum MediaCommand: String {
    case playPause = "playpause"
    case next = "next track"
    case previous = "previous track"
}

struct NowPlaying: Equatable {
    /// nil = dari Now Playing sistem (YouTube di browser, dll.).
    var app: MediaApp?
    var sourceName: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var duration: Double
    var position: Double
    var fetchedAt: Date
    var artworkURL: String?
    var artwork: NSImage?
    /// Bundle app pemutar (dari Now Playing sistem); untuk ikon & membuka app-nya.
    var bundleID: String? = nil

    var sourceBundleID: String? { bundleID ?? app?.bundleID }

    /// Posisi diperkirakan antar-polling supaya progress bar bergerak halus.
    func position(at now: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + now.timeIntervalSince(fetchedAt))
    }
}

// MARK: - Monitor (AppleScript ke Music / Spotify)

/// macOS membatasi akses "Now Playing" sistem untuk app pihak ketiga,
/// jadi widget ini bertanya langsung ke Music dan Spotify lewat AppleScript.
final class MediaMonitor {
    private(set) var permissionDenied: MediaApp?
    private var scripts: [MediaApp: NSAppleScript] = [:]
    private var artworkKey = ""
    private var artwork: NSImage?

    private static let separator = "|~|"

    private static func source(for app: MediaApp) -> String {
        let sep = "\"\(separator)\""
        switch app {
        case .music:
            return """
            tell application id "com.apple.Music"
                set st to player state as string
                if st is "stopped" then return "stopped"
                set t to current track
                return st & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & ((duration of t) as string) & \(sep) & ((player position) as string)
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                set st to player state as string
                if st is "stopped" then return "stopped"
                set t to current track
                return st & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & (((duration of t) / 1000) as string) & \(sep) & ((player position) as string) & \(sep) & (artwork url of t)
            end tell
            """
        }
    }

    func poll() -> NowPlaying? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        // Hanya tanya app yang sudah jalan — `tell application` akan membuka app yang tertutup.
        let candidates = MediaApp.allCases.filter { running.contains($0.bundleID) }.compactMap(query)
        guard var np = candidates.first(where: \.isPlaying) ?? candidates.first else { return nil }

        let key = "\(np.sourceName)|\(np.title)|\(np.artist)|\(np.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(for: np, key: key)
        }
        np.artwork = artwork
        return np
    }

    private func query(_ app: MediaApp) -> NowPlaying? {
        if scripts[app] == nil { scripts[app] = NSAppleScript(source: Self.source(for: app)) }
        var error: NSDictionary?
        guard let result = scripts[app]?.executeAndReturnError(&error) else {
            // -1743: pengguna belum/tidak mengizinkan otomatisasi untuk app ini.
            if (error?[NSAppleScript.errorNumber] as? Int) == -1743 { permissionDenied = app }
            return nil
        }
        if permissionDenied == app { permissionDenied = nil }
        guard let text = result.stringValue, text != "stopped" else { return nil }

        let f = text.components(separatedBy: Self.separator)
        guard f.count >= 6 else { return nil }
        // Angka dari AppleScript bisa memakai koma desimal sesuai locale.
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(app: app, sourceName: app.displayName, title: f[1], artist: f[2], album: f[3],
                          isPlaying: f[0] == "playing", duration: num(f[4]), position: num(f[5]),
                          fetchedAt: Date(), artworkURL: f.count > 6 ? f[6] : nil, artwork: nil)
    }

    private func loadArtwork(for np: NowPlaying, key: String) {
        guard let app = np.app else { return }
        switch app {
        case .music:
            let script = NSAppleScript(source: "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track")
            if let data = script?.executeAndReturnError(nil).data {
                artwork = NSImage(data: data)
            }
        case .spotify:
            guard let urlString = np.artworkURL, let url = URL(string: urlString) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    if self?.artworkKey == key { self?.artwork = image }
                }
            }.resume()
        }
    }

    func send(_ command: MediaCommand, to app: MediaApp) {
        NSAppleScript(source: "tell application id \"\(app.bundleID)\" to \(command.rawValue)")?
            .executeAndReturnError(nil)
    }
}

// MARK: - Now Playing sistem (lewat /usr/bin/perl)

/// Membaca Now Playing sistem — semua pemutar, termasuk YouTube di browser — lewat
/// NowPlayingBridge.dylib yang dimuat ke dalam /usr/bin/perl (lihat NowPlayingBridge/).
/// Bila tidak tersedia, `latest` tetap nil dan widget kembali ke AppleScript.
final class SystemNowPlaying {
    private(set) var latest: NowPlaying?
    var onChange: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var artwork: NSImage?
    private var restartAt = Date.distantPast

    private static var lib: URL? { Bundle.main.resourceURL?.appendingPathComponent("NowPlayingBridge.dylib") }
    private static var script: URL? { Bundle.main.resourceURL?.appendingPathComponent("nowplaying.pl") }

    /// Idempoten: menyalakan stream bila belum jalan; menunggu 10 dtk setelah crash.
    func start() {
        guard process == nil, Date() >= restartAt,
              let lib = Self.lib, let script = Self.script,
              FileManager.default.fileExists(atPath: lib.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, lib.path, "stream"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.process = nil
                self?.latest = nil
                self?.restartAt = Date().addingTimeInterval(10)
            }
        }
        guard (try? p.run()) != nil else { restartAt = Date().addingTimeInterval(60); return }
        process = p
    }

    func stop() {
        process?.terminate()
        process = nil
        latest = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(obj) }
        }
        onChange?()
    }

    private func apply(_ o: [String: Any]) {
        if let art = o["artwork"] as? String {
            artwork = art.isEmpty ? nil : Data(base64Encoded: art).flatMap(NSImage.init(data:))
        }
        guard o["empty"] as? Bool != true, let title = o["title"] as? String else {
            latest = nil
            return
        }
        func num(_ key: String) -> Double { (o[key] as? NSNumber)?.doubleValue ?? 0 }
        let bundleID = o["bundleID"] as? String
        // Posisi dilaporkan pada `timestamp`; NowPlaying.position(at:) mengekstrapolasi dari sana.
        let stamp = (o["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        latest = NowPlaying(app: MediaApp.allCases.first { $0.bundleID == bundleID },
                            sourceName: o["appName"] as? String ?? "Now Playing",
                            title: title,
                            artist: o["artist"] as? String ?? "",
                            album: o["album"] as? String ?? "",
                            isPlaying: (o["playing"] as? Bool) ?? (num("rate") > 0),
                            duration: num("duration"),
                            position: num("elapsed"),
                            fetchedAt: stamp,
                            artworkURL: nil,
                            artwork: artwork,
                            bundleID: bundleID)
    }

    /// Perintah lewat MediaRemote — berlaku untuk pemutar apa pun yang sedang aktif.
    func send(_ command: MediaCommand) {
        guard let lib = Self.lib, let script = Self.script else { return }
        let id: String
        switch command {
        case .playPause: id = "2"
        case .next: id = "4"
        case .previous: id = "5"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, lib.path, "send", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - Warna & ikon

/// Warna aksen dari artwork (seperti widget musik di iOS): warna paling "hidup" di sampul,
/// dicerahkan secukupnya supaya terbaca di latar hitam.
enum ArtworkPalette {
    private static var cache: [ObjectIdentifier: NSColor] = [:]
    static let fallback = Color(red: 0.98, green: 0.62, blue: 0.35)

    static func accent(for image: NSImage?) -> Color {
        guard let image else { return fallback }
        let key = ObjectIdentifier(image)
        if let cached = cache[key] { return Color(nsColor: cached) }
        guard let color = dominant(in: image) else { return fallback }
        if cache.count > 30 { cache.removeAll() }
        cache[key] = color
        return Color(nsColor: color)
    }

    private static func dominant(in image: NSImage) -> NSColor? {
        // Konteks bitmap CG sendiri — tidak menyentuh NSGraphicsContext.current, karena fungsi ini
        // dipanggil di tengah render SwiftUI.
        let side = 12
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        func pixel(_ x: Int, _ y: Int) -> NSColor {
            let i = (y * side + x) * 4
            return NSColor(deviceRed: CGFloat(data[i]) / 255, green: CGFloat(data[i + 1]) / 255,
                           blue: CGFloat(data[i + 2]) / 255, alpha: 1)
        }

        var best: (score: CGFloat, color: NSColor)?
        var sum = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), n: CGFloat(0))
        for x in 0..<side {
            for y in 0..<side {
                let c = pixel(x, y)
                sum = (sum.r + c.redComponent, sum.g + c.greenComponent, sum.b + c.blueComponent, sum.n + 1)
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard b > 0.2 else { continue }
                let score = s * b
                if score > (best?.score ?? 0.08) { best = (score, c) }
            }
        }
        let base = best?.color ?? (sum.n > 0 ? NSColor(deviceRed: sum.r / sum.n, green: sum.g / sum.n, blue: sum.b / sum.n, alpha: 1) : nil)
        guard let base else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s, 0.35), 0.85), brightness: max(b, 0.82), alpha: 1)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let icon = standardRange(NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
        cache[bundleID] = icon
        return icon
    }

    /// Ikon file (untuk Shelf), juga dalam rentang warna standar.
    static func fileIcon(_ url: URL) -> NSImage {
        let key = "file:" + url.path
        if let cached = cache[key] { return cached }
        let raw = NSWorkspace.shared.icon(forFile: url.path)
        let icon = standardRange(raw) ?? raw
        if cache.count > 200 { cache.removeAll() }
        cache[key] = icon
        return icon
    }

    /// Gambar ulang ke bitmap sRGB 8-bit. Ikon macOS modern bisa berwarna extended/HDR, dan satu gambar
    /// HDR membuat SwiftUI menurunkan kecerahan seluruh tampilan di sekitarnya (putih jadi abu-abu).
    static func standardRange(_ image: NSImage, side: Int = 64) -> NSImage? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: rect)
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    static func open(_ bundleID: String?) {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - UI

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.1)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Bar equalizer kecil yang bergerak saat musik diputar.
struct EqualizerBars: View {
    let playing: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: Motion.frame, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i) * 1.3
                    let h = playing ? 4 + 8 * abs(sin(t * (3.2 + Double(i) * 0.7) + phase)) : 3
                    Capsule().fill(color).frame(width: 2.5, height: h)
                }
            }
            .frame(height: 12)
        }
    }
}

struct MediaCard: View {
    let nowPlaying: NowPlaying?
    let deniedApp: MediaApp?
    let now: Date
    let onCommand: (MediaCommand) -> Void

    private var accent: Color { ArtworkPalette.accent(for: nowPlaying?.artwork) }

    private func time(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Group {
            if let np = nowPlaying {
                player(np)
            } else {
                placeholder
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.4), value: nowPlaying?.title)
    }

    // Latar: tile gelap dengan pendaran warna artwork dari kiri.
    private var background: some View {
        ZStack {
            Palette.tile
            if nowPlaying?.artwork != nil {
                LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.06), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }

    private func player(_ np: NowPlaying) -> some View {
        let pos = np.position(at: now)
        let fraction = np.duration > 0 ? min(1, pos / np.duration) : 0
        return HStack(spacing: 14) {
            // Artwork besar + ikon app sumber di pojok (klik → buka app-nya).
            ArtworkView(image: np.artwork, size: 104, radius: 18)
                .overlay(alignment: .bottomTrailing) {
                    if let icon = AppIcons.icon(for: np.sourceBundleID) {
                        Button { AppIcons.open(np.sourceBundleID) } label: {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .padding(2)
                                .background(Circle().fill(Color.black.opacity(0.75)))
                        }
                        .buttonStyle(PressScaleStyle())
                        .padding(5)
                    }
                }
                .shadow(color: accent.opacity(0.45), radius: 14, y: 4)

            VStack(alignment: .leading, spacing: 0) {
                Text(np.title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(np.artist.isEmpty ? np.sourceName : np.artist)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .padding(.top, 2)

                Spacer(minLength: 6)

                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(accent).frame(width: max(5, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                    HStack {
                        Text(time(pos))
                        Spacer()
                        Text(np.duration > 0 ? time(np.duration) : "--:--")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.secondary)
                }

                Spacer(minLength: 6)

                HStack(spacing: 0) {
                    Spacer()
                    control("backward.fill", 16) { onCommand(.previous) }
                    Spacer()
                    control(np.isPlaying ? "pause.fill" : "play.fill", 26) { onCommand(.playPause) }
                    Spacer()
                    control("forward.fill", 16) { onCommand(.next) }
                    Spacer()
                }
            }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 18, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var placeholder: some View {
        HStack(spacing: 14) {
            ArtworkView(image: nil, size: 104, radius: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidak ada yang diputar")
                    .font(.system(size: 15, weight: .bold))
                if let app = deniedApp {
                    Text("Izinkan NotchIsland mengontrol \(app.displayName) di Pengaturan Sistem › Privasi & Keamanan › Otomatisasi.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text("Putar musik atau video di app mana pun — Spotify, Music, YouTube di browser.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}
