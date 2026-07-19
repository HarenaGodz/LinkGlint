import XCTest
@testable import LinkGlint

final class NetworkProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: NetworkProfileStore!
    private let suite = "local.codex.LinkGlint.tests.profiles"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = NetworkProfileStore(defaults: defaults, key: "profiles")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testSavesAndLoadsSnapshot() {
        let date = Date(timeIntervalSince1970: 1234)
        let saved = store.saveSnapshot(
            name: "办公室",
            serviceStates: ["Wi-Fi": false, "USB LAN": true],
            wifiPowerStates: ["en0": false],
            now: date
        )

        XCTAssertEqual(store.profiles, [saved])
        XCTAssertEqual(store.profiles.first?.serviceStates["USB LAN"], true)
        XCTAssertEqual(store.profiles.first?.wifiPowerStates["en0"], false)
    }

    func testSameNameUpdatesExistingSnapshot() {
        let first = store.saveSnapshot(name: "Home", serviceStates: ["Wi-Fi": true], wifiPowerStates: [:])
        let updated = store.saveSnapshot(name: "home", serviceStates: ["Wi-Fi": false], wifiPowerStates: [:])

        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.serviceStates["Wi-Fi"], false)
    }

    func testDeletesSnapshot() {
        let profile = store.saveSnapshot(name: "临时", serviceStates: [:], wifiPowerStates: [:])
        store.delete(id: profile.id)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testBlankNameUsesFallback() {
        let profile = store.saveSnapshot(name: "   ", serviceStates: [:], wifiPowerStates: [:])
        XCTAssertEqual(profile.name, "未命名方案")
    }

    func testProfileNameIsNormalizedToOneReadableLine() {
        let profile = store.saveSnapshot(
            name: "  办公室\n\t有线  ",
            serviceStates: [:],
            wifiPowerStates: [:]
        )
        XCTAssertEqual(profile.name, "办公室 有线")
    }

    func testLongProfileNameIsBoundedForMenusAndOperationFeedback() {
        let profile = store.saveSnapshot(
            name: String(repeating: "长", count: 80),
            serviceStates: [:],
            wifiPowerStates: [:]
        )
        XCTAssertEqual(profile.name.count, NetworkProfileStore.maximumProfileNameLength)
        XCTAssertEqual(store.profiles.first?.name.count, NetworkProfileStore.maximumProfileNameLength)
    }

    func testRenamingServiceMigratesSavedProfiles() {
        store.saveSnapshot(
            name: "Dock",
            serviceStates: ["Old LAN": true, "Wi-Fi": false],
            wifiPowerStates: [:]
        )

        store.renameService(from: "Old LAN", to: "Studio LAN")

        XCTAssertNil(store.profiles.first?.serviceStates["Old LAN"])
        XCTAssertEqual(store.profiles.first?.serviceStates["Studio LAN"], true)
        XCTAssertEqual(store.profiles.first?.serviceStates["Wi-Fi"], false)
    }

    func testBuiltInProfileRequiresItsTargetAdapter() {
        let ethernet = service(name: "LAN", device: "en7", kind: .ethernet)

        XCTAssertNil(NetworkProfileApplicationPlanner.builtIn(token: "__wifi__", services: [ethernet]))
        let plan = NetworkProfileApplicationPlanner.builtIn(token: "__ethernet__", services: [ethernet])
        XCTAssertEqual(plan?.serviceStates, ["LAN": true])
    }

    func testCustomProfileDoesNotApplyOnlyDestructiveHalfWhenRequiredAdapterIsMissing() {
        let profile = NetworkProfile(
            id: UUID(),
            name: "Wi-Fi only",
            createdAt: Date(),
            serviceStates: ["Wi-Fi": true, "LAN": false],
            wifiPowerStates: ["en0": true]
        )

        XCTAssertNil(
            NetworkProfileApplicationPlanner.custom(
                profile,
                services: [service(name: "LAN", device: "en7", kind: .ethernet)]
            )
        )
    }

    func testCustomProfileSafelySkipsUnavailableDisabledAdapter() {
        let profile = NetworkProfile(
            id: UUID(),
            name: "Current devices",
            createdAt: Date(),
            serviceStates: ["Wi-Fi": true, "Old LAN": false],
            wifiPowerStates: ["en0": true]
        )
        let plan = NetworkProfileApplicationPlanner.custom(
            profile,
            services: [service(name: "Wi-Fi", device: "en0", kind: .wifi)]
        )

        XCTAssertEqual(plan?.serviceStates, ["Wi-Fi": true])
        XCTAssertEqual(plan?.wifiPowerStates, ["en0": true])
        XCTAssertEqual(plan?.skippedUnavailableItems, 1)
    }

    func testPoweredOffWiFiDoesNotCountAsRemainingPhysicalConnection() {
        let plan = NetworkProfileApplicationPlan(
            title: "Radios off",
            serviceStates: ["Wi-Fi": true, "LAN": false],
            wifiPowerStates: ["en0": false],
            skippedUnavailableItems: 0
        )
        let services = [
            service(name: "Wi-Fi", device: "en0", kind: .wifi),
            service(name: "LAN", device: "en7", kind: .ethernet)
        ]

        XCTAssertFalse(
            NetworkProfileApplicationPlanner.leavesPhysicalTransportEnabled(plan, services: services)
        )
        XCTAssertEqual(
            NetworkProfileApplicationPlanner.readinessServiceNames(plan, services: services),
            []
        )
    }

    func testReadinessTargetsExcludeWiFiWhoseRadioWillBePoweredOff() {
        let plan = NetworkProfileApplicationPlan(
            title: "Ethernet preferred",
            serviceStates: ["Wi-Fi": true, "LAN": true],
            wifiPowerStates: ["en0": false],
            skippedUnavailableItems: 0
        )
        let services = [
            service(name: "Wi-Fi", device: "en0", kind: .wifi),
            service(name: "LAN", device: "en7", kind: .ethernet)
        ]

        XCTAssertEqual(
            NetworkProfileApplicationPlanner.readinessServiceNames(plan, services: services),
            ["LAN"]
        )
    }

    private func service(name: String, device: String, kind: NetworkService.Kind) -> NetworkService {
        NetworkService(
            name: name,
            orderIndex: 0,
            hardwarePort: nil,
            device: device,
            enabled: true,
            connected: false,
            ipAddress: nil,
            subnetMask: nil,
            router: nil,
            dnsServers: [],
            macAddress: nil,
            ssid: nil,
            isPrimary: false,
            kind: kind,
            wifiPowered: kind == .wifi ? true : nil
        )
    }
}
