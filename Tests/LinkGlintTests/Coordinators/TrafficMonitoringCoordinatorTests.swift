import XCTest
@testable import LinkGlint

final class TrafficMonitoringCoordinatorTests: XCTestCase {
    func testPipelineDoesNotStartTwice() throws {
        let coordinator = TrafficMonitoringCoordinator()
        let ticket = try XCTUnwrap(coordinator.begin(.process))

        XCTAssertTrue(coordinator.isRunning(.process))
        XCTAssertNil(coordinator.begin(.process))
        XCTAssertTrue(coordinator.complete(ticket))
        XCTAssertFalse(coordinator.isRunning(.process))
        XCTAssertNotNil(coordinator.begin(.process))
    }

    func testInvalidatedCompletionCannotFinishNewGeneration() throws {
        let coordinator = TrafficMonitoringCoordinator()
        let old = try XCTUnwrap(coordinator.begin(.interface))
        coordinator.invalidate(.interface)
        let current = try XCTUnwrap(coordinator.begin(.interface))

        XCTAssertFalse(coordinator.complete(old))
        XCTAssertTrue(coordinator.isRunning(.interface))
        XCTAssertTrue(coordinator.complete(current))
    }

    func testPipelinesHaveIndependentCancellation() throws {
        let coordinator = TrafficMonitoringCoordinator()
        let interface = try XCTUnwrap(coordinator.begin(.interface))
        let process = try XCTUnwrap(coordinator.begin(.process))
        let vpn = try XCTUnwrap(coordinator.begin(.vpn))
        coordinator.invalidate(.process)

        XCTAssertTrue(coordinator.complete(interface))
        XCTAssertFalse(coordinator.complete(process))
        XCTAssertTrue(coordinator.complete(vpn))
    }

    func testInvalidateAllRejectsEveryOutstandingTicket() throws {
        let coordinator = TrafficMonitoringCoordinator()
        let tickets = try TrafficMonitoringCoordinator.Pipeline.allCases.map {
            try XCTUnwrap(coordinator.begin($0))
        }
        coordinator.invalidateAll()

        XCTAssertTrue(tickets.allSatisfy { !coordinator.complete($0) })
    }
}
