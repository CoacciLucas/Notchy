import Foundation

/// Codex (OpenAI) — primary: GET chatgpt.com/backend-api/wham/usage with the
/// ChatGPT OAuth token from ~/.codex/auth.json. Fallback: last token_count
/// rate_limits snapshot in the newest rollout JSONL (local files, no network).
final class CodexProvider: UsageProvider {
    let info = ProviderInfo(id: "codex", name: "Codex", tintHex: "#10A37F", symbol: "circle.hexagongrid")
    let refresh: RefreshPolicy = .poll(.seconds(150))   // gentle: 2–5 min staggered band
    var watchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".codex/sessions").path,
                home.appendingPathComponent(".codex/auth.json").path]
    }

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    // Codex CLI's public OAuth client id.
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let fm = FileManager.default
    private var authPath: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json") }

    struct AuthFile: Codable {
        struct Tokens: Codable {
            var idToken: String?
            var accessToken: String?
            var refreshToken: String?
            var accountId: String?
            enum CodingKeys: String, CodingKey {
                case idToken = "id_token", accessToken = "access_token"
                case refreshToken = "refresh_token", accountId = "account_id"
            }
        }
        var tokens: Tokens?
    }

    func currentUsage() async throws -> ProviderUsage {
        var auth = try readAuth()
        do {
            return try await fetchUsage(auth: auth)
        } catch HTTPError.unauthorized {
            // Refresh once (rotating refresh token written back immediately so
            // the Codex CLI keeps working), then retry.
            auth = try await refresh(auth: auth)
            return try await fetchUsage(auth: auth)
        }
    }

    func localUsage() async -> ProviderUsage? {
        guard let snapshot = latestRolloutRateLimits() else { return nil }
        return Self.parse(rateLimits: snapshot)
    }

    // MARK: - Auth

    private func readAuth() throws -> AuthFile.Tokens {
        let data = try Data(contentsOf: authPath)
        return (try JSONDecoder().decode(AuthFile.self, from: data)).tokens
            ?? AuthFile.Tokens()
    }

    private func writeAuth(_ tokens: AuthFile.Tokens) throws {
        // Read-modify-write the whole file so foreign keys survive.
        let url = authPath
        guard var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else {
            throw HTTPError.unauthorized
        }
        var t = (root["tokens"] as? [String: Any]) ?? [:]
        if let v = tokens.accessToken { t["access_token"] = v }
        if let v = tokens.refreshToken { t["refresh_token"] = v }
        if let v = tokens.idToken { t["id_token"] = v }
        if let v = tokens.accountId { t["account_id"] = v }
        root["tokens"] = t
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)
    }

    private func refresh(auth: AuthFile.Tokens) async throws -> AuthFile.Tokens {
        guard let rt = auth.refreshToken, !rt.isEmpty else { throw HTTPError.unauthorized }
        var req = URLRequest(url: tokenURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": rt,
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
        var tokens = auth
        tokens.accessToken = access
        tokens.refreshToken = new["refresh_token"] as? String ?? tokens.refreshToken
        tokens.idToken = new["id_token"] as? String ?? tokens.idToken
        try writeAuth(tokens)
        return tokens
    }

    private func fetchUsage(auth: AuthFile.Tokens) async throws -> ProviderUsage {
        guard let access = auth.accessToken else { throw HTTPError.unauthorized }
        var headers = [
            "Authorization": "Bearer \(access)",
            "OpenAI-Beta": "codex-1",
        ]
        if let acct = auth.accountId { headers["ChatGPT-Account-Id"] = acct }
        let json = try await fetchJSON(usageURL, headers: headers)
        // wham/usage nests under "rate_limits" (or "usage.rate_limits" on some builds).
        let limits = (json["rate_limits"] as? [String: Any])
            ?? ((json["usage"] as? [String: Any])?["rate_limits"] as? [String: Any])
        guard let limits else { throw HTTPError.status(-2) }
        return Self.parse(rateLimits: limits)
    }

    /// rate_limits carries primary/secondary (and sometimes more) windows.
    /// Classify strictly by duration — never by label or order (§1.2).
    static func parse(rateLimits: [String: Any]) -> ProviderUsage {
        var session: UsageWindow?
        var weekly: UsageWindow?
        for (_, value) in rateLimits {
            guard let w = value as? [String: Any] else { continue }
            let minutes = anyDouble(w["window_minutes"])
                ?? (anyDouble(w["limit_window_seconds"]) ?? 0) / 60
            guard let kind = UsageMath.codexWindowKind(seconds: Int(minutes * 60)),
                  let used = anyDouble(w["used_percent"]) else { continue }
            let win = UsageWindow(
                percent: UsageMath.normalizePercent(used) ?? 0,
                used: nil, limit: nil, unit: nil,
                resetsAt: anyDouble(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            )
            switch kind {
            case .session where session == nil: session = win
            case .weekly where weekly == nil: weekly = win
            default: break
            }
        }
        return ProviderUsage(session: session, weekly: weekly)
    }

    // MARK: - Rollout JSONL fallback

    /// Scan ~/.codex/sessions for the newest rollout file carrying a token_count
    /// rate_limits snapshot, newest-first. ponytail: scans the tree tail first;
    /// switch to an mtime-sorted reverse walk if the tree grows huge.
    private func latestRolloutRateLimits() -> [String: Any]? {
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let files = (enumerator.allObjects as? [URL])?
            .filter { $0.pathExtension == "jsonl" } ?? []
        let sorted = files.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }
        for file in sorted {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let limits = evt["rate_limits"] as? [String: Any] else { continue }
                return limits
            }
        }
        return nil
    }
}
