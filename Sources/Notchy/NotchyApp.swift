import AppKit
import SwiftUI

@main
struct NotchyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }   // no windows; the notch panel is the whole UI
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: UsageStore?
    var panel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no Cmd-Tab entry

        // Mock registry behind a debug flag (UI was built against mocks).
        let mock = ProcessInfo.processInfo.environment["NOTCHY_MOCK"] == "1"
        let providers: [UsageProvider] = mock
            ? [MockProvider(info: ProviderInfo(id: "claude", name: "Claude", tintHex: "#D97757", symbol: "claude"), session: 0.73, weekly: 0.41),
               MockProvider(info: ProviderInfo(id: "codex", name: "Codex", tintHex: "#10A37F", symbol: "openai"), session: nil, weekly: 0.38),
               MockProvider(info: ProviderInfo(id: "glm", name: "GLM", tintHex: "#2E66FF", symbol: "zai"), session: 1.0, weekly: 0.62)]
            : [ClaudeProvider(), CodexProvider(), GLMProvider()]

        let store = UsageStore(providers: providers)
        let notch = NotchState()
        let panel = NotchPanel(contentSize: NotchMetrics.expandedSize(providers.count))
        let host = PassthroughHostingView(
            rootView: NotchContentView().environmentObject(store).environmentObject(notch))
        host.state = notch
        panel.contentView = host
        panel.positionOnScreen()
        panel.observeScreenChanges()

        self.store = store
        self.panel = panel
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }
}

/// Mock provider for UI work (NOTCHY_MOCK=1). `session: nil` exercises the
/// weekly-fallback `wk` state; `session >= 1` the over-limit state.
final class MockProvider: UsageProvider {
    let info: ProviderInfo
    let refresh: RefreshPolicy = .poll(.seconds(60))
    let session: Double?
    let weekly: Double

    init(info: ProviderInfo, session: Double?, weekly: Double) {
        self.info = info
        self.session = session
        self.weekly = weekly
    }

    func currentUsage() async throws -> ProviderUsage {
        ProviderUsage(
            session: session.map { UsageWindow(percent: $0, resetsAt: Date().addingTimeInterval(51 * 60)) },
            weekly: UsageWindow(percent: weekly, resetsAt: Date().addingTimeInterval((2 * 24 + 4) * 3600))
        )
    }

    func localUsage() async -> ProviderUsage? { nil }
}
