import Foundation
import Security

/// Claude (Anthropic) — primary: GET api.anthropic.com/api/oauth/usage with the
/// Claude Code OAuth token from Keychain item "Claude Code-credentials".
/// Fallback: ~/.claude.json → cachedUsageUtilization (refreshed by the CLI).
final class ClaudeProvider: UsageProvider {
    let info = ProviderInfo(id: "claude", name: "Claude", tintHex: "#D97757", symbol: "asterisk")
    let refresh: RefreshPolicy = .poll(.seconds(300))   // ≥ 5 min — endpoint 429s aggressively
    var watchPaths: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path]
    }

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // In-memory token cache: one Keychain read per launch (read-prompt loops, §1.1).
    private var cachedToken: (accessToken: String, expiresAt: Date?)?

    func currentUsage() async throws -> ProviderUsage {
        let tok = try await token()
        do {
            return try await fetchUsage(accessToken: tok.accessToken)
        } catch HTTPError.unauthorized {
            // The CLI refreshes and rewrites the Keychain blob as the user uses
            // Claude Code — re-read it once before giving up.
            // NEVER run the OAuth refresh flow ourselves: writing the secret
            // from this unsigned binary rewrites the item's ACL and makes the
            // CLI prompt for the login password on every token read.
            cachedToken = nil
            let fresh = try await token()
            guard fresh.accessToken != tok.accessToken else {
                throw HTTPError.unauthorized   // → .noData with re-auth guidance
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
              let util = Self.unwrap(cached) else { return nil }
        return Self.parse(utilization: util)
    }

    // MARK: - Token handling

    /// Read the token the CLI maintains. Read-only — this app never writes the
    /// Keychain item (a write from an unsigned binary rewrites its ACL and
    /// makes the CLI prompt for the login password on every token read).
    /// An expired token is still returned: the usage endpoint decides if it
    /// works, and a 401 falls back to one re-read (the CLI may have refreshed).
    private func token() throws -> (accessToken: String, expiresAt: Date?) {
        if let cachedToken { return cachedToken }
        let blob = try readKeychainBlob()
        let oauth = blob["claudeAiOauth"] as? [String: Any] ?? [:]
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else {
            throw HTTPError.unauthorized
        }
        let exp = (oauth["expiresAt"] as? String).flatMap(Self.parseISO)
        let t = (access, exp)
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
        guard let usage = Self.unwrap(json) else { throw HTTPError.status(-2) }
        return Self.parse(utilization: usage)
    }

    /// The endpoint returns the windows at the top level; the cached file nests
    /// them under "utilization" (and an older endpoint shape used "usage").
    static func unwrap(_ json: [String: Any]) -> [String: Any]? {
        for candidate in [json["usage"] as? [String: Any], json["utilization"] as? [String: Any], json] {
            if let c = candidate, c["five_hour"] != nil || c["seven_day"] != nil { return c }
        }
        return nil
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
