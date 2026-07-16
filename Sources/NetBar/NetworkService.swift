import Foundation
import Network

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
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NetworkError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        let primaryDevice = defaultRouteInterface()

        return serviceStates.enumerated().map { index, state in
            let (name, enabled) = state
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

            return NetworkService(
                name: name,
                orderIndex: index,
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
        }
    }

    func fetchTrafficCounters() throws -> [String: InterfaceCounters] {
        let output = try CommandRunner.run("/usr/sbin/netstat", ["-ibn"])
        return parseTrafficCounters(output)
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
