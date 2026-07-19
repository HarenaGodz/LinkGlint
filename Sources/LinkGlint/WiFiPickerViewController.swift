import AppKit

/// Tracks one coalesced retry while CoreWLAN is still servicing the previous
/// scan. Tokens make delayed timeout callbacks harmless after the request has
/// completed, been cancelled, or been replaced by a later picker session.
struct WiFiPendingScanRequest {
    private(set) var isPending = false
    private var token: UInt = 0

    /// Returns a timeout token for the first pending request. Repeated clicks
    /// stay coalesced and do not extend the original bounded wait.
    mutating func enqueue() -> UInt? {
        guard !isPending else { return nil }
        token &+= 1
        isPending = true
        return token
    }

    mutating func expire(token expectedToken: UInt) -> Bool {
        guard isPending, token == expectedToken else { return false }
        isPending = false
        token &+= 1
        return true
    }

    mutating func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        token &+= 1
        return true
    }

    mutating func cancel() {
        isPending = false
        token &+= 1
    }
}

final class WiFiPickerViewController: NSViewController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onRefresh: (() -> Void)?
    var onConnect: ((String, String?, Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onSuspendScan: (() -> Void)?
    var onOpenLocationSettings: (() -> Void)?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    private var lastNetworks: [WiFiNetwork] = []
    private var currentSSID: String?
    private var tableNetworks: [WiFiNetwork] = []
    private weak var nameField: NSTextField?
    private weak var passwordField: NSSecureTextField?
    private weak var connectButton: NSButton?
    private var credentialNetworkIsSecure = false

    override func loadView() {
        let size = NSSize(width: 360, height: 380)
        view = WiFiPickerBackgroundView(frame: NSRect(origin: .zero, size: size))
        preferredContentSize = size
    }

    func showLoading() {
        showScanProgress(
            message: "正在扫描附近的 Wi-Fi…",
            subtitle: "扫描可能需要几秒钟"
        )
    }

    func showWaitingForCurrentScan() {
        showScanProgress(
            message: "正在等待上一次扫描结束…",
            subtitle: "已合并请求 · 不会重复扫描"
        )
    }

    private func showScanProgress(message: String, subtitle: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = secondaryLabel(message)
        let body = centeredBody([spinner, label])
        install(
            title: "选择 Wi-Fi",
            subtitle: subtitle,
            body: body,
            footer: manualButton(),
            size: NSSize(width: 332, height: 250)
        )
    }

    func showLocationRequest() {
        let icon = symbolView("location", color: .systemBlue, size: 28)
        let title = NSTextField(labelWithString: "需要允许读取附近网络")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = wrappingLabel("macOS 使用“定位服务”保护附近 Wi-Fi 名称。授权后即可在这里直接选择网络。")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let body = centeredBody([icon, title, detail, spinner])
        install(title: "选择 Wi-Fi", subtitle: "等待系统授权", body: body, footer: manualButton(), size: NSSize(width: 332, height: 292))
    }

    func showLocationDenied() {
        let icon = symbolView("location.slash", color: .systemOrange, size: 28)
        let title = NSTextField(labelWithString: "附近网络列表不可用")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = wrappingLabel("请在“系统设置 → 隐私与安全性 → 定位服务”中允许 LinkGlint；也可继续手动输入网络名称。")
        let settings = NSButton(title: "打开定位服务设置", target: self, action: #selector(openLocationSettings))
        settings.bezelStyle = .rounded
        settings.controlSize = .small
        let body = centeredBody([icon, title, detail, settings])
        install(title: "选择 Wi-Fi", subtitle: "需要定位服务权限", body: body, footer: manualButton(), size: NSSize(width: 332, height: 300))
    }

    func showError(_ message: String) {
        let icon = symbolView("wifi.exclamationmark", color: .systemOrange, size: 28)
        let title = NSTextField(labelWithString: "未能读取附近网络")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = wrappingLabel(message)
        let retry = NSButton(title: "重新扫描", target: self, action: #selector(refresh))
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        let body = centeredBody([icon, title, detail, retry])
        install(title: "选择 Wi-Fi", subtitle: "扫描失败", body: body, footer: manualButton(), size: NSSize(width: 332, height: 292))
    }

    func showNetworks(_ networks: [WiFiNetwork], currentSSID: String?) {
        lastNetworks = networks
        self.currentSSID = currentSSID

        let body: NSView
        var tableToFocus: WiFiNetworkTableView?
        if networks.isEmpty {
            let icon = symbolView("wifi.slash", color: .secondaryLabelColor, size: 28)
            let title = NSTextField(labelWithString: "未发现附近网络")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = secondaryLabel("请靠近无线路由器后重新扫描")
            body = centeredBody([icon, title, detail])
        } else {
            tableNetworks = networks
            let table = WiFiNetworkTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("wifi-network"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .regular
            table.allowsEmptySelection = false
            table.allowsMultipleSelection = false
            table.rowHeight = 48
            table.intercellSpacing = NSSize(width: 0, height: 2)
            table.dataSource = self
            table.delegate = self
            table.onActivate = { [weak self, weak table] in
                guard let self, let table, self.tableNetworks.indices.contains(table.selectedRow) else { return }
                self.chooseNetwork(self.tableNetworks[table.selectedRow])
            }
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = networks.count > 6
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.documentView = table
            body = scroll
            tableToFocus = table
        }

        let countText = networks.isEmpty ? "没有可用网络" : "发现 \(networks.count) 个网络"
        install(title: "选择 Wi-Fi", subtitle: countText, body: body, footer: manualButton(), size: NSSize(width: 332, height: 380))
        if let tableToFocus {
            let selectedRow = networks.firstIndex(where: { $0.ssid == currentSSID }) ?? 0
            tableToFocus.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            DispatchQueue.main.async { [weak self, weak tableToFocus] in
                self?.view.window?.makeFirstResponder(tableToFocus)
            }
        }
    }

    func showConnecting(to ssid: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let detail = secondaryLabel("正在等待 macOS 完成连接…")
        let body = centeredBody([spinner, detail])
        let close = NSButton(title: "返回网络面板", target: self, action: #selector(closePicker))
        close.bezelStyle = .rounded
        close.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, close])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        install(
            title: "正在连接“\(ssid)”",
            subtitle: "现有连接会保留到目标网络就绪",
            body: body,
            footer: footer,
            size: NSSize(width: 360, height: 250),
            showsRefresh: false
        )
    }

    func showConnectionError(ssid: String, password: String?, isSecure: Bool, message: String) {
        showCredentials(
            ssid: ssid,
            isSecure: isSecure,
            passwordValue: password ?? "",
            errorMessage: message
        )
    }

    private func showCredentials(
        ssid: String?,
        isSecure: Bool,
        passwordValue: String = "",
        errorMessage: String? = nil
    ) {
        credentialNetworkIsSecure = isSecure
        let name = NSTextField(string: ssid ?? "")
        name.placeholderString = "网络名称（SSID）"
        name.delegate = self
        name.heightAnchor.constraint(equalToConstant: 26).isActive = true
        nameField = name

        let password = NSSecureTextField(string: passwordValue)
        password.placeholderString = isSecure ? "留空以尝试已保存的密码" : "密码（开放网络可留空）"
        password.delegate = self
        password.heightAnchor.constraint(equalToConstant: 26).isActive = true
        passwordField = password

        let labels = ["网络名称", "密码"]
        let fields: [NSView] = [name, password]
        let form = NSGridView(views: zip(labels, fields).map { label, field in
            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.textColor = .secondaryLabelColor
            return [text, field]
        })
        form.rowSpacing = 8
        form.columnSpacing = 8
        form.column(at: 0).width = 62
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill

        let hint = wrappingLabel(errorMessage ?? (isSecure ? "已保存过此网络时，可直接留空密码连接。" : "请输入网络信息后连接。"))
        if errorMessage != nil { hint.textColor = .systemRed }
        let content = NSStackView(views: [form, hint])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10

        let back = NSButton(title: "返回列表", target: self, action: #selector(backToList))
        back.bezelStyle = .rounded
        back.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let connect = NSButton(title: errorMessage == nil ? "连接" : "重试连接", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        connect.controlSize = .small
        connect.keyEquivalent = "\r"
        connect.isEnabled = !(ssid ?? "").isEmpty
        connectButton = connect
        let footer = NSStackView(views: [back, spacer, connect])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        install(
            title: ssid.map { "连接“\($0)”" } ?? "连接其他网络",
            subtitle: isSecure ? "此网络需要密码" : "手动输入网络信息",
            body: content,
            footer: footer,
            size: NSSize(width: 360, height: 250),
            showsRefresh: false
        )
        let firstResponder = ssid == nil ? name : password
        DispatchQueue.main.async { [weak self, weak firstResponder] in
            self?.view.window?.makeKey()
            self?.view.window?.makeFirstResponder(firstResponder)
            if errorMessage != nil { firstResponder?.selectText(nil) }
        }
    }

    private func networkRow(_ network: WiFiNetwork, isCurrent: Bool) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 7
        card.borderWidth = 0.7
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.55)
        card.fillColor = isCurrent ? NSColor.systemGreen.withAlphaComponent(0.08) : NSColor.controlBackgroundColor.withAlphaComponent(0.32)

        let wifi = symbolView("wifi", color: signalColor(network.rssiValue), size: 17)
        let name = NSTextField(labelWithString: network.ssid)
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let security = network.isSecure ? "已加密" : "开放网络"
        let detail = secondaryLabel("\(network.signalDescription) · \(security)")
        detail.font = .systemFont(ofSize: 9.5)
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let state = NSTextField(labelWithString: isCurrent ? "当前" : "")
        state.font = .systemFont(ofSize: 10, weight: .medium)
        state.textColor = .systemGreen
        let lock = symbolView(network.isSecure ? "lock.fill" : "chevron.right", color: .tertiaryLabelColor, size: 10)
        let row = NSStackView(views: [wifi, labels, spacer, state, lock])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(row)

        let action = WiFiNetworkRowButton(title: "", target: self, action: #selector(selectNetwork(_:)))
        action.network = network
        action.isBordered = false
        action.focusRingType = .none
        action.isEnabled = !isCurrent
        action.setAccessibilityLabel(isCurrent ? "\(network.ssid)，当前已连接" : "连接 \(network.ssid)")
        action.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(action)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 44),
            wifi.widthAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: card.contentView!.centerYAnchor),
            action.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor),
            action.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            action.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor)
        ])
        return card
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableNetworks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableNetworks.indices.contains(row) else { return nil }
        let network = tableNetworks[row]
        return networkRow(network, isCurrent: network.ssid == currentSSID)
    }

    private func install(
        title: String,
        subtitle: String,
        body: NSView,
        footer: NSView,
        size: NSSize,
        showsRefresh: Bool = true
    ) {
        _ = view
        // Keep one stable panel geometry for every state. Resizing an already
        // visible menu-bar popover can leave its old viewport in place while
        // Auto Layout expands the content, clipping the header and shifting the
        // network rows outside the visible bounds.
        _ = size
        view.subviews.forEach { $0.removeFromSuperview() }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = secondaryLabel(subtitle)
        subtitleLabel.font = .systemFont(ofSize: 9.5)
        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var headerViews: [NSView] = [heading, spacer]
        if showsRefresh {
            let refresh = iconButton("arrow.clockwise", help: "重新扫描", action: #selector(refresh))
            headerViews.append(refresh)
        }
        headerViews.append(iconButton("chevron.backward", help: "返回网络面板", action: #selector(closePicker)))
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 5

        let divider = NSBox()
        divider.boxType = .separator
        for item in [header, divider, body, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
    }

    private func centeredBody(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])
        return container
    }

    private func manualButton() -> NSView {
        let button = NSButton(title: "其他网络…", target: self, action: #selector(manualNetwork))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [button, spacer])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        return footer
    }

    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = help
        return button
    }

    private func symbolView(_ symbol: String, color: NSColor, size: CGFloat) -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        return view
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 10.5)
        return label
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = secondaryLabel(text)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        label.preferredMaxLayoutWidth = 260
        return label
    }

    private func signalColor(_ rssi: Int) -> NSColor {
        if rssi >= -60 { return .systemGreen }
        if rssi >= -72 { return .systemOrange }
        return .secondaryLabelColor
    }

    @objc private func refresh() { onRefresh?() }
    @objc private func closePicker() { onDismiss?() }
    @objc private func openLocationSettings() { onOpenLocationSettings?() }
    @objc private func manualNetwork() {
        onSuspendScan?()
        showCredentials(ssid: nil, isSecure: false)
    }
    @objc private func backToList() { showNetworks(lastNetworks, currentSSID: currentSSID) }

    @objc private func selectNetwork(_ sender: WiFiNetworkRowButton) {
        guard let network = sender.network else { return }
        chooseNetwork(network)
    }

    private func chooseNetwork(_ network: WiFiNetwork) {
        guard network.ssid != currentSSID else { return }
        if network.isSecure {
            showCredentials(ssid: network.ssid, isSecure: true)
        } else {
            onConnect?(network.ssid, nil, false)
        }
    }

    @objc private func connect() {
        let ssid = nameField?.stringValue ?? ""
        guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let password = passwordField?.stringValue ?? ""
        onConnect?(
            ssid,
            password.isEmpty ? nil : password,
            credentialNetworkIsSecure || !password.isEmpty
        )
    }

    func controlTextDidChange(_ obj: Notification) {
        let ssid = nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        connectButton?.isEnabled = !ssid.isEmpty
    }
}

private final class WiFiNetworkRowButton: NSButton {
    var network: WiFiNetwork?
}

private final class WiFiNetworkTableView: NSTableView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class WiFiPickerBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}
