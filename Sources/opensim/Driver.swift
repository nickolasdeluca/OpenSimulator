import AppKit
import Foundation
import ImageIO
import SimBridge
import SimulatorCore
import UniformTypeIdentifiers

typealias Tool = CommandLineTool

/// Carries out commands on booted devices for both the command line and the MCP server, and tells
/// OpenSimulator about each one so the person watching sees it happen.
final class Driver {
    let developerDir: String
    let core: CoreSimulator
    /// Kept for the life of the process, so an MCP session connects to each device once.
    private var hids: [String: HIDClient] = [:]
    private var shownDevices: Set<String> = []
    /// Devices this process has announced a session on, for the MCP server.
    private(set) var sessionDevices: Set<String> = []
    var announcesSessions = false

    init() throws {
        developerDir = try Xcode.developerDirectory()
        do {
            core = try CoreSimulator.connect(withDeveloperDirectory: developerDir)
        } catch {
            throw Tool.Failure(error.localizedDescription, code: .unsupported)
        }
    }

    // MARK: Devices

    struct Target {
        let device: DeviceSnapshot
        let bootSession: String

        var udid: String { device.udid }
        var orientation: DeviceOrientation {
            OrientationRecord().orientation(udid: udid, session: bootSession)
        }
        /// The portrait screen in points.
        var portraitPoints: CGSize {
            let scale = max(device.pointScale, 1)
            return CGSize(width: device.mainScreenPixelSize.width / scale,
                          height: device.mainScreenPixelSize.height / scale)
        }
    }

    func target(_ query: String?) throws -> Target {
        let devices = core.devices()
        let candidates = devices.map { Tool.Candidate(udid: $0.udid, name: $0.name, isBooted: $0.state == .booted) }
        let chosen = try Tool.resolveDevice(query, among: candidates)
        guard let device = devices.first(where: { $0.udid == chosen.udid }) else {
            throw Tool.Failure("The device went away.", code: .device)
        }
        return Target(device: device, bootSession: ResourceMonitor.bootSession(udid: device.udid) ?? "unknown")
    }

    func bootedDevices() -> [DeviceSnapshot] {
        core.devices().filter { $0.state == .booted }
    }

    private func hid(for target: Target) throws -> HIDClient {
        if let hid = hids[target.udid] { return hid }
        let hid = try core.openHID(forDevice: target.udid)
        hids[target.udid] = hid
        return hid
    }

    /// Everything that changes the device goes through here: it must be on screen, and the person
    /// must not have stopped the agent.
    private func prepare(_ target: Target) throws {
        if AgentBlockList().isBlocked(udid: target.udid, session: target.bootSession) {
            throw Tool.Failure(
                "The person watching \(target.device.name) in OpenSimulator stopped the agent. "
                + "Ask them before going on; they allow it again from the device's window.",
                code: .stopped)
        }
        show(target)
        if announcesSessions, !sessionDevices.contains(target.udid) {
            sessionDevices.insert(target.udid)
            post(.session(pid: getpid(), active: true), udid: target.udid)
        }
    }

    // MARK: Telling the app

    func post(_ event: AgentActivity.Event, udid: String) {
        DistributedNotificationCenter.default().postNotificationName(
            AgentActivity.event, object: udid, userInfo: event.userInfo, deliverImmediately: true)
    }

    func endSessions() {
        for udid in sessionDevices { post(.session(pid: getpid(), active: false), udid: udid) }
        sessionDevices.removeAll()
    }

    /// Asks OpenSimulator to show the device, starting it if needed, and waits for the window so
    /// the person sees the agent's first touch. Without the app installed the agent carries on.
    private func show(_ target: Target) {
        guard !shownDevices.contains(target.udid) else { return }
        shownDevices.insert(target.udid)
        guard let app = Self.appURL(), let bundleID = Bundle(url: app)?.bundleIdentifier else { return }

        var shown = false
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: AgentActivity.shown, object: target.udid, queue: nil) { _ in
            shown = true
        }
        defer { center.removeObserver(observer) }

        let timeout: TimeInterval
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            // At launch the app opens a window for every booted device by itself.
            _ = try? ProcessRunner.runSync("/usr/bin/open", ["-g", app.path])
            timeout = 30
        } else {
            center.postNotificationName(AgentActivity.showRequest, object: target.udid, userInfo: nil,
                                        deliverImmediately: true)
            timeout = 8
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !shown, Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.25)))
        }
    }

    /// The app this tool ships in, or the one installed under the app's bundle identifier.
    static func appURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        let identifier = ProcessInfo.processInfo.environment["OPENSIM_APP_ID"] ?? "com.nickolasdeluca.OpenSimulator"
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    // MARK: Commands

    /// Runs one command. Returns JSON for commands that answer something.
    func run(_ command: Tool.Command, device query: String?) throws -> String? {
        let target = try target(query)
        switch command {
        case .help:
            return nil

        case .info:
            let orientation = target.orientation
            let points = orientation.displayedSize(portrait: target.portraitPoints)
            let pixels = orientation.displayedSize(portrait: target.device.mainScreenPixelSize)
            return Self.json([
                "udid": target.udid,
                "name": target.device.name,
                "deviceType": target.device.deviceTypeName,
                "runtime": target.device.runtimeName,
                "width": Double(points.width),
                "height": Double(points.height),
                "scale": Double(target.device.pointScale),
                "pixelWidth": Double(pixels.width),
                "pixelHeight": Double(pixels.height),
                "orientation": Tool.orientationName(orientation),
            ])

        case let .tap(point, count):
            let native = try touchPoint(point, target)
            try prepare(target)
            let hid = try hid(for: target)
            let edge = Self.edge(for: native)
            for index in 0..<count {
                // Much quicker and iOS reads two single taps rather than a double tap.
                if index > 0 { pause(0.15) }
                touch(hid, native, .down, edge, target)
                pause(0.05)
                touch(hid, native, .up, edge, target)
            }
            try hid.waitUntilSent(withTimeout: 5)

        case let .longPress(point, duration):
            let native = try touchPoint(point, target)
            try prepare(target)
            let hid = try hid(for: target)
            let edge = Self.edge(for: native)
            touch(hid, native, .down, edge, target)
            pause(duration)
            touch(hid, native, .up, edge, target)
            try hid.waitUntilSent(withTimeout: 5)

        case let .swipe(start, end, duration):
            let from = try touchPoint(start, target)
            let to = try touchPoint(end, target)
            try prepare(target)
            let hid = try hid(for: target)
            let edge = Self.edge(for: from)
            // About 60 moves a second, like a finger on glass.
            let steps = max(Int(duration * 60), 2)
            let path = HomeGesture.line(from: from, to: to, steps: steps)
            touch(hid, path[0], .down, edge, target)
            for point in path.dropFirst() {
                pause(duration / Double(steps))
                touch(hid, point, .move, edge, target)
            }
            touch(hid, path[path.count - 1], .up, edge, target)
            try hid.waitUntilSent(withTimeout: 5)

        case let .type(text, paste):
            if paste {
                try prepare(target)
                try simctl(["pbcopy", target.udid], input: Data(text.utf8))
                post(.keys("⌘V " + Self.quoted(text)), udid: target.udid)
                let hid = try hid(for: target)
                press(KeyboardMap.Chord(usage: 0x19, modifiers: [KeyboardMap.leftCommand]), on: hid)
                try hid.waitUntilSent(withTimeout: 5)
            } else {
                let chords: [KeyboardMap.Chord]
                do {
                    chords = try KeyboardMap.chords(forTyping: text)
                } catch {
                    throw Tool.Failure(error.localizedDescription, code: .usage)
                }
                try prepare(target)
                post(.keys(Self.quoted(text)), udid: target.udid)
                let hid = try hid(for: target)
                for chord in chords {
                    press(chord, on: hid)
                    pause(0.01)
                }
                try hid.waitUntilSent(withTimeout: 10)
            }

        case let .key(chord, count):
            try prepare(target)
            let caption = AgentActivity.caption(for: chord)
            post(.keys(count > 1 ? "\(caption) ×\(count)" : caption), udid: target.udid)
            let hid = try hid(for: target)
            for index in 0..<count {
                if index > 0 { pause(0.01) }
                press(chord, on: hid)
            }
            try hid.waitUntilSent(withTimeout: 5)

        case let .rotate(rotation):
            try prepare(target)
            let next: DeviceOrientation
            switch rotation {
            case .left: next = target.orientation.rotatedLeft
            case .right: next = target.orientation.rotatedRight
            case let .to(orientation): next = orientation
            }
            try core.setOrientation(next.gsEventValue, forDevice: target.udid)
            OrientationRecord().set(next, udid: target.udid, session: target.bootSession)
            post(.rotated(next), udid: target.udid)

        case .home:
            try prepare(target)
            post(.keys("Home"), udid: target.udid)
            let hid = try hid(for: target)
            hid.send(.home, down: true)
            hid.send(.home, down: false)
            try hid.waitUntilSent(withTimeout: 5)
        }
        return nil
    }

    func openURL(_ url: String, device query: String?) throws {
        let target = try target(query)
        try prepare(target)
        post(.keys("Open " + Self.quoted(url)), udid: target.udid)
        try simctl(["openurl", target.udid, url])
    }

    /// The screen as the person sees it, scaled to one pixel per point so a position in the image
    /// is the point to tap.
    func screenshot(device query: String?) throws -> Data {
        let target = try target(query)
        show(target)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("opensim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try simctl(["io", target.udid, "screenshot", "--type=png", file.path])

        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Tool.Failure("The screenshot could not be read.") }
        let points = target.orientation.displayedSize(portrait: target.portraitPoints)
        let width = Int(points.width.rounded()), height = Int(points.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Tool.Failure("The screenshot could not be scaled.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw Tool.Failure("The screenshot could not be scaled.") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Tool.Failure("The screenshot could not be encoded.") }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Tool.Failure("The screenshot could not be encoded.") }
        return output as Data
    }

    // MARK: Helpers

    private func touchPoint(_ point: CGPoint, _ target: Target) throws -> CGPoint {
        let orientation = target.orientation
        guard let native = Tool.touchPoint(point, portraitPoints: target.portraitPoints, orientation: orientation) else {
            let shown = orientation.displayedSize(portrait: target.portraitPoints)
            throw Tool.Failure(
                "(\(Self.format(point.x)), \(Self.format(point.y))) is off the screen, which is "
                + "\(Self.format(shown.width)) x \(Self.format(shown.height)) points in \(Tool.orientationName(orientation)).",
                code: .usage)
        }
        return native
    }

    private func touch(_ hid: HIDClient, _ point: CGPoint, _ phase: AgentActivity.TouchPhase, _ edge: TouchEdge,
                       _ target: Target) {
        let hidPhase: TouchPhase = switch phase {
        case .down: .down
        case .move: .move
        case .up: .up
        }
        hid.sendTouch(at: point, phase: hidPhase, edge: edge)
        post(.touch(point, phase), udid: target.udid)
    }

    private func press(_ chord: KeyboardMap.Chord, on hid: HIDClient) {
        for modifier in chord.modifiers { hid.sendKeyUsage(modifier, down: true) }
        hid.sendKeyUsage(chord.usage, down: true)
        hid.sendKeyUsage(chord.usage, down: false)
        for modifier in chord.modifiers.reversed() { hid.sendKeyUsage(modifier, down: false) }
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @discardableResult
    private func simctl(_ arguments: [String], input: Data? = nil) throws -> String {
        let result = try ProcessRunner.runSync("/usr/bin/xcrun", ["simctl"] + arguments, input: input,
                                               environment: ["DEVELOPER_DIR": developerDir])
        guard result.status == 0 else {
            throw Tool.Failure("simctl \(arguments[0]) failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output
    }

    static func edge(for point: CGPoint) -> TouchEdge {
        switch ScreenGeometry.edge(forPortraitPoint: point) {
        case .none: .none
        case .top: .top
        case .left: .left
        case .bottom: .bottom
        case .right: .right
        }
    }

    static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return "“" + (flat.count > 40 ? flat.prefix(39) + "…" : flat) + "”"
    }

    static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
