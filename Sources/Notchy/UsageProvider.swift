import Foundation

/// How UsageStore keeps a provider fresh. Endpoint fetches happen ONLY on the
/// poll timer, on wake, and on reset expiry — never on file-watch events
/// (else active coding sessions would 429-storm the endpoints).
enum RefreshPolicy: Equatable {
    case poll(Duration)                    // primary endpoint cadence (with jitter)
}

// MARK: - Tiny shared HTTP helper (zero-dependency)

enum HTTPError: Error {
    case rateLimited            // 429 → caller backs off
    case unauthorized           // 401 → caller re-reads/refreshes credentials
    case status(Int)
}

func fetchJSON(_ url: URL, headers: [String: String], timeout: TimeInterval = 20) async throws -> [String: Any] {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw HTTPError.status(-1) }
    switch http.statusCode {
    case 200: break
    case 429: throw HTTPError.rateLimited
    case 401: throw HTTPError.unauthorized
    default: throw HTTPError.status(http.statusCode)
    }
    // [String:Any] not Codable — schemas are undocumented and churn;
    // tolerant key-probing beats recompiling Decodables on every change
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

protocol UsageProvider {
    var info: ProviderInfo { get }
    var refresh: RefreshPolicy { get }

    /// Primary endpoint — network. Throws on failure; caller keeps last good.
    func currentUsage() async throws -> ProviderUsage

    /// Local/fallback sources only — never network. Nil when unavailable.
    func localUsage() async -> ProviderUsage?
}

extension UsageProvider {
    var watchPaths: [String] { [] }
}
