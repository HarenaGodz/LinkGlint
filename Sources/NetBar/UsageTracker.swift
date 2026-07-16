import Foundation

struct DailyNetworkUsage: Codable, Equatable {
    let dateKey: String
    var receivedBytes: UInt64
    var sentBytes: UInt64
}

final class UsageTracker {
    private let defaults: UserDefaults
    private let key: String
    private let calendar: Calendar
    private var records: [String: DailyNetworkUsage]
    private var lastPersistedAt: Date?

    private(set) var sessionReceivedBytes: UInt64 = 0
    private(set) var sessionSentBytes: UInt64 = 0

    init(defaults: UserDefaults = .standard, key: String = "dailyNetworkUsage.v1", calendar: Calendar = .current) {
        self.defaults = defaults
        self.key = key
        self.calendar = calendar
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: DailyNetworkUsage].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(receivedBytes: UInt64, sentBytes: UInt64, at date: Date = Date()) {
        guard receivedBytes > 0 || sentBytes > 0 else { return }
        let day = dateKey(for: date)
        var usage = records[day] ?? DailyNetworkUsage(dateKey: day, receivedBytes: 0, sentBytes: 0)
        usage.receivedBytes = usage.receivedBytes &+ receivedBytes
        usage.sentBytes = usage.sentBytes &+ sentBytes
        records[day] = usage
        sessionReceivedBytes = sessionReceivedBytes &+ receivedBytes
        sessionSentBytes = sessionSentBytes &+ sentBytes

        if lastPersistedAt.map({ date.timeIntervalSince($0) >= 15 }) ?? true {
            flush(at: date)
        }
    }

    func usage(for date: Date = Date()) -> DailyNetworkUsage {
        let day = dateKey(for: date)
        return records[day] ?? DailyNetworkUsage(dateKey: day, receivedBytes: 0, sentBytes: 0)
    }

    func recentDays(limit: Int = 7) -> [DailyNetworkUsage] {
        records.values.sorted { $0.dateKey > $1.dateKey }.prefix(max(limit, 0)).map { $0 }
    }

    func resetToday(at date: Date = Date()) {
        let day = dateKey(for: date)
        records[day] = DailyNetworkUsage(dateKey: day, receivedBytes: 0, sentBytes: 0)
        flush(at: date)
    }

    func flush(at date: Date = Date()) {
        // Retain a compact 30-day history.
        let retainedKeys = Set(records.keys.sorted(by: >).prefix(30))
        records = records.filter { retainedKeys.contains($0.key) }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
            lastPersistedAt = date
        }
    }

    private func dateKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showMenuBarTitle": true,
            "openWindowAtLaunch": true,
            "autoRunDiagnostics": false
        ])
    }

    var showMenuBarTitle: Bool {
        get { defaults.bool(forKey: "showMenuBarTitle") }
        nonmutating set { defaults.set(newValue, forKey: "showMenuBarTitle") }
    }

    var openWindowAtLaunch: Bool {
        get { defaults.bool(forKey: "openWindowAtLaunch") }
        nonmutating set { defaults.set(newValue, forKey: "openWindowAtLaunch") }
    }

    var autoRunDiagnostics: Bool {
        get { defaults.bool(forKey: "autoRunDiagnostics") }
        nonmutating set { defaults.set(newValue, forKey: "autoRunDiagnostics") }
    }
}
