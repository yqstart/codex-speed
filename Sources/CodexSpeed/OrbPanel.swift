import AppKit
import QuartzCore

final class OrbPanel: NSPanel {
    private let orb: OrbView
    private var diameter: CGFloat
    private var extendsLeft = true
    private var hasPlacement = false
    private var primaryCenter: CGPoint {
        CGPoint(x: frame.minX + orb.geometry.primary.midX, y: frame.maxY - orb.geometry.primary.midY)
    }

    init(settingsMenu: OrbSettingsMenu) {
        let settings = settingsMenu.settings
        let size = CGFloat(settings.size)
        diameter = size
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
        if hasPlacement, screen.frame.contains(primaryCenter) {
            if !visible.contains(frame) {
                reposition(around: primaryCenter, within: visible)
            }
            return
        }
        reposition(around: CGPoint(x: visible.maxX - diameter / 2 - 20, y: visible.minY + diameter / 2 + 20),
                   within: visible)
        hasPlacement = true
    }

    func show(_ snapshot: SessionDisplayState) {
        orb.show(snapshot)
        if orb.satelliteCount != orb.geometry.satellites.count { resizeAroundPrimary() }
    }

    func apply(_ settings: OrbSettings) {
        if appearance?.name != settings.appearance.name {
            appearance = settings.appearance.name.flatMap(NSAppearance.init(named:))
        }
        orb.setStyle(settings.style)

        let size = CGFloat(settings.size)
        guard diameter != size else { return }
        diameter = size
        resizeAroundPrimary()
    }

    private func resizeAroundPrimary() {
        let center = primaryCenter
        let targetScreen = NSScreen.screens.first { $0.frame.contains(center) } ?? screen
        reposition(around: center, within: targetScreen?.visibleFrame)
    }

    private func reposition(around center: CGPoint, within visible: CGRect?) {
        var geometry = OrbLayout(diameter: diameter, satelliteCount: orb.satelliteCount, extendsLeft: extendsLeft)
        var resized = geometry.frame(centeredOn: center)
        if let visible {
            if orb.satelliteCount > 0, resized.minX < visible.minX || resized.maxX > visible.maxX {
                // 优先向空间更宽的一侧展开，尽量保持主球的位置。
                let roomOnLeft = center.x - visible.minX
                let roomOnRight = visible.maxX - center.x
                extendsLeft = roomOnLeft >= roomOnRight
                geometry = OrbLayout(diameter: diameter, satelliteCount: orb.satelliteCount, extendsLeft: extendsLeft)
                resized = geometry.frame(centeredOn: center)
            }
            resized.origin.x = max(visible.minX, min(resized.minX, visible.maxX - resized.width))
            resized.origin.y = max(visible.minY, min(resized.minY, visible.maxY - resized.height))
        }
        orb.setGeometry(geometry)
        if frame != resized { setFrame(resized, display: true) }
        invalidateShadow()
    }
}

private final class OrbView: NSView, NSViewToolTipOwner {
    private enum Target: Equatable {
        case session(String), more
    }

    private enum Satellite: Equatable {
        case session(SessionSnapshot), overflow(Int)

        var target: Target {
            switch self {
            case let .session(session): .session(session.id)
            case .overflow: .more
            }
        }

        var value: String {
            switch self {
            case let .session(session): session.reading?.displayValue ?? "—"
            case let .overflow(count): "+\(count)"
            }
        }

        var subdued: Bool {
            if case let .session(session) = self { return session.reading == nil }
            return true
        }

        var accessibilityDescription: String {
            switch self {
            case let .session(session):
                let speed = session.reading.map(OrbDial.State.measured)?.accessibilityValue ?? "等待读数"
                return "\(session.title)，\(speed)"
            case let .overflow(count):
                return "另有 \(count) 个会话"
            }
        }
    }

    private let dial: OrbDial
    private let settingsMenu: OrbSettingsMenu
    private var sessions: [SessionSnapshot] = []
    private var sessionOrder: [String] = []
    private var focusedSession: SessionSnapshot?
    private var pinned: SessionSnapshot?
    private var primarySession: SessionSnapshot?
    private var satellites: [Satellite] = []
    private var pressedSatellite: (target: Target, event: NSEvent)?
    private(set) var geometry: OrbLayout
    var satelliteCount: Int { satellites.count }

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
                let primary = self.geometry.primary
                return self.contextMenu().popUp(positioning: nil, at: CGPoint(x: primary.midX, y: primary.midY), in: self)
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
        focusedSession = snapshot.focused
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
        let primaryChanged = primarySession?.id != primary?.id
        if let primary, let previous = primarySession, previous.id != primary.id,
           let oldIndex = sessionOrder.firstIndex(of: previous.id),
           let newIndex = sessionOrder.firstIndex(of: primary.id) {
            // 主会话变化时交换两颗球的位置，让其余会话留在原位。
            sessionOrder.swapAt(oldIndex, newIndex)
        }
        primarySession = primary
        if primaryChanged { refreshToolTips() }

        let others = sessionOrder.filter { $0 != primary?.id }
        let capacity = OrbLayout.maximumSatellites
        let visibleCount = others.count > capacity ? capacity - 1 : capacity
        let snapshots = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var next = others.prefix(visibleCount).compactMap { snapshots[$0].map(Satellite.session) }
        if others.count > visibleCount { next.append(.overflow(others.count - visibleCount)) }
        if satellites != next {
            satellites = next
            needsDisplay = true
        }

        let hasActivity = primary.map { sessionOrder.contains($0.id) } ?? false
        let state = primary?.reading.map(OrbDial.State.measured) ?? (hasActivity ? .waiting : .standby)
        if state != dial.state {
            dial.show(state)
            needsDisplay = true
        }
        let identified = primary ?? pinned
        let label = ["Codex 输出速率", identified?.title, identified?.model].compactMap { $0 }.joined(separator: "，")
        setAccessibilityLabel(label)
        setAccessibilityValue(([state.accessibilityValue] + satellites.map(\.accessibilityDescription)).joined(separator: "。"))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dial.layer.position = CGPoint(x: geometry.primary.midX, y: geometry.primary.midY)
        dial.layer.setAffineTransform(CGAffineTransform(scaleX: geometry.scale, y: geometry.scale))
        CATransaction.commit()
        refreshToolTips()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, rect) in geometry.satellites.enumerated() {
            let parent = index == 2 ? geometry.satellites[0] : geometry.primary
            dial.drawBond(from: CGPoint(x: parent.midX, y: parent.midY), to: CGPoint(x: rect.midX, y: rect.midY), scale: geometry.scale)
        }
        for (satellite, rect) in zip(satellites, geometry.satellites) {
            dial.drawSatellite(value: satellite.value, in: rect, subdued: satellite.subdued)
        }
        context.saveGState()
        context.translateBy(x: geometry.primary.minX, y: geometry.primary.minY)
        context.scaleBy(x: geometry.scale, y: geometry.scale)
        dial.draw(emphasized: !satellites.isEmpty)
        context.restoreGState()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in geometry.satellites { addCursorRect(rect, cursor: .pointingHand) }
    }

    private func refreshToolTips() {
        removeAllToolTips()
        addToolTip(geometry.primary.insetBy(dx: 7 * geometry.scale, dy: 7 * geometry.scale), owner: self, userData: nil)
        for rect in geometry.satellites { addToolTip(rect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        if let satellite = satellite(at: point) {
            switch satellite {
            case let .session(session): return session.title
            case let .overflow(count): return "另有 \(count) 个会话，点击查看全部"
            }
        }
        guard geometry.primary.contains(point) else { return "" }
        return primarySession?.title ?? pinned?.title ?? ""
    }

    private func satellite(at point: CGPoint) -> Satellite? {
        guard let index = geometry.satelliteIndex(at: point), satellites.indices.contains(index) else { return nil }
        return satellites[index]
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedSatellite = nil
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
        } else if let satellite = satellite(at: convert(event.locationInWindow, from: nil)) {
            pressedSatellite = (satellite.target, event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedSatellite else { return }
        let start = pressed.event.locationInWindow
        let end = event.locationInWindow
        guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return }
        pressedSatellite = nil
        window?.performDrag(with: pressed.event)
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedSatellite
        pressedSatellite = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, let satellite = satellite(at: point), pressed.target == satellite.target else { return }
        switch satellite {
        case let .session(session): pin(session)
        case .overflow: sessionMenu().popUp(positioning: nil, at: point, in: self)
        }
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
