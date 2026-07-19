import AppKit

final class PriorityOrderEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let dragType = NSPasteboard.PasteboardType("io.github.harenagodz.LinkGlint.priority-row")

    private var services: [NetworkService]
    private let tableView = NSTableView()
    private let moveUpButton = NSButton()
    private let moveDownButton = NSButton()

    var orderedServiceNames: [String] { services.map(\.name) }

    init(services: [NetworkService]) {
        self.services = services.sorted { $0.orderIndex < $1.orderIndex }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))

        let hint = NSTextField(wrappingLabelWithString: "拖动服务即可排序，也可选中后使用上下按钮。第 1 项优先级最高。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("service"))
        column.title = "网络服务"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        moveUpButton.title = "上移"
        moveUpButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        moveUpButton.imagePosition = .imageLeading
        moveUpButton.bezelStyle = .rounded
        moveUpButton.target = self
        moveUpButton.action = #selector(moveSelectedServiceUp(_:))

        moveDownButton.title = "下移"
        moveDownButton.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        moveDownButton.imagePosition = .imageLeading
        moveDownButton.bezelStyle = .rounded
        moveDownButton.target = self
        moveDownButton.action = #selector(moveSelectedServiceDown(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [spacer, moveUpButton, moveDownButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let stack = NSStackView(views: [hint, scrollView, controls])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 225)
        ])
        view = root
        if !services.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("priority-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? PriorityOrderCellView)
            ?? PriorityOrderCellView(identifier: identifier)
        cell.configure(service: services[row], position: row + 1)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pasteboard: NSPasteboard) -> Bool {
        guard let row = rowIndexes.first else { return false }
        pasteboard.declareTypes([Self.dragType], owner: nil)
        return pasteboard.setString(String(row), forType: Self.dragType)
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingPasteboard.string(forType: Self.dragType) == nil ? [] : .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.dragType),
              let source = Int(text), services.indices.contains(source) else { return false }
        var destination = min(max(row, 0), services.count)
        let service = services.remove(at: source)
        if source < destination { destination -= 1 }
        services.insert(service, at: destination)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        updateButtons()
        return true
    }

    @objc private func moveSelectedServiceUp(_ sender: Any?) { moveSelection(by: -1) }
    @objc private func moveSelectedServiceDown(_ sender: Any?) { moveSelection(by: 1) }

    private func moveSelection(by offset: Int) {
        let source = tableView.selectedRow
        let destination = source + offset
        guard services.indices.contains(source), services.indices.contains(destination) else { return }
        services.swapAt(source, destination)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        tableView.scrollRowToVisible(destination)
        updateButtons()
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        moveUpButton.isEnabled = row > 0
        moveDownButton.isEnabled = row >= 0 && row < services.count - 1
    }
}

private final class PriorityOrderCellView: NSTableCellView {
    private let handle = NSImageView()
    private let positionLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")
        handle.contentTintColor = .tertiaryLabelColor
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        positionLabel.alignment = .center
        positionLabel.textColor = .secondaryLabelColor
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        stateLabel.font = .systemFont(ofSize: 10.5)
        stateLabel.alignment = .right

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [handle, positionLabel, nameLabel, spacer, stateLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            handle.widthAnchor.constraint(equalToConstant: 16),
            handle.heightAnchor.constraint(equalToConstant: 16),
            positionLabel.widthAnchor.constraint(equalToConstant: 24),
            stateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(service: NetworkService, position: Int) {
        positionLabel.stringValue = "\(position)"
        nameLabel.stringValue = service.name
        nameLabel.toolTip = service.name
        if service.isPrimary {
            stateLabel.stringValue = "当前出口"
            stateLabel.textColor = .systemGreen
        } else if service.connected {
            stateLabel.stringValue = "已连接"
            stateLabel.textColor = .systemBlue
        } else if service.enabled {
            stateLabel.stringValue = "可用"
            stateLabel.textColor = .secondaryLabelColor
        } else {
            stateLabel.stringValue = "已停用"
            stateLabel.textColor = .tertiaryLabelColor
        }
    }
}
