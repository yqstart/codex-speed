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
    var automaticallyFetchUpdates: Bool

    init(defaults: UserDefaults = .standard) {
        let values = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        let savedSize = values["size"] as? Double ?? Self.defaultSize
        size = savedSize.isFinite
            ? min(max(savedSize.rounded(), Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            : Self.defaultSize
        style = (values["style"] as? String).flatMap(Style.init(rawValue:)) ?? .instrument
        appearance = (values["appearance"] as? String).flatMap(Appearance.init(rawValue:)) ?? .system
        automaticallyFetchUpdates = values["automaticallyFetchUpdates"] as? Bool ?? false
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set([
            "size": size,
            "style": style.rawValue,
            "appearance": appearance.rawValue,
            "automaticallyFetchUpdates": automaticallyFetchUpdates,
        ], forKey: Self.defaultsKey)
    }
}

final class OrbSettingsWindow: NSWindow {
    private var settings: OrbSettings
    private var updateStatus: ReleaseUpdater.Status
    private let onChange: (OrbSettings) -> Void
    private let sizeValue = NSTextField(labelWithString: "")
    private let updateMessage = NSTextField(labelWithString: "")
    private let updateButton = NSButton()

    init(settings: OrbSettings, updateStatus: ReleaseUpdater.Status, onChange: @escaping (OrbSettings) -> Void) {
        self.settings = settings
        self.updateStatus = updateStatus
        self.onChange = onChange
        super.init(contentRect: NSRect(x: 0, y: 0, width: 408, height: 244),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "悬浮球设置"
        isReleasedWhenClosed = false
        configureContent()
        showUpdateStatus(updateStatus)
        center()
    }

    func showUpdateStatus(_ status: ReleaseUpdater.Status) {
        updateStatus = status
        updateMessage.stringValue = status.message
        let title: String? = switch status {
        case .available: "查看发布页"
        case .downloaded: "在访达中显示"
        default: nil
        }
        if let title { updateButton.title = title }
        updateButton.isHidden = title == nil
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

        let updateDivider = NSBox()
        updateDivider.boxType = .separator
        let updates = NSSwitch()
        updates.state = settings.automaticallyFetchUpdates ? .on : .off
        updates.target = self
        updates.action = #selector(changeAutomaticUpdates)
        updates.setAccessibilityLabel("自动获取更新")
        let updateToggle = row(NSTextField(labelWithString: "自动获取更新"), trailing: updates)

        updateMessage.textColor = .secondaryLabelColor
        updateMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.target = self
        updateButton.action = #selector(openUpdate)
        let updateDetails = row(updateMessage, trailing: updateButton)
        updateDetails.detachesHiddenViews = false

        let rows: [NSView] = [sizeHeader, slider, divider, style, appearance, updateDivider, updateToggle, updateDetails]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 13
        stack.setCustomSpacing(6, after: sizeHeader)
        stack.setCustomSpacing(5, after: updateToggle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            updateDetails.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }

    private func segmentedRow(_ title: String, labels: [String], selected: Int, action: Selector) -> NSStackView {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        control.segmentDistribution = .fillEqually
        control.selectedSegment = selected
        control.setAccessibilityLabel(title)
        control.widthAnchor.constraint(equalToConstant: 228).isActive = true

        return row(NSTextField(labelWithString: title), trailing: control)
    }

    private func row(_ label: NSView, trailing: NSView) -> NSStackView {
        let row = NSStackView(views: [label, trailing])
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

    @objc private func changeAutomaticUpdates(_ sender: NSSwitch) {
        settings.automaticallyFetchUpdates = sender.state == .on
        onChange(settings)
    }

    @objc private func openUpdate() {
        switch updateStatus {
        case let .available(_, page): NSWorkspace.shared.open(page)
        case let .downloaded(_, archive): NSWorkspace.shared.activateFileViewerSelecting([archive])
        default: break
        }
    }
}
