import Foundation

struct NetworkProfile: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var serviceStates: [String: Bool]
    var wifiPowerStates: [String: Bool]
}

struct NetworkProfileApplicationPlan: Equatable {
    let title: String
    let serviceStates: [String: Bool]
    let wifiPowerStates: [String: Bool]
    let skippedUnavailableItems: Int
}

enum NetworkProfileApplicationPlanner {
    static func leavesPhysicalTransportEnabled(
        _ plan: NetworkProfileApplicationPlan,
        services: [NetworkService]
    ) -> Bool {
        services.filter(\.isPhysicalTransport).contains { service in
            guard plan.serviceStates[service.name] ?? service.enabled else { return false }
            guard service.kind == .wifi, let device = service.device else { return true }
            // An enabled Wi-Fi service cannot carry traffic while its radio is
            // explicitly powered off by the same profile.
            return plan.wifiPowerStates[device] ?? service.wifiPowered ?? true
        }
    }

    static func readinessServiceNames(
        _ plan: NetworkProfileApplicationPlan,
        services: [NetworkService]
    ) -> [String] {
        services.filter { service in
            guard service.isPhysicalTransport, plan.serviceStates[service.name] == true else {
                return false
            }
            if service.kind == .wifi, let device = service.device,
               plan.wifiPowerStates[device] == false {
                return false
            }
            return true
        }.map(\.name)
    }

    static func builtIn(token: String, services: [NetworkService]) -> NetworkProfileApplicationPlan? {
        let physical = services.filter(\.isPhysicalTransport)
        guard !physical.isEmpty else { return nil }

        let title: String
        let targetKind: NetworkService.Kind?
        switch token {
        case "__all__":
            title = "全部物理网络启用"
            targetKind = nil
        case "__wifi__":
            title = "仅 Wi-Fi"
            targetKind = .wifi
        case "__ethernet__":
            title = "仅有线网络"
            targetKind = .ethernet
        default:
            return nil
        }
        if let targetKind, !physical.contains(where: { $0.kind == targetKind }) {
            return nil
        }

        let serviceStates = Dictionary(
            physical.map { service in (service.name, targetKind.map { service.kind == $0 } ?? true) },
            uniquingKeysWith: { _, latest in latest }
        )
        let wifiPowerStates = Dictionary(
            physical.compactMap { service -> (String, Bool)? in
                guard service.kind == .wifi, let device = service.device else { return nil }
                return (device, targetKind != .ethernet)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        return NetworkProfileApplicationPlan(
            title: title,
            serviceStates: serviceStates,
            wifiPowerStates: wifiPowerStates,
            skippedUnavailableItems: 0
        )
    }

    static func custom(_ profile: NetworkProfile, services: [NetworkService]) -> NetworkProfileApplicationPlan? {
        let availableServiceNames = Set(services.map(\.name))
        let availableWiFiDevices = Set(services.compactMap { service in
            service.kind == .wifi ? service.device : nil
        })
        // Silently dropping a missing item that the profile expects to enable
        // can leave only its "turn other adapters off" half, disconnecting the
        // Mac. Require every enabling target to be present; unavailable items
        // that were only meant to be disabled are safe to ignore.
        let hasMissingRequiredService = profile.serviceStates.contains {
            $0.value && !availableServiceNames.contains($0.key)
        }
        let hasMissingRequiredWiFi = profile.wifiPowerStates.contains {
            $0.value && !availableWiFiDevices.contains($0.key)
        }
        guard !hasMissingRequiredService, !hasMissingRequiredWiFi else { return nil }
        let serviceStates = profile.serviceStates.filter { availableServiceNames.contains($0.key) }
        let wifiPowerStates = profile.wifiPowerStates.filter { availableWiFiDevices.contains($0.key) }
        guard !serviceStates.isEmpty || !wifiPowerStates.isEmpty else { return nil }

        return NetworkProfileApplicationPlan(
            title: profile.name,
            serviceStates: serviceStates,
            wifiPowerStates: wifiPowerStates,
            skippedUnavailableItems: profile.serviceStates.count - serviceStates.count
                + profile.wifiPowerStates.count - wifiPowerStates.count
        )
    }
}

final class NetworkProfileStore {
    static let maximumProfileNameLength = 32

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "networkProfiles.v1") {
        self.defaults = defaults
        self.key = key
    }

    var profiles: [NetworkProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NetworkProfile].self, from: data) else {
            return []
        }
        return decoded.map { profile in
            var profile = profile
            profile.name = Self.normalizedProfileName(profile.name)
            return profile
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func saveSnapshot(
        name: String,
        serviceStates: [String: Bool],
        wifiPowerStates: [String: Bool],
        now: Date = Date()
    ) -> NetworkProfile {
        let cleanName = Self.normalizedProfileName(name)
        var items = profiles
        if let index = items.firstIndex(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }) {
            items[index].name = cleanName
            items[index].serviceStates = serviceStates
            items[index].wifiPowerStates = wifiPowerStates
            persist(items)
            return items[index]
        }

        let profile = NetworkProfile(
            id: UUID(),
            name: cleanName,
            createdAt: now,
            serviceStates: serviceStates,
            wifiPowerStates: wifiPowerStates
        )
        items.append(profile)
        persist(items)
        return profile
    }

    func delete(id: UUID) {
        persist(profiles.filter { $0.id != id })
    }

    func profile(id: UUID) -> NetworkProfile? {
        profiles.first { $0.id == id }
    }

    func renameService(from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        var items = profiles
        var changed = false
        for index in items.indices {
            guard let state = items[index].serviceStates.removeValue(forKey: oldName) else { continue }
            // Preserve an existing destination entry if a previous system rename
            // already produced it, otherwise migrate the saved state.
            if items[index].serviceStates[newName] == nil {
                items[index].serviceStates[newName] = state
            }
            changed = true
        }
        if changed { persist(items) }
    }

    private func persist(_ items: [NetworkProfile]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    private static func normalizedProfileName(_ name: String) -> String {
        let singleLineName = name.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmedName = singleLineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmedName.isEmpty ? "未命名方案" : trimmedName
        return String(fallback.prefix(maximumProfileNameLength))
    }
}
