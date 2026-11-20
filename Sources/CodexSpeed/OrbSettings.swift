import AppKit

struct OrbSettings: Equatable {
    enum Style: String, CaseIterable {
        case instrument, minimal

        var title: String {
            switch self {
            case .instrument: "动态仪表"
            case .minimal: "简洁读数"
            }
        }
    }

    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }

        var name: NSAppearance.Name? {
            switch self {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    static let defaultSize = 116.0
    static let sizeRange = 84.0...176.0
    private static let defaultsKey = "orbSettings"

    var size: Double
    var style: Style
    var appearance: Appearance

    init(defaults: UserDefaults = .standard) {
        let values = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let savedSize = values["size"] as? Double ?? Self.defaultSize
        size = savedSize.isFinite
            ? min(max(savedSize.rounded(), Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            : Self.defaultSize
        style = (values["style"] as? String).flatMap(Style.init(rawValue:)) ?? .instrument
        appearance = (values["appearance"] as? String).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(["size": size, "style": style.rawValue, "appearance": appearance.rawValue], forKey: Self.defaultsKey)
    }
}

final class OrbSettingsWindow: NSWindow {
    private var settings: OrbSettings
    private let onChange: (OrbSettings) -> Void
    private let sizeValue = NSTextField(labelWithString: "")

    init(settings: OrbSettings, onChange: @escaping (OrbSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        super.init(contentRect: NSRect(x: 0, y: 0, width: 408, height: 176),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "悬浮球设置"
        isReleasedWhenClosed = false
        configureContent()
        center()
    }

    private func configureContent() {
        sizeValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        sizeValue.textColor = .secondaryLabelColor
        updateSizeLabel()
        let sizeHeader = NSStackView(views: [NSTextField(labelWithString: "悬浮球大小"), sizeValue])
        sizeHeader.alignment = .firstBaseline
        sizeHeader.distribution = .equalSpacing

        let slider = NSSlider(value: settings.size, minValue: OrbSettings.sizeRange.lowerBound,
                              maxValue: OrbSettings.sizeRange.upperBound, target: self, action: #selector(changeSize))
        slider.isContinuous = true
        slider.setAccessibilityLabel("悬浮球大小")

        let divider = NSBox()
        divider.boxType = .separator
        let styles = OrbSettings.Style.allCases
        let style = segmentedRow("表盘样式", labels: styles.map(\.title),
                                 selected: styles.firstIndex(of: settings.style) ?? 0, action: #selector(changeStyle))
        let appearances = OrbSettings.Appearance.allCases
        let appearance = segmentedRow("配色", labels: appearances.map(\.title),
                                      selected: appearances.firstIndex(of: settings.appearance) ?? 0,
                                      action: #selector(changeAppearance))

        let rows: [NSView] = [sizeHeader, slider, divider, style, appearance]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 13
        stack.setCustomSpacing(6, after: sizeHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func segmentedRow(_ title: String, labels: [String], selected: Int, action: Selector) -> NSStackView {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        control.segmentDistribution = .fillEqually
        control.selectedSegment = selected
        control.setAccessibilityLabel(title)
        control.widthAnchor.constraint(equalToConstant: 228).isActive = true

        let row = NSStackView(views: [NSTextField(labelWithString: title), control])
        row.alignment = .centerY
        row.distribution = .equalSpacing
        return row
    }

    private func updateSizeLabel() {
        sizeValue.stringValue = "\(Int(settings.size)) 点"
    }

    @objc private func changeSize(_ sender: NSSlider) {
        let size = sender.doubleValue.rounded()
        guard size != settings.size else { return }
        settings.size = size
        updateSizeLabel()
        onChange(settings)
    }

    @objc private func changeStyle(_ sender: NSSegmentedControl) {
        let styles = OrbSettings.Style.allCases
        guard styles.indices.contains(sender.selectedSegment) else { return }
        settings.style = styles[sender.selectedSegment]
        onChange(settings)
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let appearances = OrbSettings.Appearance.allCases
        guard appearances.indices.contains(sender.selectedSegment) else { return }
        settings.appearance = appearances[sender.selectedSegment]
        onChange(settings)
    }
}
