import Foundation

/// One usage window (5-hour session or weekly), percent-first — endpoints natively
/// report percent; absolutes are optional bonuses (e.g. Claude dollars).
struct UsageWindow: Codable, Equatable {
    var percent: Double        // 0…1, always present
    var used: Double?          // absolutes when the source has them
    var limit: Double?
    var unit: String?          // "$", "prompts", …
    var resetsAt: Date?        // nil = unknown → UI hides the countdown
}

struct ProviderUsage: Codable, Equatable {
    var session: UsageWindow?  // 5-hour window — drives the ring
    var weekly: UsageWindow?   // weekly window — popover only
}

struct ProviderInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let tintHex: String        // brand tint, e.g. "#D97757"
    let symbol: String         // brand logo: Resources/<symbol>.svg
}

enum LoadState: Equatable {
    case ok
    case stale(since: Date)
    case noData(reason: String)
}

struct ProviderSnapshot: Identifiable {
    var info: ProviderInfo
    var usage: ProviderUsage?
    var state: LoadState = .noData(reason: "not fetched yet")

    var id: String { info.id }

    /// What the ring shows: the 5-hour session percent, falling back to the
    /// weekly percent with a visible `wk` marker when no session window exists.
    var ringWindow: (window: UsageWindow?, isWeeklyFallback: Bool) {
        if let s = usage?.session { return (s, false) }
        if let w = usage?.weekly { return (w, true) }
        return (nil, false)
    }
}

// MARK: - Pure formatting / normalization (unit-tested)

enum UsageMath {
    /// Clamp any integer/float percent from an endpoint into 0…1. Negative or
    /// garbage values fail soft to nil.
    static func normalizePercent(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return min(max(raw / 100.0, 0), 1)
    }

    /// Codex: classify windows by duration — never by primary/secondary label
    /// or array order. 18000 s = 5 h session, 604800 s = weekly.
    static func codexWindowKind(seconds: Int) -> WindowKind? {
        switch seconds {
        case 17_000...19_000: return .session
        case 600_000...6_100_000: return .weekly  // Loose band around 604800 for clock-drifty values
        default: return nil
        }
    }

    /// GLM: classify by unit+number — never array order. unit=3,number=5 → 5 h;
    /// unit=6,number=1 → weekly.
    static func glmWindowKind(unit: Int, number: Int) -> WindowKind? {
        if unit == 3 && number == 5 { return .session }
        if unit == 6 && number == 1 { return .weekly }
        return nil
    }

    /// "< 1 h → 51 min", "< 24 h → 5 h 12 min", else "2 d 4 h".
    static func countdown(until date: Date, from now: Date = Date()) -> String? {
        let secs = date.timeIntervalSince(now)
        guard secs > 0 else { return nil }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h == 0 { return "\(m) min" }
        if h < 24 { return "\(h) h \(m) min" }
        return "\(h / 24) d \(h % 24) h"
    }

    /// Ring label: "73%", "38% wk", "100%+", "–".
    static func ringLabel(percent: Double?, isWeeklyFallback: Bool, hasData: Bool) -> String {
        guard hasData, let percent else { return "–" }
        let suffix = isWeeklyFallback ? " wk" : ""
        if percent >= 1 { return "100%+\(suffix)" }
        return "\(Int((percent * 100).rounded()))%\(suffix)"
    }
}

enum WindowKind {
    case session, weekly
}
