import Foundation
import Darwin

/// A deliberately small root helper. It accepts only LinkGlint's fixed network
/// operations and launches `networksetup` directly—never a shell or an
/// arbitrary executable. The installed copy is owned by root and invoked with
/// `sudo -n`, so normal network changes cannot display another password prompt.
enum HelperFailure: Error, CustomStringConvertible {
    case usage(String)
    case permission
    case command(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .permission: return "LinkGlintHelper must run as root."
        case .command(let message): return message
        }
    }
}

private let networksetup = "/usr/sbin/networksetup"
private let ifconfig = "/sbin/ifconfig"
private let helperProtocolVersion = 3

private func validateName(_ value: String, label: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw HelperFailure.usage("Invalid \(label).")
    }
}

private func validateDevice(_ value: String) throws {
    guard value.range(of: #"^[A-Za-z0-9._-]{1,32}$"#, options: .regularExpression) != nil else {
        throw HelperFailure.usage("Invalid network device.")
    }
}

private func validateState(_ value: String) throws {
    guard value == "on" || value == "off" else {
        throw HelperFailure.usage("State must be on or off.")
    }
}

private func validateIPAddress(_ value: String) throws {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    let plainIPv6 = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
    let isIPv4 = value.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
    let isIPv6 = plainIPv6.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    guard isIPv4 || isIPv6 else { throw HelperFailure.usage("Invalid DNS address.") }
}

@discardableResult
private func runCommand(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 20
) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let stateLock = NSLock()
    var timedOut = false
    let timeoutWork = DispatchWorkItem {
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
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    // Drain before waiting so an unexpectedly verbose system error cannot fill
    // the pipe and deadlock the privileged operation.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeoutWork.cancel()
    stateLock.lock()
    let didTimeOut = timedOut
    stateLock.unlock()
    let text = String(data: data, encoding: .utf8) ?? ""
    if didTimeOut {
        throw HelperFailure.command("\(URL(fileURLWithPath: executable).lastPathComponent) timed out.")
    }
    guard process.terminationStatus == 0 else {
        throw HelperFailure.command(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return text
}

@discardableResult
private func runNetworkSetup(
    _ arguments: [String],
    timeout: TimeInterval = 20
) throws -> String {
    try runCommand(networksetup, arguments, timeout: timeout)
}

private func isUsableIPAddress(_ value: String) -> Bool {
    let lower = value.lowercased()
    guard !value.isEmpty, lower != "none", value != "0.0.0.0",
          value != "::", value != "::1", !value.hasPrefix("127."),
          !value.hasPrefix("169.254."), !lower.hasPrefix("fe80:") else { return false }
    var ipv4 = in_addr()
    if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
    let plainIPv6 = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
    var ipv6 = in6_addr()
    return plainIPv6.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
}

private func networkServiceHasIPAddress(_ name: String, timeout: TimeInterval = 2) -> Bool {
    guard let output = try? runNetworkSetup(["-getinfo", name], timeout: timeout) else { return false }
    for rawLine in output.split(separator: "\n") {
        let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("IP address:") || line.hasPrefix("IPv6 IP address:") else { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableIPAddress(value) { return true }
    }
    return false
}

private func currentNetworkServiceOrder() throws -> [String] {
    let output = try runNetworkSetup(["-listnetworkserviceorder"])
    return output.split(separator: "\n").compactMap { rawLine in
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let token = line[line.index(after: line.startIndex)..<close]
        guard token == "*" || Int(token) != nil else { return nil }
        let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

private func currentNetworkServiceDevices(timeout: TimeInterval = 5) throws -> [String: String] {
    let output = try runNetworkSetup(["-listnetworkserviceorder"], timeout: timeout)
    var currentService: String?
    var result: [String: String] = [:]
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
            let token = line[line.index(after: line.startIndex)..<close]
            if token == "*" || Int(token) != nil {
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                currentService = name.isEmpty ? nil : name
                continue
            }
        }
        guard line.hasPrefix("(Hardware Port:"), line.hasSuffix(")"),
              let currentService,
              let deviceMarker = line.range(of: ", Device: ") else { continue }
        let value = line[deviceMarker.upperBound..<line.index(before: line.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, value != "--" { result[currentService] = value }
    }
    return result
}

private func interfaceIsActive(_ device: String, timeout: TimeInterval = 1.5) -> Bool {
    guard let output = try? runCommand(ifconfig, [device], timeout: timeout) else { return false }
    let lines = output.split(separator: "\n").map(String.init)
    let explicitStatus = lines.lazy
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .first { $0.hasPrefix("status:") }
    if let explicitStatus { return explicitStatus == "status: active" }
    return lines.first.map {
        $0.contains("<") && $0.contains("UP") && $0.contains("RUNNING")
    } ?? false
}

private func waitForAnyReadyNetworkService(_ names: [String]) -> Bool {
    guard !names.isEmpty else { return false }
    guard let devices = try? currentNetworkServiceDevices(timeout: 3) else { return false }
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while ProcessInfo.processInfo.systemUptime < deadline {
        for name in names {
            guard let device = devices[name] else { continue }
            var remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            guard interfaceIsActive(device, timeout: min(remaining, 1.5)) else { continue }
            remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            if networkServiceHasIPAddress(name, timeout: min(remaining, 2)) { return true }
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        usleep(useconds_t(min(remaining, 0.5) * 1_000_000))
    }
    return false
}

private func currentServiceStates(_ names: Set<String>) throws -> [String: String] {
    let output = try runNetworkSetup(["-listallnetworkservices"])
    var result: [String: String] = [:]
    for rawLine in output.split(separator: "\n") {
        let line = String(rawLine)
        if line.hasPrefix("*") {
            let name = String(line.dropFirst())
            if names.contains(name) { result[name] = "off" }
        } else if names.contains(line) {
            result[line] = "on"
        }
    }
    guard result.count == names.count else {
        throw HelperFailure.command("Some network services are no longer available.")
    }
    return result
}

private func currentWiFiPowerState(_ device: String) throws -> String {
    let output = try runNetworkSetup(["-getairportpower", device])
    return output.localizedCaseInsensitiveContains(": On") ? "on" : "off"
}

private func run(_ arguments: [String]) throws {
    guard !arguments.isEmpty else { throw HelperFailure.usage("Missing operation.") }

    if arguments == ["status"] {
        guard geteuid() == 0 else { throw HelperFailure.permission }
        print("LinkGlintHelper ready \(helperProtocolVersion)")
        return
    }
    guard geteuid() == 0 else { throw HelperFailure.permission }

    switch arguments[0] {
    case "service":
        guard arguments.count == 3 else { throw HelperFailure.usage("Usage: service NAME on|off") }
        try validateName(arguments[1], label: "service name")
        try validateState(arguments[2])
        try runNetworkSetup(["-setnetworkserviceenabled", arguments[1], arguments[2]])

    case "wifi":
        guard arguments.count == 3 else { throw HelperFailure.usage("Usage: wifi DEVICE on|off") }
        try validateDevice(arguments[1])
        try validateState(arguments[2])
        try runNetworkSetup(["-setairportpower", arguments[1], arguments[2]])

    case "join-wifi":
        guard arguments.count == 3 else {
            throw HelperFailure.usage("Usage: join-wifi DEVICE NETWORK")
        }
        try validateDevice(arguments[1])
        try validateName(arguments[2], label: "network name")
        try runNetworkSetup(["-setairportnetwork"] + Array(arguments.dropFirst()))

    case "rename":
        guard arguments.count == 3 else { throw HelperFailure.usage("Usage: rename OLD_NAME NEW_NAME") }
        try validateName(arguments[1], label: "old service name")
        try validateName(arguments[2], label: "new service name")
        try runNetworkSetup(["-renamenetworkservice", arguments[1], arguments[2]])

    case "dns":
        guard arguments.count >= 3, arguments.count <= 18 else {
            throw HelperFailure.usage("Usage: dns SERVICE empty|ADDRESS...")
        }
        try validateName(arguments[1], label: "service name")
        let values = Array(arguments.dropFirst(2))
        if values != ["empty"] {
            for value in values { try validateIPAddress(value) }
        }
        try runNetworkSetup(["-setdnsservers", arguments[1]] + values)

    case "order":
        guard arguments.count >= 2, arguments.count <= 65 else {
            throw HelperFailure.usage("Usage: order SERVICE...")
        }
        for value in arguments.dropFirst() { try validateName(value, label: "service name") }
        try runNetworkSetup(["-ordernetworkservices"] + Array(arguments.dropFirst()))

    case "switch":
        guard arguments.count >= 3, arguments.count <= 67 else {
            throw HelperFailure.usage("Usage: switch TARGET WIFI_OR_DASH CURRENT_ORDER...")
        }
        let target = arguments[1]
        let wifiDevice = arguments[2]
        try validateName(target, label: "service name")
        if wifiDevice != "-" {
            try validateDevice(wifiDevice)
        }
        let currentOrder = Array(arguments.dropFirst(3))
        for service in currentOrder { try validateName(service, label: "service name") }
        guard currentOrder.contains(target), Set(currentOrder).count == currentOrder.count else {
            throw HelperFailure.usage("Incomplete network service order.")
        }
        let systemOrder = try currentNetworkServiceOrder()
        guard systemOrder == currentOrder else {
            throw HelperFailure.command("Network service order changed; refresh and try again.")
        }
        let originalTargetState = try currentServiceStates([target])[target] ?? "off"
        let originalWiFiState = try wifiDevice == "-" ? nil : currentWiFiPowerState(wifiDevice)

        do {
            if wifiDevice != "-" {
                try runNetworkSetup(["-setairportpower", wifiDevice, "on"])
            }
            try runNetworkSetup(["-setnetworkserviceenabled", target, "on"])
            guard waitForAnyReadyNetworkService([target]) else {
                throw HelperFailure.command("目标网络尚未获得可用地址；原有连接与优先级已保留。")
            }
            // Prefer the requested service without disabling healthy fallbacks.
            // macOS can then recover automatically if the new route later drops.
            let newOrder = [target] + currentOrder.filter { $0 != target }
            try runNetworkSetup(["-ordernetworkservices"] + newOrder)
        } catch {
            _ = try? runNetworkSetup(["-ordernetworkservices"] + systemOrder)
            _ = try? runNetworkSetup(["-setnetworkserviceenabled", target, originalTargetState])
            if wifiDevice != "-", let originalWiFiState {
                _ = try? runNetworkSetup(["-setairportpower", wifiDevice, originalWiFiState])
            }
            throw error
        }

    case "profile":
        let values = Array(arguments.dropFirst())
        guard !values.isEmpty, values.count.isMultiple(of: 3), values.count <= 192 else {
            throw HelperFailure.usage("Usage: profile (service|wifi NAME on|off)...")
        }
        var operations: [(kind: String, name: String, state: String)] = []
        var index = 0
        while index < values.count {
            let kind = values[index]
            let name = values[index + 1]
            let state = values[index + 2]
            try validateState(state)
            if kind == "service" || kind == "ready" {
                try validateName(name, label: "service name")
                if kind == "ready", state != "on" {
                    throw HelperFailure.usage("Readiness targets must use state on.")
                }
            } else if kind == "wifi" {
                try validateDevice(name)
            } else {
                throw HelperFailure.usage("Unknown profile operation.")
            }
            operations.append((kind, name, state))
            index += 3
        }
        let orderedOperations = operations.filter { $0.kind == "wifi" && $0.state == "on" }
            + operations.filter { $0.kind == "service" && $0.state == "on" }
            + operations.filter { $0.kind == "service" && $0.state == "off" }
            + operations.filter { $0.kind == "wifi" && $0.state == "off" }
        let enabledServiceNames = Set(orderedOperations.filter {
            $0.kind == "service" && $0.state == "on"
        }.map(\.name))
        let enabledTargets = operations.filter { $0.kind == "ready" }.map(\.name)
        guard Set(enabledTargets).count == enabledTargets.count,
              Set(enabledTargets).isSubset(of: enabledServiceNames) else {
            throw HelperFailure.usage("Invalid profile readiness targets.")
        }
        let serviceNames = Set(operations.filter { $0.kind == "service" }.map(\.name))
        let originalServiceStates = try currentServiceStates(serviceNames)
        var originalWiFiStates: [String: String] = [:]
        for device in Set(operations.filter { $0.kind == "wifi" }.map(\.name)) {
            originalWiFiStates[device] = try currentWiFiPowerState(device)
        }

        do {
            var checkedReadiness = false
            for operation in orderedOperations {
                let isDestructive = operation.state == "off"
                    && (operation.kind == "service" || operation.kind == "wifi")
                if isDestructive,
                   !checkedReadiness, !enabledTargets.isEmpty {
                    guard waitForAnyReadyNetworkService(enabledTargets) else {
                        throw HelperFailure.command("方案中的目标网络尚未就绪；现有连接已保留。")
                    }
                    checkedReadiness = true
                }
                if operation.kind == "service" {
                    try runNetworkSetup(["-setnetworkserviceenabled", operation.name, operation.state])
                } else {
                    try runNetworkSetup(["-setairportpower", operation.name, operation.state])
                }
            }
        } catch {
            // Best-effort transaction rollback. Restore every touched item to
            // the state captured before the profile began, in reverse order.
            for operation in orderedOperations.reversed() {
                if operation.kind == "service", let state = originalServiceStates[operation.name] {
                    _ = try? runNetworkSetup(["-setnetworkserviceenabled", operation.name, state])
                } else if operation.kind == "wifi", let state = originalWiFiStates[operation.name] {
                    _ = try? runNetworkSetup(["-setairportpower", operation.name, state])
                }
            }
            throw error
        }

    default:
        throw HelperFailure.usage("Unknown operation.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("LinkGlintHelper: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
