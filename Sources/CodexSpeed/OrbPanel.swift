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
    private struct Pin {
        var session: SessionSnapshot
        let focusedSessionID: String?
    }

    private let dial: OrbDial
    private let settingsMenu: OrbSettingsMenu
    private var snapshot = SessionDisplayState(active: [], focused: nil)
    private var pinned: Pin?
    private var parallelBadgePress: NSEvent?
    private var pointerTrackingArea: NSTrackingArea?
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
        setAccessibilityValue(dial.presentation.state.accessibilityValue)
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
        if let focused = snapshot.focused, let pinned, pinned.focusedSessionID != focused.id {
            self.pinned = nil
        }
        self.snapshot = snapshot
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
        let pinnedSession = pinned.flatMap { selection in snapshot.active.first { $0.id == selection.session.id } }
        if let pinnedSession { pinned?.session = pinnedSession }
        let primary = pinnedSession ?? snapshot.focused ?? snapshot.active.first
        let source: OrbDial.Presentation.Source? = if pinnedSession != nil {
            .pinned
        } else if snapshot.focused != nil {
            .current
        } else if primary != nil {
            .recent
        } else {
            nil
        }

        let isActive = snapshot.active.contains { $0.id == primary?.id }
        let state = primary?.reading.map(OrbDial.State.measured) ?? (isActive ? .waiting : .standby)
        let parallelCount = snapshot.active.count - (isActive ? 1 : 0)
        let presentation = OrbDial.Presentation(session: primary, source: source, state: state, parallelCount: parallelCount)
        guard dial.show(presentation) else { return }
        needsDisplay = true

        let label = ["Codex 输出速率", source?.rawValue, primary?.title, primary?.model].compactMap { $0 }.joined(separator: "，")
        setAccessibilityLabel(label)
        let parallelStatus = parallelCount > 0 ? "另有 \(parallelCount) 个并行会话" : nil
        setAccessibilityValue([state.accessibilityValue, parallelStatus].compactMap { $0 }.joined(separator: "。"))
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
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (isParallelBadge(at: point) ? NSCursor.pointingHand : .arrow).set()
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        if isParallelBadge(at: point) { return "查看并行会话" }
        let presentation = dial.presentation
        return [presentation.source?.rawValue, presentation.session?.title, presentation.state.accessibilityValue]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func isParallelBadge(at point: CGPoint) -> Bool {
        dial.presentation.parallelCount > 0 && geometry.containsParallelBadge(at: point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        parallelBadgePress = nil
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
        } else if isParallelBadge(at: convert(event.locationInWindow, from: nil)) {
            parallelBadgePress = event
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = parallelBadgePress else { return }
        let start = pressed.locationInWindow
        let end = event.locationInWindow
        guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return }
        parallelBadgePress = nil
        window?.performDrag(with: pressed)
    }

    override func mouseUp(with event: NSEvent) {
        guard parallelBadgePress != nil else { return }
        parallelBadgePress = nil
        let point = convert(event.locationInWindow, from: nil)
        guard isParallelBadge(at: point) else { return }
        sessionMenu().popUp(positioning: nil, at: point, in: self)
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
        if dial.presentation.session != nil || pinned != nil {
            let sessions = NSMenuItem(title: "会话", action: nil, keyEquivalent: "")
            sessions.submenu = sessionMenu()
            menu.addItem(sessions)
            menu.addItem(.separator())
        }
        settingsMenu.addItems(to: menu)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu(title: "会话")
        menu.autoenablesItems = false
        let focused = snapshot.focused
        var entries = snapshot.active.filter { $0.id != focused?.id }
        if let focused { entries.insert(focused, at: 0) }
        if let pinned, !entries.contains(where: { $0.id == pinned.session.id }) {
            let session = pinned.session
            entries.append(SessionSnapshot(id: session.id, title: session.title, model: session.model, reading: nil))
        }
        let names = entries.map { session in
            session.title.count > 28 ? "\(session.title.prefix(27))…" : session.title
        }
        let entriesByName = Dictionary(grouping: names, by: { $0 })
        let activeIDs = Set(snapshot.active.map(\.id))
        for (index, session) in entries.enumerated() {
            if index == 1, focused != nil { menu.addItem(.separator()) }
            let name = names[index]
            let label = entriesByName[name, default: []].count > 1 ? "\(name)（\(session.id.suffix(6))）" : name
            menu.addItem(sessionItem(session, name: label, isActive: activeIDs.contains(session.id)))
        }

        if pinned != nil {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "取消固定", action: #selector(clearPin), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        return menu
    }

    private func sessionItem(_ session: SessionSnapshot, name: String, isActive: Bool) -> NSMenuItem {
        let source: OrbDial.Presentation.Source? = if session.id == snapshot.focused?.id {
            .current
        } else if session.id == pinned?.session.id {
            .pinned
        } else if session.id == dial.presentation.session?.id {
            dial.presentation.source
        } else {
            nil
        }
        let reading = session.reading.map {
            "\($0.estimated ? "约 " : "")\($0.displayValue) \(RateReading.unit)"
        } ?? (isActive ? "等待读数" : "待机")
        let title = [source?.rawValue, name, session.model, reading].compactMap { $0 }.joined(separator: "  ·  ")
        let item = NSMenuItem(title: title, action: #selector(selectSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.isEnabled = isActive || session.id == snapshot.focused?.id
        item.state = session.id == dial.presentation.session?.id ? .on : .off
        item.toolTip = session.title
        return item
    }

    @objc private func selectSession(_ item: NSMenuItem) {
        guard let session = item.representedObject as? SessionSnapshot else { return }
        if session.id == snapshot.focused?.id {
            pinned = nil
        } else if snapshot.active.contains(where: { $0.id == session.id }) {
            pinned = Pin(session: session, focusedSessionID: snapshot.focused?.id)
        }
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
