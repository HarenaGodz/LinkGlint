import Foundation
import Network
import Darwin

struct NetworkService: Hashable {
    enum Kind {
        case wifi
        case ethernet
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
        target: String,
        disabledServices: [String]
    ) -> [NetworkService] {
        guard services.contains(where: { $0.name == target }) else { return services }
        let disabledNames = Set(disabledServices)
        return services.map { service in
            let isTarget = service.name == target
            let isDisabled = disabledNames.contains(service.name)
            return NetworkService(
                name: service.name,
                orderIndex: service.orderIndex,
                hardwarePort: service.hardwarePort,
                device: service.device,
                enabled: isTarget ? true : (isDisabled ? false : service.enabled),
                connected: isTarget ? true : (isDisabled ? false : service.connected),
                ipAddress: service.ipAddress,
                subnetMask: service.subnetMask,
                router: service.router,
                dnsServers: service.dnsServers,
                macAddress: service.macAddress,
                ssid: service.ssid,
                isPrimary: isTarget,
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
        if gatewayLatencyMilliseconds == nil { return "无法连接本地网关" }
        return "DNS 查询异常"
    }
}

enum NetworkError: LocalizedError {
    case commandFailed(String)
    case privilegedAccessRequired

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .privilegedAccessRequired:
            return "请先完成一次免密码网络切换配置。之后日常切换和登录启动都不再要求输入密码。"
        }
    }
}

enum CommandRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String] = []) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain the pipe while the child is running. Waiting first can deadlock
        // once output fills the kernel pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
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
    private let privilegedHelper: PrivilegedHelperManager

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
        let priorityByName = Dictionary(uniqueKeysWithValues: configuredOrder.enumerated().map { ($0.element, $0.offset) })
        let primaryDevice = defaultRouteInterface()

        // `networksetup` exposes per-service details through separate commands.
        // Read independent services concurrently so machines with many adapters
        // do not pay the full subprocess latency serially on every refresh.
        var resolvedServices = Array<NetworkService?>(repeating: nil, count: serviceStates.count)
        let resultLock = NSLock()
        let detailQueue = OperationQueue()
        detailQueue.name = "io.github.harenagodz.LinkGlint.service-details"
        detailQueue.qualityOfService = .utility
        detailQueue.maxConcurrentOperationCount = min(max(serviceStates.count, 1), 4)

        for (fallbackIndex, state) in serviceStates.enumerated() {
            detailQueue.addOperation { [self] in
                let (name, enabled) = state
                let priorityIndex = priorityByName[name] ?? (configuredOrder.count + fallbackIndex)
                let mapping = mappings[name]
                let info = (try? CommandRunner.run(networksetup, ["-getinfo", name])) ?? ""
                let ip = parseValue("IP address", in: info).flatMap { value in
                    let lower = value.lowercased()
                    return (lower == "none" || value == "0.0.0.0") ? nil : value
                }
                let device = mapping?.device
                let interface = device.map(interfaceDetails) ?? (active: false, macAddress: nil)
                let kind = classify(name: name, hardwarePort: mapping?.port)
                let wifiPower: Bool?
                let ssid: String?
                if kind == .wifi, let device {
                    let output = try? CommandRunner.run(networksetup, ["-getairportpower", device])
                    wifiPower = output.map { $0.localizedCaseInsensitiveContains(": On") }
                    if wifiPower == true {
                        let networkOutput = try? CommandRunner.run(networksetup, ["-getairportnetwork", device])
                        ssid = networkOutput.flatMap(parseCurrentWiFiNetwork)
                    } else {
                        // `-getairportnetwork` can wait several seconds while the radio
                        // is off, so skip it for a much faster initial refresh.
                        ssid = nil
                    }
                } else {
                    wifiPower = nil
                    ssid = nil
                }

                let dnsOutput = (try? CommandRunner.run(networksetup, ["-getdnsservers", name])) ?? ""

                let service = NetworkService(
                    name: name,
                    orderIndex: priorityIndex,
                    hardwarePort: mapping?.port,
                    device: device,
                    enabled: enabled,
                    connected: enabled && interface.active && ip != nil,
                    ipAddress: ip,
                    subnetMask: parseValue("Subnet mask", in: info),
                    router: parseValue("Router", in: info).flatMap(validNetworkValue),
                    dnsServers: parseDNSServers(dnsOutput),
                    macAddress: interface.macAddress,
                    ssid: ssid,
                    isPrimary: device != nil && device == primaryDevice,
                    kind: kind,
                    wifiPowered: wifiPower
                )
                resultLock.lock()
                resolvedServices[fallbackIndex] = service
                resultLock.unlock()
            }
        }
        detailQueue.waitUntilAllOperationsAreFinished()
        return resolvedServices.compactMap { $0 }.sorted { $0.orderIndex < $1.orderIndex }
    }

    func fetchTrafficCounters() throws -> [String: InterfaceCounters] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            throw NetworkError.commandFailed("读取网络流量计数器失败。")
        }
        defer { freeifaddrs(firstAddress) }

        var result: [String: InterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let pointer = cursor {
            let interface = pointer.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let rawData = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                result[name] = InterfaceCounters(
                    receivedBytes: UInt64(data.ifi_ibytes),
                    sentBytes: UInt64(data.ifi_obytes)
                )
            }
            cursor = interface.ifa_next
        }
        return result
    }

    func runDiagnostics() -> NetworkDiagnostic {
        let routeOutput = (try? CommandRunner.run("/sbin/route", ["-n", "get", "default"])) ?? ""
        let defaultInterface = parseValue("interface", in: routeOutput)
        let gateway = parseValue("gateway", in: routeOutput)
        let latency: Double?
        if let gateway,
           let output = try? CommandRunner.run("/sbin/ping", ["-c", "1", "-W", "1000", gateway]) {
            latency = parsePingLatency(output)
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
            dnsLookupSucceeded: dnsLookupOutput.contains("ip_address:"),
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
        var arguments = ["join-wifi", device, networkName]
        if let password, !password.isEmpty { arguments.append(password) }
        try privilegedHelper.run(arguments)
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

    /// Enables the chosen physical service first, then disables the other active
    /// physical services. A Wi-Fi radio is powered on before its service is enabled.
    func switchToService(_ target: String, otherServices: [String], wifiDevice: String?) throws {
        try privilegedHelper.run(["switch", target, wifiDevice ?? "-"] + otherServices)
    }

    /// Applies an entire saved network state with one administrator authorization.
    /// Fixed shell code consumes every user-visible name as a positional argument.
    func applyProfile(serviceStates: [String: Bool], wifiPowerStates: [String: Bool]) throws {
        var arguments: [String] = ["profile"]
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

    func parseDNSServers(_ output: String) -> [String] {
        guard !output.localizedCaseInsensitiveContains("aren't any DNS") else { return [] }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func parseCurrentWiFiNetwork(_ output: String) -> String? {
        guard let colon = output.firstIndex(of: ":") else { return nil }
        let value = String(output[output.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.localizedCaseInsensitiveContains("not associated"),
              !value.localizedCaseInsensitiveContains("unable") else { return nil }
        return value
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

    private func interfaceDetails(_ device: String) -> (active: Bool, macAddress: String?) {
        guard let output = try? CommandRunner.run("/sbin/ifconfig", [device]) else {
            return (false, nil)
        }
        let mac = output.split(separator: "\n").lazy
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("ether ") }
            .map { String($0.dropFirst("ether ".count)).trimmingCharacters(in: .whitespaces) }
        return (output.localizedCaseInsensitiveContains("status: active"), mac)
    }

    private func defaultRouteInterface() -> String? {
        guard let output = try? CommandRunner.run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        return parseValue("interface", in: output)
    }

    private func classify(name: String, hardwarePort: String?) -> NetworkService.Kind {
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
        return .other
    }
}
