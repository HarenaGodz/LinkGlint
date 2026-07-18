import XCTest
@testable import LinkGlint

final class UsageTrackerTests: XCTestCase {
    private let suite = "local.codex.LinkGlint.tests.usage"
    private var defaults: UserDefaults!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        calendar = nil
        super.tearDown()
    }

    func testTracksDailyAndSessionUsage() {
        let tracker = UsageTracker(defaults: defaults, key: "usage", calendar: calendar)
        let date = makeDate(2026, 7, 16)
        tracker.record(receivedBytes: 1_000, sentBytes: 250, at: date)
        tracker.record(receivedBytes: 500, sentBytes: 100, at: date.addingTimeInterval(20))

        XCTAssertEqual(tracker.usage(for: date).receivedBytes, 1_500)
        XCTAssertEqual(tracker.usage(for: date).sentBytes, 350)
        XCTAssertEqual(tracker.sessionReceivedBytes, 1_500)
        XCTAssertEqual(tracker.sessionSentBytes, 350)
    }

    func testPersistsUsageAcrossInstances() {
        let date = makeDate(2026, 7, 16)
        let first = UsageTracker(defaults: defaults, key: "usage", calendar: calendar)
        first.record(receivedBytes: 4_096, sentBytes: 2_048, at: date)
        first.flush(at: date)

        let second = UsageTracker(defaults: defaults, key: "usage", calendar: calendar)
        XCTAssertEqual(second.usage(for: date).receivedBytes, 4_096)
        XCTAssertEqual(second.usage(for: date).sentBytes, 2_048)
        XCTAssertEqual(second.sessionReceivedBytes, 0)
    }

    func testResetTodayDoesNotDeleteOtherDays() {
        let tracker = UsageTracker(defaults: defaults, key: "usage", calendar: calendar)
        let firstDay = makeDate(2026, 7, 15)
        let secondDay = makeDate(2026, 7, 16)
        tracker.record(receivedBytes: 100, sentBytes: 50, at: firstDay)
        tracker.record(receivedBytes: 200, sentBytes: 75, at: secondDay)
        tracker.resetToday(at: secondDay)

        XCTAssertEqual(tracker.usage(for: secondDay).receivedBytes, 0)
        XCTAssertEqual(tracker.usage(for: firstDay).receivedBytes, 100)
    }

    func testPreferencesHaveExpectedDefaultsAndPersist() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showMenuBarTitle)
        XCTAssertTrue(preferences.showMenuBarSpeed)
        XCTAssertTrue(preferences.menuBarSpeedTwoLines)
        XCTAssertFalse(preferences.menuBarSpeedInBits)
        XCTAssertEqual(preferences.menuBarTrafficIndicatorStyle, .coloredDots)
        XCTAssertEqual(preferences.trafficRefreshInterval, 2)
        XCTAssertFalse(preferences.openWindowAtLaunch)
        XCTAssertFalse(preferences.autoRunDiagnostics)
        preferences.showMenuBarTitle = false
        preferences.showMenuBarSpeed = false
        preferences.menuBarSpeedTwoLines = false
        preferences.menuBarSpeedInBits = true
        preferences.menuBarTrafficIndicatorStyle = .coloredTriangles
        preferences.trafficRefreshInterval = 5
        XCTAssertFalse(AppPreferences(defaults: defaults).showMenuBarTitle)
        XCTAssertFalse(AppPreferences(defaults: defaults).showMenuBarSpeed)
        XCTAssertFalse(AppPreferences(defaults: defaults).menuBarSpeedTwoLines)
        XCTAssertTrue(AppPreferences(defaults: defaults).menuBarSpeedInBits)
        XCTAssertEqual(AppPreferences(defaults: defaults).menuBarTrafficIndicatorStyle, .coloredTriangles)
        XCTAssertEqual(AppPreferences(defaults: defaults).trafficRefreshInterval, 5)
    }

    func testTrafficRateHistoryKeepsNewestSamplesWithinCapacity() {
        var history = TrafficRateHistory(capacity: 3)
        for value in 1...4 {
            history.append(
                downloadBytesPerSecond: Double(value),
                uploadBytesPerSecond: Double(value * 10),
                at: Date(timeIntervalSince1970: Double(value))
            )
        }

        XCTAssertEqual(history.samples.count, 3)
        XCTAssertEqual(history.samples.map(\.downloadBytesPerSecond), [2, 3, 4])
        XCTAssertEqual(history.peakBytesPerSecond, 40)
    }

    func testTrafficRateHistorySanitizesInvalidRates() {
        var history = TrafficRateHistory(capacity: 2)
        history.append(downloadBytesPerSecond: -.infinity, uploadBytesPerSecond: .nan)

        XCTAssertEqual(history.samples.first?.downloadBytesPerSecond, 0)
        XCTAssertEqual(history.samples.first?.uploadBytesPerSecond, 0)
        XCTAssertEqual(history.peakBytesPerSecond, 1)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
