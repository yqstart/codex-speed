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
            case .measured: "词元/秒"
            }
        }

        var accessibilityValue: String {
            guard let reading else { return caption }
            let approximation = reading.estimated ? "约 " : ""
            return "\(approximation)\(reading.value) 词元每秒"
        }

        var sweepDuration: CFTimeInterval {
            switch self {
            case .standby: 5.8
            case .waiting: 2.7
            case .measured: 4.1
            }
        }
    }

    private struct Palette {
        let standby: NSColor
        let active: NSColor
        let text: NSColor
        let muted: NSColor
        let bezel: NSGradient?
        let face: NSGradient?

        static let light = Palette(
            standby: NSColor(srgbRed: 0.09, green: 0.40, blue: 0.81, alpha: 1),
            active: NSColor(srgbRed: 0.0, green: 0.48, blue: 0.40, alpha: 1),
            text: NSColor(srgbRed: 0.08, green: 0.18, blue: 0.30, alpha: 1),
            muted: NSColor(srgbRed: 0.23, green: 0.34, blue: 0.46, alpha: 1),
            bezel: NSGradient(
                starting: NSColor(srgbRed: 0.70, green: 0.79, blue: 0.88, alpha: 1),
                ending: NSColor(srgbRed: 0.49, green: 0.59, blue: 0.71, alpha: 1)
            ),
            face: NSGradient(
                starting: NSColor(srgbRed: 0.98, green: 0.993, blue: 1, alpha: 1),
                ending: NSColor(srgbRed: 0.86, green: 0.91, blue: 0.965, alpha: 1)
            )
        )

        static let dark = Palette(
            standby: NSColor(srgbRed: 0.41, green: 0.70, blue: 1, alpha: 1),
            active: NSColor(srgbRed: 0.40, green: 1, blue: 0.82, alpha: 1),
            text: NSColor(srgbRed: 0.92, green: 0.97, blue: 1, alpha: 1),
            muted: NSColor(srgbRed: 0.63, green: 0.75, blue: 0.86, alpha: 1),
            bezel: NSGradient(
                starting: NSColor(srgbRed: 0.35, green: 0.47, blue: 0.62, alpha: 1),
                ending: NSColor(srgbRed: 0.12, green: 0.18, blue: 0.26, alpha: 1)
            ),
            face: NSGradient(
                starting: NSColor(srgbRed: 0.105, green: 0.164, blue: 0.26, alpha: 1),
                ending: NSColor(srgbRed: 0.027, green: 0.045, blue: 0.084, alpha: 1)
            )
        )
    }

    static let size: CGFloat = 116
    private static let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    private static let center = CGPoint(x: size / 2, y: size / 2)
    private static let orbitPath = CGPath(ellipseIn: bounds.insetBy(dx: 3.6, dy: 3.6), transform: nil)
    private static let faceBounds = bounds.insetBy(dx: 7, dy: 7)
    private static let gaugeRadius: CGFloat = 44.5
    private static let gaugeStart: CGFloat = 145 * .pi / 180
    private static let gaugeSweep: CGFloat = 250 * .pi / 180
    private static let gaugePath: CGPath = {
        let path = CGMutablePath()
        path.addArc(center: center, radius: gaugeRadius, startAngle: gaugeStart,
                    endAngle: gaugeStart + gaugeSweep, clockwise: false)
        return path
    }()

    private static let restAngle = -CGFloat.pi * 0.35
    private static let barHeights: [CGFloat] = [4, 9, 15, 9, 4]

    let layer = CALayer()
    private let orbit = CAGradientLayer()
    private let signal = CALayer()
    private let ripple = CAShapeLayer()
    private let bars = barHeights.map { _ in CALayer() }
    private let glow = CAShapeLayer()
    private let progress = CAShapeLayer()
    private var colorScheme: NSAppearance.Name
    private var palette: Palette { colorScheme == .darkAqua ? .dark : .light }
    private var motionEnabled = false
    private(set) var state = State.standby

    init(appearance: NSAppearance) {
        colorScheme = Self.colorScheme(for: appearance)
        layer.frame = Self.bounds

        let orbitMask = CAShapeLayer()
        orbitMask.frame = Self.bounds
        orbitMask.path = Self.orbitPath
        orbitMask.fillColor = nil
        orbitMask.strokeColor = NSColor.white.cgColor
        orbitMask.lineWidth = 1.8
        orbit.type = .conic
        orbit.frame = Self.bounds
        orbit.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbit.endPoint = CGPoint(x: 1, y: 0.5)
        orbit.locations = [0, 0.60, 0.69, 0.81, 0.93, 0.946, 1]
        orbit.mask = orbitMask
        orbit.transform = CATransform3DMakeRotation(Self.restAngle, 0, 0, 1)
        layer.addSublayer(orbit)

        for arc in [glow, progress] {
            arc.frame = Self.bounds
            arc.path = Self.gaugePath
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeEnd = 0
            layer.addSublayer(arc)
        }
        glow.lineWidth = 5
        progress.lineWidth = 2

        let signalCenter = CGPoint(x: Self.center.x, y: Self.center.y - 7)
        signal.frame = Self.bounds
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
        applyPalette()
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
        applyPalette()
        CATransaction.commit()
        return true
    }

    func show(_ newState: State) {
        let previous = state
        state = newState

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 刷新读数时沿用外圈流光的当前相位。
        switch (previous, newState) {
        case (.measured, .measured): break
        default:
            updateStateAppearance()
            updateAmbientMotion()
        }
        updateProgress()
        CATransaction.commit()
    }

    func setMotionEnabled(_ enabled: Bool) {
        guard enabled != motionEnabled else { return }
        motionEnabled = enabled
        updateAmbientMotion()
        if !enabled {
            glow.removeAnimation(forKey: "strokeEnd")
            progress.removeAnimation(forKey: "strokeEnd")
        }
    }

    private func applyPalette() {
        let palette = palette
        let signalColor = palette.standby.cgColor
        ripple.strokeColor = signalColor
        for bar in bars { bar.backgroundColor = signalColor }
        glow.strokeColor = palette.active.withAlphaComponent(0.20).cgColor
        progress.strokeColor = palette.active.cgColor
        updateStateAppearance()
    }

    private func updateStateAppearance() {
        let accent = state.reading == nil ? palette.standby : palette.active
        orbit.colors = [0, 0, 0.08, 0.34, 1, 0, 0].map { accent.withAlphaComponent($0).cgColor }
        signal.isHidden = state.reading != nil
        signal.opacity = state == .standby ? 0.82 : 1
    }

    private func updateAmbientMotion() {
        let rotationKey = "transform.rotation.z"
        if motionEnabled {
            let rotation = CABasicAnimation(keyPath: rotationKey)
            rotation.fromValue = orbit.presentation()?.value(forKeyPath: rotationKey) ?? Self.restAngle
            rotation.byValue = 2 * CGFloat.pi
            rotation.duration = state.sweepDuration
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            orbit.add(rotation, forKey: rotationKey)
        } else {
            orbit.removeAnimation(forKey: rotationKey)
        }

        let pulseKey = "transform.scale.y"
        guard motionEnabled && state.reading == nil else {
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

    private func updateProgress() {
        let fraction = state.reading.map { reading in
            let speed = CGFloat(reading.value)
            return max(0.025, speed / (speed + 55))
        } ?? 0

        for arc in [glow, progress] {
            guard arc.strokeEnd != fraction else { continue }
            let visibleEnd = arc.presentation()?.strokeEnd ?? arc.strokeEnd
            arc.strokeEnd = fraction
            if motionEnabled {
                let glide = CABasicAnimation(keyPath: "strokeEnd")
                glide.fromValue = visibleEnd
                glide.toValue = fraction
                glide.duration = 0.42
                glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                arc.add(glide, forKey: "strokeEnd")
            }
        }
    }

    func draw() {
        let palette = palette
        palette.bezel?.draw(in: NSBezierPath(ovalIn: Self.faceBounds), angle: 74)
        let face = NSBezierPath(ovalIn: Self.faceBounds.insetBy(dx: 1.15, dy: 1.15))
        palette.face?.draw(in: face, relativeCenterPosition: NSPoint(x: -0.17, y: -0.27))
        drawMarkings()

        if let reading = state.reading { drawValue(reading) }
        let caption = NSAttributedString(string: state.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.muted,
            .kern: state == .standby ? 1.5 : 0.55,
        ])
        let captionSize = caption.size()
        caption.draw(at: CGPoint(x: Self.center.x - captionSize.width / 2,
                                 y: Self.center.y + 17 - captionSize.height / 2))
    }

    private func drawMarkings() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = palette
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(0.7)
        context.setStrokeColor(palette.standby.withAlphaComponent(0.18).cgColor)
        context.addPath(Self.orbitPath)
        context.strokePath()
        context.setLineWidth(1)
        context.setStrokeColor(palette.muted.withAlphaComponent(0.21).cgColor)
        context.addPath(Self.gaugePath)
        context.strokePath()

        for tick in 0...24 {
            let angle = Self.gaugeStart + Self.gaugeSweep * CGFloat(tick) / 24
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let outerRadius = Self.gaugeRadius - 3.3
            let major = tick.isMultiple(of: 6)
            let innerRadius = outerRadius - (major ? 3.6 : 1.7)
            context.move(to: CGPoint(x: Self.center.x + direction.x * outerRadius,
                                     y: Self.center.y + direction.y * outerRadius))
            context.addLine(to: CGPoint(x: Self.center.x + direction.x * innerRadius,
                                        y: Self.center.y + direction.y * innerRadius))
            context.setLineWidth(major ? 1 : 0.65)
            context.setStrokeColor(palette.muted.withAlphaComponent(major ? 0.59 : 0.31).cgColor)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawValue(_ reading: RateReading) {
        let palette = palette
        let mark = reading.estimated ? NSAttributedString(string: "≈", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: palette.active,
        ]) : nil
        let markWidth = mark.map { $0.size().width + 3 } ?? 0
        let baseSize: CGFloat = 31
        let number = NSMutableAttributedString(string: String(reading.value), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold),
            .foregroundColor: palette.text,
            .kern: -0.65,
        ])
        let availableWidth = 72 - markWidth
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * availableWidth / numberWidth, weight: .semibold)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }

        let measured = number.size()
        let left = Self.center.x - (measured.width + markWidth) / 2
        let centerY = Self.center.y - 6
        number.draw(at: CGPoint(x: left + markWidth, y: centerY - measured.height / 2))
        if let mark {
            mark.draw(at: CGPoint(x: left, y: centerY - mark.size().height / 2 + 1))
        }
    }
}
