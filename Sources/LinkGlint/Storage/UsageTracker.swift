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
    private var lastPersistedUptime: TimeInterval?

    private(set) var sessionReceivedBytes: UInt64 = 0
    private(set) var sessionSentBytes: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        key: String = "dailyNetworkUsage.v1",
        calendar: Calendar = .autoupdatingCurrent
    ) {
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
        usage.receivedBytes = addingWithoutOverflow(usage.receivedBytes, receivedBytes)
        usage.sentBytes = addingWithoutOverflow(usage.sentBytes, sentBytes)
        records[day] = usage
        sessionReceivedBytes = addingWithoutOverflow(sessionReceivedBytes, receivedBytes)
        sessionSentBytes = addingWithoutOverflow(sessionSentBytes, sentBytes)

        let uptime = ProcessInfo.processInfo.systemUptime
        if lastPersistedUptime.map({ uptime - $0 >= 15 }) ?? true {
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
            lastPersistedUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    private func dateKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        rhs > UInt64.max - lhs ? UInt64.max : lhs + rhs
    }
}

struct AppPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showMenuBarTitle": true,
            "showMenuBarSpeed": true,
            // Two lines keep the status item compact when both the network name
            // and live traffic are visible.
            "menuBarSpeedTwoLines": true,
            "menuBarSpeedInBits": false,
            "menuBarTrafficIndicatorStyle": MenuBarTrafficIndicatorStyle.coloredDots.rawValue,
            "trafficRefreshInterval": 2.0,
            // A login item should start quietly in the menu bar. Users who use
            // the management window continuously can opt into showing it.
            "openWindowAtLaunch": false,
            "autoRunDiagnostics": false
        ])
    }

    var showMenuBarTitle: Bool {
        get { defaults.bool(forKey: "showMenuBarTitle") }
        nonmutating set { defaults.set(newValue, forKey: "showMenuBarTitle") }
    }

    var showMenuBarSpeed: Bool {
        get { defaults.bool(forKey: "showMenuBarSpeed") }
        nonmutating set { defaults.set(newValue, forKey: "showMenuBarSpeed") }
    }

    var menuBarSpeedTwoLines: Bool {
        get { defaults.bool(forKey: "menuBarSpeedTwoLines") }
        nonmutating set { defaults.set(newValue, forKey: "menuBarSpeedTwoLines") }
    }

    var menuBarSpeedInBits: Bool {
        get { defaults.bool(forKey: "menuBarSpeedInBits") }
        nonmutating set { defaults.set(newValue, forKey: "menuBarSpeedInBits") }
    }

    var menuBarTrafficIndicatorStyle: MenuBarTrafficIndicatorStyle {
        get {
            MenuBarTrafficIndicatorStyle(
                rawValue: defaults.string(forKey: "menuBarTrafficIndicatorStyle") ?? ""
            ) ?? .coloredDots
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "menuBarTrafficIndicatorStyle") }
    }

    var trafficRefreshInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: "trafficRefreshInterval")
            return [1.0, 2.0, 5.0].contains(value) ? value : 2.0
        }
        nonmutating set { defaults.set(newValue, forKey: "trafficRefreshInterval") }
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
