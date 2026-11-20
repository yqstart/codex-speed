import AppKit

@main
@MainActor
struct CodexSpeedApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"
    private let updater = ReleaseUpdater()
    private lazy var settingsMenu: OrbSettingsMenu = OrbSettingsMenu(settings: OrbSettings(), updater: updater) { [weak self] settings in
        settings.save()
        self?.orb.apply(settings)
        self?.updater.setEnabled(settings.automaticallyFetchUpdates)
    }
    private lazy var orb: OrbPanel = OrbPanel(settingsMenu: settingsMenu)
    private var foregroundObservation: NSKeyValueObservation?
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        orb.placeOnScreen()
        foregroundObservation = NSWorkspace.shared.observe(\.frontmostApplication, options: .initial) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }

        let monitor = SessionMonitor { [weak orb] sessions in
            orb?.show(sessions)
        }
        self.monitor = monitor
        monitor.start()
        updater.setEnabled(settingsMenu.settings.automaticallyFetchUpdates)
    }

    private func updateOrbVisibility() {
        let visible = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.codexBundleIdentifier
        guard visible != orb.isVisible else { return }
        if visible {
            orb.orderFrontRegardless()
        } else {
            orb.orderOut(nil)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(orb.frame) }) {
            orb.placeOnScreen()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater.isInstalling ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        foregroundObservation?.invalidate()
        monitor?.stop()
        updater.stop()
    }
}
