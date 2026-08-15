import XCTest
@testable import LinkGlint

final class EgressIPClientTests: XCTestCase {
    func testHedgedRequestReturnsFirstValidAndCancelsDelayedFallbacks() async {
        let recorder = InvocationRecorder()
        let producers: [@Sendable () async -> String?] = [
                {
                    await recorder.record("primary")
                    return "203.0.113.1"
                },
                {
                    await recorder.record("fallback")
                    return "203.0.113.2"
                }
        ]
        let result = await HedgedRequest.firstValid(
            producers,
            hedgeDelayNanoseconds: 200_000_000
        )
        XCTAssertEqual(result, "203.0.113.1")
        let values = await recorder.snapshot()
        XCTAssertEqual(values, ["primary"])
    }

    func testHedgedRequestUsesFallbackAfterPrimaryFailure() async {
        let producers: [@Sendable () async -> String?] = [
            { nil },
            { "198.51.100.5" }
        ]
        let result = await HedgedRequest.firstValid(
            producers,
            hedgeDelayNanoseconds: 1_000_000
        )
        XCTAssertEqual(result, "198.51.100.5")
    }
}

private actor InvocationRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}
