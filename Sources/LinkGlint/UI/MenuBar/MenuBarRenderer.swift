import AppKit

enum MenuBarTrafficColors {
    static let download = NSColor(srgbRed: 0.20, green: 0.64, blue: 0.96, alpha: 1)
    static let upload = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.18, alpha: 1)
}

enum MenuBarStatusSemantics {
    static func titleColor(for title: String) -> NSColor? {
        switch title {
        case "检测中": return .tertiaryLabelColor
        case "离线": return .secondaryLabelColor
        case "读取失败": return .systemOrange
        default: return nil
        }
    }

    static func toolTip(for baseToolTip: String, networkTitle: String) -> String {
        switch networkTitle {
        case "检测中":
            return "LinkGlint · 正在检测网络状态"
        case "离线":
            return "LinkGlint · 离线 · 当前无可用网络连接"
        case "读取失败":
            return baseToolTip.contains("读取失败") ? baseToolTip : "LinkGlint · 读取失败 · 请尝试刷新"
        default:
            return baseToolTip
        }
    }
}

enum MenuBarDisplayPreset: String, CaseIterable {
    case compact
    case standard
    case minimal

    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .minimal: return "极简"
        }
    }

    func apply(to preferences: inout AppPreferences) {
        switch self {
        case .compact:
            preferences.showMenuBarTitle = false
            preferences.showMenuBarSpeed = true
            preferences.menuBarSpeedTwoLines = true
            preferences.menuBarSpeedInBits = false
            preferences.menuBarTrafficIndicatorStyle = .coloredDots
        case .standard:
            preferences.showMenuBarTitle = true
            preferences.showMenuBarSpeed = true
            preferences.menuBarSpeedTwoLines = true
            preferences.menuBarSpeedInBits = false
            preferences.menuBarTrafficIndicatorStyle = .coloredDots
        case .minimal:
            preferences.showMenuBarTitle = false
            preferences.showMenuBarSpeed = false
            preferences.menuBarSpeedTwoLines = true
            preferences.menuBarSpeedInBits = false
            preferences.menuBarTrafficIndicatorStyle = .coloredDots
        }
    }

    func matches(_ preferences: AppPreferences) -> Bool {
        switch self {
        case .compact:
            return !preferences.showMenuBarTitle
                && preferences.showMenuBarSpeed
                && preferences.menuBarSpeedTwoLines
                && !preferences.menuBarSpeedInBits
                && preferences.menuBarTrafficIndicatorStyle == .coloredDots
        case .standard:
            return preferences.showMenuBarTitle
                && preferences.showMenuBarSpeed
                && preferences.menuBarSpeedTwoLines
                && !preferences.menuBarSpeedInBits
                && preferences.menuBarTrafficIndicatorStyle == .coloredDots
        case .minimal:
            return !preferences.showMenuBarTitle
                && !preferences.showMenuBarSpeed
                && preferences.menuBarSpeedTwoLines
                && !preferences.menuBarSpeedInBits
                && preferences.menuBarTrafficIndicatorStyle == .coloredDots
        }
    }
}

struct MenuBarRenderContext: Equatable {
    let symbolName: String
    let networkTitle: String
    let vpnConnected: Bool
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let showsNetworkTitle: Bool
    let showsSpeed: Bool
    let usesTwoLines: Bool
    let usesBits: Bool
    let indicatorStyle: MenuBarTrafficIndicatorStyle

    init(
        symbolName: String,
        networkTitle: String,
        vpnConnected: Bool = false,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        showsNetworkTitle: Bool,
        showsSpeed: Bool,
        usesTwoLines: Bool,
        usesBits: Bool,
        indicatorStyle: MenuBarTrafficIndicatorStyle
    ) {
        self.symbolName = symbolName
        self.networkTitle = networkTitle
        self.vpnConnected = vpnConnected
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.showsNetworkTitle = showsNetworkTitle
        self.showsSpeed = showsSpeed
        self.usesTwoLines = usesTwoLines
        self.usesBits = usesBits
        self.indicatorStyle = indicatorStyle
    }

    static let preview = MenuBarRenderContext(
        symbolName: "wifi",
        networkTitle: "无线·Office",
        vpnConnected: false,
        downloadBytesPerSecond: 1_250_000,
        uploadBytesPerSecond: 42_000,
        showsNetworkTitle: true,
        showsSpeed: true,
        usesTwoLines: true,
        usesBits: false,
        indicatorStyle: .coloredDots
    )

    func applying(preferences: AppPreferences) -> MenuBarRenderContext {
        MenuBarRenderContext(
            symbolName: symbolName,
            networkTitle: networkTitle,
            vpnConnected: vpnConnected,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            showsNetworkTitle: preferences.showMenuBarTitle,
            showsSpeed: preferences.showMenuBarSpeed,
            usesTwoLines: preferences.menuBarSpeedTwoLines,
            usesBits: preferences.menuBarSpeedInBits,
            indicatorStyle: preferences.menuBarTrafficIndicatorStyle
        )
    }
}

struct MenuBarRenderOutcome: Equatable {
    let renderedPresentation: MenuBarTrafficPresentation
    let renderKey: String
}

final class MenuBarRenderer {
    private static let rateSegmentExpression = try? NSRegularExpression(
        pattern: #"([↓↑])\s*([0-9]+(?:\.[0-9]+)?)\s+([KMGT]?B/s|[KMGT]?bps)(?=\s|$)"#
    )

    private var lastRenderKey: String?
    private var lastRenderedPresentation: MenuBarTrafficPresentation?
    private var lastStandaloneSymbolKey: String?
    private var rateColumnWidths: [Bool: CGFloat] = [:]

    func resetCachedPresentation() {
        lastRenderKey = nil
        lastRenderedPresentation = nil
    }

    func invalidateRenderCache() {
        lastRenderKey = nil
    }

    func symbolImageForLaunch(accessibilityDescription: String) -> NSImage? {
        symbolImage(symbolName: "network", accessibilityDescription: accessibilityDescription)
    }

    @discardableResult
    func apply(to button: NSButton, statusItem: NSStatusItem, context: MenuBarRenderContext) -> MenuBarRenderOutcome? {
        let showsText = context.showsNetworkTitle || context.showsSpeed
        let latestPresentation = MenuBarTrafficPresentation.make(
            networkTitle: context.networkTitle,
            downloadBytesPerSecond: context.downloadBytesPerSecond,
            uploadBytesPerSecond: context.uploadBytesPerSecond,
            showsNetworkTitle: context.showsNetworkTitle,
            showsSpeed: context.showsSpeed,
            usesTwoLines: context.usesTwoLines,
            usesBits: context.usesBits
        )
        let renderState = MenuBarRenderPolicy.make(
            latestSymbolName: context.symbolName,
            latestPresentation: latestPresentation
        )
        let presentation = renderState.presentation
        let appearanceName = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let renderKey = "\(renderState.symbolName)|vpn=\(context.vpnConnected)|\(presentation.usesTwoLines)|\(context.indicatorStyle.rawValue)|\(appearanceName)|\(presentation.text)"
        guard renderKey != lastRenderKey else {
            if let lastRenderedPresentation {
                return MenuBarRenderOutcome(renderedPresentation: lastRenderedPresentation, renderKey: renderKey)
            }
            return nil
        }
        lastRenderKey = renderKey
        lastRenderedPresentation = presentation

        if presentation.usesTwoLines {
            lastStandaloneSymbolKey = nil
            if button.attributedTitle.length != 0 {
                button.attributedTitle = NSAttributedString(string: "")
            }
            button.image = twoLineImage(
                symbolName: renderState.symbolName,
                networkTitle: context.networkTitle,
                vpnConnected: context.vpnConnected,
                text: presentation.text,
                indicatorStyle: context.indicatorStyle,
                appearance: button.effectiveAppearance
            )
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
            if button.imageScaling != .scaleNone { button.imageScaling = .scaleNone }
            let targetLength = max(
                NSStatusItem.squareLength,
                ceil(button.image?.size.width ?? NSStatusItem.squareLength)
            )
            if abs(statusItem.length - targetLength) > 0.5 {
                statusItem.length = targetLength
            }
        } else {
            let stableText = MenuBarSingleLineLayout.stabilizedText(presentation.text)
            let title = attributedTitle(
                stableText,
                networkTitle: context.networkTitle,
                indicatorStyle: context.indicatorStyle
            )
            if !button.attributedTitle.isEqual(to: title) {
                button.attributedTitle = title
            }
            let standaloneSymbolKey = "\(renderState.symbolName)|vpn=\(context.vpnConnected)"
            if lastStandaloneSymbolKey != standaloneSymbolKey {
                button.image = statusSymbolImage(
                    symbolName: renderState.symbolName,
                    vpnConnected: context.vpnConnected,
                    accessibilityDescription: context.networkTitle
                )
                lastStandaloneSymbolKey = standaloneSymbolKey
            }
            let targetPosition: NSControl.ImagePosition = showsText ? .imageLeading : .imageOnly
            if button.imagePosition != targetPosition { button.imagePosition = targetPosition }
            let targetScaling: NSImageScaling = showsText ? .scaleProportionallyDown : .scaleNone
            if button.imageScaling != targetScaling { button.imageScaling = targetScaling }
            let targetLength = Self.statusItemLength(
                showsText: showsText,
                imageWidth: button.image?.size.width ?? 0
            )
            if abs(statusItem.length - targetLength) > 0.5 {
                statusItem.length = targetLength
            }
        }
        return MenuBarRenderOutcome(renderedPresentation: presentation, renderKey: renderKey)
    }

    func renderPreview(context: MenuBarRenderContext, appearance: NSAppearance) -> NSImage? {
        let presentation = MenuBarTrafficPresentation.make(
            networkTitle: context.networkTitle,
            downloadBytesPerSecond: context.downloadBytesPerSecond,
            uploadBytesPerSecond: context.uploadBytesPerSecond,
            showsNetworkTitle: context.showsNetworkTitle,
            showsSpeed: context.showsSpeed,
            usesTwoLines: context.usesTwoLines,
            usesBits: context.usesBits
        )
        guard context.showsNetworkTitle || context.showsSpeed else {
            return statusSymbolImage(
                symbolName: context.symbolName,
                vpnConnected: context.vpnConnected,
                accessibilityDescription: "预览"
            )
        }
        if presentation.usesTwoLines {
            return twoLineImage(
                symbolName: context.symbolName,
                networkTitle: context.networkTitle,
                vpnConnected: context.vpnConnected,
                text: presentation.text,
                indicatorStyle: context.indicatorStyle,
                appearance: appearance
            )
        }
        let stableText = MenuBarSingleLineLayout.stabilizedText(presentation.text)
        let title = attributedTitle(
            stableText,
            networkTitle: context.networkTitle,
            indicatorStyle: context.indicatorStyle
        )
        let symbol = statusSymbolImage(
            symbolName: context.symbolName,
            vpnConnected: context.vpnConnected,
            accessibilityDescription: "预览"
        )
        let symbolWidth = symbol?.size.width ?? 18
        let textWidth = ceil(title.size().width)
        let imageSize = NSSize(width: symbolWidth + 4 + textWidth, height: 20)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                symbol?.draw(
                    in: NSRect(x: 0, y: (rect.height - (symbol?.size.height ?? 16)) / 2, width: symbolWidth, height: symbol?.size.height ?? 16),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                title.draw(in: NSRect(x: symbolWidth + 4, y: 2, width: textWidth, height: rect.height - 4))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func trafficRateAttributedString(
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        usesBits: Bool,
        indicatorStyle: MenuBarTrafficIndicatorStyle = .coloredDots
    ) -> NSAttributedString {
        let downloadRate = TrafficRateFormatter.fixedWidthString(
            bytesPerSecond: downloadBytesPerSecond,
            usesBits: usesBits
        )
        let uploadRate = TrafficRateFormatter.fixedWidthString(
            bytesPerSecond: uploadBytesPerSecond,
            usesBits: usesBits
        )
        let markerFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let rateFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
        let unitColor = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString()
        result.append(markerAttributedString(
            marker: indicatorStyle == .coloredDots ? "●" : (indicatorStyle == .coloredTriangles ? "▼" : "↓"),
            direction: "↓",
            indicatorStyle: indicatorStyle,
            markerFont: markerFont
        ))
        result.append(NSAttributedString(string: " ", attributes: [.font: rateFont]))
        result.append(rateValueAttributedString(
            rateText: downloadRate,
            directionColor: MenuBarTrafficColors.download,
            indicatorStyle: indicatorStyle,
            rateFont: rateFont,
            unitColor: unitColor
        ))
        result.append(NSAttributedString(string: "   ", attributes: [.font: rateFont]))
        result.append(markerAttributedString(
            marker: indicatorStyle == .coloredDots ? "●" : (indicatorStyle == .coloredTriangles ? "▲" : "↑"),
            direction: "↑",
            indicatorStyle: indicatorStyle,
            markerFont: markerFont
        ))
        result.append(NSAttributedString(string: " ", attributes: [.font: rateFont]))
        result.append(rateValueAttributedString(
            rateText: uploadRate,
            directionColor: MenuBarTrafficColors.upload,
            indicatorStyle: indicatorStyle,
            rateFont: rateFont,
            unitColor: unitColor
        ))
        return result
    }

    static func usageSummaryAttributedString(
        downloadText: String,
        uploadText: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle = .coloredDots
    ) -> NSAttributedString {
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let markerFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        let unitColor = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString(
            string: "今日记录 ",
            attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
        result.append(markerAttributedString(
            marker: "↓",
            direction: "↓",
            indicatorStyle: indicatorStyle,
            markerFont: markerFont
        ))
        result.append(NSAttributedString(string: " \(downloadText)  ", attributes: [.font: bodyFont, .foregroundColor: unitColor]))
        result.append(markerAttributedString(
            marker: "↑",
            direction: "↑",
            indicatorStyle: indicatorStyle,
            markerFont: markerFont
        ))
        result.append(NSAttributedString(string: " \(uploadText)", attributes: [.font: bodyFont, .foregroundColor: unitColor]))
        return result
    }

    private static func markerAttributedString(
        marker: String,
        direction: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle,
        markerFont: NSFont
    ) -> NSAttributedString {
        let color: NSColor
        if indicatorStyle.usesColor {
            color = direction == "↓" ? MenuBarTrafficColors.download : MenuBarTrafficColors.upload
        } else {
            color = .secondaryLabelColor
        }
        return NSAttributedString(
            string: marker,
            attributes: [.font: markerFont, .foregroundColor: color, .baselineOffset: 0.25]
        )
    }

    private static func rateValueAttributedString(
        rateText: String,
        directionColor: NSColor,
        indicatorStyle: MenuBarTrafficIndicatorStyle,
        rateFont: NSFont,
        unitColor: NSColor
    ) -> NSAttributedString {
        let trimmed = rateText.trimmingCharacters(in: .whitespaces)
        guard indicatorStyle.usesColor,
              let parts = MenuBarRateParts.parse("↓\(trimmed)") ?? MenuBarRateParts.parse("↑\(trimmed)") else {
            return NSAttributedString(
                string: trimmed,
                attributes: [.font: rateFont, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: rateFont,
            .foregroundColor: directionColor
        ]
        let unitAttributes: [NSAttributedString.Key: Any] = [
            .font: rateFont,
            .foregroundColor: unitColor
        ]
        let result = NSMutableAttributedString(string: parts.number, attributes: numberAttributes)
        result.append(NSAttributedString(string: " \(parts.unit)", attributes: unitAttributes))
        return result
    }

    private func symbolImage(symbolName: String, accessibilityDescription: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func statusSymbolImage(
        symbolName: String,
        vpnConnected: Bool,
        accessibilityDescription: String
    ) -> NSImage? {
        guard vpnConnected else {
            return symbolImage(symbolName: symbolName, accessibilityDescription: accessibilityDescription)
        }
        // Reserve three distinct horizontal zones: the complete network
        // symbol, a small gap, and the VPN lock at the lower-right. This keeps
        // the lock clear of both the symbol and any title drawn to its right.
        let image = NSImage(size: NSSize(width: 30, height: 20), flipped: false) { rect in
            guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                  let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)) else {
                return false
            }
            let baseSize = MenuBarIconLayout.fittedSize(
                source: base.size,
                bounding: NSSize(width: 19, height: 19)
            )
            base.draw(
                in: NSRect(
                    x: 0,
                    y: (rect.height - baseSize.height) / 2,
                    width: baseSize.width,
                    height: baseSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let lockSize = MenuBarIconLayout.fittedSize(
                source: lock.size,
                bounding: NSSize(width: 10, height: 10)
            )
            lock.draw(
                in: NSRect(
                    x: 19.5,
                    y: 0.5,
                    width: lockSize.width,
                    height: lockSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func attributedTitle(
        _ text: String,
        networkTitle: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle
    ) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        if let semanticColor = MenuBarStatusSemantics.titleColor(for: networkTitle),
           text.hasPrefix(networkTitle) {
            result.addAttribute(
                .foregroundColor,
                value: semanticColor,
                range: NSRange(location: 0, length: (networkTitle as NSString).length)
            )
        }
        let speedFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let protectedPrefixLength = text.hasPrefix(networkTitle) ? (networkTitle as NSString).length : 0
        let fullRange = NSRange(location: 0, length: result.length)
        let matches = Self.rateSegmentExpression?.matches(in: result.string, range: fullRange) ?? []
        for match in matches.reversed() where match.range.location >= protectedPrefixLength {
            let markerRange = match.range(at: 1)
            let numberRange = match.range(at: 2)
            let unitRange = match.range(at: 3)
            let direction = (result.string as NSString).substring(with: markerRange)
            let marker: String
            switch indicatorStyle {
            case .arrows:
                marker = direction
            case .coloredDots:
                marker = "●"
            case .coloredTriangles:
                marker = direction == "↓" ? "▼" : "▲"
            }
            if marker != direction {
                result.replaceCharacters(in: markerRange, with: marker)
            }
            result.addAttribute(.font, value: speedFont, range: match.range)
            guard indicatorStyle.usesColor else { continue }

            let directionColor = direction == "↓"
                ? MenuBarTrafficColors.download : MenuBarTrafficColors.upload
            let markerSize: CGFloat = indicatorStyle == .coloredDots ? 8.5 : 7.5
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: markerSize, weight: .bold),
                .foregroundColor: directionColor,
                .kern: 1.0,
                .baselineOffset: 0.25
            ], range: markerRange)
            result.addAttribute(.foregroundColor, value: directionColor, range: numberRange)
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: unitRange)
        }
        return result
    }

    private func twoLineImage(
        symbolName: String,
        networkTitle: String,
        vpnConnected: Bool,
        text: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle,
        appearance: NSAppearance
    ) -> NSImage? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 2 else {
            return statusSymbolImage(
                symbolName: symbolName,
                vpnConnected: vpnConnected,
                accessibilityDescription: text
            )
        }

        let topFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let bottomFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let foregroundColor = indicatorStyle.usesColor ? NSColor.labelColor : NSColor.black
        let topColor = MenuBarStatusSemantics.titleColor(for: networkTitle) ?? foregroundColor
        let topAttributes: [NSAttributedString.Key: Any] = [
            .font: topFont,
            .foregroundColor: topColor
        ]
        let bottomAttributes: [NSAttributedString.Key: Any] = [
            .font: bottomFont,
            .foregroundColor: foregroundColor
        ]
        let unitColor = NSColor.secondaryLabelColor
        let centeredMarkerStyle = NSMutableParagraphStyle()
        centeredMarkerStyle.alignment = .center
        let centeredMarkerAttributes: [NSAttributedString.Key: Any] = [
            .font: bottomFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: centeredMarkerStyle
        ]
        let topWidth = ceil((lines[0] as NSString).size(withAttributes: topAttributes).width)
        let combinedColumns = MenuBarTrafficColumns.parse(combinedLine: lines[1])

        func ratePair(_ first: String, _ second: String) -> (MenuBarRateParts, MenuBarRateParts)? {
            guard let firstRate = MenuBarRateParts.parse(first),
                  let secondRate = MenuBarRateParts.parse(second) else { return nil }
            return (firstRate, secondRate)
        }

        let combinedRates = combinedColumns.flatMap { ratePair($0.download, $0.upload) }
        let speedOnlyRates = ratePair(lines[0], lines[1])
        let representativeRate = combinedRates?.0 ?? speedOnlyRates?.0
        let usesBits = representativeRate?.unit.hasSuffix("bps") == true
        let unitSamples = usesBits
            ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
            : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let valueWidth: CGFloat
        if let cachedWidth = rateColumnWidths[usesBits] {
            valueWidth = cachedWidth
        } else {
            let valueSamples = ["0", "9.9", "10", "999"].flatMap { number in
                unitSamples.map { "\(number) \($0)" }
            }
            valueWidth = valueSamples.map {
                ceil(($0 as NSString).size(withAttributes: bottomAttributes).width)
            }.max() ?? 0
            rateColumnWidths[usesBits] = valueWidth
        }
        let rateGeometry = MenuBarRatePairGeometry(
            markerWidth: 8,
            valueWidth: valueWidth,
            markerValueGap: 1,
            groupGap: 3
        )
        let plainBottomWidth = ceil((lines[1] as NSString).size(withAttributes: bottomAttributes).width)
        let geometry: MenuBarTwoLineGeometry
        if combinedRates != nil {
            geometry = .make(topWidth: topWidth, bottomWidth: rateGeometry.totalWidth)
        } else if speedOnlyRates != nil {
            geometry = .make(topWidth: rateGeometry.groupWidth, bottomWidth: rateGeometry.groupWidth)
        } else {
            geometry = .make(topWidth: topWidth, bottomWidth: plainBottomWidth)
        }
        // VPN gets its own lower-right slot after the complete network symbol.
        // Keep the same text gap as the non-VPN layout so rates are not cramped.
        let iconBoxSize = NSSize(width: vpnConnected ? 30 : 18, height: vpnConnected ? 20 : 16)
        let baseSymbolBoxSize = NSSize(width: 18, height: vpnConnected ? 18 : 16)
        let textSpacing: CGFloat = 4
        let textWidth = geometry.textWidth
        let imageSize = NSSize(width: iconBoxSize.width + textSpacing + textWidth, height: 20)

        let image = NSImage(size: imageSize, flipped: false) { rect in
            var rendered = false
            appearance.performAsCurrentDrawingAppearance {
                var baseSymbolRect = NSRect(
                    x: 0,
                    y: (rect.height - baseSymbolBoxSize.height) / 2,
                    width: baseSymbolBoxSize.width,
                    height: baseSymbolBoxSize.height
                )
                let foregroundColor = NSColor.labelColor
                if let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                    let pointConfiguration = NSImage.SymbolConfiguration(
                        pointSize: vpnConnected ? 16 : 15,
                        weight: .semibold
                    )
                    let configuration: NSImage.SymbolConfiguration
                    if indicatorStyle.usesColor {
                        configuration = pointConfiguration.applying(
                            NSImage.SymbolConfiguration(paletteColors: [foregroundColor])
                        )
                    } else {
                        configuration = pointConfiguration
                    }
                    if let symbol = baseSymbol.withSymbolConfiguration(configuration) {
                        let fittedSize = MenuBarIconLayout.fittedSize(
                            source: symbol.size,
                            bounding: baseSymbolBoxSize
                        )
                        baseSymbolRect = NSRect(
                            x: (baseSymbolBoxSize.width - fittedSize.width) / 2,
                            y: (rect.height - fittedSize.height) / 2,
                            width: fittedSize.width,
                            height: fittedSize.height
                        )
                        symbol.draw(
                            in: baseSymbolRect,
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1
                        )
                    }
                }
                if vpnConnected,
                   let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
                    let lockPoint = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
                    let lockConfiguration = lockPoint.applying(
                        NSImage.SymbolConfiguration(paletteColors: [NSColor.secondaryLabelColor])
                    )
                    let configuredLock = lock.withSymbolConfiguration(lockConfiguration) ?? lock
                    let lockSize = MenuBarIconLayout.fittedSize(
                        source: configuredLock.size,
                        bounding: NSSize(width: 10, height: 10)
                    )
                    configuredLock.draw(
                        in: NSRect(
                            x: 19.5,
                            y: 0.5,
                            width: lockSize.width,
                            height: lockSize.height
                        ),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                }

                let textX = iconBoxSize.width + textSpacing
                let topLineX = textX + geometry.centeredX(contentWidth: topWidth)

                func drawMarker(_ direction: String, x: CGFloat, y: CGFloat) {
                    let markerRect = NSRect(x: x, y: y, width: rateGeometry.markerWidth, height: 10.2)
                    switch indicatorStyle {
                    case .arrows:
                        (direction as NSString).draw(in: markerRect, withAttributes: centeredMarkerAttributes)
                    case .coloredDots:
                        (direction == "↓" ? MenuBarTrafficColors.download : MenuBarTrafficColors.upload).setFill()
                        let diameter: CGFloat = 5.5
                        NSBezierPath(
                            ovalIn: NSRect(
                                x: markerRect.midX - diameter / 2,
                                y: markerRect.midY - diameter / 2,
                                width: diameter,
                                height: diameter
                            )
                        ).fill()
                    case .coloredTriangles:
                        let color = direction == "↓" ? MenuBarTrafficColors.download : MenuBarTrafficColors.upload
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                            .foregroundColor: color,
                            .paragraphStyle: centeredMarkerStyle,
                            .baselineOffset: 0.25
                        ]
                        let glyph = direction == "↓" ? "▼" : "▲"
                        (glyph as NSString).draw(in: markerRect, withAttributes: attributes)
                    }
                }

                func drawRateGroup(_ rate: MenuBarRateParts, x: CGFloat, y: CGFloat) {
                    drawMarker(rate.direction, x: x, y: y)
                    let directionColor = rate.direction == "↓" ? MenuBarTrafficColors.download : MenuBarTrafficColors.upload
                    let numberAttributes: [NSAttributedString.Key: Any] = [
                        .font: bottomFont,
                        .foregroundColor: indicatorStyle.usesColor ? directionColor : foregroundColor
                    ]
                    let unitAttributes: [NSAttributedString.Key: Any] = [
                        .font: bottomFont,
                        .foregroundColor: indicatorStyle.usesColor ? unitColor : foregroundColor
                    ]
                    let numberRect = NSRect(
                        x: x + rateGeometry.valueX,
                        y: y,
                        width: rateGeometry.valueWidth,
                        height: 10.2
                    )
                    (rate.number as NSString).draw(in: numberRect, withAttributes: numberAttributes)
                    let numberWidth = ceil((rate.number as NSString).size(withAttributes: numberAttributes).width)
                    let unitRect = NSRect(
                        x: x + rateGeometry.valueX + numberWidth,
                        y: y,
                        width: max(rateGeometry.valueWidth - numberWidth, 0),
                        height: 10.2
                    )
                    (" \(rate.unit)" as NSString).draw(in: unitRect, withAttributes: unitAttributes)
                }

                if let rates = combinedRates {
                    (lines[0] as NSString).draw(
                        in: NSRect(x: topLineX, y: 9.7, width: topWidth, height: 10.3),
                        withAttributes: topAttributes
                    )
                    let ratePairX = textX + geometry.centeredX(contentWidth: rateGeometry.totalWidth)
                    drawRateGroup(rates.0, x: ratePairX, y: -0.1)
                    drawRateGroup(rates.1, x: ratePairX + rateGeometry.uploadX, y: -0.1)
                } else if let rates = speedOnlyRates {
                    drawRateGroup(rates.0, x: textX, y: 9.7)
                    drawRateGroup(rates.1, x: textX, y: -0.1)
                } else {
                    (lines[0] as NSString).draw(
                        in: NSRect(x: topLineX, y: 9.7, width: topWidth, height: 10.3),
                        withAttributes: topAttributes
                    )
                    (lines[1] as NSString).draw(
                        in: NSRect(
                            x: textX + geometry.centeredX(contentWidth: plainBottomWidth),
                            y: -0.1,
                            width: plainBottomWidth,
                            height: 10.2
                        ),
                        withAttributes: bottomAttributes
                    )
                }
                rendered = true
            }
            return rendered
        }
        image.isTemplate = !indicatorStyle.usesColor
        image.accessibilityDescription = text.replacingOccurrences(of: "\n", with: "，")
        return image
    }
}

final class MenuBarPreviewView: NSView {
    var previewImage: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let strip = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: strip, xRadius: 10, yRadius: 10)

            // Menu-bar-like strip: soft fill + subtle top highlight.
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
            path.fill()

            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()

            guard let previewImage else { return }
            let maxHeight = max(strip.height - 14, 18)
            let scale = min(1, maxHeight / max(previewImage.size.height, 1))
            let fittedHeight = previewImage.size.height * scale
            let fittedWidth = previewImage.size.width * scale
            let drawRect = NSRect(
                x: strip.midX - fittedWidth / 2,
                y: strip.midY - fittedHeight / 2,
                width: fittedWidth,
                height: fittedHeight
            )
            previewImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

extension MenuBarRenderer {
    /// `NSStatusItem.squareLength` is a sentinel (-2), not a point size. Only
    /// replace it with an explicit width for the wider VPN composite icon (~30pt).
    static func statusItemLength(showsText: Bool, imageWidth: CGFloat) -> CGFloat {
        if showsText { return NSStatusItem.variableLength }
        if imageWidth >= 28 {
            return max(28, ceil(imageWidth))
        }
        return NSStatusItem.squareLength
    }

    func makeAttributedTitleForTesting(
        text: String,
        networkTitle: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle
    ) -> NSAttributedString {
        attributedTitle(text, networkTitle: networkTitle, indicatorStyle: indicatorStyle)
    }

    func statusItemLengthForTesting(showsText: Bool, vpnConnected: Bool, symbolName: String = "wifi") -> CGFloat {
        let image = statusSymbolImage(
            symbolName: symbolName,
            vpnConnected: vpnConnected,
            accessibilityDescription: "test"
        )
        return Self.statusItemLength(showsText: showsText, imageWidth: image?.size.width ?? 0)
    }
}
