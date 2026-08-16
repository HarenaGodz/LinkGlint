import Foundation
import Network
import Darwin
import CoreWLAN
import CFNetwork

/// Read-only snapshot of the local proxy path. It deliberately does not expose
/// controls: LinkGlint can observe the path without taking ownership of Clash
/// or changing the user's proxy configuration.
struct ProxyPathSnapshot: Equatable {
    let systemProxyEnabled: Bool?
    let tunEnabled: Bool
    let clashOutboundMode: ClashOutboundMode?
    let intranetAddresses: [String]
}

enum ClashOutboundMode: String, Equatable {
    case rule
    case global
    case direct

    var displayName: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }

    static func parse(_ raw: String?) -> ClashOutboundMode? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rule": return .rule
        case "global": return .global
        case "direct": return .direct
        default: return nil
        }
    }
}

enum ProxyPathDetector {
    static func snapshot(tunEnabled: Bool, clashOutboundMode: ClashOutboundMode? = nil) -> ProxyPathSnapshot {
        ProxyPathSnapshot(
            systemProxyEnabled: systemProxyEnabled(),
            tunEnabled: tunEnabled,
            clashOutboundMode: clashOutboundMode,
            intranetAddresses: intranetAddresses()
        )
    }

    static func systemProxyEnabled() -> Bool? {
        guard let unmanaged = CFNetworkCopySystemProxySettings(),
              let settings = unmanaged.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let keys = [
            kCFNetworkProxiesHTTPEnable as String,
            kCFNetworkProxiesHTTPSEnable as String,
            kCFNetworkProxiesSOCKSEnable as String
        ]
        let values = keys.compactMap { settings[$0] as? NSNumber }
        guard !values.isEmpty else { return false }
        return values.contains { $0.boolValue }
    }

    /// Returns usable addresses on active, non-loopback interfaces. IPv6 is
    /// preferred because it is the most useful representation in a compact
    /// dashboard card, followed by IPv4. Link-local IPv6 is omitted.
    static func intranetAddresses() -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var ipv6: [String] = []
        var ipv4: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let rawAddress = entry.ifa_addr,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(rawAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let interface = String(cString: entry.ifa_name)
            guard !interface.hasPrefix("utun") else {
                // A TUN address is a virtual path, not the user's intranet
                // address shown by FlClash's local-network card.
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                rawAddress,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let address = String(cString: host)
            if family == AF_INET6 {
                let normalized = address.lowercased()
                guard normalized != "::", normalized != "::1", !normalized.hasPrefix("fe80:") else { continue }
                ipv6.append(address)
            } else {
                guard !address.hasPrefix("127."), !address.hasPrefix("169.254.") else { continue }
                ipv4.append(address)
            }
        }
        var result: [String] = []
        for address in ipv6 + ipv4 where !result.contains(address) {
            result.append(address)
        }
        return result
    }
}

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

struct ProcessTrafficCounters: Equatable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

enum PublicIPAddressParser {
    static func parse(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if IPv4Address(value) != nil || IPv6Address(value) != nil { return value }
        return nil
    }
}

enum CloudflareTraceIPParser {
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ip=") else { continue }
            let value = String(trimmed.dropFirst(3))
            if let address = PublicIPAddressParser.parse(value) { return address }
        }
        return nil
    }
}

struct PublicIPInfo: Equatable {
    let address: String
    let countryCode: String?
    let city: String?
    let region: String?
    let continentCode: String?
    let organization: String?
    let timezone: String?

    init(
        address: String,
        countryCode: String? = nil,
        city: String? = nil,
        region: String? = nil,
        continentCode: String? = nil,
        organization: String? = nil,
        timezone: String? = nil
    ) {
        self.address = address
        self.countryCode = countryCode
        self.city = city
        self.region = region
        self.continentCode = continentCode
        self.organization = organization
        self.timezone = timezone
    }
}

struct PublicIPGeoInfo: Equatable {
    let countryCode: String?
    let city: String?
    let region: String?
    let continentCode: String?
    let organization: String?
    let timezone: String?

    init(
        countryCode: String? = nil,
        city: String? = nil,
        region: String? = nil,
        continentCode: String? = nil,
        organization: String? = nil,
        timezone: String? = nil
    ) {
        self.countryCode = countryCode
        self.city = city
        self.region = region
        self.continentCode = continentCode
        self.organization = organization
        self.timezone = timezone
    }

    var hasUsefulLocation: Bool {
        countryCode != nil || city != nil || region != nil || continentCode != nil || organization != nil
    }
}

struct PublicIPPanelPresentation: Equatable {
    let addressLine: String
    let countryLine: String?
    let detailLine: String?
    let ownershipLine: String?
    let toolTip: String

    /// Combined location for compact one-line displays (menu strings, tooltips).
    var locationLine: String? {
        let parts = [countryLine, detailLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum PublicIPCountryCodeParser {
    static func parse(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return nil
        }
        return code
    }
}

enum PublicIPContinentFormatter {
    static func chineseName(for code: String?) -> String? {
        guard let code else { return nil }
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "AS": return "亚洲"
        case "EU": return "欧洲"
        case "NA": return "北美洲"
        case "SA": return "南美洲"
        case "AF": return "非洲"
        case "OC": return "大洋洲"
        case "AN": return "南极洲"
        default: return nil
        }
    }
}

enum PublicIPInfoParser {
    static func parse(_ output: String) -> PublicIPInfo? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIP = json["ip"] as? String,
              let address = PublicIPAddressParser.parse(rawIP) else { return nil }
        let geo = PublicIPGeoFieldsParser.parse(json)
        return PublicIPInfo(
            address: address,
            countryCode: geo.countryCode,
            city: geo.city,
            region: geo.region,
            continentCode: geo.continentCode,
            organization: geo.organization,
            timezone: geo.timezone
        )
    }
}

enum PublicIPGeoFieldsParser {
    static func parse(_ json: [String: Any]) -> PublicIPGeoInfo {
        let countryCode = PublicIPCountryCodeParser.parse(json["country_code"] as? String)
            ?? PublicIPCountryCodeParser.parse(json["country"] as? String)
        let city = cleanedText(json["city"] as? String)
        let region = cleanedText(json["region"] as? String)
        let continentCode = cleanedText(json["continent_code"] as? String)?.uppercased()
        let organization = cleanedText(json["organization_name"] as? String)
            ?? cleanedOrganization(json["organization"] as? String)
            ?? cleanedText(json["org"] as? String)
        let timezone = cleanedText(json["timezone"] as? String)
        return PublicIPGeoInfo(
            countryCode: countryCode,
            city: city,
            region: region,
            continentCode: continentCode,
            organization: organization,
            timezone: timezone
        )
    }

    private static func cleanedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func cleanedOrganization(_ raw: String?) -> String? {
        guard var value = cleanedText(raw) else { return nil }
        // geojs often prefixes "AS12345 ".
        if value.uppercased().hasPrefix("AS"),
           let space = value.firstIndex(of: " ") {
            value = String(value[value.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }
}

enum GeoJSGeoParser {
    static func parse(_ output: String) -> PublicIPGeoInfo? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let geo = PublicIPGeoFieldsParser.parse(json)
        return geo.hasUsefulLocation ? geo : nil
    }
}

enum PublicIPDisplayFormatter {
    /// Mainland-compliance overrides: never present TW/HK/MO as independent states,
    /// and never emit the Taiwan flag emoji.
    private static let sensitiveRegionDisplays: [String: (flag: String, name: String)] = [
        "CN": ("🇨🇳", "中国"),
        "TW": ("🇨🇳", "中国台湾"),
        "HK": ("🇨🇳", "中国香港"),
        "MO": ("🇨🇳", "中国澳门")
    ]

    static func panelPresentation(
        address: String?,
        countryCode: String?,
        city: String? = nil,
        region: String? = nil,
        continentCode: String? = nil,
        organization: String? = nil,
        timezone: String? = nil
    ) -> PublicIPPanelPresentation {
        guard let address else {
            return PublicIPPanelPresentation(
                addressLine: "检测中…",
                countryLine: nil,
                detailLine: nil,
                ownershipLine: nil,
                toolTip: "正在检测出口 IP"
            )
        }
        let country = countryLine(countryCode: countryCode)
        let detail = detailLine(
            countryCode: countryCode,
            city: city,
            region: region,
            continentCode: continentCode
        )
        let ownership = ownershipLine(organization: organization)
        var tipLines = ["最近检测：\(address)"]
        let locationParts = [country, detail].compactMap { $0 }
        if !locationParts.isEmpty {
            tipLines.append(locationParts.joined(separator: " · "))
        }
        if let ownership { tipLines.append("归属 \(ownership)") }
        if let timezone, !timezone.isEmpty { tipLines.append("时区：\(timezone)") }
        return PublicIPPanelPresentation(
            addressLine: address,
            countryLine: country,
            detailLine: detail,
            ownershipLine: ownership,
            toolTip: tipLines.joined(separator: "\n")
        )
    }

    static func string(
        address: String,
        countryCode: String?,
        city: String? = nil
    ) -> String {
        let presentation = panelPresentation(
            address: address,
            countryCode: countryCode,
            city: city
        )
        if let location = presentation.locationLine {
            return "\(presentation.addressLine) · \(location)"
        }
        return presentation.addressLine
    }

    static func toolTip(
        address: String,
        countryCode: String?,
        city: String? = nil,
        organization: String? = nil,
        timezone: String? = nil
    ) -> String {
        panelPresentation(
            address: address,
            countryCode: countryCode,
            city: city,
            organization: organization,
            timezone: timezone
        ).toolTip
    }

    private static func countryLine(countryCode: String?) -> String? {
        guard let country = regionDisplay(for: countryCode) else { return nil }
        return "\(country.flag) \(country.name)"
    }

    private static func detailLine(
        countryCode: String?,
        city: String?,
        region: String?,
        continentCode: String?
    ) -> String? {
        var parts: [String] = []
        let countryName = regionDisplay(for: countryCode)?.name
        if let city = distinctPlace(city, avoiding: [countryName].compactMap { $0 }) {
            parts.append(city)
        }
        if let region = distinctPlace(region, avoiding: [countryName, city].compactMap { $0 }) {
            parts.append(region)
        }
        if let continent = PublicIPContinentFormatter.chineseName(for: continentCode) {
            parts.append(continent)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func ownershipLine(organization: String?) -> String? {
        cleanedText(organization)
    }

    private static func regionDisplay(for countryCode: String?) -> (flag: String, name: String)? {
        guard let countryCode else { return nil }
        if let override = sensitiveRegionDisplays[countryCode] {
            return override
        }
        guard Locale.Region.isoRegions.contains(Locale.Region(countryCode)),
              let name = Locale(identifier: "zh_CN").localizedString(forRegionCode: countryCode),
              !name.isEmpty,
              let flag = flagEmoji(for: countryCode) else {
            return nil
        }
        return (flag, name)
    }

    private static func distinctPlace(_ value: String?, avoiding: [String]) -> String? {
        guard let cleaned = cleanedText(value) else { return nil }
        for item in avoiding where cleaned.caseInsensitiveCompare(item) == .orderedSame {
            return nil
        }
        return cleaned
    }

    private static func cleanedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func flagEmoji(for countryCode: String) -> String? {
        if sensitiveRegionDisplays[countryCode] != nil {
            return sensitiveRegionDisplays[countryCode]?.flag
        }
        let scalars = countryCode.uppercased().unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            guard CharacterSet.uppercaseLetters.contains(scalar),
                  let value = Unicode.Scalar(127397 + scalar.value) else { return nil }
            return value
        }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }
}

enum ProcessTrafficParser {
    static func parse(_ output: String) -> [String: ProcessTrafficCounters] {
        let rows = output.split(whereSeparator: \.isNewline)
        guard let header = rows.first?.split(separator: ",", omittingEmptySubsequences: false),
              let receivedIndex = header.firstIndex(of: "bytes_in"),
              let sentIndex = header.firstIndex(of: "bytes_out") else { return [:] }
        var result: [String: ProcessTrafficCounters] = [:]
        for row in rows.dropFirst() {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(receivedIndex, sentIndex), fields.count > 1,
                  let received = UInt64(fields[receivedIndex].trimmingCharacters(in: .whitespaces)),
                  let sent = UInt64(fields[sentIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let rawName = fields[1].trimmingCharacters(in: .whitespaces)
            guard !rawName.isEmpty else { continue }
            let name = rawName.split(separator: ".").last.map(String.init).flatMap { Int($0) } != nil
                ? String(rawName[..<(rawName.lastIndex(of: ".") ?? rawName.endIndex)])
                : rawName
            let old = result[name] ?? ProcessTrafficCounters(receivedBytes: 0, sentBytes: 0)
            result[name] = ProcessTrafficCounters(
                receivedBytes: old.receivedBytes > UInt64.max - received ? UInt64.max : old.receivedBytes + received,
                sentBytes: old.sentBytes > UInt64.max - sent ? UInt64.max : old.sentBytes + sent
            )
        }
        return result
    }
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
        // interface. Prefer the primary VPN when one is active; otherwise sum
        // every connected physical transport so simultaneous Wi-Fi + cellular
        // traffic is not silently omitted from the total rate.
        var measured: InterfaceCounters
        if let primaryVPN = services.first(where: {
            $0.connected && $0.isPrimary && $0.kind == .vpn
        })?.device.flatMap({ deltas[$0] }) {
            measured = primaryVPN
        } else {
            let physicalDevices = services
                .filter { $0.connected && $0.isPhysicalTransport }
                .compactMap(\.device)
            func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
                lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
            }
            measured = physicalDevices.reduce(
                InterfaceCounters(receivedBytes: 0, sentBytes: 0)
            ) { partial, device in
                guard let delta = deltas[device] else { return partial }
                return InterfaceCounters(
                    receivedBytes: saturatingAdd(partial.receivedBytes, delta.receivedBytes),
                    sentBytes: saturatingAdd(partial.sentBytes, delta.sentBytes)
                )
            }
            if measured.receivedBytes == 0 && measured.sentBytes == 0,
               let fallbackDevice = services.first(where: { $0.connected })?.device,
               let fallback = deltas[fallbackDevice] {
                measured = fallback
            }
        }
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
    let gatewayPacketLossPercent: Double?
    let dnsLookupLatencyMilliseconds: Double?
    let internetReachable: Bool?
    let internetLatencyMilliseconds: Double?
    let ipv6DefaultRouteAvailable: Bool

    init(
        date: Date,
        defaultInterface: String?,
        gateway: String?,
        gatewayLatencyMilliseconds: Double?,
        dnsLookupSucceeded: Bool,
        systemDNSServers: [String],
        gatewayPacketLossPercent: Double? = nil,
        dnsLookupLatencyMilliseconds: Double? = nil,
        internetReachable: Bool? = nil,
        internetLatencyMilliseconds: Double? = nil,
        ipv6DefaultRouteAvailable: Bool = false
    ) {
        self.date = date
        self.defaultInterface = defaultInterface
        self.gateway = gateway
        self.gatewayLatencyMilliseconds = gatewayLatencyMilliseconds
        self.dnsLookupSucceeded = dnsLookupSucceeded
        self.systemDNSServers = systemDNSServers
        self.gatewayPacketLossPercent = gatewayPacketLossPercent
        self.dnsLookupLatencyMilliseconds = dnsLookupLatencyMilliseconds
        self.internetReachable = internetReachable
        self.internetLatencyMilliseconds = internetLatencyMilliseconds
        self.ipv6DefaultRouteAvailable = ipv6DefaultRouteAvailable
    }

    var summary: String {
        guard defaultInterface != nil else { return "未检测到默认网络" }
        if internetReachable == false { return "外网不可达" }
        if gatewayPacketLossPercent.map({ $0 >= 100 }) == true { return "网关不可达" }
        if gatewayLatencyMilliseconds != nil && dnsLookupSucceeded { return "网络状态良好" }
        if gatewayLatencyMilliseconds == nil && dnsLookupSucceeded { return "网络可用 · 网关未响应延迟检测" }
        if gatewayLatencyMilliseconds == nil { return "网络连通性需要检查" }
        return "DNS 查询异常"
    }

    var isUsable: Bool {
        defaultInterface != nil
            && dnsLookupSucceeded
            && internetReachable != false
            && gatewayPacketLossPercent.map { $0 < 100 } != false
    }
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

final class NetworkManager {
    private let networksetup = "/usr/sbin/networksetup"
    private static let coreWLANAccessGate = CoreWLANAccessGate()
    private let privilegedHelper: PrivilegedHelperManager
    private let egressIPClient: EgressIPClient
    private let clashRuntimeStatusClient: ClashRuntimeStatusClient
    private let wifiSSIDCacheLock = NSLock()
    private var wifiSSIDCache = WiFiSSIDStabilityCache()

    init(
        privilegedHelper: PrivilegedHelperManager = PrivilegedHelperManager(),
        egressIPClient: EgressIPClient = URLSessionEgressIPClient(),
        clashRuntimeStatusClient: ClashRuntimeStatusClient = ClashRuntimeStatusClient()
    ) {
        self.privilegedHelper = privilegedHelper
        self.egressIPClient = egressIPClient
        self.clashRuntimeStatusClient = clashRuntimeStatusClient
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

    func fetchProcessTrafficCounters() throws -> [String: ProcessTrafficCounters] {
        ProcessTrafficParser.parse(try CommandRunner.run(
            "/usr/bin/nettop",
            ["-P", "-L", "1", "-x", "-n"],
            timeout: 5
        ))
    }

    func fetchPublicIPAddress(vpnActive: Bool = false) async throws -> String {
        try await egressIPClient.fetchAddress(vpnActive: vpnActive)
    }

    func fetchDirectPublicIPAddress() async throws -> String {
        try await egressIPClient.fetchDirectAddress()
    }

    func fetchPublicIPGeoInfo(for address: String) async throws -> PublicIPGeoInfo {
        try await egressIPClient.fetchGeoInfo(for: address)
    }

    func fetchPublicIPInfoCombined(vpnActive: Bool = false) async throws -> PublicIPInfo {
        try await egressIPClient.fetchCombinedInfo(vpnActive: vpnActive)
    }

    /// Returns tunnel interfaces that have a routable address. macOS network
    /// extensions (for example FlClash's TUN mode) may create an active utun
    /// interface without registering a Network Service in `scutil --nc`.
    func fetchActiveVPNInterfaceNames() -> Set<String> {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var addresses: [VPNInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }
            guard let rawAddress = entry.ifa_addr else { continue }
            let family = Int32(rawAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("tun") else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                rawAddress,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append(VPNInterfaceAddress(
                name: name,
                address: String(cString: host),
                isUp: entry.ifa_flags & UInt32(IFF_UP) != 0
            ))
        }
        return ActiveVPNInterfaceDetector.activeInterfaceNames(in: addresses)
    }

    /// Reads the local network path for the optional dashboard summary. This
    /// method is intentionally cheap except for the loopback Clash probe and
    /// should be called only while the shortcut panel is visible.
    func fetchProxyPathSnapshot(tunEnabled: Bool) async -> ProxyPathSnapshot {
        let mode = await clashRuntimeStatusClient.fetchMode()
        return ProxyPathDetector.snapshot(tunEnabled: tunEnabled, clashOutboundMode: mode)
    }

    func runDiagnostics() async -> NetworkDiagnostic {
        let ipv4Route = try? CommandRunner.run("/sbin/route", ["-n", "get", "default"])
        let ipv6RouteOutput = try? CommandRunner.run("/sbin/route", ["-n", "get", "-inet6", "default"])
        let routeOutput = ipv4Route ?? ipv6RouteOutput ?? ""
        let defaultInterface = parseValue("interface", in: routeOutput)
        let gateway = parseValue("gateway", in: routeOutput)
        let gatewayResult: (latency: Double?, loss: Double?)
        if let gateway {
            let ping = diagnosticPingInvocation(gateway: gateway)
            let output = try? CommandRunner.run(
                ping.executable,
                pingArguments(ping.arguments, count: 3),
                timeout: 5
            )
            if let output {
                gatewayResult = (
                    parsePingAverageLatency(output) ?? parsePingLatency(output),
                    parsePingPacketLoss(output)
                )
            } else {
                gatewayResult = (nil, 100)
            }
        } else {
            gatewayResult = (nil, nil)
        }

        let dnsStartedAt = ProcessInfo.processInfo.systemUptime
        let dnsLookupOutput = (try? CommandRunner.run(
            "/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "www.apple.com"], timeout: 3
        )) ?? ""
        let dnsLatency = (ProcessInfo.processInfo.systemUptime - dnsStartedAt) * 1000
        let dnsOutput = (try? CommandRunner.run("/usr/sbin/scutil", ["--dns"])) ?? ""
        let internet = await probeInternet()

        return NetworkDiagnostic(
            date: Date(),
            defaultInterface: defaultInterface,
            gateway: gateway,
            gatewayLatencyMilliseconds: gatewayResult.latency,
            dnsLookupSucceeded: dnsLookupDidResolve(dnsLookupOutput),
            systemDNSServers: parseSystemDNSServers(dnsOutput),
            gatewayPacketLossPercent: gatewayResult.loss,
            dnsLookupLatencyMilliseconds: dnsLookupOutput.isEmpty ? nil : dnsLatency,
            internetReachable: internet.reachable,
            internetLatencyMilliseconds: internet.latency,
            ipv6DefaultRouteAvailable: ipv6RouteOutput != nil
        )
    }

    private func probeInternet() async -> (reachable: Bool, latency: Double?) {
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
                return (false, nil)
            }
            return (true, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        } catch {
            return (false, nil)
        }
    }

    private func pingArguments(_ arguments: [String], count: Int) -> [String] {
        var result = arguments
        if let index = result.firstIndex(of: "-c"), result.indices.contains(index + 1) {
            result[index + 1] = String(max(count, 1))
        }
        return result
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

    func parseActiveVPNInterfaceNames(_ output: String) -> Set<String> {
        var active: Set<String> = []
        var currentInterface: String?
        var hasRoutableAddress = false

        func finishCurrentInterface() {
            guard let currentInterface,
                  hasRoutableAddress,
                  currentInterface.hasPrefix("utun")
                    || currentInterface.hasPrefix("ppp")
                    || currentInterface.hasPrefix("tun") else { return }
            active.insert(currentInterface)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if !text.hasPrefix(" ") && !text.hasPrefix("\t"),
               let colon = text.firstIndex(of: ":") {
                finishCurrentInterface()
                currentInterface = String(text[..<colon])
                hasRoutableAddress = false
                continue
            }
            guard currentInterface != nil else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                hasRoutableAddress = true
            } else if trimmed.hasPrefix("inet6 ") {
                let fields = trimmed.split(whereSeparator: \.isWhitespace)
                if let address = fields.dropFirst().first,
                   !address.hasPrefix("fe80:") {
                    hasRoutableAddress = true
                }
            }
        }
        finishCurrentInterface()
        return active
    }

    func parsePingLatency(_ output: String) -> Double? {
        let expression = #"time[=<]([0-9.]+)\s*ms"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }

    func parsePingAverageLatency(_ output: String) -> Double? {
        let expression = #"=\s*[0-9.]+/([0-9.]+)/[0-9.]+/[0-9.]+\s*ms"#
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Double(output[range])
    }

    func parsePingPacketLoss(_ output: String) -> Double? {
        let expression = #"([0-9.]+)%\s*packet loss"#
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
