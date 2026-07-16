import Foundation

struct NetworkStatusPresentation: Equatable {
    let title: String
    let symbolName: String

    static func make(services: [NetworkService], hasLoaded: Bool) -> NetworkStatusPresentation {
        guard hasLoaded else { return .init(title: "检测中", symbolName: "network") }
        guard let active = services.first(where: { $0.isPrimary && $0.connected })
                ?? services.first(where: \.connected) else {
            return .init(title: "离线", symbolName: "network.slash")
        }
        switch active.kind {
        case .wifi:
            let title = active.ssid.flatMap { !$0.isEmpty && $0.count <= 14 ? "Wi‑Fi · \($0)" : nil }
                ?? "Wi‑Fi · 已连接"
            return .init(title: title, symbolName: "wifi")
        case .ethernet:
            return .init(title: "有线 · 已连接", symbolName: "cable.connector")
        case .vpn:
            return .init(title: "VPN · 已连接", symbolName: "lock.shield")
        case .other:
            return .init(title: "网络 · 已连接", symbolName: "network")
        }
    }
}
