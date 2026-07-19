import XCTest
@testable import LinkGlint

final class NetworkManagerTests: XCTestCase {
    func testWiFiSSIDCacheKeepsOnlyRecentValuesAfterReadFailure() {
        var cache = WiFiSSIDStabilityCache(fallbackLifetime: 30)
        XCTAssertEqual(
            cache.resolve(
                device: "en0",
                connectionIsEligible: true,
                outcome: .current("Office"),
                uptime: 100
            ),
            "Office"
        )
        XCTAssertEqual(
            cache.resolve(
                device: "en0",
                connectionIsEligible: true,
                outcome: .failed,
                uptime: 120
            ),
            "Office"
        )
        XCTAssertNil(
            cache.resolve(
                device: "en0",
                connectionIsEligible: true,
                outcome: .failed,
                uptime: 131
            )
        )
    }

    func testWiFiSSIDCacheClearsOnExplicitDisconnect() {
        var cache = WiFiSSIDStabilityCache()
        _ = cache.resolve(
            device: "en0",
            connectionIsEligible: true,
            outcome: .current("Office"),
            uptime: 100
        )
        XCTAssertNil(
            cache.resolve(
                device: "en0",
                connectionIsEligible: true,
                outcome: .current(nil),
                uptime: 101
            )
        )
        XCTAssertNil(
            cache.resolve(
                device: "en0",
                connectionIsEligible: true,
                outcome: .failed,
                uptime: 102
            )
        )
    }

    func testCoreWLANAccessWaitIsBoundedInsteadOfOverlappingOperations() {
        let gate = CoreWLANAccessGate()
        let firstOperationEntered = expectation(description: "first CoreWLAN operation entered")
        let firstOperationFinished = expectation(description: "first CoreWLAN operation finished")
        let releaseFirstOperation = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try gate.withAccess(waitTimeout: 1) {
                    firstOperationEntered.fulfill()
                    _ = releaseFirstOperation.wait(timeout: .now() + 2)
                }
            } catch {
                XCTFail("The first operation should acquire the gate: \(error)")
            }
            firstOperationFinished.fulfill()
        }

        wait(for: [firstOperationEntered], timeout: 1)
        XCTAssertThrowsError(try gate.withAccess(waitTimeout: 0.05) {}) { error in
            XCTAssertTrue(error.localizedDescription.contains("另一项扫描或连接"))
        }
        releaseFirstOperation.signal()
        wait(for: [firstOperationFinished], timeout: 1)
    }

    func testMissingUnpluggedInterfaceIsTreatedAsUnavailable() {
        let manager = NetworkManager()
        XCTAssertTrue(manager.interfaceIsUnavailable("ifconfig: interface en6 does not exist"))
        XCTAssertTrue(manager.interfaceIsUnavailable("ifconfig: no such interface en8"))
        XCTAssertFalse(manager.interfaceIsUnavailable("ifconfig timed out"))
    }

    func testExplicitInactiveInterfaceOverridesRunningFlags() {
        let output = """
        bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            ether aa:bb:cc:dd:ee:ff
            status: inactive
        """
        let details = NetworkManager().parseInterfaceDetails(output)
        XCTAssertFalse(details.active)
        XCTAssertEqual(details.macAddress, "aa:bb:cc:dd:ee:ff")
    }

    func testInterfaceWithoutStatusUsesRunningFlags() {
        let output = "utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380"
        XCTAssertTrue(NetworkManager().parseInterfaceDetails(output).active)
    }

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

    func testCommandRunnerTimesOutHungCommand() {
        let startedAt = Date()
        XCTAssertThrowsError(try CommandRunner.run("/bin/sleep", ["5"], timeout: 0.1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
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
        XCTAssertEqual(
            manager.parseDNSServers("(Wi-Fi is currently disabled)\n2001:4860:4860::8888\n"),
            ["2001:4860:4860::8888"]
        )
    }

    func testParsesCurrentWiFiNetwork() {
        let manager = NetworkManager()
        XCTAssertEqual(manager.parseCurrentWiFiNetwork("Current Wi-Fi Network: Office LAN\n"), "Office LAN")
        XCTAssertEqual(manager.parseCurrentWiFiNetwork("Current Wi-Fi Network:  Office \n"), " Office ")
        XCTAssertNil(manager.parseCurrentWiFiNetwork("You are not associated with an AirPort network."))
        XCTAssertEqual(
            manager.parseCurrentWiFiNetworkOutcome("You are not associated with an AirPort network."),
            .current(nil)
        )
        XCTAssertEqual(manager.parseCurrentWiFiNetworkOutcome(""), .failed)
        XCTAssertEqual(manager.parseCurrentWiFiNetworkOutcome("unexpected output"), .failed)
    }

    func testUsesValidMacOSPingArgumentsForIPv4AndIPv6() {
        let manager = NetworkManager()
        let ipv4 = manager.diagnosticPingInvocation(gateway: "192.168.1.1")
        XCTAssertEqual(ipv4.executable, "/sbin/ping")
        XCTAssertEqual(ipv4.arguments, ["-c", "1", "-W", "1000", "192.168.1.1"])

        let ipv6 = manager.diagnosticPingInvocation(gateway: "2001:db8::1")
        XCTAssertEqual(ipv6.executable, "/sbin/ping6")
        XCTAssertEqual(ipv6.arguments, ["-c", "1", "2001:db8::1"])
    }

    func testWiFiCatalogDeduplicatesBySSIDAndKeepsStrongestSignal() {
        let networks = [
            WiFiNetwork(ssid: "Office", rssiValue: -72, isSecure: true),
            WiFiNetwork(ssid: "Guest", rssiValue: -55, isSecure: false),
            WiFiNetwork(ssid: "Office", rssiValue: -48, isSecure: true),
            WiFiNetwork(ssid: "   ", rssiValue: -30, isSecure: false)
        ]

        let result = WiFiNetworkCatalog.normalized(networks, currentSSID: nil)

        XCTAssertEqual(result.map(\.ssid), ["Office", "Guest"])
        XCTAssertEqual(result.first?.rssiValue, -48)
    }

    func testWiFiCatalogPinsCurrentNetworkBeforeStrongerNetworks() {
        let networks = [
            WiFiNetwork(ssid: "Current", rssiValue: -78, isSecure: true),
            WiFiNetwork(ssid: "Nearby", rssiValue: -42, isSecure: true)
        ]

        let result = WiFiNetworkCatalog.normalized(networks, currentSSID: "Current")

        XCTAssertEqual(result.map(\.ssid), ["Current", "Nearby"])
    }

    func testWiFiCatalogPreservesLegalSSIDWhitespace() {
        let result = WiFiNetworkCatalog.normalized(
            [WiFiNetwork(ssid: " Office ", rssiValue: -50, isSecure: true)],
            currentSSID: " Office "
        )
        XCTAssertEqual(result.first?.ssid, " Office ")
    }

    func testWiFiSignalDescriptionsUseReadableBands() {
        XCTAssertEqual(WiFiNetwork(ssid: "A", rssiValue: -45, isSecure: true).signalDescription, "信号极佳")
        XCTAssertEqual(WiFiNetwork(ssid: "B", rssiValue: -58, isSecure: true).signalDescription, "信号良好")
        XCTAssertEqual(WiFiNetwork(ssid: "C", rssiValue: -67, isSecure: true).signalDescription, "信号一般")
        XCTAssertEqual(WiFiNetwork(ssid: "D", rssiValue: -82, isSecure: true).signalDescription, "信号较弱")
    }

    func testClassifiesMobileBroadbandAdaptersAsCellular() {
        let manager = NetworkManager()
        XCTAssertEqual(
            manager.classify(name: "Flymodem", hardwarePort: "Mobile Composite Device Bus"),
            .cellular
        )
        XCTAssertEqual(
            manager.classify(name: "USB Modem", hardwarePort: "WWAN Adapter"),
            .cellular
        )
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

    func testReadsNative64BitTrafficCounters() throws {
        let counters = try NetworkManager().fetchTrafficCounters()
        XCTAssertNotNil(counters["lo0"])
    }

    func testParsesPingLatency() {
        let input = "64 bytes from 192.168.1.1: icmp_seq=0 ttl=64 time=0.717 ms"
        XCTAssertEqual(NetworkManager().parsePingLatency(input), 0.717)
    }

    func testDNSLookupAcceptsIPv4AndIPv6Results() {
        let manager = NetworkManager()
        XCTAssertTrue(manager.dnsLookupDidResolve("name: example.test\nip_address: 192.0.2.1"))
        XCTAssertTrue(manager.dnsLookupDidResolve("name: example.test\nipv6_address: 2001:db8::1"))
        XCTAssertFalse(manager.dnsLookupDidResolve("name: example.test"))
    }

    func testParsesUniqueSystemDNSServers() {
        let input = """
          nameserver[0] : fe80::1234%en9
          nameserver[1] : 192.168.88.1
          nameserver[0] : 192.168.88.1
        """
        XCTAssertEqual(NetworkManager().parseSystemDNSServers(input), ["fe80::1234%en9", "192.168.88.1"])
    }

    func testParsesConnectedVPNServiceNames() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      1234 PPP --> L2TP       \"Work VPN\" [VPN:L2TP]
        * (Disconnected)   5678 IPSec              \"Backup VPN\" [VPN:IPSec]
        """
        XCTAssertEqual(NetworkManager().parseConnectedVPNServiceNames(output), ["Work VPN"])
    }

    func testParsesVPNInterfaceAndMatchesPrimaryAmongMultipleConnections() {
        let manager = NetworkManager()
        let output = """
        Connected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            InterfaceName : utun7
          }
        }
        """

        XCTAssertEqual(manager.parseVPNInterfaceName(output), "utun7")
        XCTAssertEqual(
            manager.primaryVPNServiceName(
                connectedNames: ["Work", "Backup"],
                interfacesByName: ["Work": "utun6", "Backup": "utun7"],
                defaultInterface: "utun7"
            ),
            "Backup"
        )
    }

    func testPrimaryVPNFallbackIsOnlyUsedWhenUnambiguous() {
        let manager = NetworkManager()
        XCTAssertEqual(
            manager.primaryVPNServiceName(
                connectedNames: ["Only VPN"],
                interfacesByName: [:],
                defaultInterface: "utun2"
            ),
            "Only VPN"
        )
        XCTAssertNil(
            manager.primaryVPNServiceName(
                connectedNames: ["Work", "Backup"],
                interfacesByName: [:],
                defaultInterface: "utun2"
            )
        )
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

    func testOptimisticSwitchEnablesTargetWithoutDisablingFallback() {
        let ethernet = service(name: "USB LAN", device: "en7", primary: true, kind: .ethernet)
        let wifi = service(
            name: "Wi-Fi",
            device: "en0",
            enabled: false,
            connected: false,
            primary: false,
            kind: .wifi
        )

        let result = NetworkServiceTransition.switching(
            services: [ethernet, wifi],
            target: "Wi-Fi"
        )

        XCTAssertFalse(result[1].isPrimary)
        XCTAssertFalse(result[1].connected)
        XCTAssertTrue(result[1].enabled)
        XCTAssertEqual(result[1].wifiPowered, true)
        XCTAssertTrue(result[0].isPrimary)
        XCTAssertTrue(result[0].connected)
        XCTAssertTrue(result[0].enabled)
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

    func testUsesPrimaryVPNTunnelCountersWhenInterfaceCanBeResolved() {
        let result = TrafficSampleCalculator.calculate(
            previous: [
                "en0": .init(receivedBytes: 1_000, sentBytes: 2_000),
                "utun4": .init(receivedBytes: 5_000, sentBytes: 8_000)
            ],
            current: [
                "en0": .init(receivedBytes: 1_600, sentBytes: 2_200),
                "utun4": .init(receivedBytes: 5_500, sentBytes: 8_150)
            ],
            services: [
                service(name: "VPN", device: "utun4", primary: true, kind: .vpn),
                service(name: "Wi-Fi", device: "en0", primary: false, kind: .wifi)
            ]
        )

        XCTAssertEqual(result.receivedBytes, 500)
        XCTAssertEqual(result.sentBytes, 150)
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
