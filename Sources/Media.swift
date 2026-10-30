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
                            artwork: artwork)
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

    private func time(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Group {
            if let np = nowPlaying {
                player(np)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    private func player(_ np: NowPlaying) -> some View {
        let pos = np.position(at: now)
        let fraction = np.duration > 0 ? pos / np.duration : 0
        return HStack(spacing: 12) {
            ArtworkView(image: np.artwork, size: 76, radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(np.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(np.sourceName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                Text(np.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(time(pos))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.white).frame(width: geo.size.width * min(1, fraction))
                        }
                    }
                    .frame(height: 4)
                    Text("-" + time(np.duration - pos))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                HStack(spacing: 26) {
                    control("backward.fill", 13) { onCommand(.previous) }
                    control(np.isPlaying ? "pause.fill" : "play.fill", 17) { onCommand(.playPause) }
                    control("forward.fill", 13) { onCommand(.next) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var placeholder: some View {
        HStack(spacing: 12) {
            ArtworkView(image: nil, size: 76, radius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidak ada yang diputar")
                    .font(.system(size: 13, weight: .semibold))
                if let app = deniedApp {
                    Text("Izinkan NotchIsland mengontrol \(app.displayName) di Pengaturan Sistem › Privasi & Keamanan › Otomatisasi.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text("Putar musik atau video di app mana pun.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }
}
