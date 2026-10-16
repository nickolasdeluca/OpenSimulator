import AppKit
import SimBridge
import SimulatorCore

/// The device's body around its screen, with clickable side buttons, like the classic Simulator.
/// Without chrome (turned off, or none installed for the device) the screen fills the view.
final class DeviceChromeView: NSView {
    var onButton: ((HardwareButton, Bool) -> Void)?

    let screenView: NSView
    let overlay: NSView
    private(set) var chrome: DeviceChrome?
    private var composite: NSImage?
    private var slices: [String: NSImage] = [:]
    private var buttonImages: [String: NSImage] = [:]
    private var screenPoints = CGSize(width: 402, height: 874)
    private var orientation: DeviceOrientation = .portrait
    private var hovered: DeviceChrome.Button?
    private var pressed: DeviceChrome.Button?
    private var tracking: NSTrackingArea?

    init(screenView: NSView, overlay: NSView) {
        self.screenView = screenView
        self.overlay = overlay
        super.init(frame: .zero)
        addSubview(screenView)
        addSubview(overlay)
        for view in [screenView, overlay] {
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The screen's upright size in points.
    func setScreenPoints(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        screenPoints = size
        relayout()
    }

    func setOrientation(_ orientation: DeviceOrientation) {
        self.orientation = orientation
        relayout()
    }

    func setChrome(_ chrome: DeviceChrome?) {
        self.chrome = chrome
        composite = chrome?.composite.flatMap { NSImage(contentsOf: chrome!.resource($0)) }
        slices = [:]
        buttonImages = [:]
        if let chrome {
            if let parts = chrome.slices {
                for name in [parts.topLeft, parts.top, parts.topRight, parts.left, parts.right,
                             parts.bottomLeft, parts.bottom, parts.bottomRight] {
                    slices[name] = NSImage(contentsOf: chrome.resource(name))
                }
            }
            for button in chrome.buttons {
                buttonImages[button.image] = NSImage(contentsOf: chrome.resource(button.image))
                buttonImages[button.imageDown] = NSImage(contentsOf: chrome.resource(button.imageDown))
            }
        }
        relayout()
    }

    var hasBody: Bool { chrome != nil && (composite != nil || !slices.isEmpty) }
    private var activeChrome: DeviceChrome? { hasBody ? chrome : nil }

    /// The device's size upright in points, body included when shown.
    var uprightSize: CGSize { DeviceLayout.uprightSize(screen: screenPoints, chrome: activeChrome) }

    private var deviceTransform: CGAffineTransform {
        DeviceLayout.transform(viewSize: bounds.size, upright: uprightSize, orientation: orientation)
    }

    private func relayout() {
        needsLayout = true
        needsDisplay = true
        window?.invalidateShadow()
    }

    override func layout() {
        super.layout()
        let transform = deviceTransform
        let screen = DeviceLayout.screenRect(upright: uprightSize, chrome: activeChrome)
            .applying(transform).integral
        screenView.frame = screen
        overlay.frame = screen
        // The body's corner radius is its outside edge, so the bezel comes off for the screen's.
        var radius: CGFloat = 0
        if let chrome = activeChrome {
            radius = max(0, chrome.cornerRadius - chrome.maxInset) * hypot(transform.a, transform.b)
        }
        for view in [screenView, overlay] {
            view.layer?.cornerRadius = radius
            view.layer?.masksToBounds = radius > 0
        }
        window?.invalidateShadow()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let chrome = activeChrome, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.cgContext.concatenate(deviceTransform)

        let upright = uprightSize
        let body = DeviceLayout.bodyRect(upright: upright, chrome: chrome)
        drawButtons(chrome, upright: upright, onTop: false)
        if let composite {
            composite.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
        } else if let parts = chrome.slices {
            NSDrawNinePartImage(
                body,
                slices[parts.topLeft], slices[parts.top], slices[parts.topRight],
                slices[parts.left], nil, slices[parts.right],
                slices[parts.bottomLeft], slices[parts.bottom], slices[parts.bottomRight],
                .sourceOver, 1, false
            )
        }
        drawButtons(chrome, upright: upright, onTop: true)
    }

    private func drawButtons(_ chrome: DeviceChrome, upright: CGSize, onTop: Bool) {
        for button in chrome.buttons where button.onTop == onTop {
            guard let image = buttonImages[pressed == button ? button.imageDown : button.image]
                ?? buttonImages[button.image] else { continue }
            image.draw(in: rect(for: button, chrome: chrome, upright: upright), from: .zero,
                       operation: .sourceOver, fraction: 1)
        }
    }

    private func rect(for button: DeviceChrome.Button, chrome: DeviceChrome, upright: CGSize) -> CGRect {
        DeviceLayout.buttonRect(
            button,
            imageSize: buttonImages[button.image]?.size ?? .zero,
            upright: upright,
            chrome: chrome,
            hovered: hovered == button || pressed == button
        )
    }

    // MARK: Buttons

    private func button(at viewPoint: CGPoint) -> DeviceChrome.Button? {
        guard let chrome = activeChrome else { return nil }
        let point = viewPoint.applying(deviceTransform.inverted())
        let upright = uprightSize
        return chrome.buttons.first { button in
            DeviceLayout.buttonRect(button, imageSize: buttonImages[button.image]?.size ?? .zero,
                                    upright: upright, chrome: chrome, hovered: false).contains(point)
        }
    }

    private static func hardware(_ button: DeviceChrome.Button) -> HardwareButton? {
        switch button.name {
        case "home": .home
        case "power": .lock
        case "volume-up": .volumeUp
        case "volume-down": .volumeDown
        default: nil
        }
    }

    /// Clicks on the body outside the screen and buttons drag the window, as in the classic
    /// Simulator. Clicks on the transparent area around the device fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if button(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let button = button(at: point) else {
            window?.performDrag(with: event)
            return
        }
        pressed = button
        needsDisplay = true
        if let hardware = Self.hardware(button) { onButton?(hardware, true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let button = pressed else { return }
        pressed = nil
        needsDisplay = true
        if let hardware = Self.hardware(button) { onButton?(hardware, false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(button(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ button: DeviceChrome.Button?) {
        guard hovered != button else { return }
        hovered = button
        needsDisplay = true
    }
}
