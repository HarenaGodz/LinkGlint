import XCTest
@testable import NetBar

final class NetworkManagerTests: XCTestCase {
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
