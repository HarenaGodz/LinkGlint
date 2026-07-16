import AppKit
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let manager = NetworkManager()
    private let profileStore = NetworkProfileStore()
    private let usageTracker = UsageTracker()
    private var preferences = AppPreferences()
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow!
    private var preferencesWindow: NSWindow?
    private var servicesStack: NSStackView!
    private var overviewLabel: NSTextField!
    private var diagnosticLabel: NSTextField!
    private var profilePopup: NSPopUpButton!
    private var deleteProfileButton: NSButton!
    private var usageLabel: NSTextField!
    private var loginItemCheckbox: NSButton!
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
    private let pathMonitorQueue = DispatchQueue(label: "local.codex.NetBar.path-monitor")
    private var pendingPathRefresh: DispatchWorkItem?
    private var isRefreshing = false
    private var isSamplingTraffic = false
    private var isDiagnosing = false
    private var lastServices: [NetworkService] = []
    private var lastDiagnostic: NetworkDiagnostic?
    private var previousTrafficCounters: [String: InterfaceCounters] = [:]
    private var previousTrafficSampleDate: Date?
    private var trafficLabels: [String: NSTextField] = [:]
    private var lastAutoDiagnosticAt: Date?
    private var hasLoadedNetworkState = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as a menu-bar app. Showing a management window temporarily restores
        // the regular policy; closing the last window removes the Dock icon again.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "local.codex.NetBar.network-status"
        statusItem.isVisible = true
        statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "网络管理")
        // Keep a text label visible as well. This avoids an apparently "missing"
        // app when a system symbol is unavailable or hard to spot among many items.
        applyMenuBarAppearance()
        statusItem.button?.toolTip = "NetBar 网络管理"

        createMainWindow()
        showLoadingMenu()
        if preferences.openWindowAtLaunch {
            showMainWindow()
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sampleTraffic()
        }
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
        // Closing the management window intentionally leaves the status item and
        // timers alive. Brief feedback makes this behavior discoverable without
        // interrupting the user's workflow with another dialog.
        statusItem.button?.title = "仍在菜单栏运行"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "NetBar 仍在菜单栏运行；从菜单选择“退出 NetBar”可完全结束"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.applyMenuBarAppearance()
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
        statusItem.menu = menu
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let services = try self.manager.fetchServices()
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.hasLoadedNetworkState = true
                    self.lastServices = services
                    self.rebuildMenu(with: services)
                    self.rebuildWindow(with: services)
                    self.sampleTraffic()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.showError(error)
                }
            }
        }
    }

    private func rebuildMenu(with services: [NetworkService]) {
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
        statusItem.menu = menu
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

        let today = usageTracker.usage()
        let usageItem = NSMenuItem(
            title: "今日用量：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))",
            action: nil,
            keyEquivalent: ""
        )
        usageItem.identifier = NSUserInterfaceItemIdentifier("daily-usage")
        usageItem.isEnabled = false
        menu.addItem(usageItem)

        let usageHistory = NSMenuItem(title: "查看用量历史…", action: #selector(showUsageHistory), keyEquivalent: "")
        usageHistory.target = self
        menu.addItem(usageHistory)

        let resetUsage = NSMenuItem(title: "重置今日用量…", action: #selector(resetTodayUsage), keyEquivalent: "")
        resetUsage.target = self
        menu.addItem(resetUsage)

        let showWindow = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "1")
        showWindow.target = self
        menu.addItem(showWindow)

        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let diagnostic = NSMenuItem(title: "运行网络诊断", action: #selector(runDiagnostics), keyEquivalent: "d")
        diagnostic.target = self
        menu.addItem(diagnostic)

        let copyReport = NSMenuItem(title: "复制诊断报告", action: #selector(copyDiagnosticReport), keyEquivalent: "")
        copyReport.target = self
        menu.addItem(copyReport)

        let exportReport = NSMenuItem(title: "导出诊断报告…", action: #selector(exportDiagnosticReport), keyEquivalent: "")
        exportReport.target = self
        menu.addItem(exportReport)

        let settings = NSMenuItem(title: "打开网络设置…", action: #selector(openNetworkSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let accessReady = manager.privilegedAccessState == .ready
        let accessItem = NSMenuItem(
            title: accessReady ? "免密码网络切换：已启用" : "配置免密码网络切换…",
            action: #selector(showPrivilegedAccessSetup),
            keyEquivalent: ""
        )
        accessItem.target = self
        accessItem.state = accessReady ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(accessItem)

        let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLoginMenu(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItemState
        menu.addItem(loginItem)

        let preferencesItem = NSMenuItem(title: "NetBar 偏好设置…", action: #selector(showPreferences), keyEquivalent: "")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NetBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func updateStatusIcon(_ services: [NetworkService]) {
        let active = services.first(where: { $0.isPrimary && $0.connected })
            ?? services.first(where: \.connected)
        let presentation = NetworkStatusPresentation.make(services: services, hasLoaded: hasLoadedNetworkState)
        statusItem.button?.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: "网络状态")
        applyMenuBarAppearance()
        statusItem.button?.toolTip = active.map {
            var text = "NetBar · 已连接 · \($0.name)"
            if let ssid = $0.ssid { text += " · \(ssid)" }
            if let ip = $0.ipAddress { text += " · \(ip)" }
            return text
        } ?? "NetBar · 离线 · 当前无网络连接"
    }

    private func schedulePathRefresh() {
        pendingPathRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh()
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
                    let activeDevices = Set(self.lastServices.filter(\.connected).compactMap(\.device))
                    var totalReceived: UInt64 = 0
                    var totalSent: UInt64 = 0
                    for (device, current) in counters {
                        guard let previous = self.previousTrafficCounters[device] else { continue }
                        let received = current.receivedBytes >= previous.receivedBytes
                            ? current.receivedBytes - previous.receivedBytes : 0
                        let sent = current.sentBytes >= previous.sentBytes
                            ? current.sentBytes - previous.sentBytes : 0
                        if activeDevices.contains(device) {
                            totalReceived &+= received
                            totalSent &+= sent
                        }
                        if let label = self.trafficLabels[device] {
                            label.stringValue = "↓ \(self.formatRate(Double(received) / interval))   ↑ \(self.formatRate(Double(sent) / interval))"
                        }
                    }
                    self.usageTracker.record(receivedBytes: totalReceived, sentBytes: totalSent, at: sampleDate)
                    self.updateUsageDisplay()
                }
                self.previousTrafficCounters = counters
                self.previousTrafficSampleDate = sampleDate
            }
        }
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
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
        button.title = preferences.showMenuBarTitle ? menuBarStatusTitle : ""
        button.imagePosition = preferences.showMenuBarTitle ? .imageLeading : .imageOnly
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

        performPrivilegedChange(description: enable ? "启用 \(name)" : "停用 \(name)") { [manager] in
            try manager.setService(name, enabled: enable)
        }
    }

    @objc private func toggleWiFiPower(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let device = data["device"] as? String,
              let enable = data["enable"] as? Bool else { return }

        performPrivilegedChange(description: enable ? "打开 Wi-Fi" : "关闭 Wi-Fi") { [manager] in
            try manager.setWiFiPower(device: device, enabled: enable)
        }
    }

    @objc private func switchToService(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? NSDictionary,
              let target = data["target"] as? String,
              let others = data["others"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }

        let wifiDevice = wifiDeviceValue.isEmpty ? nil : wifiDeviceValue
        performPrivilegedChange(description: "切换到 \(target)") { [manager] in
            try manager.switchToService(target, otherServices: others, wifiDevice: wifiDevice)
        }
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

    private func setHighestPriority(service: String, currentOrder: [String]) {
        performPrivilegedChange(description: "提高优先级：\(service)") { [manager] in
            try manager.setHighestPriority(service: service, currentOrder: currentOrder)
        }
    }

    private func performPrivilegedChange(description: String, operation: @escaping () throws -> Void) {
        guard manager.privilegedAccessState == .ready else {
            configurePrivilegedAccess { [weak self] in
                self?.performPrivilegedChange(description: description, operation: operation)
            }
            return
        }
        statusItem.button?.toolTip = "\(description)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try operation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error)
                }
            }
        }
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
        alert.informativeText = "下一步会显示一次 macOS 管理员授权。NetBar 将安装只允许网络设置操作的本机助手；完成后，日常切换和登录启动均不再输入密码。"
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
                alert.informativeText = "请在“系统设置 → 通用 → 登录项”中允许 NetBar。"
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
        if let menu = statusItem.menu {
            for item in menu.items where item.title == "登录时启动" {
                item.state = loginItemState
            }
        }
    }

    @objc private func copyMenuValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        copyToPasteboard(value)
    }

    @objc private func copyButtonValue(_ sender: NetworkActionButton) {
        guard let value = sender.payload?["value"] as? String else { return }
        copyToPasteboard(value)
        sender.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = "复制"
        }
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
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileStore.delete(id: id)
        updateProfilePopup()
        rebuildMenu(with: lastServices)
    }

    @objc private func profileSelectionChanged() {
        let token = profilePopup.selectedItem?.representedObject as? String ?? ""
        deleteProfileButton?.isEnabled = token.hasPrefix("profile:")
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
        profileSelectionChanged()
    }

    private func updateUsageDisplay() {
        let today = usageTracker.usage()
        let text = "今日  ↓ \(formatBytes(today.receivedBytes))   ↑ \(formatBytes(today.sentBytes))"
        usageLabel?.stringValue = text
        if let item = statusItem?.menu?.items.first(where: { $0.identifier?.rawValue == "daily-usage" }) {
            item.title = "今日用量：↓ \(formatBytes(today.receivedBytes)) · ↑ \(formatBytes(today.sentBytes))"
        }
    }

    @objc private func resetTodayUsage() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重置今天的网络用量？"
        alert.informativeText = "只会清除 NetBar 从本机接口统计的今日累计值，不会影响网络设置。"
        alert.addButton(withTitle: "重置")
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
        alert.messageText = "最近网络用量"
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showPreferences() {
        NSApp.setActivationPolicy(.regular)
        if let preferencesWindow {
            updatePrivilegedAccessControls()
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NetBar 偏好设置"
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
        let generalStack = NSStackView(views: [menuTitle, openWindow, autoDiagnostic])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
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

        let closeHint = NSTextField(wrappingLabelWithString: "关闭主窗口后 Dock 图标会自动隐藏，NetBar 继续在菜单栏运行；从菜单选择“退出 NetBar”可完全结束。登录时启动使用 macOS 原生登录项，不需要管理员密码。如暂时看不到状态项，请展开菜单栏隐藏区域并按住 ⌘ 将 NetBar 拖到常驻区域。")
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
        updatePrivilegedAccessControls()
        window.makeKeyAndOrderFront(nil)
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
        case "openWindowAtLaunch":
            preferences.openWindowAtLaunch = enabled
        case "autoRunDiagnostics":
            preferences.autoRunDiagnostics = enabled
        default:
            break
        }
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
        panel.title = "导出 NetBar 诊断报告"
        panel.nameFieldStringValue = "NetBar-诊断报告-\(reportFileTimestamp()).txt"
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
            "NetBar 网络诊断报告",
            "生成时间：\(formatter.string(from: Date()))",
            "NetBar 版本：\(version)",
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
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func hideMainWindow() {
        mainWindow?.orderOut(nil)
        showMenuBarRunningFeedback()
        hideDockIconIfNoWindowsAreVisible()
    }

    private func createMainWindow() {
        mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.title = "NetBar"
        mainWindow.minSize = NSSize(width: 680, height: 480)
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
        headerIcon.image = NSImage(systemSymbolName: "network", accessibilityDescription: "NetBar")
        headerIcon.symbolConfiguration = .init(pointSize: 24, weight: .semibold)
        headerIcon.contentTintColor = .systemBlue
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "NetBar")
        title.font = .systemFont(ofSize: 21, weight: .bold)
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
        header.spacing = 9

        // This compact banner is visible only until the one-time setup is ready.
        accessBanner = NSBox()
        accessBanner.boxType = .custom
        accessBanner.cornerRadius = 10
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
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        profilePopup.controlSize = .small
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        let applyProfileButton = NSButton(title: "应用", target: self, action: #selector(applySelectedProfile))
        applyProfileButton.bezelStyle = .rounded
        applyProfileButton.controlSize = .small
        applyProfileButton.contentTintColor = .systemBlue
        deleteProfileButton = NSButton()
        deleteProfileButton.isHidden = true
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
        profilePanel.cornerRadius = 10
        profilePanel.borderWidth = 1
        profilePanel.borderColor = NSColor.separatorColor.withAlphaComponent(0.65)
        profilePanel.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.56)
        profilePanel.contentView?.addSubview(profileRow)
        updateProfilePopup()

        let adaptersTitle = NSTextField(labelWithString: "网络适配器")
        adaptersTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let adapterHint = NSTextField(labelWithString: "开关用于启用或停用 · 更多操作在 ⋯")
        adapterHint.font = .systemFont(ofSize: 10.5)
        adapterHint.textColor = .tertiaryLabelColor
        let adapterHeaderSpacer = NSView()
        adapterHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let adapterHeader = NSStackView(views: [adaptersTitle, adapterHeaderSpacer, adapterHint])
        adapterHeader.orientation = .horizontal
        adapterHeader.alignment = .centerY

        servicesStack = NSStackView()
        servicesStack.orientation = .vertical
        servicesStack.alignment = .width
        servicesStack.spacing = 8
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
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 17),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
            headerIcon.widthAnchor.constraint(equalToConstant: 32),
            headerIcon.heightAnchor.constraint(equalToConstant: 32),
            shield.widthAnchor.constraint(equalToConstant: 22),
            shield.heightAnchor.constraint(equalToConstant: 22),
            accessRow.topAnchor.constraint(equalTo: accessBanner.contentView!.topAnchor, constant: 8),
            accessRow.bottomAnchor.constraint(equalTo: accessBanner.contentView!.bottomAnchor, constant: -8),
            accessRow.leadingAnchor.constraint(equalTo: accessBanner.contentView!.leadingAnchor, constant: 12),
            accessRow.trailingAnchor.constraint(equalTo: accessBanner.contentView!.trailingAnchor, constant: -12),
            profilePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            profileRow.topAnchor.constraint(equalTo: profilePanel.contentView!.topAnchor, constant: 9),
            profileRow.bottomAnchor.constraint(equalTo: profilePanel.contentView!.bottomAnchor, constant: -9),
            profileRow.leadingAnchor.constraint(equalTo: profilePanel.contentView!.leadingAnchor, constant: 12),
            profileRow.trailingAnchor.constraint(equalTo: profilePanel.contentView!.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
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
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 28)
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
        menu.addItem(.separator())
        addToolItem(menu, title: "用量历史…", symbol: "chart.bar", action: #selector(showUsageHistory))
        addToolItem(menu, title: "重置今日用量…", symbol: "arrow.counterclockwise", action: #selector(resetTodayUsage))
        menu.addItem(.separator())
        addToolItem(menu, title: "打开网络设置…", symbol: "gear", action: #selector(openNetworkSettings))
        addToolItem(menu, title: "偏好设置…", symbol: "slider.horizontal.3", action: #selector(showPreferences))
        return button
    }

    private func addToolItem(_ menu: NSMenu, title: String, symbol: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private func rebuildWindow(with services: [NetworkService]) {
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
    }

    private func serviceCard(_ service: NetworkService, allServices: [NetworkService]) -> NSView {
        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 10
        card.borderWidth = 1
        let accentColor: NSColor
        switch service.kind {
        case .wifi: accentColor = .systemBlue
        case .ethernet: accentColor = .systemTeal
        case .vpn: accentColor = .systemPurple
        case .other: accentColor = .systemGray
        }
        card.borderColor = service.connected
            ? accentColor.withAlphaComponent(0.34)
            : NSColor.separatorColor.withAlphaComponent(0.58)
        card.fillColor = service.connected
            ? accentColor.withAlphaComponent(0.045)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.40)
        card.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = symbol(for: service)
        iconView.contentTintColor = service.connected ? accentColor : .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 19, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameText = service.name + (service.isPrimary ? "  ·  默认" : "")
        let name = NSTextField(labelWithString: nameText)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        var detailParts = [service.connected ? "已连接" : (service.enabled ? "未连接" : "已停用")]
        if let ssid = service.ssid { detailParts.append(ssid) }
        if let ip = service.ipAddress { detailParts.append(ip) }
        if let device = service.device { detailParts.append(device) }
        let detail = NSTextField(labelWithString: detailParts.joined(separator: "  ·  "))
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = service.connected ? accentColor : .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let traffic = NSTextField(labelWithString: service.connected ? "↓ 正在采样…   ↑ 正在采样…" : "")
        traffic.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        traffic.textColor = .tertiaryLabelColor
        traffic.isHidden = !service.connected || service.device == nil
        if service.connected, let device = service.device { trafficLabels[device] = traffic }

        let labels = NSStackView(views: [name, detail, traffic])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
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
        let row = NSStackView(views: [iconView, labels, spacer, toggle, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(row)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25),
            row.topAnchor.constraint(equalTo: card.contentView!.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.contentView!.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: card.contentView!.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: card.contentView!.trailingAnchor, constant: -11)
        ])
        return card
    }

    private func serviceActionsButton(_ service: NetworkService, allServices: [NetworkService]) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.setAccessibilityLabel("\(service.name) 的更多操作")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
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
        performPrivilegedChange(description: enable ? "启用 \(name)" : "停用 \(name)") { [manager] in
            try manager.setService(name, enabled: enable)
        }
    }

    @objc private func windowToggleService(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let name = data["name"] as? String,
              let enable = data["enable"] as? Bool else { return }
        performPrivilegedChange(description: enable ? "启用 \(name)" : "停用 \(name)") { [manager] in
            try manager.setService(name, enabled: enable)
        }
    }

    @objc private func windowToggleWiFi(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let device = data["device"] as? String,
              let enable = data["enable"] as? Bool else { return }
        performPrivilegedChange(description: enable ? "打开 Wi-Fi" : "关闭 Wi-Fi") { [manager] in
            try manager.setWiFiPower(device: device, enabled: enable)
        }
    }

    @objc private func windowSwitchToService(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let target = data["target"] as? String,
              let others = data["others"] as? [String],
              let wifiDeviceValue = data["wifiDevice"] as? String else { return }
        performPrivilegedChange(description: "切换到 \(target)") { [manager] in
            try manager.switchToService(
                target,
                otherServices: others,
                wifiDevice: wifiDeviceValue.isEmpty ? nil : wifiDeviceValue
            )
        }
    }

    @objc private func windowDNSSettings(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let service = data["service"] as? String,
              let servers = data["servers"] as? [String] else { return }
        showDNSSettings(service: service, currentServers: servers)
    }

    @objc private func windowSetHighestPriority(_ sender: NetworkActionButton) {
        guard let data = sender.payload,
              let service = data["service"] as? String,
              let order = data["order"] as? [String] else { return }
        setHighestPriority(service: service, currentOrder: order)
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

private final class NetworkToggleSwitch: NSSwitch {
    var payload: NSDictionary?
}

/// NSScrollView otherwise starts an auto-layout document at its bottom edge.
/// A flipped document gives the service list the natural top-to-bottom order.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
