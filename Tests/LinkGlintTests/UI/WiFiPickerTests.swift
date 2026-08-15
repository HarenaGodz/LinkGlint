import XCTest
@testable import LinkGlint

final class WiFiPickerTests: XCTestCase {
    func testPendingRetriesCoalesceWithoutExtendingTheirDeadline() throws {
        var request = WiFiPendingScanRequest()

        let timeoutToken = try XCTUnwrap(request.enqueue())
        XCTAssertTrue(request.isPending)
        XCTAssertNil(request.enqueue())

        XCTAssertTrue(request.expire(token: timeoutToken))
        XCTAssertFalse(request.isPending)
        XCTAssertFalse(request.expire(token: timeoutToken))
    }

    func testCancellingPendingRetryInvalidatesItsDelayedTimeout() throws {
        var request = WiFiPendingScanRequest()
        let staleToken = try XCTUnwrap(request.enqueue())

        request.cancel()
        let currentToken = try XCTUnwrap(request.enqueue())

        XCTAssertFalse(request.expire(token: staleToken))
        XCTAssertTrue(request.isPending)
        XCTAssertTrue(request.expire(token: currentToken))
    }

    func testPendingRetryIsConsumedOnlyOnce() {
        var request = WiFiPendingScanRequest()
        _ = request.enqueue()

        XCTAssertTrue(request.consume())
        XCTAssertFalse(request.consume())
        XCTAssertFalse(request.isPending)
    }
}
