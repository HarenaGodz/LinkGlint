import Foundation

public enum HelperWorkflowError: Error, CustomStringConvertible, Equatable {
    case command(String)

    public var description: String {
        switch self {
        case .command(let message): return message
        }
    }
}

/// Executes LinkGlint's validated privileged operations. Keeping the workflow
/// outside the executable makes command order and rollback behavior testable
/// without running a process as root.
public final class HelperWorkflow {
    private typealias RollbackStep = (label: String, action: () throws -> Void)

    private let executor: HelperCommandExecutor
    private let networksetup: String
    private let ifconfig: String
    private let uptime: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    public init(
        executor: HelperCommandExecutor,
        networksetup: String = "/usr/sbin/networksetup",
        ifconfig: String = "/sbin/ifconfig",
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.executor = executor
        self.networksetup = networksetup
        self.ifconfig = ifconfig
        self.uptime = uptime
        self.sleep = sleep
    }

    @discardableResult
    public func execute(_ operation: HelperOperation) throws -> String? {
        switch operation {
        case .status:
            return "LinkGlintHelper ready 3"
        case .service(let name, let state):
            try runNetworkSetup(["-setnetworkserviceenabled", name, state])
        case .wifi(let device, let state):
            try runNetworkSetup(["-setairportpower", device, state])
        case .joinWiFi(let device, let network):
            try runNetworkSetup(["-setairportnetwork", device, network])
        case .rename(let oldName, let newName):
            try runNetworkSetup(["-renamenetworkservice", oldName, newName])
        case .dns(let service, let values):
            try runNetworkSetup(["-setdnsservers", service] + values)
        case .order(let services):
            try runNetworkSetup(["-ordernetworkservices"] + services)
        case .switch(let target, let wifiDevice, let currentOrder):
            try executeSwitch(target: target, wifiDevice: wifiDevice, currentOrder: currentOrder)
        case .profile(let operations):
            try executeProfile(operations)
        }
        return nil
    }

    @discardableResult
    private func runNetworkSetup(
        _ arguments: [String],
        timeout: TimeInterval = 20
    ) throws -> String {
        try executor.run(networksetup, arguments: arguments, timeout: timeout)
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
        guard let output = try? executor.run(ifconfig, arguments: [device], timeout: timeout) else {
            return false
        }
        let lines = output.split(separator: "\n").map(String.init)
        let explicitStatus = lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .first { $0.hasPrefix("status:") }
        if let explicitStatus { return explicitStatus == "status: active" }
        return lines.first.map {
            $0.contains("<") && $0.contains("UP") && $0.contains("RUNNING")
        } ?? false
    }

    private func networkServiceHasIPAddress(_ name: String, timeout: TimeInterval = 2) -> Bool {
        guard let output = try? runNetworkSetup(["-getinfo", name], timeout: timeout) else { return false }
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("IP address:") || line.hasPrefix("IPv6 IP address:") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if HelperArgumentValidation.isUsableIPAddress(value) { return true }
        }
        return false
    }

    private func waitForAnyReadyNetworkService(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        guard let devices = try? currentNetworkServiceDevices(timeout: 3) else { return false }
        let deadline = uptime() + 10
        while uptime() < deadline {
            for name in names {
                guard let device = devices[name] else { continue }
                var remaining = deadline - uptime()
                guard remaining > 0 else { return false }
                guard interfaceIsActive(device, timeout: min(remaining, 1.5)) else { continue }
                remaining = deadline - uptime()
                guard remaining > 0 else { return false }
                if networkServiceHasIPAddress(name, timeout: min(remaining, 2)) { return true }
            }
            let remaining = deadline - uptime()
            guard remaining > 0 else { return false }
            sleep(min(remaining, 0.5))
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
            throw HelperWorkflowError.command("Some network services are no longer available.")
        }
        return result
    }

    private func currentWiFiPowerState(_ device: String) throws -> String {
        let output = try runNetworkSetup(["-getairportpower", device])
        return output.localizedCaseInsensitiveContains(": On") ? "on" : "off"
    }

    private func executeSwitch(target: String, wifiDevice: String?, currentOrder: [String]) throws {
        let systemOrder = try currentNetworkServiceOrder()
        guard systemOrder == currentOrder else {
            throw HelperWorkflowError.command("Network service order changed; refresh and try again.")
        }
        let originalTargetState = try currentServiceStates([target])[target] ?? "off"
        let originalWiFiState = try wifiDevice.map(currentWiFiPowerState)
        var rollback: [RollbackStep] = []

        do {
            if let wifiDevice, let originalWiFiState {
                rollback.append(("restore Wi-Fi power for \(wifiDevice)", {
                    _ = try self.runNetworkSetup(["-setairportpower", wifiDevice, originalWiFiState])
                }))
                try runNetworkSetup(["-setairportpower", wifiDevice, "on"])
            }
            rollback.append(("restore service state for \(target)", {
                _ = try self.runNetworkSetup(["-setnetworkserviceenabled", target, originalTargetState])
            }))
            try runNetworkSetup(["-setnetworkserviceenabled", target, "on"])
            guard waitForAnyReadyNetworkService([target]) else {
                throw HelperWorkflowError.command("目标网络尚未获得可用地址；原有连接与优先级已保留。")
            }
            rollback.append(("restore network service order", {
                _ = try self.runNetworkSetup(["-ordernetworkservices"] + systemOrder)
            }))
            let newOrder = [target] + currentOrder.filter { $0 != target }
            try runNetworkSetup(["-ordernetworkservices"] + newOrder)
        } catch {
            try throwAfterRollback(originalError: error, steps: rollback.reversed())
        }
    }

    private func executeProfile(_ operations: [HelperProfileOperation]) throws {
        let orderedOperations = operations.filter { $0.kind == .wifi && $0.state == "on" }
            + operations.filter { $0.kind == .service && $0.state == "on" }
            + operations.filter { $0.kind == .service && $0.state == "off" }
            + operations.filter { $0.kind == .wifi && $0.state == "off" }
        let enabledTargets = operations.filter { $0.kind == .ready }.map(\.name)
        let serviceNames = Set(operations.filter { $0.kind == .service }.map(\.name))
        let originalServiceStates = try currentServiceStates(serviceNames)
        var originalWiFiStates: [String: String] = [:]
        for device in Set(operations.filter { $0.kind == .wifi }.map(\.name)) {
            originalWiFiStates[device] = try currentWiFiPowerState(device)
        }

        var completed: [HelperProfileOperation] = []
        do {
            var checkedReadiness = false
            for operation in orderedOperations {
                let isDestructive = operation.state == "off"
                if isDestructive, !checkedReadiness, !enabledTargets.isEmpty {
                    guard waitForAnyReadyNetworkService(enabledTargets) else {
                        throw HelperWorkflowError.command("方案中的目标网络尚未就绪；现有连接已保留。")
                    }
                    checkedReadiness = true
                }
                completed.append(operation)
                switch operation.kind {
                case .service:
                    try runNetworkSetup(["-setnetworkserviceenabled", operation.name, operation.state])
                case .wifi:
                    try runNetworkSetup(["-setairportpower", operation.name, operation.state])
                case .ready:
                    break
                }
            }
        } catch {
            let rollback: [RollbackStep] = completed.reversed().compactMap { operation in
                switch operation.kind {
                case .service:
                    guard let state = originalServiceStates[operation.name] else { return nil }
                    return ("restore service state for \(operation.name)", {
                        _ = try self.runNetworkSetup(["-setnetworkserviceenabled", operation.name, state])
                    })
                case .wifi:
                    guard let state = originalWiFiStates[operation.name] else { return nil }
                    return ("restore Wi-Fi power for \(operation.name)", {
                        _ = try self.runNetworkSetup(["-setairportpower", operation.name, state])
                    })
                case .ready:
                    return nil
                }
            }
            try throwAfterRollback(originalError: error, steps: rollback)
        }
    }

    private func throwAfterRollback<S: Sequence>(
        originalError: Error,
        steps: S
    ) throws where S.Element == RollbackStep {
        var rollbackFailures: [String] = []
        for step in steps {
            do {
                try step.action()
            } catch {
                rollbackFailures.append("\(step.label): \(error)")
            }
        }
        guard !rollbackFailures.isEmpty else { throw originalError }
        throw HelperWorkflowError.command(
            "\(originalError) Rollback also failed: \(rollbackFailures.joined(separator: "; "))"
        )
    }
}
