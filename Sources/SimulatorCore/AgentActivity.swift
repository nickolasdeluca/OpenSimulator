import CoreGraphics
import Foundation

/// What `opensim` tells the app while an agent drives a device, so the person watching the window
/// sees each touch and key the way they would see a person's, and can stop the agent. It travels
/// as distributed notifications: local to this Mac, no port, and nothing runs when nobody listens.
public enum AgentActivity {
    /// Posted by `opensim` with the device's UDID as the object.
    public static let event = Notification.Name("OpenSimulator.agent.event")
    /// Posted by `opensim` to ask the app to show the device in a window.
    public static let showRequest = Notification.Name("OpenSimulator.agent.show")
    /// Posted by the app once a window shows the device, in answer to `showRequest`.
    public static let shown = Notification.Name("OpenSimulator.agent.shown")

    public enum TouchPhase: String, Sendable { case down, move, up }

    public enum Event: Equatable, Sendable {
        /// `point` is normalized to the portrait framebuffer, as touches are sent.
        case touch(CGPoint, TouchPhase)
        /// Text typed or a key pressed, as a short caption such as "⌘B".
        case keys(String)
        case rotated(DeviceOrientation)
        /// An agent process starts or stops driving the device. The app watches `pid` so a session
        /// that ends without saying so still clears.
        case session(pid: Int32, active: Bool)

        public var userInfo: [String: Any] {
            switch self {
            case let .touch(point, phase):
                ["kind": "touch", "x": Double(point.x), "y": Double(point.y), "phase": phase.rawValue]
            case let .keys(caption):
                ["kind": "keys", "caption": caption]
            case let .rotated(orientation):
                ["kind": "rotated", "orientation": orientation.rawValue]
            case let .session(pid, active):
                ["kind": "session", "pid": Int(pid), "active": active]
            }
        }

        public init?(userInfo: [AnyHashable: Any]?) {
            guard let info = userInfo, let kind = info["kind"] as? String else { return nil }
            switch kind {
            case "touch":
                guard let x = info["x"] as? Double, let y = info["y"] as? Double,
                      let raw = info["phase"] as? String, let phase = TouchPhase(rawValue: raw) else { return nil }
                self = .touch(CGPoint(x: x, y: y), phase)
            case "keys":
                guard let caption = info["caption"] as? String else { return nil }
                self = .keys(caption)
            case "rotated":
                guard let raw = info["orientation"] as? Int, let orientation = DeviceOrientation(rawValue: raw) else {
                    return nil
                }
                self = .rotated(orientation)
            case "session":
                guard let pid = info["pid"] as? Int, let active = info["active"] as? Bool else { return nil }
                self = .session(pid: Int32(pid), active: active)
            default:
                return nil
            }
        }
    }

    static let keyNames: [UInt32: String] = [
        0x28: "Return", 0x29: "Esc", 0x2A: "Delete", 0x2B: "Tab", 0x2C: "Space", 0x39: "Caps Lock",
        0x4C: "Forward Delete", 0x4A: "Home", 0x4D: "End", 0x4B: "Page Up", 0x4E: "Page Down",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
    ]

    /// How a key chord reads in a caption: "⌘⇧Z", "⌘B", "Return".
    public static func caption(for chord: KeyboardMap.Chord) -> String {
        let symbols: [(UInt32, String)] = [
            (KeyboardMap.leftControl, "⌃"), (KeyboardMap.leftOption, "⌥"),
            (KeyboardMap.leftShift, "⇧"), (KeyboardMap.leftCommand, "⌘"),
        ]
        let prefix = symbols.filter { chord.modifiers.contains($0.0) }.map(\.1).joined()
        if let name = keyNames[chord.usage] { return prefix + name }
        if (0x3A...0x45).contains(chord.usage) { return prefix + "F\(chord.usage - 0x39)" }
        let character = KeyboardMap.strokeByCharacter.first { $0.value.usage == chord.usage && !$0.value.shift }?.key
        return prefix + (character.map { String($0).uppercased() } ?? "Key")
    }
}

/// Devices whose window's Stop button the person pressed. `opensim` refuses to drive them until
/// the person allows it again or the device restarts. A file, because a one-shot `opensim` call
/// has no time to wait for a notification.
public struct AgentBlockList: Sendable {
    public let url: URL

    public init(url: URL = AgentBlockList.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenSimulator/agent-stopped.json")
    }

    public func isBlocked(udid: String, session: String) -> Bool {
        load()[udid.uppercased()] == session
    }

    public func setBlocked(_ blocked: Bool, udid: String, session: String) {
        var entries = load()
        entries[udid.uppercased()] = blocked ? session : nil
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
