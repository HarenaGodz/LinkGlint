import AppKit

/// Explicit equal-width mid row so traffic/IP cards stay flush (no NSStackView gravity float).
enum StatusPanelTrafficCardLayout {
    static let rangeLabelWidth: CGFloat = 72

    static func makeRangeContainer(label: NSTextField) -> NSView {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .right
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: rangeLabelWidth),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    static func makeTitleRow(title: NSTextField, rangeContainer: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, spacer, rangeContainer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = LinkGlintLayout.compactGap
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func makeContent(titleRow: NSView, rates: NSView, chart: NSView) -> NSView {
        let padding = LinkGlintLayout.cardPadding
        let spacing = LinkGlintLayout.cardInnerSpacing
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleRow, rates, chart] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        titleRow.setContentHuggingPriority(.required, for: .vertical)
        rates.setContentHuggingPriority(.required, for: .vertical)
        chart.setContentHuggingPriority(.defaultLow, for: .vertical)
        chart.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: content.topAnchor, constant: padding.top),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            rates.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: spacing),
            rates.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            rates.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            chart.topAnchor.constraint(equalTo: rates.bottomAnchor, constant: spacing),
            chart.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            chart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            chart.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding.bottom)
        ])
        return content
    }
}

/// Fixed-height IP meta block so geo lines loading do not reflow the card.
enum StatusPanelIPCardLayout {
    static let metaBlockHeight: CGFloat = 92
    static let countryLineHeight: CGFloat = 14
    static let detailLineHeight: CGFloat = 13
    static let ownershipLineHeight: CGFloat = 12
    static let intranetLineHeight: CGFloat = 15
    static let intranetGeoLineHeight: CGFloat = 14
    static let intranetOwnershipLineHeight: CGFloat = 12

    static func configureMetaLine(_ label: NSTextField, height: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    static func makeContent(title: NSView, address: NSView, meta: NSView) -> NSView {
        let padding = LinkGlintLayout.cardPadding
        let spacing = LinkGlintLayout.cardInnerSpacing
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [title, address, meta] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        title.setContentHuggingPriority(.required, for: .vertical)
        address.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: padding.top),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            address.topAnchor.constraint(equalTo: title.bottomAnchor, constant: spacing),
            address.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            address.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            meta.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding.left),
            meta.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding.right),
            meta.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding.bottom),
            meta.heightAnchor.constraint(equalToConstant: metaBlockHeight)
        ])
        return content
    }
}

enum StatusPanelMidRowLayout {
    static var height: CGFloat { LinkGlintLayout.trafficIPHeight }
    static var spacing: CGFloat { LinkGlintLayout.panelSectionGap }
    static var rowWidth: CGFloat { LinkGlintLayout.panelContentWidth }
    static var cardWidth: CGFloat { LinkGlintLayout.midRowCardWidth }

    static func makeRow(leading: NSView, trailing: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        for card in [leading, trailing] {
            card.setContentHuggingPriority(.defaultLow, for: .horizontal)
            card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            card.setContentHuggingPriority(.defaultLow, for: .vertical)
            card.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        row.addSubview(leading)
        row.addSubview(trailing)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: height),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leading.topAnchor.constraint(equalTo: row.topAnchor),
            leading.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.topAnchor.constraint(equalTo: row.topAnchor),
            trailing.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            trailing.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: spacing),
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor)
        ])
        return row
    }
}

/// Flat panel card without NSBox contentView centering, so mid-row charts fill width.
final class StatusPanelCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = LinkGlintLayout.rowRadius
        layer?.borderWidth = 1
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(LinkGlintLayout.cardBorderAlpha).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(LinkGlintLayout.cardFillAlpha).cgColor
    }
}
