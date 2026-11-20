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
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var screenTracking: Timer?
    private var monitor: SessionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared
        foregroundObservation = workspace.observe(\.frontmostApplication, options: .initial) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }
        runningApplicationsObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
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
        let screens = NSScreen.screens
        let target: NSScreen?
        if screens.count > 1 {
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
            let processIDs = Set(processes.map(\.processIdentifier))
            updateScreenTracking(enabled: !processIDs.isEmpty)
            target = Self.screenForTopmostWindow(of: processIDs, among: screens)
        } else {
            updateScreenTracking(enabled: false)
            let codexIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.codexBundleIdentifier
            target = codexIsFrontmost ? screens.first : nil
        }

        guard let target else {
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
        // 各屏幕的窗口排序可独立变化，跨屏移动也可能不触发前台应用通知。
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }
        timer.tolerance = 0.2
        screenTracking = timer
    }

    private static func screenForTopmostWindow(of processIDs: Set<pid_t>, among screens: [NSScreen]) -> NSScreen? {
        guard !processIDs.isEmpty else { return nil }
        var availableDisplays = screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (screen, CGDisplayBounds(number.uint32Value))
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        for window in windows {
            guard let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == normalLevel,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let coordinates = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: coordinates as CFDictionary) else { continue }

            // 窗口由前往后排列，排除已有其他应用窗口在最前的屏幕。
            if processIDs.contains(processID) {
                let intersections = availableDisplays.compactMap { display -> (screen: NSScreen, area: CGFloat)? in
                    let overlap = bounds.intersection(display.bounds)
                    guard !overlap.isEmpty else { return nil }
                    return (display.screen, overlap.width * overlap.height)
                }
                if let best = intersections.max(by: { $0.area < $1.area }) { return best.screen }
            } else {
                availableDisplays.removeAll { !bounds.intersection($0.bounds).isEmpty }
                if availableDisplays.isEmpty { return nil }
            }
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
        runningApplicationsObservation?.invalidate()
        screenTracking?.invalidate()
        monitor?.stop()
        updater.stop()
    }
}
