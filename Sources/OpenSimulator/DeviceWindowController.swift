import AppKit
import CoreImage
import MetalKit
import SimBridge
import SimulatorCore

/// One window per device, like the classic Simulator. The window owns the device's display stream
/// and input client while it is open, and pauses the stream whenever it cannot be seen.
@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let udid: String
    private let store: SimulatorStore
    private let onClose: (DeviceWindowController) -> Void

    private let screenView: DeviceScreenView
    nonisolated private let renderer: ScreenRenderer
    private let overlay = StatusOverlayView()
    private let chromeView: DeviceChromeView
    private let chrome: DeviceChrome?

    private var display: DisplayStream?
    private var hid: HIDClient?
    private var orientation: DeviceOrientation = .portrait
    private var pixelSize: CGSize
    private var pointScale: CGFloat
    private var pixelsPerInch: Int = 0

    /// True while this window is the reason the device is booting, restarting or erasing, so the
    /// state changes that causes are not mistaken for the device being shut down elsewhere.
    private var lifecycleInFlight = false
    private var isClosing = false

    // Touch state for the gesture in progress.
    private var contactEdge: TouchEdge = .none
    private var contactIsPinch = false

    // Frame pacing. The flag is set from the stream queue, so it lives in a locked box.
    nonisolated private let frameQueued = LockedFlag()
    private var lastDraw: CFTimeInterval = 0

    init(udid: String, store: SimulatorStore, onClose: @escaping (DeviceWindowController) -> Void) throws {
        guard let metal = MTLCreateSystemDefaultDevice() else {
            throw RendererError("This Mac has no Metal device.")
        }
        self.udid = udid
        self.store = store
        self.onClose = onClose
        screenView = DeviceScreenView(device: metal)
        renderer = try ScreenRenderer(device: metal, pixelFormat: screenView.colorPixelFormat)
        screenView.delegate = renderer

        let snapshot = store.device(udid)
        pixelSize = snapshot.map { $0.mainScreenPixelSize } ?? CGSize(width: 1206, height: 2622)
        if pixelSize.width <= 0 || pixelSize.height <= 0 { pixelSize = CGSize(width: 1206, height: 2622) }
        pointScale = max(snapshot?.pointScale ?? 3, 1)
        chrome = snapshot.flatMap { DeviceChrome.forDeviceType($0.deviceTypeIdentifier) }
        chromeView = DeviceChromeView(screenView: screenView, overlay: overlay)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 402, height: 874)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = snapshot?.name ?? "Simulator"
        window.subtitle = snapshot?.runtimeName ?? ""
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Device-\(udid)")

        window.contentView = chromeView

        super.init(window: window)
        window.delegate = self
        chromeView.setScreenPoints(screenPoints)
        applyBezelPreference()
        wireInput()

        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: .simulatorDevicesChanged, object: store
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: Lifecycle

    /// Shows the window and boots the device if it is not already running.
    func present() {
        let restored = UserDefaults.standard.string(forKey: "NSWindow Frame Device-\(udid)") != nil
        applyZoom(savedZoom ?? defaultZoom, animate: false)
        if !restored { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(screenView)
        Task { await bootAndAttach() }
    }

    private func bootAndAttach() async {
        guard let snapshot = store.device(udid) else {
            overlay.show("This simulator no longer exists.")
            return
        }
        if snapshot.state != .booted {
            overlay.show("Booting \(snapshot.name)…", spinning: true)
            lifecycleInFlight = true
            let booted = await store.boot(udid)
            lifecycleInFlight = false
            // The window was closed while the device was still booting.
            if booted, isClosing {
                if Preferences.shutDownOnClose { await store.shutdown(udid) }
                return
            }
            guard booted else {
                overlay.show(store.lastError ?? "The simulator did not boot.")
                return
            }
        }
        await attach()
    }

    /// Opens display and input. The display port can appear a moment after `bootstatus` returns,
    /// so it is retried briefly.
    private func attach() async {
        overlay.show("Connecting…", spinning: true)
        var lastError: Error?
        for _ in 0..<20 {
            guard !isClosing else { return }
            do {
                let stream = try store.core.openDisplay(forDevice: udid)
                display = stream
                pixelSize = stream.pixelSize
                pixelsPerInch = Int(stream.pixelsPerInch)
                stream.prefersMaskedSurface = true
                break
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard display != nil else {
            overlay.show(lastError?.localizedDescription ?? "Could not show the device's screen.")
            return
        }

        do {
            hid = try store.core.openHID(forDevice: udid)
        } catch {
            NSLog("OpenSimulator: input unavailable: \(error.localizedDescription)")
        }
        screenView.sendsKeyboardInput = Preferences.hardwareKeyboard && hid != nil
        try? store.core.setHardwareKeyboardEnabled(Preferences.hardwareKeyboard, forDevice: udid)

        overlay.hide()
        chromeView.setScreenPoints(screenPoints)
        applyZoom(currentZoom, animate: true)
        updateStreaming()
    }

    private func detach() {
        display?.stop()
        display = nil
        hid = nil
    }

    // MARK: Frames

    /// Streams only while the window is on screen. A hidden, minimized or fully covered window
    /// unregisters from CoreSimulator, so the Mac does no work for a screen nobody can see.
    private func updateStreaming() {
        guard let display, let window else { return }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        if visible || !Preferences.pauseWhenHidden {
            guard !display.isRunning else { return }
            display.start { [weak self] surface in
                self?.frameArrived(surface)
            }
        } else {
            display.stop()
        }
    }

    /// Runs on the stream's queue. Frames are coalesced so at most one draw is ever queued, and
    /// paced to the frame rate limit.
    nonisolated private func frameArrived(_ surface: IOSurfaceRef) {
        renderer.accept(surface)
        guard frameQueued.testAndSet() == false else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDraw() }
        }
    }

    private func scheduleDraw() {
        let interval = 1.0 / Double(Preferences.frameRateLimit)
        let delay = max(0, lastDraw + interval - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frameQueued.clear()
                self.lastDraw = CACurrentMediaTime()
                self.screenView.draw()
            }
        }
    }

    @objc private func occlusionChanged(_ note: Notification) {
        updateStreaming()
    }

    @objc private func preferencesChanged(_ note: Notification) {
        if (chromeView.chrome != nil) != (Preferences.showBezel && chrome != nil) {
            let zoom = currentZoom
            applyBezelPreference()
            applyZoom(zoom, animate: true)
        }
        updateStreaming()
    }

    /// Show Device Bezels: the device's body on a transparent window, or the bare screen on black.
    private func applyBezelPreference() {
        let body = Preferences.showBezel ? chrome : nil
        chromeView.setChrome(body)
        guard let window else { return }
        window.isOpaque = body == nil
        window.backgroundColor = body == nil ? .black : .clear
        window.hasShadow = true
        window.invalidateShadow()
    }

    @objc private func devicesChanged(_ note: Notification) {
        guard let snapshot = store.device(udid) else {
            if !isClosing { close() }
            return
        }
        window?.title = snapshot.name
        // Shut down from somewhere else (simctl, Xcode, Device Hub): the window goes with it.
        if snapshot.state == .shutdown, display != nil, !lifecycleInFlight, !isClosing {
            detach()
            close()
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        screenView.releaseModifiers()
        detach()
        NotificationCenter.default.removeObserver(self)
        if Preferences.shutDownOnClose, store.device(udid)?.state == .booted {
            let store = store, udid = udid
            Task { await store.shutdown(udid) }
        }
        onClose(self)
    }

    func windowDidMiniaturize(_ notification: Notification) { updateStreaming() }
    func windowDidDeminiaturize(_ notification: Notification) { updateStreaming() }

    func windowDidResignKey(_ notification: Notification) {
        screenView.releaseModifiers()
    }

    private var screenPoints: CGSize {
        CGSize(width: pixelSize.width / pointScale, height: pixelSize.height / pointScale)
    }

    /// The device as the window shows it at zoom 1 (Point Accurate), body included, turned.
    private var deviceSize: CGSize { orientation.displayedSize(portrait: chromeView.uprightSize) }

    // MARK: Size
    //
    // Window size is kept as a zoom: window points per device point, so 1 is Point Accurate.
    // Each device remembers its own zoom, whether picked from the Window menu or dragged to size,
    // the way the classic Simulator remembered each device's scale.

    private static let zoomDefaultsKey = "DeviceZoom"

    private var savedZoom: CGFloat? {
        get {
            let all = UserDefaults.standard.dictionary(forKey: Self.zoomDefaultsKey) as? [String: Double]
            return all?[udid].map { CGFloat($0) }
        }
        set {
            var all = UserDefaults.standard.dictionary(forKey: Self.zoomDefaultsKey) as? [String: Double] ?? [:]
            all[udid] = newValue.map(Double.init)
            UserDefaults.standard.set(all, forKey: Self.zoomDefaultsKey)
        }
    }

    /// For a device opened for the first time: the size picked in Settings.
    private var defaultZoom: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main else { return 1 }
        return zoom(for: Preferences.scaleMode, on: screen)
    }

    private var currentZoom: CGFloat {
        guard let window, deviceSize.width > 0 else { return savedZoom ?? 1 }
        return window.contentLayoutRect.width / deviceSize.width
    }

    private func zoom(for mode: ScaleMode, on screen: NSScreen) -> CGFloat {
        switch mode {
        case .pointAccurate:
            return 1
        case .pixelAccurate:
            return pointScale / screen.backingScaleFactor
        case .physicalSize:
            guard pixelsPerInch > 0,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return 1 }
            let millimetres = CGDisplayScreenSize(number)
            guard millimetres.width > 0 else { return 1 }
            let macPointsPerInch = screen.frame.width / (millimetres.width / 25.4)
            // A device point is pointScale pixels at pixelsPerInch.
            return macPointsPerInch * pointScale / CGFloat(pixelsPerInch)
        case .fitScreen:
            let fitted = ScreenGeometry.fittedRect(container: available(on: screen), content: deviceSize)
            return deviceSize.width > 0 ? fitted.width / deviceSize.width : 1
        }
    }

    /// The largest content size that still fits on screen with the title bar.
    private func available(on screen: NSScreen) -> CGSize {
        let titleBar = (window?.frame.height ?? 0) - (window?.contentLayoutRect.height ?? 0)
        return CGSize(width: screen.visibleFrame.width - 40, height: screen.visibleFrame.height - max(titleBar, 28) - 20)
    }

    private func applyZoom(_ zoom: CGFloat, animate: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main, !window.styleMask.contains(.fullScreen) else { return }
        let device = deviceSize
        var size = CGSize(width: device.width * zoom, height: device.height * zoom)
        let room = available(on: screen)
        if size.width > room.width || size.height > room.height {
            size = ScreenGeometry.fittedRect(container: room, content: size).size
        }
        size = CGSize(width: size.width.rounded(), height: size.height.rounded())
        window.contentAspectRatio = device
        window.contentMinSize = CGSize(width: device.width * 0.25, height: device.height * 0.25)

        // Grow and shrink from the top left corner, as the classic Simulator does.
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
        if device.width > 0 { savedZoom = size.width / device.width }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        savedZoom = currentZoom
    }

    // MARK: Input

    private func wireInput() {
        screenView.onContact = { [weak self] point, contact, pinch in
            MainActor.assumeIsolated { self?.handleContact(point, contact, pinch: pinch) }
        }
        screenView.onMagnify = { [weak self] contact, spread in
            MainActor.assumeIsolated { self?.handleMagnify(contact, spread: spread) }
        }
        screenView.onKey = { [weak self] usage, down in
            MainActor.assumeIsolated { self?.hid?.sendKeyUsage(usage, down: down) }
        }
        screenView.onDrop = { [weak self] files, url in
            MainActor.assumeIsolated { self?.handleDrop(files, url: url) ?? false }
        }
    }

    private func normalized(_ viewPoint: CGPoint) -> CGPoint {
        ScreenGeometry.normalizedPoint(
            viewPoint: viewPoint,
            viewSize: screenView.bounds.size,
            pixelSize: pixelSize,
            orientation: orientation
        )
    }

    private func handleContact(_ viewPoint: CGPoint, _ contact: DeviceScreenView.Contact, pinch: Bool) {
        guard let hid else { return }
        let point = normalized(viewPoint)
        let phase: TouchPhase
        switch contact {
        case .began:
            phase = .down
            contactIsPinch = pinch
            contactEdge = TouchEdge(ScreenGeometry.edge(forPortraitPoint: point))
        case .moved: phase = .move
        case .ended: phase = .up
        }
        if contactIsPinch {
            hid.sendTouches(at: point, and: CGPoint(x: 1 - point.x, y: 1 - point.y), phase: phase)
        } else {
            hid.sendTouch(at: point, phase: phase, edge: contactEdge)
        }
    }

    /// A trackpad pinch becomes two fingers either side of the screen's centre.
    private func handleMagnify(_ contact: DeviceScreenView.Contact, spread: CGFloat) {
        guard let hid else { return }
        let size = screenView.bounds.size
        let half = spread / 2
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let a = normalized(CGPoint(x: centre.x - half, y: centre.y))
        let b = normalized(CGPoint(x: centre.x + half, y: centre.y))
        let phase: TouchPhase = contact == .began ? .down : contact == .moved ? .move : .up
        hid.sendTouches(at: a, and: b, phase: phase)
    }

    private func handleDrop(_ files: [URL], url: String?) -> Bool {
        let udid = udid
        if let url {
            Task { await store.perform(nil) { try await $0.openURL(udid, url) } }
            return true
        }
        let apps = files.filter { ["app", "ipa"].contains($0.pathExtension.lowercased()) }
        let media = files.filter { !apps.contains($0) }
        Task {
            for app in apps {
                overlay.flash("Installing \(app.lastPathComponent)…")
                await store.perform(nil) { try await $0.install(udid, app: app) }
            }
            if !media.isEmpty {
                await store.perform(nil) { try await $0.addMedia(udid, files: media) }
            }
            overlay.flash(apps.isEmpty ? "Added to Photos" : "Installed")
        }
        return true
    }

    private func press(_ button: HardwareButton) {
        hid?.send(button, down: true)
        hid?.send(button, down: false)
    }

    private func typeKeys(_ usages: [UInt32], modifier: UInt32? = nil) {
        guard let hid else { return }
        if let modifier { hid.sendKeyUsage(modifier, down: true) }
        for usage in usages {
            hid.sendKeyUsage(usage, down: true)
            hid.sendKeyUsage(usage, down: false)
        }
        if let modifier { hid.sendKeyUsage(modifier, down: false) }
    }

    private func runGesture(_ path: [CGPoint]) {
        guard let hid, !path.isEmpty else { return }
        let native = path.map { ScreenGeometry.portraitPoint(fromShown: $0, orientation: orientation) }
        let edge = TouchEdge(ScreenGeometry.edge(forPortraitPoint: native[0]))
        Task {
            hid.sendTouch(at: native[0], phase: .down, edge: edge)
            for point in native.dropFirst() {
                try? await Task.sleep(for: .milliseconds(12))
                hid.sendTouch(at: point, phase: .move, edge: edge)
            }
            hid.sendTouch(at: native[native.count - 1], phase: .up, edge: edge)
        }
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func rotateLeft(_ sender: Any?) { rotate(to: orientation.rotatedLeft) }
    @objc func rotateRight(_ sender: Any?) { rotate(to: orientation.rotatedRight) }

    private func rotate(to next: DeviceOrientation) {
        do {
            try store.core.setOrientation(next.gsEventValue, forDevice: udid)
        } catch {
            overlay.flash(error.localizedDescription)
            return
        }
        let zoom = currentZoom
        orientation = next
        renderer.setOrientation(next)
        chromeView.setOrientation(next)
        applyZoom(zoom, animate: true)
        screenView.draw()
    }

    @objc func pressHome(_ sender: Any?) { press(.home) }
    @objc func pressLock(_ sender: Any?) { press(.lock) }
    @objc func pressSiri(_ sender: Any?) { press(.siri) }
    @objc func volumeUp(_ sender: Any?) { press(.volumeUp) }
    @objc func volumeDown(_ sender: Any?) { press(.volumeDown) }
    @objc func swipeHome(_ sender: Any?) { runGesture(HomeGesture.homePath()) }
    @objc func showAppSwitcher(_ sender: Any?) { runGesture(HomeGesture.appSwitcherPath()) }

    @objc func shake(_ sender: Any?) {
        let udid = udid
        Task { await store.perform(nil) { try await $0.shake(udid) } }
    }

    @objc func simulateMemoryWarning(_ sender: Any?) {
        do {
            try store.core.simulateMemoryWarning(forDevice: udid)
        } catch {
            overlay.flash(error.localizedDescription)
        }
    }

    @objc func toggleHardwareKeyboard(_ sender: Any?) {
        let enabled = !Preferences.hardwareKeyboard
        do {
            try store.core.setHardwareKeyboardEnabled(enabled, forDevice: udid)
            Preferences.hardwareKeyboard = enabled
            screenView.sendsKeyboardInput = enabled && hid != nil
        } catch {
            overlay.flash(error.localizedDescription)
        }
    }

    @objc func toggleAppearance(_ sender: Any?) {
        let udid = udid
        Task {
            await store.perform(nil) { simctl in
                let current = try await simctl.appearance(udid)
                try await simctl.setAppearance(udid, current == .dark ? .light : .dark)
            }
        }
    }

    @objc func setScaleMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ScaleMode,
              let screen = window?.screen ?? NSScreen.main else { return }
        applyZoom(zoom(for: mode, on: screen), animate: true)
    }

    @objc func toggleBezel(_ sender: Any?) {
        Preferences.showBezel.toggle()
    }

    @objc func toggleStayOnTop(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc func saveScreen(_ sender: Any?) {
        let name = store.device(udid)?.name ?? "Simulator"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = Preferences.screenshotFolder
            .appendingPathComponent("Simulator Screenshot - \(name) - \(formatter.string(from: Date())).png")
        let udid = udid
        Task {
            if await store.perform(nil, { try await $0.screenshot(udid, to: file) }) {
                overlay.flash("Saved to \(file.deletingLastPathComponent().lastPathComponent)")
            }
        }
    }

    @objc func copyScreen(_ sender: Any?) {
        guard let surface = renderer.currentSurface else { return }
        let image = CIImage(ioSurface: surface)
        let rep = NSCIImageRep(ciImage: image)
        let picture = NSImage(size: rep.size)
        picture.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
        overlay.flash("Screen copied")
    }

    /// Edit > Paste: hands the Mac's clipboard to the device and pastes it where the cursor is.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let udid = udid
        Task {
            if await store.perform(nil, { try await $0.copyToDevicePasteboard(udid, text: text) }) {
                typeKeys([0x19], modifier: KeyboardMap.leftCommand)
            }
        }
    }

    /// Edit > Copy: copies the device's selection and brings it to the Mac's clipboard.
    @objc func copy(_ sender: Any?) {
        typeKeys([0x06], modifier: KeyboardMap.leftCommand)
        let udid = udid
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            var text = ""
            if await store.perform(nil, { text = try await $0.devicePasteboard(udid) }), !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// Types the Mac's clipboard as key strokes, for fields that refuse a paste.
    @objc func typePasteboard(_ sender: Any?) {
        guard let hid, let text = NSPasteboard.general.string(forType: .string) else { return }
        guard let strokes = KeyboardMap.strokes(forTyping: text) else {
            overlay.flash("Only plain US keyboard characters can be typed")
            return
        }
        Task {
            for stroke in strokes {
                if stroke.shift { hid.sendKeyUsage(KeyboardMap.leftShift, down: true) }
                hid.sendKeyUsage(stroke.usage, down: true)
                hid.sendKeyUsage(stroke.usage, down: false)
                if stroke.shift { hid.sendKeyUsage(KeyboardMap.leftShift, down: false) }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    @objc func openURL(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "A web address or a custom URL scheme to open on the device."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com or myapp://path"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let url = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty, let self else { return }
            MainActor.assumeIsolated {
                let udid = self.udid
                Task { await self.store.perform(nil) { try await $0.openURL(udid, url) } }
            }
        }
    }

    @objc func restartDevice(_ sender: Any?) {
        Task { await cycle(erase: false) }
    }

    @objc func eraseDevice(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Erase all content and settings?"
        alert.informativeText = "Every app, file and setting on \(store.device(udid)?.name ?? "this simulator") will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.cycle(erase: true) }
            }
        }
    }

    /// Restart or erase while keeping the window open, then reconnect.
    private func cycle(erase: Bool) async {
        lifecycleInFlight = true
        detach()
        overlay.show(erase ? "Erasing…" : "Restarting…", spinning: true)
        let udid = udid
        let ok = await store.perform(udid) { simctl in
            try await simctl.shutdown(udid)
            if erase { try await simctl.erase(udid) }
            try await simctl.waitUntilBooted(udid)
        }
        lifecycleInFlight = false
        orientation = .portrait
        renderer.setOrientation(.portrait)
        chromeView.setOrientation(.portrait)
        if ok { await attach() } else { overlay.show(store.lastError ?? "The simulator did not restart.") }
    }

    @objc func shutDownDevice(_ sender: Any?) {
        let store = store, udid = udid
        close()
        if !Preferences.shutDownOnClose {
            Task { await store.shutdown(udid) }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setScaleMode(_:)):
            // Checked when the window is at that mode's size, give or take a pixel or two.
            if let mode = menuItem.representedObject as? ScaleMode, let screen = window?.screen ?? NSScreen.main {
                menuItem.state = abs(zoom(for: mode, on: screen) - currentZoom) < 0.01 ? .on : .off
            }
            return window?.styleMask.contains(.fullScreen) == false
        case #selector(toggleBezel(_:)):
            menuItem.state = Preferences.showBezel ? .on : .off
            return true
        case #selector(toggleStayOnTop(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        case #selector(toggleHardwareKeyboard(_:)):
            menuItem.state = Preferences.hardwareKeyboard ? .on : .off
            return display != nil
        case #selector(saveScreen(_:)), #selector(restartDevice(_:)), #selector(eraseDevice(_:)),
             #selector(shutDownDevice(_:)), #selector(setScaleMode(_:)):
            return true
        default:
            // Everything else talks to a running device.
            return display != nil && !lifecycleInFlight
        }
    }
}

/// A boolean shared between the display stream's queue and the main thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag and returns what it was before.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = true
        return old
    }

    func clear() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

private extension TouchEdge {
    init(_ edge: ScreenGeometry.EdgeKind) {
        switch edge {
        case .none: self = .none
        case .top: self = .top
        case .left: self = .left
        case .bottom: self = .bottom
        case .right: self = .right
        }
    }
}

/// Text over the screen while the device boots, plus short confirmations.
final class StatusOverlayView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stack: NSStackView
    private var flashGeneration = 0

    override init(frame: NSRect) {
        stack = NSStackView(views: [spinner, label])
        super.init(frame: frame)
        wantsLayer = true
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 260
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// True while covering a screen that isn't there yet. A flash over a running screen lets
    /// clicks through.
    private var blocksInput = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocksInput ? super.hitTest(point) : nil
    }

    func show(_ text: String, spinning: Bool = false) {
        flashGeneration += 1
        label.stringValue = text
        spinner.isHidden = !spinning
        spinning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        layer?.backgroundColor = NSColor.black.cgColor
        blocksInput = true
        isHidden = false
    }

    func hide() {
        spinner.stopAnimation(nil)
        blocksInput = false
        isHidden = true
    }

    /// A brief message over a running screen.
    func flash(_ text: String) {
        flashGeneration += 1
        let generation = flashGeneration
        label.stringValue = text
        spinner.isHidden = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        blocksInput = false
        isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.isHidden = true
        }
    }
}
