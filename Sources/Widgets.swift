import SwiftUI

/// Daftar widget yang bisa tampil di island. Urutan case = urutan tab.
enum WidgetKind: String, CaseIterable, Identifiable {
    case claude, antigravity, media, clock, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .media: return "Sedang Diputar"
        case .clock: return "Jam & Kontrol"
        case .shortcuts: return "Folder"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .antigravity: return "a.circle.fill"
        case .media: return "music.note"
        case .clock: return "clock.fill"
        case .shortcuts: return "folder.fill"
        }
    }

    /// Tinggi area konten widget (di bawah baris notch).
    var contentHeight: CGFloat {
        switch self {
        case .claude: return 104
        case .antigravity: return 104
        case .media: return 104
        case .clock: return 100
        case .shortcuts: return 58
        }
    }

    static let defaultEnabled: [WidgetKind] = [.claude, .antigravity, .media]
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
