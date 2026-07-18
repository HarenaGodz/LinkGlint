import XCTest
@testable import LinkGlint

final class NetworkManagerTests: XCTestCase {
    func testCommandRunnerDrainsLargeOutputWithoutDeadlocking() throws {
        let output = try CommandRunner.run(
            "/bin/sh",
            ["-c", "/usr/bin/head -c 131072 /dev/zero | /usr/bin/tr '\\0' x"]
        )
        XCTAssertEqual(output.utf8.count, 131_072)
    }

    func testCommandRunnerProvidesUsefulMessageForSilentFailure() {
        XCTAssertThrowsError(try CommandRunner.run("/usr/bin/false")) { error in
            XCTAssertTrue(error.localizedDescription.contains("false"))
            XCTAssertTrue(error.localizedDescription.contains("状态"))
        }
    }

    func testParsesEnabledAndDisabledServices() {
        let input = """
        An asterisk (*) denotes that a network service is disabled.
        USB Ethernet
        Wi-Fi
        *Thunderbolt Bridge
        """
        let result = NetworkManager().parseServiceStates(input)

        XCTAssertEqual(result.map(\.0), ["USB Ethernet", "Wi-Fi", "Thunderbolt Bridge"])
        XCTAssertEqual(result.map(\.1), [true, true, false])
    }

    func testDisabledServiceKeepsItsOwnHardwareMapping() {
        let input = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (*) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """
        let result = NetworkManager().parseServiceMappings(input)

        XCTAssertEqual(result["Wi-Fi"]?.port, "Wi-Fi")
        XCTAssertEqual(result["Wi-Fi"]?.device, "en0")
        XCTAssertEqual(result["Thunderbolt Bridge"]?.port, "Thunderbolt Bridge")
        XCTAssertEqual(result["Thunderbolt Bridge"]?.device, "bridge0")
    }

    func testParsesNetworkServicePriorityOrder() {
        let input = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB Ethernet
        (Hardware Port: USB Ethernet, Device: en7)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (*) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """
        XCTAssertEqual(
            NetworkManager().parseServiceOrder(input),
            ["USB Ethernet", "Wi-Fi", "Thunderbolt Bridge"]
        )
    }

    func testParsesIndentedRouteValue() {
        let input = """
           route to: default
        destination: default
          interface: en9
        """
        XCTAssertEqual(NetworkManager().parseValue("interface", in: input), "en9")
    }

    func testParsesConfiguredDNSServers() {
        let manager = NetworkManager()
        XCTAssertEqual(manager.parseDNSServers("1.1.1.1\n8.8.8.8\n"), ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(manager.parseDNSServers("There aren't any DNS Servers set on Wi-Fi."), [])
    }

    func testParsesCurrentWiFiNetwork() {
        let manager = NetworkManager()
        XCTAssertEqual(manager.parseCurrentWiFiNetwork("Current Wi-Fi Network: Office LAN\n"), "Office LAN")
        XCTAssertNil(manager.parseCurrentWiFiNetwork("You are not associated with an AirPort network."))
    }

    func testParsesTrafficCountersFromLinkRowsOnly() {
        let input = """
        Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
        en9 1500 <Link#13> ac:f0:df:c9:9e:6e 918504 0 1034938152 720416 0 170542425 0
        en9 1500 192.168.88 192.168.88.100 918504 - 1034938152 720416 - 170542425 -
        en0 1500 <Link#4> aa:bb:cc:dd:ee:ff 100 0 2048 50 0 1024 0
        """
        let result = NetworkManager().parseTrafficCounters(input)
        XCTAssertEqual(result["en9"], InterfaceCounters(receivedBytes: 1_034_938_152, sentBytes: 170_542_425))
        XCTAssertEqual(result["en0"], InterfaceCounters(receivedBytes: 2_048, sentBytes: 1_024))
        XCTAssertEqual(result.count, 2)
    }

    func testParsesPingLatency() {
        let input = "64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.717 ms"
        XCTAssertEqual(NetworkManager().parsePingLatency(input), 0.717)
    }

    func testParsesUniqueSystemDNSServers() {
        let input = """
          nameserver[0] : fe80::1234%en9
          nameserver[1] : 192.168.88.1
          nameserver[0] : 192.168.88.1
        """
        XCTAssertEqual(NetworkManager().parseSystemDNSServers(input), ["fe80::1234%en9", "192.168.88.1"])
    }

    func testNormalizesAndDeduplicatesDNSInput() throws {
        let input = "1.1.1.1, 8.8.8.8\n2001:4860:4860::8888;1.1.1.1"
        XCTAssertEqual(
            try NetworkManager().normalizedDNSServers(input),
            ["1.1.1.1", "8.8.8.8", "2001:4860:4860::8888"]
        )
    }

    func testEmptyDNSInputMeansAutomatic() throws {
        XCTAssertEqual(try NetworkManager().normalizedDNSServers("  \n"), [])
    }

    func testRejectsInvalidDNSInput() {
        XCTAssertThrowsError(try NetworkManager().normalizedDNSServers("8.8.8.999"))
        XCTAssertThrowsError(try NetworkManager().normalizedDNSServers("dns.example.com"))
    }
}

final class TrafficSampleCalculatorTests: XCTestCase {
    func testOptimisticDisableClearsTransientConnectionState() {
        let ethernet = service(name: "USB LAN", device: "en7", primary: true, kind: .ethernet)

        let result = NetworkServiceTransition.settingEnabled(
            services: [ethernet],
            named: "USB LAN",
            enabled: false
        )

        XCTAssertFalse(result[0].enabled)
        XCTAssertFalse(result[0].connected)
        XCTAssertFalse(result[0].isPrimary)
        XCTAssertNil(result[0].ipAddress)
        XCTAssertNil(result[0].router)
    }

    func testOptimisticEnablePreservesKnownMetadataWithoutClaimingConnection() {
        let disabled = service(name: "Wi-Fi", device: "en0", enabled: false, connected: false, primary: false, kind: .wifi)

        let result = NetworkServiceTransition.settingEnabled(
            services: [disabled],
            named: "Wi-Fi",
            enabled: true
        )

        XCTAssertTrue(result[0].enabled)
        XCTAssertFalse(result[0].connected)
        XCTAssertFalse(result[0].isPrimary)
        XCTAssertEqual(result[0].device, "en0")
    }

    func testOptimisticSwitchUpdatesPrimaryServiceImmediately() {
        let ethernet = service(name: "USB LAN", device: "en7", primary: true, kind: .ethernet)
        let wifi = service(name: "Wi-Fi", device: "en0", primary: false, kind: .wifi)

        let result = NetworkServiceTransition.switching(
            services: [ethernet, wifi],
            target: "Wi-Fi",
            disabledServices: ["USB LAN"]
        )

        XCTAssertTrue(result[1].isPrimary)
        XCTAssertTrue(result[1].connected)
        XCTAssertTrue(result[1].enabled)
        XCTAssertEqual(result[1].wifiPowered, true)
        XCTAssertFalse(result[0].isPrimary)
        XCTAssertFalse(result[0].connected)
        XCTAssertFalse(result[0].enabled)
    }

    func testUsesDefaultRouteOnlyAndDoesNotDoubleCountVPN() {
        let previous = [
            "en0": InterfaceCounters(receivedBytes: 1_000, sentBytes: 2_000),
            "utun4": InterfaceCounters(receivedBytes: 5_000, sentBytes: 8_000)
        ]
        let current = [
            "en0": InterfaceCounters(receivedBytes: 1_600, sentBytes: 2_200),
            "utun4": InterfaceCounters(receivedBytes: 5_500, sentBytes: 8_150)
        ]
        let result = TrafficSampleCalculator.calculate(
            previous: previous,
            current: current,
            services: [
                service(name: "Wi-Fi", device: "en0", primary: true, kind: .wifi),
                service(name: "VPN", device: "utun4", primary: false, kind: .vpn)
            ]
        )

        XCTAssertEqual(result.receivedBytes, 600)
        XCTAssertEqual(result.sentBytes, 200)
        XCTAssertEqual(result.deltasByDevice["utun4"], InterfaceCounters(receivedBytes: 500, sentBytes: 150))
    }

    func testFallsBackToConnectedPhysicalService() {
        let result = TrafficSampleCalculator.calculate(
            previous: ["en7": .init(receivedBytes: 100, sentBytes: 200)],
            current: ["en7": .init(receivedBytes: 140, sentBytes: 230)],
            services: [service(name: "USB LAN", device: "en7", primary: false, kind: .ethernet)]
        )
        XCTAssertEqual(result.receivedBytes, 40)
        XCTAssertEqual(result.sentBytes, 30)
    }

    func testCounterResetDoesNotCreateAnArtificialSpike() {
        let result = TrafficSampleCalculator.calculate(
            previous: ["en0": .init(receivedBytes: 9_000, sentBytes: 8_000)],
            current: ["en0": .init(receivedBytes: 20, sentBytes: 30)],
            services: [service(name: "Wi-Fi", device: "en0", primary: true, kind: .wifi)]
        )
        XCTAssertEqual(result.receivedBytes, 0)
        XCTAssertEqual(result.sentBytes, 0)
    }

    private func service(
        name: String,
        device: String,
        enabled: Bool = true,
        connected: Bool = true,
        primary: Bool,
        kind: NetworkService.Kind
    ) -> NetworkService {
        NetworkService(
            name: name,
            orderIndex: 0,
            hardwarePort: nil,
            device: device,
            enabled: enabled,
            connected: connected,
            ipAddress: connected ? "192.0.2.2" : nil,
            subnetMask: nil,
            router: nil,
            dnsServers: [],
            macAddress: nil,
            ssid: nil,
            isPrimary: primary,
            kind: kind,
            wifiPowered: kind == .wifi ? true : nil
        )
    }
}
