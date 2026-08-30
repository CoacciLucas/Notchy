import AppKit
import SwiftUI

/// Owns the custom popover panel: hover-open (250 ms dwell), click-to-pin,
/// mouse-leave close (400 ms grace), click-outside close (global + local
/// monitors — global monitors never deliver events consumed by your own app),
/// Esc-to-close while pinned (panel takes key WITHOUT activating the app).
@MainActor
final class PopoverController: ObservableObject {
    @Published var visibleProviderID: String?
    @Published var pinned = false
    weak var store: UsageStore?

    private var panel: PopoverPanel?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var monitors: [Any] = []

    func hover(_ id: String, _ hovering: Bool) {
        if hovering {
            closeTask?.cancel()
            guard !pinned, visibleProviderID != id else { return }
            openTask?.cancel()
            openTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                show(id: id, pinned: false)
            }
        } else {
            openTask?.cancel()
            guard !pinned, visibleProviderID != nil else { return }
            closeTask?.cancel()
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                close()
            }
        }
    }

    /// Hover over the popover body itself: part of the spec'd popover+slot
    /// region — cancels the pending close; leaving schedules it (unpinned only).
    func popoverHover(_ hovering: Bool) {
        if hovering {
            closeTask?.cancel()
        } else if !pinned, visibleProviderID != nil {
            closeTask?.cancel()
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                close()
            }
        }
    }

    func click(_ id: String) {
        if pinned && visibleProviderID == id {
            close()
        } else {
            show(id: id, pinned: true)
        }
    }

    private func show(id: String, pinned: Bool) {
        let panel = self.panel ?? {
            let p = PopoverPanel()
            self.panel = p
            p.controller = self
            installMonitors()
            return p
        }()
        guard let notch = notchPanel, let store,
              let index = store.snapshots.firstIndex(where: { $0.id == id }) else { return }

        let content = DetailPopoverView(providerID: id)
            .environmentObject(store)
            .environmentObject(self)
            .onHover { hovering in self.popoverHover(hovering) }
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize   // width is fixed by the view; height fits the content

        // Slot centres are pure geometry (NotchMetrics) — no need to round-trip
        // frames back out of SwiftUI, and it stays right mid-animation.
        let flare = NotchMetrics.flare(width: NotchMetrics.expandedWidth)
        let slotMidY = notch.frame.maxY - flare - (CGFloat(index) + 0.5) * NotchMetrics.slotHeight
        let x = notch.frame.maxX - NotchMetrics.expandedWidth - 4 - size.width
        let y = slotMidY - size.height / 2
        // Clamp to the screen vertically; the notch is at the right edge so x is fine.
        let screen = NSScreen.screens.first?.frame ?? .zero
        let clampedY = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: clampedY), size: size), display: false)
        panel.contentView = host

        visibleProviderID = id
        self.pinned = pinned
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        if pinned {
            // .nonactivatingPanel takes key without activating the app — the
            // user's editor keeps focus, but Esc reaches performKeyEquivalent.
            panel.makeKey()
        } else {
            panel.resignKey()
        }
    }

    private var notchPanel: NotchPanel? {
        NSApp.windows.first { $0 is NotchPanel } as? NotchPanel
    }

    private var isOpen: Bool { visibleProviderID != nil }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        pinned = false
        visibleProviderID = nil
        if let panel, isOpen || panel.alphaValue > 0 {
            panel.resignKey()
            // Never orderOut while fullscreen apps are active (drops all-Spaces
            // membership — claude-notch-tracker #2–4); retract with alpha-0
            // and stop intercepting clicks.
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }
        }
    }

    private func installMonitors() {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfOutside() }
        } ?? ())
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.closeIfOutside() }
            return event
        } ?? ())
    }

    private func closeIfOutside() {
        guard isOpen, let panel else { return }
        let mouse = NSEvent.mouseLocation
        // Clicks on the notch itself are handled by the slot's own handlers.
        if !panel.frame.contains(mouse) {
            let notchFrame = notchPanel?.frame ?? .zero
            if !notchFrame.contains(mouse) { close() }
        }
    }
}

/// Custom borderless popover panel (NSPopover has no arrow-direction API on
/// macOS and its placement fallback is "not guaranteed" — PLAN §3 Phase C).
final class PopoverPanel: NSPanel {
    weak var controller: PopoverController?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 230),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Own collectionBehavior set — child windows don't inherit it, and the
        // popover must not lag on Space switches/fullscreen.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        // Starts retracted (alpha-0, click-through); never orderOut — see close().
        alphaValue = 0
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {   // Esc
            Task { @MainActor in controller?.close() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Popover content: name, session bar, weekly bar, reset countdowns (§3 Phase C).
struct DetailPopoverView: View {
    let providerID: String
    @EnvironmentObject var store: UsageStore

    private static let bubbleWidth: CGFloat = 250
    private static let beakWidth: CGFloat = 9

    var body: some View {
        TimelineView(.everyMinute) { _ in
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(width: Self.bubbleWidth, alignment: .topLeading)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1))
                .overlay(alignment: .trailing) {
                    // Beak pointing right, at the slot icon.
                    ArrowShape()
                        .fill(Color.black)
                        .frame(width: Self.beakWidth, height: 32)
                        .offset(x: Self.beakWidth - 0.5)
                        .accessibilityHidden(true)
                }
                .padding(.trailing, Self.beakWidth)   // the beak lives in this gutter
        }
    }

    private var content: some View {
        Group {
            if let snap = store.snapshots.first(where: { $0.info.id == providerID }) {
                VStack(alignment: .leading, spacing: 12) {
                    header(snap)
                    windowBlock(title: "Current session", window: snap.usage?.session,
                                missingText: "No 5-hour limit published", tint: tint(snap))
                    windowBlock(title: "Weekly limit", window: snap.usage?.weekly,
                                missingText: "No weekly limit published", tint: tint(snap))
                    if let warning = warningText(snap) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    HStack {
                        Spacer()
                        // The only way to quit an LSUIElement app — without
                        // this there's no Dock icon or menu to quit from.
                        Button("Quit Notchy") { NSApp.terminate(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            } else {
                Text("No data").foregroundStyle(.white)
            }
        }
    }

    private func header(_ snap: ProviderSnapshot) -> some View {
        HStack(spacing: 7) {
            Image(systemName: snap.info.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Text("\(snap.info.name) Usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func windowBlock(title: String, window: UsageWindow?, missingText: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(.white)
                Spacer(minLength: 0)
                if let reset = window?.resetsAt {
                    Text(resetText(reset))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
            if let window {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(window.percent >= 1 ? Color.red : tint)
                            .frame(width: max(5, geo.size.width * window.percent))
                    }
                }
                .frame(height: 5)
                Text(usedText(window))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text(missingText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .animation(.easeOut(duration: 0.3), value: window?.percent)
    }

    private func usedText(_ window: UsageWindow) -> String {
        let pct = "\(Int((window.percent * 100).rounded()))% Used"
        guard let used = window.used, let limit = window.limit, let unit = window.unit else { return pct }
        return pct + String(format: "  ·  %@%.2f / %@%.0f", unit, used, unit, limit)
    }

    private func resetText(_ reset: Date) -> String {
        // Beyond a day a countdown is useless — name the day, like the menu bar clock.
        if reset.timeIntervalSinceNow > 24 * 3600 {
            return "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        if let left = UsageMath.countdown(until: reset) { return "Resets in \(left)" }
        return "Resetting…"   // deadline passed; refresh fires via UsageStore
    }

    private func warningText(_ snap: ProviderSnapshot) -> String? {
        switch snap.state {
        case .noData(let reason): return "No data — \(reason)"
        case .stale: return "Showing last known values"
        case .ok: return nil
        }
    }

    private func tint(_ snap: ProviderSnapshot) -> Color {
        Color(hex: snap.info.tintHex) ?? .white
    }
}

struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                       control: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.22))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                       control: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.22))
        p.closeSubpath()
        return p
    }
}
