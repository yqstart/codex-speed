import AppKit
import CoreGraphics
import Foundation

struct IconArtwork {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let scale: CGFloat = 1024
    private static let center = CGPoint(x: 512, y: 514)

    static func render(pixels: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw IconError.render }
        let ratio = CGFloat(pixels) / scale
        context.scaleBy(x: ratio, y: ratio)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        drawCase(in: context, detailed: pixels >= 64)
        drawDial(in: context, detailed: pixels >= 64)

        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw IconError.render
        }
        return png
    }

    private static func drawCase(in context: CGContext, detailed: Bool) {
        let rect = CGRect(x: 96, y: 104, width: 832, height: 832)
        let outline = CGPath(roundedRect: rect, cornerWidth: 191, cornerHeight: 191, transform: nil)
        if detailed {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: color(0x000000, alpha: 0.37))
            context.setFillColor(color(0x12151E))
            context.addPath(outline)
            context.fillPath()
            context.restoreGState()
        }

        let top = CGPoint(x: 172, y: 941)
        let bottom = CGPoint(x: 888, y: 126)
        fill(outline, in: context, from: color(0x69717E), to: color(0x222630), start: top, end: bottom)
        let inset: CGFloat = detailed ? 11 : 16
        let face = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                          cornerWidth: 191 - inset, cornerHeight: 191 - inset, transform: nil)
        fill(face, in: context, from: color(0x353B49), to: color(0x11141D), start: top, end: bottom)
    }

    private static func drawDial(in context: CGContext, detailed: Bool) {
        let radius: CGFloat = 296
        let dialRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let dial = CGPath(ellipseIn: dialRect, transform: nil)
        fill(dial, in: context, from: color(0x151923), to: color(0x252B37),
             start: CGPoint(x: 375, y: 778), end: CGPoint(x: 709, y: 236))

        // 小尺寸加粗弧线和指针，轮廓缩小后仍然清楚。
        let lineWidth: CGFloat = detailed ? 34 : 53
        let track = arc(from: 220, to: -40)
        let progress = arc(from: 220, to: 50)
        context.setLineCap(.round)
        context.setStrokeColor(color(0x454C5C))
        context.setLineWidth(lineWidth)
        context.addPath(track)
        context.strokePath()

        if detailed {
            context.setStrokeColor(color(0xFFAB54, alpha: 0.13))
            context.setLineWidth(66)
            context.addPath(progress)
            context.strokePath()
        }
        let progressShape = progress.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        fill(progressShape, in: context, from: color(0xF39A47), to: color(0xFFCA80),
             start: CGPoint(x: 274, y: 348), end: CGPoint(x: 639, y: 742))

        let angle = radians(50)
        let length: CGFloat = detailed ? 191 : 177
        let halfWidth: CGFloat = detailed ? 29 : 38
        let needle = CGMutablePath()
        needle.move(to: point(along: length, across: 0, angle: angle))
        needle.addLine(to: point(along: -25, across: halfWidth, angle: angle))
        needle.addLine(to: point(along: -25, across: -halfWidth, angle: angle))
        needle.closeSubpath()
        fill(needle, in: context, from: color(0xFFAC55), to: color(0xFFE2B5),
             start: center, end: point(along: length, across: 0, angle: angle))

        let hubRadius: CGFloat = detailed ? 41 : 44
        context.setFillColor(color(0xFFC378))
        context.fillEllipse(in: CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: 2 * hubRadius, height: 2 * hubRadius))
        if detailed {
            context.setFillColor(color(0x312B2F))
            context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
        }
    }

    private static func arc(from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: 248, startAngle: radians(start), endAngle: radians(end), clockwise: true)
        return path
    }

    private static func point(along: CGFloat, across: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + along * cos(angle) - across * sin(angle),
                y: center.y + along * sin(angle) + across * cos(angle))
    }

    private static func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

    private static func fill(_ path: CGPath, in context: CGContext, from first: CGColor, to last: CGColor, start: CGPoint, end: CGPoint) {
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [first, last] as CFArray, locations: nil)!
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}

enum IconError: LocalizedError {
    case render, package

    var errorDescription: String? {
        switch self {
        case .render: return "无法渲染应用图标。"
        case .package: return "无法生成 macOS 图标资源。"
        }
    }
}

func buildIcon(at output: URL) throws {
    let files = FileManager.default
    let work = files.temporaryDirectory.appendingPathComponent("codex-speed-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: work) }

    var rendered: [Int: Data] = [:]
    for points in [16, 32, 128, 256, 512] {
        for density in [1, 2] {
            let pixels = points * density
            let png = try rendered[pixels] ?? IconArtwork.render(pixels: pixels)
            rendered[pixels] = png
            let suffix = density == 2 ? "@2x" : ""
            try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw IconError.package }
}

do {
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.icns")
    try buildIcon(at: output)
    print("应用图标已生成到 \(output.path)")
} catch {
    FileHandle.standardError.write(Data("应用图标生成失败。\(error.localizedDescription)\n".utf8))
    exit(1)
}
