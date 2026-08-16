import AppKit

final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let tracker: UsageTracker
    private let formatBytes: (UInt64) -> String
    private let calendar: Calendar
    private var rangeControl: NSSegmentedControl!
    private var chartView: UsageHistoryChartView!
    private var tableView: NSTableView!
    private var records: [DailyNetworkUsage] = []
    private var receivedSummaryLabel: NSTextField!
    private var sentSummaryLabel: NSTextField!
    private var totalSummaryLabel: NSTextField!
    private var averageSummaryLabel: NSTextField!

    init(
        tracker: UsageTracker,
        formatBytes: @escaping (UInt64) -> String,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.tracker = tracker
        self.formatBytes = formatBytes
        self.calendar = calendar
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinkGlint 用量中心"
        window.minSize = NSSize(width: 580, height: 470)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("LinkGlint.UsageHistoryWindow.v1")
        if !window.setFrameUsingName("LinkGlint.UsageHistoryWindow.v1") {
            window.center()
        }
        buildInterface()
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        refresh()
    }

    @objc private func exportCSV(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "导出用量记录"
        panel.nameFieldStringValue = "LinkGlint-用量记录.csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let lines = ["日期,下载字节,上传字节,下载,上传"] + records.map { record in
            let received = formatBytes(record.receivedBytes)
            let sent = formatBytes(record.sentBytes)
            return "\(record.dateKey),\(record.receivedBytes),\(record.sentBytes),\(received),\(sent)"
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func copySummary(_ sender: Any?) {
        let totalReceived = records.reduce(0) { saturatingAdd($0, $1.receivedBytes) }
        let totalSent = records.reduce(0) { saturatingAdd($0, $1.sentBytes) }
        let period = records.count == 7 ? "最近 7 天" : "最近 30 天"
        let text = "LinkGlint 用量摘要（\(period)）\n下载：\(formatBytes(totalReceived))\n上传：\(formatBytes(totalSent))\n合计：\(formatBytes(saturatingAdd(totalReceived, totalSent)))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func buildInterface() {
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .behindWindow
        background.state = .active
        window?.contentView = background

        let title = NSTextField(labelWithString: "用量中心")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "仅统计 LinkGlint 运行期间从本机接口采集的流量，数据保存在本机。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        rangeControl = NSSegmentedControl(labels: ["最近 7 天", "最近 30 天"], trackingMode: .selectOne, target: self, action: #selector(rangeChanged(_:)))
        rangeControl.segmentStyle = .rounded
        rangeControl.selectedSegment = 0
        rangeControl.setAccessibilityLabel("用量时间范围")
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        rangeControl.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let export = NSButton(title: "导出 CSV…", target: self, action: #selector(exportCSV(_:)))
        export.bezelStyle = .rounded
        export.controlSize = .small
        let copy = NSButton(title: "复制摘要", target: self, action: #selector(copySummary(_:)))
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        let controlsSpacer = NSView()
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [rangeControl, controlsSpacer, copy, export])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let header = NSStackView(views: [title, subtitle, controls])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 5

        receivedSummaryLabel = summaryValueLabel(color: MenuBarTrafficColors.download)
        sentSummaryLabel = summaryValueLabel(color: MenuBarTrafficColors.upload)
        totalSummaryLabel = summaryValueLabel(color: .labelColor)
        averageSummaryLabel = summaryValueLabel(color: .secondaryLabelColor)
        let summaryCards = [
            summaryCard(title: "下载", value: receivedSummaryLabel, symbol: "arrow.down", color: MenuBarTrafficColors.download),
            summaryCard(title: "上传", value: sentSummaryLabel, symbol: "arrow.up", color: MenuBarTrafficColors.upload),
            summaryCard(title: "合计", value: totalSummaryLabel, symbol: "sum", color: .labelColor),
            summaryCard(title: "日均合计", value: averageSummaryLabel, symbol: "chart.bar", color: .secondaryLabelColor)
        ]
        let summaries = NSStackView(views: summaryCards)
        summaries.orientation = .horizontal
        summaries.alignment = .centerY
        summaries.spacing = 8
        for card in summaryCards.dropFirst() {
            card.widthAnchor.constraint(equalTo: summaryCards[0].widthAnchor).isActive = true
        }

        chartView = UsageHistoryChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.heightAnchor.constraint(equalToConstant: 210).isActive = true
        let chartCard = card(containing: chartView, title: "每日用量")

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 25
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.width = 150
        let receivedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("received"))
        receivedColumn.resizingMask = .autoresizingMask
        let sentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sent"))
        sentColumn.width = 180
        tableView.addTableColumn(dateColumn)
        tableView.addTableColumn(receivedColumn)
        tableView.addTableColumn(sentColumn)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let tableCard = card(containing: scroll, title: "每日明细")
        let root = NSStackView(views: [header, summaries, chartCard, tableCard])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18)
        ])
        for arrangedView in [header, summaries, chartCard, tableCard] {
            NSLayoutConstraint.activate([
                arrangedView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                arrangedView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
            ])
        }
    }

    private func refresh() {
        let count = rangeControl?.selectedSegment == 1 ? 30 : 7
        records = tracker.dailyWindow(limit: count, endingAt: Date())
        chartView?.records = records
        tableView?.reloadData()
        let received = records.reduce(0) { saturatingAdd($0, $1.receivedBytes) }
        let sent = records.reduce(0) { saturatingAdd($0, $1.sentBytes) }
        receivedSummaryLabel?.stringValue = formatBytes(received)
        sentSummaryLabel?.stringValue = formatBytes(sent)
        totalSummaryLabel?.stringValue = formatBytes(saturatingAdd(received, sent))
        averageSummaryLabel?.stringValue = formatBytes(saturatingAdd(received, sent) / UInt64(max(records.count, 1)))
    }

    private func summaryValueLabel(color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "—")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = color
        return label
    }

    private func summaryCard(title: String, value: NSTextField, symbol: String, color: NSColor) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.spacing = 2
        let row = NSStackView(views: [icon, stack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return card(containing: row, title: nil)
    }

    private func card(containing content: NSView, title: String?) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.35)
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.32)
        var views: [NSView] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            views.append(label)
        }
        views.append(content)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = title == nil ? 0 : 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        box.contentView?.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)
        ])
        return box
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        rhs > UInt64.max - lhs ? UInt64.max : lhs + rhs
    }
}

extension UsageHistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cellID = NSUserInterfaceItemIdentifier("usage-\(identifier.rawValue)")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView)
            ?? NSTableCellView(frame: .zero)
        cell.identifier = cellID
        let label = (cell.textField ?? NSTextField(labelWithString: ""))
        if label.superview == nil {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        let record = records[row]
        switch identifier.rawValue {
        case "date": label.stringValue = record.dateKey
        case "received":
            label.stringValue = "↓ \(formatBytes(record.receivedBytes))"
            label.textColor = MenuBarTrafficColors.download
        default:
            label.stringValue = "↑ \(formatBytes(record.sentBytes))"
            label.textColor = MenuBarTrafficColors.upload
        }
        return cell
    }
}

private final class UsageHistoryChartView: NSView {
    var records: [DailyNetworkUsage] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !records.isEmpty else { return }
        let plot = NSRect(
            x: bounds.minX + 36,
            y: bounds.minY + 16,
            width: max(bounds.width - 50, 1),
            height: max(bounds.height - 42, 1)
        )
        let maxValue = max(records.map { max(Double($0.receivedBytes), Double($0.sentBytes)) }.max() ?? 0, 1)
        let spacing: CGFloat = records.count > 14 ? 2 : 5
        let columnWidth = max((plot.width - CGFloat(records.count - 1) * spacing) / CGFloat(records.count), 2)
        let baseline: CGFloat = plot.origin.y + plot.size.height
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: plot.minX, y: baseline))
        grid.line(to: NSPoint(x: plot.maxX, y: baseline))
        grid.stroke()
        let formatter = ByteAxisFormatter()
        let maxLabel = formatter.string(UInt64(maxValue))
        let maxLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        NSString(string: maxLabel).draw(
            at: NSPoint(x: 2, y: plot.minY - 5),
            withAttributes: maxLabelAttributes
        )
        for (index, record) in records.enumerated() {
            let x = plot.minX + CGFloat(index) * (columnWidth + spacing)
            let receivedHeight = plot.height * CGFloat(Double(record.receivedBytes) / maxValue)
            let sentHeight = plot.height * CGFloat(Double(record.sentBytes) / maxValue)
            let receivedRect = NSRect(x: x, y: baseline - receivedHeight, width: max(columnWidth * 0.46, 1), height: receivedHeight)
            let sentRect = NSRect(x: x + columnWidth * 0.52, y: baseline - sentHeight, width: max(columnWidth * 0.46, 1), height: sentHeight)
            MenuBarTrafficColors.download.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: receivedRect, xRadius: 2, yRadius: 2).fill()
            MenuBarTrafficColors.upload.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: sentRect, xRadius: 2, yRadius: 2).fill()
            if records.count <= 14 || index.isMultiple(of: 5) || index == records.count - 1 {
                let date = String(record.dateKey.suffix(5))
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
                NSString(string: date).draw(at: NSPoint(x: x - 5, y: baseline + 5), withAttributes: attrs)
            }
        }
    }
}

private struct ByteAxisFormatter {
    func string(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(bytes) B"
    }
}
