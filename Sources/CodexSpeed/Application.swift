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
    private struct WindowTarget {
        let window: SessionWindow
        let screen: NSScreen
    }

    private static let codexBundleIdentifier = "com.openai.codex"
    private let updater = ReleaseUpdater()
    private lazy var settingsMenu: OrbSettingsMenu = OrbSettingsMenu(
        settings: OrbSettings(), updater: updater, requestWindowTitleAccess: { [weak self] in
            _ = CGRequestScreenCaptureAccess()
            self?.updateOrbVisibility()
        }
    ) { [weak self] settings in
        settings.save()
        self?.orb.apply(settings)
        self?.updater.setEnabled(settings.automaticallyFetchUpdates)
    }
    private lazy var orb: OrbPanel = OrbPanel(settingsMenu: settingsMenu)
    private var foregroundObservation: NSKeyValueObservation?
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var screenTracking: Timer?
    private var monitor: SessionMonitor?
    private var windowTargets: [WindowTarget] = []
    private var fallbackScreen: NSScreen?
    private var focusedWindowID: CGWindowID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared
        foregroundObservation = workspace.observe(\.frontmostApplication, options: .initial) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }
        runningApplicationsObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }

        let monitor = SessionMonitor { [weak self] snapshot in
            guard let self else { return }
            self.orb.show(snapshot)
            let windowID = snapshot.focus?.windowID
            guard self.focusedWindowID != windowID else { return }
            self.focusedWindowID = windowID
            self.placeOrb()
        }
        self.monitor = monitor
        monitor.start()
        updater.setEnabled(settingsMenu.settings.automaticallyFetchUpdates)
    }

    private func updateOrbVisibility() {
        let screens = NSScreen.screens
        let canReadTitle = CGPreflightScreenCaptureAccess()
        if screens.count > 1 {
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
            let processIDs = Set(processes.map(\.processIdentifier))
            windowTargets = Self.topmostWindows(of: processIDs, among: screens, readTitles: canReadTitle)
            fallbackScreen = windowTargets.first?.screen
            updateScreenTracking(interval: processIDs.isEmpty ? nil : (canReadTitle && !windowTargets.isEmpty ? 0.25 : 1))
        } else if let screen = screens.first, let foreground = NSWorkspace.shared.frontmostApplication,
                  foreground.bundleIdentifier == Self.codexBundleIdentifier {
            updateScreenTracking(interval: canReadTitle ? 0.25 : nil)
            windowTargets = canReadTitle ? Self.topmostWindows(of: [foreground.processIdentifier], among: screens, readTitles: true) : []
            fallbackScreen = screen
        } else {
            updateScreenTracking(interval: nil)
            windowTargets = []
            fallbackScreen = nil
        }

        monitor?.focus(windows: canReadTitle ? windowTargets.map(\.window) : [])
        placeOrb()
    }

    private func placeOrb() {
        let focusedScreen = windowTargets.first { $0.window.id == focusedWindowID }?.screen
        guard let screen = focusedScreen ?? fallbackScreen else {
            if orb.isVisible { orb.orderOut(nil) }
            return
        }

        orb.place(on: screen)
        if !orb.isVisible { orb.orderFrontRegardless() }
    }

    private func updateScreenTracking(interval: TimeInterval?) {
        guard screenTracking?.timeInterval != interval else { return }
        screenTracking?.invalidate()
        screenTracking = nil
        guard let interval else { return }
        // 切换对话会改变窗口标题，应用的前台状态可能保持不变。
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateOrbVisibility() }
        }
        timer.tolerance = interval * 0.2
        screenTracking = timer
    }

    private static func topmostWindows(of processIDs: Set<pid_t>, among screens: [NSScreen],
                                       readTitles: Bool) -> [WindowTarget] {
        guard !processIDs.isEmpty else { return [] }
        var availableDisplays = screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (screen, CGDisplayBounds(number.uint32Value))
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        var targets: [WindowTarget] = []
        for window in windows {
            guard let processID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processID != ownProcessID,
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
                guard let best = intersections.max(by: { $0.area < $1.area }),
                      let number = window[kCGWindowNumber as String] as? NSNumber else { continue }
                let title = readTitles ? window[kCGWindowName as String] as? String : nil
                targets.append(WindowTarget(window: SessionWindow(id: number.uint32Value, title: title), screen: best.screen))
                if !readTitles { break }
            } else {
                availableDisplays.removeAll { !bounds.intersection($0.bounds).isEmpty }
                if availableDisplays.isEmpty { break }
            }
        }
        return targets
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
