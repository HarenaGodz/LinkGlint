import Foundation
import CFNetwork

protocol EgressIPClient {
    func fetchAddress(vpnActive: Bool) async throws -> String
    func fetchDirectAddress() async throws -> String
    func fetchGeoInfo(for address: String) async throws -> PublicIPGeoInfo
    func fetchCombinedInfo(vpnActive: Bool) async throws -> PublicIPInfo
}

final class URLSessionEgressIPClient: EgressIPClient, @unchecked Sendable {
    private let session: URLSession
    private let directSession: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            let directConfiguration = URLSessionConfiguration.ephemeral
            directConfiguration.httpCookieAcceptPolicy = .never
            directConfiguration.httpShouldSetCookies = false
            directConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            directConfiguration.urlCache = nil
            directConfiguration.timeoutIntervalForRequest = 2.5
            directConfiguration.timeoutIntervalForResource = 3
            directConfiguration.waitsForConnectivity = false
            directConfiguration.connectionProxyDictionary = Self.proxyDisabledDictionary
            self.directSession = URLSession(configuration: directConfiguration)
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        let directConfiguration = URLSessionConfiguration.ephemeral
        directConfiguration.httpCookieAcceptPolicy = .never
        directConfiguration.httpShouldSetCookies = false
        directConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        directConfiguration.urlCache = nil
        directConfiguration.timeoutIntervalForRequest = 2.5
        directConfiguration.timeoutIntervalForResource = 3
        directConfiguration.waitsForConnectivity = false
        directConfiguration.connectionProxyDictionary = Self.proxyDisabledDictionary
        self.directSession = URLSession(configuration: directConfiguration)
    }

    private static let proxyDisabledDictionary: [AnyHashable: Any] = [
        kCFNetworkProxiesHTTPEnable as String: false,
        kCFNetworkProxiesHTTPSEnable as String: false,
        kCFNetworkProxiesSOCKSEnable as String: false
    ]

    func fetchAddress(vpnActive: Bool) async throws -> String {
        try await fetchAddress(using: session, vpnActive: vpnActive)
    }

    func fetchDirectAddress() async throws -> String {
        try await fetchAddress(using: directSession, vpnActive: true)
    }

    private func fetchAddress(using session: URLSession, vpnActive: Bool) async throws -> String {
        let timeout = vpnActive ? 2.5 : 1.5
        let probes: [@Sendable () async -> String?] = [
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
                    timeout: timeout,
                    session: session
                ) else { return nil }
                return CloudflareTraceIPParser.parse(text)
            },
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://api.ipify.org")!,
                    timeout: timeout,
                    session: session
                ) else { return nil }
                return PublicIPAddressParser.parse(text)
            },
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://ipv4.icanhazip.com")!,
                    timeout: timeout,
                    session: session
                ) else { return nil }
                return PublicIPAddressParser.parse(text)
            }
        ]
        guard let result = await HedgedRequest.firstValid(probes, hedgeDelayNanoseconds: 250_000_000) else {
            throw NetworkError.commandFailed("出口 IP 暂时不可用。")
        }
        return result
    }

    func fetchGeoInfo(for address: String) async throws -> PublicIPGeoInfo {
        guard PublicIPAddressParser.parse(address) != nil else {
            throw NetworkError.commandFailed("出口 IP 暂时不可用。")
        }
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        let probes: [@Sendable () async -> PublicIPGeoInfo?] = [
            { [self] in
                guard let url = URL(string: "https://get.geojs.io/v1/ip/geo/\(encoded).json"),
                      let text = try? await text(from: url, timeout: 2) else { return nil }
                return GeoJSGeoParser.parse(text)
            },
            { [self] in
                guard let url = URL(string: "https://ipinfo.io/\(encoded)/json"),
                      let text = try? await text(from: url, timeout: 2),
                      let info = PublicIPInfoParser.parse(text) else { return nil }
                return PublicIPGeoInfo(
                    countryCode: info.countryCode,
                    city: info.city,
                    region: info.region,
                    continentCode: info.continentCode,
                    organization: info.organization,
                    timezone: info.timezone
                )
            }
        ]
        guard let result = await HedgedRequest.firstValid(probes, hedgeDelayNanoseconds: 250_000_000) else {
            throw NetworkError.commandFailed("出口地理位置暂时不可用。")
        }
        return result
    }

    func fetchCombinedInfo(vpnActive: Bool) async throws -> PublicIPInfo {
        if let url = URL(string: "https://get.geojs.io/v1/ip/geo.json"),
           let text = try? await text(from: url, timeout: 2),
           let info = PublicIPInfoParser.parse(text) {
            return info
        }
        let address = try await fetchAddress(vpnActive: vpnActive)
        let geo = try? await fetchGeoInfo(for: address)
        return PublicIPInfo(
            address: address,
            countryCode: geo?.countryCode,
            city: geo?.city,
            region: geo?.region,
            continentCode: geo?.continentCode,
            organization: geo?.organization,
            timezone: geo?.timezone
        )
    }

    private func text(
        from url: URL,
        timeout: TimeInterval,
        session: URLSession? = nil
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await (session ?? self.session).data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.count <= 128 * 1024,
              let value = String(data: data, encoding: .utf8) else {
            throw NetworkError.commandFailed("出口 IP 服务返回了无效响应。")
        }
        return value
    }
}

enum HedgedRequest {
    static func firstValid<T: Sendable>(
        _ producers: [@Sendable () async -> T?],
        hedgeDelayNanoseconds: UInt64
    ) async -> T? {
        guard !producers.isEmpty else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            for (index, producer) in producers.enumerated() {
                group.addTask {
                    if index > 0 {
                        try? await Task.sleep(
                            nanoseconds: hedgeDelayNanoseconds.multipliedReportingOverflow(by: UInt64(index)).partialValue
                        )
                    }
                    guard !Task.isCancelled else { return nil }
                    return await producer()
                }
            }
            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}
