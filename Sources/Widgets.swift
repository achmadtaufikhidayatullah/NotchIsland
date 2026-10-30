import SwiftUI

/// Animasi berulang (logo berputar, arc kerja, shimmer, equalizer) dibatasi 30 fps:
/// cukup mulus untuk elemen sekecil ini, dan jauh lebih hemat CPU daripada mengikuti
/// refresh rate layar (hingga 120 Hz di ProMotion).
enum Motion {
    static let frame: TimeInterval = 1.0 / 30
}

/// Daftar widget yang bisa tampil di island. Urutan case = urutan tab.
enum WidgetKind: String, CaseIterable, Identifiable {
    case claude, antigravity, media, calendar, shelf, clock, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .media: return "Sedang Diputar"
        case .calendar: return "Kalender"
        case .shelf: return "Shelf & AirDrop"
        case .clock: return "Jam & Kontrol"
        case .shortcuts: return "Folder"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .antigravity: return "a.circle.fill"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .shelf: return "tray.full.fill"
        case .clock: return "clock.fill"
        case .shortcuts: return "folder.fill"
        }
    }

    /// Tinggi area konten widget (di bawah baris notch).
    var contentHeight: CGFloat {
        switch self {
        case .claude: return 104
        case .antigravity: return 104
        case .media: return 132
        case .calendar: return 132
        case .shelf: return 112
        case .clock: return 100
        case .shortcuts: return 58
        }
    }

    static let defaultEnabled: [WidgetKind] = [.claude, .antigravity, .media, .calendar, .shelf]
    static let maxContentHeight = allCases.map(\.contentHeight).max() ?? 104
}

/// Tab ikon kecil di kiri notch untuk berpindah widget.
struct WidgetTabs: View {
    let widgets: [WidgetKind]
    let selected: WidgetKind
    let onSelect: (WidgetKind) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(widgets) { kind in
                let isOn = kind == selected
                Button { onSelect(kind) } label: {
                    Group {
                        if kind == .claude {
                            ClaudeMark(size: 11, color: isOn ? ClaudeStyle.accent : Palette.secondary)
                        } else if kind == .antigravity {
                            AntigravityMark(size: 12, tint: isOn ? nil : Palette.secondary)
                        } else {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(isOn ? Color.white : Palette.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(isOn ? 0.16 : 0)))
                    .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .help(kind.title)
            }
        }
    }
}
