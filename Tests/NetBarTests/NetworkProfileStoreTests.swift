import XCTest
@testable import NetBar

final class NetworkProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: NetworkProfileStore!
    private let suite = "local.codex.NetBar.tests.profiles"

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
}
