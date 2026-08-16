import Foundation
import CFNetwork

/// Best-effort, loopback-only reader for Clash-compatible controllers.
///
/// FlClash and other Clash front-ends commonly expose `/configs` on one of the
/// local controller ports. The probe is intentionally read-only, short-lived,
/// and skipped from all background refreshes; failure simply means that no
/// controller was discoverable from LinkGlint.
final class ClashRuntimeStatusClient: @unchecked Sendable {
    private let session: URLSession
    private let ports: [Int]

    init(session: URLSession? = nil, ports: [Int] = [9090, 9097, 9095, 9091]) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 0.35
            configuration.timeoutIntervalForResource = 0.5
            configuration.waitsForConnectivity = false
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false
            ]
            self.session = URLSession(configuration: configuration)
        }
        self.ports = ports
    }

    func fetchMode() async -> ClashOutboundMode? {
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/configs") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 0.35
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawMode = json["mode"] as? String,
                  let mode = ClashOutboundMode.parse(rawMode) else { continue }
            return mode
        }
        return nil
    }
}
