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
        let seam: NSColor
        let reflection: NSColor

        private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                    green: CGFloat((rgb >> 8) & 0xff) / 255,
                    blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
        }

        static let light = Palette(
            standby: NSColor(srgbRed: 0.09, green: 0.40, blue: 0.81, alpha: 1),
            active: NSColor(srgbRed: 0.0, green: 0.48, blue: 0.40, alpha: 1),
            text: NSColor(srgbRed: 0.08, green: 0.18, blue: 0.30, alpha: 1),
            muted: NSColor(srgbRed: 0.23, green: 0.34, blue: 0.46, alpha: 1),
            bezel: NSGradient(colorsAndLocations: (color(0xf7fdff), 0), (color(0xadc4d8), 0.30),
                              (color(0x5c7792), 0.77), (color(0x8199b0), 1)),
            face: NSGradient(colorsAndLocations: (color(0xffffff), 0), (color(0xf1f8fd), 0.24),
                             (color(0xd5e5f1), 0.52), (color(0xa8c2d7), 0.80), (color(0x89a7c0), 1)),
            seam: color(0x426283, alpha: 0.41),
            reflection: color(0xffffff, alpha: 0.94)
        )

        static let dark = Palette(
            standby: NSColor(srgbRed: 0.41, green: 0.70, blue: 1, alpha: 1),
            active: NSColor(srgbRed: 0.40, green: 1, blue: 0.82, alpha: 1),
            text: NSColor(srgbRed: 0.92, green: 0.97, blue: 1, alpha: 1),
            muted: NSColor(srgbRed: 0.63, green: 0.75, blue: 0.86, alpha: 1),
            bezel: NSGradient(colorsAndLocations: (color(0x97b2ce), 0), (color(0x506d8b), 0.26),
                              (color(0x0e1d2d), 0.77), (color(0x344d64), 1)),
            face: NSGradient(colorsAndLocations: (color(0x50759a), 0), (color(0x354f6d), 0.24),
                             (color(0x192c43), 0.52), (color(0x0a1421), 0.80), (color(0x050b14), 1)),
            seam: color(0x050c16, alpha: 0.72),
            reflection: color(0xe0f1ff, alpha: 0.63)
        )
    }

    static let size = CGFloat(OrbSettings.defaultSize)
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
    private var style: OrbSettings.Style
    private var isInstrument: Bool { style == .instrument }
    private var motionEnabled = false
    private var canAnimate: Bool { motionEnabled && isInstrument }
    private(set) var state = State.standby

    init(appearance: NSAppearance, style: OrbSettings.Style) {
        colorScheme = Self.colorScheme(for: appearance)
        self.style = style
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

    func setStyle(_ style: OrbSettings.Style) -> Bool {
        guard self.style != style else { return false }
        self.style = style

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateStateAppearance()
        refreshMotion()
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
        refreshMotion()
    }

    private func refreshMotion() {
        updateAmbientMotion()
        if !canAnimate {
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
        orbit.isHidden = !isInstrument
        glow.isHidden = !isInstrument
        progress.isHidden = !isInstrument
        signal.isHidden = !isInstrument || state.reading != nil
        signal.opacity = state == .standby ? 0.82 : 1
    }

    private func updateAmbientMotion() {
        let rotationKey = "transform.rotation.z"
        if canAnimate {
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
        guard canAnimate && state.reading == nil else {
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
            if canAnimate {
                let glide = CABasicAnimation(keyPath: "strokeEnd")
                glide.fromValue = visibleEnd
                glide.toValue = fraction
                glide.duration = 0.42
                glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                arc.add(glide, forKey: "strokeEnd")
            }
        }
    }

    func draw(emphasized: Bool) {
        let palette = palette
        if emphasized {
            let outline = NSBezierPath(ovalIn: Self.faceBounds.insetBy(dx: -1.3, dy: -1.3))
            outline.lineWidth = 1.4
            let accent = state.reading == nil ? palette.standby : palette.active
            accent.withAlphaComponent(0.85).setStroke()
            outline.stroke()
        }
        drawSphere(in: Self.faceBounds, rimWidth: 3.1)
        if isInstrument { drawMarkings() }

        if let reading = state.reading {
            drawValue(reading)
        } else if !isInstrument {
            palette.standby.withAlphaComponent(state == .standby ? 0.6 : 1).setFill()
            let indicator = NSRect(x: Self.center.x - 7, y: Self.center.y - 9, width: 14, height: 4)
            NSBezierPath(roundedRect: indicator, xRadius: 2, yRadius: 2).fill()
        }
        let caption = NSAttributedString(string: state.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: palette.muted,
            .kern: state == .standby ? 1.5 : 0.55,
        ])
        let captionSize = caption.size()
        let captionOffset: CGFloat = if state.reading != nil { 22 } else { isInstrument ? 17 : 10 }
        caption.draw(at: CGPoint(x: Self.center.x - captionSize.width / 2,
                                 y: Self.center.y + captionOffset - captionSize.height / 2))
    }

    func drawBond(from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        let radius = 4.1 * scale
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let offset = CGPoint(x: (dx < 0 ? dy : -dy) * radius / length, y: -abs(dx) * radius / length)
        let bond = CGMutablePath()
        bond.move(to: start)
        bond.addLine(to: end)

        context.saveGState()
        context.addPath(bond.copy(strokingWithWidth: radius * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        context.clip()
        palette.bezel?.draw(from: CGPoint(x: mid.x + offset.x, y: mid.y + offset.y),
                            to: CGPoint(x: mid.x - offset.x, y: mid.y - offset.y),
                            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        context.restoreGState()
    }

    func drawSatellite(value: String, in rect: CGRect, subdued: Bool) {
        let palette = palette
        drawSphere(in: rect, rimWidth: rect.width * 0.041)

        let fontSize = rect.width * (subdued ? 0.34 : 0.39)
        let number = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: subdued ? palette.muted : palette.text,
        ])
        let availableWidth = rect.width * 0.83
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize * availableWidth / numberWidth, weight: .semibold)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }
        let size = number.size()
        number.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawSphere(in rect: CGRect, rimWidth: CGFloat) {
        let palette = palette
        palette.bezel?.draw(in: NSBezierPath(ovalIn: rect), angle: 62)

        let surface = rect.insetBy(dx: rimWidth, dy: rimWidth)
        let face = NSBezierPath(ovalIn: surface)
        palette.face?.draw(in: face, relativeCenterPosition: CGPoint(x: -0.44, y: -0.48))
        face.lineWidth = rimWidth * 0.39
        palette.seam.setStroke()
        face.stroke()

        let sheen = NSBezierPath()
        sheen.appendArc(withCenter: CGPoint(x: rect.midX, y: rect.midY),
                        radius: rect.width / 2 - rimWidth * 0.53, startAngle: 207, endAngle: 274)
        sheen.lineWidth = rimWidth * 0.31
        sheen.lineCapStyle = .round
        palette.reflection.setStroke()
        sheen.stroke()
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
        let baseSize: CGFloat = isInstrument ? 31 : 37
        let number = NSMutableAttributedString(string: reading.displayValue, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .semibold),
            .foregroundColor: palette.text,
            .kern: -0.65,
        ])
        let availableWidth: CGFloat = isInstrument ? 72 : 80
        let numberWidth = number.size().width
        if numberWidth > availableWidth {
            let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * availableWidth / numberWidth, weight: .semibold)
            number.addAttribute(.font, value: font, range: NSRange(location: 0, length: number.length))
        }

        let measured = number.size()
        let centerY = Self.center.y - 4
        number.draw(at: CGPoint(x: Self.center.x - measured.width / 2, y: centerY - measured.height / 2))
    }
}
