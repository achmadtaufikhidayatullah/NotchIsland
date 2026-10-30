import AppKit
import SwiftUI

// MARK: - Posisi island

enum Placement: String, CaseIterable, Identifiable {
    case top, right, left
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: return "Tengah atas (notch)"
        case .right: return "Sisi kanan layar"
        case .left: return "Sisi kiri layar"
        }
    }
}

// MARK: - Bentuk tab sisi

/// Tab yang menempel di tepi layar, dengan "telinga" cekung di atas & bawah yang menyatu
/// dengan tepi — bentuk notch yang diputar 90°.
struct SideTabShape: Shape {
    var edge: Placement          // .right atau .left
    var ear: CGFloat = 10
    var radius: CGFloat = 18

    // Telinga & radius ikut beranimasi saat tab membesar dari mode mini.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // Dibangun dalam koordinat (u = sepanjang tepi, v = menjauhi tepi), lalu dipetakan.
        let H = rect.height, W = rect.width, t = ear, b = radius, k: CGFloat = 0.62
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            edge == .left ? CGPoint(x: rect.minX + v, y: rect.minY + u)
                          : CGPoint(x: rect.maxX - v, y: rect.minY + u)
        }
        var p = Path()
        p.move(to: pt(0, 0))
        p.addCurve(to: pt(t, t), control1: pt(t * k, 0), control2: pt(t, t * (1 - k)))
        p.addLine(to: pt(t, W - b))
        p.addCurve(to: pt(t + b, W), control1: pt(t, W - b * (1 - k)), control2: pt(t + b * (1 - k), W))
        p.addLine(to: pt(H - t - b, W))
        p.addCurve(to: pt(H - t, W - b), control1: pt(H - t - b * (1 - k), W), control2: pt(H - t, W - b * (1 - k)))
        p.addLine(to: pt(H - t, t))
        p.addCurve(to: pt(H, 0), control1: pt(H - t, t * (1 - k)), control2: pt(H - t * k, 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Notifikasi sekilas di samping tab

struct SideToast: Equatable {
    enum Action: Equatable { case none, agent(WidgetKind), terminal }
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: Action
}

extension NotchModel {
    var sideProviders: [WidgetKind] { [.claude, .antigravity].filter(enabledWidgets.contains) }

    /// Agent yang ditampilkan di kartu detail: ring yang terakhir ditunjuk kursor.
    var sideFocusedProvider: WidgetKind? {
        if let f = sideFocus, sideProviders.contains(f) { return f }
        return sideProviders.first
    }

    /// Ada sesuatu yang layak ditampilkan (untuk mode mini).
    var sideHasActivity: Bool { sideToast != nil || hasClickableCompact }

    /// Notifikasi sekilas untuk mode sisi, urut prioritas — padanan live activity di notch.
    var sideToast: SideToast? {
        if chargeAlert, let b = battery {
            return SideToast(symbol: "bolt.fill", tint: Palette.green, title: "Mengisi Daya", detail: "\(b.level)%", action: .none)
        }
        if let a = limitAlert {
            switch a.kind {
            case .threshold:
                let eta = a.eta.map { " · habis ±" + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                return SideToast(symbol: "exclamationmark.circle.fill", tint: UsageStyle.color(a.percent),
                                 title: "\(a.title) \(Int(a.percent.rounded()))%", detail: "Limit hampir habis\(eta)",
                                 action: .agent(a.provider))
            case .reset:
                return SideToast(symbol: "arrow.counterclockwise.circle.fill", tint: Palette.green,
                                 title: "Limit reset", detail: a.title, action: .agent(a.provider))
            }
        }
        if let e = terminalAlert {
            return SideToast(symbol: e.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill",
                             tint: e.succeeded ? Palette.green : Palette.red, title: e.command,
                             detail: (e.succeeded ? "" : "exit \(e.exitCode) · ") + ClaudeStyle.duration(e.duration),
                             action: .terminal)
        }
        let claudeOn = enabledWidgets.contains(.claude), agOn = enabledWidgets.contains(.antigravity)
        if claudeOn, claudeFlashDone {
            return SideToast(symbol: "checkmark.circle.fill", tint: Palette.green, title: "Claude selesai",
                             detail: primaryClaude?.displayName ?? "", action: .agent(.claude))
        }
        if agOn, agFlashDone {
            return SideToast(symbol: "checkmark.circle.fill", tint: Palette.green, title: "Antigravity selesai",
                             detail: "", action: .agent(.antigravity))
        }
        if claudeOn, let s = primaryClaude, s.isWaiting {
            return SideToast(symbol: "hand.raised.fill", tint: .orange, title: "Claude menunggu",
                             detail: s.waitingText, action: .agent(.claude))
        }
        if agOn, let a = agActivity, a.state == .waiting {
            return SideToast(symbol: "hand.raised.fill", tint: .orange, title: "Antigravity menunggu",
                             detail: a.waitingDetail ?? a.waitingFor ?? "", action: .agent(.antigravity))
        }
        if enabledWidgets.contains(.media), mediaFlash, mediaLiveMode != .off, let np = nowPlaying {
            return SideToast(symbol: "music.note", tint: .white, title: np.title, detail: np.artist, action: .none)
        }
        return nil
    }

    func perform(_ action: SideToast.Action) {
        switch action {
        case .none: break
        case .agent(let kind): openAgent(kind)
        case .terminal: openTerminalAlert()
        }
    }
}

// MARK: - Tab

struct SideTabView: View {
    @ObservedObject var model: NotchModel
    let edge: Placement

    static let width: CGFloat = 58
    static let ear: CGFloat = 10
    static let cellHeight: CGFloat = 62

    /// Mode mini: garis tipis di tepi selama tidak ada aktivitas dan tidak di-hover.
    static func isMinimized(_ model: NotchModel) -> Bool {
        model.sideMini && !model.sideHover && !model.sideHasActivity
    }

    /// Ukuran jendela tab — tetap, juga saat mode mini, supaya animasi terjadi di dalam SwiftUI
    /// (mengubah ukuran jendela di tengah animasi membuat isinya tumpang tindih).
    static func size(for model: NotchModel) -> CGSize {
        let cells = max(1, model.sideProviders.count)
        return CGSize(width: width, height: CGFloat(cells) * cellHeight + 20 + ear * 2)
    }

    /// Bagian jendela yang benar-benar terlihat (untuk hover & klik).
    /// Ukuran notch kecil saat mode mini.
    static let miniSize = CGSize(width: 12, height: 72)

    static func hitRect(in frame: CGRect, model: NotchModel, edge: Placement) -> CGRect {
        guard isMinimized(model) else { return frame }
        let w = miniSize.width + 6, h = miniSize.height
        return CGRect(x: edge == .right ? frame.maxX - w : frame.minX, y: frame.midY - h / 2, width: w, height: h)
    }

    var body: some View {
        let mini = Self.isMinimized(model)
        let full = Self.size(for: model)
        // Satu bentuk yang sama: notch hitam kecil di tepi saat mini, membesar menjadi tab penuh saat hover.
        // Ring berada DI DALAM bentuk itu dan dipotong mengikutinya, jadi saat menyusut tidak ada yang
        // tergambar di luar kotak hitam.
        let shape = SideTabShape(edge: edge, ear: mini ? 6 : Self.ear, radius: mini ? 7 : 18)
        return shape
            .fill(Color.black)
            .overlay {
                if !mini {
                    VStack(spacing: 0) {
                        if model.sideProviders.isEmpty {
                            Image(systemName: "capsule.fill")
                                .font(.system(size: 16))
                                .frame(height: Self.cellHeight)
                        }
                        ForEach(model.sideProviders) { cell($0) }
                    }
                    .padding(.vertical, 10 + Self.ear)
                    .offset(x: edge == .right ? 3 : -3)
                    .fixedSize()
                    // Muncul setelah kotak membesar; hilang seketika sebelum kotak menyusut.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(mini ? 0.25 : 0), radius: 3)
            .frame(width: mini ? Self.miniSize.width : full.width,
                   height: mini ? Self.miniSize.height : full.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .right ? .trailing : .leading)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .animation(islandSpring, value: mini)
    }

    private func cell(_ kind: WidgetKind) -> some View {
        let claude = kind == .claude
        let window = claude ? model.officialUsage?.session : model.agQuota?.headline
        let p = window?.percent(at: model.now)
        let busy = claude ? model.primaryClaude?.isWorking == true : model.agActivity?.state == .busy
        let waiting = claude ? model.primaryClaude?.isWaiting == true : model.agActivity?.state == .waiting
        let done = claude ? model.claudeFlashDone : model.agFlashDone
        return VStack(spacing: 5) {
            ZStack {
                UsageRing(percent: p ?? 0, size: 36, lineWidth: 3.5, busy: busy, waiting: waiting)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.green)
                } else if claude {
                    ClaudeMark(size: 14, spinning: busy, color: waiting ? .orange : .white)
                } else {
                    AntigravityMark(size: 13, active: busy, tint: waiting ? .orange : .white)
                }
            }
            Text(p.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .frame(height: Self.cellHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.openAgent(kind) }
        .help(claude ? "Claude — klik untuk membuka sesi" : "Antigravity — klik untuk membuka")
    }
}

// MARK: - Kartu detail (hover) & notifikasi sekilas

/// Tinggi isi kartu yang sedang tampil — dibaca AppDelegate untuk area hover/klik,
/// karena jendela kartu sendiri berukuran tetap (sebagian besar transparan).
final class SideCardMetrics {
    var height: CGFloat = 0
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SideCardView: View {
    @ObservedObject var model: NotchModel
    let edge: Placement
    let metrics: SideCardMetrics
    let openSettings: () -> Void

    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 640

    /// Kartu tumbuh dari pojok yang menempel ke tab.
    private var anchor: UnitPoint { edge == .right ? .topTrailing : .topLeading }

    /// Masuk: tumbuh dengan pegas. Keluar: memudar cepat sambil sedikit menyusut ke arah tab,
    /// sebagai satu lapisan (lihat `card(_:)`) supaya isi tidak tertinggal di luar kotak hitam.
    private func cardTransition(from scale: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: scale, anchor: anchor).combined(with: .opacity),
            removal: .scale(scale: 0.96, anchor: anchor).combined(with: .opacity)
                .animation(.easeOut(duration: 0.15)))
    }

    var body: some View {
        ZStack(alignment: edge == .right ? .topTrailing : .topLeading) {
            if model.sideHover {
                detail
                    .transition(cardTransition(from: 0.85))
            } else if let toast = model.sideToast {
                toastView(toast)
                    .transition(cardTransition(from: 0.9))
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(CardHeightKey.self) { metrics.height = $0 }
        // Isi menempel di atas & mengikuti tinggi jendela (dibatasi maxHeight di AppDelegate),
        // supaya tidak terpotong di layar yang lebih pendek.
        .frame(width: Self.width, alignment: edge == .right ? .topTrailing : .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .animation(islandSpring, value: model.sideHover)
        .animation(islandSpring, value: model.sideToast)
        .animation(islandSpring, value: model.sideFocus)
    }

    private func toastView(_ t: SideToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(t.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !t.detail.isEmpty {
                    Text(t.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .compositingGroup()
        .contentShape(Rectangle())
        .onTapGesture { model.perform(t.action) }
    }

    private var detail: some View {
        VStack(spacing: 10) {
            HStack {
                Text("NotchIsland").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                Text(model.now, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.secondary)
                Button(action: openSettings) {
                    Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                .buttonStyle(PressScaleStyle())
                .help("Pengaturan")
            }
            .padding(.horizontal, 4)

            // Hanya agent dari ring yang ditunjuk kursor; berganti saat kursor pindah ring.
            Group {
                switch model.sideFocusedProvider {
                case .claude?:
                    VStack(spacing: 10) {
                        UsageTile(title: "Claude Usage", icon: ClaudeMark(size: 12, color: .white),
                                  usage: model.officialUsage,
                                  placeholder: ("Belum ada data limit", "Buka Claude Desktop untuk persen limit resmi."),
                                  now: model.now, eta: { model.limitETA(.claude, $0) })
                            .frame(height: UsageTile<ClaudeMark>.idealHeight(model.officialUsage))
                        ClaudeCard(session: model.primaryClaude,
                                   otherActive: model.activeClaudeCount - (model.primaryClaude?.isActive == true ? 1 : 0),
                                   usage: model.claudeUsage, now: model.now,
                                   onOpen: { model.openAgent(.claude) })
                            .frame(height: 104)
                    }
                case .antigravity?:
                    VStack(spacing: 10) {
                        UsageTile(title: "Antigravity", icon: AntigravityMark(size: 12),
                                  usage: model.agQuota,
                                  placeholder: (model.agRunning ? "Mengambil kuota…" : "Antigravity sedang tertutup",
                                                "Kuota terbaca saat Antigravity terbuka."),
                                  now: model.now, grouped: true, eta: { model.limitETA(.antigravity, $0) })
                            .frame(height: UsageTile<AntigravityMark>.idealHeight(model.agQuota, grouped: true))
                        AntigravityCard(activity: model.agActivity, running: model.agRunning, now: model.now,
                                        onOpen: { model.openAgent(.antigravity) })
                            .frame(height: 104)
                    }
                default:
                    EmptyView()
                }
            }
            .id(model.sideFocusedProvider)
            .transition(.opacity.combined(with: .offset(y: 6)))
            if model.enabledWidgets.contains(.media), model.nowPlaying != nil {
                MediaCard(nowPlaying: model.nowPlaying, deniedApp: model.mediaDenied, now: model.now,
                          onCommand: model.sendMedia)
                    .frame(height: 104)
            }
        }
        .padding(12)
        .background(Color.black)
        // Satu lapisan yang terpotong di kotak hitam: saat menghilang tidak ada tile yang tertinggal di luarnya.
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .compositingGroup()
    }
}
