import Foundation

struct NetworkProfile: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var serviceStates: [String: Bool]
    var wifiPowerStates: [String: Bool]
}

final class NetworkProfileStore {
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
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func saveSnapshot(
        name: String,
        serviceStates: [String: Bool],
        wifiPowerStates: [String: Bool],
        now: Date = Date()
    ) -> NetworkProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = trimmedName.isEmpty ? "未命名方案" : trimmedName
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

    private func persist(_ items: [NetworkProfile]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}
