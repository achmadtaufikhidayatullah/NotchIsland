import Foundation

/// Satu peringatan limit yang ditampilkan sekilas di notch.
struct LimitAlert: Equatable {
    enum Kind: Equatable {
        case threshold(Int)   // pemakaian baru melewati ambang (80 / 95)
        case reset            // jendela limit baru saja reset
    }

    let provider: WidgetKind
    let title: String
    let percent: Double
    let kind: Kind
    /// Perkiraan limit habis (hanya bila sebelum waktu reset).
    let eta: Date?
}

/// Mengamati jendela limit (Claude, Antigravity) dan menghasilkan peringatan
/// saat melewati ambang atau reset, plus memperkirakan kapan limit habis.
final class LimitWatcher {
    static let thresholds = [80, 95]

    private struct Sample { let time: Date; let percent: Double }

    private var lastPercent: [String: Double] = [:]
    private var samples: [String: [Sample]] = [:]
    /// Ambang yang sudah diberi tahu per siklus reset, supaya tidak berulang.
    private var fired = Set<String>()

    /// Pengamatan pertama per jendela hanya menjadi titik awal — tidak ada peringatan
    /// untuk kondisi yang sudah ada saat app dibuka.
    func observe(provider: WidgetKind, usage: OfficialUsage, now: Date) -> [LimitAlert] {
        var alerts: [LimitAlert] = []
        for w in usage.windows {
            let key = "\(provider.rawValue)|\(w.id)"
            let p = w.percent(at: now)
            record(key: key, time: usage.capturedAt, percent: w.percent, now: now)
            defer { lastPercent[key] = p }
            guard let prev = lastPercent[key] else { continue }

            let cycle = w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
            for t in Self.thresholds where prev < Double(t) && p >= Double(t) {
                guard fired.insert("\(key)|\(cycle)|\(t)").inserted else { continue }
                alerts.append(LimitAlert(provider: provider, title: w.title, percent: p,
                                         kind: .threshold(t), eta: projection(provider: provider, window: w)))
            }
            // Turun dari pemakaian berarti ke ~0 = jendela reset; cukup penting untuk diberi tahu
            // hanya bila sebelumnya sudah terpakai banyak.
            if prev >= 50, p < 5 {
                alerts.append(LimitAlert(provider: provider, title: w.title, percent: p, kind: .reset, eta: nil))
            }
        }
        return alerts
    }

    private func record(key: String, time: Date, percent: Double, now: Date) {
        var s = samples[key, default: []]
        if s.last?.time != time {
            // Persen turun = siklus baru; sampel lama tidak relevan lagi untuk laju.
            if let last = s.last, percent < last.percent - 1 { s.removeAll() }
            s.append(Sample(time: time, percent: percent))
        }
        s.removeAll { now.timeIntervalSince($0.time) > 90 * 60 }
        samples[key] = s
    }

    /// Laju pemakaian dari sampel ≤ 90 menit terakhir (minimal rentang 5 menit),
    /// diproyeksikan ke 100%. Nil bila tidak naik, data kurang, atau aman sampai reset.
    func projection(provider: WidgetKind, window w: LimitWindow) -> Date? {
        guard let s = samples["\(provider.rawValue)|\(w.id)"], let first = s.first, let last = s.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        guard span >= 5 * 60, last.percent > first.percent, last.percent < 100 else { return nil }
        let rate = (last.percent - first.percent) / span
        let eta = last.time.addingTimeInterval((100 - last.percent) / rate)
        if let reset = w.resetsAt, eta >= reset { return nil }
        return eta
    }
}
