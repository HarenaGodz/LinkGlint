import AppKit
import Network
import ServiceManagement

/// Shared four-point-grid metrics for the menu-bar panel and main window.
private enum LinkGlintLayout {
    static let compactGap: CGFloat = 4
    static let standardGap: CGFloat = 8
    static let panelWidth: CGFloat = 388
    static let panelRowHeight: CGFloat = 46
    static let mainRowHeight: CGFloat = 52
    static let rowRadius: CGFloat = 8
    static let sectionRadius: CGFloat = 10
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private let manager = NetworkManager()
    private let profileStore = NetworkProfileStore()
    private let usageTracker = UsageTracker()
    private var preferences = AppPreferences()
    private var statusItem: NSStatusItem!
    private let statusPopover = NSPopover()
    private var statusContextMenu: NSMenu?
    private var statusPanelServicesSnapshot: [NetworkService]?
    private weak var statusPanelUsageLabel: NSTextField?
    private weak var statusPanelSummaryLabel: NSTextField?
    private weak var statusPanelTrafficRatesLabel: NSTextField?
    private weak var statusPanelTrafficChart: TrafficChartView?
    private weak var statusContextUsageItem: NSMenuItem?
    private weak var statusContextLoginItem: NSMenuItem?
    private var mainWindow: NSWindow!
    private var preferencesWindow: NSWindow?
    private var servicesStack: NSStackView!
    private var overviewLabel: NSTextField!
    private var diagnosticLabel: NSTextField!
    private var profilePopup: NSPopUpButton!
    private var usageLabel: NSTextField!
    private var loginItemCheckbox: NSButton!
    private var loginItemStatusLabel: NSTextField?
    private var accessBanner: NSBox!
    private var accessStatusLabel: NSTextField!
    private var accessDetailLabel: NSTextField!
    private var accessActionButton: NSButton!
    private var adapterSummaryLabel: NSTextField!
    private var accessCompactLabel: NSTextField!
    private var privilegePreferenceLabel: NSTextField?
    private var privilegePreferenceButton: NSButton?
    private var removePrivilegeButton: NSButton?
    private var refreshTimer: Timer?
    private var trafficTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "local.codex.LinkGlint.path-monitor")
    private var pendingPathRefresh: DispatchWorkItem?
    private var isRefreshing = false
    private var isPerformingPrivilegedChange = false
    private var isApplyingServiceSwitch = false
    private var networkStateGeneration = 0
    private var isSamplingTraffic = false
    private var isDiagnosing = false
    private var lastServices: [NetworkService] = []
    private var renderedWindowServices: [NetworkService]?
    private var lastDiagnostic: NetworkDiagnostic?
    private var previousTrafficCounters: [String: InterfaceCounters] = [:]
    private var previousTrafficSampleDate: Date?
    private var currentDownloadBytesPerSecond: Double = 0
    private var currentUploadBytesPerSecond: Double = 0
    private var trafficRateHistory = TrafficRateHistory(capacity: 60)
    private var lastMenuBarRenderKey: String?
    private var lastRenderedMenuBarPresentation: MenuBarTrafficPresentation?
    private var trafficLabels: [String: NSTextField] = [:]
    private var lastAutoDiagnosticAt: Date?
    private var hasLoadedNetworkState = false
    private var operationFeedback: (text: String, color: NSColor)?
    private var operationFeedbackReset: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createApplicationMenu()
        // Start as a menu-bar app. Showing a management window temporarily restores
        // the regular policy; closing the last window removes the Dock icon again.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Preserve the status-item placement chosen by users of NetBar 3.x.
        statusItem.autosaveName = "local.codex.NetBar.network-status"
        statusItem.isVisible = true
        statusItem.button?.image = menuBarImage(symbolName: "network", accessibilityDescription: "网络管理")
        // Keep a text label visible as well. This avoids an apparently "missing"
        // app when a system symbol is unavailable or hard to spot among many items.
        applyMenuBarAppearance()
        statusItem.button?.toolTip = "LinkGlint 网络管理"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleStatusPanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusPopover.behavior = .transient
        statusPopover.animates = true
        statusPopover.delegate = self

        createMainWindow()
        showLoadingMenu()
        if preferences.openWindowAtLaunch {
            showMainWindow()
        }
        performRefresh(showingErrors: false)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.performRefresh(showingErrors: false)
        }
        scheduleTrafficTimer()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.schedulePathRefresh()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        trafficTimer?.invalidate()
        pendingPathRefresh?.cancel()
        pathMonitor.cancel()
        usageTracker.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func createApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "LinkGlint")
        appMenuItem.submenu = appMenu

        let about = NSMenuItem(title: "关于 LinkGlint", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let preferencesItem = NSMenuItem(title: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 LinkGlint", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 LinkGlint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = mainMenu
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            showMenuBarRunningFeedback()
        }
        DispatchQueue.main.async { [weak self] in
            self?.hideDockIconIfNoWindowsAreVisible()
        }
    }

    private func hideDockIconIfNoWindowsAreVisible() {
        let hasVisibleWindow = mainWindow?.isVisible == true || preferencesWindow?.isVisible == true
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showMenuBarRunningFeedback() {
        // Keep the status-item width stable. Replacing its title with a long
        // confirmation caused nearby menu-bar items to jump every time the main
        // window closed; the preference screen already explains this behavior.
        statusItem.button?.toolTip = "LinkGlint 仍在菜单栏运行；从菜单选择“退出 LinkGlint”可完全结束"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.updateStatusIcon(self?.lastServices ?? [])
        }
    }

    private func showLoadingMenu() {
        let menu = NSMenu()
        let loading = NSMenuItem(title: "正在读取网络状态…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        menu.addItem(.separator())
        addFooter(to: menu)
        statusContextMenu = menu
        rebuildStatusPanel(with: [])
    }

    @objc private func refresh() {
        performRefresh(showingErrors: true)
    }

    private func performRefresh(showingErrors: Bool) {
        guard !isRefreshing, !isApplyingServiceSwitch, !isPerformingPrivilegedChange else { return }
        isRefreshing = true
        let generation = networkStateGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let services = try self.manager.fetchServices()
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    guard generation == self.networkStateGeneration else {
                        if !self.isApplyingServiceSwitch, !self.isPerformingPrivilegedChange {
                            self.performRefresh(showingErrors: showingErrors)
                        }
                        return
                    }
                    self.hasLoadedNetworkState = true
                    let servicesChanged = services != self.lastServices
                    self.lastServices = services
                    if servicesChanged {
                        self.rebuildMenu(with: services)
                        if self.mainWindow?.isVisible == true {
                            self.rebuildWindow(with: services)
                        }
                    } else {
                        // Most 12-second refreshes contain identical data. Avoid
                        // reconstructing every menu, card and Auto Layout tree.
                        self.updateStatusIcon(services)
                    }
                    self.sampleTraffic()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    if showingErrors {
                        self.showError(error)
                    } else {
                        self.setOperationFeedback("状态刷新失败，稍后重试", color: .systemOrange, clearAfter: 3)
                    }
                }
            }
        }
    }

    private func rebuildMenu(with services: [NetworkService]) {
        statusPanelServicesSnapshot = nil
        let menu = NSMenu()

        let connectedCount = services.filter(\.connected).count
        let primary = services.first(where: { $0.isPrimary && $0.connected })
        let summary = NSMenuItem(
            title: primary.map { "当前：\($0.name)" + ($0.ipAddress.map { " · \($0)" } ?? "") }
                ?? (connectedCount > 0 ? "已连接 \(connectedCount) 个网络" : "当前没有已连接网络"),
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        if services.isEmpty {
            let empty = NSMenuItem(title: "未发现网络服务", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for service in services {
                menu.addItem(serviceMenuItem(service, allServices: services))
            }
        }

        menu.addItem(.separator())
        addFooter(to: menu)
        statusContextMenu = menu
        if statusPopover.isShown {
            rebuildStatusPanel(with: services)
        }
        updateStatusIcon(services)
    }

    private func serviceMenuItem(_ service: NetworkService, allServices: [NetworkService]) -> NSMenuItem {
        let state = service.connected ? "●" : (service.enabled ? "○" : "—")
        let item = NSMenuItem(title: "\(state)  \(service.name)", action: nil, keyEquivalent: "")
        item.image = symbol(for: service)

        let submenu = NSMenu()
        let detailText: String
        if service.connected {
            detailText = "已连接" + (service.ipAddress.map { " · \($0)" } ?? "")
        } else if service.enabled {
            detailText = "已启用 · 未连接"
        } else {
            detailText = "已停用"
        }
        let detail = NSMenuItem(title: detailText, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        submenu.addItem(detail)

        if let port = service.hardwarePort, let device = service.device {
            let primaryText = service.isPrimary ? " · 默认出口" : ""
            let hardware = NSMenuItem(title: "\(port) · \(device) · 优先级 \(service.orderIndex + 1)\(primaryText)", action: nil, keyEquivalent: "")
            hardware.isEnabled = false
            submenu.addItem(hardware)
        }
        if let ssid = service.ssid {
            let wifi = NSMenuItem(title: "Wi-Fi：\(ssid)", action: nil, keyEquivalent: "")
            wifi.isEnabled = false
            submenu.addItem(wifi)
        }
        if let router = service.router {
            let route = NSMenuItem(title: "路由器：\(router)", action: nil, keyEquivalent: "")
            route.isEnabled = false
            submenu.addItem(route)
        }
        if !service.dnsServers.isEmpty {
            let dns = NSMenuItem(title: "DNS：\(service.dnsServers.joined(separator: ", "))", action: nil, keyEquivalent: "")
            dns.isEnabled = false
            submenu.addItem(dns)
        }
        submenu.addItem(.separator())

        let copyInfo = NSMenuItem(title: "复制网络信息", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
        copyInfo.target = self
        copyInfo.representedObject = service.copyableDetails
        submenu.addItem(copyInfo)

        let rename = NSMenuItem(title: "重命名网络服务…", action: #selector(renameNetworkService(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = service.name
        submenu.addItem(rename)

        if let ip = service.ipAddress {
            let copyIP = NSMenuItem(title: "复制 IP 地址", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
            copyIP.target = self
            copyIP.representedObject = ip
            submenu.addItem(copyIP)
        }

        let dnsSettings = NSMenuItem(title: "设置 DNS…", action: #selector(showDNSSettingsMenu(_:)), keyEquivalent: "")
        dnsSettings.target = self
        dnsSettings.representedObject = [
            "service": service.name,
            "servers": service.dnsServers
        ] as NSDictionary
        submenu.addItem(dnsSettings)

        if service.orderIndex > 0 {
            let priority = NSMenuItem(title: "设为最高优先级", action: #selector(setHighestPriorityMenu(_:)), keyEquivalent: "")
            priority.target = self
            priority.representedObject = [
                "service": service.name,
                "order": allServices.map(\.name)
            ] as NSDictionary
            submenu.addItem(priority)
        }
        submenu.addItem(.separator())

        let toggle = NSMenuItem(
            title: service.enabled ? "停用此网络服务" : "启用此网络服务",
            action: #selector(toggleService(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.representedObject = ["name": service.name, "enable": !service.enabled] as NSDictionary
        submenu.addItem(toggle)

        if service.kind == .wifi, let device = service.device, let powered = service.wifiPowered {
            let wifiToggle = NSMenuItem(
                title: powered ? "关闭 Wi-Fi 硬件" : "打开 Wi-Fi 硬件",
                action: #selector(toggleWiFiPower(_:)),
                keyEquivalent: ""
            )
            wifiToggle.target = self
            wifiToggle.representedObject = ["device": device, "enable": !powered] as NSDictionary
            submenu.addItem(wifiToggle)
        }

        if service.kind == .wifi || service.kind == .ethernet {
            let otherEnabledPhysicalServices = allServices.filter {
                $0.name != service.name && $0.enabled && ($0.kind == .wifi || $0.kind == .ethernet)
            }.map(\.name)

            if !otherEnabledPhysicalServices.isEmpty || !service.enabled {
                submenu.addItem(.separator())
                let switchItem = NSMenuItem(
                    title: "切换到此网络",
                    action: #selector(switchToService(_:)),
                    keyEquivalent: ""
                )
                switchItem.target = self
                switchItem.representedObject = [
                    "target": service.name,
                    "others": otherEnabledPhysicalServices,
                    "wifiDevice": service.kind == .wifi ? (service.device ?? "") : ""
                ] as NSDictionary
                submenu.addItem(switchItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func addFooter(to menu: NSMenu) {
        let profilesItem = NSMenuItem(title: "网络配置方案", action: nil, keyEquivalent: "")
        let profilesMenu = NSMenu()
        for (title, token) in [
            ("全部物理网络启用", "__all__"),
            ("仅 Wi-Fi", "__wifi__"),
            ("仅有线网络", "__ethernet__")
        ] {
            let item = NSMenuItem(title: title, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token
            profilesMenu.addItem(item)
        }
        if !profileStore.profiles.isEmpty {
            profilesMenu.addItem(.separator())
            for profile in profileStore.profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "profile:\(profile.id.uuidString)"
                profilesMenu.addItem(item)
            }
        }
        profilesItem.submenu = profilesMenu
        menu.addItem(profilesItem)

        if lastServices.count > 1 {
            let priority = NSMenuItem(title: "调整服务优先级…", action: #selector(showPriorityEditor), keyEquivalent: "")
            priority.target = self
            priority.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
            menu.addItem(priority)
        }

        menu.addItem(.separator())

        let today = usageTracker.usage()
        let usageItem = NSMenuItem(
            title: "今日记录：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))",
            action: nil,
            keyEquivalent: ""
        )
        usageItem.identifier = NSUserInterfaceItemIdentifier("daily-usage")
        usageItem.isEnabled = false
        statusContextUsageItem = usageItem
        let activityMenu = NSMenu()
        activityMenu.addItem(usageItem)

        let usageHistory = NSMenuItem(title: "查看用量历史…", action: #selector(showUsageHistory), keyEquivalent: "")
        usageHistory.target = self
        activityMenu.addItem(usageHistory)

        let resetUsage = NSMenuItem(title: "重置今日用量…", action: #selector(resetTodayUsage), keyEquivalent: "")
        resetUsage.target = self
        activityMenu.addItem(resetUsage)
        activityMenu.addItem(.separator())

        let diagnostic = NSMenuItem(title: "运行网络诊断", action: #selector(runDiagnostics), keyEquivalent: "d")
        diagnostic.target = self
        activityMenu.addItem(diagnostic)

        let copyReport = NSMenuItem(title: "复制诊断报告", action: #selector(copyDiagnosticReport), keyEquivalent: "")
        copyReport.target = self
        activityMenu.addItem(copyReport)

        let exportReport = NSMenuItem(title: "导出诊断报告…", action: #selector(exportDiagnosticReport), keyEquivalent: "")
        exportReport.target = self
        activityMenu.addItem(exportReport)

        let activityItem = NSMenuItem(title: "用量与诊断", action: nil, keyEquivalent: "")
        activityItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        activityItem.submenu = activityMenu
        menu.addItem(activityItem)

        let showWindow = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "1")
        showWindow.target = self
        menu.addItem(showWindow)

        let refreshItem = NSMenuItem(title: "刷新网络状态", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsMenu = NSMenu()

        let settings = NSMenuItem(title: "打开网络设置…", action: #selector(openNetworkSettings), keyEquivalent: ",")
        settings.target = self
        settingsMenu.addItem(settings)

        let accessReady = manager.privilegedAccessState == .ready
        let accessItem = NSMenuItem(
            title: accessReady ? "免密码网络切换：已启用" : "配置免密码网络切换…",
            action: #selector(showPrivilegedAccessSetup),
            keyEquivalent: ""
        )
        accessItem.target = self
        accessItem.state = accessReady ? NSControl.StateValue.on : NSControl.StateValue.off
        settingsMenu.addItem(accessItem)

        let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLoginMenu(_:)), keyEquivalent: "")
        loginItem.identifier = NSUserInterfaceItemIdentifier("launch-at-login")
        loginItem.target = self
        loginItem.state = loginItemState
        statusContextLoginItem = loginItem
        settingsMenu.addItem(loginItem)

        settingsMenu.addItem(.separator())

        let preferencesItem = NSMenuItem(title: "偏好设置…", action: #selector(showPreferences), keyEquivalent: "")
        preferencesItem.target = self
        settingsMenu.addItem(preferencesItem)

        let aboutItem = NSMenuItem(title: "关于 LinkGlint", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        settingsMenu.addItem(aboutItem)

        let settingsItem = NSMenuItem(title: "设置与帮助", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 LinkGlint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func updateStatusIcon(_ services: [NetworkService]) {
        let active = services.first(where: { $0.isPrimary && $0.connected })
            ?? services.first(where: \.connected)
        applyMenuBarAppearance()
        if let operationFeedback {
            statusItem.button?.toolTip = "LinkGlint · \(operationFeedback.text)"
            return
        }
        statusItem.button?.toolTip = active.map {
            var text = "LinkGlint · 已连接 · \($0.name)"
            if let ssid = $0.ssid { text += " · \(ssid)" }
            if let ip = $0.ipAddress { text += " · \(ip)" }
            return text
        } ?? "LinkGlint · 离线 · 当前无网络连接"
    }

    @objc private func toggleStatusPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusPopover.close()
            statusContextMenu?.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 3),
                in: button
            )
            return
        }
        if statusPopover.isShown {
            statusPopover.performClose(sender)
        } else {
            if statusPopover.contentViewController == nil || statusPanelServicesSnapshot != lastServices {
                rebuildStatusPanel(with: lastServices)
            }
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            updateUsageDisplay()
        }
    }

    private func rebuildStatusPanel(with services: [NetworkService]) {
        statusPanelServicesSnapshot = services
        let width = LinkGlintLayout.panelWidth
        let visibleRows = min(max(services.count, 1), 5)
        let rowViewportHeight = CGFloat(visibleRows) * LinkGlintLayout.panelRowHeight
            + CGFloat(max(visibleRows - 1, 0)) * LinkGlintLayout.compactGap
        let permissionHeight: CGFloat = manager.privilegedAccessState == .ready ? 0 : 30
        let height: CGFloat = 214 + permissionHeight + rowViewportHeight
        let controller = NSViewController()
        // NSPopover already supplies the window shape and shadow. A second
        // vibrancy layer here used to blend strongly with colorful wallpapers,
        // making the panel look tinted or uneven. Use an opaque dynamic system
        // background instead so text and controls remain consistent everywhere.
        let root = StatusPanelBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        controller.view = root

        let refreshButton = compactIconButton(symbol: "arrow.clockwise", label: "刷新", action: #selector(refresh))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let brandTitle = NSTextField(labelWithString: "LinkGlint")
        brandTitle.font = .systemFont(ofSize: 13.5, weight: .bold)
        brandTitle.alignment = .center
        brandTitle.translatesAutoresizingMaskIntoConstraints = false
        let brandDivider = NSBox()
        brandDivider.boxType = .separator
        brandDivider.translatesAutoresizingMaskIntoConstraints = false
        let brandHeader = NSView()
        brandHeader.translatesAutoresizingMaskIntoConstraints = false
        brandHeader.addSubview(brandTitle)
        brandHeader.addSubview(brandDivider)
        brandHeader.addSubview(refreshButton)
        NSLayoutConstraint.activate([
            brandTitle.centerXAnchor.constraint(equalTo: brandHeader.centerXAnchor),
            brandTitle.topAnchor.constraint(equalTo: brandHeader.topAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: brandTitle.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: brandHeader.trailingAnchor),
            brandDivider.leadingAnchor.constraint(equalTo: brandHeader.leadingAnchor),
            brandDivider.trailingAnchor.constraint(equalTo: brandHeader.trailingAnchor),
            brandDivider.bottomAnchor.constraint(equalTo: brandHeader.bottomAnchor),
            brandHeader.heightAnchor.constraint(equalToConstant: 22)
        ])

        let sectionLabel = NSTextField(labelWithString: "网络服务")
        sectionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor
        let sectionCount = NSTextField(labelWithString: "\(services.filter(\.connected).count) 个已连接 · \(services.filter(\.enabled).count) 个已启用")
        sectionCount.font = .systemFont(ofSize: 10)
        sectionCount.textColor = .secondaryLabelColor
        sectionCount.alignment = .right
        statusPanelSummaryLabel = sectionCount
        let sectionSpacer = NSView()
        sectionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sectionHeader = NSStackView(views: [sectionLabel, sectionSpacer, sectionCount])
        sectionHeader.orientation = .horizontal
        sectionHeader.alignment = .centerY

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = LinkGlintLayout.compactGap
        rows.translatesAutoresizingMaskIntoConstraints = false
        if services.isEmpty {
            let empty = NSTextField(labelWithString: hasLoadedNetworkState ? "未发现网络服务" : "正在读取网络状态…")
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            rows.addArrangedSubview(empty)
        } else {
            for service in services.sorted(by: statusPanelServiceOrder) {
                rows.addArrangedSubview(statusPanelServiceRow(service, allServices: services))
            }
        }

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = services.count > 5
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let trafficChart = statusPanelTrafficChartCard()
        let footer = statusPanelFooter(services: services)
        let stack = NSStackView(views: [brandHeader, sectionHeader, scroll, trafficChart, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: rowViewportHeight)
        ])
        statusPopover.contentViewController = controller
        statusPopover.contentSize = NSSize(width: width, height: height)
        updateOperationFeedbackDisplays()
    }

    private func statusPanelTrafficChartCard() -> NSView {
        let title = NSTextField(labelWithString: "实时流量")
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let range = NSTextField(labelWithString: "最近 60 次")
        range.font = .systemFont(ofSize: 9.5)
        range.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let rates = NSTextField(labelWithAttributedString: statusPanelTrafficRateText)
        rates.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        rates.alignment = .right
        rates.lineBreakMode = .byClipping
        rates.textColor = .secondaryLabelColor
        rates.translatesAutoresizingMaskIntoConstraints = false
        rates.widthAnchor.constraint(equalToConstant: 180).isActive = true
        rates.toolTip = "蓝色为下载，橙色为上传"
        statusPanelTrafficRatesLabel = rates

        let header = NSStackView(views: [title, range, spacer, rates])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = LinkGlintLayout.compactGap

        let chart = TrafficChartView()
        chart.samples = trafficRateHistory.samples
        chart.translatesAutoresizingMaskIntoConstraints = false
        statusPanelTrafficChart = chart

        let content = NSStackView(views: [header, chart])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 2
        content.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 5, right: 8)
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = LinkGlintLayout.rowRadius
        card.borderWidth = 1
        card.borderColor = NSColor.separatorColor.withAlphaComponent(0.28)
        card.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.20)
        card.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 80),
            content.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor),
            chart.heightAnchor.constraint(equalToConstant: 46)
        ])
        return card
    }

    private var statusPanelTrafficRateText: NSAttributedString {
        let download = "● ↓ \(formatRate(currentDownloadBytesPerSecond))"
        let upload = "● ↑ \(formatRate(currentUploadBytesPerSecond))"
        let result = NSMutableAttributedString(
            string: "\(download)   \(upload)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        result.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(location: 0, length: 1))
        result.addAttribute(
            .foregroundColor,
            value: NSColor.systemOrange,
            range: NSRange(location: download.utf16.count + 3, length: 1)
        )
        return result
    }

    private func statusPanelServiceRow(_ service: NetworkService, allServices: [NetworkService]) -> NSView {
        let icon = NSImageView()
        icon.image = symbol(for: service)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = service.connected ? statusColor(for: service.kind) : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let visibleName = service.kind == .wifi && service.connected ? (service.ssid ?? service.name) : service.name
        let name = NSTextField(labelWithString: visibleName)
        name.font = .systemFont(ofSize: 12, weight: service.connected ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = visibleName
        var details = ["优先级 \(service.orderIndex + 1)", networkKindName(service.kind), service.connected ? "已连接" : (service.enabled ? "可用" : "已停用")]
        if visibleName != service.name { details.append(service.name) }
        if let ip = service.ipAddress { details.append(ip) }
        let detail = NSTextField(labelWithString: details.joined(separator: " · "))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = detail.stringValue
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [icon, labels, spacer]
        if service.isPrimary && service.connected {
            views.append(statusPanelBadge("当前", color: statusColor(for: service.kind)))
        }
        if (service.kind == .wifi || service.kind == .ethernet) && !service.isPrimary {
            let others = allServices.filter {
                $0.name != service.name && $0.enabled && ($0.kind == .wifi || $0.kind == .ethernet)
            }.map(\.name)
            let use = NetworkActionButton(title: "切换", target: self, action: #selector(windowSwitchToService(_:)))
            use.bezelStyle = .rounded
            use.controlSize = .small
            use.payload = ["target": service.name, "others": others, "wifiDevice": service.kind == .wifi ? (service.device ?? "") : ""]
            views.append(use)
        }
        let enabledSwitch = NetworkToggleSwitch()
        enabledSwitch.target = self
        enabledSwitch.action = #selector(windowToggleServiceSwitch(_:))
        enabledSwitch.state = service.enabled ? .on : .off
        enabledSwitch.controlSize = .small
        enabledSwitch.payload = ["name": service.name]
        enabledSwitch.toolTip = service.enabled ? "停用 \(service.name)" : "启用 \(service.name)"
        enabledSwitch.setAccessibilityLabel("启用 \(service.name)")
        views.append(enabledSwitch)
        views.append(serviceActionsButton(service, allServices: allServices))
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = LinkGlintLayout.rowRadius
        card.borderWidth = service.connected ? 1 : 0
        let accent = statusColor(for: service.kind)
        card.borderColor = service.connected
            ? accent.withAlphaComponent(0.25)
            : .clear
        card.fillColor = service.connected
            ? accent.withAlphaComponent(0.055)
            : NSColor.controlBackgroundColor.withAlphaComponent(service.enabled ? 0.22 : 0.10)
        card.contentView?.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: LinkGlintLayout.panelRowHeight),
            icon.widthAnchor.constraint(equalToConstant: 21),
            icon.heightAnchor.constraint(equalToConstant: 21),
            row.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -1),
            row.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -4)
        ])
        return card
    }

    private func statusPanelFooter(services: [NetworkService]) -> NSView {
        let usage = usageTracker.usage()
        let usageText = NSTextField(labelWithString: "今日记录 ↓ \(formatBytes(usage.receivedBytes))  ↑ \(formatBytes(usage.sentBytes))")
        statusPanelUsageLabel = usageText
        usageText.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        usageText.textColor = .secondaryLabelColor
        let usageSpacer = NSView()
        usageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let menuHint = NSTextField(labelWithString: "右键查看更多")
        menuHint.font = .systemFont(ofSize: 10)
        menuHint.textColor = .secondaryLabelColor
        let usageRow = NSStackView(views: [usageText, usageSpacer, menuHint])
        usageRow.orientation = .horizontal
        usageRow.alignment = .centerY

        var views: [NSView] = [statusPanelProfileButton()]
        if services.count > 1 {
            let priority = compactIconButton(symbol: "arrow.up.arrow.down", label: "调整服务优先级", action: #selector(showPriorityEditor))
            views.append(priority)
        }
        if let wifiDevice = services.first(where: { $0.kind == .wifi })?.device {
            let join = NetworkActionButton(title: "加入 Wi‑Fi…", target: self, action: #selector(showJoinWiFi(_:)))
            join.bezelStyle = .rounded
            join.controlSize = .small
            join.payload = ["device": wifiDevice]
            views.append(join)
        }
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(actionSpacer)
        let settings = compactIconButton(symbol: "gearshape", label: "网络设置", action: #selector(openNetworkSettingsFromPanel))
        views.append(settings)
        let main = compactIconButton(symbol: "macwindow", label: "全部详情", action: #selector(showMainWindowFromPanel))
        views.append(main)
        let actions = NSStackView(views: views)
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = LinkGlintLayout.compactGap

        var footerViews: [NSView] = []
        if manager.privilegedAccessState != .ready {
            let permission = NSTextField(labelWithString: "部分操作需要更新网络权限")
            permission.font = .systemFont(ofSize: 10.5, weight: .medium)
            permission.textColor = .systemOrange
            let permissionSpacer = NSView()
            permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let repair = NSButton(title: "修复…", target: self, action: #selector(showPrivilegedAccessSetup))
            repair.bezelStyle = .rounded
            repair.controlSize = .small
            let permissionRow = NSStackView(views: [permission, permissionSpacer, repair])
            permissionRow.orientation = .horizontal
            permissionRow.alignment = .centerY
            footerViews.append(permissionRow)
        }
        footerViews += [usageRow, actions]
        let footer = NSStackView(views: footerViews)
        footer.orientation = .vertical
        footer.alignment = .width
        footer.spacing = LinkGlintLayout.compactGap
        return footer
    }

    private func statusPanelProfileButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        button.bezelStyle = .rounded
        button.controlSize = .small
        let menu = button.menu!
        menu.removeAllItems()
        let title = NSMenuItem(title: "快速方案", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        menu.addItem(title)
        for (label, token) in [
            ("全部物理网络启用", "__all__"),
            ("仅 Wi-Fi", "__wifi__"),
            ("仅有线网络", "__ethernet__")
        ] {
            let item = NSMenuItem(title: label, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = token
            menu.addItem(item)
        }
        if !profileStore.profiles.isEmpty {
            menu.addItem(.separator())
            for profile in profileStore.profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "profile:\(profile.id.uuidString)"
                menu.addItem(item)
            }
        }
        return button
    }

    private func statusPanelBadge(_ title: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 7
        box.borderWidth = 1
        box.borderColor = color.withAlphaComponent(0.28)
        box.fillColor = color.withAlphaComponent(0.09)
        box.contentView?.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -2)
        ])
        return box
    }

    private func statusPanelServiceOrder(_ lhs: NetworkService, _ rhs: NetworkService) -> Bool {
        lhs.orderIndex < rhs.orderIndex
    }

    @objc private func openNetworkSettingsFromPanel() {
        statusPopover.close()
        openNetworkSettings()
    }

    @objc private func showMainWindowFromPanel() {
        statusPopover.close()
        showMainWindow()
    }

    private func networkKindName(_ kind: NetworkService.Kind) -> String {
        switch kind {
        case .wifi: return "无线"
        case .ethernet: return "有线"
        case .vpn: return "VPN"
        case .other: return "其他"
        }
    }

    private func statusColor(for kind: NetworkService.Kind) -> NSColor {
        switch kind {
        case .wifi: return .systemBlue
        case .ethernet: return .systemTeal
        case .vpn: return .systemPurple
        case .other: return .systemGray
        }
    }

    private func schedulePathRefresh() {
        pendingPathRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performRefresh(showingErrors: false)
            if self.preferences.autoRunDiagnostics,
               self.lastAutoDiagnosticAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                self.lastAutoDiagnosticAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.runDiagnostics()
                }
            }
        }
        pendingPathRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    @objc private func sampleTraffic() {
        guard !isSamplingTraffic else { return }
        isSamplingTraffic = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let counters = try? self.manager.fetchTrafficCounters()
            let sampleDate = Date()
            DispatchQueue.main.async {
                self.isSamplingTraffic = false
                guard let counters else { return }
                if let previousDate = self.previousTrafficSampleDate {
                    let interval = max(sampleDate.timeIntervalSince(previousDate), 0.1)
                    let sample = TrafficSampleCalculator.calculate(
                        previous: self.previousTrafficCounters,
                        current: counters,
                        services: self.lastServices
                    )
                    for (device, delta) in sample.deltasByDevice {
                        if self.mainWindow?.isVisible == true, let label = self.trafficLabels[device] {
                            label.stringValue = "↓ \(self.formatRate(Double(delta.receivedBytes) / interval))   ↑ \(self.formatRate(Double(delta.sentBytes) / interval))"
                        }
                    }
                    self.usageTracker.record(
                        receivedBytes: sample.receivedBytes,
                        sentBytes: sample.sentBytes,
                        at: sampleDate
                    )
                    self.currentDownloadBytesPerSecond = Double(sample.receivedBytes) / interval
                    self.currentUploadBytesPerSecond = Double(sample.sentBytes) / interval
                    self.trafficRateHistory.append(
                        downloadBytesPerSecond: self.currentDownloadBytesPerSecond,
                        uploadBytesPerSecond: self.currentUploadBytesPerSecond,
                        at: sampleDate
                    )
                    self.statusPanelTrafficRatesLabel?.attributedStringValue = self.statusPanelTrafficRateText
                    self.statusPanelTrafficChart?.samples = self.trafficRateHistory.samples
                    self.updateUsageDisplay()
                    self.applyMenuBarAppearance()
                }
                self.previousTrafficCounters = counters
                self.previousTrafficSampleDate = sampleDate
            }
        }
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        TrafficRateFormatter.string(bytesPerSecond: bytesPerSecond, usesBits: false)
    }

    private func scheduleTrafficTimer() {
        trafficTimer?.invalidate()
        trafficTimer = Timer.scheduledTimer(withTimeInterval: preferences.trafficRefreshInterval, repeats: true) { [weak self] _ in
            self?.sampleTraffic()
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(bytes) B"
    }

    private func applyMenuBarAppearance() {
        guard let button = statusItem?.button else { return }
        let showsText = preferences.showMenuBarTitle || preferences.showMenuBarSpeed
        let networkPresentation = NetworkStatusPresentation.make(services: lastServices, hasLoaded: hasLoadedNetworkState)
        let latestPresentation = MenuBarTrafficPresentation.make(
            networkTitle: networkPresentation.title,
            downloadBytesPerSecond: currentDownloadBytesPerSecond,
            uploadBytesPerSecond: currentUploadBytesPerSecond,
            showsNetworkTitle: preferences.showMenuBarTitle,
            showsSpeed: preferences.showMenuBarSpeed,
            usesTwoLines: preferences.menuBarSpeedTwoLines,
            usesBits: preferences.menuBarSpeedInBits
        )
        // While the panel is open, freeze only the text geometry so its anchor
        // cannot move. The network symbol can still change immediately.
        let renderState = MenuBarRenderPolicy.make(
            latestSymbolName: networkPresentation.symbolName,
            latestPresentation: latestPresentation,
            renderedPresentation: lastRenderedMenuBarPresentation,
            panelIsOpen: statusPopover.isShown
        )
        let presentation = renderState.presentation
        let indicatorStyle = preferences.menuBarTrafficIndicatorStyle
        let appearanceName = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let renderKey = "\(renderState.symbolName)|\(presentation.usesTwoLines)|\(indicatorStyle.rawValue)|\(appearanceName)|\(presentation.text)"
        guard renderKey != lastMenuBarRenderKey else { return }
        lastMenuBarRenderKey = renderKey
        lastRenderedMenuBarPresentation = presentation
        if presentation.usesTwoLines {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = twoLineMenuBarImage(
                symbolName: renderState.symbolName,
                text: presentation.text,
                indicatorStyle: indicatorStyle,
                appearance: button.effectiveAppearance
            )
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            statusItem.length = ceil(button.image?.size.width ?? NSStatusItem.squareLength) + 8
        } else {
            let title = menuBarAttributedTitle(presentation.text, indicatorStyle: indicatorStyle)
            button.attributedTitle = title
            button.image = menuBarImage(
                symbolName: renderState.symbolName,
                accessibilityDescription: networkPresentation.title
            )
            button.imagePosition = showsText ? .imageLeading : .imageOnly
            button.imageScaling = .scaleProportionallyDown
            if showsText {
                statusItem.length = NSStatusItem.variableLength
            } else {
                statusItem.length = NSStatusItem.squareLength
            }
        }
        button.setAccessibilityLabel("LinkGlint · \(menuBarStatusTitle) · 下载 \(formatRate(currentDownloadBytesPerSecond)) · 上传 \(formatRate(currentUploadBytesPerSecond))")
    }

    private func twoLineMenuBarImage(
        symbolName: String,
        text: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle,
        appearance: NSAppearance
    ) -> NSImage? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 2 else {
            return menuBarImage(symbolName: symbolName, accessibilityDescription: text)
        }

        let topFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let foregroundColor = indicatorStyle.usesColor ? NSColor.labelColor : NSColor.black
        let topAttributes: [NSAttributedString.Key: Any] = [
            .font: topFont,
            .foregroundColor: foregroundColor
        ]
        let bottomAttributes: [NSAttributedString.Key: Any] = [
            .font: bottomFont,
            .foregroundColor: foregroundColor
        ]
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
        let unitSamples = representativeRate?.unit.hasSuffix("bps") == true
            ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
            : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let valueSamples = ["0", "9.9", "10", "999"].flatMap { number in
            unitSamples.map { "\(number) \($0)" }
        }
        let valueWidth = valueSamples.map {
            ceil(($0 as NSString).size(withAttributes: bottomAttributes).width)
        }.max() ?? 0
        let rateGeometry = MenuBarRatePairGeometry(
            markerWidth: 8,
            valueWidth: valueWidth,
            markerValueGap: 1,
            groupGap: 3
        )
        let geometry: MenuBarTwoLineGeometry
        if combinedRates != nil {
            geometry = .make(topWidth: topWidth, bottomWidth: rateGeometry.totalWidth)
        } else if speedOnlyRates != nil {
            geometry = .make(topWidth: rateGeometry.groupWidth, bottomWidth: rateGeometry.groupWidth)
        } else {
            let bottomWidth = ceil((lines[1] as NSString).size(withAttributes: bottomAttributes).width)
            geometry = .make(topWidth: topWidth, bottomWidth: bottomWidth)
        }
        let iconBoxSize = NSSize(width: 18, height: 16)
        let textSpacing: CGFloat = 4
        let textWidth = geometry.textWidth
        let imageSize = NSSize(width: iconBoxSize.width + textSpacing + textWidth, height: 20)

        let image = NSImage(size: imageSize, flipped: false) { rect in
            var rendered = false
            appearance.performAsCurrentDrawingAppearance {
                if let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                    let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                    let configuration: NSImage.SymbolConfiguration
                    if indicatorStyle.usesColor {
                        configuration = pointConfiguration.applying(
                            NSImage.SymbolConfiguration(paletteColors: [foregroundColor])
                        )
                    } else {
                        configuration = pointConfiguration
                    }
                    if let symbol = baseSymbol.withSymbolConfiguration(configuration) {
                        let fittedSize = MenuBarIconLayout.fittedSize(source: symbol.size, bounding: iconBoxSize)
                        symbol.draw(
                            in: NSRect(
                                x: (iconBoxSize.width - fittedSize.width) / 2,
                                y: (rect.height - fittedSize.height) / 2,
                                width: fittedSize.width,
                                height: fittedSize.height
                            ),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1
                        )
                    }
                }

                let downloadColor = NSColor(srgbRed: 0.20, green: 0.64, blue: 0.96, alpha: 1)
                let uploadColor = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.18, alpha: 1)
                let textX = iconBoxSize.width + textSpacing

                func drawMarker(_ direction: String, x: CGFloat, y: CGFloat) {
                    let markerRect = NSRect(x: x, y: y, width: rateGeometry.markerWidth, height: 10.2)
                    switch indicatorStyle {
                    case .arrows:
                        (direction as NSString).draw(in: markerRect, withAttributes: centeredMarkerAttributes)
                    case .coloredDots:
                        (direction == "↓" ? downloadColor : uploadColor).setFill()
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
                        let color = direction == "↓" ? downloadColor : uploadColor
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
                    let value = "\(rate.number) \(rate.unit)"
                    (value as NSString).draw(
                        in: NSRect(
                            x: x + rateGeometry.valueX,
                            y: y,
                            width: rateGeometry.valueWidth,
                            height: 10.2
                        ),
                        withAttributes: bottomAttributes
                    )
                }

                if let rates = combinedRates {
                    (lines[0] as NSString).draw(
                        in: NSRect(x: textX, y: 9.7, width: topWidth, height: 10.3),
                        withAttributes: topAttributes
                    )
                    drawRateGroup(rates.0, x: textX, y: -0.1)
                    drawRateGroup(rates.1, x: textX + rateGeometry.uploadX, y: -0.1)
                } else if let rates = speedOnlyRates {
                    drawRateGroup(rates.0, x: textX, y: 9.7)
                    drawRateGroup(rates.1, x: textX, y: -0.1)
                } else {
                    (lines[0] as NSString).draw(
                        in: NSRect(x: textX, y: 9.7, width: topWidth, height: 10.3),
                        withAttributes: topAttributes
                    )
                    (lines[1] as NSString).draw(
                        in: NSRect(x: textX, y: -0.1, width: textWidth, height: 10.2),
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

    private func menuBarAttributedTitle(
        _ text: String,
        indicatorStyle: MenuBarTrafficIndicatorStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        let downloadColor = NSColor(srgbRed: 0.20, green: 0.64, blue: 0.96, alpha: 1)
        let uploadColor = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.18, alpha: 1)
        let replacements: [(source: String, marker: String, color: NSColor)]
        switch indicatorStyle {
        case .arrows:
            replacements = [("↓", "↓", downloadColor), ("↑", "↑", uploadColor)]
        case .coloredDots:
            replacements = [("↓", "●", downloadColor), ("↑", "●", uploadColor)]
        case .coloredTriangles:
            replacements = [("↓", "▼", downloadColor), ("↑", "▲", uploadColor)]
        }
        var coloredMarkerRanges: [(range: NSRange, color: NSColor)] = []
        for replacement in replacements {
            var searchLocation = 0
            while searchLocation < result.length {
                let searchRange = NSRange(location: searchLocation, length: result.length - searchLocation)
                let found = (result.string as NSString).range(of: replacement.source, options: [], range: searchRange)
                guard found.location != NSNotFound else { break }
                if replacement.marker != replacement.source {
                    result.replaceCharacters(in: found, with: replacement.marker)
                }
                if indicatorStyle.usesColor {
                    result.addAttribute(.foregroundColor, value: replacement.color, range: found)
                    coloredMarkerRanges.append((found, replacement.color))
                }
                searchLocation = found.location + found.length
            }
        }
        let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let expression = try? NSRegularExpression(pattern: "[↓↑●▼▲][^↓↑●▼▲]+")
        let range = NSRange(location: 0, length: result.length)
        expression?.enumerateMatches(in: result.string, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.font, value: speedFont, range: match.range)
        }
        if indicatorStyle.usesColor {
            let markerSize: CGFloat = indicatorStyle == .coloredDots ? 8.5 : 7.5
            let markerFont = NSFont.systemFont(ofSize: markerSize, weight: .bold)
            for marker in coloredMarkerRanges {
                result.addAttributes([
                    .font: markerFont,
                    .foregroundColor: marker.color,
                    .kern: 1.0,
                    .baselineOffset: 0.25
                ], range: marker.range)
            }
        }
        return result
    }

    func popoverDidClose(_ notification: Notification) {
        lastMenuBarRenderKey = nil
        lastRenderedMenuBarPresentation = nil
        applyMenuBarAppearance()
    }

    private func menuBarImage(symbolName: String, accessibilityDescription: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        // Template rendering automatically follows light/dark menu-bar appearance
        // and the highlighted state while the menu is open.
        image?.isTemplate = true
        return image
    }

    private var menuBarStatusTitle: String {
        NetworkStatusPresentation.make(services: lastServices, hasLoaded: hasLoadedNetworkState).title
    }

    private func symbol(for service: NetworkService) -> NSImage? {
        let name: String
        switch service.kind {
        case .wifi: name = service.enabled ? "wifi" : "wifi.slash"
        case .ethernet: name = "cable.connector"
        case .vpn: name = "lock.shield"
        case .other: name = "network"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: service.name)
        image?.isTemplate = true
        return image
    }

    @objc private func toggleService(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let name = data["name"] as? String,
              let enable = data["enable"] as? Bool else { return }
        guard enable || confirmDisablingActiveService(named: name) else { return }

        let optimistic = NetworkServiceTransition.settingEnabled(
            services: lastServices,
            named: name,
            enabled: enable
        )
        performPrivilegedChange(
            description: enable ? "启用 \(name)" : "停用 \(name)",
            optimisticServices: optimistic
        ) { [manager] in
            try manager.setService(name, enabled: enable)
        }
    }

    @objc private func toggleWiFiPower(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let device = data["device"] as? String,
              let enable = data["enable"] as? Bool else { return }
        guard enable || confirmPoweringOffActiveWiFi(device: device) else { return }

        performPrivilegedChange(description: enable ? "打开 Wi-Fi" : "关闭 Wi-Fi") { [manager] in
            try manager.setWiFiPower(device: device, enabled: enable)
        }
    }

    @objc private func switchToService(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let target = data["target"] as? String,
              let others = data["others"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }

        performServiceSwitch(
            target: target,
            otherServices: others,
            wifiDevice: wifiDeviceValue.isEmpty ? nil : wifiDeviceValue
        )
    }

    @objc private func showDNSSettingsMenu(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let service = data["service"] as? String,
              let servers = data["servers"] as? [String] else { return }
        showDNSSettings(service: service, currentServers: servers)
    }

    @objc private func setHighestPriorityMenu(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let service = data["service"] as? String,
              let order = data["order"] as? [String] else { return }
        setHighestPriority(service: service, currentOrder: order)
    }

    private func showDNSSettings(service: String, currentServers: [String]) {
        let alert = NSAlert()
        alert.messageText = "DNS 设置：\(service)"
        alert.informativeText = "输入一个或多个 IPv4/IPv6 地址，用逗号或空格分隔。留空即可恢复由 DHCP 或系统自动获取。"
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        input.placeholderString = "留空 = 自动，例如 1.1.1.1, 8.8.8.8"
        input.stringValue = currentServers.joined(separator: ", ")
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let servers = try manager.normalizedDNSServers(input.stringValue)
            performPrivilegedChange(description: servers.isEmpty ? "恢复自动 DNS：\(service)" : "更新 DNS：\(service)") { [manager] in
                try manager.setDNSServers(service: service, servers: servers)
            }
        } catch {
            showError(error)
        }
    }

    @objc private func showJoinWiFi(_ sender: NetworkActionButton) {
        guard let device = sender.payload?["device"] as? String else { return }
        let alert = NSAlert()
        alert.messageText = "连接其他 Wi‑Fi"
        alert.informativeText = "输入无线网络名称；开放网络可将密码留空。"
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        let networkName = NSTextField(string: "")
        networkName.placeholderString = "网络名称（SSID）"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "密码（可留空）"
        let fields = NSStackView(views: [networkName, password])
        fields.orientation = .vertical
        fields.alignment = .width
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 60)
        alert.accessoryView = fields
        statusPopover.close()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ssid = networkName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            showError(NetworkError.commandFailed("请输入无线网络名称。"))
            return
        }
        performPrivilegedChange(description: "连接 Wi‑Fi：\(ssid)") { [manager] in
            try manager.joinWiFi(device: device, networkName: ssid, password: password.stringValue)
        }
    }

    @objc private func renameNetworkService(_ sender: NSMenuItem) {
        guard let oldName = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "重命名网络服务"
        alert.informativeText = "名称会显示在 LinkGlint 与 macOS 网络设置中。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: oldName)
        input.frame = NSRect(x: 0, y: 0, width: 340, height: 26)
        input.selectText(nil)
        alert.accessoryView = input
        statusPopover.close()
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        performPrivilegedChange(description: "重命名 \(oldName)") { [manager] in
            try manager.renameService(oldName, to: newName)
        }
    }

    private func setHighestPriority(service: String, currentOrder: [String]) {
        performPrivilegedChange(description: "提高优先级：\(service)") { [manager] in
            try manager.setHighestPriority(service: service, currentOrder: currentOrder)
        }
    }

    @objc private func showPriorityEditor() {
        guard lastServices.count > 1 else {
            showError(NetworkError.commandFailed("至少需要两个网络服务才能调整优先级。"))
            return
        }
        let currentOrder = lastServices.sorted { $0.orderIndex < $1.orderIndex }.map(\.name)
        let editor = PriorityOrderEditorController(services: lastServices)
        _ = editor.view

        let alert = NSAlert()
        alert.messageText = "调整网络服务优先级"
        alert.informativeText = "macOS 会优先尝试列表靠前的服务。拖动完成后点击“应用顺序”。"
        alert.addButton(withTitle: "应用顺序")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = editor.view
        statusPopover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newOrder = editor.orderedServiceNames
        guard newOrder != currentOrder else { return }
        performPrivilegedChange(description: "更新网络服务优先级") { [manager] in
            try manager.setServiceOrder(newOrder)
        }
    }

    private func updateOperationFeedbackDisplays() {
        if let operationFeedback {
            statusPanelSummaryLabel?.stringValue = operationFeedback.text
            statusPanelSummaryLabel?.textColor = operationFeedback.color
            adapterSummaryLabel?.stringValue = operationFeedback.text
            adapterSummaryLabel?.textColor = operationFeedback.color
            updateNetworkControlAvailability()
            return
        }

        let connectedCount = lastServices.filter(\.connected).count
        let enabledCount = lastServices.filter(\.enabled).count
        statusPanelSummaryLabel?.stringValue = "\(connectedCount) 个已连接 · \(enabledCount) 个已启用"
        statusPanelSummaryLabel?.textColor = .secondaryLabelColor
        adapterSummaryLabel?.stringValue = "\(lastServices.count) 个服务 · \(connectedCount) 个已连接 · \(enabledCount) 个已启用"
        adapterSummaryLabel?.textColor = .secondaryLabelColor
        updateNetworkControlAvailability()
    }

    private func updateNetworkControlAvailability() {
        let enabled = !isPerformingPrivilegedChange && !isApplyingServiceSwitch
        setNetworkControlAvailability(in: mainWindow?.contentView, enabled: enabled)
        setNetworkControlAvailability(in: statusPopover.contentViewController?.view, enabled: enabled)
    }

    private func setNetworkControlAvailability(in view: NSView?, enabled: Bool) {
        guard let view else { return }
        if let control = view as? NSControl,
           control is NetworkToggleSwitch
            || control is NetworkActionButton
            || control.identifier?.rawValue == "network-operation-control" {
            control.isEnabled = enabled
        }
        for subview in view.subviews {
            setNetworkControlAvailability(in: subview, enabled: enabled)
        }
    }

    private func setOperationFeedback(_ text: String, color: NSColor, clearAfter delay: TimeInterval? = nil) {
        operationFeedbackReset?.cancel()
        operationFeedback = (text, color)
        updateOperationFeedbackDisplays()
        statusItem.button?.toolTip = "LinkGlint · \(text)"

        guard let delay else { return }
        let expectedText = text
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.operationFeedback?.text == expectedText else { return }
            self.operationFeedback = nil
            self.updateOperationFeedbackDisplays()
            self.updateStatusIcon(self.lastServices)
        }
        operationFeedbackReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearOperationFeedback() {
        operationFeedbackReset?.cancel()
        operationFeedback = nil
        updateOperationFeedbackDisplays()
        updateStatusIcon(lastServices)
    }

    private func confirmDisablingActiveService(named name: String) -> Bool {
        guard let service = lastServices.first(where: { $0.name == name }), service.connected else { return true }
        statusPopover.close()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "停用正在使用的“\(name)”？"
        alert.informativeText = "当前连接可能立即中断；只有其他已启用的网络可用时，macOS 才能自动接替。"
        alert.addButton(withTitle: "停用")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmPoweringOffActiveWiFi(device: String) -> Bool {
        guard lastServices.contains(where: { $0.device == device && $0.kind == .wifi && $0.connected }) else { return true }
        statusPopover.close()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭正在使用的 Wi‑Fi？"
        alert.informativeText = "无线连接会立即中断；只有其他已启用的网络可用时，macOS 才能自动接替。"
        alert.addButton(withTitle: "关闭 Wi‑Fi")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performPrivilegedChange(
        description: String,
        optimisticServices: [NetworkService]? = nil,
        operation: @escaping () throws -> Void
    ) {
        guard manager.privilegedAccessState == .ready else {
            configurePrivilegedAccess { [weak self] in
                self?.performPrivilegedChange(
                    description: description,
                    optimisticServices: optimisticServices,
                    operation: operation
                )
            }
            return
        }
        guard !isPerformingPrivilegedChange, !isApplyingServiceSwitch else { return }

        isPerformingPrivilegedChange = true
        let rollbackServices = lastServices
        networkStateGeneration &+= 1
        if let optimisticServices, optimisticServices != lastServices {
            lastServices = optimisticServices
            rebuildMenu(with: optimisticServices)
            if mainWindow?.isVisible == true { rebuildWindow(with: optimisticServices) }
        }
        setOperationFeedback("正在\(description)…", color: .systemOrange)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try operation()
                DispatchQueue.main.async {
                    self.isPerformingPrivilegedChange = false
                    self.setOperationFeedback("已完成：\(description)", color: .systemGreen, clearAfter: 2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.performRefresh(showingErrors: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPerformingPrivilegedChange = false
                    if optimisticServices != nil {
                        self.networkStateGeneration &+= 1
                        self.lastServices = rollbackServices
                        self.rebuildMenu(with: rollbackServices)
                        if self.mainWindow?.isVisible == true { self.rebuildWindow(with: rollbackServices) }
                    }
                    self.clearOperationFeedback()
                    self.showError(error)
                }
            }
        }
    }

    private func performServiceSwitch(target: String, otherServices: [String], wifiDevice: String?) {
        guard manager.privilegedAccessState == .ready else {
            configurePrivilegedAccess { [weak self] in
                self?.performServiceSwitch(target: target, otherServices: otherServices, wifiDevice: wifiDevice)
            }
            return
        }
        guard !isApplyingServiceSwitch, !isPerformingPrivilegedChange else { return }

        isApplyingServiceSwitch = true
        let rollbackServices = lastServices
        applyOptimisticServiceSwitch(target: target, otherServices: otherServices)
        setOperationFeedback("正在切换到 \(target)…", color: .systemOrange)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.manager.switchToService(target, otherServices: otherServices, wifiDevice: wifiDevice)
                DispatchQueue.main.async {
                    self.isApplyingServiceSwitch = false
                    self.setOperationFeedback("已切换到 \(target)", color: .systemGreen, clearAfter: 2)
                    for delay in [0.05, 1.5, 4.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.performRefresh(showingErrors: false)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isApplyingServiceSwitch = false
                    self.networkStateGeneration &+= 1
                    self.lastServices = rollbackServices
                    self.rebuildMenu(with: rollbackServices)
                    if self.mainWindow?.isVisible == true { self.rebuildWindow(with: rollbackServices) }
                    self.clearOperationFeedback()
                    self.performRefresh(showingErrors: false)
                    self.showError(error)
                }
            }
        }
    }

    private func applyOptimisticServiceSwitch(target: String, otherServices: [String]) {
        let services = NetworkServiceTransition.switching(
            services: lastServices,
            target: target,
            disabledServices: otherServices
        )
        guard services != lastServices else { return }
        currentDownloadBytesPerSecond = 0
        currentUploadBytesPerSecond = 0
        networkStateGeneration &+= 1
        lastServices = services
        rebuildMenu(with: services)
        if mainWindow?.isVisible == true { rebuildWindow(with: services) }
    }

    @objc private func showPrivilegedAccessSetup() {
        configurePrivilegedAccess(afterConfiguration: nil)
    }

    private func configurePrivilegedAccess(afterConfiguration: (() -> Void)?) {
        let currentState = manager.privilegedAccessState
        if currentState == .ready {
            let alert = NSAlert()
            alert.messageText = "免密码网络切换已启用"
            alert.informativeText = "受限权限助手已完成配置。登录后自动启动以及启用、停用、切换网络、DNS 和优先级调整都不会再次询问密码。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            afterConfiguration?()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = currentState == .needsRepair ? "修复免密码网络权限" : "首次配置免密码网络切换"
        alert.informativeText = "下一步会显示一次 macOS 管理员授权。LinkGlint 将安装只允许网络设置操作的本机助手；完成后，日常切换和登录启动均不再输入密码。"
        alert.addButton(withTitle: currentState == .needsRepair ? "修复权限" : "开始配置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        accessStatusLabel?.stringValue = "正在等待 macOS 完成一次管理员授权…"
        accessActionButton?.isEnabled = false
        do {
            try manager.configurePrivilegedAccess()
            updatePrivilegedAccessControls()
            if !lastServices.isEmpty { rebuildMenu(with: lastServices) }

            let success = NSAlert()
            success.alertStyle = .informational
            success.messageText = "配置完成"
            success.informativeText = "之后启用、停用或切换网络将直接执行，不再显示密码窗口。登录时启动也会沿用此配置。"
            success.addButton(withTitle: "完成")
            success.runModal()
            afterConfiguration?()
        } catch {
            updatePrivilegedAccessControls()
            showError(error)
        }
    }

    @objc private func removePrivilegedAccess() {
        guard manager.privilegedAccessState != .notConfigured else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除免密码网络权限？"
        alert.informativeText = "移除会再显示一次管理员授权。之后再次修改网络时，需要重新完成首次配置。"
        alert.addButton(withTitle: "移除")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.removePrivilegedAccess()
            updatePrivilegedAccessControls()
            if !lastServices.isEmpty { rebuildMenu(with: lastServices) }
        } catch {
            showError(error)
        }
    }

    private func updatePrivilegedAccessControls() {
        let state = manager.privilegedAccessState
        accessStatusLabel?.stringValue = state.title
        privilegePreferenceLabel?.stringValue = state.title

        switch state {
        case .ready:
            accessCompactLabel?.stringValue = "✓ 免密码切换"
            accessCompactLabel?.textColor = .systemGreen
            accessDetailLabel?.stringValue = "日常网络切换不再询问密码 · 助手仅允许固定网络操作"
            accessActionButton?.title = "已配置"
            accessActionButton?.isEnabled = false
            accessBanner?.borderColor = NSColor.systemGreen.withAlphaComponent(0.50)
            accessBanner?.fillColor = NSColor.systemGreen.withAlphaComponent(0.08)
            accessBanner?.isHidden = true
            privilegePreferenceButton?.title = "已配置"
            privilegePreferenceButton?.isEnabled = false
            removePrivilegeButton?.isEnabled = true
        case .notConfigured:
            accessCompactLabel?.stringValue = "需首次配置"
            accessCompactLabel?.textColor = .systemOrange
            accessDetailLabel?.stringValue = "只需一次管理员授权，之后切换适配器和登录启动均免密码"
            accessActionButton?.title = "首次配置…"
            accessActionButton?.isEnabled = true
            accessBanner?.borderColor = NSColor.systemBlue.withAlphaComponent(0.45)
            accessBanner?.fillColor = NSColor.systemBlue.withAlphaComponent(0.08)
            accessBanner?.isHidden = false
            privilegePreferenceButton?.title = "开始配置…"
            privilegePreferenceButton?.isEnabled = true
            removePrivilegeButton?.isEnabled = false
        case .needsRepair:
            accessCompactLabel?.stringValue = "权限需修复"
            accessCompactLabel?.textColor = .systemOrange
            accessDetailLabel?.stringValue = "配置不完整；修复时需要再完成一次管理员授权"
            accessActionButton?.title = "修复权限…"
            accessActionButton?.isEnabled = true
            accessBanner?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55)
            accessBanner?.fillColor = NSColor.systemOrange.withAlphaComponent(0.09)
            accessBanner?.isHidden = false
            privilegePreferenceButton?.title = "修复权限…"
            privilegePreferenceButton?.isEnabled = true
            removePrivilegeButton?.isEnabled = true
        }
    }

    @objc private func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLoginItemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var loginItemState: NSControl.StateValue {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .mixed
        default: return .off
        }
    }

    @objc private func toggleLaunchAtLoginMenu(_ sender: NSMenuItem) {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    @objc private func toggleLaunchAtLoginButton(_ sender: NSButton) {
        setLaunchAtLogin(sender.state == .on)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            updateLoginItemControls()
            if SMAppService.mainApp.status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "需要批准登录项"
                alert.informativeText = "请在“系统设置 → 通用 → 登录项”中允许 LinkGlint。"
                alert.addButton(withTitle: "打开登录项设置")
                alert.addButton(withTitle: "稍后")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    openLoginItemSettings()
                }
            }
        } catch {
            updateLoginItemControls()
            showError(error)
        }
    }

    private func updateLoginItemControls() {
        loginItemCheckbox?.state = loginItemState
        loginItemCheckbox?.toolTip = loginItemState == .mixed ? "需要在系统设置中批准" : nil
        loginItemStatusLabel?.stringValue = loginItemStatusText
        loginItemStatusLabel?.textColor = loginItemState == .mixed ? .systemOrange : .secondaryLabelColor
        statusContextLoginItem?.state = loginItemState
    }

    private var loginItemStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用 · 登录后自动运行"
        case .requiresApproval: return "等待系统批准 · 请前往系统设置 → 通用 → 登录项"
        case .notRegistered: return "未启用"
        case .notFound: return "请从“应用程序”文件夹运行后重试"
        @unknown default: return "状态未知"
        }
    }

    @objc private func copyMenuValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        copyToPasteboard(value)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func applyProfileMenu(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        applyProfile(token: token)
    }

    @objc private func applySelectedProfile() {
        guard let token = profilePopup.selectedItem?.representedObject as? String else { return }
        applyProfile(token: token)
    }

    private func applyProfile(token: String) {
        var title: String
        var serviceStates: [String: Bool] = [:]
        var wifiPowerStates: [String: Bool] = [:]

        switch token {
        case "__all__":
            title = "全部物理网络启用"
            for service in lastServices where service.kind == .wifi || service.kind == .ethernet {
                serviceStates[service.name] = true
                if service.kind == .wifi, let device = service.device { wifiPowerStates[device] = true }
            }
        case "__wifi__":
            title = "仅 Wi-Fi"
            for service in lastServices where service.kind == .wifi || service.kind == .ethernet {
                serviceStates[service.name] = service.kind == .wifi
                if service.kind == .wifi, let device = service.device { wifiPowerStates[device] = true }
            }
        case "__ethernet__":
            title = "仅有线网络"
            for service in lastServices where service.kind == .wifi || service.kind == .ethernet {
                serviceStates[service.name] = service.kind == .ethernet
                if service.kind == .wifi, let device = service.device { wifiPowerStates[device] = false }
            }
        default:
            guard token.hasPrefix("profile:"),
                  let id = UUID(uuidString: String(token.dropFirst("profile:".count))),
                  let profile = profileStore.profile(id: id) else { return }
            title = profile.name
            serviceStates = profile.serviceStates
            wifiPowerStates = profile.wifiPowerStates
        }

        guard !serviceStates.isEmpty || !wifiPowerStates.isEmpty else {
            showError(NetworkError.commandFailed("当前没有可应用的网络服务。"))
            return
        }
        performPrivilegedChange(description: "应用配置方案：\(title)") { [manager] in
            try manager.applyProfile(serviceStates: serviceStates, wifiPowerStates: wifiPowerStates)
        }
    }

    @objc private func saveCurrentProfile() {
        guard !lastServices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "保存当前网络配置"
        alert.informativeText = "以后可从主窗口或菜单栏一键恢复所有网络服务和 Wi-Fi 电源状态。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "例如：办公室、家庭、仅扩展坞"
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let states = Dictionary(uniqueKeysWithValues: lastServices.map { ($0.name, $0.enabled) })
        let wifiStates = Dictionary(uniqueKeysWithValues: lastServices.compactMap { service -> (String, Bool)? in
            guard service.kind == .wifi, let device = service.device, let powered = service.wifiPowered else { return nil }
            return (device, powered)
        })
        let saved = profileStore.saveSnapshot(
            name: input.stringValue,
            serviceStates: states,
            wifiPowerStates: wifiStates
        )
        updateProfilePopup(selecting: "profile:\(saved.id.uuidString)")
        rebuildMenu(with: lastServices)
    }

    @objc private func deleteSelectedProfile() {
        guard let token = profilePopup.selectedItem?.representedObject as? String,
              token.hasPrefix("profile:"),
              let id = UUID(uuidString: String(token.dropFirst("profile:".count))),
              let profile = profileStore.profile(id: id) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除配置方案“\(profile.name)”？"
        alert.informativeText = "只会删除保存的方案，不会更改当前网络。"
        alert.addButton(withTitle: "删除")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileStore.delete(id: id)
        updateProfilePopup()
        rebuildMenu(with: lastServices)
    }

    private func updateProfilePopup(selecting selectedToken: String? = nil) {
        guard profilePopup != nil else { return }
        let previous = selectedToken ?? (profilePopup.selectedItem?.representedObject as? String)
        profilePopup.removeAllItems()

        for (title, token) in [
            ("全部物理网络启用", "__all__"),
            ("仅 Wi-Fi", "__wifi__"),
            ("仅有线网络", "__ethernet__")
        ] {
            profilePopup.addItem(withTitle: title)
            profilePopup.lastItem?.representedObject = token
        }
        if !profileStore.profiles.isEmpty {
            profilePopup.menu?.addItem(.separator())
            for profile in profileStore.profiles {
                profilePopup.addItem(withTitle: profile.name)
                profilePopup.lastItem?.representedObject = "profile:\(profile.id.uuidString)"
            }
        }

        if let previous,
           let item = profilePopup.itemArray.first(where: { ($0.representedObject as? String) == previous }) {
            profilePopup.select(item)
        } else {
            profilePopup.selectItem(at: 0)
        }
    }

    private func updateUsageDisplay() {
        let today = usageTracker.usage()
        let text = "今日记录  ↓ \(formatBytes(today.receivedBytes))   ↑ \(formatBytes(today.sentBytes))"
        if mainWindow?.isVisible == true { usageLabel?.stringValue = text }
        if statusPopover.isShown {
            statusPanelUsageLabel?.stringValue = "今日记录 ↓ \(formatBytes(today.receivedBytes))  ↑ \(formatBytes(today.sentBytes))"
        }
        statusContextUsageItem?.title = "今日记录：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))"
    }

    @objc private func resetTodayUsage() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重置今天的网络用量？"
        alert.informativeText = "只会清除 LinkGlint 从本机接口统计的今日累计值，不会影响网络设置。"
        alert.addButton(withTitle: "重置")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        usageTracker.resetToday()
        updateUsageDisplay()
    }

    @objc private func showUsageHistory() {
        var days = usageTracker.recentDays(limit: 7)
        if days.isEmpty { days = [usageTracker.usage()] }
        let body = days.map {
            "\($0.dateKey)    ↓ \(formatBytes($0.receivedBytes))    ↑ \(formatBytes($0.sentBytes))"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "最近 LinkGlint 用量记录"
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showPreferences() {
        NSApp.setActivationPolicy(.regular)
        if let preferencesWindow {
            updatePrivilegedAccessControls()
            updateLoginItemControls()
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 592),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinkGlint 偏好设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.center()

        let content = NSVisualEffectView()
        content.material = .contentBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        let title = NSTextField(labelWithString: "偏好设置")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "设置会立即生效，并在下次启动时保留。")
        subtitle.textColor = .secondaryLabelColor

        let menuTitle = preferenceCheckbox(
            title: "在菜单栏显示当前网络状态文字",
            key: "showMenuBarTitle",
            value: preferences.showMenuBarTitle
        )
        let menuSpeed = preferenceCheckbox(
            title: "在菜单栏显示实时上传和下载速度",
            key: "showMenuBarSpeed",
            value: preferences.showMenuBarSpeed
        )
        let menuSpeedTwoLines = preferenceCheckbox(
            title: "网速使用紧凑双行显示",
            key: "menuBarSpeedTwoLines",
            value: preferences.menuBarSpeedTwoLines
        )
        let menuSpeedBits = preferenceCheckbox(
            title: "网速使用 bit/s（关闭时使用 Byte/s）",
            key: "menuBarSpeedInBits",
            value: preferences.menuBarSpeedInBits
        )
        let indicatorTitle = NSTextField(labelWithString: "上下行标记")
        let indicatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        indicatorPopup.removeAllItems()
        for style in MenuBarTrafficIndicatorStyle.allCases {
            let item = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
            item.representedObject = style.rawValue
            indicatorPopup.menu?.addItem(item)
        }
        let selectedStyleIndex = MenuBarTrafficIndicatorStyle.allCases.firstIndex(
            of: preferences.menuBarTrafficIndicatorStyle
        ) ?? 0
        indicatorPopup.selectItem(at: selectedStyleIndex)
        indicatorPopup.target = self
        indicatorPopup.action = #selector(trafficIndicatorStyleChanged(_:))
        indicatorPopup.controlSize = .small
        let indicatorSpacer = NSView()
        indicatorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let indicatorRow = NSStackView(views: [indicatorTitle, indicatorSpacer, indicatorPopup])
        indicatorRow.orientation = .horizontal
        indicatorRow.alignment = .centerY
        let intervalTitle = NSTextField(labelWithString: "网速刷新间隔")
        let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        intervalPopup.removeAllItems()
        for value in [1.0, 2.0, 5.0] {
            let item = NSMenuItem(title: String(format: "%.0f 秒", value), action: nil, keyEquivalent: "")
            item.representedObject = value
            intervalPopup.menu?.addItem(item)
        }
        intervalPopup.selectItem(at: [1.0, 2.0, 5.0].firstIndex(of: preferences.trafficRefreshInterval) ?? 1)
        intervalPopup.target = self
        intervalPopup.action = #selector(trafficIntervalChanged(_:))
        intervalPopup.controlSize = .small
        let intervalSpacer = NSView()
        intervalSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let intervalRow = NSStackView(views: [intervalTitle, intervalSpacer, intervalPopup])
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY
        let openWindow = preferenceCheckbox(
            title: "启动时自动显示主窗口",
            key: "openWindowAtLaunch",
            value: preferences.openWindowAtLaunch
        )
        let autoDiagnostic = preferenceCheckbox(
            title: "网络路径变化后自动运行诊断",
            key: "autoRunDiagnostics",
            value: preferences.autoRunDiagnostics
        )
        loginItemCheckbox = NSButton(
            checkboxWithTitle: "登录时自动启动 LinkGlint",
            target: self,
            action: #selector(toggleLaunchAtLoginButton(_:))
        )
        let loginSettingsButton = NSButton(
            title: "系统设置…",
            target: self,
            action: #selector(openLoginItemSettings)
        )
        loginSettingsButton.bezelStyle = .inline
        loginSettingsButton.controlSize = .small
        let loginSpacer = NSView()
        loginSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let loginRow = NSStackView(views: [loginItemCheckbox, loginSpacer, loginSettingsButton])
        loginRow.orientation = .horizontal
        loginRow.alignment = .centerY
        loginRow.spacing = 8
        loginItemStatusLabel = NSTextField(labelWithString: "")
        loginItemStatusLabel?.font = .systemFont(ofSize: 11)
        loginItemStatusLabel?.textColor = .secondaryLabelColor
        let generalStack = NSStackView(views: [
            loginRow, loginItemStatusLabel!, menuTitle, menuSpeed,
            menuSpeedTwoLines, menuSpeedBits, indicatorRow, intervalRow, openWindow, autoDiagnostic
        ])
        generalStack.orientation = .vertical
        generalStack.alignment = .width
        generalStack.spacing = 9
        generalStack.translatesAutoresizingMaskIntoConstraints = false
        let generalPanel = NSBox()
        generalPanel.boxType = .custom
        generalPanel.cornerRadius = 12
        generalPanel.borderWidth = 1
        generalPanel.borderColor = NSColor.separatorColor.withAlphaComponent(0.7)
        generalPanel.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65)
        generalPanel.contentView?.addSubview(generalStack)

        let accessHeading = NSTextField(labelWithString: "网络切换权限")
        accessHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let shield = NSImageView()
        shield.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
        shield.contentTintColor = .systemBlue
        shield.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        shield.translatesAutoresizingMaskIntoConstraints = false
        privilegePreferenceLabel = NSTextField(labelWithString: manager.privilegedAccessState.title)
        privilegePreferenceLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        let privilegeSpacer = NSView()
        privilegeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        privilegePreferenceButton = NSButton(title: "开始配置…", target: self, action: #selector(showPrivilegedAccessSetup))
        privilegePreferenceButton?.bezelStyle = .rounded
        removePrivilegeButton = NSButton(title: "移除…", target: self, action: #selector(removePrivilegedAccess))
        removePrivilegeButton?.bezelStyle = .rounded
        let accessRow = NSStackView(views: [shield, privilegePreferenceLabel!, privilegeSpacer, privilegePreferenceButton!, removePrivilegeButton!])
        accessRow.orientation = .horizontal
        accessRow.alignment = .centerY
        accessRow.spacing = 9
        let accessHint = NSTextField(wrappingLabelWithString: "首次配置会请求一次管理员授权。助手由 root 持有、只接受固定网络命令；之后启用、停用、DNS、优先级及网络切换均不弹出密码窗口。")
        accessHint.textColor = .secondaryLabelColor
        accessHint.font = .systemFont(ofSize: 11)
        let accessStack = NSStackView(views: [accessHeading, accessRow, accessHint])
        accessStack.orientation = .vertical
        accessStack.alignment = .width
        accessStack.spacing = 8
        accessStack.translatesAutoresizingMaskIntoConstraints = false
        let accessPanel = NSBox()
        accessPanel.boxType = .custom
        accessPanel.cornerRadius = 12
        accessPanel.borderWidth = 1
        accessPanel.borderColor = NSColor.systemBlue.withAlphaComponent(0.28)
        accessPanel.fillColor = NSColor.systemBlue.withAlphaComponent(0.055)
        accessPanel.contentView?.addSubview(accessStack)

        let closeHint = NSTextField(wrappingLabelWithString: "关闭主窗口后 Dock 图标会自动隐藏，LinkGlint 继续在菜单栏运行；从菜单选择“退出 LinkGlint”可完全结束。登录时启动使用 macOS 原生登录项，不需要管理员密码。如暂时看不到状态项，请展开菜单栏隐藏区域并按住 ⌘ 将 LinkGlint 拖到常驻区域。")
        closeHint.textColor = .tertiaryLabelColor
        closeHint.font = .systemFont(ofSize: 11)

        let done = NSButton(title: "完成", target: self, action: #selector(closePreferences))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, done])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [title, subtitle, generalPanel, accessPanel, closeHint, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            generalStack.topAnchor.constraint(equalTo: generalPanel.contentView!.topAnchor, constant: 12),
            generalStack.bottomAnchor.constraint(equalTo: generalPanel.contentView!.bottomAnchor, constant: -12),
            generalStack.leadingAnchor.constraint(equalTo: generalPanel.contentView!.leadingAnchor, constant: 14),
            generalStack.trailingAnchor.constraint(equalTo: generalPanel.contentView!.trailingAnchor, constant: -14),
            shield.widthAnchor.constraint(equalToConstant: 24),
            shield.heightAnchor.constraint(equalToConstant: 24),
            accessStack.topAnchor.constraint(equalTo: accessPanel.contentView!.topAnchor, constant: 12),
            accessStack.bottomAnchor.constraint(equalTo: accessPanel.contentView!.bottomAnchor, constant: -12),
            accessStack.leadingAnchor.constraint(equalTo: accessPanel.contentView!.leadingAnchor, constant: 14),
            accessStack.trailingAnchor.constraint(equalTo: accessPanel.contentView!.trailingAnchor, constant: -14)
        ])
        preferencesWindow = window
        updateLoginItemControls()
        updatePrivilegedAccessControls()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        statusPopover.close()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "原生 macOS 网络状态与管理工具\n\n作者：HarenaGodz（Harena）\nGitHub：github.com/HarenaGodz/LinkGlint\nMIT License",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LinkGlint",
            .applicationVersion: "版本 \(version)",
            .version: "构建 \(build)",
            .credits: credits,
            .applicationIcon: NSApp.applicationIconImage ?? NSImage()
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func preferenceCheckbox(title: String, key: String, value: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(togglePreference(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = value ? .on : .off
        return button
    }

    @objc private func togglePreference(_ sender: NSButton) {
        let enabled = sender.state == .on
        switch sender.identifier?.rawValue {
        case "showMenuBarTitle":
            preferences.showMenuBarTitle = enabled
            applyMenuBarAppearance()
        case "showMenuBarSpeed":
            preferences.showMenuBarSpeed = enabled
            applyMenuBarAppearance()
        case "menuBarSpeedTwoLines":
            preferences.menuBarSpeedTwoLines = enabled
            applyMenuBarAppearance()
        case "menuBarSpeedInBits":
            preferences.menuBarSpeedInBits = enabled
            applyMenuBarAppearance()
        case "openWindowAtLaunch":
            preferences.openWindowAtLaunch = enabled
        case "autoRunDiagnostics":
            preferences.autoRunDiagnostics = enabled
        default:
            break
        }
    }

    @objc private func trafficIntervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? Double else { return }
        preferences.trafficRefreshInterval = value
        previousTrafficSampleDate = nil
        previousTrafficCounters.removeAll()
        scheduleTrafficTimer()
        sampleTraffic()
    }

    @objc private func trafficIndicatorStyleChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = MenuBarTrafficIndicatorStyle(rawValue: rawValue) else { return }
        preferences.menuBarTrafficIndicatorStyle = style
        lastMenuBarRenderKey = nil
        applyMenuBarAppearance()
    }

    @objc private func closePreferences() {
        preferencesWindow?.orderOut(nil)
        hideDockIconIfNoWindowsAreVisible()
    }

    @objc private func runDiagnostics() {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        diagnosticLabel?.isHidden = false
        diagnosticLabel?.stringValue = "网络诊断：正在检查网关与 DNS…"
        diagnosticLabel?.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.manager.runDiagnostics()
            DispatchQueue.main.async {
                self.isDiagnosing = false
                self.lastDiagnostic = result
                var detail = "网络诊断：\(result.summary)"
                if let latency = result.gatewayLatencyMilliseconds {
                    detail += String(format: " · 网关 %.1f ms", latency)
                }
                detail += result.dnsLookupSucceeded ? " · DNS 正常" : " · DNS 异常"
                self.diagnosticLabel?.stringValue = detail
                self.diagnosticLabel?.textColor = result.gatewayLatencyMilliseconds != nil && result.dnsLookupSucceeded
                    ? .systemGreen : .systemOrange
            }
        }
    }

    @objc private func copyDiagnosticReport() {
        copyToPasteboard(makeDiagnosticReport())
        diagnosticLabel?.isHidden = false
        diagnosticLabel?.stringValue = "网络诊断：报告已复制到剪贴板"
    }

    @objc private func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.title = "导出 LinkGlint 诊断报告"
        panel.nameFieldStringValue = "LinkGlint-诊断报告-\(reportFileTimestamp()).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeDiagnosticReport().write(to: url, atomically: true, encoding: .utf8)
            diagnosticLabel?.isHidden = false
            diagnosticLabel?.stringValue = "网络诊断：报告已导出到 \(url.lastPathComponent)"
        } catch {
            showError(error)
        }
    }

    private func makeDiagnosticReport() -> String {
        let formatter = ISO8601DateFormatter()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        var lines = [
            "LinkGlint 网络诊断报告",
            "生成时间：\(formatter.string(from: Date()))",
            "LinkGlint 版本：\(version)",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            ""
        ]

        if let diagnostic = lastDiagnostic {
            lines.append("诊断结果：\(diagnostic.summary)")
            lines.append("默认接口：\(diagnostic.defaultInterface ?? "无")")
            lines.append("默认网关：\(diagnostic.gateway ?? "无")")
            lines.append("网关延迟：" + (diagnostic.gatewayLatencyMilliseconds.map { String(format: "%.3f ms", $0) } ?? "不可达"))
            lines.append("DNS 查询：www.apple.com · \(diagnostic.dnsLookupSucceeded ? "成功" : "失败")")
            lines.append("系统 DNS：\(diagnostic.systemDNSServers.isEmpty ? "未发现" : diagnostic.systemDNSServers.joined(separator: ", "))")
        } else {
            lines.append("诊断结果：尚未运行主动诊断")
        }

        let todayUsage = usageTracker.usage()
        lines.append("")
        lines.append("流量统计")
        lines.append("========")
        lines.append("今日下载：\(formatBytes(todayUsage.receivedBytes))")
        lines.append("今日上传：\(formatBytes(todayUsage.sentBytes))")
        lines.append("本次下载：\(formatBytes(usageTracker.sessionReceivedBytes))")
        lines.append("本次上传：\(formatBytes(usageTracker.sessionSentBytes))")
        let history = usageTracker.recentDays(limit: 7)
        if !history.isEmpty {
            lines.append("最近记录：")
            for day in history {
                lines.append("  \(day.dateKey) · ↓ \(formatBytes(day.receivedBytes)) · ↑ \(formatBytes(day.sentBytes))")
            }
        }

        lines.append("")
        lines.append("网络服务")
        lines.append("========")
        for service in lastServices {
            lines.append(service.copyableDetails)
            if let device = service.device, let traffic = trafficLabels[device]?.stringValue, !traffic.isEmpty {
                lines.append(traffic)
            }
            lines.append("---")
        }
        return lines.joined(separator: "\n")
    }

    private func reportFileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if hasLoadedNetworkState, renderedWindowServices != lastServices {
            rebuildWindow(with: lastServices)
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        updateUsageDisplay()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func hideMainWindow() {
        mainWindow?.orderOut(nil)
        showMenuBarRunningFeedback()
        hideDockIconIfNoWindowsAreVisible()
    }

    private func createMainWindow() {
        mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "LinkGlint"
        mainWindow.minSize = NSSize(width: 650, height: 440)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.delegate = self
        mainWindow.center()

        let content = NSVisualEffectView()
        content.material = .contentBackground
        content.blendingMode = .behindWindow
        content.state = .active
        mainWindow.contentView = content

        // Compact header: current connection first, advanced actions behind icons.
        let headerIcon = NSImageView()
        headerIcon.image = NSImage(systemSymbolName: "network", accessibilityDescription: "LinkGlint")
        headerIcon.symbolConfiguration = .init(pointSize: 21, weight: .semibold)
        headerIcon.contentTintColor = .systemBlue
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "LinkGlint")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        overviewLabel = NSTextField(labelWithString: "正在读取网络状态…")
        overviewLabel.font = .systemFont(ofSize: 12)
        overviewLabel.textColor = .secondaryLabelColor
        overviewLabel.lineBreakMode = .byTruncatingTail
        let titleStack = NSStackView(views: [title, overviewLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        accessCompactLabel = NSTextField(labelWithString: "")
        accessCompactLabel.font = .systemFont(ofSize: 11, weight: .medium)
        accessCompactLabel.alignment = .right

        let refreshButton = compactIconButton(
            symbol: "arrow.clockwise",
            label: "刷新网络状态",
            action: #selector(refresh)
        )
        let hideButton = compactIconButton(
            symbol: "menubar.rectangle",
            label: "隐藏到菜单栏",
            action: #selector(hideMainWindow)
        )
        let preferencesButton = compactIconButton(
            symbol: "slider.horizontal.3",
            label: "偏好设置",
            action: #selector(showPreferences)
        )

        let header = NSStackView(views: [headerIcon, titleStack, headerSpacer, accessCompactLabel, refreshButton, hideButton, preferencesButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = LinkGlintLayout.standardGap

        // This compact banner is visible only until the one-time setup is ready.
        accessBanner = NSBox()
        accessBanner.boxType = .custom
        accessBanner.cornerRadius = LinkGlintLayout.sectionRadius
        accessBanner.borderWidth = 1

        let shield = NSImageView()
        shield.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "权限状态")
        shield.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        shield.contentTintColor = .systemBlue
        shield.translatesAutoresizingMaskIntoConstraints = false

        accessStatusLabel = NSTextField(labelWithString: "")
        accessStatusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        accessDetailLabel = NSTextField(labelWithString: "")
        accessDetailLabel.font = .systemFont(ofSize: 10.5)
        accessDetailLabel.textColor = .secondaryLabelColor
        accessDetailLabel.lineBreakMode = .byTruncatingTail
        let accessText = NSStackView(views: [accessStatusLabel, accessDetailLabel])
        accessText.orientation = .vertical
        accessText.alignment = .leading
        accessText.spacing = 1
        accessText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let accessSpacer = NSView()
        accessSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accessActionButton = NSButton(title: "首次配置…", target: self, action: #selector(showPrivilegedAccessSetup))
        accessActionButton.bezelStyle = .rounded
        accessActionButton.controlSize = .small
        let accessRow = NSStackView(views: [shield, accessText, accessSpacer, accessActionButton])
        accessRow.orientation = .horizontal
        accessRow.alignment = .centerY
        accessRow.spacing = 10
        accessRow.translatesAutoresizingMaskIntoConstraints = false
        accessBanner.contentView?.addSubview(accessRow)

        // One-row profile control replaces the previous three-row control panel.
        let profileTitle = NSTextField(labelWithString: "方案")
        profileTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        profileTitle.textColor = .secondaryLabelColor
        profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        profilePopup.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        profilePopup.controlSize = .small
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        let applyProfileButton = NSButton(title: "应用", target: self, action: #selector(applySelectedProfile))
        applyProfileButton.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        applyProfileButton.bezelStyle = .rounded
        applyProfileButton.controlSize = .small
        applyProfileButton.contentTintColor = .systemBlue
        let profileSpacer = NSView()
        profileSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        adapterSummaryLabel = NSTextField(labelWithString: "正在加载…")
        adapterSummaryLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        adapterSummaryLabel.textColor = .secondaryLabelColor
        adapterSummaryLabel.alignment = .right
        adapterSummaryLabel.lineBreakMode = .byTruncatingTail
        let profileRow = NSStackView(views: [profileTitle, profilePopup, applyProfileButton, profileSpacer, adapterSummaryLabel])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8
        profileRow.translatesAutoresizingMaskIntoConstraints = false

        let profilePanel = NSBox()
        profilePanel.boxType = .custom
        profilePanel.cornerRadius = LinkGlintLayout.sectionRadius
        profilePanel.borderWidth = 1
        profilePanel.borderColor = NSColor.separatorColor.withAlphaComponent(0.65)
        profilePanel.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        profilePanel.contentView?.addSubview(profileRow)
        updateProfilePopup()

        let adaptersTitle = NSTextField(labelWithString: "网络适配器")
        adaptersTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let adapterHint = NSTextField(labelWithString: "开关用于启用或停用 · 更多操作在 ⋯")
        adapterHint.font = .systemFont(ofSize: 10.5)
        adapterHint.textColor = .secondaryLabelColor
        let adapterHeaderSpacer = NSView()
        adapterHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let adapterHeader = NSStackView(views: [adaptersTitle, adapterHeaderSpacer, adapterHint])
        adapterHeader.orientation = .horizontal
        adapterHeader.alignment = .centerY

        servicesStack = NSStackView()
        servicesStack.orientation = .vertical
        servicesStack.alignment = .width
        servicesStack.spacing = LinkGlintLayout.compactGap
        servicesStack.translatesAutoresizingMaskIntoConstraints = false
        let loading = NSTextField(labelWithString: "正在读取网络状态…")
        loading.alignment = .center
        loading.textColor = .secondaryLabelColor
        servicesStack.addArrangedSubview(loading)

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(servicesStack)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document

        diagnosticLabel = NSTextField(labelWithString: "")
        diagnosticLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        diagnosticLabel.textColor = .secondaryLabelColor
        diagnosticLabel.lineBreakMode = .byTruncatingTail
        diagnosticLabel.isHidden = true

        usageLabel = NSTextField(labelWithString: "")
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.lineBreakMode = .byTruncatingTail
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolsButton = makeToolsButton()
        let footer = NSStackView(views: [usageLabel, footerSpacer, toolsButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        updateUsageDisplay()

        let root = NSStackView(views: [header, accessBanner, profilePanel, adapterHeader, scroll, diagnosticLabel, footer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = LinkGlintLayout.standardGap
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),
            shield.widthAnchor.constraint(equalToConstant: 22),
            shield.heightAnchor.constraint(equalToConstant: 22),
            accessRow.topAnchor.constraint(equalTo: accessBanner.contentView!.topAnchor, constant: 6),
            accessRow.bottomAnchor.constraint(equalTo: accessBanner.contentView!.bottomAnchor, constant: -6),
            accessRow.leadingAnchor.constraint(equalTo: accessBanner.contentView!.leadingAnchor, constant: 12),
            accessRow.trailingAnchor.constraint(equalTo: accessBanner.contentView!.trailingAnchor, constant: -12),
            profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            profileRow.topAnchor.constraint(equalTo: profilePanel.contentView!.topAnchor, constant: 6),
            profileRow.bottomAnchor.constraint(equalTo: profilePanel.contentView!.bottomAnchor, constant: -6),
            profileRow.leadingAnchor.constraint(equalTo: profilePanel.contentView!.leadingAnchor, constant: 12),
            profileRow.trailingAnchor.constraint(equalTo: profilePanel.contentView!.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            servicesStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            servicesStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 1),
            servicesStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -7),
            servicesStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -5)
        ])
        updatePrivilegedAccessControls()
    }

    private func compactIconButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        return button
    }

    private func makeToolsButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel("工具与更多功能")
        let menu = button.menu!
        menu.removeAllItems()
        let title = NSMenuItem(title: "工具", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(title)
        addToolItem(menu, title: "运行网络诊断", symbol: "stethoscope", action: #selector(runDiagnostics))
        addToolItem(menu, title: "复制诊断报告", symbol: "doc.on.doc", action: #selector(copyDiagnosticReport))
        addToolItem(menu, title: "导出诊断报告…", symbol: "square.and.arrow.up", action: #selector(exportDiagnosticReport))
        menu.addItem(.separator())
        addToolItem(menu, title: "保存当前方案…", symbol: "plus.square", action: #selector(saveCurrentProfile))
        addToolItem(menu, title: "删除所选自定义方案…", symbol: "trash", action: #selector(deleteSelectedProfile))
        addToolItem(menu, title: "调整服务优先级…", symbol: "arrow.up.arrow.down", action: #selector(showPriorityEditor))
        menu.addItem(.separator())
        addToolItem(menu, title: "用量历史…", symbol: "chart.bar", action: #selector(showUsageHistory))
        addToolItem(menu, title: "重置今日用量…", symbol: "arrow.counterclockwise", action: #selector(resetTodayUsage))
        menu.addItem(.separator())
        addToolItem(menu, title: "打开网络设置…", symbol: "gear", action: #selector(openNetworkSettings))
        addToolItem(menu, title: "偏好设置…", symbol: "slider.horizontal.3", action: #selector(showPreferences))
        addToolItem(menu, title: "关于 LinkGlint", symbol: "info.circle", action: #selector(showAbout))
        return button
    }

    private func addToolItem(_ menu: NSMenu, title: String, symbol: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func rebuildWindow(with services: [NetworkService]) {
        renderedWindowServices = services
        if let primary = services.first(where: { $0.isPrimary && $0.connected }) {
            var text = "当前网络：\(primary.name)"
            if let ssid = primary.ssid { text += " · \(ssid)" }
            if let ip = primary.ipAddress { text += " · \(ip)" }
            overviewLabel.stringValue = text
        } else if let connected = services.first(where: \.connected) {
            overviewLabel.stringValue = "已连接：\(connected.name)" + (connected.ipAddress.map { " · \($0)" } ?? "")
        } else {
            overviewLabel.stringValue = "当前没有已连接网络"
        }
        let connectedCount = services.filter(\.connected).count
        let enabledCount = services.filter(\.enabled).count
        adapterSummaryLabel?.stringValue = "\(services.count) 个服务 · \(connectedCount) 个已连接 · \(enabledCount) 个已启用"
        adapterSummaryLabel?.textColor = .secondaryLabelColor
        updateLoginItemControls()
        updatePrivilegedAccessControls()
        trafficLabels.removeAll()

        for view in servicesStack.arrangedSubviews {
            servicesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if services.isEmpty {
            let empty = NSTextField(labelWithString: "未发现网络服务")
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            servicesStack.addArrangedSubview(empty)
            return
        }

        for service in services {
            servicesStack.addArrangedSubview(serviceCard(service, allServices: services))
        }
        updateOperationFeedbackDisplays()
    }

    private func serviceCard(_ service: NetworkService, allServices: [NetworkService]) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = LinkGlintLayout.rowRadius
        card.borderWidth = service.connected ? 1 : 0
        let accentColor: NSColor
        switch service.kind {
        case .wifi: accentColor = .systemBlue
        case .ethernet: accentColor = .systemTeal
        case .vpn: accentColor = .systemPurple
        case .other: accentColor = .systemGray
        }
        card.borderColor = service.connected
            ? accentColor.withAlphaComponent(0.28)
            : .clear
        card.fillColor = service.connected
            ? accentColor.withAlphaComponent(0.055)
            : NSColor.controlBackgroundColor.withAlphaComponent(service.enabled ? 0.24 : 0.11)
        card.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = symbol(for: service)
        iconView.contentTintColor = service.connected ? accentColor : .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: service.name)
        name.font = .systemFont(ofSize: 12.5, weight: service.connected ? .semibold : .medium)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = service.name

        var detailParts = [service.connected ? "已连接" : (service.enabled ? "未连接" : "已停用")]
        if let ssid = service.ssid { detailParts.append(ssid) }
        if let ip = service.ipAddress { detailParts.append(ip) }
        if let device = service.device { detailParts.append(device) }
        let detail = NSTextField(labelWithString: detailParts.joined(separator: "  ·  "))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = service.connected ? accentColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.toolTip = detail.stringValue

        let traffic = NSTextField(labelWithString: service.connected ? "↓ 正在采样…   ↑ 正在采样…" : "")
        traffic.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        traffic.textColor = .secondaryLabelColor
        traffic.isHidden = !service.connected || service.device == nil
        if service.connected, let device = service.device { trafficLabels[device] = traffic }

        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toggle = NetworkToggleSwitch()
        toggle.target = self
        toggle.action = #selector(windowToggleServiceSwitch(_:))
        toggle.state = service.enabled ? .on : .off
        toggle.payload = ["name": service.name]
        toggle.controlSize = .small
        toggle.toolTip = service.enabled ? "停用 \(service.name)" : "启用 \(service.name)"
        toggle.setAccessibilityLabel("启用 \(service.name)")

        let more = serviceActionsButton(service, allServices: allServices)
        var rowViews: [NSView] = [iconView, labels, spacer]
        if service.isPrimary {
            rowViews.append(statusPanelBadge("默认", color: accentColor))
        }
        rowViews.append(traffic)
        rowViews.append(toggle)
        rowViews.append(more)
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = LinkGlintLayout.standardGap
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(row)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: LinkGlintLayout.mainRowHeight),
            iconView.widthAnchor.constraint(equalToConstant: 23),
            iconView.heightAnchor.constraint(equalToConstant: 23),
            row.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -8)
        ])
        return card
    }

    private func serviceActionsButton(_ service: NetworkService, allServices: [NetworkService]) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.setAccessibilityLabel("\(service.name) 的更多操作")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let menu = button.menu!
        menu.removeAllItems()
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        menu.addItem(title)

        if service.kind == .wifi || service.kind == .ethernet {
            let others = allServices.filter {
                $0.name != service.name && $0.enabled && ($0.kind == .wifi || $0.kind == .ethernet)
            }.map(\.name)
            let switchItem = NSMenuItem(title: "切换到此网络", action: #selector(switchToService(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
            switchItem.representedObject = [
                "target": service.name,
                "others": others,
                "wifiDevice": service.kind == .wifi ? (service.device ?? "") : ""
            ] as NSDictionary
            menu.addItem(switchItem)
        }

        if service.kind == .wifi, let device = service.device, let powered = service.wifiPowered {
            let wifi = NSMenuItem(
                title: powered ? "关闭 Wi-Fi 硬件" : "打开 Wi-Fi 硬件",
                action: #selector(toggleWiFiPower(_:)),
                keyEquivalent: ""
            )
            wifi.target = self
            wifi.image = NSImage(systemSymbolName: powered ? "wifi.slash" : "wifi", accessibilityDescription: nil)
            wifi.representedObject = ["device": device, "enable": !powered] as NSDictionary
            menu.addItem(wifi)
        }

        menu.addItem(.separator())
        let rename = NSMenuItem(title: "重命名网络服务…", action: #selector(renameNetworkService(_:)), keyEquivalent: "")
        rename.target = self
        rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        rename.representedObject = service.name
        menu.addItem(rename)

        let dns = NSMenuItem(title: "设置 DNS…", action: #selector(showDNSSettingsMenu(_:)), keyEquivalent: "")
        dns.target = self
        dns.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        dns.representedObject = ["service": service.name, "servers": service.dnsServers] as NSDictionary
        menu.addItem(dns)

        if service.orderIndex > 0 {
            let priority = NSMenuItem(title: "设为最高优先级", action: #selector(setHighestPriorityMenu(_:)), keyEquivalent: "")
            priority.target = self
            priority.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
            priority.representedObject = ["service": service.name, "order": allServices.map(\.name)] as NSDictionary
            menu.addItem(priority)
        }

        menu.addItem(.separator())
        let copyInfo = NSMenuItem(title: "复制网络信息", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
        copyInfo.target = self
        copyInfo.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyInfo.representedObject = service.copyableDetails
        menu.addItem(copyInfo)
        if let ip = service.ipAddress {
            let copyIP = NSMenuItem(title: "复制 IP 地址", action: #selector(copyMenuValue(_:)), keyEquivalent: "")
            copyIP.target = self
            copyIP.representedObject = ip
            menu.addItem(copyIP)
        }
        return button
    }

    @objc private func windowToggleServiceSwitch(_ sender: NetworkToggleSwitch) {
        guard let name = sender.payload?["name"] as? String else { return }
        let enable = sender.state == .on
        guard enable || confirmDisablingActiveService(named: name) else {
            sender.state = .on
            sender.needsDisplay = true
            return
        }
        let optimistic = NetworkServiceTransition.settingEnabled(
            services: lastServices,
            named: name,
            enabled: enable
        )
        performPrivilegedChange(
            description: enable ? "启用 \(name)" : "停用 \(name)",
            optimisticServices: optimistic
        ) { [manager] in
            try manager.setService(name, enabled: enable)
        }
    }

    @objc private func windowSwitchToService(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let target = data["target"] as? String,
              let others = data["others"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }
        performServiceSwitch(
            target: target,
            otherServices: others,
            wifiDevice: wifiDeviceValue.isEmpty ? nil : wifiDeviceValue
        )
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "网络操作未完成"
        alert.informativeText = error.localizedDescription.isEmpty ? "请重试。" : error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

}

private final class NetworkActionButton: NSButton {
    var payload: NSDictionary?
}

private final class NetworkToggleSwitch: NSButton {
    var payload: NSDictionary?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 20) }

    private func configure() {
        setButtonType(.pushOnPushOff)
        title = ""
        isBordered = false
        focusRingType = .none
        setAccessibilityRole(.checkBox)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 36, height: 20)
        let isOn = state == .on
        let trackColor = isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor.withAlphaComponent(0.28)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()

        let knobX = isOn ? track.maxX - 18 : track.minX + 2
        let knobRect = NSRect(x: knobX, y: track.minY + 2, width: 16, height: 16)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let outline = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.25, dy: 0.25))
        outline.lineWidth = 0.5
        outline.stroke()
    }
}

private final class StatusPanelBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        updateBackgroundColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// NSScrollView otherwise starts an auto-layout document at its bottom edge.
/// A flipped document gives the service list the natural top-to-bottom order.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
