import XCTest
@testable import NetBar

final class UsageTrackerTests: XCTestCase {
    private let suite = "local.codex.NetBar.tests.usage"
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
        XCTAssertTrue(preferences.openWindowAtLaunch)
        XCTAssertFalse(preferences.autoRunDiagnostics)
        preferences.showMenuBarTitle = false
        XCTAssertFalse(AppPreferences(defaults: defaults).showMenuBarTitle)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
