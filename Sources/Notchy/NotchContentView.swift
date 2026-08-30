import SwiftUI

/// Phase A shell: the jet-black tab flush against the right screen edge, with
/// one provider slot per provider stacked vertically.
struct NotchContentView: View {
    @EnvironmentObject var store: UsageStore
    @StateObject private var popover = PopoverController()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.snapshots) { snap in
                ProviderSlotView(snapshot: snap)
                    .onHover { hovering in popover.hover(snap.id, hovering) }
                    .onTapGesture { popover.click(snap.id) }
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Color.clear.preference(key: SlotFrameKey.self,
                                                   value: [snap.id: geo.frame(in: .global)])
                        }
                    }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tabShape)
        .overlay(alignment: .leading) { hairline }
        .onPreferenceChange(SlotFrameKey.self) { popover.slotFrames = $0 }
        .onAppear { popover.store = store }
        .environmentObject(popover)
    }

    /// Leading corners 18 pt continuous curvature; trailing edge flush against
    /// the screen edge — reads as a notch cut into the display.
    private var tabShape: some View {
        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
            .fill(Color.black)
    }

    /// 1 pt hairline on the leading side only — definition on dark wallpapers.
    private var hairline: some View {
        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18)
            .stroke(Color.white.opacity(0.06), lineWidth: 1)
            .mask(
                HStack(spacing: 0) {
                    Rectangle().frame(width: 18)   // leading band only
                    Color.clear
                }
            )
    }
}

/// Publishes each slot's global frame so the popover panel can position its
/// arrow against the right slot.
struct SlotFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
