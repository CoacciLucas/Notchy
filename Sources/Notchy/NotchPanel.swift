import AppKit
import SwiftUI

/// The side-notch overlay panel. Property recipe verified against the macOS 26
/// SDK and boring.notch's shipped configuration (PLAN §2.2).
final class NotchPanel: NSPanel {
    init(contentSize: NSSize) {
        // styleMask at init — changing it later doesn't update WindowServer's
        // activation tag (FB16484811).
        super.init(contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
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
    }

    // Never key/main: a key non-activating panel steals keystrokes from
    // the user's editor.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Positioning (right edge of the zero screen, vertically centered)

    static func notchSize(providerCount: Int) -> NSSize {
        NSSize(width: 36, height: CGFloat(providerCount) * 56 + 16)
    }

    func positionOnScreen() {
        // NSScreen.main is key-window-based and nullable — unreliable for an
        // accessory app. screens.first is the "zero" screen.
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = frame.size
        let x = screen.frame.maxX - size.width
        let y = screen.frame.midY - size.height / 2
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

/// Click-through outside the notch shape: returns nil so events fall through
/// to whatever is behind. (Never set ignoresMouseEvents — kills per-pixel
/// pass-through entirely.)
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return Self.tabHitPath(in: bounds).contains(point) ? super.hitTest(point) : nil
    }

    /// Match the drawn tab: 18 pt radius on the leading (screen-facing) corners
    /// only, flat trailing edge flush against the screen edge.
    static func tabHitPath(in rect: CGRect) -> NSBezierPath {
        let r: CGFloat = 18
        let p = NSBezierPath()
        p.move(to: NSPoint(x: rect.maxX, y: rect.minY))                       // trailing bottom
        p.line(to: NSPoint(x: rect.minX + r, y: rect.minY))                   // bottom edge
        p.appendArc(from: NSPoint(x: rect.minX + r, y: rect.minY),
                    to: NSPoint(x: rect.minX, y: rect.minY + r), radius: r)   // bottom-leading
        p.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))                   // leading edge
        p.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY - r),
                    to: NSPoint(x: rect.minX + r, y: rect.maxY), radius: r)   // top-leading
        p.line(to: NSPoint(x: rect.maxX, y: rect.maxY))                       // top edge
        p.close()
        return p
    }
}
