import AppKit
import QuartzCore
import SimulatorCore

/// Drawn over the device's screen while an agent drives it: a dot for each touch, a caption for
/// what it types, a border, and a banner with Stop. Everything is Core Animation that runs only
/// when an event arrives, and clicks pass through to the screen except on the banner.
final class AgentOverlayView: NSView {
    enum State { case idle, active, stopped }

    var onStop: (() -> Void)?
    var onAllow: (() -> Void)?

    private(set) var state: State = .idle
    private var dots: [CALayer] = []
    private var currentDot: CALayer?
    private let caption = NSTextField(labelWithString: "")
    private let captionBox = NSView()
    private var captionGeneration = 0
    private let banner = NSView()
    private let bannerLabel = NSTextField(labelWithString: "")
    private let bannerButton = NSButton(title: "", target: nil, action: nil)

    static let accent = NSColor.systemOrange
    private static let dotSize: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = Self.accent.cgColor

        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        captionBox.layer?.cornerRadius = 10
        captionBox.layer?.cornerCurve = .continuous
        captionBox.alphaValue = 0
        caption.textColor = .white
        caption.font = .systemFont(ofSize: 15, weight: .medium)
        caption.lineBreakMode = .byTruncatingTail
        caption.translatesAutoresizingMaskIntoConstraints = false
        captionBox.translatesAutoresizingMaskIntoConstraints = false
        captionBox.addSubview(caption)
        addSubview(captionBox)

        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        banner.layer?.cornerRadius = 15
        banner.layer?.cornerCurve = .continuous
        banner.isHidden = true
        bannerLabel.textColor = .white
        bannerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        bannerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bannerButton.bezelStyle = .push
        bannerButton.controlSize = .small
        bannerButton.target = self
        bannerButton.action = #selector(bannerButtonPressed)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.accent.cgColor
        dot.layer?.cornerRadius = 4
        let stack = NSStackView(views: [dot, bannerLabel, bannerButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(stack)
        addSubview(banner)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            stack.topAnchor.constraint(equalTo: banner.topAnchor),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            banner.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),

            caption.topAnchor.constraint(equalTo: captionBox.topAnchor, constant: 6),
            caption.bottomAnchor.constraint(equalTo: captionBox.bottomAnchor, constant: -6),
            caption.leadingAnchor.constraint(equalTo: captionBox.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: captionBox.trailingAnchor, constant: -12),
            captionBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            captionBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionBox.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Only the banner takes clicks; the rest of the screen belongs to the person.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !banner.isHidden else { return nil }
        let local = convert(point, from: superview)
        return banner.frame.contains(local) ? super.hitTest(point) : nil
    }

    override var isFlipped: Bool { false }

    // MARK: State

    func setState(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        switch state {
        case .idle:
            banner.isHidden = true
            layer?.borderWidth = 0
        case .active:
            bannerButton.title = "Stop"
            banner.isHidden = false
            layer?.borderWidth = 3
        case .stopped:
            bannerButton.title = "Allow"
            banner.isHidden = false
            layer?.borderWidth = 0
            clearDots()
        }
        fitBanner()
    }

    /// Longest first. The banner takes the first that fits the screen as shown, so a narrow
    /// iPhone at a small zoom gets a shorter message rather than a cut-off one.
    private var bannerMessages: [String] {
        state == .stopped
            ? ["Agent stopped", "Stopped"]
            : ["An agent is using this device", "Agent in control", "Agent"]
    }

    override func layout() {
        super.layout()
        fitBanner()
    }

    private func fitBanner() {
        guard state != .idle else { return }
        // Everything in the banner except the message: margins, dot, spacing and the button.
        let chrome: CGFloat = 16 + 12 + 6 + 8 + 2 * 8
        // Set only on a change: each set lays the banner out again, which lands back here.
        func apply(_ message: String, _ font: NSFont, _ control: NSControl.ControlSize) {
            if bannerButton.controlSize != control { bannerButton.controlSize = control }
            if bannerLabel.font != font { bannerLabel.font = font }
            if bannerLabel.stringValue != message { bannerLabel.stringValue = message }
        }
        let sizes: [(CGFloat, NSControl.ControlSize)] = [(12, .small), (11, .small), (10, .mini)]
        for (size, control) in sizes {
            let button = NSButton(title: bannerButton.title, target: nil, action: nil)
            button.bezelStyle = .push
            button.controlSize = control
            let room = bounds.width - chrome - button.intrinsicContentSize.width
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            if let message = bannerMessages.first(where: { $0.size(withAttributes: [.font: font]).width + 2 <= room }) {
                apply(message, font, control)
                return
            }
        }
        // Too narrow for any words: the dot and the button still say it.
        apply("", .systemFont(ofSize: 10, weight: .semibold), .mini)
    }

    @objc private func bannerButtonPressed() {
        state == .stopped ? onAllow?() : onStop?()
    }

    // MARK: Touches and captions

    /// `point` is in this view's coordinates.
    func showTouch(at point: CGPoint, phase: AgentActivity.TouchPhase) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch phase {
        case .down:
            let dot = Self.makeDot()
            dot.position = point
            layer.addSublayer(dot)
            dots.append(dot)
            currentDot = dot
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 1
            grow.duration = 0.12
            dot.add(grow, forKey: "grow")
        case .move:
            currentDot?.position = point
        case .up:
            guard let dot = currentDot else { break }
            dot.position = point
            currentDot = nil
            fade(dot)
        }
        CATransaction.commit()
    }

    func showCaption(_ text: String) {
        caption.stringValue = text
        captionGeneration += 1
        let generation = captionGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            captionBox.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.captionGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.captionBox.animator().alphaValue = 0
            }
        }
    }

    private static func makeDot() -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dot.cornerRadius = dotSize / 2
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        dot.borderColor = accent.cgColor
        dot.borderWidth = 2.5
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        return dot
    }

    private func fade(_ dot: CALayer) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak dot] in
            dot?.removeFromSuperlayer()
            self?.dots.removeAll { $0 === dot }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 1.5
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = 0.45
        dot.opacity = 0
        dot.add(group, forKey: "fade")
        CATransaction.commit()
    }

    private func clearDots() {
        for dot in dots { dot.removeFromSuperlayer() }
        dots.removeAll()
        currentDot = nil
    }
}
