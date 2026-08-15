import XCTest
@testable import LinkGlint

final class TrafficMonitoringTests: XCTestCase {
    func testProcessTrafficRunsOnlyWhilePanelIsOpen() {
        XCTAssertTrue(ProcessTrafficSamplingPolicy.shouldRun(panelOpen: true))
        XCTAssertFalse(ProcessTrafficSamplingPolicy.shouldRun(panelOpen: false))
        XCTAssertEqual(ProcessTrafficSamplingPolicy.refreshInterval, 2)
    }

    func testActiveVPNDetectorRequiresUpTunnelWithRoutableAddress() {
        let addresses = [
            VPNInterfaceAddress(name: "utun0", address: "fe80::1", isUp: true),
            VPNInterfaceAddress(name: "utun1", address: "198.18.0.1", isUp: false),
            VPNInterfaceAddress(name: "utun2", address: "198.18.0.2", isUp: true),
            VPNInterfaceAddress(name: "en0", address: "192.168.1.5", isUp: true),
            VPNInterfaceAddress(name: "ppp0", address: "2001:db8::5", isUp: true)
        ]
        XCTAssertEqual(
            ActiveVPNInterfaceDetector.activeInterfaceNames(in: addresses),
            ["utun2", "ppp0"]
        )
    }

    func testRoutableAddressRejectsLoopbackUnspecifiedAndLinkLocal() {
        for address in ["", "0.0.0.0", "127.0.0.1", "169.254.2.3", "::", "::1", "fe80::1"] {
            XCTAssertFalse(ActiveVPNInterfaceDetector.isRoutableAddress(address), address)
        }
        XCTAssertTrue(ActiveVPNInterfaceDetector.isRoutableAddress("198.18.0.1"))
        XCTAssertTrue(ActiveVPNInterfaceDetector.isRoutableAddress("2001:db8::1"))
    }
}
