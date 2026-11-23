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

    private struct Tint {
        let ink: NSColor
        let low: NSColor
        let high: NSColor

        init(_ ink: UInt32, _ low: UInt32, _ high: UInt32) {
            self.ink = Palette.color(ink)
            self.low = Palette.color(low)
            self.high = Palette.color(high)
        }
    }

    private struct Palette {
        let faceTop: NSColor
        let faceBottom: NSColor
        let text: NSColor
        let muted: NSColor
        let edge: NSColor
        let track: NSColor
        let current: Tint
        let pinned: Tint
        let neutral: Tint

        static func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                    green: CGFloat((rgb >> 8) & 0xff) / 255,
                    blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        }

        static let light = Palette(
            faceTop: color(0xfafdfd), faceBottom: color(0xcfdee2),
            text: color(0x10252d), muted: color(0x3c565f),
            edge: color(0x718f96), track: color(0xb0c6cb),
            current: Tint(0x075c4a, 0x16665e, 0x0fb88b),
            pinned: Tint(0x754a10, 0x8d5418, 0xefaa39),
            neutral: Tint(0x375666, 0x436777, 0x6e9fb5)
        )

        static let dark = Palette(
            faceTop: color(0x202e37), faceBottom: color(0x080c11),
            text: color(0xeafff7), muted: color(0xa7bbc1),
            edge: color(0x526970), track: color(0x29414a),
            current: Tint(0x79ffdc, 0x118078, 0x5bffd4),
            pinned: Tint(0xffce86, 0xa15e18, 0xffc36e),
            neutral: Tint(0xb4cbd7, 0x4e7083, 0xa4c6db)
        )
    }

    private enum ArcMotion { case none, glide, charge }

    private static let arcRadius: CGFloat = 48.7
    private static let orbitRadius: CGFloat = 54.7
    private static let barHeights: [CGFloat] = [4, 9, 16, 9, 4]

    let layer = CALayer()
    private let ticks = CAShapeLayer()
    private let track = CAShapeLayer()
    private let arcGlow = CAShapeLayer()
    private let arcGradient = CAGradientLayer()
    private let arcMask = CAShapeLayer()
    private let arcHead = CALayer()
    private let arcLight = CALayer()
    private let rotor = CALayer()
    private let orbitTail = CAShapeLayer()
    private let orbitLight = CALayer()
    private let focusFlash = CAShapeLayer()
    private let signal = CALayer()
    private let ripple = CAShapeLayer()
    private let idleLight = CALayer()
    private let bars = barHeights.map { _ in CALayer() }

    private var colorScheme: NSAppearance.Name
    private var isDark: Bool { colorScheme == .darkAqua }
    private var palette: Palette { isDark ? .dark : .light }
    private var tint: Tint {
        switch presentation.source {
        case .current: palette.current
        case .pinned: palette.pinned
        case .recent, nil: palette.neutral
        }
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
        configureLayers()
        updateColors()
        updateRing(motion: .none)
        updateOrbit()
        updateSignal()
    }

    private static func colorScheme(for appearance: NSAppearance) -> NSAppearance.Name {
        appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }

    private static func arc(radius: CGFloat, start: CGFloat = -.pi / 2, sweep: CGFloat = 2 * .pi) -> CGPath {
        let arc = CGMutablePath()
        arc.addRelativeArc(center: OrbLayout.center, radius: radius, startAngle: start, delta: sweep)
        return arc
    }

    private func configureLayers() {
        let frame = OrbLayout.bounds
        let center = OrbLayout.center
        let arc = Self.arc(radius: Self.arcRadius)
        for shape in [ticks, track, arcGlow, arcMask, focusFlash] {
            shape.frame = frame
            shape.fillColor = nil
            shape.lineCap = .round
        }

        let dialTicks = CGMutablePath()
        for index in 0..<48 {
            let angle = CGFloat(index) * .pi / 24 - .pi / 2
            let vector = CGPoint(x: cos(angle), y: sin(angle))
            let innerRadius: CGFloat = index.isMultiple(of: 4) ? 50.9 : 52.5
            dialTicks.move(to: CGPoint(x: center.x + vector.x * innerRadius, y: center.y + vector.y * innerRadius))
            dialTicks.addLine(to: CGPoint(x: center.x + vector.x * 53.8, y: center.y + vector.y * 53.8))
        }
        ticks.path = dialTicks
        ticks.lineWidth = 0.7
        layer.addSublayer(ticks)

        track.path = arc
        arcGlow.path = arc
        arcGlow.shadowRadius = 3.1
        arcGlow.shadowOffset = .zero
        arcMask.path = arc
        arcMask.strokeColor = NSColor.white.cgColor
        arcMask.strokeEnd = 0
        arcGlow.strokeEnd = 0

        arcGradient.frame = frame
        arcGradient.startPoint = CGPoint(x: 0.82, y: 0.12)
        arcGradient.endPoint = CGPoint(x: 0.12, y: 0.86)
        arcGradient.mask = arcMask

        arcHead.frame = frame
        arcLight.bounds = CGRect(x: 0, y: 0, width: 3.9, height: 3.9)
        arcLight.cornerRadius = 1.95
        arcLight.position = CGPoint(x: center.x, y: center.y - Self.arcRadius)
        arcLight.shadowOffset = .zero
        arcLight.shadowRadius = 2.8
        arcLight.shadowOpacity = 0.95
        arcHead.addSublayer(arcLight)

        rotor.frame = frame
        orbitTail.frame = frame
        orbitTail.path = Self.arc(radius: Self.orbitRadius, start: -.pi / 2 - 0.76, sweep: 0.76)
        orbitTail.fillColor = nil
        orbitTail.lineWidth = 1.15
        orbitTail.lineCap = .round
        orbitLight.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 2.5)
        orbitLight.position = CGPoint(x: center.x, y: center.y - Self.orbitRadius)
        orbitLight.cornerRadius = 1.25
        orbitLight.shadowOffset = .zero
        orbitLight.shadowRadius = 2
        orbitLight.shadowOpacity = 0.8
        rotor.addSublayer(orbitTail)
        rotor.addSublayer(orbitLight)

        focusFlash.path = Self.arc(radius: 45)
        focusFlash.lineWidth = 1.1
        focusFlash.opacity = 0
        for effect in [track, arcGlow, arcGradient, arcHead, rotor, focusFlash] {
            layer.addSublayer(effect)
        }

        signal.frame = frame
        let signalCenter = CGPoint(x: center.x, y: 59)
        idleLight.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        idleLight.position = signalCenter
        idleLight.cornerRadius = 2.5
        idleLight.shadowRadius = 5
        idleLight.shadowOffset = .zero
        idleLight.shadowOpacity = 0.8
        idleLight.opacity = 0.74
        signal.addSublayer(idleLight)

        ripple.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        ripple.position = signalCenter
        ripple.path = CGPath(ellipseIn: ripple.bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        ripple.fillColor = nil
        ripple.lineWidth = 0.8
        ripple.opacity = 0
        signal.addSublayer(ripple)
        for (index, bar) in bars.enumerated() {
            let offset = CGFloat(index - bars.count / 2) * 5.1
            bar.bounds = CGRect(x: 0, y: 0, width: 2.2, height: Self.barHeights[index])
            bar.position = CGPoint(x: signalCenter.x + offset, y: signalCenter.y)
            bar.cornerRadius = 1.1
            signal.addSublayer(bar)
        }
        layer.addSublayer(signal)
    }

    func setAppearance(_ appearance: NSAppearance) -> Bool {
        let newScheme = Self.colorScheme(for: appearance)
        guard colorScheme != newScheme else { return false }
        colorScheme = newScheme

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateColors()
        CATransaction.commit()
        return true
    }

    func setStyle(_ style: OrbSettings.Style) -> Bool {
        guard self.style != style else { return false }
        self.style = style
        refreshMotion()
        return true
    }

    func show(_ next: Presentation) -> Bool {
        guard presentation != next else { return false }
        let previous = presentation
        let switchedSession = previous.session?.id != next.session?.id
        presentation = next

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if previous.source != next.source { updateColors() }
        let motion: ArcMotion = if !canAnimate || next.state.reading == nil {
            .none
        } else if switchedSession || previous.state.reading == nil {
            .charge
        } else {
            .glide
        }
        updateRing(motion: motion)
        updateOrbit()
        if previous.state != next.state && (previous.state.reading == nil || next.state.reading == nil) {
            updateSignal()
        }
        if canAnimate, switchedSession, next.session != nil {
            pulse(focusFlash, from: 0.78, to: 1.15, peak: 0.84, duration: 0.58, repeats: false)
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
        updateRing(motion: .none)
        updateOrbit()
        updateSignal()
        if !canAnimate { focusFlash.removeAllAnimations() }
        CATransaction.commit()
    }

    private func updateColors() {
        let tint = tint
        let palette = palette
        ticks.strokeColor = palette.edge.withAlphaComponent(0.75).cgColor
        track.strokeColor = palette.track.cgColor
        arcGradient.colors = [tint.low.cgColor, tint.high.cgColor]
        arcGlow.strokeColor = tint.high.withAlphaComponent(0.42).cgColor
        arcGlow.shadowColor = tint.high.cgColor
        arcLight.backgroundColor = palette.text.cgColor
        arcLight.shadowColor = tint.high.cgColor
        orbitTail.strokeColor = tint.high.withAlphaComponent(0.76).cgColor
        orbitLight.backgroundColor = tint.high.cgColor
        orbitLight.shadowColor = tint.high.cgColor
        focusFlash.strokeColor = tint.high.cgColor
        idleLight.backgroundColor = tint.ink.cgColor
        idleLight.shadowColor = tint.high.cgColor
        ripple.strokeColor = tint.high.cgColor
        for bar in bars {
            bar.backgroundColor = tint.ink.cgColor
        }
    }

    private var rateFraction: CGFloat {
        guard let reading = presentation.state.reading else { return 0 }
        let speed = CGFloat(reading.value)
        return max(0.025, speed / (speed + 55))
    }

    private func updateRing(motion: ArcMotion) {
        let fraction = rateFraction
        let oldFraction = arcMask.strokeEnd
        let isMeasured = presentation.state.reading != nil
        ticks.isHidden = !isInstrument
        track.lineWidth = isInstrument ? 2.8 : 2
        arcMask.lineWidth = isInstrument ? 3.4 : 2.4
        arcGlow.lineWidth = 4.5
        arcGlow.shadowOpacity = isInstrument && isDark ? 0.9 : 0
        arcGlow.isHidden = !isInstrument
        arcHead.isHidden = !isInstrument || !isMeasured
        let from = motion == .charge ? 0 : arcMask.presentation()?.strokeEnd ?? oldFraction

        if motion != .glide {
            arcMask.removeAllAnimations()
            arcGlow.removeAllAnimations()
            arcHead.removeAllAnimations()
        }
        guard oldFraction != fraction || motion == .charge else { return }
        arcMask.strokeEnd = fraction
        arcGlow.strokeEnd = fraction
        arcHead.transform = CATransform3DMakeRotation(fraction * 2 * .pi, 0, 0, 1)
        guard motion != .none, from != fraction else { return }

        let duration = motion == .charge ? 0.53 : 0.36
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = from
        fill.toValue = fraction
        fill.duration = duration
        fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
        arcMask.add(fill, forKey: "reading")
        arcGlow.add(fill, forKey: "reading")

        let advance = CABasicAnimation(keyPath: "transform.rotation.z")
        advance.fromValue = from * 2 * .pi
        advance.toValue = fraction * 2 * .pi
        advance.duration = duration
        advance.timingFunction = fill.timingFunction
        arcHead.add(advance, forKey: "reading")
    }

    private func updateOrbit() {
        let spinning = canAnimate && presentation.state != .standby
        rotor.isHidden = !spinning
        guard spinning else {
            rotor.removeAnimation(forKey: "orbit")
            return
        }

        let speed = presentation.state == .waiting ? 0.68 : Float(0.62 + rateFraction * 1.68)
        if rotor.speed != speed {
            // 更新转速时保留彗星在圆周上的位置。
            let now = CACurrentMediaTime()
            let localTime = rotor.convertTime(now, from: nil)
            rotor.beginTime = layer.convertTime(now, from: nil)
            rotor.timeOffset = localTime
            rotor.speed = speed
        }

        guard rotor.animation(forKey: "orbit") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 3.2
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        rotor.add(spin, forKey: "orbit")
    }

    private func updateSignal() {
        let idle = presentation.state == .standby
        let waiting = presentation.state == .waiting
        signal.isHidden = !isInstrument || !(idle || waiting)
        idleLight.isHidden = !idle
        idleLight.removeAllAnimations()
        ripple.removeAllAnimations()
        for bar in bars {
            bar.isHidden = !waiting
            bar.removeAllAnimations()
        }
        guard canAnimate, idle || waiting else { return }

        if idle {
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [0.32, 0.94, 0.32]
            breathe.duration = 2.6
            breathe.repeatCount = .infinity
            idleLight.add(breathe, forKey: "breathe")
            return
        }

        let period = 1.34
        pulse(ripple, from: 0.72, to: 1.27, peak: 0.65, duration: period, repeats: true)
        for (index, bar) in bars.enumerated() {
            let wave = CAKeyframeAnimation(keyPath: "transform.scale.y")
            wave.values = [0.44, 1.12, 0.44]
            let ease = CAMediaTimingFunction(name: .easeInEaseOut)
            wave.timingFunctions = [ease, ease]
            wave.duration = period
            wave.timeOffset = Double(index) * period / 7
            wave.repeatCount = .infinity
            bar.add(wave, forKey: "signal")
        }
    }

    private func pulse(_ shape: CAShapeLayer, from: CGFloat, to: CGFloat, peak: Double, duration: Double, repeats: Bool) {
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = from
        expand.toValue = to
        expand.duration = duration
        expand.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, peak, 0]
        fade.keyTimes = [0, 0.22, 1]
        fade.duration = duration
        let group = CAAnimationGroup()
        group.animations = [expand, fade]
        group.duration = duration
        group.repeatCount = repeats ? .infinity : 0
        shape.add(group, forKey: "pulse")
    }

    func draw() {
        let palette = palette
        let tint = tint
        let face = NSBezierPath(ovalIn: OrbLayout.bounds.insetBy(dx: 0.8, dy: 0.8))
        NSGradient(starting: palette.faceTop, ending: palette.faceBottom)?.draw(in: face, angle: 90)
        if isInstrument {
            let bloom = tint.low.withAlphaComponent(isDark ? 0.44 : 0.17)
            NSGradient(starting: bloom, ending: bloom.withAlphaComponent(0))?
                .draw(in: face, relativeCenterPosition: CGPoint(x: -0.47, y: -0.51))
        }
        let bezel = NSBezierPath(ovalIn: OrbLayout.bounds.insetBy(dx: 1.45, dy: 1.45))
        palette.edge.withAlphaComponent(0.64).setStroke()
        bezel.lineWidth = 0.72
        bezel.stroke()

        if let source = presentation.source, let title = presentation.session?.title {
            drawSource(source)
            drawLine(title, at: 34.5, width: 77, font: .systemFont(ofSize: 11.2, weight: .semibold), color: palette.text)
        }

        let state = presentation.state
        if let reading = state.reading {
            drawValue(reading)
            let unit = reading.estimated ? "约 \(RateReading.unit)" : RateReading.unit
            drawLine(unit, at: 80.5, font: .monospacedSystemFont(ofSize: 8.4, weight: .regular), color: palette.muted)
        } else {
            let font = NSFont.systemFont(ofSize: isInstrument ? 11 : 15, weight: .medium)
            drawLine(state.caption, at: isInstrument ? 80.5 : 61, font: font, color: palette.muted)
        }

        if presentation.parallelCount > 0 {
            let badge = OrbLayout.parallelBadge
            drawPill(badge, fill: palette.track.withAlphaComponent(isDark ? 0.58 : 0.50),
                     edge: palette.edge.withAlphaComponent(0.52))
            drawLine("并行 \(presentation.parallelCount)", at: badge.midY, width: badge.width,
                     font: .systemFont(ofSize: 9, weight: .semibold), color: palette.text)
        }
    }

    private func drawSource(_ source: Presentation.Source) {
        let font = NSFont.systemFont(ofSize: 8.6, weight: .medium)
        let label = source.rawValue
        let width = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let center = OrbLayout.center.x
        let y: CGFloat = 20
        let dot = CGRect(x: center - width / 2 - 3.2, y: y - 1.4, width: 2.8, height: 2.8)
        tint.ink.setFill()
        NSBezierPath(ovalIn: dot).fill()
        drawLine(label, at: y, x: center + 3.2, width: width + 4, font: font, color: tint.ink)
    }

    private func drawPill(_ rect: CGRect, fill: NSColor, edge: NSColor) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        fill.setFill()
        pill.fill()
        edge.setStroke()
        pill.lineWidth = 0.65
        pill.stroke()
    }

    private func drawLine(_ text: String, at y: CGFloat, x: CGFloat = OrbLayout.center.x, width: CGFloat = 80,
                          font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        let line = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let height = ceil(line.size().height)
        let frame = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        line.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawValue(_ reading: RateReading) {
        let baseSize: CGFloat = 30
        let weight = NSFont.Weight.semibold
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: weight),
            .foregroundColor: palette.text,
            .kern: -0.7,
        ]
        if isInstrument && isDark {
            let shadow = NSShadow()
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = 5
            shadow.shadowColor = tint.high.withAlphaComponent(0.34)
            attributes[.shadow] = shadow
        }

        let number = NSMutableAttributedString(string: reading.displayValue, attributes: attributes)
        let availableWidth: CGFloat = 77
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * availableWidth / numberWidth, weight: weight)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }

        let size = number.size()
        number.draw(at: CGPoint(x: OrbLayout.center.x - size.width / 2, y: 59.5 - size.height / 2))
    }
}
