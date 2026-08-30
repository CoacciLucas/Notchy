import Foundation

/// GLM (Z.AI coding plan, consumed via opencode) — primary:
/// GET api.z.ai/api/monitor/usage/quota/limit with the opencode API key.
/// Percentage-only (no absolute credits) — approved display (§4.4 Q10).
final class GLMProvider: UsageProvider {
    let info = ProviderInfo(id: "glm", name: "GLM", tintHex: "#2E66FF", symbol: "bolt")
    let refresh: RefreshPolicy = .poll(.seconds(150))
    var watchPaths: [String] { [keyPath.path] }   // credential change → next local read picks it up

    private let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    private var cachedKey: String?
    private let keyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")

    func currentUsage() async throws -> ProviderUsage {
        guard let key = try readKey() else { throw HTTPError.unauthorized }
        let json = try await fetchJSON(quotaURL, headers: ["Authorization": "Bearer \(key)"])
        let data = json["data"] as? [String: Any] ?? json
        guard let limits = data["limits"] as? [[String: Any]] else { throw HTTPError.status(-2) }
        return Self.parse(limits: limits)
    }

    /// MVP has no local fallback for GLM (opencode.db credit math is post-MVP,
    /// approximate, and glm-5.1 has no published multipliers — §1.3).
    func localUsage() async -> ProviderUsage? { nil }

    private func readKey() throws -> String? {
        if let cachedKey { return cachedKey }
        // ponytail: no negative cache — re-reads a tiny file per poll (~2.5 min),
        // so a key added after launch gets picked up without a relaunch
        guard let data = try? Data(contentsOf: keyPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["zai-coding-plan"] as? [String: Any],
              let key = entry["key"] as? String else { return nil }
        cachedKey = key
        return key
    }

    /// limits[] entries: {unit, number, percentage (int %), nextResetTime (unix ms)}.
    /// Classify strictly by unit+number — never array order (§1.3).
    static func parse(limits: [[String: Any]]) -> ProviderUsage {
        var session: UsageWindow?
        var weekly: UsageWindow?
        for entry in limits {
            guard let unit = anyDouble(entry["unit"]).map(Int.init),
                  let number = anyDouble(entry["number"]).map(Int.init),
                  let kind = UsageMath.glmWindowKind(unit: unit, number: number) else { continue }
            let win = UsageWindow(
                percent: UsageMath.normalizePercent(anyDouble(entry["percentage"])) ?? 0,
                used: nil, limit: nil, unit: nil,
                resetsAt: anyDouble(entry["nextResetTime"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            )
            switch kind {
            case .session where session == nil: session = win
            case .weekly where weekly == nil: weekly = win
            default: break
            }
        }
        return ProviderUsage(session: session, weekly: weekly)
    }
}
