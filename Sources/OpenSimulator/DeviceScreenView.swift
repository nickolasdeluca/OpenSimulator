import AppKit
import MetalKit
import SimulatorCore

/// The device's screen. It never runs a display loop of its own: it is redrawn only when the guest
/// delivers a frame, so a still screen uses no CPU or GPU on the Mac.
final class DeviceScreenView: MTKView {
    enum Contact { case began, moved, ended }

    /// A click or drag, in view coordinates. `pinch` is true while Option is held, which makes the
    /// pointer one finger and its mirror through the centre the other, as in the classic Simulator.
    var onContact: ((CGPoint, Contact, _ pinch: Bool) -> Void)?
    /// A trackpad pinch, as the distance between two fingers in view points.
    var onMagnify: ((Contact, CGFloat) -> Void)?
    var onKey: ((UInt32, Bool) -> Void)?
    var onDrop: (([URL], String?) -> Bool)?

    var sendsKeyboardInput = true
    private var pressedModifiers = Set<UInt16>()
    private var magnifySpread: CGFloat = 0

    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        // Transparent where the masked frame has rounded corners, so the body shows through.
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    /// A click on an inactive window still taps the device, like the classic Simulator.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Pointer

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onContact?(point(event), .began, event.modifierFlags.contains(.option))
    }

    override func mouseDragged(with event: NSEvent) {
        onContact?(point(event), .moved, event.modifierFlags.contains(.option))
    }

    override func mouseUp(with event: NSEvent) {
        onContact?(point(event), .ended, event.modifierFlags.contains(.option))
    }

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            magnifySpread = min(bounds.width, bounds.height) / 4
            onMagnify?(.began, magnifySpread)
        case .changed:
            magnifySpread = max(magnifySpread + event.magnification * min(bounds.width, bounds.height), 8)
            onMagnify?(.moved, magnifySpread)
        case .ended, .cancelled:
            onMagnify?(.ended, magnifySpread)
        default:
            break
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard sendsKeyboardInput, let usage = KeyboardMap.usage(forKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        // The guest repeats held keys itself.
        if !event.isARepeat { onKey?(usage, true) }
    }

    override func keyUp(with event: NSEvent) {
        guard sendsKeyboardInput, let usage = KeyboardMap.usage(forKeyCode: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        onKey?(usage, false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard sendsKeyboardInput, let usage = KeyboardMap.modifierUsageByKeyCode[event.keyCode] else {
            super.flagsChanged(with: event)
            return
        }
        // A flags change does not say whether the key went down or up, so track which are held.
        if pressedModifiers.contains(event.keyCode) {
            pressedModifiers.remove(event.keyCode)
            onKey?(usage, false)
        } else {
            pressedModifiers.insert(event.keyCode)
            onKey?(usage, true)
        }
    }

    /// Releases modifiers the device thinks are held, for when focus leaves mid-press.
    func releaseModifiers() {
        for keyCode in pressedModifiers {
            if let usage = KeyboardMap.modifierUsageByKeyCode[keyCode] { onKey?(usage, false) }
        }
        pressedModifiers.removeAll()
    }

    override func resignFirstResponder() -> Bool {
        releaseModifiers()
        return super.resignFirstResponder()
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onDrop else { return false }
        let pasteboard = sender.draggingPasteboard
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty { return onDrop(files, nil) }
        if let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string),
           let scheme = URLComponents(string: text)?.scheme, !scheme.isEmpty {
            return onDrop([], text)
        }
        return false
    }
}
