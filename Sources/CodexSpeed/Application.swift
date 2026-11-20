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
    private let initialSettings = OrbSettings()
    private lazy var orb = OrbPanel(settings: initialSettings) { [weak self] in self?.showSettings() }
    private lazy var updater = ReleaseUpdater { [weak self] status in
        self?.settingsWindow?.showUpdateStatus(status)
    }
    private var settingsWindow: OrbSettingsWindow?
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        orb.placeOnScreen()
        orb.orderFrontRegardless()

        let monitor = SessionMonitor { [weak orb] sessions in
            orb?.show(sessions)
        }
        self.monitor = monitor
        monitor.start()
        updater.setEnabled(initialSettings.automaticallyFetchUpdates)
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

    private func showSettings() {
        let window = settingsWindow ?? OrbSettingsWindow(
            settings: initialSettings, updateStatus: updater.status
        ) { [weak self] value in
            value.save()
            self?.orb.apply(value)
            self?.updater.setEnabled(value.automaticallyFetchUpdates)
        }
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
