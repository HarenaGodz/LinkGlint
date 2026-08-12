import Foundation

enum NetworkDisplayText {
    static func singleLine(_ value: String, fallback: String = "未命名") -> String {
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let sanitized = value.unicodeScalars.map {
            forbidden.contains($0) ? "�" : String($0)
        }.joined()
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback : sanitized
    }

    static func compact(_ value: String, maximumCharacters: Int = 9) -> String {
        let singleLineValue = singleLine(value)
        let limit = max(maximumCharacters, 1)
        guard singleLineValue.count > limit else { return singleLineValue }
        let prefixLength = max(limit - 1, 0)
        return String(singleLineValue.prefix(prefixLength))
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}

enum NetworkServiceSummaryText {
    static func panel(services: [NetworkService]) -> String {
        let connectedCount = services.filter(\.connected).count
        let enabledCount = services.filter(\.enabled).count
        let activeName = services.first(where: { $0.isPrimary && $0.connected })?.name
            ?? services.first(where: \.connected)?.name
        var parts = ["\(connectedCount) 个已连接", "\(enabledCount) 个已启用"]
        if let activeName {
            parts.insert(NetworkDisplayText.singleLine(activeName), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    static func mainWindow(services: [NetworkService]) -> String {
        let connectedCount = services.filter(\.connected).count
        let enabledCount = services.filter(\.enabled).count
        return "\(services.count) 个服务 · \(connectedCount) 个已连接 · \(enabledCount) 个已启用"
    }
}

struct NetworkDiagnosticPresentation: Equatable {
    let title: String
    let detail: String
    let isHealthy: Bool?

    static func make(_ diagnostic: NetworkDiagnostic?) -> NetworkDiagnosticPresentation {
        guard let diagnostic else {
            return .init(
                title: "网络检测",
                detail: "检查默认路由、网关延迟与 DNS",
                isHealthy: nil
            )
        }
        var details = [diagnostic.summary]
        if let latency = diagnostic.gatewayLatencyMilliseconds {
            details.append(String(format: "网关 %.1f ms", latency))
        }
        details.append(diagnostic.dnsLookupSucceeded ? "DNS 正常" : "DNS 异常")
        return .init(
            title: diagnostic.isUsable ? "网络良好" : "需要检查",
            detail: details.joined(separator: " · "),
            isHealthy: diagnostic.isUsable
        )
    }
}

enum TrafficHistoryWindowFormatter {
    static func string(samples: [TrafficRateSample]) -> String {
        guard samples.count > 1, let first = samples.first, let last = samples.last else {
            return samples.isEmpty ? "等待样本" : "1 个样本"
        }
        let seconds = max(last.date.timeIntervalSince(first.date), 0)
        if seconds < 60 {
            return "近 \(max(Int(seconds.rounded()), 1)) 秒"
        }
        let minutes = seconds / 60
        if minutes < 10 {
            return String(format: "近 %.1f 分钟", minutes)
        }
        return "近 \(Int(minutes.rounded())) 分钟"
    }
}

enum StatusPanelClick: Equatable {
    case left
    case right
}

enum StatusPanelClickAction: Equatable {
    case openPanel
    case closePanel
    case showContextMenu
}

struct StatusPanelInteraction {
    static func action(for click: StatusPanelClick, panelIsOpen: Bool) -> StatusPanelClickAction {
        switch click {
        case .right:
            return .showContextMenu
        case .left:
            return panelIsOpen ? .closePanel : .openPanel
        }
    }
}

enum StatusPanelDismissalPolicy {
    static func dismissesForExternalInteraction(isPinned: Bool) -> Bool {
        !isPinned
    }
}

/// Collapses bursts of refresh requests into at most one follow-up operation.
/// A user-initiated request upgrades an already queued background refresh so
/// that errors are still surfaced when the follow-up runs.
struct RefreshRequestCoalescer {
    private(set) var isRunning = false
    private var pendingShowsErrors: Bool?

    mutating func request(showingErrors: Bool) -> Bool {
        guard isRunning else {
            isRunning = true
            return true
        }
        pendingShowsErrors = (pendingShowsErrors ?? false) || showingErrors
        return false
    }

    /// Finishes the active operation and returns the coalesced follow-up, if
    /// any. The caller submits that value through the normal guarded entry
    /// point, so a newly started network mutation can defer it safely.
    mutating func finish() -> Bool? {
        let pending = pendingShowsErrors
        self.pendingShowsErrors = nil
        isRunning = false
        return pending
    }
}

enum MenuBarTrafficIndicatorStyle: String, CaseIterable, Equatable {
    case coloredDots
    case coloredTriangles
    case arrows

    var title: String {
        switch self {
        case .coloredDots: return "蓝橙圆点（推荐）"
        case .coloredTriangles: return "彩色方向三角"
        case .arrows: return "经典上下箭头"
        }
    }

    var usesColor: Bool { self != .arrows }
}

struct NetworkStatusPresentation: Equatable {
    let title: String
    let symbolName: String
    let vpnConnected: Bool

    init(title: String, symbolName: String, vpnConnected: Bool = false) {
        self.title = title
        self.symbolName = symbolName
        self.vpnConnected = vpnConnected
    }

    static func make(
        services: [NetworkService],
        hasLoaded: Bool,
        activeVPNInterfaceNames: Set<String> = []
    ) -> NetworkStatusPresentation {
        guard hasLoaded else { return .init(title: "检测中", symbolName: "network") }
        guard let active = services.first(where: { $0.isPrimary && $0.connected })
                ?? services.first(where: \.connected) else {
            return .init(title: "离线", symbolName: "network.slash")
        }
        let base: NetworkStatusPresentation
        switch active.kind {
        case .wifi:
            base = .init(title: "无线·\(NetworkDisplayText.compact(active.ssid ?? active.name))", symbolName: "wifi")
        case .ethernet:
            base = .init(title: "有线·\(NetworkDisplayText.compact(active.name))", symbolName: "cable.connector")
        case .cellular:
            base = .init(title: "移动·\(NetworkDisplayText.compact(active.name))", symbolName: "antenna.radiowaves.left.and.right")
        case .vpn:
            let physicalSymbol = services.first(where: {
                $0.connected && $0.isPhysicalTransport
            }).map { transport -> String in
                switch transport.kind {
                case .wifi: return "wifi"
                case .ethernet: return "cable.connector"
                case .cellular: return "antenna.radiowaves.left.and.right"
                default: return "network"
                }
            } ?? "network"
            base = .init(
                title: "VPN·\(NetworkDisplayText.compact(active.name))·已开启",
                symbolName: physicalSymbol,
                vpnConnected: true
            )
        case .other:
            base = .init(title: "其他·\(NetworkDisplayText.compact(active.name))", symbolName: "network")
        }
        guard active.kind != .vpn else {
            return base
        }
        let vpnConnected = services.contains(where: { $0.connected && $0.kind == .vpn })
            || !activeVPNInterfaceNames.isEmpty
        guard vpnConnected else { return base }
        // A split-tunnel or secondary VPN can be connected without becoming
        // the default route. Keep the physical network name, but make the VPN
        // state visible in the menu bar while preserving the physical network
        // symbol. The renderer adds a small lock badge beside that symbol.
        return .init(
            title: "\(base.title) · VPN·已开启",
            symbolName: base.symbolName,
            vpnConnected: true
        )
    }
}

struct MenuBarTrafficPresentation: Equatable {
    let text: String
    let usesTwoLines: Bool

    static func make(
        networkTitle: String,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        showsNetworkTitle: Bool,
        showsSpeed: Bool,
        usesTwoLines: Bool,
        usesBits: Bool
    ) -> MenuBarTrafficPresentation {
        let down = "↓\(TrafficRateFormatter.string(bytesPerSecond: downloadBytesPerSecond, usesBits: usesBits))"
        let up = "↑\(TrafficRateFormatter.string(bytesPerSecond: uploadBytesPerSecond, usesBits: usesBits))"
        guard showsSpeed else {
            return .init(text: showsNetworkTitle ? networkTitle : "", usesTwoLines: false)
        }
        if usesTwoLines {
            let first = showsNetworkTitle ? networkTitle : down
            let second = showsNetworkTitle ? "\(down)  \(up)" : up
            return .init(text: "\(first)\n\(second)", usesTwoLines: true)
        }
        let text = showsNetworkTitle ? "\(networkTitle)  \(down) \(up)" : "\(down) \(up)"
        return .init(text: text, usesTwoLines: false)
    }

}

struct MenuBarTrafficColumns: Equatable {
    let download: String
    let upload: String

    static func parse(combinedLine: String) -> MenuBarTrafficColumns? {
        let parts = combinedLine.components(separatedBy: "  ")
        guard parts.count == 2,
              parts[0].hasPrefix("↓"),
              parts[1].hasPrefix("↑") else { return nil }
        return MenuBarTrafficColumns(download: parts[0], upload: parts[1])
    }
}

struct MenuBarRateParts: Equatable {
    let direction: String
    let number: String
    let unit: String

    static func parse(_ value: String) -> MenuBarRateParts? {
        guard let direction = value.first, direction == "↓" || direction == "↑" else { return nil }
        let body = value.dropFirst()
        guard let separator = body.firstIndex(of: " ") else { return nil }
        let number = String(body[..<separator])
        let unit = String(body[body.index(after: separator)...])
        guard !number.isEmpty, !unit.isEmpty else { return nil }
        return MenuBarRateParts(direction: String(direction), number: number, unit: unit)
    }
}

struct MenuBarTwoLineGeometry: Equatable {
    let textWidth: CGFloat

    static func make(
        topWidth: CGFloat,
        bottomWidth: CGFloat
    ) -> MenuBarTwoLineGeometry {
        MenuBarTwoLineGeometry(textWidth: max(topWidth, bottomWidth))
    }

    func centeredX(contentWidth: CGFloat) -> CGFloat {
        max((textWidth - contentWidth) / 2, 0)
    }
}

struct MenuBarRatePairGeometry: Equatable {
    let markerWidth: CGFloat
    let valueWidth: CGFloat
    let markerValueGap: CGFloat
    let groupGap: CGFloat

    var valueX: CGFloat { markerWidth + markerValueGap }
    var groupWidth: CGFloat { valueX + valueWidth }
    var uploadX: CGFloat { groupWidth + groupGap }
    var totalWidth: CGFloat { uploadX + groupWidth }
}

struct MenuBarRenderState: Equatable {
    let symbolName: String
    let presentation: MenuBarTrafficPresentation
}

enum MenuBarRenderPolicy {
    static func make(
        latestSymbolName: String,
        latestPresentation: MenuBarTrafficPresentation,
        renderedPresentation: MenuBarTrafficPresentation?,
        panelIsOpen: Bool
    ) -> MenuBarRenderState {
        MenuBarRenderState(
            symbolName: latestSymbolName,
            presentation: panelIsOpen
                ? (renderedPresentation ?? latestPresentation)
                : latestPresentation
        )
    }
}

enum MenuBarSingleLineLayout {
    private static let rateExpression = try? NSRegularExpression(
        pattern: #"([↓↑])([0-9]+(?:\.[0-9]+)?\s+(?:[KMGT]?B/s|[KMGT]?bps))"#
    )

    static func stabilizedText(_ text: String, rateWidth: Int = 8) -> String {
        guard rateWidth > 0, let expression = rateExpression else { return text }
        let result = NSMutableString(string: text)
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        for match in matches.reversed() {
            let valueRange = match.range(at: 2)
            let value = (text as NSString).substring(with: valueRange)
            let padding = String(repeating: " ", count: max(rateWidth - value.count, 0))
            result.replaceCharacters(in: valueRange, with: padding + value)
        }
        return result as String
    }
}

enum TrafficRateFormatter {
    static func string(bytesPerSecond: Double, usesBits: Bool) -> String {
        let safeBytes = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let value = usesBits ? safeBytes * 8 : safeBytes
        let units = usesBits
            ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
            : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var scaled = value
        var unitIndex = 0
        while scaled >= 1_000, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }
        // Integer formatting begins at 9.95, so a value in the final half-step
        // below 1,000 would otherwise render as `1000 KB/s`. Promote that
        // rounded boundary before formatting to keep every rate inside the
        // fixed menu-bar column and avoid a one-frame width jump.
        if scaled >= 999.5, unitIndex < units.count - 1 {
            scaled /= 1_000
            unitIndex += 1
        }
        // Keep corrupted or synthetic counter spikes inside the fixed menu-bar
        // geometry instead of creating an arbitrarily wide status item.
        if unitIndex == units.count - 1, scaled > 999 {
            scaled = 999
        }

        let number: String
        // Values just below 10 can round to "10.0", unexpectedly growing past
        // the fixed eight-character rate column. Switch to integer formatting
        // at the half-step where one-decimal output would cross that boundary.
        if unitIndex == 0 || scaled >= 9.95 {
            number = String(format: "%.0f", scaled)
        } else {
            number = String(format: "%.1f", scaled)
        }
        return "\(number) \(units[unitIndex])"
    }

    static func fixedWidthString(
        bytesPerSecond: Double,
        usesBits: Bool,
        width: Int = 8
    ) -> String {
        let value = string(bytesPerSecond: bytesPerSecond, usesBits: usesBits)
        guard width > value.count else { return value }
        return String(repeating: " ", count: width - value.count) + value
    }
}

enum MenuBarIconLayout {
    static func fittedSize(source: CGSize, bounding: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, bounding.width > 0, bounding.height > 0 else {
            return .zero
        }
        let scale = min(bounding.width / source.width, bounding.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}
