import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

extension NotchModel {
    static let shelfKey = "shelfPaths"

    /// Muat isi shelf yang tersimpan; file yang sudah tidak ada dibuang.
    static func loadShelf() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: shelfKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addToShelf(_ urls: [URL]) {
        let fresh = urls.filter { url in !shelf.contains(where: { $0.path == url.path }) }
        guard !fresh.isEmpty else { return }
        shelf.append(contentsOf: fresh)
    }

    func removeFromShelf(_ url: URL) { shelf.removeAll { $0.path == url.path } }
    func clearShelf() { shelf.removeAll() }

    /// File yang dipindah/dihapus di luar app ikut hilang dari shelf.
    func pruneShelf() {
        let alive = shelf.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive.count != shelf.count { shelf = alive }
    }

    /// Kirim lewat AirDrop (membuka pemilih perangkat AirDrop macOS).
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if service.canPerform(withItems: urls) { service.perform(withItems: urls) }
    }

    /// Ada file yang sedang diseret mendekati notch → buka island di tab Shelf.
    func beginFileDrag() {
        guard enabledWidgets.contains(.shelf), !fileDragActive else { return }
        fileDragActive = true
        selectedWidget = .shelf
    }
}

/// Ambil URL file dari item yang di-drop (Finder, desktop, app lain).
func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

// MARK: - Tampilan widget Shelf

struct ShelfWidget: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var targets = ShelfTargets.shared

    var body: some View {
        HStack(spacing: 10) {
            shelfTile
            airDropTile.frame(width: 118)
        }
    }

    // Kiri: daftar file yang dititip, atau ajakan untuk menyeret file ke sini.
    private var shelfTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Shelf", systemImage: "tray.full.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.shelf.isEmpty {
                    Button("Hapus semua") { withAnimation(islandSpring) { model.clearShelf() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
            }
            if model.shelf.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 18))
                    Text("Seret file ke sini untuk dititip").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(targets.shelf ? Color.white : Palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.shelf, id: \.path) { ShelfItem(url: $0, model: model) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dropBackground(targets.shelf, radius: 18))
        .onDrop(of: [UTType.fileURL], isTargeted: $targets.shelf) { providers in
            loadFileURLs(from: providers) { urls in withAnimation(islandSpring) { model.addToShelf(urls) } }
            return true
        }
    }

    // Kanan: lepas file di sini untuk mengirimnya lewat AirDrop.
    private var airDropTile: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(targets.airDrop ? Color(red: 0.04, green: 0.52, blue: 1) : Color.white.opacity(0.1))
                    .frame(width: 46, height: 46)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
            }
            .scaleEffect(targets.airDrop ? 1.1 : 1)
            Text("AirDrop").font(.system(size: 11, weight: .semibold))
            Text(model.shelf.isEmpty ? "Lepas file di sini" : "Klik: kirim semua")
                .font(.system(size: 9))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropBackground(targets.airDrop, radius: 18))
        .contentShape(Rectangle())
        .onTapGesture { model.airDrop(model.shelf) }
        .onDrop(of: [UTType.fileURL], isTargeted: $targets.airDrop) { providers in
            loadFileURLs(from: providers) { model.airDrop($0) }
            return true
        }
        .animation(islandSpring, value: targets.airDrop)
        .help("Lepas file untuk mengirim lewat AirDrop, atau klik untuk mengirim semua isi shelf")
    }

    private func dropBackground(_ targeted: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.tile)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(targeted ? Color.white.opacity(0.7) : Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])))
    }
}

/// Status "sedang ditunjuk" untuk tiap zona drop (tanpa @State — toolchain tanpa plugin macro).
final class ShelfTargets: ObservableObject {
    static let shared = ShelfTargets()
    @Published var shelf = false
    @Published var airDrop = false
}

struct ShelfItem: View {
    let url: URL
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: AppIcons.fileIcon(url))
                .resizable()
                .frame(width: 36, height: 36)
            Text(url.lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 62)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Seret keluar ke app/folder lain; file aslinya tidak berubah.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Buka") { NSWorkspace.shared.open(url) }
            Button("Tampilkan di Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Kirim via AirDrop") { model.airDrop([url]) }
            Divider()
            Button("Hapus dari shelf") { withAnimation(islandSpring) { model.removeFromShelf(url) } }
        }
        .help("\(url.path)\nSeret keluar · klik dua kali untuk membuka · klik kanan untuk opsi")
    }
}

// MARK: - Penangkap drop di area notch fisik

/// Jendela kecil tak terlihat tepat di atas notch fisik. Area itu tertutup kamera (tidak bisa diklik),
/// jadi aman dibiarkan menerima event: begitu file diseret ke sana, island terbuka di tab Shelf.
final class DropCatcherView: NSView {
    var onFileDragEntered: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDragEntered?()
        return .copy
    }
    // Drop sungguhan ditangani oleh island yang terbuka di atasnya.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
