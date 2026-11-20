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
    private lazy var settingsMenu: OrbSettingsMenu = OrbSettingsMenu(settings: OrbSettings()) { [weak self] settings in
        settings.save()
        self?.orb.apply(settings)
        self?.updater.setEnabled(settings.automaticallyFetchUpdates)
    }
    private lazy var orb: OrbPanel = OrbPanel(settingsMenu: settingsMenu)
    private lazy var updater: ReleaseUpdater = ReleaseUpdater { [weak self] status in
        self?.settingsMenu.updateStatus = status
    }
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        orb.placeOnScreen()
        orb.orderFrontRegardless()

        let monitor = SessionMonitor { [weak orb] sessions in
            orb?.show(sessions)
        }
        self.monitor = monitor
        monitor.start()
        updater.setEnabled(settingsMenu.settings.automaticallyFetchUpdates)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(orb.frame) }) {
            orb.placeOnScreen()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        updater.setEnabled(false)
    }
}
