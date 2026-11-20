import AppKit
import CoreGraphics

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
    private var screenTracking: Timer?
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let foreground = NSWorkspace.shared.frontmostApplication
        let codexIsFrontmost = foreground?.bundleIdentifier == Self.codexBundleIdentifier
        let screens = NSScreen.screens
        updateScreenTracking(enabled: codexIsFrontmost && screens.count > 1)

        guard codexIsFrontmost, let foreground,
              let target = Self.screenForWindow(of: foreground.processIdentifier, among: screens) else {
            if orb.isVisible { orb.orderOut(nil) }
            return
        }

        orb.place(on: target)
        if !orb.isVisible { orb.orderFrontRegardless() }
    }

    private func updateScreenTracking(enabled: Bool) {
        guard enabled else {
            screenTracking?.invalidate()
            screenTracking = nil
            return
        }
        guard screenTracking == nil else { return }
        // 同一应用内移动窗口或切换窗口时，系统的前台应用不会变化。
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }
        timer.tolerance = 0.2
        screenTracking = timer
    }

    private static func screenForWindow(of processID: pid_t, among screens: [NSScreen]) -> NSScreen? {
        guard screens.count > 1 else { return screens.first }
        let displays = screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (screen, CGDisplayBounds(number.uint32Value))
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == normalLevel,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let coordinates = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: coordinates as CFDictionary) else { continue }

            // 窗口可能横跨多个屏幕，选择占用面积最大的那个。
            let intersections = displays.compactMap { display -> (screen: NSScreen, area: CGFloat)? in
                let overlap = bounds.intersection(display.bounds)
                guard !overlap.isEmpty else { return nil }
                return (display.screen, overlap.width * overlap.height)
            }
            if let best = intersections.max(by: { $0.area < $1.area }) { return best.screen }
        }
        return nil
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateOrbVisibility()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater.isInstalling ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        foregroundObservation?.invalidate()
        screenTracking?.invalidate()
        monitor?.stop()
        updater.stop()
    }
}
