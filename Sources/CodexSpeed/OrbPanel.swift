import AppKit
import QuartzCore

final class OrbPanel: NSPanel {
    private let orb: OrbView

    init(settings: OrbSettings, openSettings: @escaping () -> Void) {
        let size = CGFloat(settings.size)
        let appearance = settings.appearance.name.flatMap(NSAppearance.init(named:))
        orb = OrbView(appearance: appearance ?? NSApplication.shared.effectiveAppearance,
                      style: settings.style, openSettings: openSettings)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Codex Speed"
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.appearance = appearance
        contentView = orb
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func placeOnScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 20, y: visible.minY + 20))
    }

    func show(_ sessions: [SessionSnapshot]) {
        orb.show(sessions)
    }

    func apply(_ settings: OrbSettings) {
        if appearance?.name != settings.appearance.name {
            appearance = settings.appearance.name.flatMap(NSAppearance.init(named:))
        }
        orb.setStyle(settings.style)

        let size = CGFloat(settings.size)
        guard frame.width != size else { return }
        var resized = NSRect(x: frame.maxX - size, y: frame.minY, width: size, height: size)
        if let visible = screen?.visibleFrame {
            resized.origin.x = max(visible.minX, min(resized.minX, visible.maxX - size))
            resized.origin.y = max(visible.minY, min(resized.minY, visible.maxY - size))
        }
        setFrame(resized, display: true)
        invalidateShadow()
    }
}

private final class OrbView: NSView {
    private let dial: OrbDial
    private let openSettings: () -> Void
    private var sessions: [SessionSnapshot] = []
    private var pinned: SessionSnapshot?

    init(appearance: NSAppearance, style: OrbSettings.Style, openSettings: @escaping () -> Void) {
        dial = OrbDial(appearance: appearance, style: style)
        self.openSettings = openSettings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dial.layer)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Codex 输出速率")
        setAccessibilityValue(dial.state.accessibilityValue)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "设置") { [weak self] in
                guard let self else { return false }
                self.openSettings()
                return true
            },
            NSAccessibilityCustomAction(name: "退出") { [weak self] in
                guard let self else { return false }
                self.quit()
                return true
            },
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if dial.setAppearance(effectiveAppearance) { needsDisplay = true }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateMotion), name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        updateMotion()
    }

    @objc private func updateMotion() {
        let visible = window?.occlusionState.contains(.visible) == true
        dial.setMotionEnabled(visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func show(_ sessions: [SessionSnapshot]) {
        self.sessions = sessions
        updateReading()
    }

    func setStyle(_ style: OrbSettings.Style) {
        if dial.setStyle(style) { needsDisplay = true }
    }

    private func updateReading() {
        let entry: SessionSnapshot?
        if let pinned {
            entry = sessions.first { $0.id == pinned.id }
            if let entry { self.pinned = entry }
        } else {
            entry = sessions.first
        }
        let state = entry?.reading.map(OrbDial.State.measured) ?? (entry == nil ? .standby : .waiting)
        if state != dial.state {
            dial.show(state)
            setAccessibilityValue(state.accessibilityValue)
            needsDisplay = true
        }
        let identified = entry ?? pinned
        let label = ["Codex 输出速率", identified?.title, identified?.model].compactMap { $0 }.joined(separator: "，")
        setAccessibilityLabel(label)
    }

    override func layout() {
        super.layout()
        let scale = bounds.width / OrbDial.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dial.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dial.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / OrbDial.size
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        dial.draw()
        context.restoreGState()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        let menu = NSMenu()
        let automatic = NSMenuItem(title: "自动显示最近活跃", action: #selector(selectAutomatic), keyEquivalent: "")
        automatic.target = self
        automatic.state = pinned == nil ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())

        if sessions.isEmpty && pinned == nil {
            menu.addItem(NSMenuItem(title: "暂无工作会话", action: nil, keyEquivalent: ""))
        }
        for session in sessions {
            menu.addItem(sessionItem(session, reading: session.reading))
        }
        if let pinned, !sessions.contains(where: { $0.id == pinned.id }) {
            menu.addItem(sessionItem(pinned, reading: nil))
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func sessionItem(_ session: SessionSnapshot, reading: RateReading?) -> NSMenuItem {
        let name = session.title.count > 24 ? "\(session.title.prefix(24))…" : session.title
        let model = session.model ?? "模型未知"
        let speed = reading?.displayValue ?? "—"
        let item = NSMenuItem(title: "\(name)  ·  \(model)  ·  \(speed) 词元/秒", action: #selector(selectSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.state = session.id == pinned?.id ? .on : .off
        return item
    }

    @objc private func selectSession(_ item: NSMenuItem) {
        guard let session = item.representedObject as? SessionSnapshot else { return }
        pinned = session
        updateReading()
    }

    @objc private func selectAutomatic() {
        pinned = nil
        updateReading()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
