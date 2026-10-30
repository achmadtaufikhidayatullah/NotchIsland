import AppKit
import SwiftUI
import Combine
import ServiceManagement
import IOKit.ps
import CoreAudio
import AudioToolbox

// MARK: - Deteksi notch & device

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize      // ukuran notch fisik (atau virtual bila tidak ada notch)
    var hasPhysicalNotch: Bool
    var screenName: String
    var displayID: CGDirectDisplayID

    /// Rect notch dalam koordinat global AppKit (origin kiri-bawah).
    var notchRect: CGRect {
        CGRect(x: screenFrame.midX - notchSize.width / 2,
               y: screenFrame.maxY - notchSize.height,
               width: notchSize.width, height: notchSize.height)
    }
}

enum DeviceInfo {
    static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Nama marketing dari System Information (contoh: "MacBook Pro (14-inch, Nov 2023)").
    static let marketingName: String = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/com.apple.SystemProfiler.plist")
        if let dict = NSDictionary(contentsOf: url),
           let names = dict["CPU Names"] as? [String: String],
           let name = names.values.first {
            return name
        }
        return Host.current().localizedName ?? "Mac"
    }()
}

enum NotchDetector {
    /// Pilih layar yang punya notch; kalau tidak ada, pakai layar utama.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func detect(on screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()

        // macOS 12+: area kiri & kanan notch disediakan oleh sistem → lebar notch presisi.
        if top > 0, !simulateNoNotch,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(screenFrame: frame,
                                 notchSize: CGSize(width: width, height: top),
                                 hasPhysicalNotch: true,
                                 screenName: screen.localizedName,
                                 displayID: displayID)
        }

        // Layar tanpa notch (monitor eksternal / Mac lama): buat "pulau" virtual setinggi menu bar.
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: frame,
                             notchSize: CGSize(width: 190, height: menuBarHeight),
                             hasPhysicalNotch: false,
                             screenName: screen.localizedName,
                             displayID: displayID)
    }
}

// MARK: - Kontrol sistem

enum SystemVolume {
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    static func get() -> Float? {
        guard let dev = defaultOutputDevice() else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(dev, &volumeAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func set(_ value: Float) {
        guard let dev = defaultOutputDevice() else { return }
        var v = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(dev, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

/// Brightness layar built-in lewat DisplayServices (framework privat, di-load dinamis).
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) {
        _ = setFn?(display, min(max(value, 0), 1))
    }
}

struct BatteryState: Equatable {
    var level: Int
    var charging: Bool
    var onAC: Bool

    static func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return BatteryState(level: cap,
                                charging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                                onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

// MARK: - State

final class NotchModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var expanded = false
    @Published var now = Date()
    @Published var battery: BatteryState? = nil
    @Published var chargeAlert = false
    /// App terdepan sedang full-screen di layar island.
    @Published var fullscreenActive = false
    @Published var volume: Float? = nil
    @Published var brightness: Float? = nil
    @Published var claudeSessions: [ClaudeSession] = []
    @Published var claudeUsage: ClaudeUsage? = nil
    @Published var claudeFlashDone = false
    @Published var officialUsage: OfficialUsage? = nil
    @Published var agActivity: AgentActivity? = nil
    @Published var agQuota: OfficialUsage? = nil
    @Published var agRunning = false
    @Published var agFlashDone = false
    @Published var alwaysShowUsage: Bool {
        didSet { UserDefaults.standard.set(alwaysShowUsage, forKey: "alwaysShowUsage") }
    }
    @Published var nowPlaying: NowPlaying? = nil
    @Published var mediaFlash = false
    @Published var limitAlert: LimitAlert? = nil
    @Published var terminalAlert: TerminalEvent? = nil
    @Published var terminalAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(terminalAlertsEnabled, forKey: "terminalAlerts") }
    }
    @Published var mediaLiveMode: MediaLiveMode {
        didSet { UserDefaults.standard.set(mediaLiveMode.rawValue, forKey: "mediaLiveMode") }
    }
    @Published var mediaDenied: MediaApp? = nil
    @Published var selectedWidget: WidgetKind = .claude
    @Published var enabledWidgets: [WidgetKind] {
        didSet {
            UserDefaults.standard.set(enabledWidgets.map(\.rawValue), forKey: "enabledWidgets")
            if !enabledWidgets.contains(selectedWidget) { selectedWidget = enabledWidgets.first ?? .claude }
        }
    }
    @Published var soundOnClaudeDone: Bool {
        didSet { UserDefaults.standard.set(soundOnClaudeDone, forKey: "soundOnClaudeDone") }
    }

    /// Tinggi pulau mengikuti widget yang sedang dipilih.
    var expandedSize: CGSize {
        let content = enabledWidgets.isEmpty ? 40 : selectedWidget.contentHeight
        return CGSize(width: 500, height: geometry.notchSize.height + 24 + content)
    }
    var maxExpandedSize: CGSize {
        CGSize(width: 500, height: geometry.notchSize.height + 24 + WidgetKind.maxContentHeight)
    }
    private var timer: Timer?
    private let media = MediaMonitor()
    let systemMedia = SystemNowPlaying()
    private let launchedAt = Date()
    private var lastMediaKey: String?
    private var mediaWasPlaying = false
    private var mediaFlashWork: DispatchWorkItem?
    private let limitWatcher = LimitWatcher()
    private var limitQueue: [LimitAlert] = []
    private var terminalQueue: [TerminalEvent] = []
    private var alertWork: DispatchWorkItem?
    private let claude = ClaudeMonitor()
    private let claudeQueue = DispatchQueue(label: "notchisland.claude", qos: .utility)
    private var claudeFlashWork: DispatchWorkItem?
    private var lastUsageAt = Date.distantPast
    private let antigravity = AntigravityMonitor()
    private var agFlashWork: DispatchWorkItem?
    private var lastAgQuotaAt = Date.distantPast

    /// Sesi yang ditampilkan: yang sedang aktif lebih dulu, lalu yang terakhir diperbarui.
    var primaryClaude: ClaudeSession? { claudeSessions.first(where: \.isActive) ?? claudeSessions.first }
    var activeClaudeCount: Int { claudeSessions.filter(\.isActive).count }

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        let defaults = UserDefaults.standard
        var widgets = defaults.stringArray(forKey: "enabledWidgets")?.compactMap(WidgetKind.init(rawValue:))
            ?? WidgetKind.defaultEnabled
        // Widget Antigravity ikut aktif sekali untuk pengaturan yang sudah tersimpan.
        if !defaults.bool(forKey: "addedAntigravity") {
            defaults.set(true, forKey: "addedAntigravity")
            let current = widgets
            widgets = WidgetKind.allCases.filter { current.contains($0) || $0 == .antigravity }
            defaults.set(widgets.map(\.rawValue), forKey: "enabledWidgets")
        }
        enabledWidgets = widgets
        soundOnClaudeDone = defaults.object(forKey: "soundOnClaudeDone") as? Bool ?? true
        // Default: notch hanya melebar saat Claude bekerja / menunggu / baru selesai.
        alwaysShowUsage = defaults.object(forKey: "alwaysShowUsage") as? Bool ?? false
        terminalAlertsEnabled = defaults.object(forKey: "terminalAlerts") as? Bool ?? true
        mediaLiveMode = defaults.string(forKey: "mediaLiveMode").flatMap(MediaLiveMode.init(rawValue:)) ?? .glance
        selectedWidget = enabledWidgets.first ?? .claude
        battery = BatteryState.read()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        observePowerSource()
    }

    func refresh() {
        now = Date()
        battery = BatteryState.read()
        let fullscreen = FullScreenDetector.isActive(on: geometry.screenFrame)
        if fullscreen != fullscreenActive { fullscreenActive = fullscreen }
        refreshClaude()
        refreshAntigravity()
        refreshMedia()
        checkLimits()
        checkTerminal()
    }

    // MARK: Notifikasi command terminal

    private func checkTerminal() {
        let events = TerminalWatcher.drain()   // selalu dikosongkan supaya file tidak menumpuk
        guard terminalAlertsEnabled, !events.isEmpty else { return }
        terminalQueue += events.suffix(3)
        showNextTerminalAlert()
    }

    private func showNextTerminalAlert() {
        guard terminalAlert == nil, !terminalQueue.isEmpty else { return }
        let event = terminalQueue.removeFirst()
        terminalAlert = event
        // Tanpa bunyi bila terminalnya sedang di depan — kamu sudah melihatnya.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if soundOnClaudeDone, front != event.appBundleID {
            NSSound(named: event.succeeded ? "Tink" : "Basso")?.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard self?.terminalAlert == event else { return }
            self?.dismissTerminalAlert()
        }
    }

    private func dismissTerminalAlert() {
        terminalAlert = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showNextTerminalAlert() }
    }

    // MARK: Membuka app agent

    func openAgent(_ kind: WidgetKind) {
        switch kind {
        case .antigravity:
            AntigravityApp.open()
        default:
            // App tempat sesi berjalan; Claude Desktop sebagai cadangan.
            let id = primaryClaude?.appBundleID ?? "com.anthropic.claudefordesktop"
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    /// Lebar sayap live activity yang bisa diklik (kiri/kanan notch), nil bila tidak ada.
    /// Mengikuti lebar tampilan supaya ikon menu bar di luar sayap tetap bisa diklik.
    var clickableWing: CGFloat? {
        // Island disembunyikan saat full-screen di layar tanpa notch → jangan tangkap klik.
        if !geometry.hasPhysicalNotch, fullscreenActive { return nil }
        if terminalAlert != nil { return 140 }
        if limitAlert != nil || chargeAlert { return nil }
        let claudeOn = enabledWidgets.contains(.claude), agOn = enabledWidgets.contains(.antigravity)
        if (claudeOn && primaryClaude?.isWaiting == true) || (agOn && agActivity?.state == .waiting) { return 130 }
        if (claudeOn && (claudeFlashDone || primaryClaude?.isWorking == true))
            || (agOn && (agFlashDone || agActivity?.state == .busy)) { return 72 }
        return nil
    }

    var hasClickableCompact: Bool { clickableWing != nil }

    func openTerminalAlert() {
        guard let event = terminalAlert else { return }
        TerminalWatcher.open(event)
        dismissTerminalAlert()
    }

    func testTerminalAlerts() {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        terminalQueue += [
            TerminalEvent(id: "test-ok", command: "npm run build", exitCode: 0, duration: 102,
                          cwd: NSHomeDirectory(), termProgram: "", bundleID: bundle),
            TerminalEvent(id: "test-fail", command: "pnpm test --run", exitCode: 1, duration: 47,
                          cwd: NSHomeDirectory(), termProgram: "", bundleID: bundle),
        ]
        showNextTerminalAlert()
    }

    // MARK: Peringatan limit

    private func checkLimits() {
        var alerts: [LimitAlert] = []
        if enabledWidgets.contains(.claude), let u = officialUsage {
            alerts += limitWatcher.observe(provider: .claude, usage: u, now: now)
        }
        if enabledWidgets.contains(.antigravity), let u = agQuota {
            alerts += limitWatcher.observe(provider: .antigravity, usage: u, now: now)
        }
        limitQueue += alerts
        showNextLimitAlert()
    }

    /// Perkiraan limit habis untuk satu jendela (nil = aman sampai reset / data kurang).
    func limitETA(_ provider: WidgetKind, _ window: LimitWindow) -> Date? {
        limitWatcher.projection(provider: provider, window: window)
    }

    /// Peringatan tampil satu per satu, masing-masing 5 detik.
    private func showNextLimitAlert() {
        guard limitAlert == nil, !limitQueue.isEmpty else { return }
        let alert = limitQueue.removeFirst()
        limitAlert = alert
        if soundOnClaudeDone {
            switch alert.kind {
            case .threshold(let t): NSSound(named: t >= 95 ? "Sosumi" : "Ping")?.play()
            case .reset: NSSound(named: "Hero")?.play()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.limitAlert = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.showNextLimitAlert() }
        }
    }

    func testLimitAlerts() {
        let w = officialUsage?.session
        limitQueue += [
            LimitAlert(provider: .claude, title: w?.title ?? "Sesi saat ini", percent: 82, kind: .threshold(80),
                       eta: Date().addingTimeInterval(52 * 60)),
            LimitAlert(provider: .antigravity, title: "Gemini · 5 jam", percent: 3, kind: .reset, eta: nil),
        ]
        showNextLimitAlert()
    }

    func toggleWidget(_ kind: WidgetKind) {
        var set = Set(enabledWidgets)
        if set.contains(kind) { set.remove(kind) } else { set.insert(kind) }
        enabledWidgets = WidgetKind.allCases.filter(set.contains)
    }

    /// Saat pulau dibuka, langsung tampilkan widget yang sedang "hidup".
    func autoSelectWidget() {
        if enabledWidgets.contains(.claude), primaryClaude?.isActive == true {
            selectedWidget = .claude
        } else if enabledWidgets.contains(.antigravity), let a = agActivity, a.state != .idle {
            selectedWidget = .antigravity
        } else if enabledWidgets.contains(.media), nowPlaying?.isPlaying == true {
            selectedWidget = .media
        }
    }

    private func refreshMedia() {
        guard enabledWidgets.contains(.media) else {
            systemMedia.stop()
            if nowPlaying != nil { nowPlaying = nil }
            return
        }
        // Now Playing sistem dulu (semua pemutar); AppleScript Music/Spotify sebagai cadangan.
        systemMedia.onChange = { [weak self] in self?.applySystemMedia() }
        systemMedia.start()
        nowPlaying = systemMedia.latest ?? media.poll()
        observeMediaChange()
        if mediaDenied != media.permissionDenied { mediaDenied = media.permissionDenied }
    }

    private func applySystemMedia() {
        guard enabledWidgets.contains(.media), let np = systemMedia.latest else { return }
        nowPlaying = np
        observeMediaChange()
    }

    /// Mode "sekilas": melebar 4 detik saat media mulai diputar atau berganti judul.
    private func observeMediaChange() {
        let key = nowPlaying.map { "\($0.sourceName)|\($0.title)|\($0.artist)" }
        let playing = nowPlaying?.isPlaying == true
        defer { lastMediaKey = key; mediaWasPlaying = playing }
        // Data awal saat app baru dibuka bukan "mulai diputar".
        guard playing, Date().timeIntervalSince(launchedAt) > 3,
              !mediaWasPlaying || key != lastMediaKey else { return }
        mediaFlashWork?.cancel()
        mediaFlash = true
        let work = DispatchWorkItem { [weak self] in self?.mediaFlash = false }
        mediaFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func sendMedia(_ command: MediaCommand) {
        if systemMedia.latest != nil {
            systemMedia.send(command)
        } else if let app = nowPlaying?.app {
            media.send(command, to: app)
            refreshMedia()
        }
    }

    private func refreshClaude() {
        let sessions = claude.readSessions()
        let finished = sessions.contains { s in
            s.state == "done" && claudeSessions.contains { $0.session_id == s.session_id && $0.isWorking }
        }
        if sessions != claudeSessions { claudeSessions = sessions }
        if finished {
            showClaudeDone()
            lastUsageAt = .distantPast       // hitung ulang usage setelah prompt selesai
        }

        // Parsing transcript lebih berat → di background, tiap 15 detik.
        guard now.timeIntervalSince(lastUsageAt) > 15 else { return }
        lastUsageAt = now
        let transcript = primaryClaude?.transcript_path
        claudeQueue.async { [weak self, claude] in
            let usage = claude.computeUsage(contextTranscript: transcript)
            let official = ClaudeDesktopUsage.read()
            DispatchQueue.main.async {
                self?.claudeUsage = usage
                if let official { self?.officialUsage = official }
            }
        }
    }

    private func refreshAntigravity() {
        guard enabledWidgets.contains(.antigravity) else { return }
        let activity = antigravity.poll(now: now)
        let wasActive = agActivity.map { $0.state != .idle } ?? false
        if activity != agActivity { agActivity = activity }
        if wasActive, let a = activity, a.state == .idle, !a.stalled { showAgDone() }

        // Kuota lewat ps + lsof + request lokal → di background; lebih sering saat bekerja.
        let interval: TimeInterval = activity?.state == .busy ? 30 : 60
        guard now.timeIntervalSince(lastAgQuotaAt) > interval else { return }
        lastAgQuotaAt = now
        claudeQueue.async { [weak self] in
            let quota = AntigravityQuota.fetch()
            let running = quota != nil || AntigravityQuota.isRunning()
            DispatchQueue.main.async {
                self?.agRunning = running
                if let quota { self?.agQuota = quota }
            }
        }
    }

    private func showAgDone() {
        agFlashWork?.cancel()
        agFlashDone = true
        if soundOnClaudeDone { NSSound(named: "Glass")?.play() }
        let work = DispatchWorkItem { [weak self] in self?.agFlashDone = false }
        agFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func showClaudeDone() {
        guard enabledWidgets.contains(.claude) else { return }
        claudeFlashWork?.cancel()
        claudeFlashDone = true
        if soundOnClaudeDone { NSSound(named: "Glass")?.play() }   // bunyi "ding" bawaan macOS
        let work = DispatchWorkItem { [weak self] in self?.claudeFlashDone = false }
        claudeFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func refreshControls() {
        volume = SystemVolume.get()
        brightness = DisplayBrightness.get(geometry.displayID)
    }

    func setVolume(_ v: Float) {
        volume = v
        SystemVolume.set(v)
    }

    func setBrightness(_ v: Float) {
        brightness = v
        DisplayBrightness.set(geometry.displayID, v)
    }

    // Notifikasi instan dari IOKit saat sumber daya berubah (colok / cabut charger).
    private func observePowerSource() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<NotchModel>.fromOpaque(ctx).takeUnretainedValue().powerSourceChanged()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func powerSourceChanged() {
        let wasOnAC = battery?.onAC ?? false
        battery = BatteryState.read()
        if let b = battery, b.onAC, !wasOnAC { showChargeAlert() }
    }

    func showChargeAlert() {
        alertWork?.cancel()
        chargeAlert = true
        let work = DispatchWorkItem { [weak self] in self?.chargeAlert = false }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Bentuk notch (telinga atas cekung, sudut bawah continuous ala Apple)

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = bottomRadius
        let k: CGFloat = 0.62   // tarikan kurva kubik → lengkung halus mendekati squircle
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                   control1: CGPoint(x: rect.minX + t * k, y: rect.minY),
                   control2: CGPoint(x: rect.minX + t, y: rect.minY + t * (1 - k)))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * (1 - k)),
                   control2: CGPoint(x: rect.minX + t + b * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                   control1: CGPoint(x: rect.maxX - t - b * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * (1 - k)))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * (1 - k)),
                   control2: CGPoint(x: rect.maxX - t * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Komponen UI

enum Palette {
    static let green = Color(red: 0.20, green: 0.84, blue: 0.29)
    static let red = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let secondary = Color.white.opacity(0.55)
    static let tile = Color.white.opacity(0.07)
}

/// Spring khas Dynamic Island: cepat, sedikit memantul.
let islandSpring = Animation.spring(response: 0.42, dampingFraction: 0.8)

struct FolderShortcut: Identifiable {
    let name: String
    let icon: String
    let url: URL
    var id: String { name }

    static let all: [FolderShortcut] = {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory, _ mask: FileManager.SearchPathDomainMask = .userDomainMask) -> URL {
            fm.urls(for: d, in: mask).first ?? fm.homeDirectoryForCurrentUser
        }
        return [
            FolderShortcut(name: "Home", icon: "house.fill", url: fm.homeDirectoryForCurrentUser),
            FolderShortcut(name: "Desktop", icon: "menubar.dock.rectangle", url: dir(.desktopDirectory)),
            FolderShortcut(name: "Dokumen", icon: "doc.fill", url: dir(.documentDirectory)),
            FolderShortcut(name: "Unduhan", icon: "arrow.down", url: dir(.downloadsDirectory)),
            FolderShortcut(name: "Aplikasi", icon: "square.grid.2x2.fill", url: dir(.applicationDirectory, .localDomainMask)),
        ]
    }()
}

struct BatteryGlyph: View {
    let level: Int
    let charging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, 21 * CGFloat(level) / 100))
                    .padding(2)
            }
            .frame(width: 25, height: 12)
            .overlay {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }
}

/// Slider kapsul tebal seperti di Control Center: isi putih, ikon berubah warna saat tertutup isian.
struct CapsuleSlider: View {
    let value: Double
    let icon: String
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = w * value
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Rectangle().fill(Color.white).frame(width: fill)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fill > 32 ? Color.black.opacity(0.75) : Color.white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                    .padding(.leading, 10)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(min(max(g.location.x / w, 0), 1))
            })
        }
        .frame(height: 30)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

final class HoverState: ObservableObject {
    @Published var on = false
}

struct ShortcutButton: View {
    let item: FolderShortcut
    @StateObject private var hover = HoverState()

    var body: some View {
        Button { NSWorkspace.shared.open(item.url) } label: {
            VStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(hover.on ? 0.2 : 0.1)))
                Text(item.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover.on = h } }
    }
}

extension View {
    func tile() -> some View {
        padding(12)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - View

struct NotchView: View {
    @ObservedObject var model: NotchModel

    private var g: NotchGeometry { model.geometry }
    private var topR: CGFloat { model.expanded ? 14 : 6 }
    /// Live activity saat pulau tertutup, urut prioritas.
    private enum Agent: Equatable { case claude, antigravity }
    private enum Compact: Equatable { case none, charge, limit(LimitAlert), terminal(TerminalEvent), done(Agent), waiting(Agent), working(Agent), media, claudeIdle }

    private var compact: Compact {
        if model.chargeAlert { return .charge }
        if let alert = model.limitAlert { return .limit(alert) }
        if let event = model.terminalAlert { return .terminal(event) }
        let claudeOn = model.enabledWidgets.contains(.claude)
        let agOn = model.enabledWidgets.contains(.antigravity)
        let claude = claudeOn ? model.primaryClaude : nil
        let ag = agOn ? model.agActivity : nil
        if claudeOn, model.claudeFlashDone { return .done(.claude) }
        if agOn, model.agFlashDone { return .done(.antigravity) }
        if claude?.isWaiting == true { return .waiting(.claude) }
        if ag?.state == .waiting { return .waiting(.antigravity) }
        if claude?.isWorking == true { return .working(.claude) }
        if ag?.state == .busy { return .working(.antigravity) }
        if model.enabledWidgets.contains(.media), model.nowPlaying?.isPlaying == true,
           model.mediaLiveMode == .always || (model.mediaLiveMode == .glance && model.mediaFlash) {
            return .media
        }
        // Opsional: ring usage Claude tetap terlihat walau diam.
        if claudeOn, model.alwaysShowUsage, model.officialUsage?.session != nil { return .claudeIdle }
        return .none
    }

    private var compactAgent: Agent? {
        switch compact {
        case .done(let a), .waiting(let a), .working(let a): return a
        case .claudeIdle: return .claude
        default: return nil
        }
    }

    /// Jendela limit yang ditampilkan di notch untuk agent tertentu.
    private func headline(_ agent: Agent) -> LimitWindow? {
        agent == .claude ? model.officialUsage?.session : model.agQuota?.headline
    }

    // Lebar tambahan kiri/kanan notch untuk live activity.
    private var wing: CGFloat {
        switch compact {
        case .none: return 0
        case .charge: return 104
        case .limit: return 116
        case .waiting: return 130
        case .terminal: return 140
        case .media: return 64
        default: return compactAgent.flatMap(headline) != nil ? 72 : 64
        }
    }

    private var size: CGSize {
        if model.expanded { return model.expandedSize }
        return CGSize(width: g.notchSize.width + topR * 2 + wing * 2, height: g.notchSize.height)
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(.blurReplace)
                .combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(islandSpring.delay(0.05)),
            removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    /// Di layar tanpa notch, pil hitam permanen akan menutupi konten (tab browser, judul jendela),
    /// jadi island hanya terlihat saat ada live activity atau sedang dibuka — dan tidak saat full-screen.
    private var invisible: Bool {
        guard !model.expanded, !g.hasPhysicalNotch else { return false }
        return compact == .none || model.fullscreenActive
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: topR,
                           bottomRadius: model.expanded ? 32 : (compact == .none ? 10 : 14))
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.expanded ? 0.35 : 0), radius: 18, y: 8)

                if model.expanded {
                    expandedContent
                        .padding(.horizontal, topR)
                        .transition(contentTransition)
                } else if compact == .charge {
                    chargeAlertContent
                        .transition(contentTransition)
                } else if compact == .media {
                    mediaCompactContent
                        .transition(contentTransition)
                } else if case .terminal(let event) = compact {
                    terminalCompactContent(event)
                        .transition(contentTransition)
                } else if case .limit(let alert) = compact {
                    limitCompactContent(alert)
                        .transition(contentTransition)
                } else if let agent = compactAgent {
                    agentCompactContent(agent)
                        .transition(contentTransition)
                }
            }
            .frame(width: size.width, height: size.height)
            .opacity(invisible ? 0 : 1)
            .scaleEffect(invisible ? 0.85 : 1, anchor: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(islandSpring, value: invisible)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(islandSpring, value: model.expanded)
        .animation(islandSpring, value: compact)
        .animation(islandSpring, value: model.selectedWidget)
    }

    // Live activity musik: artwork di kiri notch, equalizer di kanan.
    private var mediaCompactContent: some View {
        HStack {
            ArtworkView(image: model.nowPlaying?.artwork, size: 20, radius: 5)
            Spacer()
            EqualizerBars(playing: model.nowPlaying?.isPlaying ?? false)
        }
        .padding(.horizontal, topR + 12)
        .frame(height: g.notchSize.height)
    }

    // Live activity agent: logo di kiri notch, persen limit + ring (atau status) di kanan.
    private func agentCompactContent(_ agent: Agent) -> some View {
        let done = compact == .done(agent)
        let waiting = compact == .waiting(agent)
        let working = compact == .working(agent)
        return HStack {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.green)
            } else if agent == .claude {
                ClaudeMark(size: 14, spinning: working, color: waiting ? .orange : ClaudeStyle.accent)
            } else {
                AntigravityMark(size: 14, active: working, tint: waiting ? .orange : nil)
            }
            if waiting {
                waitingCompact(agent)
            } else {
                Spacer()
            }
            if waiting {
                EmptyView()
            } else if let window = headline(agent) {
                // Arc berputar saat bekerja, ring oranye berdenyut saat menunggu.
                let p = window.percent(at: model.now)
                HStack(spacing: 6) {
                    Text("\(Int(p.rounded()))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    UsageRing(percent: p, size: 18, busy: working, waiting: waiting)
                }
            } else if done {
                Text("Selesai")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.green)
            } else if waiting {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if agent == .claude, let p = model.primaryClaude?.planProgress {
                ProgressRing(fraction: Double(p.done) / Double(p.total))
            } else if let e = elapsed(agent) {
                Text(ClaudeStyle.duration(e))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(agent == .claude ? ClaudeStyle.accent : Color(red: 0.45, green: 0.6, blue: 1))
            }
        }
        .padding(.horizontal, topR + 14)
        .frame(height: g.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.openAgent(agent == .claude ? .claude : .antigravity) }
        .help(agent == .claude ? "Klik untuk membuka sesi Claude" : "Klik untuk membuka Antigravity")
    }

    /// Saat agent minta izin: apa yang diminta (kiri: tool/jenis, kanan: detail).
    @ViewBuilder
    private func waitingCompact(_ agent: Agent) -> some View {
        let claude = model.primaryClaude
        let label = agent == .claude
            ? (claude?.waiting_kind == "input" ? "Claude" : (claude?.tool ?? "Izin"))
            : (model.agActivity?.waitingFor ?? "Menunggu")
        let detail = agent == .claude
            ? (claude?.waiting_kind == "input" ? "menunggu balasanmu" : (claude?.tool_target ?? claude?.tool_detail ?? ""))
            : (model.agActivity?.waitingDetail ?? "")
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .frame(maxWidth: wing - 40, alignment: .leading)   // tetap di sisi kiri notch fisik
        Spacer(minLength: 8)
        HStack(spacing: 6) {
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: wing - 20, alignment: .trailing)
    }

    // Peringatan limit: tanda provider + nama jendela di kiri, persen/perkiraan atau reset di kanan.
    private func limitCompactContent(_ alert: LimitAlert) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if alert.provider == .claude {
                    ClaudeMark(size: 14)
                } else {
                    AntigravityMark(size: 14)
                }
                Text(alert.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: wing - 20, alignment: .leading)   // jangan masuk ke bawah notch fisik
            Spacer(minLength: 8)
            switch alert.kind {
            case .threshold:
                if let eta = alert.eta {
                    Text("habis ±" + eta.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UsageStyle.color(alert.percent))
                        .lineLimit(1)
                }
                Text("\(Int(alert.percent.rounded()))%")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                UsageRing(percent: alert.percent, size: 18)
            case .reset:
                Text("Limit reset")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.green)
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.green)
            }
        }
        .padding(.horizontal, topR + 14)
        .frame(height: g.notchSize.height)
    }

    // Command terminal selesai: ✓/✗ + command di kiri, exit code & durasi di kanan. Klik → buka terminalnya.
    private func terminalCompactContent(_ e: TerminalEvent) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: e.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(e.succeeded ? Palette.green : Palette.red)
                Text(e.command)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: wing - 20, alignment: .leading)
            Spacer(minLength: 8)
            if !e.succeeded {
                Text("exit \(e.exitCode)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.red)
            }
            Text(ClaudeStyle.duration(e.duration))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, topR + 14)
        .frame(height: g.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.openTerminalAlert() }
        .help(e.cwd)
    }

    private func elapsed(_ agent: Agent) -> TimeInterval? {
        switch agent {
        case .claude: return model.primaryClaude?.elapsed(now: model.now)
        case .antigravity: return model.agActivity?.busySince.map { model.now.timeIntervalSince($0) }
        }
    }

    private var batteryTint: Color {
        guard let b = model.battery else { return .white }
        if b.onAC { return Palette.green }
        return b.level <= 20 ? Palette.red : .white
    }

    // Pill melebar di kiri-kanan notch, seperti notifikasi charging di iPhone.
    private var chargeAlertContent: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.green)
                Text("Mengisi Daya")
                    .font(.system(size: 12, weight: .semibold))
            }
            Spacer()
            if let b = model.battery {
                HStack(spacing: 6) {
                    Text("\(b.level)%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.green)
                    BatteryGlyph(level: b.level, charging: false, tint: Palette.green)
                }
            }
        }
        .padding(.horizontal, topR + 14)
        .frame(height: g.notchSize.height)
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            topStrip
            Group {
                if model.enabledWidgets.isEmpty {
                    Text("Aktifkan widget lewat ikon kapsul di menu bar.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                } else {
                    widgetContent(model.selectedWidget)
                        .frame(height: model.selectedWidget.contentHeight)
                }
            }
            .id(model.selectedWidget)
            .transition(AnyTransition(.blurReplace).animation(islandSpring))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func widgetContent(_ kind: WidgetKind) -> some View {
        switch kind {
        case .claude:
            HStack(spacing: 10) {
                UsageTile(title: "Claude Usage", icon: ClaudeMark(size: 12, color: .white),
                          usage: model.officialUsage,
                          placeholder: (model.claudeUsage.map { "≈ \(ClaudeStyle.tokens($0.blockTokens)) token · 5 jam (estimasi)" } ?? "menghitung…",
                                        "Buka Claude Desktop untuk persen limit resmi."),
                          now: model.now, eta: { model.limitETA(.claude, $0) })
                    .frame(width: 196)
                ClaudeCard(session: model.primaryClaude,
                           otherActive: model.activeClaudeCount - (model.primaryClaude?.isActive == true ? 1 : 0),
                           usage: model.claudeUsage,
                           now: model.now,
                           onOpen: { model.openAgent(.claude) })
            }
        case .antigravity:
            HStack(spacing: 10) {
                UsageTile(title: "Antigravity", icon: AntigravityMark(size: 12),
                          usage: model.agQuota,
                          placeholder: (model.agRunning ? "Mengambil kuota…" : "Antigravity sedang tertutup",
                                        "Kuota terbaca saat Antigravity terbuka."),
                          now: model.now, grouped: true, eta: { model.limitETA(.antigravity, $0) })
                    .frame(width: 236)
                AntigravityCard(activity: model.agActivity, running: model.agRunning, now: model.now,
                                onOpen: { model.openAgent(.antigravity) })
            }
        case .media:
            MediaCard(nowPlaying: model.nowPlaying, deniedApp: model.mediaDenied, now: model.now,
                      onCommand: model.sendMedia)
        case .clock:
            HStack(spacing: 10) {
                clockTile
                controlsTile
            }
        case .shortcuts:
            shortcuts
        }
    }

    // Baris setinggi notch: tab widget di kiri notch, jam & baterai di kanan.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Group {
                if model.enabledWidgets.count > 1 {
                    WidgetTabs(widgets: model.enabledWidgets, selected: model.selectedWidget) {
                        model.selectedWidget = $0
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 12, weight: .medium))
                        Text(DeviceInfo.marketingName.components(separatedBy: " (").first ?? "Mac")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: g.notchSize.width)

            HStack(spacing: 6) {
                Text(model.now, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .padding(.trailing, 4)
                if let b = model.battery {
                    Text("\(b.level)%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(b.onAC ? Palette.green : .white)
                    BatteryGlyph(level: b.level, charging: b.charging, tint: batteryTint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: g.notchSize.height)
    }

    private var clockTile: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.now, format: .dateTime.weekday(.wide))
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(Palette.red)
            Text(model.now, format: .dateTime.day().month(.wide))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 0)
            Text(model.now, format: .dateTime.hour().minute())
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: model.now)
        }
        .frame(width: 140, alignment: .leading)
        .tile()
    }

    private var controlsTile: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if let v = model.volume {
                CapsuleSlider(value: Double(v), icon: Self.volumeIcon(v)) { model.setVolume(Float($0)) }
            }
            if let b = model.brightness {
                CapsuleSlider(value: Double(b), icon: b < 0.5 ? "sun.min.fill" : "sun.max.fill") {
                    model.setBrightness(Float($0))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .tile()
    }

    private static func volumeIcon(_ v: Float) -> String {
        switch v {
        case 0: return "speaker.slash.fill"
        case ..<0.33: return "speaker.wave.1.fill"
        case ..<0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 4) {
            ForEach(FolderShortcut.all) { ShortcutButton(item: $0) }
        }
    }
}

// MARK: - Window

/// Agar slider & tombol langsung merespons klik pertama walau panel tidak menjadi key window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .mainMenu + 3                        // di atas menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true                    // klik tembus ke menu bar saat tertutup
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var widgetItems: [NSMenuItem] = []
    var soundItem: NSMenuItem!
    var usageItem: NSMenuItem!
    var mediaModeItems: [NSMenuItem] = []
    var panel: NotchPanel!
    var model: NotchModel!
    var statusItem: NSStatusItem!
    var monitors: [Any] = []
    var collapseWork: DispatchWorkItem?
    var terminalSink: AnyCancellable?
    var terminalItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var claudeHookItem: NSMenuItem!
    var terminalHookItem: NSMenuItem!

    func applicationWillTerminate(_ note: Notification) {
        model?.systemMedia.stop()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NotchDetector.preferredScreen() else { return }
        model = NotchModel(geometry: NotchDetector.detect(on: screen))

        panel = NotchPanel(frame: panelFrame())
        let host = FirstMouseHostingView(rootView: NotchView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        // Setelah notifikasi terminal hilang, klik kembali tembus ke menu bar.
        // Setelah live activity hilang, klik kembali tembus ke menu bar (dicek tiap detik).
        terminalSink = model.$now.sink { [weak self] _ in
            guard let self, !self.model.expanded, !self.model.hasClickableCompact else { return }
            self.panel.ignoresMouseEvents = true
        }

        setupStatusItem()
        migrateIntegrations()

        // `open NotchIsland.app --args --enable-login-item` mengaktifkan "Buka saat login" sekali jalan.
        if CommandLine.arguments.contains("--enable-login-item"), SMAppService.mainApp.status != .enabled {
            toggleLoginItem()
        }

        // Re-deteksi saat layar berubah (ganti resolusi, colok/lepas monitor, clamshell).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.relayout()
        }

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.trackMouse() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged],
                                                    handler: { handler($0); return $0 }) {
            monitors.append(m)
        }
    }

    func panelFrame() -> CGRect {
        let g = model.geometry
        let w = model.maxExpandedSize.width + 40, h = model.maxExpandedSize.height + 30
        return CGRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    func relayout() {
        guard let screen = NotchDetector.preferredScreen() else { return }
        let g = NotchDetector.detect(on: screen)
        if g != model.geometry {
            model.geometry = g
            panel.setFrame(panelFrame(), display: true)
        }
    }

    private var hoverWork: DispatchWorkItem?

    private func expandIsland() {
        hoverWork?.cancel()
        hoverWork = nil
        collapseWork?.cancel()
        model.refreshControls()
        model.autoSelectWidget()
        model.expanded = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        panel.ignoresMouseEvents = false
    }

    private func scheduleHoverExpand(in zone: CGRect) {
        guard hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hoverWork = nil
            guard let self, !self.model.expanded, zone.contains(NSEvent.mouseLocation) else { return }
            self.expandIsland()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func trackMouse() {
        let p = NSEvent.mouseLocation
        let g = model.geometry
        let hotZone = g.notchRect.insetBy(dx: -8, dy: -4)
        let es = model.expandedSize
        let expandedRect = CGRect(x: g.screenFrame.midX - es.width / 2, y: g.screenFrame.maxY - es.height,
                                  width: es.width, height: es.height)
        let dragging = NSEvent.pressedMouseButtons & 1 != 0

        if !model.expanded, model.terminalAlert != nil, let wing = model.clickableWing {
            panel.ignoresMouseEvents = !g.notchRect.insetBy(dx: -(wing + 6), dy: -4).contains(p)
            return
        }
        // Live activity agent: hover di notch tetap membuka island; sayap kiri/kanan bisa diklik.
        if !model.expanded, let wing = model.clickableWing, !hotZone.contains(p) {
            panel.ignoresMouseEvents = !g.notchRect.insetBy(dx: -(wing + 6), dy: -4).contains(p)
            return
        }

        if !model.expanded, hotZone.contains(p) {
            if g.hasPhysicalNotch {
                expandIsland()
            } else if !model.fullscreenActive {
                // Tanpa notch, zona hover menimpa konten sungguhan (tab, menu):
                // buka hanya bila kursor berhenti sebentar, bukan sekadar lewat.
                scheduleHoverExpand(in: hotZone)
            }
        } else if model.expanded, !dragging, !expandedRect.insetBy(dx: -6, dy: -6).contains(p) {
            guard collapseWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.model.expanded = false
                self?.panel.ignoresMouseEvents = true
                self?.collapseWork = nil
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else if model.expanded {
            collapseWork?.cancel()
            collapseWork = nil
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        let g = model.geometry
        menu.addItem(withTitle: "\(DeviceInfo.marketingName) (\(DeviceInfo.modelIdentifier))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Notch: \(Int(g.notchSize.width))×\(Int(g.notchSize.height)) pt", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Widget"))
        for kind in WidgetKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            menu.addItem(item)
            widgetItems.append(item)
        }
        soundItem = NSMenuItem(title: "Bunyi notifikasi agent & limit", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        menu.addItem(soundItem)
        usageItem = NSMenuItem(title: "Selalu tampilkan usage Claude", action: #selector(toggleUsage), keyEquivalent: "")
        usageItem.target = self
        menu.addItem(usageItem)
        let mediaMenu = NSMenu()
        for mode in MediaLiveMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setMediaMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            mediaMenu.addItem(item)
            mediaModeItems.append(item)
        }
        mediaMenu.delegate = self
        let integrationMenu = NSMenu()
        claudeHookItem = NSMenuItem(title: "Claude Code (status sesi)", action: #selector(toggleClaudeHook), keyEquivalent: "")
        terminalHookItem = NSMenuItem(title: "Terminal zsh (command selesai)", action: #selector(toggleTerminalHook), keyEquivalent: "")
        for item in [claudeHookItem!, terminalHookItem!] {
            item.target = self
            integrationMenu.addItem(item)
        }
        integrationMenu.delegate = self
        let integrationItem = NSMenuItem(title: "Integrasi", action: nil, keyEquivalent: "")
        integrationItem.submenu = integrationMenu
        menu.addItem(integrationItem)
        terminalItem = NSMenuItem(title: "Notifikasi command terminal", action: #selector(toggleTerminal), keyEquivalent: "")
        terminalItem.target = self
        menu.addItem(terminalItem)
        loginItem = NSMenuItem(title: "Buka saat login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let mediaItem = NSMenuItem(title: "Live activity musik", action: nil, keyEquivalent: "")
        mediaItem.submenu = mediaMenu
        menu.addItem(mediaItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tes notifikasi charger", action: #selector(testChargeAlert), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Tes peringatan limit", action: #selector(testLimitAlert), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Tes notifikasi terminal", action: #selector(testTerminalAlert), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Deteksi ulang layar", action: #selector(redetect), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    // Centang widget & opsi bunyi diperbarui setiap menu dibuka.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in widgetItems {
            let kind = (item.representedObject as? String).flatMap(WidgetKind.init(rawValue:))
            item.state = kind.map(model.enabledWidgets.contains) == true ? .on : .off
        }
        soundItem.state = model.soundOnClaudeDone ? .on : .off
        usageItem.state = model.alwaysShowUsage ? .on : .off
        terminalItem.state = model.terminalAlertsEnabled ? .on : .off
        claudeHookItem.state = Integrations.claudeHookStatus() == .notInstalled ? .off : .on
        terminalHookItem.state = Integrations.isTerminalHookInstalled() ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in mediaModeItems {
            item.state = item.representedObject as? String == model.mediaLiveMode.rawValue ? .on : .off
        }
    }

    @objc func setMediaMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(MediaLiveMode.init(rawValue:)) else { return }
        model.mediaLiveMode = mode
    }

    @objc func toggleUsage() { model.alwaysShowUsage.toggle() }

    @objc func toggleWidget(_ sender: NSMenuItem) {
        guard let kind = (sender.representedObject as? String).flatMap(WidgetKind.init(rawValue:)) else { return }
        model.toggleWidget(kind)
    }

    @objc func toggleSound() { model.soundOnClaudeDone.toggle() }
    @objc func redetect() { relayout() }
    @objc func testChargeAlert() { model.showChargeAlert() }
    @objc func testLimitAlert() { model.testLimitAlerts() }
    @objc func testTerminalAlert() { model.testTerminalAlerts() }
    @objc func toggleTerminal() { model.terminalAlertsEnabled.toggle() }

    // MARK: Integrasi (hook)

    /// Hook lama (skrip Python) atau path app yang berpindah → arahkan ulang ke app ini.
    /// Hanya menyentuh entri milik NotchIsland, dan tidak dari lokasi sementara (DMG).
    func migrateIntegrations() {
        guard !Integrations.isRunningFromTemporaryLocation else { return }
        if Integrations.claudeHookStatus() == .outdated {
            do { try Integrations.installClaudeHook() } catch { NSLog("NotchIsland: migrasi hook Claude gagal: \(error)") }
        }
        if Integrations.isTerminalHookInstalled() { try? Integrations.refreshTerminalScript() }
    }

    /// Konfirmasi sebelum mengubah file konfigurasi pengguna.
    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Batal")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func report(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc func toggleClaudeHook() {
        let installed = Integrations.claudeHookStatus() != .notInstalled
        if Integrations.isRunningFromTemporaryLocation, !installed {
            report(NSError(domain: "NotchIsland", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Pindahkan NotchIsland ke folder Aplikasi dulu, lalu buka dari sana sebelum menghubungkan Claude Code."]))
            return
        }
        let ok = installed
            ? confirm("Lepas hook Claude Code?", "Entri NotchIsland akan dihapus dari ~/.claude/settings.json (backup dibuat). Status Claude tidak lagi tampil di notch.", "Lepas")
            : confirm("Hubungkan Claude Code?", "NotchIsland akan menambahkan hook ke ~/.claude/settings.json (backup: settings.json.bak-notchisland) supaya status sesi Claude tampil di notch. Hook lain milikmu tidak diubah.", "Hubungkan")
        guard ok else { return }
        do {
            try installed ? Integrations.uninstallClaudeHook() : Integrations.installClaudeHook()
        } catch {
            report(error)
        }
    }

    @objc func toggleTerminalHook() {
        let installed = Integrations.isTerminalHookInstalled()
        let ok = installed
            ? confirm("Lepas hook terminal?", "Baris NotchIsland akan dihapus dari ~/.zshrc (backup dibuat). Berlaku di jendela terminal baru.", "Lepas")
            : confirm("Aktifkan notifikasi command terminal?", "NotchIsland akan menambahkan satu baris `source` ke ~/.zshrc (backup: .zshrc.bak-notchisland). Command yang berjalan ≥30 detik akan memberi notifikasi di notch saat selesai. Berlaku di jendela terminal baru.", "Aktifkan")
        guard ok else { return }
        do {
            try installed ? Integrations.uninstallTerminalHook() : Integrations.installTerminalHook()
        } catch {
            report(error)
        }
    }

    /// Login item resmi macOS (Pengaturan Sistem › Umum › Item Login).
    @objc func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("NotchIsland: login item gagal diubah: \(error.localizedDescription)")
        }
        // macOS bisa meminta persetujuan pengguna di Pengaturan Sistem.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

// Hook Claude Code: `NotchIsland --claude-hook` (dipanggil oleh Claude Code, bukan oleh pengguna).
if CommandLine.arguments.contains("--claude-hook") {
    ClaudeHook.run()
}

// Pemasang hook dari terminal (dipakai juga oleh hooks/*.sh).
let integrationCommands: [String: () throws -> Void] = [
    "--install-claude-hook": Integrations.installClaudeHook,
    "--uninstall-claude-hook": Integrations.uninstallClaudeHook,
    "--install-terminal-hook": Integrations.installTerminalHook,
    "--uninstall-terminal-hook": Integrations.uninstallTerminalHook,
]
if let flag = CommandLine.arguments.first(where: { integrationCommands[$0] != nil }) {
    do {
        try integrationCommands[flag]!()
        print(flag.contains("uninstall") ? "✓ Hook dilepas." : "✓ Hook terpasang.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Debug: `NotchIsland --test-limits` mensimulasikan pemakaian naik lalu reset.
if CommandLine.arguments.contains("--test-limits") {
    let watcher = LimitWatcher()
    let start = Date()
    let reset = start.addingTimeInterval(3 * 3600)
    let steps: [(TimeInterval, Double, TimeInterval)] = [(0, 70, 0), (10 * 60, 82, 10 * 60), (20 * 60, 96, 20 * 60),
                                                         (25 * 60, 97, 25 * 60), (3 * 3600 + 60, 97, 3 * 3600 + 60)]
    for (captured, percent, at) in steps {
        let usage = OfficialUsage(windows: [LimitWindow(id: "session", title: "Sesi saat ini", percent: percent, resetsAt: reset)],
                                  capturedAt: start.addingTimeInterval(captured))
        let alerts = watcher.observe(provider: .claude, usage: usage, now: start.addingTimeInterval(at))
        let desc = alerts.map { a -> String in
            let eta = a.eta.map { " eta +\(Int($0.timeIntervalSince(start) / 60)) mnt" } ?? ""
            return "\(a.kind) \(Int(a.percent))%\(eta)"
        }
        print("menit \(Int(at / 60)) · \(Int(percent))% → \(desc.isEmpty ? "-" : desc.joined(separator: ", "))")
    }
    exit(0)
}

// Debug: `NotchIsland --print-claude` mencetak data monitor Claude lalu keluar.
if CommandLine.arguments.contains("--print-claude") {
    if let screen = NotchDetector.preferredScreen() {
        let g = NotchDetector.detect(on: screen)
        print("layar: \(g.screenName) · notch fisik: \(g.hasPhysicalNotch ? "ya" : "tidak") · \(Int(g.notchSize.width))×\(Int(g.notchSize.height)) pt · full-screen: \(FullScreenDetector.isActive(on: g.screenFrame) ? "ya" : "tidak")")
    }
    let monitor = ClaudeMonitor()
    let sessions = monitor.readSessions()
    for s in sessions {
        print("\(s.displayName): \(s.state ?? "?") · \(s.tool_count ?? 0) tool · plan \(s.plan ?? [])")
    }
    if let o = ClaudeDesktopUsage.read() {
        for w in o.windows {
            print("resmi: \(w.title) \(Int(w.percent))% · \(UsageStyle.resetText(w.resetsAt, now: Date())) · cache \(UsageStyle.ageText(o.capturedAt, now: Date()))")
        }
    } else {
        print("resmi: cache Claude Desktop tidak ditemukan")
    }
    if let a = AntigravityMonitor().poll() {
        print("antigravity: \(a.state.rawValue) · percakapan \(a.conversation.prefix(8)) · tulis \(UsageStyle.ageText(a.lastWrite, now: Date()))")
    }
    if let q = AntigravityQuota.fetch() {
        for w in q.windows { print("antigravity kuota: \(w.title) \(Int(w.percent))% · \(UsageStyle.resetText(w.resetsAt, now: Date()))") }
    } else {
        print("antigravity kuota: tidak tersedia (Antigravity \(AntigravityQuota.isRunning() ? "terbuka" : "tertutup"))")
    }
    let u = monitor.computeUsage(contextTranscript: sessions.first?.transcript_path)
    print("5 jam ≈ \(ClaudeStyle.tokens(u.blockTokens)) · reset \(u.resetAt.map { "\($0)" } ?? "-") · ctx \(u.contextTokens.map(ClaudeStyle.tokens) ?? "-")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // tanpa ikon Dock
app.run()
