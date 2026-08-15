import Foundation
import Darwin

public enum HelperArgumentValidation {
    public static func validateName(_ value: String, label: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HelperArgumentError.invalid("Invalid \(label).")
        }
    }

    public static func validateDevice(_ value: String) throws {
        guard value.range(of: #"^[A-Za-z0-9._-]{1,32}$"#, options: .regularExpression) != nil else {
            throw HelperArgumentError.invalid("Invalid network device.")
        }
    }

    public static func validateState(_ value: String) throws {
        guard value == "on" || value == "off" else {
            throw HelperArgumentError.invalid("State must be on or off.")
        }
    }

    public static func validateIPAddress(_ value: String) throws {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let components = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let plainIPv6 = components.first.map(String.init) ?? value
        if components.count == 2 {
            try validateDevice(String(components[1]))
        }
        let isIPv4 = value.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
        let isIPv6 = plainIPv6.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
        guard isIPv4 || isIPv6 else { throw HelperArgumentError.invalid("Invalid DNS address.") }
    }

    public static func isUsableIPAddress(_ value: String) -> Bool {
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
}

public enum HelperArgumentError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): return message
        }
    }
}
