import XCTest
@testable import LinkGlint

final class EgressIPRefreshCoordinatorTests: XCTestCase {
    func testForcedRequestsCoalesceIntoOneFollowUp() throws {
        let coordinator = EgressIPRefreshCoordinator()
        let ticket = try XCTUnwrap(coordinator.begin(force: true, now: 10, refreshInterval: 60))

        XCTAssertNil(coordinator.begin(force: false, now: 11, refreshInterval: 60))
        XCTAssertNil(coordinator.begin(force: true, now: 12, refreshInterval: 60))
        XCTAssertNil(coordinator.begin(force: true, now: 13, refreshInterval: 60))

        let completion = try XCTUnwrap(coordinator.completeSuccess(ticket, now: 14))
        XCTAssertTrue(completion.forcedFollowUp)
        XCTAssertNotNil(coordinator.begin(force: true, now: 14, refreshInterval: 60))
    }

    func testSuccessThrottlesNormalRefreshButNotForcedRefresh() throws {
        let coordinator = EgressIPRefreshCoordinator()
        let ticket = try XCTUnwrap(coordinator.begin(force: false, now: 100, refreshInterval: 60))
        XCTAssertNotNil(coordinator.completeSuccess(ticket, now: 101))

        XCTAssertNil(coordinator.begin(force: false, now: 150, refreshInterval: 60))
        XCTAssertNotNil(coordinator.begin(force: true, now: 150, refreshInterval: 60))
    }

    func testNetworkInvalidationCancelsTaskAndRejectsOldCompletion() throws {
        let coordinator = EgressIPRefreshCoordinator()
        let ticket = try XCTUnwrap(coordinator.begin(force: true, now: 1, refreshInterval: 60))
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        coordinator.attach(task, to: ticket)

        coordinator.invalidateNetworkGeneration(clearSuccessTime: true)

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.completeSuccess(ticket, now: 2))
        XCTAssertNotNil(coordinator.begin(force: false, now: 2, refreshInterval: 60))
    }

    func testFailureCountTracksRetryAttemptAndResetsAfterSuccess() throws {
        let coordinator = EgressIPRefreshCoordinator()
        let first = try XCTUnwrap(coordinator.begin(force: true, now: 1, refreshInterval: 60))
        XCTAssertNotNil(coordinator.completeFailure(first))
        XCTAssertEqual(coordinator.consecutiveFailures, 1)
        XCTAssertEqual(coordinator.failureRetryAttempt, 0)

        let second = try XCTUnwrap(coordinator.begin(force: true, now: 2, refreshInterval: 60))
        XCTAssertNotNil(coordinator.completeFailure(second))
        XCTAssertEqual(coordinator.failureRetryAttempt, 1)

        let third = try XCTUnwrap(coordinator.begin(force: true, now: 3, refreshInterval: 60))
        XCTAssertNotNil(coordinator.completeSuccess(third, now: 4))
        XCTAssertEqual(coordinator.consecutiveFailures, 0)
    }

    func testGeoCacheRefreshesWhenMissingChangedOrExpired() {
        let coordinator = EgressIPRefreshCoordinator(geoCacheLifetime: 100)

        XCTAssertTrue(coordinator.shouldRefreshGeo(for: "192.0.2.1", hasCachedValue: false, now: 10))
        coordinator.recordGeoSuccess(for: "192.0.2.1", now: 10)
        XCTAssertFalse(coordinator.shouldRefreshGeo(for: "192.0.2.1", hasCachedValue: true, now: 109))
        XCTAssertTrue(coordinator.shouldRefreshGeo(for: "192.0.2.1", hasCachedValue: true, now: 110))
        XCTAssertTrue(coordinator.shouldRefreshGeo(for: "198.51.100.1", hasCachedValue: true, now: 20))
    }
}
