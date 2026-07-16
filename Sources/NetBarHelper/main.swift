import Foundation
import Darwin

/// A deliberately small root helper. It accepts only NetBar's fixed network
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
        case .permission: return "NetBarHelper must run as root."
        case .command(let message): return message
        }
    }
}

private let networksetup = "/usr/sbin/networksetup"

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
private func runNetworkSetup(_ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: networksetup)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw HelperFailure.command(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return text
}

private func run(_ arguments: [String]) throws {
    guard !arguments.isEmpty else { throw HelperFailure.usage("Missing operation.") }

    if arguments == ["status"] {
        guard geteuid() == 0 else { throw HelperFailure.permission }
        print("NetBarHelper ready")
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
            throw HelperFailure.usage("Usage: switch TARGET WIFI_OR_DASH [OTHER_SERVICE...]")
        }
        let target = arguments[1]
        let wifiDevice = arguments[2]
        try validateName(target, label: "service name")
        if wifiDevice != "-" {
            try validateDevice(wifiDevice)
            try runNetworkSetup(["-setairportpower", wifiDevice, "on"])
        }
        try runNetworkSetup(["-setnetworkserviceenabled", target, "on"])
        for service in arguments.dropFirst(3) {
            try validateName(service, label: "service name")
            try runNetworkSetup(["-setnetworkserviceenabled", service, "off"])
        }

    case "profile":
        let values = Array(arguments.dropFirst())
        guard !values.isEmpty, values.count.isMultiple(of: 3), values.count <= 192 else {
            throw HelperFailure.usage("Usage: profile (service|wifi NAME on|off)...")
        }
        var index = 0
        while index < values.count {
            let kind = values[index]
            let name = values[index + 1]
            let state = values[index + 2]
            try validateState(state)
            if kind == "service" {
                try validateName(name, label: "service name")
                try runNetworkSetup(["-setnetworkserviceenabled", name, state])
            } else if kind == "wifi" {
                try validateDevice(name)
                try runNetworkSetup(["-setairportpower", name, state])
            } else {
                throw HelperFailure.usage("Unknown profile operation.")
            }
            index += 3
        }

    default:
        throw HelperFailure.usage("Unknown operation.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("NetBarHelper: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
