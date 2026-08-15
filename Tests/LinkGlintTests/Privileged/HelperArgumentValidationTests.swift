import XCTest
import LinkGlintHelperSupport

final class HelperArgumentValidationTests: XCTestCase {
    func testValidateNameRejectsEmptyControlAndOverlong() {
        XCTAssertNoThrow(try HelperArgumentValidation.validateName("Wi-Fi", label: "service name"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateName("", label: "service name"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateName("bad\nname", label: "service name"))
        XCTAssertThrowsError(
            try HelperArgumentValidation.validateName(String(repeating: "a", count: 257), label: "service name")
        )
    }

    func testValidateDeviceAcceptsCommonInterfaceNames() {
        XCTAssertNoThrow(try HelperArgumentValidation.validateDevice("en0"))
        XCTAssertNoThrow(try HelperArgumentValidation.validateDevice("utun3"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateDevice(""))
        XCTAssertThrowsError(try HelperArgumentValidation.validateDevice("en 0"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateDevice("../../etc/passwd"))
    }

    func testValidateStateOnlyAllowsOnOff() {
        XCTAssertNoThrow(try HelperArgumentValidation.validateState("on"))
        XCTAssertNoThrow(try HelperArgumentValidation.validateState("off"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateState("ON"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateState("maybe"))
    }

    func testValidateIPAddressAcceptsIPv4AndIPv6() {
        XCTAssertNoThrow(try HelperArgumentValidation.validateIPAddress("1.1.1.1"))
        XCTAssertNoThrow(try HelperArgumentValidation.validateIPAddress("2001:db8::1"))
        XCTAssertNoThrow(try HelperArgumentValidation.validateIPAddress("fe80::1%en0"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateIPAddress("not-an-ip"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateIPAddress("1.2.3"))
    }

    func testUsableIPAddressFiltersLocalAndLinkLocal() {
        XCTAssertTrue(HelperArgumentValidation.isUsableIPAddress("203.0.113.8"))
        XCTAssertTrue(HelperArgumentValidation.isUsableIPAddress("2001:db8::1"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress(""))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("none"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("0.0.0.0"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("127.0.0.1"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("169.254.1.1"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("::1"))
        XCTAssertFalse(HelperArgumentValidation.isUsableIPAddress("fe80::1"))
    }

    func testValidateIPAddressRejectsInvalidIPv6Scope() {
        XCTAssertThrowsError(try HelperArgumentValidation.validateIPAddress("fe80::1%"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateIPAddress("fe80::1%en 0"))
        XCTAssertThrowsError(try HelperArgumentValidation.validateIPAddress("fe80::1%../../tmp"))
    }

    func testRequestParserCoversCoreOperations() throws {
        XCTAssertEqual(try HelperRequest.parse(["status"]), .status)
        XCTAssertEqual(
            try HelperRequest.parse(["service", "Wi-Fi", "on"]),
            .service(name: "Wi-Fi", state: "on")
        )
        XCTAssertEqual(
            try HelperRequest.parse(["dns", "Wi-Fi", "1.1.1.1", "2606:4700:4700::1111"]),
            .dns(service: "Wi-Fi", values: ["1.1.1.1", "2606:4700:4700::1111"])
        )
        XCTAssertEqual(
            try HelperRequest.parse(["switch", "USB LAN", "-", "Wi-Fi", "USB LAN"]),
            .switch(target: "USB LAN", wifiDevice: nil, currentOrder: ["Wi-Fi", "USB LAN"])
        )
    }

    func testRequestParserRejectsAmbiguousAndDuplicateOperations() {
        XCTAssertThrowsError(try HelperRequest.parse(["dns", "Wi-Fi", "empty", "1.1.1.1"]))
        XCTAssertThrowsError(try HelperRequest.parse(["order", "Wi-Fi", "Wi-Fi"]))
        XCTAssertThrowsError(try HelperRequest.parse(["switch", "Wi-Fi", "-", "Ethernet"]))
        XCTAssertThrowsError(try HelperRequest.parse([
            "profile", "service", "Wi-Fi", "on", "service", "Wi-Fi", "off"
        ]))
        XCTAssertThrowsError(try HelperRequest.parse([
            "profile", "ready", "Wi-Fi", "on", "ready", "Wi-Fi", "on",
            "service", "Wi-Fi", "on"
        ]))
    }
}
