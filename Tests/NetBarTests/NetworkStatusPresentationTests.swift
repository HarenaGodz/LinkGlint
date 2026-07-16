import XCTest
@testable import NetBar

final class NetworkStatusPresentationTests: XCTestCase {
    func testLoadingAndOfflinePresentations() {
        XCTAssertEqual(
            NetworkStatusPresentation.make(services: [], hasLoaded: false),
            .init(title: "检测中", symbolName: "network")
        )
        XCTAssertEqual(
            NetworkStatusPresentation.make(services: [], hasLoaded: true),
            .init(title: "离线", symbolName: "network.slash")
        )
    }

    func testWiFiPresentationIncludesShortSSID() {
        let value = NetworkStatusPresentation.make(
            services: [service(kind: .wifi, ssid: "Office", primary: true)],
            hasLoaded: true
        )
        XCTAssertEqual(value, .init(title: "Wi‑Fi · Office", symbolName: "wifi"))
    }

    func testPrimaryEthernetWinsOverAnotherConnectedService() {
        let value = NetworkStatusPresentation.make(
            services: [
                service(kind: .wifi, ssid: "Office", primary: false),
                service(kind: .ethernet, primary: true)
            ],
            hasLoaded: true
        )
        XCTAssertEqual(value, .init(title: "有线 · 已连接", symbolName: "cable.connector"))
    }

    private func service(
        kind: NetworkService.Kind,
        ssid: String? = nil,
        primary: Bool
    ) -> NetworkService {
        NetworkService(
            name: "测试服务",
            orderIndex: 0,
            hardwarePort: nil,
            device: "en0",
            enabled: true,
            connected: true,
            ipAddress: "192.0.2.2",
            subnetMask: nil,
            router: nil,
            dnsServers: [],
            macAddress: nil,
            ssid: ssid,
            isPrimary: primary,
            kind: kind,
            wifiPowered: kind == .wifi ? true : nil
        )
    }
}
