import Foundation
import Security

/// Claude (Anthropic) — primary: GET api.anthropic.com/api/oauth/usage with the
/// Claude Code OAuth token from Keychain item "Claude Code-credentials".
/// Fallback: ~/.claude.json → cachedUsageUtilization (refreshed by the CLI).
final class ClaudeProvider: UsageProvider {
    let info = ProviderInfo(id: "claude", name: "Claude", tintHex: "#D97757", symbol: "sparkles")
    let refresh: RefreshPolicy = .poll(.seconds(300))   // ≥ 5 min — endpoint 429s aggressively
    var watchPaths: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path]
    }

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    // Claude Code's public OAuth client id (same one the CLI itself uses).
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // In-memory token cache: one Keychain read per launch (read-prompt loops, §1.1).
    private var cachedToken: (accessToken: String, refreshToken: String, expiresAt: Date?)?
    private let keychain = Keychain()

    func currentUsage() async throws -> ProviderUsage {
        let tok = try await token(forceRefresh: false)
        do {
            return try await fetchUsage(accessToken: tok.accessToken)
        } catch HTTPError.unauthorized {
            // CLI may have refreshed and rewritten the blob since launch → re-read once.
            cachedToken = nil
            let fresh = try await token(forceRefresh: false)
            if fresh.accessToken == tok.accessToken {
                // Same token really is rejected → run the refresh flow ourselves.
                let t = try await token(forceRefresh: true)
                return try await fetchUsage(accessToken: t.accessToken)
            }
            return try await fetchUsage(accessToken: fresh.accessToken)
        }
    }

    func localUsage() async -> ProviderUsage? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let util = cached["utilization"] as? [String: Any] else { return nil }
        return Self.parse(utilization: util)
    }

    // MARK: - Token handling

    private func token(forceRefresh: Bool) async throws -> (accessToken: String, refreshToken: String, expiresAt: Date?) {
        if !forceRefresh, let cachedToken, let exp = cachedToken.expiresAt, exp > Date() {
            return cachedToken
        }
        var blob = try readKeychainBlob()
        var oauth = blob["claudeAiOauth"] as? [String: Any] ?? [:]
        if !forceRefresh,
           let access = oauth["accessToken"] as? String, !access.isEmpty,
           let expStr = oauth["expiresAt"] as? String,
           let exp = ISO8601DateFormatter().date(from: expStr), exp > Date() {
            let t = (access, oauth["refreshToken"] as? String ?? "", exp)
            cachedToken = t
            return t
        }
        // Refresh flow; write the new blob back so the CLI stays in sync.
        guard let refreshTok = oauth["refreshToken"] as? String, !refreshTok.isEmpty else {
            throw HTTPError.unauthorized
        }
        var req = URLRequest(url: tokenURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshTok,
            "client_id": clientID,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw HTTPError.unauthorized
        }
        guard let new = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = new["access_token"] as? String else {
            throw HTTPError.unauthorized
        }
        oauth["accessToken"] = access
        if let rt = new["refresh_token"] as? String { oauth["refreshToken"] = rt }
        if let expIn = new["expires_in"] as? Double {
            oauth["expiresAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expIn))
        }
        blob["claudeAiOauth"] = oauth
        try keychain.write(blob: blob)
        let exp = (oauth["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let t = (access, oauth["refreshToken"] as? String ?? "", exp)
        cachedToken = t
        return t
    }

    private func readKeychainBlob() throws -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError.unauthorized
        }
        return blob
    }

    private func fetchUsage(accessToken: String) async throws -> ProviderUsage {
        let json = try await fetchJSON(usageURL, headers: [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        guard let usage = json["usage"] as? [String: Any] ?? json["utilization"] as? [String: Any] else {
            throw HTTPError.status(-2)
        }
        return Self.parse(utilization: usage)
    }

    /// Endpoint and cachedUsageUtilization share this shape (verified locally):
    /// five_hour / seven_day { utilization: int %, resets_at: ISO-8601, *_dollars? }.
    static func parse(utilization: [String: Any]) -> ProviderUsage {
        func window(_ key: String) -> UsageWindow? {
            guard let w = utilization[key] as? [String: Any],
                  let pct = UsageMath.normalizePercent(anyDouble(w["utilization"])) else { return nil }
            return UsageWindow(
                percent: pct,
                used: anyDouble(w["used_dollars"]),
                limit: anyDouble(w["limit_dollars"]),
                unit: w["limit_dollars"] != nil ? "$" : nil,
                resetsAt: (w["resets_at"] as? String).flatMap(Self.parseISO)
            )
        }
        return ProviderUsage(session: window("five_hour"), weekly: window("seven_day"))
    }

    /// resets_at carries fractional seconds ("…:59.745262+00:00") — plain
    /// ISO8601DateFormatter rejects those; try both forms.
    static func parseISO(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Any numeric JSON value (Int/Double/NSString) → Double, tolerantly.
func anyDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

/// Keychain read/write for the "Claude Code-credentials" generic-password blob.
struct Keychain {
    private let service = "Claude Code-credentials"

    func write(blob: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: blob)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        var update = base
        update[kSecValueData as String] = data
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw HTTPError.unauthorized }
    }
}
