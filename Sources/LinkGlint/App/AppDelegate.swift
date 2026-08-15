import AppKit
import Network
import ServiceManagement
import CoreLocation

/// Shared four-point-grid metrics for the menu-bar panel and main window.
enum LinkGlintLayout {
    static let compactGap: CGFloat = 4
    static let standardGap: CGFloat = 8
    static let panelWidth: CGFloat = 388
    static let panelRowHeight: CGFloat = 46
    static let mainRowHeight: CGFloat = 52
    static let rowRadius: CGFloat = 8
    static let sectionRadius: CGFloat = 10
    static let networkRefreshInterval: TimeInterval = 30

    // Status popover panel
    static let panelInsetY: CGFloat = 10
    static let panelInsetX: CGFloat = 12
    static let panelSectionGap: CGFloat = 8
    static let panelBaseHeight: CGFloat = 400
    static let trafficIPHeight: CGFloat = 102
    static let processRowHeight: CGFloat = 19
    static let processRowSpacing: CGFloat = 3
    static let footerGap: CGFloat = 8
    static let cardPadding = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    static let cardInnerSpacing: CGFloat = 4
    static let cardBorderAlpha: CGFloat = 0.26
    static let cardFillAlpha: CGFloat = 0.18

    static var panelContentWidth: CGFloat { panelWidth - panelInsetX * 2 }
    static var midRowCardWidth: CGFloat { (panelContentWidth - panelSectionGap) / 2 }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, CLLocationManagerDelegate, NSMenuItemValidation, @unchecked Sendable {
    private static let privilegedOnboardingCompletedKey = "privilegedAccessOnboardingCompleted.v1"
    private let menuBarRenderer = MenuBarRenderer()

    private let manager: NetworkManager
    private let profileStore: NetworkProfileStore
    private let usageTracker: UsageTracker
    private let defaults: UserDefaults
    private let monotonicClock: MonotonicClock
    private let refreshScheduler: RefreshScheduling
    private var preferences: AppPreferences
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
    private var statusPanelIsPinned = false
    private var statusPanelPreviousApplication: NSRunningApplication?
    private var statusPanelLocalEventMonitor: Any?
    private var statusPanelGlobalEventMonitor: Any?
    private var statusPanelResignObserver: NSObjectProtocol?
    private var statusPanelServicesSnapshot: [NetworkService]?
    private weak var statusPanelUsageLabel: NSTextField?
    private weak var statusPanelSummaryLabel: NSTextField?
    private weak var statusPanelTrafficRatesLabel: NSTextField?
    private weak var statusPanelTrafficRangeLabel: NSTextField?
    private weak var statusPanelTrafficChart: TrafficChartView?
    private weak var statusPanelProcessTrafficView: NSStackView?
    private weak var statusPanelIPAddressLabel: NSTextField?
    private weak var statusPanelIPCountryLabel: NSTextField?
    private weak var statusPanelIPDetailLabel: NSTextField?
    private weak var statusPanelIPOwnershipLabel: NSTextField?
    private weak var statusPanelIPCard: NSView?
    private var currentPublicIPAddress: String?
    private var currentPublicIPCountryCode: String?
    private var currentPublicIPCity: String?
    private var currentPublicIPRegion: String?
    private var currentPublicIPContinentCode: String?
    private var currentPublicIPOrganization: String?
    private var currentPublicIPTimezone: String?
    private let egressIPRefreshCoordinator = EgressIPRefreshCoordinator()
    private var egressGeoGenerationByAddress: [String: Int] = [:]
    private var pendingEgressIPBurstWork: [DispatchWorkItem] = []
    private var pendingEgressIPRetryWork: DispatchWorkItem?
    private var privilegedSetupController: PrivilegedSetupWindowController?
    private var pendingAfterPrivilegedConfiguration: (() -> Void)?
    private var pendingPrivilegedConfigurationUnavailable: (() -> Void)?
    private weak var statusPanelPinButton: NSButton?
    private weak var statusPanelDiagnosticButton: NSButton?
    private weak var statusContextUsageItem: NSMenuItem?
    private weak var statusContextTrafficItem: NSMenuItem?
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
    private var privilegePreferenceShield: NSImageView?
    private var privilegeAccessPanel: NSBox?
    private var privilegeAccessHint: NSTextField?
    private var removePrivilegeButton: NSButton?
    private var menuBarSpeedTwoLinesCheckbox: NSButton?
    private var menuBarSpeedBitsCheckbox: NSButton?
    private var menuBarTitleCheckbox: NSButton?
    private var menuBarSpeedCheckbox: NSButton?
    private var menuBarIndicatorPopup: NSPopUpButton?
    private var menuBarIntervalPopup: NSPopUpButton?
    private var menuBarIndicatorTitle: NSTextField?
    private var menuBarIntervalTitle: NSTextField?
    private var menuBarPreviewView: MenuBarPreviewView?
    private var menuBarPresetSegment: NSSegmentedControl?
    private var preferencesSegment: NSSegmentedControl?
    private var preferencesPageHost: NSView?
    private var preferencesMenuBarPage: NSView?
    private var preferencesLaunchPage: NSView?
    private var preferencesAccessPage: NSView?
    private var refreshTimer: Timer?
    private var trafficTimer: Timer?
    private var processTrafficTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "local.codex.LinkGlint.path-monitor")
    private var pendingPathRefresh: DispatchWorkItem?
    private let networkRefreshCoordinator = NetworkRefreshCoordinator()
    private var isPerformingPrivilegedChange = false
    private var isApplyingServiceSwitch = false
    private var isConfiguringPrivilegedAccess = false
    private let trafficMonitoringCoordinator = TrafficMonitoringCoordinator()
    private var isDiagnosing = false
    private var diagnosticPending = false
    private var privilegedAccessState: PrivilegedAccessState = .notConfigured
    private var automaticallyPresentedAccessGuidance: PrivilegedAccessGuidance?
    private var lastServices: [NetworkService] = []
    private var renderedWindowServices: [NetworkService]?
    private var lastDiagnostic: NetworkDiagnostic?
    private var previousTrafficCounters: [String: InterfaceCounters] = [:]
    private var previousTrafficSampleDate: Date?
    private var previousTrafficSampleUptime: TimeInterval?
    private var previousProcessTrafficCounters: [String: ProcessTrafficCounters] = [:]
    private var previousProcessTrafficUptime: TimeInterval?
    private var currentProcessTraffic: [(name: String, download: Double, upload: Double)] = []
    private var smoothedProcessTraffic: [String: (download: Double, upload: Double)] = [:]
    private var processTrafficIdleSamples: [String: Int] = [:]
    private var activeVPNInterfaceNames: Set<String> = []
    private var currentDownloadBytesPerSecond: Double = 0
    private var currentUploadBytesPerSecond: Double = 0
    private var trafficRateHistory = TrafficRateHistory(capacity: 60)
    private var trafficLabels: [String: [NSTextField]] = [:]
    private var lastAutoDiagnosticUptime: TimeInterval?
    private var hasLoadedNetworkState = false
    private var initialRefreshError: String?
    private var lastSuccessfulRefreshAt: Date?
    private var refreshFailureMessage: String?
    private var operationFeedback: (text: String, color: NSColor)?
    private var operationFeedbackReset: DispatchWorkItem?

    override convenience init() {
        self.init(
            manager: NetworkManager(),
            defaults: .standard,
            monotonicClock: SystemMonotonicClock(),
            refreshScheduler: DispatchRefreshScheduler()
        )
    }

    init(
        manager: NetworkManager,
        defaults: UserDefaults,
        monotonicClock: MonotonicClock,
        refreshScheduler: RefreshScheduling
    ) {
        self.manager = manager
        self.defaults = defaults
        self.monotonicClock = monotonicClock
        self.refreshScheduler = refreshScheduler
        self.profileStore = NetworkProfileStore(defaults: defaults)
        self.usageTracker = UsageTracker(defaults: defaults)
        self.preferences = AppPreferences(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createApplicationMenu()
        // Start as a menu-bar app. Showing a management window temporarily restores
        // the regular policy; closing the last window removes the Dock icon again.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Preserve the status-item placement chosen by users of NetBar 3.x.
        statusItem.autosaveName = "local.codex.NetBar.network-status"
        statusItem.isVisible = true
        statusItem.button?.image = menuBarRenderer.symbolImageForLaunch(accessibilityDescription: "网络管理")
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
        sampleVPNInterfaces()
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
        processTrafficTimer?.invalidate()
        pendingPathRefresh?.cancel()
        pathMonitor.cancel()
        invalidateEgressIPRefresh(clearSuccessTime: false)
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
        stopProcessTrafficSampling(clearDisplay: false)
        invalidateEgressIPRefresh(clearSuccessTime: true)
    }

    @objc private func handleSystemWake() {
        // Interface counters or the active route may change while the process is
        // suspended. Invalidate work launched before sleep and start with a
        // fresh baseline so neither an old route snapshot nor a large averaged
        // traffic spike can briefly overwrite the post-wake state.
        networkRefreshCoordinator.invalidateGeneration()
        pendingPathRefresh?.cancel()
        pendingPathRefresh = nil
        invalidateEgressIPRefresh(clearSuccessTime: true)
        invalidateDiagnosticResult()
        resetTrafficSampling(clearHistory: true)
        applyMenuBarAppearance()
        performRefresh(showingErrors: false)
        sampleTraffic()
        sampleVPNInterfaces()
        if statusPanelIsOpen { startProcessTrafficSampling() }
    }

    private func resetTrafficSampling(clearHistory: Bool = false) {
        trafficMonitoringCoordinator.invalidateAll()
        previousTrafficCounters.removeAll()
        previousTrafficSampleDate = nil
        previousTrafficSampleUptime = nil
        previousProcessTrafficCounters.removeAll()
        previousProcessTrafficUptime = nil
        currentProcessTraffic.removeAll()
        smoothedProcessTraffic.removeAll()
        processTrafficIdleSamples.removeAll()
        updateStatusPanelProcessTraffic()
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
        updateStatusPanelTrafficRangeLabel()
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
        guard let effectiveShowsErrors = networkRefreshCoordinator.request(
            showingErrors: showingErrors,
            mutationActive: networkMutationIsActive
        ) else { return }
        startNetworkRefresh(showingErrors: effectiveShowsErrors)
    }

    private func startNetworkRefresh(showingErrors: Bool) {
        let generation = networkRefreshCoordinator.generation
        let qos: DispatchQoS.QoSClass = showingErrors ? .userInitiated : .utility

        DispatchQueue.global(qos: qos).async { [weak self] in
            guard let self else { return }
            do {
                let services = try self.manager.fetchServices()
                let accessState = self.manager.privilegedAccessState
                DispatchQueue.main.async {
                    guard generation == self.networkRefreshCoordinator.generation else {
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
                        self.networkRefreshCoordinator.invalidateGeneration()
                        self.invalidateEgressIPRefresh(clearSuccessTime: true)
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
                    if servicesChanged {
                        self.refreshEgressIPIfNeeded(force: true)
                    }
                    if self.diagnosticPending && !self.isDiagnosing {
                        self.runDiagnostics()
                    }
                    self.schedulePrivilegedAccessGuidance(for: accessState)
                    self.completeNetworkRefresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.networkRefreshCoordinator.generation else {
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
        guard let followUp = networkRefreshCoordinator.finish(
            retryingWith: retryShowsErrors
        ) else { return }
        performRefresh(showingErrors: followUp)
    }

    private var networkMutationIsActive: Bool {
        isApplyingServiceSwitch || isPerformingPrivilegedChange || isConfiguringPrivilegedAccess
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let writeActions: [Selector] = [
            #selector(toggleService(_:)), #selector(toggleWiFiPower(_:)),
            #selector(switchToService(_:)), #selector(showDNSSettingsMenu(_:)),
            #selector(setHighestPriorityMenu(_:)), #selector(renameNetworkService(_:)),
            #selector(applyProfileMenu(_:)), #selector(applySelectedProfile),
            #selector(saveCurrentProfile),
            #selector(showPriorityEditor), #selector(showJoinWiFi(_:)),
            #selector(removePrivilegedAccess),
            #selector(showMainWindow), #selector(showPreferences)
        ]
        if currentAccessGuidance().requiresBlockingSetup,
           let action = menuItem.action,
           writeActions.contains(action) {
            return false
        }
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
            summaryTitle = primary.map {
                "当前：\(NetworkDisplayText.singleLine($0.name))"
                    + ($0.ipAddress.map { " · \($0)" } ?? "")
            }
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
        let displayName = NetworkDisplayText.singleLine(service.name)
        let item = NSMenuItem(title: "\(state)  \(displayName)", action: nil, keyEquivalent: "")
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
            let wifi = NSMenuItem(
                title: "Wi-Fi：\(NetworkDisplayText.singleLine(ssid))",
                action: nil,
                keyEquivalent: ""
            )
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
        disablePrivilegedWriteIfNeeded(rename)
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
        disablePrivilegedWriteIfNeeded(dnsSettings)
        submenu.addItem(dnsSettings)

        if service.orderIndex > 0 {
            let priority = NSMenuItem(title: "设为最高优先级", action: #selector(setHighestPriorityMenu(_:)), keyEquivalent: "")
            priority.target = self
            priority.representedObject = [
                "service": service.name,
                "order": allServices.map(\.name)
            ] as NSDictionary
            disablePrivilegedWriteIfNeeded(priority)
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
        disablePrivilegedWriteIfNeeded(toggle)
        submenu.addItem(toggle)

        if service.kind == .wifi, let device = service.device, let powered = service.wifiPowered {
            let wifiToggle = NSMenuItem(
                title: powered ? "关闭 Wi-Fi 硬件" : "打开 Wi-Fi 硬件",
                action: #selector(toggleWiFiPower(_:)),
                keyEquivalent: ""
            )
            wifiToggle.target = self
            wifiToggle.representedObject = ["device": device, "enable": !powered] as NSDictionary
            disablePrivilegedWriteIfNeeded(wifiToggle)
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
                disablePrivilegedWriteIfNeeded(switchItem)
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
            disablePrivilegedWriteIfNeeded(item)
            profilesMenu.addItem(item)
        }
        if !profileStore.profiles.isEmpty {
            profilesMenu.addItem(.separator())
            for profile in profileStore.profiles {
                let item = NSMenuItem(title: profile.name, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "profile:\(profile.id.uuidString)"
                disablePrivilegedWriteIfNeeded(item)
                profilesMenu.addItem(item)
            }
        }
        profilesItem.submenu = profilesMenu
        disablePrivilegedWriteIfNeeded(profilesItem)
        menu.addItem(profilesItem)

        if lastServices.count > 1 {
            let priority = NSMenuItem(title: "调整服务优先级…", action: #selector(showPriorityEditor), keyEquivalent: "")
            priority.target = self
            priority.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)
            disablePrivilegedWriteIfNeeded(priority)
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
        let trafficItem = NSMenuItem(title: "当前速率：↓ 0 B/s · ↑ 0 B/s", action: nil, keyEquivalent: "")
        trafficItem.identifier = NSUserInterfaceItemIdentifier("current-traffic")
        trafficItem.isEnabled = false
        statusContextTrafficItem = trafficItem
        activityMenu.addItem(trafficItem)
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
        if currentAccessGuidance().requiresBlockingSetup {
            showWindow.isEnabled = false
            showWindow.toolTip = "完成管理员授权后可用"
        }
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
            var text = "LinkGlint · 已连接 · \(NetworkDisplayText.singleLine($0.name))"
            if let ssid = $0.ssid { text += " · \(NetworkDisplayText.singleLine(ssid))" }
            if let ip = $0.ipAddress { text += " · \(ip)" }
            if currentNetworkPresentation.vpnConnected { text += " · VPN 已开启" }
            return text
        } ?? "LinkGlint · 离线 · 当前无网络连接"
        let networkTitle = currentNetworkPresentation.title
        let semanticToolTip = MenuBarStatusSemantics.toolTip(for: baseToolTip, networkTitle: networkTitle)
        statusItem.button?.toolTip = refreshFailureMessage == nil
            ? semanticToolTip : "\(semanticToolTip) · 状态可能已过期"
    }

    @objc private func toggleStatusPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let click: StatusPanelClick = NSApp.currentEvent?.type == .rightMouseUp ? .right : .left
        switch PrivilegedBlockedInteractionPolicy.action(
            blocked: currentAccessGuidance().requiresBlockingSetup,
            rightClick: click == .right
        ) {
        case .presentSetup:
            _ = presentBlockingPrivilegedSetupIfNeeded()
            return
        case .presentRestrictedMenu:
            presentPrivilegedSetupContextMenu(relativeTo: button)
            return
        case .continueNormally:
            break
        }
        switch StatusPanelInteraction.action(for: click, panelIsOpen: statusPanelIsOpen) {
        case .showContextMenu:
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            let applicationToRestore = statusPanelPreviousApplication
                ?? (frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    ? nil : frontmostApplication)
            closeStatusPanel()
            presentStatusContextMenu(relativeTo: button, applicationToRestore: applicationToRestore)
        case .closePanel:
            closeStatusPanel(restoringPreviousApplication: true)
        case .openPanel:
            if presentBlockingPrivilegedSetupIfNeeded() { return }
            openStatusPanel(relativeTo: button)
        }
    }

    private func presentPrivilegedSetupContextMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        let guidance = currentAccessGuidance()
        let status = NSMenuItem(title: guidance.setupTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let configure = NSMenuItem(
            title: guidance.primaryActionTitle,
            action: #selector(showPrivilegedAccessSetup),
            keyEquivalent: ""
        )
        configure.target = self
        menu.addItem(configure)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 LinkGlint",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 3), in: button)
        button.highlight(false)
    }

    private func presentStatusContextMenu(
        relativeTo button: NSStatusBarButton,
        applicationToRestore: NSRunningApplication?
    ) {
        // Menu-item actions run synchronously inside `popUp`. Preserve the app
        // that owned focus so an action which opens a modal can restore it after
        // the temporary UI is dismissed.
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
    }

    private func openStatusPanel(relativeTo button: NSStatusBarButton) {
        if presentBlockingPrivilegedSetupIfNeeded() { return }
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
        if statusPanelIsPinned {
            statusPopover.contentViewController?.view.window?.level = .floating
            statusPopover.contentViewController?.view.window?.collectionBehavior.insert(.canJoinAllSpaces)
        }
        updateUsageDisplay()
        refreshEgressIPIfNeeded(force: true)
        scheduleEgressIPBurstRefresh()
        startProcessTrafficSampling()
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
        stopProcessTrafficSampling(clearDisplay: true)
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
            if StatusPanelDismissalPolicy.dismissesForExternalInteraction(isPinned: self.statusPanelIsPinned) {
                self.closeStatusPanel()
            }
            return event
        }
        statusPanelGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.isRequestingLocationAuthorization != true,
                      self?.isKeepingStatusPanelOpenForModalInteraction != true,
                      self?.statusPanelIsPinned != true else { return }
                self?.closeStatusPanel()
            }
        }
        statusPanelResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard self?.isRequestingLocationAuthorization != true,
                  self?.isKeepingStatusPanelOpenForModalInteraction != true,
                  self?.statusPanelIsPinned != true else { return }
            self?.closeStatusPanel()
        }
    }

    @objc private func toggleStatusPanelPinned() {
        statusPanelIsPinned.toggle()
        updateStatusPanelPinButton()
        if statusPanelIsPinned {
            statusPopover.contentViewController?.view.window?.level = .floating
            statusPopover.contentViewController?.view.window?.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            statusPopover.contentViewController?.view.window?.level = .normal
        }
    }

    private func updateStatusPanelPinButton() {
        guard let button = statusPanelPinButton else { return }
        button.image = NSImage(
            systemSymbolName: statusPanelIsPinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        )
        button.contentTintColor = statusPanelIsPinned ? .controlAccentColor : .labelColor
        button.toolTip = statusPanelIsPinned ? "取消置顶；恢复点击外部自动关闭" : "置顶面板；切换应用时继续观察进程流量"
        button.setAccessibilityLabel(statusPanelIsPinned ? "取消置顶面板" : "置顶面板")
        button.state = statusPanelIsPinned ? .on : .off
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
        let height: CGFloat = LinkGlintLayout.panelBaseHeight + permissionHeight + rowViewportHeight
        let controller = NSViewController()
        // NSPopover already supplies the window shape and shadow. A second
        // vibrancy layer here used to blend strongly with colorful wallpapers,
        // making the panel look tinted or uneven. Use an opaque dynamic system
        // background instead so text and controls remain consistent everywhere.
        let root = StatusPanelBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        controller.view = root

        let refreshButton = compactIconButton(symbol: "arrow.clockwise", label: "刷新", action: #selector(refresh))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        let pinButton = compactIconButton(symbol: "pin", label: "置顶面板", action: #selector(toggleStatusPanelPinned))
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        statusPanelPinButton = pinButton
        updateStatusPanelPinButton()

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
        brandHeader.addSubview(pinButton)
        NSLayoutConstraint.activate([
            brandTitle.centerXAnchor.constraint(equalTo: brandHeader.centerXAnchor),
            brandTitle.topAnchor.constraint(equalTo: brandHeader.topAnchor),
            pinButton.centerYAnchor.constraint(equalTo: brandTitle.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -4),
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
        let activeService = services.first(where: { $0.isPrimary && $0.connected })
            ?? services.first(where: \.connected)
        let sectionCount = NSTextField(labelWithString: NetworkServiceSummaryText.panel(services: services))
        sectionCount.font = .systemFont(ofSize: 10)
        sectionCount.textColor = .secondaryLabelColor
        sectionCount.alignment = .right
        sectionCount.lineBreakMode = .byTruncatingTail
        sectionCount.maximumNumberOfLines = 1
        sectionCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusPanelSummaryLabel = sectionCount
        let sectionSpacer = NSView()
        sectionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let copyConnection = compactIconButton(
            symbol: "doc.on.doc",
            label: "复制当前连接摘要",
            action: #selector(copyCurrentConnectionSummary)
        )
        copyConnection.isEnabled = activeService != nil
        let sectionHeader = NSStackView(views: [sectionLabel, sectionSpacer, sectionCount, copyConnection])
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
        let ipStatus = statusPanelIPStatusCard()
        let trafficIPRow = StatusPanelMidRowLayout.makeRow(leading: trafficChart, trailing: ipStatus)
        trafficIPRow.setContentHuggingPriority(.init(1), for: .horizontal)
        trafficIPRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let processTraffic = statusPanelProcessTrafficCard()
        let footer = statusPanelFooter(services: services)
        let stack = NSStackView(views: [brandHeader, sectionHeader, scroll, trafficIPRow, processTraffic, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = LinkGlintLayout.panelSectionGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: LinkGlintLayout.panelInsetY),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: LinkGlintLayout.panelInsetX),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -LinkGlintLayout.panelInsetX),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -LinkGlintLayout.panelInsetY),
            scroll.heightAnchor.constraint(equalToConstant: rowViewportHeight),
            // NSStackView `.width` alignment does not reliably stretch; pin mid-row
            // edges so traffic/IP cards stay flush instead of drifting trailing.
            trafficIPRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            trafficIPRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        statusPopover.contentViewController = controller
        statusPopover.contentSize = NSSize(width: width, height: height)
        updateOperationFeedbackDisplays()
    }

    private func makeStatusPanelCard(content: NSView) -> StatusPanelCardView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = StatusPanelCardView()
        card.setContentHuggingPriority(.defaultLow, for: .horizontal)
        card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func statusPanelTrafficChartCard() -> NSView {
        let title = NSTextField(labelWithString: "实时流量")
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let range = NSTextField(
            labelWithString: TrafficHistoryWindowFormatter.fixedWidthString(samples: trafficRateHistory.samples)
        )
        range.font = .systemFont(ofSize: 9.5)
        range.textColor = .tertiaryLabelColor
        range.toolTip = "根据实际采样时间显示"
        statusPanelTrafficRangeLabel = range

        let titleRow = StatusPanelTrafficCardLayout.makeTitleRow(
            title: title,
            rangeContainer: StatusPanelTrafficCardLayout.makeRangeContainer(label: range)
        )

        let rates = NSTextField(labelWithAttributedString: statusPanelTrafficRateText)
        rates.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
        rates.alignment = .left
        rates.lineBreakMode = .byTruncatingTail
        rates.textColor = .secondaryLabelColor
        rates.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rates.toolTip = "蓝色为下载，橙色为上传"
        statusPanelTrafficRatesLabel = rates

        let chart = TrafficChartView()
        chart.samples = trafficRateHistory.samples
        chart.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chart.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusPanelTrafficChart = chart

        let content = StatusPanelTrafficCardLayout.makeContent(
            titleRow: titleRow,
            rates: rates,
            chart: chart
        )
        return makeStatusPanelCard(content: content)
    }

    private func statusPanelProcessTrafficCard() -> NSView {
        let title = NSTextField(labelWithString: "进程实时流量")
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        let hint = NSTextField(labelWithString: "TOP 5 · 总速率排序")
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, spacer, hint])
        header.orientation = .horizontal; header.alignment = .centerY
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        let processHeading = NSTextField(labelWithString: "应用 / 进程")
        let downloadHeading = NSTextField(labelWithString: "↓ 下载")
        let uploadHeading = NSTextField(labelWithString: "↑ 上传")
        for label in [processHeading, downloadHeading, uploadHeading] {
            label.font = .systemFont(ofSize: 8.5, weight: .medium)
            label.textColor = .tertiaryLabelColor
        }
        downloadHeading.alignment = .right; uploadHeading.alignment = .right
        downloadHeading.translatesAutoresizingMaskIntoConstraints = false
        uploadHeading.translatesAutoresizingMaskIntoConstraints = false
        downloadHeading.widthAnchor.constraint(equalToConstant: 72).isActive = true
        uploadHeading.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let headingSpacer = NSView(); headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headings = NSStackView(views: [processHeading, headingSpacer, downloadHeading, uploadHeading])
        headings.orientation = .horizontal; headings.spacing = 5; headings.alignment = .centerY
        headings.setContentCompressionResistancePriority(.required, for: .vertical)
        let rows = NSStackView(); rows.orientation = .vertical; rows.spacing = LinkGlintLayout.processRowSpacing
        for index in 0..<5 {
            let row = ProcessTrafficRowView(rank: index + 1)
            row.identifier = NSUserInterfaceItemIdentifier("process-traffic-row-\(index)")
            rows.addArrangedSubview(row)
        }
        let content = NSStackView(views: [header, headings, rows])
        content.orientation = .vertical
        content.spacing = 6
        content.alignment = .width
        content.edgeInsets = LinkGlintLayout.cardPadding
        let card = makeStatusPanelCard(content: content)
        statusPanelProcessTrafficView = rows
        updateStatusPanelProcessTraffic()
        return card
    }

    private func statusPanelIPStatusCard() -> NSView {
        let title = NSTextField(labelWithString: "出口 IP")
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let address = NSTextField(labelWithString: "检测中…")
        address.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        address.alignment = .left
        address.textColor = .labelColor
        address.lineBreakMode = .byTruncatingMiddle
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setContentHuggingPriority(.defaultHigh, for: .vertical)
        statusPanelIPAddressLabel = address

        let country = NSTextField(labelWithString: "")
        country.font = .systemFont(ofSize: 11, weight: .medium)
        country.textColor = .labelColor
        country.lineBreakMode = .byTruncatingTail
        country.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        StatusPanelIPCardLayout.configureMetaLine(country, height: StatusPanelIPCardLayout.countryLineHeight)
        statusPanelIPCountryLabel = country

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        StatusPanelIPCardLayout.configureMetaLine(detail, height: StatusPanelIPCardLayout.detailLineHeight)
        statusPanelIPDetailLabel = detail

        let ownership = NSTextField(labelWithString: "")
        ownership.font = .systemFont(ofSize: 9.5, weight: .regular)
        ownership.textColor = .tertiaryLabelColor
        ownership.lineBreakMode = .byTruncatingTail
        ownership.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        StatusPanelIPCardLayout.configureMetaLine(ownership, height: StatusPanelIPCardLayout.ownershipLineHeight)
        statusPanelIPOwnershipLabel = ownership

        let meta = NSStackView(views: [country, detail, ownership])
        meta.orientation = .vertical
        meta.alignment = .width
        meta.spacing = 2
        meta.translatesAutoresizingMaskIntoConstraints = false

        let content = StatusPanelIPCardLayout.makeContent(title: title, address: address, meta: meta)
        let card = makeStatusPanelCard(content: content)
        statusPanelIPCard = card
        updateStatusPanelIP()
        return card
    }

    private func updateStatusPanelIP() {
        guard let addressLabel = statusPanelIPAddressLabel else { return }
        let presentation = PublicIPDisplayFormatter.panelPresentation(
            address: currentPublicIPAddress,
            countryCode: currentPublicIPCountryCode,
            city: currentPublicIPCity,
            region: currentPublicIPRegion,
            continentCode: currentPublicIPContinentCode,
            organization: currentPublicIPOrganization,
            timezone: currentPublicIPTimezone
        )
        addressLabel.stringValue = presentation.addressLine
        statusPanelIPCountryLabel?.stringValue = presentation.countryLine ?? ""
        statusPanelIPDetailLabel?.stringValue = presentation.detailLine ?? ""
        statusPanelIPOwnershipLabel?.stringValue = presentation.ownershipLine ?? ""
        let tip = presentation.toolTip
        addressLabel.toolTip = tip
        statusPanelIPCountryLabel?.toolTip = tip
        statusPanelIPDetailLabel?.toolTip = tip
        statusPanelIPOwnershipLabel?.toolTip = tip
        statusPanelIPCard?.toolTip = tip
    }

    private func refreshEgressIPIfNeeded(force: Bool = false) {
        let vpnActive = !activeVPNInterfaceNames.isEmpty
        let uptime = monotonicClock.now
        let interval = EgressIPRefreshPolicy.refreshInterval(
            panelOpen: statusPanelIsOpen,
            vpnActive: vpnActive
        )
        guard let ticket = egressIPRefreshCoordinator.begin(
            force: force,
            now: uptime,
            refreshInterval: interval
        ) else { return }
        let previousAddress = currentPublicIPAddress
        let previousCountry = currentPublicIPCountryCode
        let previousCity = currentPublicIPCity
        let previousRegion = currentPublicIPRegion
        let previousContinent = currentPublicIPContinentCode
        let previousOrganization = currentPublicIPOrganization
        let previousTimezone = currentPublicIPTimezone
        let priority: TaskPriority = (force || statusPanelIsOpen) ? .userInitiated : .utility
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }

            if previousAddress == nil {
                if let combined = try? await self.manager.fetchPublicIPInfoCombined(vpnActive: vpnActive) {
                    guard !Task.isCancelled else { return }
                    DispatchQueue.main.async {
                        let applied = self.completeEgressIPFetchSuccess(ticket: ticket) {
                            self.currentPublicIPAddress = combined.address
                            self.currentPublicIPCountryCode = combined.countryCode
                            self.currentPublicIPCity = combined.city
                            self.currentPublicIPRegion = combined.region
                            self.currentPublicIPContinentCode = combined.continentCode
                            self.currentPublicIPOrganization = combined.organization
                            self.currentPublicIPTimezone = combined.timezone
                        }
                        let hasGeo = combined.countryCode != nil || combined.city != nil
                            || combined.region != nil || combined.continentCode != nil
                            || combined.organization != nil || combined.timezone != nil
                        if applied, hasGeo {
                            self.egressIPRefreshCoordinator.recordGeoSuccess(
                                for: combined.address,
                                now: self.monotonicClock.now
                            )
                        }
                    }
                } else if let address = try? await self.manager.fetchPublicIPAddress(vpnActive: vpnActive) {
                    guard !Task.isCancelled else { return }
                    DispatchQueue.main.async {
                        let applied = self.completeEgressIPFetchSuccess(ticket: ticket) {
                            self.currentPublicIPAddress = address
                            self.currentPublicIPCountryCode = nil
                            self.currentPublicIPCity = nil
                            self.currentPublicIPRegion = nil
                            self.currentPublicIPContinentCode = nil
                            self.currentPublicIPOrganization = nil
                            self.currentPublicIPTimezone = nil
                        }
                        if applied {
                            self.fetchEgressIPGeo(for: address, priority: priority)
                        }
                    }
                } else {
                    guard !Task.isCancelled else { return }
                    DispatchQueue.main.async {
                        self.completeEgressIPFetchFailure(ticket: ticket)
                    }
                }
                return
            }

            let address = try? await self.manager.fetchPublicIPAddress(vpnActive: vpnActive)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                guard let address else {
                    self.completeEgressIPFetchFailure(ticket: ticket)
                    return
                }
                let applied = self.completeEgressIPFetchSuccess(ticket: ticket) {
                    let ipChanged = address != previousAddress
                    self.currentPublicIPAddress = address
                    let hasCachedGeo = previousCountry != nil
                        || previousCity != nil
                        || previousRegion != nil
                        || previousContinent != nil
                        || previousOrganization != nil
                    if !ipChanged, hasCachedGeo {
                        self.currentPublicIPCountryCode = previousCountry
                        self.currentPublicIPCity = previousCity
                        self.currentPublicIPRegion = previousRegion
                        self.currentPublicIPContinentCode = previousContinent
                        self.currentPublicIPOrganization = previousOrganization
                        self.currentPublicIPTimezone = previousTimezone
                    } else if ipChanged {
                        self.currentPublicIPCountryCode = nil
                        self.currentPublicIPCity = nil
                        self.currentPublicIPRegion = nil
                        self.currentPublicIPContinentCode = nil
                        self.currentPublicIPOrganization = nil
                        self.currentPublicIPTimezone = nil
                    }
                }
                guard applied else { return }
                let hasCachedGeo = previousCountry != nil || previousCity != nil
                    || previousRegion != nil || previousContinent != nil
                    || previousOrganization != nil || previousTimezone != nil
                let needsGeo = self.egressIPRefreshCoordinator.shouldRefreshGeo(
                    for: address,
                    hasCachedValue: address == previousAddress && hasCachedGeo,
                    now: self.monotonicClock.now
                )
                if needsGeo {
                    self.fetchEgressIPGeo(for: address, priority: priority)
                }
            }
        }
        egressIPRefreshCoordinator.attach(task, to: ticket)
    }

    @discardableResult
    private func completeEgressIPFetchSuccess(
        ticket: EgressIPRefreshCoordinator.Ticket,
        _ apply: () -> Void
    ) -> Bool {
        guard let completion = egressIPRefreshCoordinator.completeSuccess(
            ticket,
            now: monotonicClock.now
        ) else { return false }
        let previousAddress = currentPublicIPAddress
        apply()
        if currentPublicIPAddress != previousAddress {
            egressIPRefreshCoordinator.clearGeoCache()
            cancelPendingEgressIPBurstRefresh()
        }
        pendingEgressIPRetryWork?.cancel()
        pendingEgressIPRetryWork = nil
        updateStatusPanelIP()
        if completion.forcedFollowUp {
            DispatchQueue.main.async { [weak self] in
                self?.refreshEgressIPIfNeeded(force: true)
            }
        }
        return true
    }

    private func completeEgressIPFetchFailure(ticket: EgressIPRefreshCoordinator.Ticket) {
        guard let completion = egressIPRefreshCoordinator.completeFailure(ticket) else { return }
        updateStatusPanelIP()
        scheduleEgressIPFailureRetry()
        if completion.forcedFollowUp {
            DispatchQueue.main.async { [weak self] in
                self?.refreshEgressIPIfNeeded(force: true)
            }
        }
    }

    private func fetchEgressIPGeo(for address: String, priority: TaskPriority) {
        let generation = egressIPRefreshCoordinator.currentGeneration
        guard egressGeoGenerationByAddress[address] == nil else { return }
        egressGeoGenerationByAddress[address] = generation
        Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            let geo = try? await self.manager.fetchPublicIPGeoInfo(for: address)
            DispatchQueue.main.async {
                guard self.egressGeoGenerationByAddress[address] == generation,
                      self.egressIPRefreshCoordinator.currentGeneration == generation else { return }
                self.egressGeoGenerationByAddress.removeValue(forKey: address)
                guard self.currentPublicIPAddress == address else { return }
                if let geo {
                    self.currentPublicIPCountryCode = geo.countryCode
                    self.currentPublicIPCity = geo.city
                    self.currentPublicIPRegion = geo.region
                    self.currentPublicIPContinentCode = geo.continentCode
                    self.currentPublicIPOrganization = geo.organization
                    self.currentPublicIPTimezone = geo.timezone
                    self.egressIPRefreshCoordinator.recordGeoSuccess(
                        for: address,
                        now: self.monotonicClock.now
                    )
                }
                self.updateStatusPanelIP()
            }
        }
    }

    private func scheduleEgressIPFailureRetry() {
        let vpnActive = !activeVPNInterfaceNames.isEmpty
        guard EgressIPRefreshPolicy.shouldScheduleFailureRetry(
            panelOpen: statusPanelIsOpen,
            vpnActive: vpnActive,
            attempt: egressIPRefreshCoordinator.failureRetryAttempt
        ) else { return }

        pendingEgressIPRetryWork?.cancel()
        let delay = EgressIPRefreshPolicy.failureRetryInterval(
            panelOpen: statusPanelIsOpen,
            vpnActive: vpnActive
        )
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshEgressIPIfNeeded(force: true)
        }
        pendingEgressIPRetryWork = work
        refreshScheduler.schedule(work, after: delay)
    }

    private func scheduleEgressIPBurstRefresh() {
        guard !activeVPNInterfaceNames.isEmpty else { return }
        cancelPendingEgressIPBurstRefresh()
        for delay in EgressIPRefreshPolicy.burstRefreshDelays {
            let work = DispatchWorkItem { [weak self] in
                self?.refreshEgressIPIfNeeded(force: true)
            }
            pendingEgressIPBurstWork.append(work)
            refreshScheduler.schedule(work, after: delay)
        }
    }

    private func cancelPendingEgressIPBurstRefresh() {
        pendingEgressIPBurstWork.forEach { $0.cancel() }
        pendingEgressIPBurstWork.removeAll()
    }

    private func invalidateEgressIPRefresh(clearSuccessTime: Bool) {
        egressIPRefreshCoordinator.invalidateNetworkGeneration(clearSuccessTime: clearSuccessTime)
        egressGeoGenerationByAddress.removeAll()
        pendingEgressIPRetryWork?.cancel()
        pendingEgressIPRetryWork = nil
        cancelPendingEgressIPBurstRefresh()
    }

    private func updateStatusPanelProcessTraffic() {
        guard let rows = statusPanelProcessTrafficView else { return }
        let values = currentProcessTraffic
        for (index, view) in rows.arrangedSubviews.enumerated() {
            guard let row = view as? ProcessTrafficRowView else { continue }
            if index < values.count {
                let value = values[index]
                row.configure(
                    name: value.name,
                    icon: processIcon(named: value.name),
                    download: fixedWidthRate(value.download),
                    upload: fixedWidthRate(value.upload)
                )
            } else if index == 0 {
                row.showPlaceholder()
            } else {
                row.clearSlot()
            }
        }
    }

    private func processIcon(named name: String) -> NSImage? {
        let normalized = name.lowercased()
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == normalized
                || $0.executableURL?.deletingPathExtension().lastPathComponent.lowercased() == normalized
        }), let url = app.bundleURL ?? app.executableURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    }

    private var statusPanelTrafficRateText: NSAttributedString {
        MenuBarRenderer.trafficRateAttributedString(
            downloadBytesPerSecond: currentDownloadBytesPerSecond,
            uploadBytesPerSecond: currentUploadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits,
            indicatorStyle: preferences.menuBarTrafficIndicatorStyle
        )
    }

    private func updateStatusPanelTrafficRangeLabel() {
        let samples = trafficRateHistory.samples
        statusPanelTrafficRangeLabel?.stringValue = TrafficHistoryWindowFormatter.fixedWidthString(samples: samples)
        statusPanelTrafficRangeLabel?.toolTip = samples.isEmpty
            ? "等待流量样本" : "\(samples.count) 个样本 · 按实际采样时间计算"
    }

    private func statusPanelServiceRow(_ service: NetworkService, allServices: [NetworkService]) -> NSView {
        let icon = NSImageView()
        icon.image = symbol(for: service)
        icon.setAccessibilityElement(false)
        icon.setAccessibilityHidden(true)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = service.connected ? statusColor(for: service.kind) : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let rawVisibleName = service.kind == .wifi && service.connected
            ? (service.ssid ?? service.name) : service.name
        let visibleName = NetworkDisplayText.singleLine(rawVisibleName)
        let serviceDisplayName = NetworkDisplayText.singleLine(service.name)
        let name = NSTextField(labelWithString: visibleName)
        name.font = .systemFont(ofSize: 12, weight: service.connected ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = visibleName
        var details = ["优先级 \(service.orderIndex + 1)", networkKindName(service.kind), service.connected ? "已连接" : (service.enabled ? "可用" : "已停用")]
        if rawVisibleName != service.name { details.append(serviceDisplayName) }
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
            use.setAccessibilityLabel("切换到 \(serviceDisplayName)")
            views.append(use)
        }
        let enabledSwitch = NetworkToggleSwitch()
        enabledSwitch.target = self
        enabledSwitch.action = #selector(windowToggleServiceSwitch(_:))
        enabledSwitch.state = service.enabled ? .on : .off
        enabledSwitch.controlSize = .small
        enabledSwitch.payload = ["name": service.name]
        enabledSwitch.toolTip = service.enabled ? "停用 \(serviceDisplayName)" : "启用 \(serviceDisplayName)"
        enabledSwitch.setAccessibilityLabel("\(serviceDisplayName) 网络服务")
        enabledSwitch.setAccessibilityHelp(service.enabled ? "停用 \(serviceDisplayName)" : "启用 \(serviceDisplayName)")
        views.append(enabledSwitch)
        views.append(serviceActionsButton(service, allServices: allServices))
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = LinkGlintLayout.rowRadius
        let isPrimaryConnected = service.isPrimary && service.connected
        card.borderWidth = isPrimaryConnected ? 1 : 0
        let accent = statusColor(for: service.kind)
        card.borderColor = isPrimaryConnected
            ? accent.withAlphaComponent(0.28)
            : .clear
        card.fillColor = service.connected
            ? accent.withAlphaComponent(isPrimaryConnected ? 0.07 : 0.04)
            : NSColor.controlBackgroundColor.withAlphaComponent(service.enabled ? 0.22 : 0.10)
        card.contentView?.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: LinkGlintLayout.panelRowHeight),
            icon.widthAnchor.constraint(equalToConstant: 21),
            icon.heightAnchor.constraint(equalToConstant: 21),
            row.topAnchor.constraint(equalTo: card.contentView!.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor)
        ])
        return card
    }

    private func statusPanelFooter(services: [NetworkService]) -> NSView {
        let usage = usageTracker.usage()
        let usageText = NSTextField(labelWithString: "")
        usageText.attributedStringValue = MenuBarRenderer.usageSummaryAttributedString(
            downloadText: formatBytes(usage.receivedBytes),
            uploadText: formatBytes(usage.sentBytes),
            indicatorStyle: preferences.menuBarTrafficIndicatorStyle
        )
        statusPanelUsageLabel = usageText
        let usageSpacer = NSView()
        usageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let diagnostic = NSButton(title: "网络检测", target: self, action: #selector(runDiagnostics))
        diagnostic.bezelStyle = .inline
        diagnostic.controlSize = .small
        diagnostic.font = .systemFont(ofSize: 10)
        diagnostic.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        diagnostic.imagePosition = .imageLeading
        statusPanelDiagnosticButton = diagnostic
        updateStatusPanelDiagnosticButton()
        let menuHint = NSButton(title: "完整菜单", target: self, action: #selector(showStatusContextMenuFromPanel))
        menuHint.bezelStyle = .inline
        menuHint.controlSize = .small
        menuHint.font = .systemFont(ofSize: 10)
        let usageRow = NSStackView(views: [usageText, usageSpacer, diagnostic, menuHint])
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
        footer.spacing = LinkGlintLayout.footerGap
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
            self.invalidateEgressIPRefresh(clearSuccessTime: true)
            self.performRefresh(showingErrors: false)
            if !self.activeVPNInterfaceNames.isEmpty {
                self.refreshEgressIPIfNeeded(force: true)
                self.scheduleEgressIPBurstRefresh()
            }
            let uptime = self.monotonicClock.now
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
        refreshScheduler.schedule(workItem, after: 0.6)
    }

    @objc private func sampleTraffic() {
        guard !networkMutationIsActive,
              let ticket = trafficMonitoringCoordinator.begin(.interface) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let counters = try? self.manager.fetchTrafficCounters()
            let sampleDate = Date()
            let sampleUptime = self.monotonicClock.now
            DispatchQueue.main.async {
                guard self.trafficMonitoringCoordinator.complete(ticket) else {
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
                        self.updateStatusPanelTrafficRangeLabel()
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

    private func startProcessTrafficSampling() {
        guard ProcessTrafficSamplingPolicy.shouldRun(panelOpen: statusPanelIsOpen) else { return }
        processTrafficTimer?.invalidate()
        sampleProcessTraffic()
        let timer = Timer(timeInterval: ProcessTrafficSamplingPolicy.refreshInterval, repeats: true) { [weak self] _ in
            self?.sampleProcessTraffic()
        }
        timer.tolerance = 0.2
        processTrafficTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopProcessTrafficSampling(clearDisplay: Bool) {
        processTrafficTimer?.invalidate()
        processTrafficTimer = nil
        trafficMonitoringCoordinator.invalidate(.process)
        previousProcessTrafficCounters.removeAll()
        previousProcessTrafficUptime = nil
        smoothedProcessTraffic.removeAll()
        processTrafficIdleSamples.removeAll()
        if clearDisplay {
            currentProcessTraffic.removeAll()
            updateStatusPanelProcessTraffic()
        }
    }

    private func sampleProcessTraffic() {
        guard ProcessTrafficSamplingPolicy.shouldRun(panelOpen: statusPanelIsOpen),
              !networkMutationIsActive,
              let ticket = trafficMonitoringCoordinator.begin(.process) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let counters = try? self.manager.fetchProcessTrafficCounters()
            let uptime = self.monotonicClock.now
            DispatchQueue.main.async {
                guard self.trafficMonitoringCoordinator.complete(ticket),
                      self.statusPanelIsOpen else { return }
                guard let counters else {
                    self.currentProcessTraffic.removeAll()
                    self.updateStatusPanelProcessTraffic()
                    return
                }
                if let previousUptime = self.previousProcessTrafficUptime {
                    let interval = max(uptime - previousUptime, 0.1)
                    var sampledNames = Set<String>()
                    for (name, current) in counters {
                        guard let old = self.previousProcessTrafficCounters[name] else { continue }
                        let received = current.receivedBytes >= old.receivedBytes
                            ? current.receivedBytes - old.receivedBytes : 0
                        let sent = current.sentBytes >= old.sentBytes
                            ? current.sentBytes - old.sentBytes : 0
                        sampledNames.insert(name)
                        let download = Double(received) / interval
                        let upload = Double(sent) / interval
                        let oldRate = self.smoothedProcessTraffic[name] ?? (download: 0, upload: 0)
                        self.smoothedProcessTraffic[name] = (
                            download: oldRate.download * 0.55 + download * 0.45,
                            upload: oldRate.upload * 0.55 + upload * 0.45
                        )
                        self.processTrafficIdleSamples[name] = (download >= 1 || upload >= 1)
                            ? 0 : self.processTrafficIdleSamples[name, default: 0] + 1
                    }
                    for name in self.smoothedProcessTraffic.keys where !sampledNames.contains(name) {
                        self.processTrafficIdleSamples[name, default: 0] += 1
                    }
                    for name in self.processTrafficIdleSamples.filter({ $0.value >= 4 }).map(\.key) {
                        self.smoothedProcessTraffic.removeValue(forKey: name)
                        self.processTrafficIdleSamples.removeValue(forKey: name)
                    }
                    var rates = self.smoothedProcessTraffic.map {
                        (name: $0.key, download: $0.value.download, upload: $0.value.upload)
                    }
                    rates.removeAll { $0.download + $0.upload < 1 }
                    rates.sort { ($0.download + $0.upload) > ($1.download + $1.upload) }
                    self.currentProcessTraffic = Array(rates.prefix(5))
                    self.updateStatusPanelProcessTraffic()
                }
                self.previousProcessTrafficCounters = counters
                self.previousProcessTrafficUptime = uptime
            }
        }
    }

    private func sampleVPNInterfaces() {
        guard let ticket = trafficMonitoringCoordinator.begin(.vpn) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let interfaces = self.manager.fetchActiveVPNInterfaceNames()
            DispatchQueue.main.async {
                guard self.trafficMonitoringCoordinator.complete(ticket) else {
                    self.sampleVPNInterfaces()
                    return
                }
                let changed = interfaces != self.activeVPNInterfaceNames
                if changed {
                    self.invalidateEgressIPRefresh(clearSuccessTime: true)
                }
                self.activeVPNInterfaceNames = interfaces
                self.refreshEgressIPIfNeeded(force: changed)
                if changed, !interfaces.isEmpty {
                    self.scheduleEgressIPBurstRefresh()
                } else if interfaces.isEmpty {
                    self.cancelPendingEgressIPBurstRefresh()
                }
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
            self?.sampleVPNInterfaces()
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
        let networkPresentation = currentNetworkPresentation
        let context = MenuBarRenderContext(
            symbolName: networkPresentation.symbolName,
            networkTitle: networkPresentation.title,
            vpnConnected: networkPresentation.vpnConnected,
            downloadBytesPerSecond: currentDownloadBytesPerSecond,
            uploadBytesPerSecond: currentUploadBytesPerSecond,
            showsNetworkTitle: preferences.showMenuBarTitle,
            showsSpeed: preferences.showMenuBarSpeed,
            usesTwoLines: preferences.menuBarSpeedTwoLines,
            usesBits: preferences.menuBarSpeedInBits,
            indicatorStyle: preferences.menuBarTrafficIndicatorStyle
        )
        let accessibleDownload = TrafficRateFormatter.string(
            bytesPerSecond: currentDownloadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        let accessibleUpload = TrafficRateFormatter.string(
            bytesPerSecond: currentUploadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        var accessibilityLabel = "LinkGlint · \(menuBarStatusTitle) · 下载 \(accessibleDownload) · 上传 \(accessibleUpload)"
        if networkPresentation.vpnConnected {
            accessibilityLabel += " · VPN 已开启"
        }
        button.setAccessibilityLabel(accessibilityLabel)
        menuBarRenderer.apply(to: button, statusItem: statusItem, context: context)
        updateMenuBarPreviewIfNeeded()
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
        menuBarRenderer.resetCachedPresentation()
        applyMenuBarAppearance()
    }

    private var menuBarStatusTitle: String {
        currentNetworkPresentation.title
    }

    private var currentNetworkPresentation: NetworkStatusPresentation {
        if initialRefreshError != nil, lastServices.isEmpty {
            return .init(title: "读取失败", symbolName: "exclamationmark.triangle")
        }
        return NetworkStatusPresentation.make(
            services: lastServices,
            hasLoaded: hasLoadedNetworkState,
            activeVPNInterfaceNames: activeVPNInterfaceNames
        )
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
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )
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
            description: "连接 Wi-Fi：\(NetworkDisplayText.singleLine(ssid))",
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

        updateSummaryLabel(
            statusPanelSummaryLabel,
            text: NetworkServiceSummaryText.panel(services: lastServices),
            color: .secondaryLabelColor
        )
        updateSummaryLabel(
            adapterSummaryLabel,
            text: NetworkServiceSummaryText.mainWindow(services: lastServices),
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
        updateStatusPanelDiagnosticButton()
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
        networkRefreshCoordinator.invalidateGeneration()
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
                        self.networkRefreshCoordinator.invalidateGeneration()
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
                    self.networkRefreshCoordinator.invalidateGeneration()
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
        networkRefreshCoordinator.invalidateGeneration()
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
        if privilegedAccessState == .ready {
            configurePrivilegedAccess(afterConfiguration: nil)
            return
        }
        _ = presentBlockingPrivilegedSetupIfNeeded()
    }

    private func currentAccessGuidance() -> PrivilegedAccessGuidance {
        PrivilegedAccessGuidance.make(
            state: privilegedAccessState,
            wasPreviouslyConfigured: defaults.bool(forKey: Self.privilegedOnboardingCompletedKey)
        )
    }

    @discardableResult
    private func presentBlockingPrivilegedSetupIfNeeded() -> Bool {
        let guidance = currentAccessGuidance()
        guard guidance.requiresBlockingSetup else {
            dismissBlockingPrivilegedSetupIfAllowed()
            return false
        }
        closeStatusPanel()
        mainWindow?.orderOut(nil)
        preferencesWindow?.orderOut(nil)
        hideDockIconIfNoWindowsAreVisible()

        if let existing = privilegedSetupController {
            existing.apply(guidance: guidance)
            let stealFocus = PrivilegedSetupPresentationPolicy.shouldStealFocus(
                windowAlreadyVisible: existing.isWindowVisible,
                previousGuidance: automaticallyPresentedAccessGuidance,
                newGuidance: guidance
            )
            automaticallyPresentedAccessGuidance = guidance
            if stealFocus {
                existing.presentStealingFocus()
            } else {
                existing.refreshInPlace()
            }
            return true
        }
        let controller = PrivilegedSetupWindowController(guidance: guidance)
        controller.onConfigure = { [weak self] in
            self?.beginPrivilegedAccessConfiguration(
                afterConfiguration: self?.pendingAfterPrivilegedConfiguration,
                onUnavailable: self?.pendingPrivilegedConfigurationUnavailable
            )
        }
        controller.onQuit = {
            NSApp.terminate(nil)
        }
        privilegedSetupController = controller
        automaticallyPresentedAccessGuidance = guidance
        controller.presentStealingFocus()
        return true
    }

    private func dismissBlockingPrivilegedSetupIfAllowed() {
        let phase = privilegedSetupController?.currentPhase
        guard PrivilegedSetupPresentationPolicy.shouldDismissSetupWhenAccessReady(currentPhase: phase) else {
            return
        }
        dismissBlockingPrivilegedSetup()
    }

    private func dismissBlockingPrivilegedSetup() {
        privilegedSetupController?.close()
        privilegedSetupController = nil
        automaticallyPresentedAccessGuidance = nil
        pendingAfterPrivilegedConfiguration = nil
        pendingPrivilegedConfigurationUnavailable = nil
    }

    private func schedulePrivilegedAccessGuidance(for state: PrivilegedAccessState) {
        if state == .ready {
            defaults.set(true, forKey: Self.privilegedOnboardingCompletedKey)
            dismissBlockingPrivilegedSetupIfAllowed()
            return
        }
        let guidance = PrivilegedAccessGuidance.make(
            state: state,
            wasPreviouslyConfigured: defaults.bool(forKey: Self.privilegedOnboardingCompletedKey)
        )
        guard guidance.requiresBlockingSetup else { return }
        if automaticallyPresentedAccessGuidance == guidance,
           privilegedSetupController?.isWindowVisible == true {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.privilegedAccessState == state,
                  !self.isConfiguringPrivilegedAccess else { return }
            _ = self.presentBlockingPrivilegedSetupIfNeeded()
        }
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
        let currentState = privilegedAccessState
        privilegedAccessState = currentState
        if currentState == .ready {
            afterConfiguration?()
            return
        }

        pendingAfterPrivilegedConfiguration = afterConfiguration
        pendingPrivilegedConfigurationUnavailable = onUnavailable
        _ = presentBlockingPrivilegedSetupIfNeeded()
    }

    private func presentPrivilegedAccessCompletion(onDismiss: (() -> Void)?) {
        if let existing = privilegedSetupController {
            existing.showCompletion(onDismiss: { [weak self] in
                self?.dismissBlockingPrivilegedSetup()
                onDismiss?()
            })
            existing.presentStealingFocus()
            return
        }
        let controller = PrivilegedSetupWindowController(completionOnly: true)
        controller.showCompletion(onDismiss: { [weak self] in
            self?.dismissBlockingPrivilegedSetup()
            onDismiss?()
        })
        privilegedSetupController = controller
        controller.presentStealingFocus()
    }

    private func disablePrivilegedWriteIfNeeded(_ item: NSMenuItem) {
        guard currentAccessGuidance().requiresBlockingSetup else { return }
        item.isEnabled = false
        item.toolTip = "完成管理员授权后可用"
    }

    private func beginPrivilegedAccessConfiguration(
        afterConfiguration: (() -> Void)?,
        onUnavailable: (() -> Void)?
    ) {
        guard !isConfiguringPrivilegedAccess,
              !isPerformingPrivilegedChange,
              !isApplyingServiceSwitch else {
            reportBusyNetworkOperation()
            onUnavailable?()
            return
        }
        guard privilegedAccessState != .ready else {
            afterConfiguration?()
            dismissBlockingPrivilegedSetup()
            return
        }

        privilegedSetupController?.setBusy(true)
        accessStatusLabel?.stringValue = "正在等待 macOS 完成一次管理员授权…"
        accessActionButton?.isEnabled = false
        isConfiguringPrivilegedAccess = true
        networkRefreshCoordinator.invalidateGeneration()
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
            let resolvedState = self.manager.privilegedAccessState
            DispatchQueue.main.async {
                self.isConfiguringPrivilegedAccess = false
                switch result {
                case .success(let state):
                    self.privilegedAccessState = state
                    if state == .ready {
                        self.defaults.set(true, forKey: Self.privilegedOnboardingCompletedKey)
                    }
                    self.updatePrivilegedAccessControls()
                    if !self.lastServices.isEmpty { self.rebuildMenu(with: self.lastServices) }
                    let pendingAfter = afterConfiguration ?? self.pendingAfterPrivilegedConfiguration
                    if state == .ready {
                        self.presentPrivilegedAccessCompletion(onDismiss: pendingAfter)
                    } else {
                        onUnavailable?()
                        _ = self.presentBlockingPrivilegedSetupIfNeeded()
                        self.privilegedSetupController?.setStatus("配置未完成，请重试。")
                    }
                case .failure(let error):
                    self.privilegedAccessState = resolvedState
                    self.updatePrivilegedAccessControls()
                    self.privilegedSetupController?.setBusy(false)
                    self.privilegedSetupController?.setStatus(error.localizedDescription)
                    onUnavailable?()
                    if self.privilegedSetupController == nil, onUnavailable == nil {
                        self.showError(error)
                    }
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
        networkRefreshCoordinator.invalidateGeneration()
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
                    self.defaults.set(false, forKey: Self.privilegedOnboardingCompletedKey)
                    self.automaticallyPresentedAccessGuidance = nil
                    self.updatePrivilegedAccessControls()
                    if !self.lastServices.isEmpty { self.rebuildMenu(with: self.lastServices) }
                    _ = self.presentBlockingPrivilegedSetupIfNeeded()
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
            accessDetailLabel?.stringValue = "日常网络切换不再询问密码 · 仅允许预定义的网络设置操作"
            accessActionButton?.title = "已启用"
            accessActionButton?.isEnabled = false
            accessBanner?.borderColor = NSColor.systemGreen.withAlphaComponent(0.50)
            accessBanner?.fillColor = NSColor.systemGreen.withAlphaComponent(0.08)
            accessBanner?.isHidden = true
            privilegePreferenceButton?.title = "已启用"
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
        updatePrivilegeAccessPreferencesAppearance(for: state)
        updateNetworkControlAvailability()
    }

    private func updatePrivilegeAccessPreferencesAppearance(for state: PrivilegedAccessState) {
        let accent: NSColor
        let symbol: String
        let borderAlpha: CGFloat
        let fillAlpha: CGFloat
        let hint: String
        switch state {
        case .ready:
            accent = .systemGreen
            symbol = "checkmark.shield.fill"
            borderAlpha = 0.50
            fillAlpha = 0.08
            hint = "日常网络修改不再弹出密码窗口。登录时启动使用 macOS 原生登录项，与此权限独立。"
        case .notConfigured:
            accent = .controlAccentColor
            symbol = "lock.shield.fill"
            borderAlpha = 0.45
            fillAlpha = 0.06
            hint = "首次配置会请求一次管理员授权；之后日常网络修改不再弹出密码窗口。"
        case .needsRepair:
            accent = .systemOrange
            symbol = "exclamationmark.shield.fill"
            borderAlpha = 0.55
            fillAlpha = 0.09
            hint = "网络管理组件需要修复。修复时会再请求一次管理员授权，不会更改当前网络连接。"
        }
        privilegePreferenceShield?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        privilegePreferenceShield?.contentTintColor = accent
        privilegeAccessPanel?.borderColor = accent.withAlphaComponent(borderAlpha)
        privilegeAccessPanel?.fillColor = accent.withAlphaComponent(fillAlpha)
        privilegeAccessHint?.stringValue = hint
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

    @objc private func copyCurrentConnectionSummary() {
        guard let service = lastServices.first(where: { $0.isPrimary && $0.connected })
                ?? lastServices.first(where: \.connected) else {
            NSSound.beep()
            return
        }
        let usage = usageTracker.usage()
        let downloadRate = TrafficRateFormatter.string(
            bytesPerSecond: currentDownloadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        let uploadRate = TrafficRateFormatter.string(
            bytesPerSecond: currentUploadBytesPerSecond,
            usesBits: preferences.menuBarSpeedInBits
        )
        var lines = [
            "LinkGlint 当前连接摘要",
            "====================",
            service.copyableDetails,
            "",
            "实时速率：下载 \(downloadRate) · 上传 \(uploadRate)",
            "今日记录：下载 \(formatBytes(usage.receivedBytes)) · 上传 \(formatBytes(usage.sentBytes))"
        ]
        if let lastDiagnostic {
            lines += ["", "网络检测：\(NetworkDiagnosticPresentation.make(lastDiagnostic).detail)"]
        }
        copyToPasteboard(lines.joined(separator: "\n"))
        setOperationFeedback("当前连接摘要已复制", color: .systemGreen, clearAfter: 2)
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
            let panelUsage = MenuBarRenderer.usageSummaryAttributedString(
                downloadText: formatBytes(today.receivedBytes),
                uploadText: formatBytes(today.sentBytes),
                indicatorStyle: preferences.menuBarTrafficIndicatorStyle
            )
            if statusPanelUsageLabel?.attributedStringValue.isEqual(to: panelUsage) == false {
                statusPanelUsageLabel?.attributedStringValue = panelUsage
            }
        }
        let menuText = "今日记录：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))"
        if statusContextUsageItem?.title != menuText {
            statusContextUsageItem?.title = menuText
        }
        let trafficText = "当前速率：↓ \(TrafficRateFormatter.string(bytesPerSecond: currentDownloadBytesPerSecond, usesBits: preferences.menuBarSpeedInBits)) · ↑ \(TrafficRateFormatter.string(bytesPerSecond: currentUploadBytesPerSecond, usesBits: preferences.menuBarSpeedInBits))"
        if statusContextTrafficItem?.title != trafficText {
            statusContextTrafficItem?.title = trafficText
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

    @objc private func showStatusContextMenuFromPanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let applicationToRestore = statusPanelPreviousApplication
            ?? (frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? nil : frontmostApplication)
        closeStatusPanel()
        presentStatusContextMenu(relativeTo: button, applicationToRestore: applicationToRestore)
    }

    @objc private func showPreferences() {
        if presentBlockingPrivilegedSetupIfNeeded() { return }
        NSApp.setActivationPolicy(.regular)
        if let preferencesWindow {
            updatePrivilegedAccessControls()
            updateLoginItemControls()
            updateMenuBarPreferenceControls()
            updateMenuBarPreviewIfNeeded()
            syncMenuBarPresetSegment()
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LinkGlint 偏好设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        if !window.setFrameUsingName("LinkGlint.PreferencesWindow.v2") { window.center() }
        window.setFrameAutosaveName("LinkGlint.PreferencesWindow.v2")

        let content = NSVisualEffectView()
        content.material = .contentBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        let segment = NSSegmentedControl(
            labels: ["菜单栏", "启动", "权限"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(preferencesSegmentChanged(_:))
        )
        segment.segmentStyle = .rounded
        segment.selectedSegment = 0
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.widthAnchor.constraint(equalToConstant: 280).isActive = true
        preferencesSegment = segment
        let segmentRow = NSStackView()
        segmentRow.orientation = .horizontal
        segmentRow.alignment = .centerY
        let segmentLeading = NSView()
        let segmentTrailing = NSView()
        segmentLeading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        segmentTrailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        segmentRow.addArrangedSubview(segmentLeading)
        segmentRow.addArrangedSubview(segment)
        segmentRow.addArrangedSubview(segmentTrailing)

        preferencesMenuBarPage = makeMenuBarPreferencesTab()
        preferencesLaunchPage = makeLaunchPreferencesTab()
        preferencesAccessPage = makeAccessPreferencesTab()

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        preferencesPageHost = host

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: document.topAnchor),
            host.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Keep the document locked to the clip view width so preference cards
        // stretch full-width instead of shrinking to intrinsic content size.
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let done = NSButton(title: "完成", target: self, action: #selector(closePreferences))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, done])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [segmentRow, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        for view in [segmentRow, scroll, footer] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        stack.setCustomSpacing(14, after: segmentRow)

        showPreferencesPage(at: 0)
        preferencesWindow = window
        updateLoginItemControls()
        updatePrivilegedAccessControls()
        updateMenuBarPreferenceControls()
        syncMenuBarPresetSegment()
        updateMenuBarPreviewIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func preferencesSegmentChanged(_ sender: NSSegmentedControl) {
        showPreferencesPage(at: sender.selectedSegment)
    }

    private func showPreferencesPage(at index: Int) {
        guard let host = preferencesPageHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView?
        switch index {
        case 1: page = preferencesLaunchPage
        case 2: page = preferencesAccessPage
        default: page = preferencesMenuBarPage
        }
        guard let page else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        if index == 0 {
            updateMenuBarPreferenceControls()
            updateMenuBarPreviewIfNeeded()
        } else if index == 1 {
            updateLoginItemControls()
        } else if index == 2 {
            updatePrivilegedAccessControls()
        }
    }

    private func makeMenuBarPreferencesTab() -> NSView {
        let previewCaption = NSTextField(labelWithString: "实时预览")
        previewCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        let previewHint = NSTextField(labelWithString: "改动会即时反映在上方")
        previewHint.font = .systemFont(ofSize: 11)
        previewHint.textColor = .secondaryLabelColor
        let previewHeaderSpacer = NSView()
        previewHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let previewHeader = NSStackView(views: [previewCaption, previewHeaderSpacer, previewHint])
        previewHeader.orientation = .horizontal
        previewHeader.alignment = .centerY

        let previewView = MenuBarPreviewView(frame: .zero)
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        menuBarPreviewView = previewView
        let previewCard = preferenceSection(title: nil, views: [previewHeader, previewView])

        let presets = MenuBarDisplayPreset.allCases
        let presetSegment = NSSegmentedControl(
            labels: presets.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(menuBarPresetSegmentChanged(_:))
        )
        presetSegment.segmentStyle = .rounded
        presetSegment.setAccessibilityLabel("菜单栏显示预设")
        presetSegment.translatesAutoresizingMaskIntoConstraints = false
        menuBarPresetSegment = presetSegment
        syncMenuBarPresetSegment()
        let presetCard = preferenceSection(title: "快速预设", views: [presetSegment])

        let menuTitle = preferenceCheckbox(
            title: "显示当前网络名称",
            key: "showMenuBarTitle",
            value: preferences.showMenuBarTitle
        )
        menuBarTitleCheckbox = menuTitle
        let menuSpeed = preferenceCheckbox(
            title: "显示实时上传 / 下载速度",
            key: "showMenuBarSpeed",
            value: preferences.showMenuBarSpeed
        )
        menuBarSpeedCheckbox = menuSpeed
        let contentCard = preferenceSection(title: "显示内容", views: [menuTitle, menuSpeed])

        let menuSpeedTwoLines = preferenceCheckbox(
            title: "使用紧凑双行网速",
            key: "menuBarSpeedTwoLines",
            value: preferences.menuBarSpeedTwoLines
        )
        let menuSpeedBits = preferenceCheckbox(
            title: "网速单位使用 bit/s（关闭则为 Byte/s）",
            key: "menuBarSpeedInBits",
            value: preferences.menuBarSpeedInBits
        )
        menuBarSpeedTwoLinesCheckbox = menuSpeedTwoLines
        menuBarSpeedBitsCheckbox = menuSpeedBits

        menuBarIndicatorTitle = NSTextField(labelWithString: "上下行标记")
        let indicatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        indicatorPopup.removeAllItems()
        for style in MenuBarTrafficIndicatorStyle.allCases {
            let item = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
            item.representedObject = style.rawValue
            indicatorPopup.menu?.addItem(item)
        }
        indicatorPopup.selectItem(
            at: MenuBarTrafficIndicatorStyle.allCases.firstIndex(of: preferences.menuBarTrafficIndicatorStyle) ?? 0
        )
        indicatorPopup.target = self
        indicatorPopup.action = #selector(trafficIndicatorStyleChanged(_:))
        indicatorPopup.controlSize = .small
        indicatorPopup.setAccessibilityLabel("上下行标记")
        menuBarIndicatorPopup = indicatorPopup
        let indicatorSpacer = NSView()
        indicatorSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let indicatorRow = NSStackView(views: [menuBarIndicatorTitle!, indicatorSpacer, indicatorPopup])
        indicatorRow.orientation = .horizontal
        indicatorRow.alignment = .centerY

        menuBarIntervalTitle = NSTextField(labelWithString: "刷新间隔")
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
        intervalPopup.setAccessibilityLabel("刷新间隔")
        menuBarIntervalPopup = intervalPopup
        let intervalSpacer = NSView()
        intervalSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let intervalRow = NSStackView(views: [menuBarIntervalTitle!, intervalSpacer, intervalPopup])
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY

        let speedCard = preferenceSection(
            title: "网速样式",
            views: [menuSpeedTwoLines, menuSpeedBits, indicatorRow, intervalRow]
        )

        return preferenceTabContent(views: [previewCard, presetCard, contentCard, speedCard])
    }

    private func makeLaunchPreferencesTab() -> NSView {
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
        loginSettingsButton.bezelStyle = .rounded
        loginSettingsButton.controlSize = .small
        let loginSpacer = NSView()
        loginSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let loginRow = NSStackView(views: [loginItemCheckbox!, loginSpacer, loginSettingsButton])
        loginRow.orientation = .horizontal
        loginRow.alignment = .centerY
        loginRow.spacing = 8
        loginItemStatusLabel = NSTextField(labelWithString: "")
        loginItemStatusLabel?.font = .systemFont(ofSize: 11)
        loginItemStatusLabel?.textColor = .secondaryLabelColor
        let loginHint = NSTextField(wrappingLabelWithString: "使用 macOS 原生登录项，无需管理员密码。")
        loginHint.textColor = .secondaryLabelColor
        loginHint.font = .systemFont(ofSize: 11)
        let loginCard = preferenceSection(
            title: "登录项",
            views: [loginRow, loginItemStatusLabel!, loginHint]
        )

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
        let behaviorHint = NSTextField(wrappingLabelWithString: "关闭主窗口后 Dock 图标会自动隐藏，LinkGlint 继续在菜单栏运行。")
        behaviorHint.textColor = .secondaryLabelColor
        behaviorHint.font = .systemFont(ofSize: 11)
        let behaviorCard = preferenceSection(
            title: "启动行为",
            views: [openWindow, autoDiagnostic, behaviorHint]
        )
        return preferenceTabContent(views: [loginCard, behaviorCard])
    }

    private func makeAccessPreferencesTab() -> NSView {
        let shield = NSImageView()
        shield.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)
        shield.contentTintColor = .controlAccentColor
        shield.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        shield.translatesAutoresizingMaskIntoConstraints = false
        privilegePreferenceShield = shield
        privilegePreferenceLabel = NSTextField(wrappingLabelWithString: privilegedAccessState.title)
        privilegePreferenceLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        privilegePreferenceLabel?.maximumNumberOfLines = 3
        privilegePreferenceLabel?.alignment = .left
        privilegePreferenceLabel?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusStack = NSStackView(views: [shield, privilegePreferenceLabel!])
        statusStack.orientation = .horizontal
        statusStack.alignment = .top
        statusStack.spacing = 10

        privilegePreferenceButton = NSButton(title: "开始配置…", target: self, action: #selector(showPrivilegedAccessSetup))
        privilegePreferenceButton?.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        privilegePreferenceButton?.bezelStyle = .rounded
        removePrivilegeButton = NSButton(title: "移除…", target: self, action: #selector(removePrivilegedAccess))
        removePrivilegeButton?.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        removePrivilegeButton?.bezelStyle = .rounded
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [actionSpacer, privilegePreferenceButton!, removePrivilegeButton!])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let accessHint = NSTextField(wrappingLabelWithString: "")
        accessHint.textColor = .secondaryLabelColor
        accessHint.font = .systemFont(ofSize: 11)
        accessHint.alignment = .left
        accessHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        privilegeAccessHint = accessHint

        let accessPanel = preferenceSection(
            title: nil,
            views: [statusStack, actionRow, accessHint],
            borderColor: NSColor.controlAccentColor.withAlphaComponent(0.45),
            fillColor: NSColor.controlAccentColor.withAlphaComponent(0.06)
        )
        privilegeAccessPanel = accessPanel
        let root = preferenceTabContent(views: [accessPanel])
        NSLayoutConstraint.activate([
            shield.widthAnchor.constraint(equalToConstant: 28),
            shield.heightAnchor.constraint(equalToConstant: 28)
        ])
        updatePrivilegeAccessPreferencesAppearance(for: privilegedAccessState)
        return root
    }

    private func preferenceTabContent(views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        // NSStackView's `.width` alignment does not mean "stretch arranged
        // subviews". Pinning each section explicitly prevents intrinsic-width
        // cards from drifting to the trailing edge of the preferences window.
        for view in views {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return container
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

    private func preferenceSection(
        title: String?,
        views: [NSView],
        borderColor: NSColor = NSColor.separatorColor.withAlphaComponent(0.55),
        fillColor: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
    ) -> NSBox {
        var arranged: [NSView] = []
        if let title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.alignment = .left
            arranged.append(heading)
        }
        for view in views {
            if let field = view as? NSTextField {
                field.alignment = .left
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            if let button = view as? NSButton {
                button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                button.alignment = .left
            }
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            arranged.append(view)
        }
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSBox()
        panel.boxType = .custom
        panel.cornerRadius = 12
        panel.borderWidth = 1
        panel.borderColor = borderColor
        panel.fillColor = fillColor
        panel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        panel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -14)
        ])
        for view in arranged {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return panel
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
            refreshMenuBarPreferences()
        case "showMenuBarSpeed":
            preferences.showMenuBarSpeed = enabled
            refreshMenuBarPreferences()
        case "menuBarSpeedTwoLines":
            preferences.menuBarSpeedTwoLines = enabled
            refreshMenuBarPreferences()
        case "menuBarSpeedInBits":
            preferences.menuBarSpeedInBits = enabled
            refreshMenuBarPreferences()
        case "openWindowAtLaunch":
            preferences.openWindowAtLaunch = enabled
        case "autoRunDiagnostics":
            preferences.autoRunDiagnostics = enabled
        default:
            break
        }
    }

    @objc private func menuBarPresetSegmentChanged(_ sender: NSSegmentedControl) {
        let presets = MenuBarDisplayPreset.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < presets.count else { return }
        applyMenuBarDisplayPreset(presets[sender.selectedSegment])
    }

    private func applyMenuBarDisplayPreset(_ preset: MenuBarDisplayPreset) {
        preset.apply(to: &preferences)
        syncMenuBarPreferenceControlsFromPreferences()
        syncMenuBarPresetSegment()
        refreshMenuBarPreferences()
    }

    private func syncMenuBarPresetSegment() {
        let presets = MenuBarDisplayPreset.allCases
        menuBarPresetSegment?.selectedSegment = presets.firstIndex {
            $0.matches(preferences)
        } ?? -1
    }

    private func syncMenuBarPreferenceControlsFromPreferences() {
        menuBarTitleCheckbox?.state = preferences.showMenuBarTitle ? .on : .off
        menuBarSpeedCheckbox?.state = preferences.showMenuBarSpeed ? .on : .off
        menuBarSpeedTwoLinesCheckbox?.state = preferences.menuBarSpeedTwoLines ? .on : .off
        menuBarSpeedBitsCheckbox?.state = preferences.menuBarSpeedInBits ? .on : .off
        if let styleIndex = MenuBarTrafficIndicatorStyle.allCases.firstIndex(of: preferences.menuBarTrafficIndicatorStyle) {
            menuBarIndicatorPopup?.selectItem(at: styleIndex)
        }
        if let intervalIndex = [1.0, 2.0, 5.0].firstIndex(of: preferences.trafficRefreshInterval) {
            menuBarIntervalPopup?.selectItem(at: intervalIndex)
        }
        syncMenuBarPresetSegment()
    }

    private func updateMenuBarPreferenceControls() {
        let speedEnabled = preferences.showMenuBarSpeed
        menuBarSpeedTwoLinesCheckbox?.isEnabled = speedEnabled
        menuBarSpeedBitsCheckbox?.isEnabled = speedEnabled
        menuBarIndicatorPopup?.isEnabled = speedEnabled
        menuBarIntervalPopup?.isEnabled = speedEnabled
        menuBarIndicatorTitle?.textColor = speedEnabled ? .labelColor : .disabledControlTextColor
        menuBarIntervalTitle?.textColor = speedEnabled ? .labelColor : .disabledControlTextColor
    }

    private func refreshMenuBarPreferences() {
        updateMenuBarPreferenceControls()
        syncMenuBarPresetSegment()
        menuBarRenderer.invalidateRenderCache()
        applyMenuBarAppearance()
        if statusPopover.isShown, let label = statusPanelTrafficRatesLabel {
            label.attributedStringValue = statusPanelTrafficRateText
        }
        updateUsageDisplay()
        updateMenuBarPreviewIfNeeded()
    }

    private func updateMenuBarPreviewIfNeeded() {
        guard let previewView = menuBarPreviewView else { return }
        let appearance = previewView.effectiveAppearance
        let context = MenuBarRenderContext.preview.applying(preferences: preferences)
        previewView.previewImage = menuBarRenderer.renderPreview(context: context, appearance: appearance)
    }

    @objc private func trafficIntervalChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? Double else { return }
        preferences.trafficRefreshInterval = value
        resetTrafficSampling()
        refreshMenuBarPreferences()
        scheduleTrafficTimer()
        sampleTraffic()
    }

    @objc private func trafficIndicatorStyleChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let style = MenuBarTrafficIndicatorStyle(rawValue: rawValue) else { return }
        preferences.menuBarTrafficIndicatorStyle = style
        refreshMenuBarPreferences()
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
            updateStatusPanelDiagnosticButton()
            return
        }
        isDiagnosing = true
        diagnosticPending = false
        let generation = networkRefreshCoordinator.generation
        diagnosticLabel?.isHidden = false
        diagnosticLabel?.stringValue = "网络诊断：正在检查网关与 DNS…"
        diagnosticLabel?.textColor = .secondaryLabelColor
        updateStatusPanelDiagnosticButton()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.manager.runDiagnostics()
            DispatchQueue.main.async {
                self.isDiagnosing = false
                if generation == self.networkRefreshCoordinator.generation {
                    self.lastDiagnostic = result
                    let presentation = NetworkDiagnosticPresentation.make(result)
                    self.diagnosticLabel?.stringValue = "网络诊断：\(presentation.detail)"
                    self.diagnosticLabel?.textColor = result.isUsable ? .systemGreen : .systemOrange
                } else {
                    self.diagnosticLabel?.stringValue = "网络诊断：连接已变化，正在重新检查…"
                    self.diagnosticLabel?.textColor = .secondaryLabelColor
                    self.diagnosticPending = true
                }
                self.updateStatusPanelDiagnosticButton()
                if self.diagnosticPending { self.runDiagnostics() }
            }
        }
    }

    private func updateStatusPanelDiagnosticButton() {
        guard let button = statusPanelDiagnosticButton else { return }
        if isDiagnosing {
            button.title = "检测中…"
            button.toolTip = "正在检查默认路由、网关延迟与 DNS"
            button.contentTintColor = .systemOrange
            button.isEnabled = false
        } else if networkMutationIsActive {
            button.title = diagnosticPending ? "等待检测" : "网络检测"
            button.toolTip = "当前网络操作完成后可运行检测"
            button.contentTintColor = .secondaryLabelColor
            button.isEnabled = false
        } else {
            let presentation = NetworkDiagnosticPresentation.make(lastDiagnostic)
            button.title = presentation.title
            button.toolTip = presentation.detail
            button.contentTintColor = presentation.isHealthy.map {
                $0 ? NSColor.systemGreen : NSColor.systemOrange
            } ?? .secondaryLabelColor
            button.isEnabled = true
        }
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityHelp(button.toolTip ?? "运行网络检测")
    }

    private func invalidateDiagnosticResult() {
        lastDiagnostic = nil
        updateStatusPanelDiagnosticButton()
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
        if presentBlockingPrivilegedSetupIfNeeded() { return }
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
        headerIcon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        // The adjacent title already conveys the brand. Exposing this decorative
        // symbol creates a duplicate "LinkGlint" stop for VoiceOver.
        headerIcon.setAccessibilityElement(false)
        headerIcon.setAccessibilityHidden(true)
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
        shield.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)
        shield.setAccessibilityElement(false)
        shield.setAccessibilityHidden(true)
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
        profilePopup.setAccessibilityLabel("网络方案")
        profilePopup.setAccessibilityHelp("选择要应用的网络配置方案")
        profilePopup.controlSize = .small
        profilePopup.cell?.lineBreakMode = .byTruncatingTail
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        let applyProfileButton = NSButton(title: "应用", target: self, action: #selector(applySelectedProfile))
        applyProfileButton.identifier = NSUserInterfaceItemIdentifier("network-operation-control")
        applyProfileButton.setAccessibilityLabel("应用所选网络方案")
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
            var text = "当前网络：\(NetworkDisplayText.singleLine(primary.name))"
            if let ssid = primary.ssid { text += " · \(NetworkDisplayText.singleLine(ssid))" }
            if let ip = primary.ipAddress { text += " · \(ip)" }
            overviewLabel.stringValue = text
        } else if let connected = services.first(where: \.connected) {
            overviewLabel.stringValue = "已连接：\(NetworkDisplayText.singleLine(connected.name))"
                + (connected.ipAddress.map { " · \($0)" } ?? "")
        } else {
            overviewLabel.stringValue = "当前没有已连接网络"
        }
        adapterSummaryLabel?.stringValue = NetworkServiceSummaryText.mainWindow(services: services)
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
        // Service name and state are represented by the neighboring labels.
        // Keeping the icon out of the accessibility tree avoids reading every
        // adapter name twice.
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityHidden(true)
        iconView.contentTintColor = service.connected ? accentColor : .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let displayName = NetworkDisplayText.singleLine(service.name)
        let name = NSTextField(labelWithString: displayName)
        name.font = .systemFont(ofSize: 12.5, weight: service.connected ? .semibold : .medium)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = displayName

        var detailParts = [service.connected ? "已连接" : (service.enabled ? "未连接" : "已停用")]
        if let ssid = service.ssid { detailParts.append(NetworkDisplayText.singleLine(ssid)) }
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
        toggle.toolTip = service.enabled ? "停用 \(displayName)" : "启用 \(displayName)"
        toggle.setAccessibilityLabel("\(displayName) 网络服务")
        toggle.setAccessibilityHelp(service.enabled ? "停用 \(displayName)" : "启用 \(displayName)")

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
        button.setAccessibilityLabel("\(NetworkDisplayText.singleLine(service.name)) 的更多操作")
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

private final class ProcessTrafficRowView: NSView {
    private let rankLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let downloadLabel = NSTextField(labelWithString: "")
    private let uploadLabel = NSTextField(labelWithString: "")
    private let stripe: Bool

    init(rank: Int) {
        stripe = rank.isMultiple(of: 2)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        if stripe {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.06).cgColor
        }
        rankLabel.stringValue = "\(rank)"
        rankLabel.alignment = .center
        rankLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        rankLabel.textColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadLabel.textColor = MenuBarTrafficColors.download
        uploadLabel.textColor = MenuBarTrafficColors.upload
        for label in [downloadLabel, uploadLabel] {
            label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }
        let nameStack = NSStackView(views: [iconView, nameLabel])
        nameStack.orientation = .horizontal; nameStack.spacing = 5; nameStack.alignment = .centerY
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [rankLabel, nameStack, spacer, downloadLabel, uploadLabel])
        row.orientation = .horizontal; row.spacing = 5; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: LinkGlintLayout.processRowHeight),
            rankLabel.widthAnchor.constraint(equalToConstant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 14), iconView.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        name: String,
        icon: NSImage?,
        download: String,
        upload: String
    ) {
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        iconView.image = icon
        downloadLabel.stringValue = download
        uploadLabel.stringValue = upload
        alphaValue = 1
        if stripe {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.06).cgColor
        }
    }

    func showPlaceholder() {
        rankLabel.stringValue = ""
        nameLabel.stringValue = "等待检测到活动进程…"
        nameLabel.toolTip = nil
        iconView.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        downloadLabel.stringValue = "—"
        uploadLabel.stringValue = "—"
        alphaValue = 0.48
    }

    func clearSlot() {
        rankLabel.stringValue = ""
        nameLabel.stringValue = ""
        nameLabel.toolTip = nil
        iconView.image = nil
        downloadLabel.stringValue = ""
        uploadLabel.stringValue = ""
        alphaValue = 0
        layer?.backgroundColor = nil
    }
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
