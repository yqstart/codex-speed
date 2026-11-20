import AppKit

final class OrbPanel: NSPanel {
    private static let size: CGFloat = 104
    private let orb = OrbView(frame: .zero)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
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
}

private final class OrbView: NSView {
    private static let bezel = NSGradient(
        starting: NSColor(srgbRed: 0.47, green: 0.49, blue: 0.52, alpha: 1),
        ending: NSColor(srgbRed: 0.19, green: 0.20, blue: 0.22, alpha: 1)
    )
    private static let face = NSGradient(
        starting: NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1),
        ending: NSColor(srgbRed: 0.064, green: 0.070, blue: 0.085, alpha: 1)
    )
    private static let accent = NSColor(srgbRed: 1, green: 0.70, blue: 0.37, alpha: 1)
    private static let digits = NSColor(srgbRed: 0.99, green: 0.97, blue: 0.93, alpha: 1)
    private static let unit = NSColor(srgbRed: 0.69, green: 0.70, blue: 0.73, alpha: 1)
    private static let idle = NSColor(srgbRed: 0.48, green: 0.50, blue: 0.54, alpha: 1)

    private var sessions: [SessionSnapshot] = []
    private var pinned: SessionSnapshot?

    private var reading: RateReading? {
        didSet {
            guard reading != oldValue else { return }
            needsDisplay = true
            let value = reading.map { ($0.estimated ? "约 " : "") + "\($0.value) 词元每秒" }
            setAccessibilityValue(value ?? "暂无速率")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Codex 输出速率")
        setAccessibilityValue("暂无速率")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "退出") { [weak self] in
            guard let self else { return false }
            self.quit()
            return true
        }])
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func show(_ sessions: [SessionSnapshot]) {
        self.sessions = sessions
        updateReading()
    }

    private func updateReading() {
        let entry: SessionSnapshot?
        if let pinned {
            entry = sessions.first { $0.id == pinned.id }
            if let entry { self.pinned = entry }
        } else {
            entry = sessions.first
        }
        reading = entry?.reading
        let identified = entry ?? pinned
        let label = ["Codex 输出速率", identified?.title, identified?.model].compactMap { $0 }.joined(separator: "，")
        setAccessibilityLabel(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        let disc = bounds.insetBy(dx: 6, dy: 6)
        let outer = NSBezierPath(ovalIn: disc)
        let inner = NSBezierPath(ovalIn: disc.insetBy(dx: 1.6, dy: 1.6))
        Self.bezel?.draw(in: outer, angle: 62)
        Self.face?.draw(in: inner, angle: 82)
        NSColor.black.withAlphaComponent(0.36).setStroke()
        outer.lineWidth = 0.75
        outer.stroke()

        drawDial(radius: disc.width / 2 - 6.2)
        drawReading(maximumWidth: disc.width - 25)
    }

    private func drawDial(radius: CGFloat) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let start: CGFloat = 143
        let sweep: CGFloat = 254
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
        track.lineCapStyle = .round
        track.lineWidth = 1.25
        Self.unit.withAlphaComponent(0.20).setStroke()
        track.stroke()

        guard let reading else { return }
        let speed = CGFloat(reading.value)
        let fraction = max(0.025, speed / (speed + 55))
        let progress = NSBezierPath()
        progress.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + sweep * fraction, clockwise: false)
        progress.lineCapStyle = .round
        progress.lineWidth = 4
        Self.accent.withAlphaComponent(0.12).setStroke()
        progress.stroke()
        progress.lineWidth = 1.65
        Self.accent.setStroke()
        progress.stroke()
    }

    private func drawReading(maximumWidth: CGFloat) {
        let mark = reading?.estimated == true ? NSAttributedString(string: "≈", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: Self.accent,
        ]) : nil
        let markWidth = mark.map { $0.size().width + 3 } ?? 0
        let value = reading.map { String($0.value) } ?? "—"
        let color = reading == nil ? Self.idle : Self.digits
        let baseSize: CGFloat = reading == nil ? 26 : 31
        let number = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold),
            .foregroundColor: color,
            .kern: -0.75,
        ])
        let remainingWidth = maximumWidth - markWidth
        let numberWidth = number.size().width
        if numberWidth > remainingWidth {
            let size = baseSize * remainingWidth / numberWidth
            number.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), range: NSRange(location: 0, length: number.length))
        }
        let measured = number.size()
        let left = bounds.midX - (measured.width + markWidth) / 2
        let centerY = bounds.midY - 8
        number.draw(at: NSPoint(x: left + markWidth, y: centerY - measured.height / 2))
        if let mark {
            mark.draw(at: NSPoint(x: left, y: centerY - mark.size().height / 2 + 1))
        }

        let unit = NSAttributedString(string: "token/s", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: Self.unit,
            .kern: 0.12,
        ])
        let measuredUnit = unit.size()
        unit.draw(at: NSPoint(x: bounds.midX - measuredUnit.width / 2, y: bounds.midY + 14 - measuredUnit.height / 2))
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
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func sessionItem(_ session: SessionSnapshot, reading: RateReading?) -> NSMenuItem {
        let name = session.title.count > 24 ? "\(session.title.prefix(24))…" : session.title
        let model = session.model ?? "模型未知"
        let speed = reading?.displayValue ?? "—"
        let item = NSMenuItem(title: "\(name)  ·  \(model)  ·  \(speed) token/s", action: #selector(selectSession(_:)), keyEquivalent: "")
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
