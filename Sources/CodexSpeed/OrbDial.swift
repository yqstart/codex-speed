import AppKit
import QuartzCore

@MainActor
final class OrbDial {
    enum State: Equatable {
        case standby, waiting, measured(RateReading)

        var reading: RateReading? {
            if case let .measured(reading) = self { return reading }
            return nil
        }

        var caption: String {
            switch self {
            case .standby: "待机"
            case .waiting: "等待读数"
            case .measured: RateReading.unit
            }
        }

        var accessibilityValue: String {
            guard let reading else { return caption }
            let approximation = reading.estimated ? "约 " : ""
            return "\(approximation)\(reading.value) 词元每秒"
        }
    }

    private struct Palette {
        let face: NSColor
        let text: NSColor
        let muted: NSColor
        let track: NSColor
        let ringColors: [NSColor]

        private static func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                    green: CGFloat((rgb >> 8) & 0xff) / 255,
                    blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }

        static let light = Palette(
            face: color(0xf9fbfe),
            text: color(0x162437),
            muted: color(0x49586d),
            track: color(0xe1e7f0),
            ringColors: [0x405fd1, 0x628013, 0x6952a5, 0x007486, 0xaf4e1c].map(color)
        )

        static let dark = Palette(
            face: color(0x171e2b),
            text: color(0xecf2fb),
            muted: color(0xabbad0),
            track: color(0x323e50),
            ringColors: [0x839fff, 0xb6d75e, 0xbea5fa, 0x5bc9d6, 0xffa578].map(color)
        )
    }

    private struct Ring {
        let track = CAShapeLayer()
        let progress = CAShapeLayer()

        init(index: Int) {
            let radius = OrbLayout.ringRadius(at: index)
            let inset = OrbLayout.baseDiameter / 2 - radius
            track.path = CGPath(ellipseIn: OrbLayout.bounds.insetBy(dx: inset, dy: inset), transform: nil)
            let arc = CGMutablePath()
            arc.addRelativeArc(center: OrbLayout.center, radius: radius, startAngle: -.pi / 2, delta: 2 * .pi)
            progress.path = arc
            progress.strokeEnd = 0
            progress.lineCap = .round
            for shape in [track, progress] {
                shape.frame = OrbLayout.bounds
                shape.fillColor = nil
                shape.isHidden = true
            }
        }
    }

    private static let barHeights: [CGFloat] = [4, 9, 15, 9, 4]

    let layer = CALayer()
    private let rings = (0..<OrbLayout.maximumRings).map(Ring.init)
    private let signal = CALayer()
    private let ripple = CAShapeLayer()
    private let bars = barHeights.map { _ in CALayer() }
    private var colorScheme: NSAppearance.Name
    private var palette: Palette { colorScheme == .darkAqua ? .dark : .light }
    private var selectedColor: NSColor? { selectedIndex.map { palette.ringColors[$0] } }
    private var style: OrbSettings.Style
    private var isInstrument: Bool { style == .instrument }
    private var motionEnabled = false
    private var canAnimate: Bool { motionEnabled && isInstrument }
    private(set) var state = State.standby
    private(set) var sessions: [SessionSnapshot] = []
    private var selectedIndex: Int?

    init(appearance: NSAppearance, style: OrbSettings.Style) {
        colorScheme = Self.colorScheme(for: appearance)
        self.style = style
        layer.frame = OrbLayout.bounds
        for ring in rings {
            layer.addSublayer(ring.track)
            layer.addSublayer(ring.progress)
        }

        let center = OrbLayout.center
        let signalCenter = CGPoint(x: center.x, y: center.y - 7)
        signal.frame = OrbLayout.bounds
        ripple.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        ripple.position = signalCenter
        ripple.path = CGPath(ellipseIn: ripple.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        ripple.fillColor = nil
        ripple.lineWidth = 0.8
        ripple.opacity = 0.22
        signal.addSublayer(ripple)
        for (index, bar) in bars.enumerated() {
            let offset = CGFloat(index - bars.count / 2) * 5.3
            bar.bounds = CGRect(x: 0, y: 0, width: 2.5, height: Self.barHeights[index])
            bar.position = CGPoint(x: signalCenter.x + offset, y: signalCenter.y)
            bar.cornerRadius = 1.25
            bar.opacity = index == bars.count / 2 ? 1 : 0.75
            signal.addSublayer(bar)
        }
        layer.addSublayer(signal)
        updateSignalColor()
        updateSignal()
    }

    private static func colorScheme(for appearance: NSAppearance) -> NSAppearance.Name {
        appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }

    func setAppearance(_ appearance: NSAppearance) -> Bool {
        let newScheme = Self.colorScheme(for: appearance)
        guard colorScheme != newScheme else { return false }
        colorScheme = newScheme

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateSignalColor()
        updateRings(previousSessions: sessions)
        CATransaction.commit()
        return true
    }

    func setStyle(_ style: OrbSettings.Style) -> Bool {
        guard self.style != style else { return false }
        self.style = style
        refreshMotion()
        return true
    }

    func show(_ newState: State, sessions: [SessionSnapshot], selectedIndex: Int?) -> Bool {
        let selectionChanged = self.selectedIndex != selectedIndex
        guard state != newState || self.sessions != sessions || selectionChanged else { return false }
        let previousState = state
        let previousSessions = self.sessions
        state = newState
        self.sessions = sessions
        self.selectedIndex = selectedIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRings(previousSessions: previousSessions)
        if selectionChanged { updateSignalColor() }
        if previousState != newState && (previousState.reading == nil || newState.reading == nil) {
            updateSignal()
        }
        CATransaction.commit()
        return true
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard enabled != motionEnabled else { return }
        motionEnabled = enabled
        refreshMotion()
    }

    private func refreshMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateSignal()
        if !canAnimate {
            for ring in rings { ring.progress.removeAnimation(forKey: "strokeEnd") }
        }
        CATransaction.commit()
    }

    private func updateSignalColor() {
        let color = (selectedColor ?? palette.ringColors[0]).cgColor
        ripple.strokeColor = color
        for bar in bars { bar.backgroundColor = color }
    }

    private func updateSignal() {
        signal.isHidden = !isInstrument || state.reading != nil
        signal.opacity = state == .standby ? 0.82 : 1

        let pulseKey = "transform.scale.y"
        guard motionEnabled && !signal.isHidden else {
            ripple.removeAnimation(forKey: "ripple")
            for bar in bars { bar.removeAnimation(forKey: pulseKey) }
            return
        }

        let period: CFTimeInterval = state == .standby ? 2.2 : 1.15
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 0.76
        expand.toValue = 1.35
        expand.duration = period
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.55, 0]
        fade.keyTimes = [0, 0.23, 1]
        fade.duration = period
        let wave = CAAnimationGroup()
        wave.animations = [expand, fade]
        wave.duration = period
        wave.repeatCount = .infinity
        ripple.add(wave, forKey: "ripple")

        for (index, bar) in bars.enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: pulseKey)
            pulse.values = [0.44, 1.10, 0.44]
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.timingFunctions = [ease, ease]
            pulse.duration = period
            pulse.timeOffset = Double(index) * period / 6
            pulse.repeatCount = .infinity
            bar.add(pulse, forKey: pulseKey)
        }
    }

    private func updateRings(previousSessions: [SessionSnapshot]) {
        let palette = palette
        for (index, ring) in rings.enumerated() {
            let visible = sessions.indices.contains(index)
            ring.track.isHidden = !visible
            ring.progress.isHidden = !visible
            guard visible else {
                ring.progress.removeAnimation(forKey: "strokeEnd")
                continue
            }

            let session = sessions[index]
            let selected = index == selectedIndex
            let color = palette.ringColors[index]
            let width: CGFloat = selected ? 4.3 : 3.2
            ring.track.lineWidth = width
            ring.progress.lineWidth = width
            ring.track.strokeColor = (selected ? color.withAlphaComponent(0.22) : palette.track).cgColor
            ring.progress.strokeColor = color.withAlphaComponent(session.reading == nil ? 0.65 : 1).cgColor
            let fraction = session.reading.map { reading in
                let speed = CGFloat(reading.value)
                return max(0.025, speed / (speed + 55))
            } ?? 0.001

            let sameSession = previousSessions.indices.contains(index) && previousSessions[index].id == session.id
            if !sameSession { ring.progress.removeAnimation(forKey: "strokeEnd") }
            guard ring.progress.strokeEnd != fraction else { continue }
            let visibleEnd = ring.progress.presentation()?.strokeEnd ?? ring.progress.strokeEnd
            ring.progress.strokeEnd = fraction
            if canAnimate && sameSession {
                let glide = CABasicAnimation(keyPath: "strokeEnd")
                glide.fromValue = visibleEnd
                glide.toValue = fraction
                glide.duration = 0.42
                glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ring.progress.add(glide, forKey: "strokeEnd")
            }
        }
    }

    func draw() {
        let palette = palette
        let center = OrbLayout.center
        palette.face.setFill()
        NSBezierPath(ovalIn: OrbLayout.bounds.insetBy(dx: 1, dy: 1)).fill()

        if let reading = state.reading {
            drawValue(reading)
        } else if !isInstrument {
            let accent = selectedColor ?? palette.ringColors[0]
            accent.withAlphaComponent(state == .standby ? 0.6 : 1).setFill()
            let indicator = NSRect(x: center.x - 7, y: center.y - 9, width: 14, height: 4)
            NSBezierPath(roundedRect: indicator, xRadius: 2, yRadius: 2).fill()
        }

        let caption = NSAttributedString(string: state.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.muted,
            .kern: state == .standby ? 1.5 : 0.55,
        ])
        let captionSize = caption.size()
        let captionOffset: CGFloat = if state.reading != nil { 17 } else { isInstrument ? 15 : 10 }
        caption.draw(at: CGPoint(x: center.x - captionSize.width / 2,
                                 y: center.y + captionOffset - captionSize.height / 2))
    }

    private func drawValue(_ reading: RateReading) {
        let baseSize: CGFloat = isInstrument ? 34 : 37
        let number = NSMutableAttributedString(string: reading.displayValue, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold),
            .foregroundColor: selectedColor ?? palette.text,
            .kern: -0.65,
        ])
        let innerRadius = OrbLayout.ringRadius(at: max(0, sessions.count - 1))
        let availableWidth = min(80, 2 * (innerRadius - 6))
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * availableWidth / numberWidth, weight: .semibold)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }

        let size = number.size()
        let center = OrbLayout.center
        number.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - 6 - size.height / 2))
    }
}
