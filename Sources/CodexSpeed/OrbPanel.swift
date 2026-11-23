import AppKit
import QuartzCore

final class OrbPanel: NSPanel {
    private let orb: OrbView
    private var hasPlacement = false
    private var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    init(settingsMenu: OrbSettingsMenu) {
        let settings = settingsMenu.settings
        let size = CGFloat(settings.size)
        let appearance = settings.appearance.name.flatMap(NSAppearance.init(named:))
        orb = OrbView(geometry: OrbLayout(diameter: size), settingsMenu: settingsMenu,
                      appearance: appearance ?? NSApplication.shared.effectiveAppearance)
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
        acceptsMouseMovedEvents = true
        allowsToolTipsWhenApplicationIsInactive = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.appearance = appearance
        contentView = orb
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        if hasPlacement, screen.frame.contains(center) {
            if !visible.contains(frame) {
                reposition(around: center, within: visible)
            }
            return
        }
        let diameter = orb.geometry.diameter
        reposition(around: CGPoint(x: visible.maxX - diameter / 2 - 20, y: visible.minY + diameter / 2 + 20),
                   within: visible)
        hasPlacement = true
    }

    func show(_ snapshot: SessionDisplayState) {
        orb.show(snapshot)
    }

    func apply(_ settings: OrbSettings) {
        if appearance?.name != settings.appearance.name {
            appearance = settings.appearance.name.flatMap(NSAppearance.init(named:))
        }
        orb.setStyle(settings.style)

        let geometry = OrbLayout(diameter: CGFloat(settings.size))
        guard orb.geometry != geometry else { return }
        let center = self.center
        let targetScreen = NSScreen.screens.first { $0.frame.contains(center) } ?? screen
        orb.setGeometry(geometry)
        reposition(around: center, within: targetScreen?.visibleFrame)
    }

    private func reposition(around center: CGPoint, within visible: CGRect?) {
        var resized = orb.geometry.frame(centeredOn: center)
        if let visible {
            resized.origin.x = max(visible.minX, min(resized.minX, visible.maxX - resized.width))
            resized.origin.y = max(visible.minY, min(resized.minY, visible.maxY - resized.height))
        }
        if frame != resized { setFrame(resized, display: true) }
        invalidateShadow()
    }
}

private final class OrbView: NSView, NSViewToolTipOwner {
    private let dial: OrbDial
    private let settingsMenu: OrbSettingsMenu
    private var sessions: [SessionSnapshot] = []
    private var sessionOrder: [String] = []
    private var focusedSession: SessionSnapshot?
    private var pinned: SessionSnapshot?
    private var primarySession: SessionSnapshot?
    private var pressedRing: (id: String, event: NSEvent)?
    private var ringTrackingArea: NSTrackingArea?
    private(set) var geometry: OrbLayout

    init(geometry: OrbLayout, settingsMenu: OrbSettingsMenu, appearance: NSAppearance) {
        self.geometry = geometry
        self.settingsMenu = settingsMenu
        dial = OrbDial(appearance: appearance, style: settingsMenu.settings.style)
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
            NSAccessibilityCustomAction(name: "打开右键菜单") { [weak self] in
                guard let self else { return false }
                let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
                return self.contextMenu().popUp(positioning: nil, at: center, in: self)
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

    func show(_ snapshot: SessionDisplayState) {
        sessions = snapshot.active
        focusedSession = snapshot.focus?.session
        let incoming = sessions.map(\.id)
        let activeIDs = Set(incoming)
        sessionOrder.removeAll { !activeIDs.contains($0) }
        let existing = Set(sessionOrder)
        sessionOrder.append(contentsOf: incoming.filter { !existing.contains($0) })
        updateReading()
    }

    func setStyle(_ style: OrbSettings.Style) {
        if dial.setStyle(style) { needsDisplay = true }
    }

    func setGeometry(_ geometry: OrbLayout) {
        guard self.geometry != geometry else { return }
        self.geometry = geometry
        needsLayout = true
    }

    private func updateReading() {
        let pinnedEntry = pinned.flatMap { selection in sessions.first { $0.id == selection.id } }
        if let pinnedEntry { pinned = pinnedEntry }
        let primary = pinnedEntry ?? focusedSession ?? sessions.first
        primarySession = primary

        let snapshots = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var visible = sessionOrder.prefix(OrbLayout.maximumRings).compactMap { snapshots[$0] }
        if let id = primary?.id, let selected = snapshots[id], !visible.contains(where: { $0.id == id }) {
            // 从菜单选中未显示的会话时，用最内圈展示它。
            visible[visible.count - 1] = selected
        }

        let selectedIndex = visible.firstIndex { $0.id == primary?.id }
        let state = primary?.reading.map(OrbDial.State.measured) ?? (selectedIndex == nil ? .standby : .waiting)
        if dial.show(state, sessions: visible, selectedIndex: selectedIndex) {
            needsDisplay = true
        }
        let identified = primary ?? pinned
        let label = ["Codex 输出速率", identified?.title, identified?.model].compactMap { $0 }.joined(separator: "，")
        setAccessibilityLabel(label)
        let otherReadings = visible.filter { $0.id != primary?.id }.map { session in
            let value = session.reading.map(OrbDial.State.measured)?.accessibilityValue ?? "等待读数"
            return "\(session.title)，\(value)"
        }
        setAccessibilityValue(([state.accessibilityValue] + otherReadings).joined(separator: "。"))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dial.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dial.layer.setAffineTransform(CGAffineTransform(scaleX: geometry.scale, y: geometry.scale))
        CATransaction.commit()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: geometry.scale, y: geometry.scale)
        dial.draw()
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ringTrackingArea { removeTrackingArea(ringTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        ringTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let session = ringSession(at: convert(event.locationInWindow, from: nil))
        (session == nil ? NSCursor.arrow : .pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        if let session = ringSession(at: point) {
            let speed = session.reading.map { reading in
                "\(reading.estimated ? "约 " : "")\(reading.displayValue) \(RateReading.unit)"
            } ?? "等待读数"
            return "\(session.title)\n\(speed)"
        }
        return primarySession?.title ?? pinned?.title ?? ""
    }

    private func ringSession(at point: CGPoint) -> SessionSnapshot? {
        guard let index = geometry.ringIndex(at: point, count: dial.sessions.count) else { return nil }
        return dial.sessions[index]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedRing = nil
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
        } else if let session = ringSession(at: convert(event.locationInWindow, from: nil)) {
            pressedRing = (session.id, event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedRing else { return }
        let start = pressed.event.locationInWindow
        let end = event.locationInWindow
        guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return }
        pressedRing = nil
        window?.performDrag(with: pressed.event)
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedRing
        pressedRing = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, let session = ringSession(at: point), pressed.id == session.id else { return }
        pin(session)
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        contextMenu().popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        settingsMenu.addItems(to: menu)
        if !sessions.isEmpty || pinned != nil {
            menu.addItem(.separator())
            let sessions = NSMenuItem(title: "会话", action: nil, keyEquivalent: "")
            sessions.submenu = sessionMenu()
            menu.addItem(sessions)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu(title: "会话")
        for session in sessions {
            menu.addItem(sessionItem(session, reading: session.reading))
        }
        if let pinned, !sessions.contains(where: { $0.id == pinned.id }) {
            menu.addItem(sessionItem(pinned, reading: nil))
        }

        if pinned != nil {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "取消固定", action: #selector(clearPin), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        return menu
    }

    private func sessionItem(_ session: SessionSnapshot, reading: RateReading?) -> NSMenuItem {
        let name = session.title.count > 24 ? "\(session.title.prefix(24))…" : session.title
        let model = session.model ?? "模型未知"
        let speed = reading?.displayValue ?? "—"
        let item = NSMenuItem(title: "\(name)  ·  \(model)  ·  \(speed) \(RateReading.unit)", action: #selector(selectSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.state = session.id == pinned?.id ? .on : .off
        return item
    }

    @objc private func selectSession(_ item: NSMenuItem) {
        guard let session = item.representedObject as? SessionSnapshot else { return }
        pin(session)
    }

    private func pin(_ session: SessionSnapshot) {
        pinned = session
        updateReading()
    }

    @objc private func clearPin() {
        pinned = nil
        updateReading()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
