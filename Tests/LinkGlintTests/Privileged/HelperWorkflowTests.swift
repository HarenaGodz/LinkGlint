import XCTest
@testable import LinkGlintHelperSupport

final class HelperWorkflowTests: XCTestCase {
    private struct StubError: Error, CustomStringConvertible {
        let description: String
    }

    private final class FakeExecutor: HelperCommandExecutor {
        struct Call: Equatable {
            let executable: String
            let arguments: [String]
            let timeout: TimeInterval
        }

        var calls: [Call] = []
        var handler: ([String]) throws -> String = { _ in "" }

        func run(
            _ executable: String,
            arguments: [String],
            timeout: TimeInterval
        ) throws -> String {
            calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            return try handler(arguments)
        }
    }

    func testStatusAndDirectOperationsUseFixedExecutablesAndArguments() throws {
        let executor = FakeExecutor()
        let workflow = HelperWorkflow(executor: executor)

        XCTAssertEqual(try workflow.execute(.status), "LinkGlintHelper ready 3")
        try workflow.execute(.service(name: "Wi-Fi", state: "on"))
        try workflow.execute(.wifi(device: "en0", state: "off"))
        try workflow.execute(.joinWiFi(device: "en0", network: "Office"))
        try workflow.execute(.rename(oldName: "Old", newName: "New"))
        try workflow.execute(.dns(service: "Wi-Fi", values: ["1.1.1.1"]))
        try workflow.execute(.order(services: ["Wi-Fi", "Ethernet"]))

        XCTAssertEqual(executor.calls.map(\.executable), Array(repeating: "/usr/sbin/networksetup", count: 6))
        XCTAssertEqual(executor.calls.map(\.arguments), [
            ["-setnetworkserviceenabled", "Wi-Fi", "on"],
            ["-setairportpower", "en0", "off"],
            ["-setairportnetwork", "en0", "Office"],
            ["-renamenetworkservice", "Old", "New"],
            ["-setdnsservers", "Wi-Fi", "1.1.1.1"],
            ["-ordernetworkservices", "Wi-Fi", "Ethernet"]
        ])
    }

    func testSwitchRaisesTargetOnlyAfterItIsReady() throws {
        let executor = readySwitchExecutor()
        let workflow = HelperWorkflow(executor: executor)

        try workflow.execute(.switch(
            target: "Wi-Fi",
            wifiDevice: "en0",
            currentOrder: ["Ethernet", "Wi-Fi"]
        ))

        let arguments = executor.calls.map(\.arguments)
        let enableWiFi = try XCTUnwrap(arguments.firstIndex(of: ["-setairportpower", "en0", "on"]))
        let enableService = try XCTUnwrap(arguments.firstIndex(of: ["-setnetworkserviceenabled", "Wi-Fi", "on"]))
        let readiness = try XCTUnwrap(arguments.firstIndex(of: ["-getinfo", "Wi-Fi"]))
        let reorder = try XCTUnwrap(arguments.firstIndex(of: ["-ordernetworkservices", "Wi-Fi", "Ethernet"]))
        XCTAssertLessThan(enableWiFi, enableService)
        XCTAssertLessThan(enableService, readiness)
        XCTAssertLessThan(readiness, reorder)
    }

    func testSwitchFailureRollsBackOrderServiceAndWiFiInReverseOrder() throws {
        let executor = readySwitchExecutor()
        executor.handler = { arguments in
            if arguments == ["-ordernetworkservices", "Wi-Fi", "Ethernet"] {
                throw StubError(description: "reorder failed")
            }
            return Self.switchResponse(for: arguments)
        }
        let workflow = HelperWorkflow(executor: executor)

        XCTAssertThrowsError(try workflow.execute(.switch(
            target: "Wi-Fi",
            wifiDevice: "en0",
            currentOrder: ["Ethernet", "Wi-Fi"]
        ))) { error in
            XCTAssertTrue(String(describing: error).contains("reorder failed"))
        }

        XCTAssertEqual(Array(executor.calls.map(\.arguments).suffix(3)), [
            ["-ordernetworkservices", "Ethernet", "Wi-Fi"],
            ["-setnetworkserviceenabled", "Wi-Fi", "off"],
            ["-setairportpower", "en0", "off"]
        ])
    }

    func testProfileRollbackPreservesOriginalErrorAndReportsRollbackFailure() throws {
        let executor = FakeExecutor()
        executor.handler = { arguments in
            switch arguments {
            case ["-listallnetworkservices"]:
                return "An asterisk denotes that a network service is disabled.\nWi-Fi\nEthernet\n"
            case ["-getairportpower", "en0"]:
                return "Wi-Fi Power (en0): Off\n"
            case ["-listnetworkserviceorder"]:
                return Self.serviceOrderOutput
            case ["en0"]:
                return "en0: flags=8863<UP,BROADCAST,RUNNING>\n\tstatus: active\n"
            case ["-getinfo", "Wi-Fi"]:
                return "IP address: 192.0.2.10\n"
            case ["-setnetworkserviceenabled", "Ethernet", "off"]:
                throw StubError(description: "forward failed")
            case ["-setairportpower", "en0", "off"]:
                throw StubError(description: "rollback wifi failed")
            default:
                return ""
            }
        }
        let workflow = HelperWorkflow(executor: executor)
        let operations = [
            HelperProfileOperation(kind: .wifi, name: "en0", state: "on"),
            HelperProfileOperation(kind: .service, name: "Wi-Fi", state: "on"),
            HelperProfileOperation(kind: .ready, name: "Wi-Fi", state: "on"),
            HelperProfileOperation(kind: .service, name: "Ethernet", state: "off")
        ]

        XCTAssertThrowsError(try workflow.execute(.profile(operations: operations))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("forward failed"))
            XCTAssertTrue(message.contains("Rollback also failed"))
            XCTAssertTrue(message.contains("restore Wi-Fi power for en0"))
            XCTAssertTrue(message.contains("rollback wifi failed"))
        }

        XCTAssertEqual(Array(executor.calls.map(\.arguments).suffix(3)), [
            ["-setnetworkserviceenabled", "Ethernet", "on"],
            ["-setnetworkserviceenabled", "Wi-Fi", "on"],
            ["-setairportpower", "en0", "off"]
        ])
    }

    func testSwitchRejectsStaleSystemOrderBeforeMutatingAnything() throws {
        let executor = FakeExecutor()
        executor.handler = { arguments in
            if arguments == ["-listnetworkserviceorder"] {
                return "(1) Wi-Fi\n(2) Ethernet\n"
            }
            return ""
        }
        let workflow = HelperWorkflow(executor: executor)

        XCTAssertThrowsError(try workflow.execute(.switch(
            target: "Wi-Fi",
            wifiDevice: nil,
            currentOrder: ["Ethernet", "Wi-Fi"]
        )))
        XCTAssertEqual(executor.calls.map(\.arguments), [["-listnetworkserviceorder"]])
    }

    private func readySwitchExecutor() -> FakeExecutor {
        let executor = FakeExecutor()
        executor.handler = { Self.switchResponse(for: $0) }
        return executor
    }

    private static func switchResponse(for arguments: [String]) -> String {
        switch arguments {
        case ["-listnetworkserviceorder"]: return serviceOrderOutput
        case ["-listallnetworkservices"]:
            return "An asterisk denotes that a network service is disabled.\nEthernet\n*Wi-Fi\n"
        case ["-getairportpower", "en0"]: return "Wi-Fi Power (en0): Off\n"
        case ["en0"]: return "en0: flags=8863<UP,BROADCAST,RUNNING>\n\tstatus: active\n"
        case ["-getinfo", "Wi-Fi"]: return "IP address: 192.0.2.10\n"
        default: return ""
        }
    }

    private static let serviceOrderOutput = """
    (1) Ethernet
    (Hardware Port: Ethernet, Device: en1)
    (2) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)
    """
}
