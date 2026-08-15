import XCTest
@testable import LinkGlint

final class NetworkRefreshCoordinatorTests: XCTestCase {
    func testMutationDefersAndUpgradesRefresh() {
        let coordinator = NetworkRefreshCoordinator()
        XCTAssertNil(coordinator.request(showingErrors: false, mutationActive: true))
        XCTAssertNil(coordinator.request(showingErrors: true, mutationActive: true))
        XCTAssertEqual(coordinator.request(showingErrors: false, mutationActive: false), true)
    }

    func testRunningRefreshCoalescesOneFollowUp() {
        let coordinator = NetworkRefreshCoordinator()
        XCTAssertEqual(coordinator.request(showingErrors: false, mutationActive: false), false)
        XCTAssertNil(coordinator.request(showingErrors: false, mutationActive: false))
        XCTAssertNil(coordinator.request(showingErrors: true, mutationActive: false))
        XCTAssertEqual(coordinator.finish(), true)
        XCTAssertEqual(coordinator.request(showingErrors: true, mutationActive: false), true)
    }

    func testRetryAndPendingRequestAreCombined() {
        let coordinator = NetworkRefreshCoordinator()
        XCTAssertNotNil(coordinator.request(showingErrors: false, mutationActive: false))
        XCTAssertNil(coordinator.request(showingErrors: false, mutationActive: false))
        XCTAssertEqual(coordinator.finish(retryingWith: true), true)
    }

    func testGenerationInvalidationIsMonotonic() {
        let coordinator = NetworkRefreshCoordinator()
        let original = coordinator.generation
        coordinator.invalidateGeneration()
        coordinator.invalidateGeneration()
        XCTAssertEqual(coordinator.generation, original + 2)
    }
}
