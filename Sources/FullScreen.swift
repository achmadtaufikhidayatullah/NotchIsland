import AppKit

/// Mendeteksi app di depan yang sedang full-screen (video, presentasi, Space full-screen).
/// Di layar tanpa notch, island disembunyikan supaya tidak menutupi konten.
enum FullScreenDetector {
    /// Jendela app terdepan menutupi seluruh layar (termasuk area menu bar).
    /// Hanya memakai posisi & ukuran jendela — tidak perlu izin Screen Recording.
    static func isActive(on screenFrame: CGRect) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // Koordinat CGWindow: origin di kiri-atas layar utama; NSScreen: kiri-bawah.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let target = CGRect(x: screenFrame.minX, y: mainHeight - screenFrame.maxY,
                            width: screenFrame.width, height: screenFrame.height)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.insetBy(dx: -1, dy: -1).contains(target) { return true }
        }
        return false
    }
}

extension NotchDetector {
    /// Uji perilaku Mac tanpa notch di Mac ber-notch:
    /// `open NotchIsland.app --args --simulate-no-notch`
    static let simulateNoNotch = CommandLine.arguments.contains("--simulate-no-notch")
}
