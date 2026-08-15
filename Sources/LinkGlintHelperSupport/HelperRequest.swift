import Foundation

public enum HelperOperation: Equatable {
    case status
    case service(name: String, state: String)
    case wifi(device: String, state: String)
    case joinWiFi(device: String, network: String)
    case rename(oldName: String, newName: String)
    case dns(service: String, values: [String])
    case order(services: [String])
    case `switch`(target: String, wifiDevice: String?, currentOrder: [String])
    case profile(operations: [HelperProfileOperation])
}

public struct HelperProfileOperation: Equatable {
    public enum Kind: String, Equatable {
        case service
        case wifi
        case ready
    }

    public let kind: Kind
    public let name: String
    public let state: String

    public init(kind: Kind, name: String, state: String) {
        self.kind = kind
        self.name = name
        self.state = state
    }
}

public enum HelperRequest {
    public static func parse(_ arguments: [String]) throws -> HelperOperation {
        guard let command = arguments.first else {
            throw HelperArgumentError.invalid("Missing operation.")
        }
        switch command {
        case "status":
            guard arguments.count == 1 else { throw usage("status") }
            return .status
        case "service":
            guard arguments.count == 3 else { throw usage("service NAME on|off") }
            try HelperArgumentValidation.validateName(arguments[1], label: "service name")
            try HelperArgumentValidation.validateState(arguments[2])
            return .service(name: arguments[1], state: arguments[2])
        case "wifi":
            guard arguments.count == 3 else { throw usage("wifi DEVICE on|off") }
            try HelperArgumentValidation.validateDevice(arguments[1])
            try HelperArgumentValidation.validateState(arguments[2])
            return .wifi(device: arguments[1], state: arguments[2])
        case "join-wifi":
            guard arguments.count == 3 else { throw usage("join-wifi DEVICE NETWORK") }
            try HelperArgumentValidation.validateDevice(arguments[1])
            try HelperArgumentValidation.validateName(arguments[2], label: "network name")
            return .joinWiFi(device: arguments[1], network: arguments[2])
        case "rename":
            guard arguments.count == 3 else { throw usage("rename OLD_NAME NEW_NAME") }
            try HelperArgumentValidation.validateName(arguments[1], label: "old service name")
            try HelperArgumentValidation.validateName(arguments[2], label: "new service name")
            return .rename(oldName: arguments[1], newName: arguments[2])
        case "dns":
            guard (3...18).contains(arguments.count) else { throw usage("dns SERVICE empty|ADDRESS...") }
            try HelperArgumentValidation.validateName(arguments[1], label: "service name")
            let values = Array(arguments.dropFirst(2))
            if values.contains("empty") {
                guard values == ["empty"] else {
                    throw HelperArgumentError.invalid("Automatic DNS must be the only DNS value.")
                }
            } else {
                for value in values { try HelperArgumentValidation.validateIPAddress(value) }
            }
            return .dns(service: arguments[1], values: values)
        case "order":
            guard (2...65).contains(arguments.count) else { throw usage("order SERVICE...") }
            let services = Array(arguments.dropFirst())
            try validateUniqueNames(services, label: "service name")
            return .order(services: services)
        case "switch":
            guard (4...67).contains(arguments.count) else {
                throw usage("switch TARGET WIFI_OR_DASH CURRENT_ORDER...")
            }
            let target = arguments[1]
            let wifi = arguments[2]
            let order = Array(arguments.dropFirst(3))
            try HelperArgumentValidation.validateName(target, label: "service name")
            if wifi != "-" { try HelperArgumentValidation.validateDevice(wifi) }
            try validateUniqueNames(order, label: "service name")
            guard order.contains(target) else {
                throw HelperArgumentError.invalid("Incomplete network service order.")
            }
            return .switch(target: target, wifiDevice: wifi == "-" ? nil : wifi, currentOrder: order)
        case "profile":
            let values = Array(arguments.dropFirst())
            guard !values.isEmpty, values.count.isMultiple(of: 3), values.count <= 192 else {
                throw usage("profile (service|wifi|ready NAME on|off)...")
            }
            var operations: [HelperProfileOperation] = []
            for index in stride(from: 0, to: values.count, by: 3) {
                guard let kind = HelperProfileOperation.Kind(rawValue: values[index]) else {
                    throw HelperArgumentError.invalid("Unknown profile operation.")
                }
                let name = values[index + 1]
                let state = values[index + 2]
                try HelperArgumentValidation.validateState(state)
                if kind == .wifi {
                    try HelperArgumentValidation.validateDevice(name)
                } else {
                    try HelperArgumentValidation.validateName(name, label: "service name")
                }
                guard kind != .ready || state == "on" else {
                    throw HelperArgumentError.invalid("Readiness targets must use state on.")
                }
                operations.append(HelperProfileOperation(kind: kind, name: name, state: state))
            }
            let readiness = operations.filter { $0.kind == .ready }.map(\.name)
            let enabled = Set(operations.filter { $0.kind == .service && $0.state == "on" }.map(\.name))
            guard Set(readiness).count == readiness.count, Set(readiness).isSubset(of: enabled) else {
                throw HelperArgumentError.invalid("Invalid profile readiness targets.")
            }
            let identifiers = operations.filter { $0.kind != .ready }.map { "\($0.kind.rawValue):\($0.name)" }
            guard Set(identifiers).count == identifiers.count else {
                throw HelperArgumentError.invalid("Duplicate profile operation.")
            }
            return .profile(operations: operations)
        default:
            throw HelperArgumentError.invalid("Unknown operation.")
        }
    }

    private static func validateUniqueNames(_ values: [String], label: String) throws {
        for value in values { try HelperArgumentValidation.validateName(value, label: label) }
        guard Set(values).count == values.count else {
            throw HelperArgumentError.invalid("Duplicate network service.")
        }
    }

    private static func usage(_ value: String) -> HelperArgumentError {
        .invalid("Usage: \(value)")
    }
}

public protocol HelperCommandExecutor {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> String
}
