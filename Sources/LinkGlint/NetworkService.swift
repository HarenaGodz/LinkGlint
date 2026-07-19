import Foundation
import Network
import Darwin
import CoreWLAN

struct WiFiNetwork: Equatable {
    let ssid: String
    let rssiValue: Int
    let isSecure: Bool

    var signalDescription: String {
        if rssiValue >= -50 { return "信号极佳" }
        if rssiValue >= -60 { return "信号良好" }
        if rssiValue >= -70 { return "信号一般" }
        return "信号较弱"
    }
}

struct WiFiScanResult: Equatable {
    let networks: [WiFiNetwork]
    let currentSSID: String?
}

enum WiFiSSIDReadOutcome: Equatable {
    /// The command completed. A nil value explicitly means the interface is
    /// not associated and must clear any older name.
    case current(String?)
    /// The command itself failed, so its result says nothing about association.
    case failed
}

/// Smooths over a short-lived `networksetup -getairportnetwork` failure without
/// turning an old SSID into permanent state. Explicit disconnects clear the
/// cache immediately; command failures may reuse one recent trusted value.
struct WiFiSSIDStabilityCache {
    private var entries: [String: (ssid: String, checkedAtUptime: TimeInterval)] = [:]
    let fallbackLifetime: TimeInterval

    init(fallbackLifetime: TimeInterval = 90) {
        self.fallbackLifetime = max(fallbackLifetime, 0)
    }

    mutating func resolve(
        device: String,
        connectionIsEligible: Bool,
        outcome: WiFiSSIDReadOutcome,
        uptime: TimeInterval
    ) -> String? {
        guard connectionIsEligible else {
            entries.removeValue(forKey: device)
            return nil
        }
        switch outcome {
        case .current(let ssid):
            if let ssid {
                entries[device] = (ssid, uptime)
            } else {
                entries.removeValue(forKey: device)
            }
            return ssid
        case .failed:
            guard let cached = entries[device],
                  uptime >= cached.checkedAtUptime,
                  uptime - cached.checkedAtUptime <= fallbackLifetime else {
                entries.removeValue(forKey: device)
                return nil
            }
            return cached.ssid
        }
    }
}

enum WiFiNetworkCatalog {
    static func normalized(_ networks: [WiFiNetwork], currentSSID: String?) -> [WiFiNetwork] {
        var strongestBySSID: [String: WiFiNetwork] = [:]
        for network in networks {
            guard !network.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Leading and trailing spaces are legal SSID bytes. Use trimming
            // only to reject an all-whitespace placeholder, never as the name
            // sent back to CoreWLAN/networksetup.
            if network.rssiValue > (strongestBySSID[network.ssid]?.rssiValue ?? Int.min) {
                strongestBySSID[network.ssid] = network
            }
        }
        return strongestBySSID.values.sorted { lhs, rhs in
            let lhsCurrent = lhs.ssid == currentSSID
            let rhsCurrent = rhs.ssid == currentSSID
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            if lhs.rssiValue != rhs.rssiValue { return lhs.rssiValue > rhs.rssiValue }
            return lhs.ssid.localizedStandardCompare(rhs.ssid) == .orderedAscending
        }
    }
}

struct NetworkService: Hashable {
    enum Kind {
        case wifi
        case ethernet
        case cellular
        case vpn
        case other
    }

    let name: String
    let orderIndex: Int
    let hardwarePort: String?
    let device: String?
    let enabled: Bool
    let connected: Bool
    let ipAddress: String?
    let subnetMask: String?
    let router: String?
    let dnsServers: [String]
    let macAddress: String?
    let ssid: String?
    let isPrimary: Bool
    let kind: Kind
    let wifiPowered: Bool?

    var copyableDetails: String {
        var lines = [
            "网络服务：\(name)",
            "服务优先级：\(orderIndex + 1)",
            "状态：\(connected ? "已连接" : (enabled ? "已启用（未连接）" : "已停用"))"
        ]
        if isPrimary { lines.append("默认网络：是") }
        if let hardwarePort { lines.append("硬件端口：\(hardwarePort)") }
        if let device { lines.append("设备：\(device)") }
        if let ssid { lines.append("Wi-Fi：\(ssid)") }
        if let ipAddress { lines.append("IP 地址：\(ipAddress)") }
        if let subnetMask { lines.append("子网掩码：\(subnetMask)") }
        if let router { lines.append("路由器：\(router)") }
        if !dnsServers.isEmpty { lines.append("DNS：\(dnsServers.joined(separator: ", "))") }
        if let macAddress { lines.append("MAC 地址：\(macAddress)") }
        return lines.joined(separator: "\n")
    }

    var isPhysicalTransport: Bool {
        kind == .wifi || kind == .ethernet || kind == .cellular
    }
}

enum NetworkServiceActionPolicy {
    static func offersSwitch(to service: NetworkService) -> Bool {
        guard service.isPhysicalTransport else { return false }
        // Switching to the route that is already active does not change the
        // user's connection or service order.
        return !service.isPrimary || !service.connected
    }
}

struct InterfaceCounters: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct TrafficSampleResult: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let deltasByDevice: [String: InterfaceCounters]
}

enum TrafficSampleCalculator {
    static func calculate(
        previous: [String: InterfaceCounters],
        current: [String: InterfaceCounters],
        services: [NetworkService]
    ) -> TrafficSampleResult {
        var deltas: [String: InterfaceCounters] = [:]
        for (device, counters) in current {
            guard let old = previous[device] else { continue }
            deltas[device] = InterfaceCounters(
                receivedBytes: counters.receivedBytes >= old.receivedBytes
                    ? counters.receivedBytes - old.receivedBytes : 0,
                sentBytes: counters.sentBytes >= old.sentBytes
                    ? counters.sentBytes - old.sentBytes : 0
            )
        }

        // A packet can appear on both a VPN and its underlying Wi-Fi/Ethernet
        // interface. Summing every connected service therefore double-counts
        // traffic. The default-route device is the authoritative menu-bar rate.
        let measuredDevice = services.first(where: { $0.connected && $0.isPrimary })?.device
            ?? services.first(where: { $0.connected && $0.kind != .vpn })?.device
            ?? services.first(where: \.connected)?.device
        let measured = measuredDevice.flatMap { deltas[$0] }
            ?? InterfaceCounters(receivedBytes: 0, sentBytes: 0)
        return TrafficSampleResult(
            receivedBytes: measured.receivedBytes,
            sentBytes: measured.sentBytes,
            deltasByDevice: deltas
        )
    }
}

enum NetworkServiceTransition {
    static func settingEnabled(
        services: [NetworkService],
        named target: String,
        enabled: Bool
    ) -> [NetworkService] {
        guard services.contains(where: { $0.name == target }) else { return services }
        return services.map { service in
            guard service.name == target else { return service }
            return NetworkService(
                name: service.name,
                orderIndex: service.orderIndex,
                hardwarePort: service.hardwarePort,
                device: service.device,
                enabled: enabled,
                connected: enabled ? service.connected : false,
                ipAddress: enabled ? service.ipAddress : nil,
                subnetMask: enabled ? service.subnetMask : nil,
                router: enabled ? service.router : nil,
                dnsServers: service.dnsServers,
                macAddress: service.macAddress,
                ssid: enabled ? service.ssid : nil,
                isPrimary: enabled ? service.isPrimary : false,
                kind: service.kind,
                wifiPowered: service.wifiPowered
            )
        }
    }

    static func switching(
        services: [NetworkService],
        target: String
    ) -> [NetworkService] {
        guard services.contains(where: { $0.name == target }) else { return services }
        return services.map { service in
            let isTarget = service.name == target
            return NetworkService(
                name: service.name,
                orderIndex: service.orderIndex,
                hardwarePort: service.hardwarePort,
                device: service.device,
                enabled: isTarget ? true : service.enabled,
                connected: service.connected,
                ipAddress: service.ipAddress,
                subnetMask: service.subnetMask,
                router: service.router,
                dnsServers: service.dnsServers,
                macAddress: service.macAddress,
                ssid: service.ssid,
                isPrimary: service.isPrimary,
                kind: service.kind,
                wifiPowered: service.kind == .wifi && isTarget ? true : service.wifiPowered
            )
        }
    }
}

struct NetworkDiagnostic {
    let date: Date
    let defaultInterface: String?
    let gateway: String?
    let gatewayLatencyMilliseconds: Double?
    let dnsLookupSucceeded: Bool
    let systemDNSServers: [String]

    var summary: String {
        guard defaultInterface != nil else { return "未检测到默认网络" }
        if gatewayLatencyMilliseconds != nil && dnsLookupSucceeded { return "网络状态良好" }
        if gatewayLatencyMilliseconds == nil && dnsLookupSucceeded { return "网络可用 · 网关未响应延迟检测" }
        if gatewayLatencyMilliseconds == nil { return "网络连通性需要检查" }
        return "DNS 查询异常"
    }

    var isUsable: Bool { defaultInterface != nil && dnsLookupSucceeded }
}

enum NetworkError: LocalizedError {
    case commandFailed(String)
    case privilegedAccessRequired

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .privilegedAccessRequired:
            return "请先完成一次免密码网络切换配置。之后日常网络修改不再要求输入密码；登录时启动无需此权限。"
        }
    }
}

/// Avoid driving CoreWLAN association and radio scanning concurrently. The app
/// performs both operations away from the main thread; this gate serializes
/// access while keeping the wait bounded if a framework call gets stuck inside
/// macOS.
final class CoreWLANAccessGate {
    private let semaphore = DispatchSemaphore(value: 1)

    func withAccess<T>(
        waitTimeout: TimeInterval = 3,
        operation: () throws -> T
    ) throws -> T {
        guard semaphore.wait(timeout: .now() + max(waitTimeout, 0)) == .success else {
            throw NetworkError.commandFailed(
                "Wi-Fi 正在完成另一项扫描或连接，请稍后重试。"
            )
        }
        defer { semaphore.signal() }
        return try operation()
    }
}

enum CommandRunner {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval? = 20
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let stateLock = NSLock()
        var timedOut = false
        let timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                stateLock.lock()
                defer { stateLock.unlock() }
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
                let processID = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    if process.isRunning { kill(processID, SIGKILL) }
                }
            }
            timeoutWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(timeout, 0.1), execute: work)
        } else {
            timeoutWork = nil
        }
        // Drain the pipe while the child is running. Waiting first can deadlock
        // once output fills the kernel pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork?.cancel()
        stateLock.lock()
        let didTimeOut = timedOut
        stateLock.unlock()
        let text = String(data: data, encoding: .utf8) ?? ""
        if didTimeOut {
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            throw NetworkError.commandFailed("命令 \(executableName) 执行超时，请稍后重试。")
        }
        guard process.terminationStatus == 0 else {
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            throw NetworkError.commandFailed(
                detail.isEmpty
                    ? "命令 \(executableName) 执行失败（状态 \(process.terminationStatus)）。"
                    : detail
            )
        }
        return text
    }

}

final class NetworkManager {
    private let networksetup = "/usr/sbin/networksetup"
    private static let coreWLANAccessGate = CoreWLANAccessGate()
    private let privilegedHelper: PrivilegedHelperManager
    private let wifiSSIDCacheLock = NSLock()
    private var wifiSSIDCache = WiFiSSIDStabilityCache()

    init(privilegedHelper: PrivilegedHelperManager = PrivilegedHelperManager()) {
        self.privilegedHelper = privilegedHelper
    }

    var privilegedAccessState: PrivilegedAccessState { privilegedHelper.state }

    func configurePrivilegedAccess() throws {
        try privilegedHelper.configureForCurrentUser()
    }

    func removePrivilegedAccess() throws {
        try privilegedHelper.removeConfiguration()
    }

    func fetchServices() throws -> [NetworkService] {
        let enabledOutput = try CommandRunner.run(networksetup, ["-listallnetworkservices"])
        let orderOutput = try CommandRunner.run(networksetup, ["-listnetworkserviceorder"])
        let serviceStates = parseServiceStates(enabledOutput)
        let mappings = parseServiceMappings(orderOutput)
        let configuredOrder = parseServiceOrder(orderOutput)
        let priorityByName = Dictionary(
            configuredOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let primaryDevice = defaultRouteInterface()
        let connectedVPNNames = activeVPNServiceNames()
        let connectedVPNInterfaces = activeVPNInterfaceNames(for: connectedVPNNames)
        let primaryVPNName = primaryVPNServiceName(
            connectedNames: connectedVPNNames,
            interfacesByName: connectedVPNInterfaces,
            defaultInterface: primaryDevice
        )

        // `networksetup` exposes per-service details through separate commands.
        // Read independent services concurrently so machines with many adapters
        // do not pay the full subprocess latency serially on every refresh.
        var resolvedServices = Array<NetworkService?>(repeating: nil, count: serviceStates.count)
        var firstDetailError: Error?
        let resultLock = NSLock()
        let detailQueue = OperationQueue()
        detailQueue.name = "io.github.harenagodz.LinkGlint.service-details"
        detailQueue.qualityOfService = .utility
        detailQueue.maxConcurrentOperationCount = min(max(serviceStates.count, 1), 4)

        for (fallbackIndex, state) in serviceStates.enumerated() {
            detailQueue.addOperation { [self] in
                do {
                    let (name, enabled) = state
                    let priorityIndex = priorityByName[name] ?? (configuredOrder.count + fallbackIndex)
                    let mapping = mappings[name]
                    // A failed critical read must fail this refresh and preserve
                    // the last trusted snapshot. Treating an error as empty data
                    // makes an online adapter flicker to offline/no-DNS.
                    let info = try CommandRunner.run(networksetup, ["-getinfo", name])
                    let ipv4 = parseValue("IP address", in: info).flatMap(validIPAddressValue)
                    let ipv6 = parseValue("IPv6 IP address", in: info).flatMap(validIPAddressValue)
                    let ip = ipv4 ?? ipv6
                    // `networksetup` commonly reports `--` as the device for a
                    // VPN. Recover the live utun/ppp interface from scutil so
                    // traffic accounting and the primary-route badge keep
                    // working when more than one VPN is connected.
                    let device = mapping?.device ?? connectedVPNInterfaces[name]
                    let interface = try device.map(interfaceDetails) ?? (active: false, macAddress: nil)
                    let kind: NetworkService.Kind = connectedVPNNames.contains(name)
                        ? .vpn : classify(name: name, hardwarePort: mapping?.port)
                    let wifiPower: Bool?
                    let ssid: String?
                    if kind == .wifi, let device {
                        let output = try CommandRunner.run(networksetup, ["-getairportpower", device])
                        wifiPower = output.localizedCaseInsensitiveContains(": On")
                        let connectionIsEligible = wifiPower == true && interface.active && ip != nil
                        let outcome: WiFiSSIDReadOutcome
                        if connectionIsEligible {
                            do {
                                let networkOutput = try CommandRunner.run(
                                    networksetup,
                                    ["-getairportnetwork", device]
                                )
                                outcome = parseCurrentWiFiNetworkOutcome(networkOutput)
                            } catch {
                                // A transient subprocess failure is not proof of
                                // disassociation. Preserve a recent trusted SSID
                                // rather than flashing the service name for one
                                // refresh and resetting the traffic baseline.
                                outcome = .failed
                            }
                        } else {
                            // `-getairportnetwork` can wait several seconds while the radio
                            // is off or disconnected, so skip it for a faster refresh.
                            outcome = .current(nil)
                        }
                        wifiSSIDCacheLock.lock()
                        ssid = wifiSSIDCache.resolve(
                            device: device,
                            connectionIsEligible: connectionIsEligible,
                            outcome: outcome,
                            uptime: ProcessInfo.processInfo.systemUptime
                        )
                        wifiSSIDCacheLock.unlock()
                    } else {
                        wifiPower = nil
                        ssid = nil
                    }

                    let dnsOutput = try CommandRunner.run(networksetup, ["-getdnsservers", name])

                    let service = NetworkService(
                        name: name,
                        orderIndex: priorityIndex,
                        hardwarePort: mapping?.port,
                        device: device,
                        enabled: enabled,
                        connected: enabled && ((interface.active && ip != nil) || connectedVPNNames.contains(name)),
                        ipAddress: ip,
                        subnetMask: parseValue("Subnet mask", in: info),
                        router: parseValue("Router", in: info).flatMap(validNetworkValue)
                            ?? parseValue("IPv6 Router", in: info).flatMap(validNetworkValue),
                        dnsServers: parseDNSServers(dnsOutput),
                        macAddress: interface.macAddress,
                        ssid: ssid,
                        isPrimary: (device != nil && device == primaryDevice)
                            || name == primaryVPNName,
                        kind: kind,
                        wifiPowered: wifiPower
                    )
                    resultLock.lock()
                    resolvedServices[fallbackIndex] = service
                    resultLock.unlock()
                } catch {
                    resultLock.lock()
                    if firstDetailError == nil { firstDetailError = error }
                    resultLock.unlock()
                }
            }
        }
        detailQueue.waitUntilAllOperationsAreFinished()
        if let firstDetailError { throw firstDetailError }
        return resolvedServices.compactMap { $0 }.sorted { $0.orderIndex < $1.orderIndex }
    }

    func fetchTrafficCounters() throws -> [String: InterfaceCounters] {
        // `getifaddrs().ifa_data` exposes the legacy 32-bit `if_data` byte
        // counters on macOS. Fast links wrap those values after only 4 GiB,
        // causing everyday downloads to briefly show zero and lose usage.
        // NET_RT_IFLIST2 returns `if_data64` without spawning `netstat` every
        // second, keeping both the rate display and cumulative usage accurate.
        for _ in 0..<3 {
            var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
            var byteCount = 0
            guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0,
                  byteCount > 0 else {
                throw NetworkError.commandFailed("读取 64 位网络流量计数器失败。")
            }
            // Route messages contain naturally aligned C structs. Allocate a
            // matching raw buffer rather than assuming `[UInt8]` alignment.
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: MemoryLayout<if_msghdr2>.alignment
            )
            var writtenByteCount = byteCount
            let status = sysctl(&mib, u_int(mib.count), buffer, &writtenByteCount, nil, 0)
            if status != 0 {
                let failure = errno
                buffer.deallocate()
                // The interface list can grow between the size query and read.
                // Retry with the new size instead of dropping a traffic tick.
                if failure == ENOMEM { continue }
                throw NetworkError.commandFailed("读取 64 位网络流量计数器失败。")
            }

            var result: [String: InterfaceCounters] = [:]
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= writtenByteCount {
                let pointer = buffer.advanced(by: offset)
                let header = pointer.assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= writtenByteCount else { break }

                if Int32(header.ifm_type) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let extended = pointer.assumingMemoryBound(to: if_msghdr2.self).pointee
                    var interfaceName = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(extended.ifm_index), &interfaceName) != nil {
                        result[String(cString: interfaceName)] = InterfaceCounters(
                            receivedBytes: extended.ifm_data.ifi_ibytes,
                            sentBytes: extended.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += messageLength
            }
            buffer.deallocate()
            guard !result.isEmpty else {
                throw NetworkError.commandFailed("没有读到可用的网络流量计数器。")
            }
            return result
        }
        throw NetworkError.commandFailed("网络接口正在变化，请稍后重试。")
    }

    func runDiagnostics() -> NetworkDiagnostic {
        let ipv4Route = try? CommandRunner.run("/sbin/route", ["-n", "get", "default"])
        let routeOutput = ipv4Route
            ?? (try? CommandRunner.run("/sbin/route", ["-n", "get", "-inet6", "default"]))
            ?? ""
        let defaultInterface = parseValue("interface", in: routeOutput)
        let gateway = parseValue("gateway", in: routeOutput)
        let latency: Double?
        if let gateway {
            let ping = diagnosticPingInvocation(gateway: gateway)
            let output = try? CommandRunner.run(ping.executable, ping.arguments, timeout: 2.5)
            if let output {
                latency = parsePingLatency(output)
            } else {
                latency = nil
            }
        } else {
            latency = nil
        }

        let dnsLookupOutput = (try? CommandRunner.run(
            "/usr/bin/dscacheutil",
            ["-q", "host", "-a", "name", "www.apple.com"]
        )) ?? ""
        let dnsOutput = (try? CommandRunner.run("/usr/sbin/scutil", ["--dns"])) ?? ""

        return NetworkDiagnostic(
            date: Date(),
            defaultInterface: defaultInterface,
            gateway: gateway,
            gatewayLatencyMilliseconds: latency,
            dnsLookupSucceeded: dnsLookupDidResolve(dnsLookupOutput),
            systemDNSServers: parseSystemDNSServers(dnsOutput)
        )
    }

    func setService(_ name: String, enabled: Bool) throws {
        try privilegedHelper.run(["service", name, enabled ? "on" : "off"])
    }

    func setWiFiPower(device: String, enabled: Bool) throws {
        try privilegedHelper.run(["wifi", device, enabled ? "on" : "off"])
    }

    func joinWiFi(device: String, networkName: String, password: String?) throws {
        try Self.coreWLANAccessGate.withAccess {
            if let password, !password.isEmpty {
                guard let interface = CWWiFiClient.shared().interface(withName: device) else {
                    throw NetworkError.commandFailed("未找到 Wi-Fi 设备 \(device)。")
                }
                let ssidData = Data(networkName.utf8)
                let networks = try interface.scanForNetworks(withSSID: ssidData)
                guard let network = networks.max(by: { $0.rssiValue < $1.rssiValue }) else {
                    throw NetworkError.commandFailed("未找到“\(networkName)”，请靠近路由器后重试。")
                }
                // CoreWLAN keeps the password out of sudo/helper/networksetup argv,
                // where another local process could otherwise observe it.
                try interface.associate(to: network, password: password)
                return
            }
            // Open-network association still drives the same radio. Keep it
            // behind the CoreWLAN gate as well so a timed-out scan cannot race
            // a networksetup association started from manual entry.
            let arguments = ["join-wifi", device, networkName]
            try privilegedHelper.run(arguments)
        }
    }

    func scanWiFiNetworks(device: String, currentSSID: String?) throws -> WiFiScanResult {
        try Self.coreWLANAccessGate.withAccess {
            guard let interface = CWWiFiClient.shared().interface(withName: device) else {
                throw NetworkError.commandFailed("未找到 Wi-Fi 设备 \(device)。")
            }
            let resolvedCurrentSSID = interface.ssid() ?? currentSSID
            let scanned = try interface.scanForNetworks(withSSID: nil).compactMap { network -> WiFiNetwork? in
                guard let ssid = network.ssid else { return nil }
                return WiFiNetwork(
                    ssid: ssid,
                    rssiValue: network.rssiValue,
                    isSecure: !network.supportsSecurity(.none)
                )
            }
            return WiFiScanResult(
                networks: WiFiNetworkCatalog.normalized(scanned, currentSSID: resolvedCurrentSSID),
                currentSSID: resolvedCurrentSSID
            )
        }
    }

    func renameService(_ oldName: String, to newName: String) throws {
        try privilegedHelper.run(["rename", oldName, newName])
    }

    func setDNSServers(service: String, servers: [String]) throws {
        try privilegedHelper.run(["dns", service] + (servers.isEmpty ? ["empty"] : servers))
    }

    func setHighestPriority(service: String, currentOrder: [String]) throws {
        let newOrder = [service] + currentOrder.filter { $0 != service }
        guard newOrder.count == currentOrder.count else {
            throw NetworkError.commandFailed("网络服务顺序不完整，请先刷新后重试。")
        }
        try privilegedHelper.run(["order"] + newOrder)
    }

    func setServiceOrder(_ order: [String]) throws {
        guard !order.isEmpty, Set(order).count == order.count else {
            throw NetworkError.commandFailed("网络服务顺序无效，请刷新后重试。")
        }
        try privilegedHelper.run(["order"] + order)
    }

    /// Enables the chosen physical service and moves it to the front of the
    /// service order while retaining healthy fallbacks. A Wi-Fi radio is powered
    /// on before its service is enabled.
    func switchToService(_ target: String, currentOrder: [String], wifiDevice: String?) throws {
        guard currentOrder.contains(target), Set(currentOrder).count == currentOrder.count else {
            throw NetworkError.commandFailed("网络服务顺序已变化，请刷新后重试。")
        }
        try privilegedHelper.run(["switch", target, wifiDevice ?? "-"] + currentOrder)
    }

    /// Applies an entire saved network state with one administrator authorization.
    /// Fixed shell code consumes every user-visible name as a positional argument.
    func applyProfile(
        serviceStates: [String: Bool],
        wifiPowerStates: [String: Bool],
        readinessServices: [String]
    ) throws {
        var arguments: [String] = ["profile"]
        for service in readinessServices.sorted() {
            arguments += ["ready", service, "on"]
        }
        // Bring radios and services up before taking other services down, reducing
        // the window where the Mac has no usable connection.
        for (device, enabled) in wifiPowerStates.sorted(by: { $0.key < $1.key }) where enabled {
            arguments += ["wifi", device, "on"]
        }
        for (service, enabled) in serviceStates.sorted(by: { $0.key < $1.key }) where enabled {
            arguments += ["service", service, "on"]
        }
        for (service, enabled) in serviceStates.sorted(by: { $0.key < $1.key }) where !enabled {
            arguments += ["service", service, "off"]
        }
        for (device, enabled) in wifiPowerStates.sorted(by: { $0.key < $1.key }) where !enabled {
            arguments += ["wifi", device, "off"]
        }
        try privilegedHelper.run(arguments)
    }

    func parseServiceStates(_ output: String) -> [(String, Bool)] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("An asterisk") }
            .map { line in
                if line.hasPrefix("*") {
                    return (String(line.dropFirst()), false)
                }
                return (line, true)
            }
    }

    func parseServiceMappings(_ output: String) -> [String: (port: String, device: String?)] {
        var result: [String: (port: String, device: String?)] = [:]
        var currentService: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^\((?:\d+|\*)\)\s+"#, options: .regularExpression) != nil {
                currentService = line.replacingOccurrences(
                    of: #"^\((?:\d+|\*)\)\s+"#,
                    with: "",
                    options: .regularExpression
                )
            } else if line.hasPrefix("(Hardware Port:"), let currentService {
                let expression = #"^\(Hardware Port:\s*(.*?),\s*Device:\s*(.*?)\)$"#
                if let regex = try? NSRegularExpression(pattern: expression),
                   let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let portRange = Range(match.range(at: 1), in: line),
                   let deviceRange = Range(match.range(at: 2), in: line) {
                    let port = String(line[portRange])
                    let deviceText = String(line[deviceRange])
                    result[currentService] = (port, deviceText == "--" ? nil : deviceText)
                }
            }
        }
        return result
    }

    func parseServiceOrder(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.range(of: #"^\((?:\d+|\*)\)\s+"#, options: .regularExpression) != nil else {
                return nil
            }
            return line.replacingOccurrences(
                of: #"^\((?:\d+|\*)\)\s+"#,
                with: "",
                options: .regularExpression
            )
        }
    }

    func parseValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let value = String(line).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(key + ":") {
                return String(value.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func validNetworkValue(_ value: String) -> String? {
        let lower = value.lowercased()
        return (lower == "none" || value == "0.0.0.0") ? nil : value
    }

    private func validIPAddressValue(_ value: String) -> String? {
        let lower = value.lowercased()
        guard lower != "none", value != "0.0.0.0", value != "::", value != "::1",
              !value.hasPrefix("127."), !value.hasPrefix("169.254."),
              !lower.hasPrefix("fe80:") else { return nil }
        return value
    }

    func parseDNSServers(_ output: String) -> [String] {
        guard !output.localizedCaseInsensitiveContains("aren't any DNS") else { return [] }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                let addressWithoutZone = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
                return IPv4Address(value) != nil || IPv6Address(addressWithoutZone) != nil
            }
    }

    func parseCurrentWiFiNetwork(_ output: String) -> String? {
        guard case .current(let value) = parseCurrentWiFiNetworkOutcome(output) else {
            return nil
        }
        return value
    }

    func parseCurrentWiFiNetworkOutcome(_ output: String) -> WiFiSSIDReadOutcome {
        let lowercasedOutput = output.lowercased()
        if lowercasedOutput.contains("not associated")
            || lowercasedOutput.contains("unable") {
            return .current(nil)
        }
        guard let colon = output.firstIndex(of: ":") else { return .failed }
        var rawValue = String(output[output.index(after: colon)...])
        // networksetup inserts one delimiter space after the colon. Remove only
        // that byte and line endings; any additional leading/trailing spaces
        // can be legal SSID bytes and must survive round-tripping.
        if rawValue.first == " " || rawValue.first == "\t" { rawValue.removeFirst() }
        let value = rawValue.trimmingCharacters(in: .newlines)
        guard !value.isEmpty else { return .failed }
        return .current(value)
    }

    func diagnosticPingInvocation(gateway: String) -> (executable: String, arguments: [String]) {
        if gateway.contains(":") {
            // macOS ping6 uses -W as a flag for a legacy Node Information query;
            // unlike IPv4 ping it does not accept a millisecond value.
            return ("/sbin/ping6", ["-c", "1", gateway])
        }
        return ("/sbin/ping", ["-c", "1", "-W", "1000", gateway])
    }

    func parseTrafficCounters(_ output: String) -> [String: InterfaceCounters] {
        var result: [String: InterfaceCounters] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 10,
                  fields[2].hasPrefix("<Link#"),
                  let received = UInt64(fields[6]),
                  let sent = UInt64(fields[9]) else { continue }
            result[fields[0]] = InterfaceCounters(receivedBytes: received, sentBytes: sent)
        }
        return result
    }

    func parsePingLatency(_ output: String) -> Double? {
        let expression = #"time[=<]([0-9.]+)\s*ms"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }

    func dnsLookupDidResolve(_ output: String) -> Bool {
        output.contains("ip_address:") || output.contains("ipv6_address:")
    }

    func parseSystemDNSServers(_ output: String) -> [String] {
        var servers: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("nameserver["), let colon = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && !servers.contains(value) { servers.append(value) }
        }
        return servers
    }

    func parseConnectedVPNServiceNames(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard line.contains("(Connected)") else { return nil }
            let quotedParts = line.components(separatedBy: "\"")
            guard quotedParts.count >= 3 else { return nil }
            let name = quotedParts[quotedParts.count - 2]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
    }

    func parseVPNInterfaceName(_ output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.range(
                of: #"^InterfaceName\s*[:=]\s*"#,
                options: .regularExpression
            ) != nil else { continue }
            let value = line.replacingOccurrences(
                of: #"^InterfaceName\s*[:=]\s*"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(
                of: #"^[A-Za-z0-9._-]+$"#,
                options: .regularExpression
            ) != nil else { continue }
            return value
        }
        return nil
    }

    func primaryVPNServiceName(
        connectedNames: Set<String>,
        interfacesByName: [String: String],
        defaultInterface: String?
    ) -> String? {
        guard let defaultInterface else { return nil }
        if let matched = connectedNames.sorted().first(where: {
            interfacesByName[$0] == defaultInterface
        }) {
            return matched
        }
        // Older VPN implementations do not always publish InterfaceName. The
        // single-connected-service fallback is unambiguous for a tunnel route;
        // with multiple services, leave the primary badge unset rather than
        // assigning it to the wrong VPN.
        if connectedNames.count == 1,
           defaultInterface.hasPrefix("utun") || defaultInterface.hasPrefix("ppp") {
            return connectedNames.first
        }
        return nil
    }

    func normalizedDNSServers(_ input: String) throws -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let values = input.components(separatedBy: separators).filter { !$0.isEmpty }
        var result: [String] = []
        for value in values {
            let addressWithoutZone = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
            guard IPv4Address(value) != nil || IPv6Address(addressWithoutZone) != nil else {
                throw NetworkError.commandFailed("“\(value)”不是有效的 IPv4 或 IPv6 DNS 地址。")
            }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    private func interfaceDetails(_ device: String) throws -> (active: Bool, macAddress: String?) {
        let output: String
        do {
            output = try CommandRunner.run("/sbin/ifconfig", [device])
        } catch {
            // macOS keeps network services for unplugged USB/mobile adapters in
            // `networksetup`, even though their enX interface no longer exists.
            // That is a normal offline state, not a reason to discard every
            // other service in the refresh.
            if interfaceIsUnavailable(error.localizedDescription) {
                return (active: false, macAddress: nil)
            }
            throw error
        }
        return parseInterfaceDetails(output)
    }

    func parseInterfaceDetails(_ output: String) -> (active: Bool, macAddress: String?) {
        let lines = output.split(separator: "\n").map(String.init)
        let mac = lines.lazy
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("ether ") }
            .map { String($0.dropFirst("ether ".count)).trimmingCharacters(in: .whitespaces) }
        let flagsAreRunning = lines.first.map { line in
            line.contains("<") && line.contains("UP") && line.contains("RUNNING")
        } ?? false
        let explicitStatus = lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .first { $0.hasPrefix("status:") }
        // Some virtual interfaces omit the status line and must fall back to
        // UP/RUNNING flags. An explicit `status: inactive` always wins.
        let active = explicitStatus.map { $0 == "status: active" } ?? flagsAreRunning
        return (active, mac)
    }

    func interfaceIsUnavailable(_ errorMessage: String) -> Bool {
        let message = errorMessage.lowercased()
        return message.contains("interface")
            && (message.contains("does not exist") || message.contains("no such interface"))
    }

    private func defaultRouteInterface() -> String? {
        if let output = try? CommandRunner.run("/sbin/route", ["-n", "get", "default"]),
           let interface = parseValue("interface", in: output) {
            return interface
        }
        guard let output = try? CommandRunner.run("/sbin/route", ["-n", "get", "-inet6", "default"]) else {
            return nil
        }
        return parseValue("interface", in: output)
    }

    private func activeVPNServiceNames() -> Set<String> {
        guard let output = try? CommandRunner.run("/usr/sbin/scutil", ["--nc", "list"]) else { return [] }
        return parseConnectedVPNServiceNames(output)
    }

    private func activeVPNInterfaceNames(for serviceNames: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for name in serviceNames.sorted() {
            guard let output = try? CommandRunner.run(
                "/usr/sbin/scutil",
                ["--nc", "show", name],
                timeout: 3
            ), let interface = parseVPNInterfaceName(output) else { continue }
            result[name] = interface
        }
        return result
    }

    func classify(name: String, hardwarePort: String?) -> NetworkService.Kind {
        let text = "\(name) \(hardwarePort ?? "")".lowercased()
        if text.contains("wi-fi") || text.contains("wifi") || text.contains("airport") {
            return .wifi
        }
        if text.contains("ethernet") || text.contains("thunderbolt") || text.contains("usb 10") {
            return .ethernet
        }
        if text.contains("vpn") || text.contains("ppp") || text.contains("ipsec") {
            return .vpn
        }
        if text.contains("cellular") || text.contains("mobile") || text.contains("wwan")
            || text.contains("broadband") || text.contains("modem") {
            return .cellular
        }
        return .other
    }
}
