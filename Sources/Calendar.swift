import AppKit
import EventKit
import SwiftUI

// MARK: - Data kalender (EventKit — membaca Kalender macOS, termasuk akun Google/iCloud yang tersinkron)

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    /// Link rapat (Zoom / Google Meet / Teams) bila ada di URL, lokasi, atau catatan acara.
    let meetingURL: URL?
}

final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var events: [CalendarEvent] = []
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    private init() {
        updateAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { [weak self] _ in self?.reload() }
        reload()
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    /// Diminta hanya saat pengguna menekan tombol di widget — tidak pernah mendadak.
    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateAccess()
                self?.reload()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    /// Hari yang tampil di strip: 2 hari lalu sampai 4 hari ke depan.
    var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (-2...4).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    func select(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        reload()
    }

    func reload() {
        guard access == .granted else { events = []; return }
        let start = selectedDay
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { e in
                CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString,
                              title: e.title?.isEmpty == false ? e.title! : "(Tanpa judul)",
                              start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                              color: Color(cgColor: e.calendar.cgColor ?? NSColor.systemBlue.cgColor),
                              meetingURL: Self.meetingURL(in: e))
            }
    }

    private static func meetingURL(in event: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]
        let candidates = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in candidates {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let host = url.host, hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }
}

// MARK: - Widget

struct CalendarWidget: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var cal = CalendarStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            monthColumn
            VStack(alignment: .leading, spacing: 10) {
                weekStrip
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.tile, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { cal.reload() }
    }

    private var monthColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(cal.selectedDay, format: .dateTime.month(.abbreviated))
                .font(.system(size: 22, weight: .bold))
            Text(cal.selectedDay, format: .dateTime.year())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.secondary)
        }
        .frame(width: 58, alignment: .leading)
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(cal.days, id: \.self) { day in
                let isToday = Calendar.current.isDateInToday(day)
                let selected = Calendar.current.isDate(day, inSameDayAs: cal.selectedDay)
                Button { withAnimation(islandSpring) { cal.select(day) } } label: {
                    VStack(spacing: 3) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isToday ? Color.white : Palette.secondary)
                        Text(day, format: .dateTime.day())
                            .font(.system(size: 13, weight: isToday ? .bold : .semibold))
                            .monospacedDigit()
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(isToday ? Color(red: 0.04, green: 0.52, blue: 1) : .clear))
                            .overlay(Circle().strokeBorder(selected && !isToday ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch cal.access {
        case .granted:
            if cal.events.isEmpty {
                Text(Calendar.current.isDateInToday(cal.selectedDay) ? "Tidak ada acara hari ini" : "Tidak ada acara")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cal.events.prefix(2)) { eventRow($0) }
                    if cal.events.count > 2 {
                        Text("+\(cal.events.count - 2) acara lagi")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                    }
                }
            }
        case .notDetermined:
            HStack {
                Text("Tampilkan acara dari Kalender macOS").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Izinkan akses") { cal.requestAccess() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .denied:
            HStack {
                Text("Akses Kalender ditolak").font(.system(size: 11)).foregroundStyle(.orange)
                Spacer()
                Button("Buka Pengaturan") { cal.openPrivacySettings() }.controlSize(.small)
            }
        }
    }

    private func eventRow(_ e: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(e.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(e.isAllDay ? "Sepanjang hari"
                     : "\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 6)
            if let url = e.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Gabung", systemImage: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.green.opacity(0.9)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }
}
