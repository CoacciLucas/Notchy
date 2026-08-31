import SwiftUI
import XCTest
@testable import Notchy

final class UsageMathTests: XCTestCase {

    // MARK: - Percent normalization

    func testNormalizeClamps() {
        XCTAssertEqual(UsageMath.normalizePercent(73), 0.73)
        XCTAssertEqual(UsageMath.normalizePercent(0), 0)
        XCTAssertEqual(UsageMath.normalizePercent(150), 1)
        XCTAssertNil(UsageMath.normalizePercent(nil))
        XCTAssertNil(UsageMath.normalizePercent(-5))
        XCTAssertNil(UsageMath.normalizePercent(.nan))
        XCTAssertNil(UsageMath.normalizePercent(.infinity))
    }

    // MARK: - Window classification

    func testCodexClassificationByDuration() {
        XCTAssertEqual(UsageMath.codexWindowKind(seconds: 18_000), .session)
        XCTAssertEqual(UsageMath.codexWindowKind(seconds: 604_800), .weekly)
        XCTAssertNil(UsageMath.codexWindowKind(seconds: 123_456))
        // Never by label: a "secondary" 300-min window is still the session window.
        let parsed = CodexProvider.parse(rateLimits: [
            "secondary": ["used_percent": 16.0, "window_minutes": 10_080, "resets_at": 1_782_392_959.0],
            "primary": ["used_percent": 0.0, "window_minutes": 300, "resets_at": 1_782_170_151.0],
        ])
        XCTAssertEqual(parsed.session?.percent, 0)
        XCTAssertEqual(parsed.weekly?.percent, 0.16)
    }

    func testGLMClassificationByUnitNumber() {
        // Never by array order: weekly entry listed FIRST must still classify as weekly.
        let parsed = GLMProvider.parse(limits: [
            ["unit": 6, "number": 1, "percentage": 31, "nextResetTime": 1_787_000_000_000.0],
            ["unit": 3, "number": 5, "percentage": 62, "nextResetTime": 1_786_000_000_000.0],
            ["unit": 1, "number": 2, "percentage": 50, "nextResetTime": 1_789_000_000_000.0],  // monthly MCP pool — ignored
        ])
        XCTAssertEqual(parsed.session?.percent, 0.62)
        XCTAssertEqual(parsed.weekly?.percent, 0.31)
        XCTAssertEqual(parsed.session?.resetsAt, Date(timeIntervalSince1970: 1_786_000_000))
    }

    func testClaudeParseTolerant() {
        let usage = ClaudeProvider.parse(utilization: [
            "five_hour": ["utilization": 100, "resets_at": "2026-08-28T00:59:59.745262+00:00"],
            "seven_day": ["utilization": 21, "resets_at": "2026-09-02T19:59:59.745290+00:00"],
            "tangelo": NSNull(),   // unknown internal-codename keys must not break parsing
        ])
        XCTAssertEqual(usage.session?.percent, 1)
        XCTAssertEqual(usage.weekly?.percent, 0.21)
        XCTAssertEqual(usage.session?.resetsAt?.timeIntervalSince1970 ?? 0,
                       ISO8601DateFormatter().date(from: "2026-08-28T00:59:59Z")!.timeIntervalSince1970,
                       accuracy: 1)
        // Fractional-seconds timestamps (live endpoint format) must parse too.
        XCTAssertNotNil(ClaudeProvider.parseISO("2026-08-28T00:59:59.745262+00:00"))
        XCTAssertNotNil(ClaudeProvider.parseISO("2026-08-28T00:59:59Z"))
        XCTAssertNil(ClaudeProvider.parseISO("not a date"))
    }

    func testClaudeUnwrapShapes() {
        let windows: [String: Any] = ["five_hour": ["utilization": 52.0], "seven_day": ["utilization": 29.0]]
        // Live endpoint: windows at the top level.
        XCTAssertEqual(ClaudeProvider.parse(utilization: ClaudeProvider.unwrap(windows)!).session?.percent, 0.52)
        // Cached file / older endpoint shapes: nested.
        XCTAssertEqual(ClaudeProvider.parse(utilization: ClaudeProvider.unwrap(["utilization": windows])!).weekly?.percent, 0.29)
        XCTAssertEqual(ClaudeProvider.parse(utilization: ClaudeProvider.unwrap(["usage": windows])!).weekly?.percent, 0.29)
        XCTAssertNil(ClaudeProvider.unwrap(["error": "nope"]))
    }

    // MARK: - Countdown formatting

    func testCountdownFormatting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UsageMath.countdown(until: now.addingTimeInterval(51 * 60), from: now), "51 min")
        XCTAssertEqual(UsageMath.countdown(until: now.addingTimeInterval(5 * 3600 + 12 * 60), from: now), "5 h 12 min")
        XCTAssertEqual(UsageMath.countdown(until: now.addingTimeInterval((2 * 24 + 4) * 3600), from: now), "2 d 4 h")
        XCTAssertNil(UsageMath.countdown(until: now.addingTimeInterval(-1), from: now))
    }

    // MARK: - Ring states

    func testRingLabels() {
        XCTAssertEqual(UsageMath.ringLabel(percent: 0.73, isWeeklyFallback: false, hasData: true), "73%")
        XCTAssertEqual(UsageMath.ringLabel(percent: 0.38, isWeeklyFallback: true, hasData: true), "38% wk")
        XCTAssertEqual(UsageMath.ringLabel(percent: 1.2, isWeeklyFallback: false, hasData: true), "100%+")
        XCTAssertEqual(UsageMath.ringLabel(percent: 1.2, isWeeklyFallback: true, hasData: true), "100%+ wk")
        XCTAssertEqual(UsageMath.ringLabel(percent: nil, isWeeklyFallback: false, hasData: true), "–")
        XCTAssertEqual(UsageMath.ringLabel(percent: 0.5, isWeeklyFallback: false, hasData: false), "–")
    }

    func testRingWindowFallback() {
        var snap = ProviderSnapshot(
            info: ProviderInfo(id: "x", name: "X", tintHex: "#FFFFFF", symbol: "circle"),
            usage: ProviderUsage(session: nil, weekly: UsageWindow(percent: 0.5)))
        XCTAssertTrue(snap.ringWindow.isWeeklyFallback)
        XCTAssertEqual(snap.ringWindow.window?.percent, 0.5)
        snap.usage = ProviderUsage(session: UsageWindow(percent: 0.2), weekly: nil)
        XCTAssertFalse(snap.ringWindow.isWeeklyFallback)
        snap.usage = nil
        XCTAssertNil(snap.ringWindow.window)
    }

    func testColorHex() {
        XCTAssertNotNil(Color(hex: "#D97757"))
        XCTAssertNil(Color(hex: "nope"))
        XCTAssertNotNil(Color(hex: "#FF0000"))
    }
}
