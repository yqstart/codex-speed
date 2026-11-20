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
    private let orb = OrbPanel()
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        orb.placeOnScreen()
        orb.orderFrontRegardless()

        let monitor = SessionMonitor { [weak orb] sessions in
            orb?.show(sessions)
        }
        self.monitor = monitor
        monitor.start()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(orb.frame) }) {
            orb.placeOnScreen()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }
}
