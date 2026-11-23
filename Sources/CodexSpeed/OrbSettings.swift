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

@MainActor
final class OrbSettingsMenu: NSObject {
    private(set) var settings: OrbSettings
    private let updater: ReleaseUpdater
    private let onChange: (OrbSettings) -> Void

    init(settings: OrbSettings, updater: ReleaseUpdater, onChange: @escaping (OrbSettings) -> Void) {
        self.settings = settings
        self.updater = updater
        self.onChange = onChange
    }

    func addItems(to menu: NSMenu) {
        let size = NSMenuItem(title: "调整悬浮球大小", action: nil, keyEquivalent: "")
        size.view = OrbSizeMenuView(size: settings.size) { [weak self] value in
            self?.change(\.size, to: value)
        }
        menu.addItem(submenu("悬浮球大小", items: [size]))
        menu.addItem(submenu("表盘样式", items: OrbSettings.Style.allCases.map { style in
            let item = actionItem(style.title, action: #selector(selectStyle(_:)), value: style)
            item.state = settings.style == style ? .on : .off
            return item
        }))
        menu.addItem(submenu("配色", items: OrbSettings.Appearance.allCases.map { appearance in
            let item = actionItem(appearance.title, action: #selector(selectAppearance(_:)), value: appearance)
            item.state = settings.appearance == appearance ? .on : .off
            return item
        }))
        menu.addItem(.separator())
        let updates = actionItem("自动获取更新", action: #selector(toggleUpdates))
        updates.state = settings.automaticallyFetchUpdates ? .on : .off
        updates.isEnabled = !updater.isInstalling
        menu.addItem(updates)

        let status = updater.status
        let check = actionItem("检查更新", action: #selector(checkForUpdates))
        check.isEnabled = status.canCheck
        menu.addItem(check)
        if let text = status.message {
            let message = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            message.isEnabled = false
            menu.addItem(message)
        }
        switch status {
        case let .ready(update, failure):
            menu.addItem(actionItem("安装并重启", action: #selector(installUpdate(_:)), value: update))
            if failure != nil {
                menu.addItem(actionItem("查看发布页", action: #selector(openReleasePage(_:)), value: update.page))
            }
        case let .available(_, page, _):
            menu.addItem(actionItem("查看发布页", action: #selector(openReleasePage(_:)), value: page))
        case let .recoveryFailed(update, backup):
            menu.addItem(actionItem("在访达中显示备份", action: #selector(revealBackup(_:)), value: backup))
            menu.addItem(actionItem("查看发布页", action: #selector(openReleasePage(_:)), value: update.page))
        default: break
        }
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func actionItem(_ title: String, action: Selector, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func change<Value: Equatable>(_ keyPath: WritableKeyPath<OrbSettings, Value>, to value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        onChange(settings)
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? OrbSettings.Style else { return }
        change(\.style, to: style)
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let appearance = sender.representedObject as? OrbSettings.Appearance else { return }
        change(\.appearance, to: appearance)
    }

    @objc private func toggleUpdates() {
        change(\.automaticallyFetchUpdates, to: !settings.automaticallyFetchUpdates)
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }

    @objc private func installUpdate(_ sender: NSMenuItem) {
        guard let update = sender.representedObject as? DownloadedUpdate else { return }
        updater.install(update)
    }

    @objc private func openReleasePage(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(page)
    }

    @objc private func revealBackup(_ sender: NSMenuItem) {
        guard let backup = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([backup])
    }
}

private final class OrbSizeMenuView: NSView {
    private let currentSize = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(size: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: 208, height: 57))
        autoresizingMask = .width
        currentSize.frame = CGRect(x: 14, y: 34, width: 180, height: 16)
        currentSize.autoresizingMask = .width
        currentSize.alignment = .center
        currentSize.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        currentSize.textColor = .secondaryLabelColor
        currentSize.stringValue = "\(Int(size)) 点"
        addSubview(currentSize)

        let slider = NSSlider(value: size, minValue: OrbSettings.sizeRange.lowerBound,
                              maxValue: OrbSettings.sizeRange.upperBound, target: self, action: #selector(slide(_:)))
        slider.frame = CGRect(x: 14, y: 7, width: 180, height: 22)
        slider.autoresizingMask = .width
        slider.isContinuous = true
        slider.setAccessibilityLabel("悬浮球大小")
        addSubview(slider)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func slide(_ sender: NSSlider) {
        let size = sender.doubleValue.rounded()
        currentSize.stringValue = "\(Int(size)) 点"
        onChange(size)
    }
}
