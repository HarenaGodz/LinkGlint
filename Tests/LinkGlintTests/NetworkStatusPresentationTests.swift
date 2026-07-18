import XCTest
@testable import LinkGlint

final class NetworkStatusPresentationTests: XCTestCase {
    func testMenuBarTrafficSupportsSingleAndTwoLineLayouts() {
        XCTAssertEqual(
            MenuBarTrafficPresentation.make(
                networkTitle: "无线·Office",
                downloadBytesPerSecond: 1_250_000,
                uploadBytesPerSecond: 42_000,
                showsNetworkTitle: true,
                showsSpeed: true,
                usesTwoLines: false,
                usesBits: false
            ),
            .init(text: "无线·Office  ↓1.2 MB/s ↑42 KB/s", usesTwoLines: false)
        )
        XCTAssertEqual(
            MenuBarTrafficPresentation.make(
                networkTitle: "无线·Office",
                downloadBytesPerSecond: 1_250_000,
                uploadBytesPerSecond: 42_000,
                showsNetworkTitle: true,
                showsSpeed: true,
                usesTwoLines: true,
                usesBits: true
            ),
            .init(text: "无线·Office\n↓10 Mbps  ↑336 Kbps", usesTwoLines: true)
        )
    }

    func testMenuBarTrafficCanShowOnlySpeedOrOnlyNetwork() {
        XCTAssertEqual(
            MenuBarTrafficPresentation.make(
                networkTitle: "有线·LAN",
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                showsNetworkTitle: false,
                showsSpeed: true,
                usesTwoLines: true,
                usesBits: false
            ),
            .init(text: "↓0 B/s\n↑0 B/s", usesTwoLines: true)
        )
        XCTAssertEqual(
            MenuBarTrafficPresentation.make(
                networkTitle: "有线·LAN",
                downloadBytesPerSecond: 10,
                uploadBytesPerSecond: 20,
                showsNetworkTitle: true,
                showsSpeed: false,
                usesTwoLines: true,
                usesBits: false
            ),
            .init(text: "有线·LAN", usesTwoLines: false)
        )
    }

    func testTwoLineTrafficSplitsIntoStableDownloadAndUploadColumns() {
        XCTAssertEqual(
            MenuBarTrafficColumns.parse(combinedLine: "↓27 KB/s  ↑13 KB/s"),
            .init(download: "↓27 KB/s", upload: "↑13 KB/s")
        )
        XCTAssertNil(MenuBarTrafficColumns.parse(combinedLine: "↓27 KB/s ↑13 KB/s"))
        XCTAssertEqual(
            MenuBarRateParts.parse("↓8.2 KB/s"),
            .init(direction: "↓", number: "8.2", unit: "KB/s")
        )
        XCTAssertEqual(
            MenuBarRateParts.parse("↑999 Mbps"),
            .init(direction: "↑", number: "999", unit: "Mbps")
        )
        XCTAssertNil(MenuBarRateParts.parse("27 KB/s"))

        let geometry = MenuBarTwoLineGeometry.make(
            topWidth: 72,
            bottomWidth: 104
        )
        XCTAssertEqual(geometry.textWidth, 104)
        XCTAssertEqual(geometry.centeredX(contentWidth: 72), 16)
        XCTAssertEqual(geometry.centeredX(contentWidth: 104), 0)
        XCTAssertEqual(geometry.centeredX(contentWidth: 120), 0)
    }

    func testTwoLineOuterWidthDoesNotDependOnLiveRateDigits() {
        let narrowRates = MenuBarTrafficColumns.parse(combinedLine: "↓0 B/s  ↑8 B/s")
        let wideRates = MenuBarTrafficColumns.parse(combinedLine: "↓999 MB/s  ↑888 MB/s")
        XCTAssertNotEqual(narrowRates, wideRates)

        let narrowGeometry = MenuBarTwoLineGeometry.make(
            topWidth: 70,
            bottomWidth: 104
        )
        let wideGeometry = MenuBarTwoLineGeometry.make(
            topWidth: 70,
            bottomWidth: 104
        )
        XCTAssertEqual(narrowGeometry, wideGeometry)
    }

    func testTrafficRateUsesStandardReadableUnits() {
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 0, usesBits: false), "0 B/s")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 999, usesBits: false), "999 B/s")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 1_250, usesBits: false), "1.2 KB/s")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 42_000, usesBits: false), "42 KB/s")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 1_250_000, usesBits: false), "1.2 MB/s")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: 1_250_000, usesBits: true), "10 Mbps")
        XCTAssertEqual(TrafficRateFormatter.string(bytesPerSecond: .infinity, usesBits: true), "0 bps")
    }

    func testMenuBarIconFitPreservesWideAndTallAspectRatios() {
        XCTAssertEqual(
            MenuBarIconLayout.fittedSize(
                source: CGSize(width: 20, height: 10),
                bounding: CGSize(width: 18, height: 16)
            ),
            CGSize(width: 18, height: 9)
        )
        XCTAssertEqual(
            MenuBarIconLayout.fittedSize(
                source: CGSize(width: 10, height: 20),
                bounding: CGSize(width: 18, height: 16)
            ),
            CGSize(width: 8, height: 16)
        )
    }

    func testOpenPanelFreezesTextButAcceptsLatestNetworkSymbol() {
        let old = MenuBarTrafficPresentation(text: "↓1.0 MB/s\n↑20 KB/s", usesTwoLines: true)
        let latest = MenuBarTrafficPresentation(text: "↓900 MB/s\n↑8.0 MB/s", usesTwoLines: true)

        XCTAssertEqual(
            MenuBarRenderPolicy.make(
                latestSymbolName: "wifi",
                latestPresentation: latest,
                renderedPresentation: old,
                panelIsOpen: true
            ),
            MenuBarRenderState(symbolName: "wifi", presentation: old)
        )
        XCTAssertEqual(
            MenuBarRenderPolicy.make(
                latestSymbolName: "wifi",
                latestPresentation: latest,
                renderedPresentation: old,
                panelIsOpen: false
            ),
            MenuBarRenderState(symbolName: "wifi", presentation: latest)
        )
    }

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
        XCTAssertEqual(value, .init(title: "无线·Office", symbolName: "wifi"))
    }

    func testPrimaryEthernetWinsOverAnotherConnectedService() {
        let value = NetworkStatusPresentation.make(
            services: [
                service(kind: .wifi, ssid: "Office", primary: false),
                service(kind: .ethernet, primary: true)
            ],
            hasLoaded: true
        )
        XCTAssertEqual(value, .init(title: "有线·测试服务", symbolName: "cable.connector"))
    }

    func testVPNAndOtherPresentationsIncludeServiceName() {
        XCTAssertEqual(
            NetworkStatusPresentation.make(services: [service(kind: .vpn, primary: true)], hasLoaded: true),
            .init(title: "VPN·测试服务", symbolName: "lock.shield")
        )
        XCTAssertEqual(
            NetworkStatusPresentation.make(services: [service(kind: .other, primary: true)], hasLoaded: true),
            .init(title: "其他·测试服务", symbolName: "network")
        )
    }

    func testLongNetworkNameIsKeptButCompact() {
        let value = NetworkStatusPresentation.make(
            services: [service(kind: .wifi, ssid: "Very Long Office Wireless Network", primary: true)],
            hasLoaded: true
        )
        XCTAssertEqual(value.title, "无线·Very Lon…")
        XCTAssertEqual(value.symbolName, "wifi")
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
