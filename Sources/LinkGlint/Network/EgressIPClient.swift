import Foundation

protocol EgressIPClient {
    func fetchAddress(vpnActive: Bool) async throws -> String
    func fetchGeoInfo(for address: String) async throws -> PublicIPGeoInfo
    func fetchCombinedInfo(vpnActive: Bool) async throws -> PublicIPInfo
}

final class URLSessionEgressIPClient: EgressIPClient, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
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
    }

    func fetchAddress(vpnActive: Bool) async throws -> String {
        let timeout = vpnActive ? 2.5 : 1.5
        let probes: [@Sendable () async -> String?] = [
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://1.1.1.1/cdn-cgi/trace")!,
                    timeout: timeout
                ) else { return nil }
                return CloudflareTraceIPParser.parse(text)
            },
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://api.ipify.org")!,
                    timeout: timeout
                ) else { return nil }
                return PublicIPAddressParser.parse(text)
            },
            { [self] in
                guard let text = try? await text(
                    from: URL(string: "https://ipv4.icanhazip.com")!,
                    timeout: timeout
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

    private func text(from url: URL, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
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
