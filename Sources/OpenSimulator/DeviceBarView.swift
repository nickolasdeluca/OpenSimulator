import AppKit
import SimulatorCore

/// The strip under the device with the buttons a person reaches for most, and a foldable's hinge
/// postures. Plain layer-backed capsules rather than a blur, so it costs nothing while idle.
final class DeviceBarView: NSView {
    static let height: CGFloat = 52

    var onHome: (() -> Void)?
    var onAppSwitcher: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onRotate: (() -> Void)?
    var onPosture: ((HingePosture) -> Void)?

    private let stack = NSStackView()
    private let foldGroup: NSView
    private var postureButtons: [HingePosture: NSButton] = [:]

    override init(frame: NSRect) {
        var postureButtons: [HingePosture: NSButton] = [:]
        for posture in HingePosture.allCases {
            postureButtons[posture] = Self.button(Self.symbol(for: posture), "Hinge: \(posture.title)")
        }
        foldGroup = Self.capsule(HingePosture.allCases.compactMap { postureButtons[$0] })
        self.postureButtons = postureButtons
        super.init(frame: frame)

        let home = Self.button("house", "Home")
        let switcher = Self.button("square.stack", "App Switcher")
        let screenshot = Self.button("camera", "Save Screen")
        let rotate = Self.button("rotate.right", "Rotate Right")
        home.target = self; home.action = #selector(homeClicked)
        switcher.target = self; switcher.action = #selector(switcherClicked)
        screenshot.target = self; screenshot.action = #selector(screenshotClicked)
        rotate.target = self; rotate.action = #selector(rotateClicked)
        for (posture, button) in postureButtons {
            button.target = self
            button.action = #selector(postureClicked(_:))
            button.tag = HingePosture.allCases.firstIndex(of: posture) ?? 0
        }

        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(Self.capsule([home, switcher, screenshot]))
        stack.addArrangedSubview(Self.capsule([rotate]))
        stack.addArrangedSubview(foldGroup)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setFoldable(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The narrowest the window can be with the bar's buttons all showing.
    var minimumWidth: CGFloat { stack.fittingSize.width + 24 }

    func setFoldable(_ foldable: Bool) {
        foldGroup.isHidden = !foldable
    }

    func setPosture(_ posture: HingePosture) {
        for (each, button) in postureButtons {
            button.contentTintColor = each == posture ? .controlAccentColor : .white
            button.setAccessibilityValue(each == posture ? "selected" : nil)
        }
    }

    @objc private func homeClicked() { onHome?() }
    @objc private func switcherClicked() { onAppSwitcher?() }
    @objc private func screenshotClicked() { onScreenshot?() }
    @objc private func rotateClicked() { onRotate?() }
    @objc private func postureClicked(_ sender: NSButton) {
        guard HingePosture.allCases.indices.contains(sender.tag) else { return }
        onPosture?(HingePosture.allCases[sender.tag])
    }

    private static func symbol(for posture: HingePosture) -> String {
        switch posture {
        case .closed: "iphone"
        case .partiallyOpen: "book"
        case .open: "ipad.landscape"
        }
    }

    private static func button(_ symbol: String, _ title: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        return button
    }

    private static func capsule(_ buttons: [NSView]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(white: 0.17, alpha: 0.94).cgColor
        row.layer?.cornerRadius = 18
        row.layer?.cornerCurve = .continuous
        row.layer?.borderWidth = 0.5
        row.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        return row
    }
}

/// The window's content: the device on top and, when shown, the bar under it.
final class DeviceContentView: NSView {
    let deviceView: NSView
    let bar: DeviceBarView

    var showsBar = true {
        didSet {
            bar.isHidden = !showsBar
            needsLayout = true
        }
    }

    var barHeight: CGFloat { showsBar ? DeviceBarView.height : 0 }

    init(deviceView: NSView, bar: DeviceBarView) {
        self.deviceView = deviceView
        self.bar = bar
        super.init(frame: .zero)
        addSubview(deviceView)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let height = barHeight
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        deviceView.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(bounds.height - height, 0))
    }
}
