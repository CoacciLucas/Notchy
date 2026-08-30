import AppKit
import SwiftUI

/// The side-notch overlay panel. Property recipe verified against the macOS 26
/// SDK and boring.notch's shipped configuration (PLAN §2.2).
final class NotchPanel: NSPanel {
    init(contentSize: CGSize) {
        // styleMask at init — changing it later doesn't update WindowServer's
        // activation tag (FB16484811).
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        // Hover has to work while another app is frontmost — this is what keeps
        // mouse-moved events flowing to a non-activating panel.
        acceptsMouseMovedEvents = true
    }

    // Never key/main: a key non-activating panel steals keystrokes from
    // the user's editor.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Positioning (right edge, near the top-right corner)

    /// Gap between the bottom of the menu bar and the top of the *expanded*
    /// island. The panel is always expanded-sized and the tab is centered in
    /// it, so this is measured against the panel frame, not the drawn sliver —
    /// that keeps the island's top edge parked at the same place whether it's
    /// collapsed or open, and it grows symmetrically from there on hover.
    static let topGap: CGFloat = 98

    func positionOnScreen() {
        // NSScreen.main is key-window-based and nullable — unreliable for an
        // accessory app. screens.first is the "zero" screen.
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = frame.size
        let x = screen.frame.maxX - size.width

        // visibleFrame.maxY sits just under the menu bar (and under the notch
        // safe area on notched displays), so the gap reads the same on every Mac.
        let top = screen.visibleFrame.maxY - Self.topGap
        // Never let it run off the bottom on short screens.
        let y = max(screen.frame.minY + 8, top - size.height)

        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func observeScreenChanges() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.positionOnScreen()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.positionOnScreen()
        }
    }
}

/// Click-through outside the drawn tab: returns nil so events fall through to
/// whatever is behind. (Never set ignoresMouseEvents — kills per-pixel
/// pass-through entirely.) The panel stays expanded-sized at all times, so the
/// live tab size comes from NotchState.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var state: NotchState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let size = state?.visibleSize, size.width > 0 else { return nil }
        // Tab is trailing-aligned and vertically centered; NotchShape is
        // symmetric, so AppKit's y-up bounds need no flip.
        let rect = CGRect(x: bounds.maxX - size.width, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        return NotchShape.cgPath(in: rect).contains(point) ? super.hitTest(point) : nil
    }
}
