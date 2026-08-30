import SwiftUI

/// One 56 pt provider indicator: brand-tinted progress ring around the icon,
/// percentage label below. Ring shows the 5-hour session percent, falling back
/// to weekly with a visible `wk` marker (PLAN §3 Phase B).
struct ProviderSlotView: View {
    let snapshot: ProviderSnapshot

    private var tint: Color {
        Color(hex: snapshot.info.tintHex) ?? .white
    }

    var body: some View {
        let (window, isWeekly) = snapshot.ringWindow
        let hasData = window != nil
        let pct = window?.percent ?? 0
        let arcColor = pct >= 1 ? Color.red : tint
        let dimmed: Bool = {
            if case .stale = snapshot.state { return true }
            if case .noData = snapshot.state { return false }   // "–" state renders at full opacity
            return false
        }()

        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 3.5)
                    .accessibilityHidden(true)
                Circle()
                    .trim(from: 0, to: max(pct, hasData ? 0.005 : 0))
                    .stroke(arcColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // from 12 o'clock, clockwise
                    .accessibilityHidden(true)
                    .animation(.easeOut(duration: 0.3), value: pct)
                Image(systemName: snapshot.info.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            Text(UsageMath.ringLabel(percent: pct, isWeeklyFallback: isWeekly, hasData: hasData))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 56)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.info.name)
        .accessibilityValue(accessibilityValue(window: window, isWeekly: isWeekly))
    }

    private func accessibilityValue(window: UsageWindow?, isWeekly: Bool) -> String {
        guard let window else { return "no data" }
        let which = isWeekly ? "weekly limit" : "5-hour limit"
        var out = "\(Int((window.percent * 100).rounded()))% of \(which)"
        if let reset = window.resetsAt, let left = UsageMath.countdown(until: reset) {
            out += ", resets in \(left)"
        }
        return out
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 8 { s = String(s.prefix(6)) }   // ignore alpha
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
