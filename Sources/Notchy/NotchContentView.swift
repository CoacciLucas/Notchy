import SwiftUI

/// Geometry shared by the SwiftUI drawing, the AppKit hit-test and the popover
/// placement — one source of truth so the clickable region, the painted tab and
/// the arrow always agree.
enum NotchMetrics {
    static let expandedWidth: CGFloat = 44
    static let collapsedWidth: CGFloat = 14
    static let slotHeight: CGFloat = 56
    static let collapsedSlot: CGFloat = 15

    /// Vertical run of the corner S-curve. Matching it to the width is what
    /// makes the tab read as cut into the display instead of a pill sitting on
    /// top of it — shorten it and the corners collapse into a rounded rect.
    static func flare(width: CGFloat) -> CGFloat { width }

    static func expandedSize(_ count: Int) -> CGSize {
        CGSize(width: expandedWidth,
               height: CGFloat(count) * slotHeight + flare(width: expandedWidth) * 2)
    }

    static func collapsedSize(_ count: Int) -> CGSize {
        CGSize(width: collapsedWidth,
               height: CGFloat(count) * collapsedSlot + flare(width: collapsedWidth) * 2)
    }
}

/// The tab's currently drawn size. The panel is always expanded-sized (its
/// frame can't animate per-frame with SwiftUI), so the hit-test has to be told
/// which shape is actually on screen — otherwise the collapsed sliver would
/// still eat clicks across the whole expanded rectangle.
final class NotchState: ObservableObject {
    var visibleSize: CGSize = .zero
}

/// Trailing edge flush against the screen, an S-curve at each end flaring out
/// to that edge. Vertically symmetric, so the same path works in SwiftUI's
/// y-down space and AppKit's y-up one.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path { Path(Self.cgPath(in: rect)) }

    static func cgPath(in rect: CGRect) -> CGPath {
        let f = min(NotchMetrics.flare(width: rect.width), rect.height / 2)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + f),               // tangent to the screen edge
                   control1: CGPoint(x: rect.maxX, y: rect.minY + f * 0.55),   // at one end and to the
                   control2: CGPoint(x: rect.minX, y: rect.minY + f * 0.45))   // leading edge at the other
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - f))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                   control1: CGPoint(x: rect.minX, y: rect.maxY - f * 0.45),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - f * 0.55))
        p.closeSubpath()
        return p
    }
}

/// Collapsed to a sliver of tinted dots; hovering grows it into the full
/// island of rings (NotchNook-style), and it stays open while a popover shows.
struct NotchContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var notch: NotchState
    @StateObject private var popover = PopoverController()
    @State private var hovering = false

    /// Popover open ⇒ stay expanded: otherwise moving the mouse into the
    /// popover collapses the island out from under its own arrow.
    private var expanded: Bool { hovering || popover.visibleProviderID != nil }

    private var size: CGSize {
        let n = max(store.snapshots.count, 1)
        return expanded ? NotchMetrics.expandedSize(n) : NotchMetrics.collapsedSize(n)
    }

    var body: some View {
        ZStack {
            collapsedTab.opacity(expanded ? 0 : 1)
            expandedTab.opacity(expanded ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(NotchShape())
        .overlay(NotchShape().stroke(Color.white.opacity(0.07), lineWidth: 1))
        .contentShape(NotchShape())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onChange(of: size, initial: true) { notch.visibleSize = $1 }
        .onAppear { popover.store = store }
        .environmentObject(popover)
    }

    private var expandedTab: some View {
        VStack(spacing: 0) {
            ForEach(store.snapshots) { snap in
                ProviderSlotView(snapshot: snap)
                    .onHover { popover.hover(snap.id, $0) }
                    .onTapGesture { popover.click(snap.id) }
            }
        }
    }

    private var collapsedTab: some View {
        VStack(spacing: 0) {
            ForEach(store.snapshots) { snap in
                Circle()
                    .fill(dotColor(snap))
                    .frame(width: 6, height: 6)
                    .frame(height: NotchMetrics.collapsedSlot)
                    .accessibilityLabel(snap.info.name)
            }
        }
    }

    private func dotColor(_ snap: ProviderSnapshot) -> Color {
        guard let window = snap.ringWindow.window else { return .white.opacity(0.25) }
        return window.percent >= 1 ? .red : (Color(hex: snap.info.tintHex) ?? .white)
    }
}
