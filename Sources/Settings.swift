import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Aksi yang butuh AppDelegate (dialog konfirmasi, tata letak ulang, tes)

struct SettingsActions {
    let toggleClaudeHook: () -> Void
    let toggleTerminalHook: () -> Void
    let toggleLoginItem: () -> Void
    let relayout: () -> Void
    let testCharge: () -> Void
    let testLimit: () -> Void
    let testTerminal: () -> Void
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, widgets, notifications, integrations, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Tampilan"
        case .widgets: return "Widget"
        case .notifications: return "Notifikasi"
        case .integrations: return "Integrasi"
        case .general: return "Umum"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .notifications: return "bell.badge.fill"
        case .integrations: return "link"
        case .general: return "gearshape.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "Bagaimana island tampil dan di layar mana."
        case .widgets: return "Widget yang tampil saat island dibuka."
        case .notifications: return "Kapan notch melebar dan berbunyi."
        case .integrations: return "Hubungkan Claude Code dan terminal."
        case .general: return "Login, versi, dan pembaruan."
        }
    }
}

/// State jendela (tanpa @State — toolchain ini tidak memuat plugin macro SwiftUI).
final class SettingsState: ObservableObject {
    @Published var section: SettingsSection = .appearance
    @Published var claudeHook: Integrations.HookStatus = .notInstalled
    @Published var terminalHook = false
    @Published var loginItem = false
    @Published var displayMode = UserDefaults.standard.string(forKey: "displayMode") ?? "auto"
    @Published var updateText: String?
    @Published var updateURL: URL?
    @Published var checkingUpdate = false

    func refresh() {
        claudeHook = Integrations.claudeHookStatus()
        terminalHook = Integrations.isTerminalHookInstalled()
        loginItem = SMAppService.mainApp.status == .enabled
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Bandingkan versi app dengan rilis terbaru di GitHub.
    func checkForUpdate() {
        checkingUpdate = true
        updateText = nil
        let url = URL(string: "https://api.github.com/repos/achmadtaufikhidayatullah/NotchIsland/releases/latest")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (obj?["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let page = (obj?["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                self.checkingUpdate = false
                guard let tag else { self.updateText = "Tidak bisa memeriksa pembaruan."; return }
                if tag.compare(Self.version, options: .numeric) == .orderedDescending {
                    self.updateText = "Versi \(tag) tersedia."
                    self.updateURL = page
                } else {
                    self.updateText = "Kamu memakai versi terbaru."
                    self.updateURL = nil
                }
            }
        }.resume()
    }
}

// MARK: - Jendela

struct SettingsView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var state: SettingsState
    let actions: SettingsActions

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.section.title).font(.system(size: 22, weight: .bold))
                    Text(state.section.subtitle).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 8)
                Form { content }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { state.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("NotchIsland").font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 34)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                Button { state.section = section } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(state.section == section ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Versi \(SettingsState.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch state.section {
        case .appearance: appearance
        case .widgets: widgets
        case .notifications: notifications
        case .integrations: integrations
        case .general: general
        }
    }

    // MARK: Tampilan

    private var appearance: some View {
        Group {
            Section {
                Picker("Layar", selection: Binding(
                    get: { state.displayMode },
                    set: { mode in
                        state.displayMode = mode
                        UserDefaults.standard.set(mode, forKey: "displayMode")
                        actions.relayout()
                    })) {
                    Text("Otomatis (layar ber-notch)").tag("auto")
                    Text("Layar dengan menu bar").tag("menubar")
                }
                LabeledContent("Terdeteksi") {
                    Text("\(model.geometry.screenName) · \(model.geometry.hasPhysicalNotch ? "notch fisik" : "tanpa notch") · \(Int(model.geometry.notchSize.width))×\(Int(model.geometry.notchSize.height)) pt")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Posisi") }

            Section {
                Toggle("Tampilkan island saat diam di layar tanpa notch", isOn: $model.showIdleWithoutNotch)
                Toggle("Selalu tampilkan ring usage Claude", isOn: $model.alwaysShowUsage)
            } header: { Text("Saat diam") } footer: {
                Text("Di layar tanpa notch, island secara default tidak terlihat saat diam supaya tidak menutupi tab browser atau judul jendela. Saat app full-screen, island selalu disembunyikan di layar tanpa notch.")
            }
        }
    }

    // MARK: Widget

    private var widgets: some View {
        Group {
            Section {
                ForEach(WidgetKind.allCases) { kind in
                    Toggle(isOn: Binding(get: { model.enabledWidgets.contains(kind) },
                                         set: { _ in model.toggleWidget(kind) })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } header: { Text("Widget aktif") } footer: {
                Text("Widget yang aktif muncul sebagai tab di kiri notch saat island dibuka.")
            }
            Section {
                Picker("Live activity musik", selection: $model.mediaLiveMode) {
                    ForEach(MediaLiveMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: { Text("Sedang diputar") }
        }
    }

    // MARK: Notifikasi

    private var notifications: some View {
        Group {
            Section {
                Toggle("Bunyi notifikasi (agent, limit, terminal)", isOn: $model.soundOnClaudeDone)
            }
            Section {
                sliderRow("Peringatan pertama", value: $model.limitWarn, range: 50...95, suffix: "%")
                sliderRow("Peringatan kritis", value: $model.limitCritical, range: 60...100, suffix: "%")
                Toggle("Beri tahu saat limit reset", isOn: $model.limitResetAlerts)
                Button("Tes peringatan limit", action: actions.testLimit)
            } header: { Text("Limit Claude & Antigravity") } footer: {
                Text("Notch melebar sekilas dengan bunyi saat pemakaian melewati ambang, sekali per siklus reset.")
            }
            Section {
                Toggle("Notifikasi command selesai", isOn: $model.terminalAlertsEnabled)
                sliderRow("Hanya command yang berjalan minimal", value: $model.terminalMinSeconds, range: 5...300, suffix: " dtk")
                Button("Tes notifikasi terminal", action: actions.testTerminal)
            } header: { Text("Terminal") } footer: {
                Text(state.terminalHook
                     ? "Ambang baru berlaku di jendela terminal yang dibuka setelah ini."
                     : "Hook terminal belum terpasang — aktifkan di Integrasi.")
            }
            Section {
                Button("Tes notifikasi charger", action: actions.testCharge)
            } header: { Text("Lainnya") }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { Double(value.wrappedValue) },
                                      set: { value.wrappedValue = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 5)
                    .frame(width: 200)
                Text("\(value.wrappedValue)\(suffix)")
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
            }
        }
    }

    // MARK: Integrasi

    private var integrations: some View {
        Group {
            Section {
                integrationRow(
                    title: "Claude Code",
                    detail: "Status sesi, detail izin, dan bunyi saat prompt selesai. Menambah hook di ~/.claude/settings.json (dengan backup).",
                    installed: state.claudeHook != .notInstalled,
                    action: { actions.toggleClaudeHook(); state.refresh() })
                integrationRow(
                    title: "Terminal (zsh)",
                    detail: "Notifikasi saat command yang lama selesai. Menambah satu baris di ~/.zshrc (dengan backup).",
                    installed: state.terminalHook,
                    action: { actions.toggleTerminalHook(); state.refresh() })
            } footer: {
                Text("Antigravity dan widget musik tidak memerlukan integrasi. Hook hanya menyentuh entri milik NotchIsland dan bisa dilepas kapan saja.")
            }
        }
    }

    private func integrationRow(title: String, detail: String, installed: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(installed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(installed ? "Lepas" : "Hubungkan", action: action)
        }
        .padding(.vertical, 4)
    }

    // MARK: Umum

    private var general: some View {
        Group {
            Section {
                Toggle("Buka NotchIsland saat login", isOn: Binding(
                    get: { state.loginItem },
                    set: { _ in actions.toggleLoginItem(); state.refresh() }))
            }
            Section {
                LabeledContent("Versi", value: SettingsState.version)
                HStack {
                    Button(state.checkingUpdate ? "Memeriksa…" : "Cek pembaruan") { state.checkForUpdate() }
                        .disabled(state.checkingUpdate)
                    if let text = state.updateText {
                        Text(text).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = state.updateURL {
                        Button("Unduh") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Link("Situs & panduan", destination: URL(string: "https://achmadtaufikhidayatullah.github.io/NotchIsland/")!)
                Link("Source di GitHub", destination: URL(string: "https://github.com/achmadtaufikhidayatullah/NotchIsland")!)
            } header: { Text("Tentang") }
            Section {
                LabeledContent("Device", value: "\(DeviceInfo.marketingName) (\(DeviceInfo.modelIdentifier))")
                Button("Keluar dari NotchIsland") { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - Pengendali jendela

final class SettingsWindowController {
    private var window: NSWindow?
    private let state = SettingsState()

    func show(model: NotchModel, actions: SettingsActions, section: SettingsSection? = nil) {
        if let section { state.section = section }
        state.refresh()
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(model: model, state: state, actions: actions))
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Pengaturan NotchIsland"
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
