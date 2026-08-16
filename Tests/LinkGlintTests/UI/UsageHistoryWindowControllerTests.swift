import XCTest
@testable import LinkGlint

final class UsageHistoryWindowControllerTests: XCTestCase {
    func testUsageCenterCardsStretchAcrossWindowInsteadOfCollapsingToIntrinsicWidth() {
        let defaults = UserDefaults(suiteName: "local.codex.LinkGlint.tests.usage-window")!
        defaults.removePersistentDomain(forName: "local.codex.LinkGlint.tests.usage-window")
        defer { defaults.removePersistentDomain(forName: "local.codex.LinkGlint.tests.usage-window") }
        let tracker = UsageTracker(defaults: defaults, key: "usage")
        tracker.record(receivedBytes: 1_000, sentBytes: 500)
        let controller = UsageHistoryWindowController(tracker: tracker, formatBytes: { "\($0) B" })
        controller.window?.setContentSize(NSSize(width: 680, height: 560))
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let boxes = descendants(of: controller.window?.contentView).compactMap { $0 as? NSBox }
        XCTAssertGreaterThanOrEqual(boxes.filter { $0.frame.width > 580 }.count, 2)
        XCTAssertGreaterThanOrEqual(boxes.filter { $0.frame.width > 120 && $0.frame.height < 160 }.count, 4)
    }

    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendants(of:))
    }
}
