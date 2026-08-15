import XCTest
@testable import LinkGlint

final class EgressIPRefreshPolicyTests: XCTestCase {
    func testRefreshIntervalWithoutVPN() {
        XCTAssertEqual(EgressIPRefreshPolicy.refreshInterval(panelOpen: true, vpnActive: false), 8)
        XCTAssertEqual(EgressIPRefreshPolicy.refreshInterval(panelOpen: false, vpnActive: false), 60)
    }

    func testRefreshIntervalWithVPNActive() {
        XCTAssertEqual(EgressIPRefreshPolicy.refreshInterval(panelOpen: true, vpnActive: true), 2)
        XCTAssertEqual(EgressIPRefreshPolicy.refreshInterval(panelOpen: false, vpnActive: true), 15)
    }

    func testFailureRetryInterval() {
        XCTAssertEqual(EgressIPRefreshPolicy.failureRetryInterval(panelOpen: false, vpnActive: false), 60)
        XCTAssertEqual(EgressIPRefreshPolicy.failureRetryInterval(panelOpen: true, vpnActive: false), 2)
        XCTAssertEqual(EgressIPRefreshPolicy.failureRetryInterval(panelOpen: false, vpnActive: true), 2)
    }

    func testShouldScheduleFailureRetry() {
        XCTAssertFalse(EgressIPRefreshPolicy.shouldScheduleFailureRetry(panelOpen: false, vpnActive: false, attempt: 0))
        XCTAssertTrue(EgressIPRefreshPolicy.shouldScheduleFailureRetry(panelOpen: true, vpnActive: false, attempt: 0))
        XCTAssertTrue(EgressIPRefreshPolicy.shouldScheduleFailureRetry(panelOpen: false, vpnActive: true, attempt: 2))
        XCTAssertFalse(EgressIPRefreshPolicy.shouldScheduleFailureRetry(panelOpen: true, vpnActive: true, attempt: 3))
    }

    func testBurstRefreshDelays() {
        XCTAssertEqual(EgressIPRefreshPolicy.burstRefreshDelays, [0.5, 2, 5])
    }

    func testRequestCoalescerKeepsOnlyOneForcedFollowUp() {
        var coalescer = EgressIPRequestCoalescer()
        XCTAssertTrue(coalescer.begin(force: false))
        XCTAssertFalse(coalescer.begin(force: false))
        XCTAssertFalse(coalescer.begin(force: true))
        XCTAssertFalse(coalescer.begin(force: true))
        XCTAssertTrue(coalescer.finish())
        XCTAssertFalse(coalescer.inFlight)

        XCTAssertTrue(coalescer.begin(force: true))
        XCTAssertFalse(coalescer.finish())
    }

    func testRequestCoalescerCancelDropsPendingWork() {
        var coalescer = EgressIPRequestCoalescer()
        XCTAssertTrue(coalescer.begin(force: false))
        XCTAssertFalse(coalescer.begin(force: true))
        coalescer.cancel()
        XCTAssertFalse(coalescer.inFlight)
        XCTAssertTrue(coalescer.begin(force: false))
        XCTAssertFalse(coalescer.finish())
    }
}
