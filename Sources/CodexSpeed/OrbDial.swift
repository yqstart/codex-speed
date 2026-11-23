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

    struct Presentation: Equatable {
        enum Source: String {
            case current = "当前会话"
            case pinned = "已固定"
            case recent = "最近活跃"
        }

        static let standby = Presentation(session: nil, source: nil, state: .standby, parallelCount: 0)

        let session: SessionSnapshot?
        let source: Source?
        let state: State
        let parallelCount: Int
    }

    private struct Palette {
        let face: NSColor
        let text: NSColor
        let muted: NSColor
        let track: NSColor
        let accent: NSColor

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
            accent: color(0x405fd1)
        )

        static let dark = Palette(
            face: color(0x171e2b),
            text: color(0xecf2fb),
            muted: color(0xabbad0),
            track: color(0x323e50),
            accent: color(0x839fff)
        )
    }

    private static let barHeights: [CGFloat] = [4, 9, 15, 9, 4]

    let layer = CALayer()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let signal = CALayer()
    private let ripple = CAShapeLayer()
    private let bars = barHeights.map { _ in CALayer() }
    private var colorScheme: NSAppearance.Name
    private var palette: Palette { colorScheme == .darkAqua ? .dark : .light }
    private var sessionAccent: NSColor {
        presentation.source == .current || presentation.source == .pinned ? palette.accent : palette.muted
    }
    private var style: OrbSettings.Style
    private var isInstrument: Bool { style == .instrument }
    private var motionEnabled = false
    private var canAnimate: Bool { motionEnabled && isInstrument }
    private(set) var presentation = Presentation.standby

    init(appearance: NSAppearance, style: OrbSettings.Style) {
        colorScheme = Self.colorScheme(for: appearance)
        self.style = style
        layer.frame = OrbLayout.bounds

        let ringInset: CGFloat = 5
        let radius = OrbLayout.baseDiameter / 2 - ringInset
        track.path = CGPath(ellipseIn: OrbLayout.bounds.insetBy(dx: ringInset, dy: ringInset), transform: nil)
        let arc = CGMutablePath()
        arc.addRelativeArc(center: OrbLayout.center, radius: radius, startAngle: -.pi / 2, delta: 2 * .pi)
        progress.path = arc
        progress.strokeEnd = 0
        progress.lineCap = .round
        for shape in [track, progress] {
            shape.frame = OrbLayout.bounds
            shape.fillColor = nil
            layer.addSublayer(shape)
        }

        let signalCenter = CGPoint(x: OrbLayout.center.x, y: 59)
        signal.frame = OrbLayout.bounds
        ripple.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
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
        updateRing(animate: false)
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
        updateRing(animate: false)
        CATransaction.commit()
        return true
    }

    func setStyle(_ style: OrbSettings.Style) -> Bool {
        guard self.style != style else { return false }
        self.style = style

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateRing(animate: false)
        CATransaction.commit()
        refreshMotion()
        return true
    }

    func show(_ next: Presentation) -> Bool {
        guard presentation != next else { return false }
        let previous = presentation
        presentation = next

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let continuesReading = previous.session?.id == next.session?.id
            && previous.state.reading != nil && next.state.reading != nil
        updateRing(animate: continuesReading && canAnimate)
        if previous.source != next.source { updateSignalColor() }
        if previous.state != next.state && (previous.state.reading == nil || next.state.reading == nil) {
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
        if !canAnimate { progress.removeAnimation(forKey: "strokeEnd") }
        CATransaction.commit()
    }

    private func updateSignalColor() {
        let color = sessionAccent.cgColor
        ripple.strokeColor = color
        for bar in bars { bar.backgroundColor = color }
    }

    private func updateSignal() {
        let state = presentation.state
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

    private func updateRing(animate: Bool) {
        let width: CGFloat = isInstrument ? 4.3 : 2.8
        track.lineWidth = width
        progress.lineWidth = width
        track.strokeColor = palette.track.cgColor
        progress.strokeColor = sessionAccent.cgColor
        let fraction = presentation.state.reading.map { reading in
            let speed = CGFloat(reading.value)
            return max(0.025, speed / (speed + 55))
        } ?? 0

        if !animate { progress.removeAnimation(forKey: "strokeEnd") }
        guard progress.strokeEnd != fraction else { return }
        let visibleEnd = progress.presentation()?.strokeEnd ?? progress.strokeEnd
        progress.strokeEnd = fraction
        guard animate else { return }

        let glide = CABasicAnimation(keyPath: "strokeEnd")
        glide.fromValue = visibleEnd
        glide.toValue = fraction
        glide.duration = 0.42
        glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        progress.add(glide, forKey: "strokeEnd")
    }

    func draw() {
        let palette = palette
        palette.face.setFill()
        NSBezierPath(ovalIn: OrbLayout.bounds.insetBy(dx: 1, dy: 1)).fill()

        if let source = presentation.source, let title = presentation.session?.title {
            drawLine(source.rawValue, at: 22, font: .systemFont(ofSize: 9, weight: .semibold), color: sessionAccent)
            drawLine(title, at: 36, font: .systemFont(ofSize: 12, weight: .semibold), color: palette.text)
        }

        let state = presentation.state
        if let reading = state.reading {
            drawValue(reading)
            let unit = reading.estimated ? "约 \(RateReading.unit)" : RateReading.unit
            drawLine(unit, at: 80, font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: palette.muted)
        } else {
            let font = NSFont.systemFont(ofSize: isInstrument ? 11 : 15, weight: .medium)
            drawLine(state.caption, at: isInstrument ? 79 : 61, font: font, color: palette.muted)
        }

        if presentation.parallelCount > 0 {
            let badge = OrbLayout.parallelBadge
            palette.track.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            drawLine("并行 \(presentation.parallelCount)", at: badge.midY, width: badge.width,
                     font: .systemFont(ofSize: 9, weight: .medium), color: palette.muted)
        }
    }

    private func drawLine(_ text: String, at y: CGFloat, width: CGFloat = 80, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let line = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let height = ceil(line.size().height)
        let frame = CGRect(x: OrbLayout.center.x - width / 2, y: y - height / 2, width: width, height: height)
        line.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawValue(_ reading: RateReading) {
        let baseSize: CGFloat = isInstrument ? 32 : 34
        let number = NSMutableAttributedString(string: reading.displayValue, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold),
            .foregroundColor: presentation.source == .recent ? palette.text : sessionAccent,
            .kern: -0.65,
        ])
        let availableWidth: CGFloat = 82
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * availableWidth / numberWidth, weight: .semibold)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }

        let size = number.size()
        number.draw(at: CGPoint(x: OrbLayout.center.x - size.width / 2, y: 60 - size.height / 2))
    }
}
