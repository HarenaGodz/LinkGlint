import AppKit
import Network
import ServiceManagement
import CoreLocation

/// Shared four-point-grid metrics for the menu-bar panel and main window.
private enum LinkGlintLayout {
    static let compactGap: CGFloat = 4
    static let standardGap: CGFloat = 8
    static let panelWidth: CGFloat = 388
    static let panelRowHeight: CGFloat = 46
    static let mainRowHeight: CGFloat = 52
    static let rowRadius: CGFloat = 8
    static let sectionRadius: CGFloat = 10
    static let networkRefreshInterval: TimeInterval = 30
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, CLLocationManagerDelegate, NSMenuItemValidation {
    private static let menuBarSpeedSegmentExpression = try? NSRegularExpression(
        pattern: "[↓↑●▼▲][^↓↑●▼▲]+"
    )

    private let manager = NetworkManager()
    private let profileStore = NetworkProfileStore()
    private let usageTracker = UsageTracker()
    private var preferences = AppPreferences()
    private var statusItem: NSStatusItem!
    private let statusPopover = NSPopover()
    private let locationManager = CLLocationManager()
    private var wifiPickerController: WiFiPickerViewController?
    private var wifiPickerDevice: String?
    private var wifiScanGeneration = 0
    private var wifiScanActiveGeneration: Int?
    private var wifiScanWorkerIsActive = false
    private var wifiPendingScanRequest = WiFiPendingScanRequest()
    private var wifiScanTimeoutWork: DispatchWorkItem?
    private var wifiPendingScanTimeoutWork: DispatchWorkItem?
    // CoreWLAN does not expose cancellation for an in-flight scan. Serialize
    // scans so a soft timeout/retry never starts a second radio scan on top of
    // the first one.
    private let wifiScanQueue = DispatchQueue(label: "io.github.harenagodz.LinkGlint.wifi-scan", qos: .userInitiated)
    private var wifiPickerIsVisible = false
    private var isRequestingLocationAuthorization = false
    private var isKeepingStatusPanelOpenForModalInteraction = false
    private var statusContextMenu: NSMenu?
    private var statusPanelIsOpen = false
    private var statusPanelPreviousApplication: NSRunningApplication?
    private var statusPanelLocalEventMonitor: Any?
    private var statusPanelGlobalEventMonitor: Any?
    private var statusPanelResignObserver: NSObjectProtocol?
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
    private var refreshRequests = RefreshRequestCoalescer()
    private var deferredRefreshShowsErrors: Bool?
    private var isPerformingPrivilegedChange = false
    private var isApplyingServiceSwitch = false
    private var isConfiguringPrivilegedAccess = false
    private var networkStateGeneration = 0
    private var isSamplingTraffic = false
    private var trafficSampleGeneration = 0
    private var isDiagnosing = false
    private var diagnosticPending = false
    private var privilegedAccessState: PrivilegedAccessState = .notConfigured
    private var lastServices: [NetworkService] = []
    private var renderedWindowServices: [NetworkService]?
    private var lastDiagnostic: NetworkDiagnostic?
    private var previousTrafficCounters: [String: InterfaceCounters] = [:]
    private var previousTrafficSampleDate: Date?
    private var previousTrafficSampleUptime: TimeInterval?
    private var currentDownloadBytesPerSecond: Double = 0
    private var currentUploadBytesPerSecond: Double = 0
    private var trafficRateHistory = TrafficRateHistory(capacity: 60)
    private var lastMenuBarRenderKey: String?
    private var lastRenderedMenuBarPresentation: MenuBarTrafficPresentation?
    private var lastStandaloneMenuBarSymbolName: String?
    private var menuBarRateColumnWidths: [Bool: CGFloat] = [:]
    private var trafficLabels: [String: [NSTextField]] = [:]
    private var lastAutoDiagnosticUptime: TimeInterval?
    private var hasLoadedNetworkState = false
    private var initialRefreshError: String?
    private var lastSuccessfulRefreshAt: Date?
    private var refreshFailureMessage: String?
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
        statusItem.button?.setAccessibilityHelp("单击打开快捷面板，右击打开完整功能菜单")
        statusItem.button?.setAccessibilityExpanded(false)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleStatusPanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The status button owns the complete open/close cycle. A transient
        // popover closes on mouse-down, while NSStatusBarButton acts on
        // mouse-up; combining both can immediately reopen a panel the user
        // just tried to close.
        statusPopover.behavior = .applicationDefined
        statusPopover.animates = false
        statusPopover.delegate = self
        locationManager.delegate = self

        createMainWindow()
        showLoadingMenu()
        if preferences.openWindowAtLaunch {
            showMainWindow()
        }
        performRefresh(showingErrors: false)
        let refreshTimer = Timer(timeInterval: LinkGlintLayout.networkRefreshInterval, repeats: true) { [weak self] _ in
            self?.performRefresh(showingErrors: false)
        }
        refreshTimer.tolerance = 2
        self.refreshTimer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
        scheduleTrafficTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeStatusPanelDismissalMonitors()
        usageTracker.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Approval can change while System Settings is frontmost. Refresh the
        // checkbox and context-menu state as soon as the user returns.
        updateLoginItemControls()
    }

    @objc private func handleSystemSleep() {
        // Persist the most recent usage bucket before the process is suspended;
        // a forced shutdown or empty battery after sleep should not lose the
        // last throttled batch of samples.
        usageTracker.flush()
        pendingPathRefresh?.cancel()
        pendingPathRefresh = nil
    }

    @objc private func handleSystemWake() {
        // Interface counters or the active route may change while the process is
        // suspended. Invalidate work launched before sleep and start with a
        // fresh baseline so neither an old route snapshot nor a large averaged
        // traffic spike can briefly overwrite the post-wake state.
        networkStateGeneration &+= 1
        pendingPathRefresh?.cancel()
        pendingPathRefresh = nil
        invalidateDiagnosticResult()
        resetTrafficSampling(clearHistory: true)
        applyMenuBarAppearance()
        performRefresh(showingErrors: false)
        sampleTraffic()
    }

    private func resetTrafficSampling(clearHistory: Bool = false) {
        trafficSampleGeneration &+= 1
        previousTrafficCounters.removeAll()
        previousTrafficSampleDate = nil
        previousTrafficSampleUptime = nil
        currentDownloadBytesPerSecond = 0
        currentUploadBytesPerSecond = 0
        if let label = statusPanelTrafficRatesLabel {
            label.attributedStringValue = statusPanelTrafficRateText
        }
        let placeholder = "  -- B/s"
        let trafficText = "↓ \(placeholder)  ↑ \(placeholder)"
        for label in trafficLabels.values.joined() where label.stringValue != trafficText {
            label.stringValue = trafficText
        }
        if clearHistory {
            trafficRateHistory = TrafficRateHistory(capacity: 60)
            statusPanelTrafficChart?.samples = []
        }
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

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
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
        guard !networkMutationIsActive else {
            deferredRefreshShowsErrors = (deferredRefreshShowsErrors ?? false) || showingErrors
            return
        }
        let effectiveShowsErrors = (deferredRefreshShowsErrors ?? false) || showingErrors
        deferredRefreshShowsErrors = nil
        guard refreshRequests.request(showingErrors: effectiveShowsErrors) else { return }
        startNetworkRefresh(showingErrors: effectiveShowsErrors)
    }

    private func startNetworkRefresh(showingErrors: Bool) {
        let generation = networkStateGeneration
        let qos: DispatchQoS.QoSClass = showingErrors ? .userInitiated : .utility

        DispatchQueue.global(qos: qos).async { [weak self] in
            guard let self else { return }
            do {
                let services = try self.manager.fetchServices()
                let accessState = self.manager.privilegedAccessState
                DispatchQueue.main.async {
                    guard generation == self.networkStateGeneration else {
                        self.completeNetworkRefresh(retryingWith: showingErrors)
                        return
                    }
                    self.hasLoadedNetworkState = true
                    let recoveredFromInitialError = self.initialRefreshError != nil
                    let recoveredFromRefreshFailure = self.refreshFailureMessage != nil
                    self.initialRefreshError = nil
                    self.refreshFailureMessage = nil
                    self.lastSuccessfulRefreshAt = Date()
                    let servicesChanged = services != self.lastServices
                    let accessStateChanged = accessState != self.privilegedAccessState
                    if servicesChanged {
                        // Diagnostics are tied to the route/service snapshot
                        // that launched them. A topology change must invalidate
                        // an older result even when it came from a normal
                        // external macOS network event rather than our helper.
                        self.networkStateGeneration &+= 1
                        self.invalidateDiagnosticResult()
                        self.resetTrafficSampling()
                    }
                    self.privilegedAccessState = accessState
                    if accessStateChanged {
                        self.updatePrivilegedAccessControls()
                    }
                    self.lastServices = services
                    if servicesChanged || accessStateChanged || recoveredFromInitialError || recoveredFromRefreshFailure {
                        self.rebuildMenu(with: services)
                        if self.mainWindow?.isVisible == true {
                            self.rebuildWindow(with: services)
                        }
                    } else {
                        // Most periodic refreshes contain identical data. Avoid
                        // reconstructing every menu, card and Auto Layout tree.
                        self.updateStatusIcon(services)
                    }
                    // The traffic timer owns steady-state sampling. Only prime
                    // the baseline or react immediately to a topology change;
                    // otherwise the service refresh would add jittery,
                    // redundant samples between regular timer ticks.
                    if self.previousTrafficSampleDate == nil || servicesChanged {
                        self.sampleTraffic()
                    }
                    if self.diagnosticPending && !self.isDiagnosing {
                        self.runDiagnostics()
                    }
                    self.completeNetworkRefresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.networkStateGeneration else {
                        self.completeNetworkRefresh(retryingWith: showingErrors)
                        return
                    }
                    if !self.hasLoadedNetworkState {
                        self.hasLoadedNetworkState = true
                        self.initialRefreshError = error.localizedDescription
                        self.rebuildMenu(with: self.lastServices)
                        if self.mainWindow?.isVisible == true {
                            self.rebuildWindow(with: self.lastServices)
                        }
                    } else if self.lastSuccessfulRefreshAt != nil {
                        let firstStaleFailure = self.refreshFailureMessage == nil
                        self.refreshFailureMessage = error.localizedDescription
                        if firstStaleFailure {
                            self.rebuildMenu(with: self.lastServices)
                            if self.mainWindow?.isVisible == true {
                                self.rebuildWindow(with: self.lastServices)
                            }
                        } else {
                            self.updateOperationFeedbackDisplays()
                            self.updateStatusIcon(self.lastServices)
                        }
                    }
                    if showingErrors {
                        self.showError(error)
                    }
                    self.completeNetworkRefresh()
                }
            }
        }
    }

    private func completeNetworkRefresh(retryingWith retryShowsErrors: Bool? = nil) {
        let pendingShowsErrors = refreshRequests.finish()
        guard pendingShowsErrors != nil || retryShowsErrors != nil else { return }
        performRefresh(
            showingErrors: (pendingShowsErrors ?? false) || (retryShowsErrors ?? false)
        )
    }

    private var networkMutationIsActive: Bool {
        isApplyingServiceSwitch || isPerformingPrivilegedChange || isConfiguringPrivilegedAccess
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard networkMutationIsActive, let action = menuItem.action else { return true }
        let mutationActions: [Selector] = [
            #selector(toggleService(_:)), #selector(toggleWiFiPower(_:)),
            #selector(switchToService(_:)), #selector(showDNSSettingsMenu(_:)),
            #selector(setHighestPriorityMenu(_:)), #selector(renameNetworkService(_:)),
            #selector(applyProfileMenu(_:)), #selector(applySelectedProfile),
            #selector(saveCurrentProfile),
            #selector(showPriorityEditor), #selector(showJoinWiFi(_:)),
            #selector(showPrivilegedAccessSetup), #selector(removePrivilegedAccess)
        ]
        return !mutationActions.contains(action)
    }

    private func reportBusyNetworkOperation() {
        setOperationFeedback("请等待当前网络操作完成", color: .systemOrange, clearAfter: 2)
    }

    private func rebuildMenu(with services: [NetworkService]) {
        statusPanelServicesSnapshot = nil
        let menu = NSMenu()

        let connectedCount = services.filter(\.connected).count
        let primary = services.first(where: { $0.isPrimary && $0.connected })
        let summaryTitle: String
        if initialRefreshError != nil, services.isEmpty {
            summaryTitle = "读取网络状态失败"
        } else if let staleRefreshSummary {
            summaryTitle = "⚠︎ \(staleRefreshSummary)"
        } else {
            summaryTitle = primary.map { "当前：\($0.name)" + ($0.ipAddress.map { " · \($0)" } ?? "") }
                ?? (connectedCount > 0 ? "已连接 \(connectedCount) 个网络" : "当前没有已连接网络")
        }
        let summary = NSMenuItem(
            title: summaryTitle,
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        if services.isEmpty {
            let empty = NSMenuItem(
                title: initialRefreshError != nil
                    ? "请选择“刷新网络状态”重试"
                    : (refreshFailureMessage != nil ? "仍显示上次可信结果" : "未发现网络服务"),
                action: nil,
                keyEquivalent: ""
            )
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
        if statusPopover.isShown && !wifiPickerIsVisible {
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

        if NetworkServiceActionPolicy.offersSwitch(to: service) {
            let otherEnabledPhysicalServices = allServices.filter {
                $0.name != service.name && $0.enabled && $0.isPhysicalTransport
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
                    "order": allServices.sorted { $0.orderIndex < $1.orderIndex }.map(\.name),
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

        let accessReady = privilegedAccessState == .ready
        let accessItem = NSMenuItem(
            title: accessReady ? "免密码网络切换：已启用" : "配置免密码网络切换…",
            action: #selector(showPrivilegedAccessSetup),
            keyEquivalent: ""
        )
        accessItem.target = self
        accessItem.state = accessReady ? NSControl.StateValue.on : NSControl.StateValue.off
        settingsMenu.addItem(accessItem)

        let loginItemTitle = SMAppService.mainApp.status == .requiresApproval
            ? "取消等待登录项批准" : "登录时启动"
        let loginItem = NSMenuItem(title: loginItemTitle, action: #selector(toggleLaunchAtLoginMenu(_:)), keyEquivalent: "")
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
        if let initialRefreshError, services.isEmpty {
            statusItem.button?.toolTip = "LinkGlint · 读取失败 · \(initialRefreshError)"
            return
        }
        let baseToolTip = active.map {
            var text = "LinkGlint · 已连接 · \($0.name)"
            if let ssid = $0.ssid { text += " · \(ssid)" }
            if let ip = $0.ipAddress { text += " · \(ip)" }
            return text
        } ?? "LinkGlint · 离线 · 当前无网络连接"
        statusItem.button?.toolTip = refreshFailureMessage == nil
            ? baseToolTip : "\(baseToolTip) · 状态可能已过期"
    }

    @objc private func toggleStatusPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let click: StatusPanelClick = NSApp.currentEvent?.type == .rightMouseUp ? .right : .left
        switch StatusPanelInteraction.action(for: click, panelIsOpen: statusPanelIsOpen) {
        case .showContextMenu:
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            let applicationToRestore = statusPanelPreviousApplication
                ?? (frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    ? nil : frontmostApplication)
            closeStatusPanel()
            // Menu-item actions run synchronously inside `popUp`. Preserve the
            // app that owned focus so actions which open another popover or a
            // modal can restore it after their temporary UI is dismissed.
            statusPanelPreviousApplication = applicationToRestore
            button.highlight(true)
            statusContextMenu?.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 3),
                in: button
            )
            button.highlight(false)
            if !statusPanelIsOpen && !statusPopover.isShown {
                statusPanelPreviousApplication = nil
            }
            let linkGlintStillFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
            let hasVisibleAppWindow = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeKey
            }
            if linkGlintStillFrontmost, !hasVisibleAppWindow {
                restoreFrontmostApplication(applicationToRestore)
            }
        case .closePanel:
            closeStatusPanel(restoringPreviousApplication: true)
        case .openPanel:
            openStatusPanel(relativeTo: button)
        }
    }

    private func openStatusPanel(relativeTo button: NSStatusBarButton) {
        guard !statusPanelIsOpen else { return }
        if statusPopover.contentViewController == nil || statusPanelServicesSnapshot != lastServices {
            rebuildStatusPanel(with: lastServices)
        }
        statusPanelIsOpen = true
        button.highlight(true)
        button.setAccessibilityExpanded(true)
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        statusPanelPreviousApplication = frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        statusPopover.contentViewController?.view.window?.makeKey()
        updateUsageDisplay()
        installStatusPanelDismissalMonitors()
    }

    private func closeStatusPanel(restoringPreviousApplication shouldRestoreApplication: Bool = false) {
        guard statusPanelIsOpen || statusPopover.isShown else {
            removeStatusPanelDismissalMonitors()
            return
        }
        let applicationToRestore = shouldRestoreApplication ? statusPanelPreviousApplication : nil
        statusPanelPreviousApplication = nil
        statusPanelIsOpen = false
        statusItem.button?.highlight(false)
        statusItem.button?.setAccessibilityExpanded(false)
        removeStatusPanelDismissalMonitors()
        wifiScanGeneration &+= 1
        wifiScanActiveGeneration = nil
        wifiPendingScanRequest.cancel()
        wifiScanTimeoutWork?.cancel()
        wifiPendingScanTimeoutWork?.cancel()
        wifiPickerIsVisible = false
        wifiPickerController = nil
        statusPanelServicesSnapshot = nil
        statusPopover.performClose(nil)
        restoreFrontmostApplication(applicationToRestore)
    }

    private func restoreFrontmostApplication(_ application: NSRunningApplication?) {
        guard let application, !application.isTerminated else { return }
        DispatchQueue.main.async {
            // Do not steal focus back from a third app selected after the
            // panel began closing. Restoration is only needed while LinkGlint
            // itself still owns the foreground.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == ProcessInfo.processInfo.processIdentifier else { return }
            _ = application.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Captures the app behind a temporary panel before closing it for a modal
    /// alert. The caller restores the returned app with `defer`, after every
    /// validation/error path has finished presenting its own UI.
    private func prepareForStatusPanelModal() -> NSRunningApplication? {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let application = statusPanelPreviousApplication
            ?? (frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? nil : frontmostApplication)
        if statusPanelIsOpen || statusPopover.isShown {
            closeStatusPanel()
        }
        return application
    }

    /// Presents a modal without letting the panel's outside-click/resign
    /// monitors tear down the UI behind it. Keeping the panel alive also keeps
    /// its focus token available if the confirmed action immediately needs a
    /// second permission dialog.
    private func runModalKeepingStatusPanelOpen(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let wasKeepingPanelOpen = isKeepingStatusPanelOpenForModalInteraction
        isKeepingStatusPanelOpenForModalInteraction = true
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        isKeepingStatusPanelOpenForModalInteraction = wasKeepingPanelOpen
        return response
    }

    private func installStatusPanelDismissalMonitors() {
        removeStatusPanelDismissalMonitors()
        statusPanelLocalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if self.isKeepingStatusPanelOpenForModalInteraction { return event }
            if event.type == .keyDown {
                guard event.window === self.statusPopover.contentViewController?.view.window else {
                    return event
                }
                let isEscape = event.keyCode == 53
                let isCommandW = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                    && event.charactersIgnoringModifiers?.lowercased() == "w"
                if isEscape || isCommandW {
                    self.closeStatusPanel(restoringPreviousApplication: true)
                    return nil
                }
                return event
            }
            // Events without a window include status-item interactions. Let the
            // button's mouse-up action perform the toggle instead of racing it.
            guard let eventWindow = event.window else { return event }
            if eventWindow === self.statusPopover.contentViewController?.view.window
                || eventWindow.level == .popUpMenu
                || self.eventIsInsideStatusButton(event) {
                return event
            }
            self.closeStatusPanel()
            return event
        }
        statusPanelGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.isRequestingLocationAuthorization != true,
                      self?.isKeepingStatusPanelOpenForModalInteraction != true else { return }
                self?.closeStatusPanel()
            }
        }
        statusPanelResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard self?.isRequestingLocationAuthorization != true,
                  self?.isKeepingStatusPanelOpenForModalInteraction != true else { return }
            self?.closeStatusPanel()
        }
    }

    private func eventIsInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, event.window === button.window else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    private func removeStatusPanelDismissalMonitors() {
        if let monitor = statusPanelLocalEventMonitor {
            NSEvent.removeMonitor(monitor)
            statusPanelLocalEventMonitor = nil
        }
        if let monitor = statusPanelGlobalEventMonitor {
            NSEvent.removeMonitor(monitor)
            statusPanelGlobalEventMonitor = nil
        }
        if let observer = statusPanelResignObserver {
            NotificationCenter.default.removeObserver(observer)
            statusPanelResignObserver = nil
        }
    }

    private func rebuildStatusPanel(with services: [NetworkService]) {
        statusPanelServicesSnapshot = services
        let width = LinkGlintLayout.panelWidth
        let visibleRows = min(max(services.count, 1), 5)
        let rowViewportHeight = CGFloat(visibleRows) * LinkGlintLayout.panelRowHeight
            + CGFloat(max(visibleRows - 1, 0)) * LinkGlintLayout.compactGap
        let permissionHeight: CGFloat = privilegedAccessState == .ready ? 0 : 30
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
        sectionCount.lineBreakMode = .byTruncatingTail
        sectionCount.maximumNumberOfLines = 1
        sectionCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            let emptyText = initialRefreshError != nil
                ? "读取失败，请点击右上角刷新按钮重试"
                : (refreshFailureMessage != nil
                    ? "状态可能已过期，请点击右上角刷新"
                    : (hasLoadedNetworkState ? "未发现网络服务" : "正在读取网络状态…"))
            let empty = NSTextField(labelWithString: emptyText)
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
        rates.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
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
        let download = "● ↓ \(fixedWidthRate(currentDownloadBytesPerSecond))"
        let upload = "● ↑ \(fixedWidthRate(currentUploadBytesPerSecond))"
        let result = NSMutableAttributedString(
            string: "\(download)   \(upload)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
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
        if NetworkServiceActionPolicy.offersSwitch(to: service) {
            let use = NetworkActionButton(title: "切换", target: self, action: #selector(windowSwitchToService(_:)))
            use.bezelStyle = .rounded
            use.controlSize = .small
            use.payload = [
                "target": service.name,
                "order": allServices.sorted { $0.orderIndex < $1.orderIndex }.map(\.name),
                "wifiDevice": service.kind == .wifi ? (service.device ?? "") : ""
            ]
            use.setAccessibilityLabel("切换到 \(service.name)")
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
            priority.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
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
        if privilegedAccessState != .ready {
            let permission = NSTextField(labelWithString: "部分操作需要更新网络权限")
            permission.font = .systemFont(ofSize: 10.5, weight: .medium)
            permission.textColor = .systemOrange
            let permissionSpacer = NSView()
            permissionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let repair = NSButton(title: "修复…", target: self, action: #selector(showPrivilegedAccessSetup))
            repair.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
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
        case .cellular: return "移动网络"
        case .vpn: return "VPN"
        case .other: return "其他"
        }
    }

    private func statusColor(for kind: NetworkService.Kind) -> NSColor {
        switch kind {
        case .wifi: return .systemBlue
        case .ethernet: return .systemTeal
        case .cellular: return .systemIndigo
        case .vpn: return .systemPurple
        case .other: return .systemGray
        }
    }

    private func schedulePathRefresh() {
        pendingPathRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performRefresh(showingErrors: false)
            let uptime = ProcessInfo.processInfo.systemUptime
            let diagnosticIntervalElapsed = self.lastAutoDiagnosticUptime.map {
                uptime < $0 || uptime - $0 >= 30
            } ?? true
            if self.preferences.autoRunDiagnostics, diagnosticIntervalElapsed {
                self.lastAutoDiagnosticUptime = uptime
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.runDiagnostics()
                }
            }
        }
        pendingPathRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    @objc private func sampleTraffic() {
        guard !isSamplingTraffic, !networkMutationIsActive else { return }
        isSamplingTraffic = true
        let generation = trafficSampleGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let counters = try? self.manager.fetchTrafficCounters()
            let sampleDate = Date()
            let sampleUptime = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.isSamplingTraffic = false
                guard generation == self.trafficSampleGeneration else {
                    self.sampleTraffic()
                    return
                }
                guard let counters else { return }
                if let previousUptime = self.previousTrafficSampleUptime {
                    // A monotonic clock is immune to manual time changes and
                    // time-zone adjustments that otherwise create rate spikes.
                    let interval = max(sampleUptime - previousUptime, 0.1)
                    let sample = TrafficSampleCalculator.calculate(
                        previous: self.previousTrafficCounters,
                        current: counters,
                        services: self.lastServices
                    )
                    for (device, delta) in sample.deltasByDevice {
                        if self.mainWindow?.isVisible == true, let labels = self.trafficLabels[device] {
                            let text = "↓ \(self.fixedWidthRate(Double(delta.receivedBytes) / interval))  ↑ \(self.fixedWidthRate(Double(delta.sentBytes) / interval))"
                            for label in labels where label.stringValue != text {
                                label.stringValue = text
                            }
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
                    if self.statusPanelIsOpen {
                        if let label = self.statusPanelTrafficRatesLabel {
                            let text = self.statusPanelTrafficRateText
                            if !label.attributedStringValue.isEqual(to: text) {
                                label.attributedStringValue = text
                            }
                        }
                        self.statusPanelTrafficChart?.samples = self.trafficRateHistory.samples
                    }
                    self.updateUsageDisplay()
                    self.applyMenuBarAppearance()
                }
                self.previousTrafficCounters = counters
                self.previousTrafficSampleDate = sampleDate
                self.previousTrafficSampleUptime = sampleUptime
            }
        }
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        TrafficRateFormatter.string(bytesPerSecond: bytesPerSecond, usesBits: false)
    }

    private func fixedWidthRate(_ bytesPerSecond: Double) -> String {
        TrafficRateFormatter.fixedWidthString(
            bytesPerSecond: bytesPerSecond,
            usesBits: false
        )
    }

    private func scheduleTrafficTimer() {
        trafficTimer?.invalidate()
        let trafficTimer = Timer(timeInterval: preferences.trafficRefreshInterval, repeats: true) { [weak self] _ in
            self?.sampleTraffic()
        }
        trafficTimer.tolerance = min(preferences.trafficRefreshInterval * 0.1, 0.2)
        self.trafficTimer = trafficTimer
        RunLoop.main.add(trafficTimer, forMode: .common)
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
        let networkPresentation = currentNetworkPresentation
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
        // Accessibility follows the latest network state even when the visual
        // render key is unchanged (for example, icon-only mode switching
        // between two Wi-Fi networks that use the same symbol).
        let accessibleDownload = TrafficRateFormatter.string(
            bytesPerSecond: currentDownloadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        let accessibleUpload = TrafficRateFormatter.string(
            bytesPerSecond: currentUploadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        button.setAccessibilityLabel("LinkGlint · \(menuBarStatusTitle) · 下载 \(accessibleDownload) · 上传 \(accessibleUpload)")
        guard renderKey != lastMenuBarRenderKey else { return }
        lastMenuBarRenderKey = renderKey
        lastRenderedMenuBarPresentation = presentation
        if presentation.usesTwoLines {
            lastStandaloneMenuBarSymbolName = nil
            if button.attributedTitle.length != 0 {
                button.attributedTitle = NSAttributedString(string: "")
            }
            button.image = twoLineMenuBarImage(
                symbolName: renderState.symbolName,
                text: presentation.text,
                indicatorStyle: indicatorStyle,
                appearance: button.effectiveAppearance
            )
            if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
            if button.imageScaling != .scaleNone { button.imageScaling = .scaleNone }
            // The rendered image already contains the icon box and its text
            // spacing. Adding another status-item inset here leaves a visible
            // empty block before the next macOS menu-bar item.
            let targetLength = max(
                NSStatusItem.squareLength,
                ceil(button.image?.size.width ?? NSStatusItem.squareLength)
            )
            if abs(statusItem.length - targetLength) > 0.5 {
                statusItem.length = targetLength
            }
        } else {
            let stableText = MenuBarSingleLineLayout.stabilizedText(presentation.text)
            let title = menuBarAttributedTitle(stableText, indicatorStyle: indicatorStyle)
            if !button.attributedTitle.isEqual(to: title) {
                button.attributedTitle = title
            }
            if lastStandaloneMenuBarSymbolName != renderState.symbolName {
                button.image = menuBarImage(
                    symbolName: renderState.symbolName,
                    accessibilityDescription: networkPresentation.title
                )
                lastStandaloneMenuBarSymbolName = renderState.symbolName
            }
            let targetPosition: NSControl.ImagePosition = showsText ? .imageLeading : .imageOnly
            if button.imagePosition != targetPosition { button.imagePosition = targetPosition }
            if button.imageScaling != .scaleProportionallyDown {
                button.imageScaling = .scaleProportionallyDown
            }
            let targetLength = showsText ? NSStatusItem.variableLength : NSStatusItem.squareLength
            if statusItem.length != targetLength { statusItem.length = targetLength }
        }
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
        // Units participate in the fixed-width rate columns as well as digits.
        // A digit-only monospaced font still lets B/K/M/G glyph widths move the
        // neighbouring menu-bar items when the unit changes.
        let bottomFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
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
        let usesBits = representativeRate?.unit.hasSuffix("bps") == true
        let unitSamples = usesBits
            ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
            : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let valueWidth: CGFloat
        if let cachedWidth = menuBarRateColumnWidths[usesBits] {
            valueWidth = cachedWidth
        } else {
            let valueSamples = ["0", "9.9", "10", "999"].flatMap { number in
                unitSamples.map { "\(number) \($0)" }
            }
            valueWidth = valueSamples.map {
                ceil(($0 as NSString).size(withAttributes: bottomAttributes).width)
            }.max() ?? 0
            menuBarRateColumnWidths[usesBits] = valueWidth
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
                let topLineX = textX + geometry.centeredX(contentWidth: topWidth)

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
        let speedFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let range = NSRange(location: 0, length: result.length)
        Self.menuBarSpeedSegmentExpression?.enumerateMatches(in: result.string, range: range) { match, _, _ in
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

    func popoverWillClose(_ notification: Notification) {
        wifiScanGeneration &+= 1
        wifiScanActiveGeneration = nil
        wifiPendingScanRequest.cancel()
        wifiScanTimeoutWork?.cancel()
        wifiPendingScanTimeoutWork?.cancel()
        wifiPickerIsVisible = false
        wifiPickerController = nil
        statusPanelServicesSnapshot = nil
        statusPanelIsOpen = false
        statusPanelPreviousApplication = nil
        statusItem.button?.highlight(false)
        statusItem.button?.setAccessibilityExpanded(false)
        removeStatusPanelDismissalMonitors()
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
        currentNetworkPresentation.title
    }

    private var currentNetworkPresentation: NetworkStatusPresentation {
        if initialRefreshError != nil, lastServices.isEmpty {
            return .init(title: "读取失败", symbolName: "exclamationmark.triangle")
        }
        return NetworkStatusPresentation.make(services: lastServices, hasLoaded: hasLoadedNetworkState)
    }

    private func symbol(for service: NetworkService) -> NSImage? {
        let name: String
        switch service.kind {
        case .wifi: name = service.enabled ? "wifi" : "wifi.slash"
        case .ethernet: name = "cable.connector"
        case .cellular: name = "antenna.radiowaves.left.and.right"
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
              let currentOrder = data["order"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }

        performServiceSwitch(
            target: target,
            currentOrder: currentOrder,
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
        let input = NSTextField(string: "")
        input.placeholderString = "留空 = 自动，例如 1.1.1.1, 8.8.8.8"
        input.stringValue = currentServers.joined(separator: ", ")
        alert.accessoryView = AlertAccessoryView(width: 380, height: 26, content: input)
        alert.window.initialFirstResponder = input
        guard runModalKeepingStatusPanelOpen(alert) == .alertFirstButtonReturn else { return }

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
        presentWiFiPicker(device: device)
    }

    private func presentWiFiPicker(device: String) {
        if statusPanelPreviousApplication == nil,
           let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            statusPanelPreviousApplication = frontmostApplication
        }
        NSApp.activate(ignoringOtherApps: true)
        wifiPickerDevice = device

        let picker = WiFiPickerViewController()
        picker.onRefresh = { [weak self] in self?.beginWiFiScan() }
        picker.onDismiss = { [weak self] in self?.restoreStatusPanelFromWiFiPicker() }
        picker.onSuspendScan = { [weak self] in
            guard let self else { return }
            self.wifiScanGeneration &+= 1
            self.wifiScanActiveGeneration = nil
            self.wifiPendingScanRequest.cancel()
            self.wifiScanTimeoutWork?.cancel()
            self.wifiPendingScanTimeoutWork?.cancel()
        }
        picker.onOpenLocationSettings = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
            NSWorkspace.shared.open(url)
        }
        picker.onConnect = { [weak self] ssid, password, isSecure in
            self?.connectToWiFi(
                device: device,
                ssid: ssid,
                password: password,
                isSecure: isSecure
            )
        }
        wifiPickerController = picker
        wifiPickerIsVisible = true
        statusPopover.contentViewController = picker
        statusPopover.contentSize = NSSize(width: 360, height: 380)
        if !statusPopover.isShown, let button = statusItem.button {
            statusPanelIsOpen = true
            button.highlight(true)
            button.setAccessibilityExpanded(true)
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            statusPopover.contentViewController?.view.window?.makeKey()
            installStatusPanelDismissalMonitors()
        }
        picker.showLoading()
        prepareWiFiScan()
    }

    private func restoreStatusPanelFromWiFiPicker() {
        wifiScanGeneration &+= 1
        wifiScanActiveGeneration = nil
        wifiPendingScanRequest.cancel()
        wifiScanTimeoutWork?.cancel()
        wifiPendingScanTimeoutWork?.cancel()
        wifiPickerIsVisible = false
        wifiPickerController = nil
        rebuildStatusPanel(with: lastServices)
    }

    private func prepareWiFiScan() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            wifiPickerController?.showLocationRequest()
            isRequestingLocationAuthorization = true
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            beginWiFiScan()
        case .denied, .restricted:
            wifiPickerController?.showLocationDenied()
        @unknown default:
            wifiPickerController?.showLocationDenied()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        isRequestingLocationAuthorization = false
        guard statusPopover.isShown, wifiPickerIsVisible else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            beginWiFiScan()
        case .denied, .restricted:
            wifiPickerController?.showLocationDenied()
        case .notDetermined:
            break
        @unknown default:
            wifiPickerController?.showLocationDenied()
        }
    }

    private func beginWiFiScan() {
        guard let device = wifiPickerDevice, statusPopover.isShown, wifiPickerIsVisible else { return }
        if lastServices.first(where: { $0.device == device })?.wifiPowered == false {
            wifiPickerController?.showError("Wi-Fi 当前已关闭，请先在网络服务列表中打开 Wi-Fi。")
            return
        }
        guard locationManager.authorizationStatus == .authorizedAlways else {
            prepareWiFiScan()
            return
        }

        if wifiScanWorkerIsActive {
            let pendingToken = wifiPendingScanRequest.enqueue()
            wifiPickerController?.showWaitingForCurrentScan()
            if let pendingToken {
                let pendingTimeout = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.wifiPendingScanRequest.expire(token: pendingToken),
                          self.statusPopover.isShown,
                          self.wifiPickerIsVisible,
                          self.wifiPickerDevice == device else { return }
                    // CoreWLAN cannot cancel the worker. Invalidate its result
                    // and release the UI after a bounded wait instead of
                    // leaving Retry on an endless loading screen.
                    self.wifiScanActiveGeneration = nil
                    self.wifiScanGeneration &+= 1
                    self.wifiPickerController?.showError(
                        "上一次 Wi-Fi 扫描仍未结束。你可以稍后重试，或手动输入网络名称。"
                    )
                }
                wifiPendingScanTimeoutWork?.cancel()
                wifiPendingScanTimeoutWork = pendingTimeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: pendingTimeout)
            }
            return
        }

        wifiPendingScanRequest.cancel()
        wifiPendingScanTimeoutWork?.cancel()
        wifiScanGeneration &+= 1
        let generation = wifiScanGeneration
        wifiScanActiveGeneration = generation
        wifiScanWorkerIsActive = true
        let currentSSID = lastServices.first(where: { $0.device == device })?.ssid
        wifiPickerController?.showLoading()
        wifiScanTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.wifiScanActiveGeneration == generation else { return }
            self.wifiScanActiveGeneration = nil
            self.wifiScanGeneration &+= 1
            // The CoreWLAN call itself cannot be cancelled. Keep the real
            // worker occupied until it returns; Retry only records one pending
            // scan instead of stacking more blocked operations.
            let hasPendingRetry = self.wifiPendingScanRequest.isPending
                && self.statusPopover.isShown && self.wifiPickerIsVisible
            if !hasPendingRetry {
                self.wifiPickerController?.showError("扫描附近网络超时，请稍后重试。")
            }
        }
        wifiScanTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        wifiScanQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.manager.scanWiFiNetworks(device: device, currentSSID: currentSSID) }
            DispatchQueue.main.async {
                self.wifiScanWorkerIsActive = false
                self.wifiScanTimeoutWork?.cancel()
                self.wifiPendingScanTimeoutWork?.cancel()
                let resultIsCurrent = self.wifiScanActiveGeneration == generation
                    && self.statusPopover.isShown
                    && self.wifiPickerIsVisible
                    && self.wifiPickerDevice == device
                    && self.wifiScanGeneration == generation
                if self.wifiScanActiveGeneration == generation {
                    self.wifiScanActiveGeneration = nil
                }
                let hadPendingRetry = self.wifiPendingScanRequest.consume()
                let shouldRepeat = hadPendingRetry
                    && self.statusPopover.isShown
                    && self.wifiPickerIsVisible
                if shouldRepeat {
                    self.beginWiFiScan()
                    return
                }
                guard resultIsCurrent else { return }
                switch result {
                case .success(let scan):
                    self.wifiPickerController?.showNetworks(scan.networks, currentSSID: scan.currentSSID)
                case .failure(let error):
                    self.wifiPickerController?.showError(error.localizedDescription)
                }
            }
        }
    }

    private func connectToWiFi(device: String, ssid: String, password: String?, isSecure: Bool) {
        wifiScanGeneration &+= 1
        wifiScanActiveGeneration = nil
        wifiPendingScanRequest.cancel()
        wifiScanTimeoutWork?.cancel()
        wifiPendingScanTimeoutWork?.cancel()
        wifiPickerController?.showConnecting(to: ssid)
        performPrivilegedChange(
            description: "连接 Wi-Fi：\(ssid)",
            requiresPrivilegedAccess: password == nil,
            onAuthorizationDeferred: { [weak self] in
                guard let self, self.statusPopover.isShown, self.wifiPickerIsVisible else { return }
                self.wifiPickerController?.showConnectionError(
                    ssid: ssid,
                    password: password,
                    isSecure: isSecure,
                    message: "连接尚未开始，请先完成一次网络权限配置后重试。"
                )
            },
            onSuccess: { [weak self] in
                guard let self,
                      self.statusPopover.isShown,
                      self.wifiPickerIsVisible else { return }
                self.closeStatusPanel(restoringPreviousApplication: true)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                if self.statusPopover.isShown, self.wifiPickerIsVisible {
                    self.wifiPickerController?.showConnectionError(
                        ssid: ssid,
                        password: password,
                        isSecure: isSecure,
                        message: error.localizedDescription
                    )
                } else {
                    self.showError(error)
                }
            }
        ) { [manager] in
            try manager.joinWiFi(device: device, networkName: ssid, password: password)
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
        alert.accessoryView = AlertAccessoryView(width: 340, height: 26, content: input)
        alert.window.initialFirstResponder = input
        input.selectText(nil)
        guard runModalKeepingStatusPanelOpen(alert) == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        performPrivilegedChange(
            description: "重命名 \(oldName)",
            onSuccess: { [weak self] in
                self?.profileStore.renameService(from: oldName, to: newName)
                self?.updateProfilePopup()
            }
        ) { [manager] in
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
        let serviceNamesAtOpen = Set(currentOrder)
        let editor = PriorityOrderEditorController(services: lastServices)
        _ = editor.view

        let alert = NSAlert()
        alert.messageText = "调整网络服务优先级"
        alert.informativeText = "macOS 会优先尝试列表靠前的服务。拖动完成后点击“应用顺序”。"
        alert.addButton(withTitle: "应用顺序")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = editor.view
        guard runModalKeepingStatusPanelOpen(alert) == .alertFirstButtonReturn else { return }

        let latestOrder = lastServices.sorted { $0.orderIndex < $1.orderIndex }.map(\.name)
        guard Set(lastServices.map(\.name)) == serviceNamesAtOpen,
              latestOrder == currentOrder else {
            showError(NetworkError.commandFailed("网络服务列表或优先级已变化，请重新打开优先级编辑器。"))
            return
        }

        let newOrder = editor.orderedServiceNames
        guard newOrder != currentOrder else { return }
        performPrivilegedChange(description: "更新网络服务优先级") { [manager] in
            try manager.setServiceOrder(newOrder)
        }
    }

    private func updateOperationFeedbackDisplays() {
        if let operationFeedback {
            updateSummaryLabel(statusPanelSummaryLabel, text: operationFeedback.text, color: operationFeedback.color)
            updateSummaryLabel(adapterSummaryLabel, text: operationFeedback.text, color: operationFeedback.color)
            updateNetworkControlAvailability()
            return
        }

        if let staleRefreshSummary {
            updateSummaryLabel(statusPanelSummaryLabel, text: staleRefreshSummary, color: .systemOrange)
            updateSummaryLabel(adapterSummaryLabel, text: staleRefreshSummary, color: .systemOrange)
            updateNetworkControlAvailability()
            return
        }

        let connectedCount = lastServices.filter(\.connected).count
        let enabledCount = lastServices.filter(\.enabled).count
        updateSummaryLabel(
            statusPanelSummaryLabel,
            text: "\(connectedCount) 个已连接 · \(enabledCount) 个已启用",
            color: .secondaryLabelColor
        )
        updateSummaryLabel(
            adapterSummaryLabel,
            text: "\(lastServices.count) 个服务 · \(connectedCount) 个已连接 · \(enabledCount) 个已启用",
            color: .secondaryLabelColor
        )
        updateNetworkControlAvailability()
    }

    private func updateSummaryLabel(_ label: NSTextField?, text: String, color: NSColor) {
        label?.stringValue = text
        label?.textColor = color
        label?.toolTip = text
    }

    private var staleRefreshSummary: String? {
        guard refreshFailureMessage != nil else { return nil }
        guard let lastSuccessfulRefreshAt else { return "状态可能已过期 · 点击刷新" }
        let time = DateFormatter.localizedString(
            from: lastSuccessfulRefreshAt,
            dateStyle: .none,
            timeStyle: .short
        )
        return "状态可能已过期 · 上次更新 \(time)"
    }

    private func updateNetworkControlAvailability() {
        let enabled = !isPerformingPrivilegedChange
            && !isApplyingServiceSwitch
            && !isConfiguringPrivilegedAccess
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "停用正在使用的“\(name)”？"
        alert.informativeText = "当前连接可能立即中断；只有其他已启用的网络可用时，macOS 才能自动接替。"
        alert.addButton(withTitle: "停用")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        return runModalKeepingStatusPanelOpen(alert) == .alertFirstButtonReturn
    }

    private func confirmPoweringOffActiveWiFi(device: String) -> Bool {
        guard lastServices.contains(where: { $0.device == device && $0.kind == .wifi && $0.connected }) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭正在使用的 Wi‑Fi？"
        alert.informativeText = "无线连接会立即中断；只有其他已启用的网络可用时，macOS 才能自动接替。"
        alert.addButton(withTitle: "关闭 Wi‑Fi")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        return runModalKeepingStatusPanelOpen(alert) == .alertFirstButtonReturn
    }

    private func performPrivilegedChange(
        description: String,
        optimisticServices: [NetworkService]? = nil,
        requiresPrivilegedAccess: Bool = true,
        onAuthorizationDeferred: (() -> Void)? = nil,
        onSuccess: (() -> Void)? = nil,
        onFailure: ((Error) -> Void)? = nil,
        operation: @escaping () throws -> Void
    ) {
        guard !requiresPrivilegedAccess || privilegedAccessState == .ready else {
            // A switch control changes its visual state before sending its
            // action. Restore the model-backed UI if setup is postponed so it
            // cannot remain stuck showing a change that never happened.
            rebuildMenu(with: lastServices)
            if mainWindow?.isVisible == true { rebuildWindow(with: lastServices) }
            configurePrivilegedAccess(
                afterConfiguration: { [weak self] in
                    self?.performPrivilegedChange(
                        description: description,
                        optimisticServices: optimisticServices,
                        requiresPrivilegedAccess: requiresPrivilegedAccess,
                        onAuthorizationDeferred: onAuthorizationDeferred,
                        onSuccess: onSuccess,
                        onFailure: onFailure,
                        operation: operation
                    )
                },
                onUnavailable: onAuthorizationDeferred
            )
            return
        }
        guard !isPerformingPrivilegedChange,
              !isApplyingServiceSwitch,
              !isConfiguringPrivilegedAccess else {
            reportBusyNetworkOperation()
            return
        }

        isPerformingPrivilegedChange = true
        let rollbackServices = lastServices
        networkStateGeneration &+= 1
        invalidateDiagnosticResult()
        if let optimisticServices, optimisticServices != lastServices {
            resetTrafficSampling()
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
                    onSuccess?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.performRefresh(showingErrors: false)
                    }
                }
            } catch {
                let accessState = self.manager.privilegedAccessState
                DispatchQueue.main.async {
                    self.isPerformingPrivilegedChange = false
                    self.privilegedAccessState = accessState
                    self.updatePrivilegedAccessControls()
                    if optimisticServices != nil {
                        self.networkStateGeneration &+= 1
                        self.lastServices = rollbackServices
                        self.rebuildMenu(with: rollbackServices)
                        if self.mainWindow?.isVisible == true { self.rebuildWindow(with: rollbackServices) }
                    }
                    self.clearOperationFeedback()
                    self.performRefresh(showingErrors: false)
                    if let onFailure {
                        onFailure(error)
                    } else {
                        self.showError(error)
                    }
                }
            }
        }
    }

    private func performServiceSwitch(target: String, currentOrder: [String], wifiDevice: String?) {
        guard privilegedAccessState == .ready else {
            configurePrivilegedAccess(afterConfiguration: { [weak self] in
                self?.performServiceSwitch(target: target, currentOrder: currentOrder, wifiDevice: wifiDevice)
            })
            return
        }
        guard !isApplyingServiceSwitch,
              !isPerformingPrivilegedChange,
              !isConfiguringPrivilegedAccess else {
            reportBusyNetworkOperation()
            return
        }

        isApplyingServiceSwitch = true
        let rollbackServices = lastServices
        applyOptimisticServiceSwitch(target: target)
        setOperationFeedback("正在切换到 \(target)…", color: .systemOrange)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.manager.switchToService(target, currentOrder: currentOrder, wifiDevice: wifiDevice)
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
                let accessState = self.manager.privilegedAccessState
                DispatchQueue.main.async {
                    self.isApplyingServiceSwitch = false
                    self.privilegedAccessState = accessState
                    self.updatePrivilegedAccessControls()
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

    private func applyOptimisticServiceSwitch(target: String) {
        let services = NetworkServiceTransition.switching(
            services: lastServices,
            target: target
        )
        // Invalidate an already-running refresh even when the target was
        // already enabled and the optimistic snapshot is otherwise identical.
        networkStateGeneration &+= 1
        invalidateDiagnosticResult()
        resetTrafficSampling()
        applyMenuBarAppearance()
        guard services != lastServices else { return }
        currentDownloadBytesPerSecond = 0
        currentUploadBytesPerSecond = 0
        lastServices = services
        rebuildMenu(with: services)
        if mainWindow?.isVisible == true { rebuildWindow(with: services) }
    }

    @objc private func showPrivilegedAccessSetup() {
        configurePrivilegedAccess(afterConfiguration: nil)
    }

    private func configurePrivilegedAccess(
        afterConfiguration: (() -> Void)?,
        onUnavailable: (() -> Void)? = nil
    ) {
        guard !isConfiguringPrivilegedAccess,
              !isPerformingPrivilegedChange,
              !isApplyingServiceSwitch else {
            reportBusyNetworkOperation()
            onUnavailable?()
            return
        }
        // Periodic background refreshes own the potentially slow helper
        // validation. Use the latest resolved UI snapshot here so a click can
        // never block the main thread on sudo status probes.
        let currentState = privilegedAccessState
        privilegedAccessState = currentState
        if currentState == .ready {
            if let afterConfiguration {
                afterConfiguration()
                return
            }
            let alert = NSAlert()
            alert.messageText = "免密码网络切换已启用"
            alert.informativeText = "受限权限助手已完成配置。启用、停用、切换网络、DNS 和优先级调整都不会再次询问密码。登录时启动使用 macOS 原生登录项，与此权限独立。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            isKeepingStatusPanelOpenForModalInteraction = true
            alert.runModal()
            isKeepingStatusPanelOpenForModalInteraction = false
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = currentState == .needsRepair ? "修复免密码网络权限" : "首次配置免密码网络切换"
        alert.informativeText = "下一步会显示一次 macOS 管理员授权。LinkGlint 将安装只允许网络设置操作的本机助手；完成后，日常网络修改不再输入密码。登录时启动无需此权限。"
        alert.addButton(withTitle: currentState == .needsRepair ? "修复权限" : "开始配置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        isKeepingStatusPanelOpenForModalInteraction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            isKeepingStatusPanelOpenForModalInteraction = false
            onUnavailable?()
            return
        }

        accessStatusLabel?.stringValue = "正在等待 macOS 完成一次管理员授权…"
        accessActionButton?.isEnabled = false
        isConfiguringPrivilegedAccess = true
        networkStateGeneration &+= 1
        updateNetworkControlAvailability()
        updatePrivilegedAccessControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: Result<PrivilegedAccessState, Error>
            do {
                try self.manager.configurePrivilegedAccess()
                result = .success(self.manager.privilegedAccessState)
            } catch {
                result = .failure(error)
            }
            // Resolve failure state off the main thread as well. A cache miss
            // may invoke sudo status and must not freeze AppKit while an error
            // alert is being prepared.
            let resolvedState = self.manager.privilegedAccessState
            DispatchQueue.main.async {
                self.isConfiguringPrivilegedAccess = false
                switch result {
                case .success(let state):
                    self.privilegedAccessState = state
                    self.updatePrivilegedAccessControls()
                    if !self.lastServices.isEmpty { self.rebuildMenu(with: self.lastServices) }

                    let success = NSAlert()
                    success.alertStyle = .informational
                    success.messageText = "配置完成"
                    success.informativeText = "之后启用、停用或切换网络将直接执行，不再显示密码窗口。登录时启动由 macOS 原生登录项单独管理。"
                    success.addButton(withTitle: "完成")
                    success.runModal()
                    afterConfiguration?()
                    self.isKeepingStatusPanelOpenForModalInteraction = false
                case .failure(let error):
                    self.privilegedAccessState = resolvedState
                    self.updatePrivilegedAccessControls()
                    onUnavailable?()
                    // A caller such as the Wi-Fi picker has restored a detailed
                    // retry form. Keep that UI in place instead of immediately
                    // closing it again for a generic alert.
                    if onUnavailable == nil {
                        self.showError(error)
                    }
                    self.isKeepingStatusPanelOpenForModalInteraction = false
                }
                self.performRefresh(showingErrors: false)
            }
        }
    }

    @objc private func removePrivilegedAccess() {
        guard !isPerformingPrivilegedChange, !isApplyingServiceSwitch, !isConfiguringPrivilegedAccess else {
            reportBusyNetworkOperation()
            return
        }
        let currentState = privilegedAccessState
        privilegedAccessState = currentState
        guard currentState != .notConfigured else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除免密码网络权限？"
        alert.informativeText = "移除会再显示一次管理员授权。之后再次修改网络时，需要重新完成首次配置。"
        alert.addButton(withTitle: "移除")
        alert.buttons.first?.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isConfiguringPrivilegedAccess = true
        networkStateGeneration &+= 1
        updateNetworkControlAvailability()
        updatePrivilegedAccessControls()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: Result<PrivilegedAccessState, Error>
            do {
                try self.manager.removePrivilegedAccess()
                result = .success(self.manager.privilegedAccessState)
            } catch {
                result = .failure(error)
            }
            let resolvedState = self.manager.privilegedAccessState
            DispatchQueue.main.async {
                self.isConfiguringPrivilegedAccess = false
                switch result {
                case .success(let state):
                    self.privilegedAccessState = state
                    self.updatePrivilegedAccessControls()
                    if !self.lastServices.isEmpty { self.rebuildMenu(with: self.lastServices) }
                case .failure(let error):
                    self.privilegedAccessState = resolvedState
                    self.updatePrivilegedAccessControls()
                    self.showError(error)
                }
                self.performRefresh(showingErrors: false)
            }
        }
    }

    private func updatePrivilegedAccessControls() {
        let state = privilegedAccessState
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
            accessDetailLabel?.stringValue = "只需一次管理员授权，之后切换适配器、DNS 和优先级均免密码"
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
        if isConfiguringPrivilegedAccess {
            accessStatusLabel?.stringValue = "正在等待 macOS 完成管理员授权…"
            privilegePreferenceLabel?.stringValue = "正在更新网络权限…"
            accessActionButton?.isEnabled = false
            privilegePreferenceButton?.isEnabled = false
            removePrivilegeButton?.isEnabled = false
        }
        updateNetworkControlAvailability()
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
        let status = SMAppService.mainApp.status
        // A pending approval is already registered. Selecting the mixed-state
        // item again should cancel it rather than submit the same request.
        setLaunchAtLogin(status != .enabled && status != .requiresApproval)
    }

    @objc private func toggleLaunchAtLoginButton(_ sender: NSButton) {
        if SMAppService.mainApp.status == .requiresApproval {
            setLaunchAtLogin(false)
        } else {
            setLaunchAtLogin(sender.state == .on)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                switch status {
                case .notRegistered:
                    try SMAppService.mainApp.register()
                case .enabled, .requiresApproval:
                    break
                case .notFound:
                    throw NetworkError.commandFailed(
                        "macOS 未找到可注册的应用副本。请先将 LinkGlint.app 放入“应用程序”文件夹，再重新打开并启用登录启动。"
                    )
                @unknown default:
                    throw NetworkError.commandFailed("登录项状态暂时不可用，请稍后重试。")
                }
            } else {
                switch status {
                case .enabled, .requiresApproval:
                    try SMAppService.mainApp.unregister()
                case .notRegistered, .notFound:
                    break
                @unknown default:
                    break
                }
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
        statusContextLoginItem?.title = loginItemState == .mixed
            ? "取消等待登录项批准" : "登录时启动"
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
        let plan: NetworkProfileApplicationPlan?
        if ["__all__", "__wifi__", "__ethernet__"].contains(token) {
            plan = NetworkProfileApplicationPlanner.builtIn(token: token, services: lastServices)
        } else if token.hasPrefix("profile:"),
                  let id = UUID(uuidString: String(token.dropFirst("profile:".count))),
                  let profile = profileStore.profile(id: id) {
            plan = NetworkProfileApplicationPlanner.custom(profile, services: lastServices)
        } else {
            plan = nil
        }

        guard let plan else {
            let detail: String
            switch token {
            case "__wifi__": detail = "当前没有可用的 Wi-Fi 网络服务。"
            case "__ethernet__": detail = "当前没有可用的有线网络服务。"
            default: detail = "方案需要的网络服务当前不可用，请重新连接设备或保存新方案。"
            }
            showError(NetworkError.commandFailed(detail))
            return
        }
        let skippedSuffix = plan.skippedUnavailableItems > 0
            ? "（忽略 \(plan.skippedUnavailableItems) 个已停用且当前不可用的项目）" : ""
        let leavesPhysicalServiceEnabled = NetworkProfileApplicationPlanner.leavesPhysicalTransportEnabled(
            plan,
            services: lastServices
        )
        if !leavesPhysicalServiceEnabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "应用后将停用所有物理网络"
            alert.informativeText = "方案“\(plan.title)”不会保留 Wi-Fi、有线或移动网络连接。"
            alert.addButton(withTitle: "仍要应用")
            alert.buttons.first?.hasDestructiveAction = true
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let readinessServices = NetworkProfileApplicationPlanner.readinessServiceNames(
            plan,
            services: lastServices
        )
        performPrivilegedChange(
            description: "应用配置方案：\(plan.title)\(skippedSuffix)",
            onFailure: { [weak self] error in
                self?.showError(
                    NetworkError.commandFailed(
                        "\(error.localizedDescription) 系统可能已完成部分更改，LinkGlint 正在重新读取真实状态。"
                    )
                )
            }
        ) { [manager] in
            try manager.applyProfile(
                serviceStates: plan.serviceStates,
                wifiPowerStates: plan.wifiPowerStates,
                readinessServices: readinessServices
            )
        }
    }

    @objc private func saveCurrentProfile() {
        guard !networkMutationIsActive else {
            reportBusyNetworkOperation()
            return
        }
        guard !lastServices.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "保存当前网络配置"
        alert.informativeText = "以后可从主窗口或菜单栏一键恢复所有网络服务和 Wi-Fi 电源状态。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(string: "")
        input.placeholderString = "例如：办公室、家庭、仅扩展坞"
        alert.accessoryView = AlertAccessoryView(width: 340, height: 26, content: input)
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let states = Dictionary(
            lastServices.map { ($0.name, $0.enabled) },
            uniquingKeysWith: { _, latest in latest }
        )
        let wifiStates = Dictionary(
            lastServices.compactMap { service -> (String, Bool)? in
                guard service.kind == .wifi, let device = service.device, let powered = service.wifiPowered else { return nil }
                return (device, powered)
            },
            uniquingKeysWith: { _, latest in latest }
        )
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
        if mainWindow?.isVisible == true, usageLabel?.stringValue != text {
            usageLabel?.stringValue = text
        }
        if statusPopover.isShown {
            let panelText = "今日记录 ↓ \(formatBytes(today.receivedBytes))  ↑ \(formatBytes(today.sentBytes))"
            if statusPanelUsageLabel?.stringValue != panelText {
                statusPanelUsageLabel?.stringValue = panelText
            }
        }
        let menuText = "今日记录：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))"
        if statusContextUsageItem?.title != menuText {
            statusContextUsageItem?.title = menuText
        }
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
        if !window.setFrameUsingName("LinkGlint.PreferencesWindow") { window.center() }
        window.setFrameAutosaveName("LinkGlint.PreferencesWindow")

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
        privilegePreferenceLabel = NSTextField(labelWithString: privilegedAccessState.title)
        privilegePreferenceLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        let privilegeSpacer = NSView()
        privilegeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        privilegePreferenceButton = NSButton(title: "开始配置…", target: self, action: #selector(showPrivilegedAccessSetup))
        privilegePreferenceButton?.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        privilegePreferenceButton?.bezelStyle = .rounded
        removePrivilegeButton = NSButton(title: "移除…", target: self, action: #selector(removePrivilegedAccess))
        removePrivilegeButton?.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
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
        resetTrafficSampling()
        applyMenuBarAppearance()
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
        guard !isDiagnosing else {
            diagnosticPending = true
            return
        }
        guard !networkMutationIsActive else {
            diagnosticPending = true
            diagnosticLabel?.isHidden = false
            diagnosticLabel?.stringValue = "网络诊断：等待当前网络操作完成…"
            diagnosticLabel?.textColor = .secondaryLabelColor
            return
        }
        isDiagnosing = true
        diagnosticPending = false
        let generation = networkStateGeneration
        diagnosticLabel?.isHidden = false
        diagnosticLabel?.stringValue = "网络诊断：正在检查网关与 DNS…"
        diagnosticLabel?.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.manager.runDiagnostics()
            DispatchQueue.main.async {
                self.isDiagnosing = false
                if generation == self.networkStateGeneration {
                    self.lastDiagnostic = result
                    var detail = "网络诊断：\(result.summary)"
                    if let latency = result.gatewayLatencyMilliseconds {
                        detail += String(format: " · 网关 %.1f ms", latency)
                    }
                    detail += result.dnsLookupSucceeded ? " · DNS 正常" : " · DNS 异常"
                    self.diagnosticLabel?.stringValue = detail
                    self.diagnosticLabel?.textColor = result.isUsable ? .systemGreen : .systemOrange
                } else {
                    self.diagnosticLabel?.stringValue = "网络诊断：连接已变化，正在重新检查…"
                    self.diagnosticLabel?.textColor = .secondaryLabelColor
                    self.diagnosticPending = true
                }
                if self.diagnosticPending { self.runDiagnostics() }
            }
        }
    }

    private func invalidateDiagnosticResult() {
        lastDiagnostic = nil
        guard diagnosticLabel?.isHidden == false else { return }
        diagnosticLabel?.stringValue = "网络诊断：连接已变化，请重新运行"
        diagnosticLabel?.textColor = .secondaryLabelColor
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
            if let device = service.device,
               let traffic = trafficLabels[device]?.first?.stringValue,
               !traffic.isEmpty {
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
        updateOperationFeedbackDisplays()
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
        if !mainWindow.setFrameUsingName("LinkGlint.MainWindow") { mainWindow.center() }
        mainWindow.setFrameAutosaveName("LinkGlint.MainWindow")

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
        accessActionButton.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
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
        profilePopup.cell?.lineBreakMode = .byTruncatingTail
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
        adapterSummaryLabel.maximumNumberOfLines = 1
        adapterSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            profilePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
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
        if initialRefreshError != nil, services.isEmpty {
            overviewLabel.stringValue = "读取网络状态失败，请点击刷新重试"
        } else if let primary = services.first(where: { $0.isPrimary && $0.connected }) {
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
        case .cellular: accentColor = .systemIndigo
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

        let placeholder = "  -- B/s"
        let traffic = NSTextField(labelWithString: service.connected ? "↓ \(placeholder)  ↑ \(placeholder)" : "")
        traffic.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        traffic.alignment = .right
        traffic.lineBreakMode = .byClipping
        traffic.textColor = .secondaryLabelColor
        traffic.isHidden = !service.connected || service.device == nil
        traffic.translatesAutoresizingMaskIntoConstraints = false
        traffic.widthAnchor.constraint(equalToConstant: 138).isActive = true
        if service.connected, let device = service.device {
            trafficLabels[device, default: []].append(traffic)
        }

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

        if NetworkServiceActionPolicy.offersSwitch(to: service) {
            let switchItem = NSMenuItem(title: "切换到此网络", action: #selector(switchToService(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
            switchItem.representedObject = [
                "target": service.name,
                "order": allServices.sorted { $0.orderIndex < $1.orderIndex }.map(\.name),
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
              let currentOrder = data["order"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }
        performServiceSwitch(
            target: target,
            currentOrder: currentOrder,
            wifiDevice: wifiDeviceValue.isEmpty ? nil : wifiDeviceValue
        )
    }

    private func showError(_ error: Error) {
        let applicationToRestore = prepareForStatusPanelModal()
        defer { restoreFrontmostApplication(applicationToRestore) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "网络操作未完成"
        alert.informativeText = error.localizedDescription.isEmpty ? "请重试。" : error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

}

/// Keeps custom controls at a stable size inside `NSAlert` on newer macOS
/// versions, where a stack view used directly as the accessory can collapse to
/// the minimum width of its arranged subviews.
private final class AlertAccessoryView: NSView {
    private let preferredSize: NSSize

    override var intrinsicContentSize: NSSize { preferredSize }

    init(width: CGFloat, height: CGFloat, content: NSView) {
        preferredSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: preferredSize))

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
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
        focusRingType = .exterior
        setAccessibilityRole(.checkBox)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 36, height: 20)
        let isOn = state == .on
        let enabledAlpha: CGFloat = isEnabled ? 1 : 0.42
        let trackColor = (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor.withAlphaComponent(0.28))
            .withAlphaComponent((isOn ? 1 : 0.28) * enabledAlpha)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10).fill()

        let knobX = isOn ? track.maxX - 18 : track.minX + 2
        let knobRect = NSRect(x: knobX, y: track.minY + 2, width: 16, height: 16)
        NSColor.white.withAlphaComponent(enabledAlpha).setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let outline = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.25, dy: 0.25))
        outline.lineWidth = 0.5
        outline.stroke()
        // Let NSButtonCell add the standard keyboard focus ring. The button is
        // borderless and titleless, so no system bezel obscures the custom track.
        super.draw(dirtyRect)
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
