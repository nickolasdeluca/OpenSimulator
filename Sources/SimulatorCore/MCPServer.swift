import CoreGraphics
import Foundation

/// A Model Context Protocol server over stdio: one JSON-RPC message per line in, one per line
/// out. It knows the protocol and the tools' shapes; `opensim mcp` supplies what calling a tool does.
public final class MCPServer {
    public enum Content {
        case text(String)
        case image(Data, mimeType: String)
    }

    /// Runs a tool. A thrown error becomes a tool result marked as an error, which the agent reads.
    public typealias Handler = (_ device: String?, _ command: MCPServer.Command) throws -> [Content]

    public enum Command: Equatable {
        case action(CommandLineTool.Command)
        case screenshot
        case openURL(String)
        case listDevices
    }

    public let version: String
    private let handler: Handler
    public private(set) var clientName: String?

    public init(version: String, handler: @escaping Handler) {
        self.version = version
        self.handler = handler
    }

    static let latestProtocol = "2025-06-18"

    /// The reply to one line, or nil for a notification or a blank line.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = object["id"]
        guard let method = object["method"] as? String else {
            return id.map { reply(id: $0, error: -32600, "Invalid request") } ?? nil
        }
        // Notifications have no id and get no reply.
        guard let id else { return nil }
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any] { clientName = info["name"] as? String }
            let requested = params["protocolVersion"] as? String
            return reply(id: id, result: [
                "protocolVersion": requested ?? Self.latestProtocol,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "opensim", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return reply(id: id, result: [String: Any]())
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return reply(id: id, error: -32602, "Missing tool name") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return reply(id: id, result: call(name, arguments))
        default:
            return reply(id: id, error: -32601, "Unknown method \(method)")
        }
    }

    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            let command = try Self.command(name, arguments)
            let content = try handler(arguments["device"] as? String, command)
            return ["content": content.map(Self.json), "isError": false]
        } catch {
            return ["content": [Self.json(.text(error.localizedDescription))], "isError": true]
        }
    }

    static func json(_ content: Content) -> [String: Any] {
        switch content {
        case let .text(text): ["type": "text", "text": text]
        case let .image(data, mimeType): ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
        }
    }

    func reply(id: Any, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func reply(id: Any, error code: Int, _ message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Tools

    static let instructions = """
    Drives an iOS simulator the person can watch in OpenSimulator. Every touch and key shows in \
    the device's window, and the person can press Stop there; if a tool says the agent was \
    stopped, ask the person before going on. Coordinates are points, origin top left, in the \
    screen as `screenshot` returns it, so a position in the screenshot can be tapped as is.
    """

    static let deviceProperty: [String: Any] = [
        "type": "string",
        "description": "UDID or name of a booted simulator. Optional when exactly one is booted.",
    ]

    static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                     required: [String] = []) -> [String: Any] {
        var all = properties
        all["device"] = deviceProperty
        return [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": all, "required": required],
        ]
    }

    static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }

    static let tools: [[String: Any]] = [
        tool("list_devices", "Booted simulators, with UDID, name and runtime."),
        tool("screenshot", "The screen as an image, one image pixel per point, in the current orientation."),
        tool("device_info", "Screen size in points, scale and orientation."),
        tool("tap", "Tap a point. count 2 double taps, which selects a word in text.",
             ["x": number("Points from the left"), "y": number("Points from the top"),
              "count": ["type": "integer", "minimum": 1, "maximum": 3, "description": "Taps, 1 to 3"]],
             required: ["x", "y"]),
        tool("long_press", "Touch and hold a point.",
             ["x": number("Points from the left"), "y": number("Points from the top"),
              "duration": number("Seconds to hold, default 0.8")],
             required: ["x", "y"]),
        tool("swipe", "Drag from one point to another: scroll, move a slider or a selection handle.",
             ["x1": number("Start, points from the left"), "y1": number("Start, points from the top"),
              "x2": number("End, points from the left"), "y2": number("End, points from the top"),
              "duration": number("Seconds, default 0.3")],
             required: ["x1", "y1", "x2", "y2"]),
        tool("type_text", "Type text on a hardware keyboard into whatever has focus. Accented Latin letters work; for other characters set paste.",
             ["text": ["type": "string"],
              "paste": ["type": "boolean", "description": "Send through the device's pasteboard and ⌘V, replacing what it held"]],
             required: ["text"]),
        tool("press_key", "Press a key, optionally with modifiers, e.g. key b with modifiers [cmd] for bold.",
             ["key": ["type": "string", "description": "A character, or return, escape, delete, tab, space, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1 to f12"],
              "modifiers": ["type": "array", "items": ["type": "string", "enum": ["cmd", "shift", "alt", "ctrl"]]],
              "count": ["type": "integer", "minimum": 1, "description": "Times to press it"]],
             required: ["key"]),
        tool("rotate", "Turn the device.",
             ["to": ["type": "string", "enum": ["left", "right", "portrait", "landscape-left", "landscape-right", "upside-down"]]],
             required: ["to"]),
        tool("press_home", "Press the Home button."),
        tool("open_url", "Open a URL on the device, in Safari or the app that handles it.",
             ["url": ["type": "string"]], required: ["url"]),
    ]

    /// Turns a tool call into a command, with the same checks the command line makes.
    public static func command(_ name: String, _ arguments: [String: Any]) throws -> Command {
        func number(_ key: String) throws -> Double {
            guard let value = (arguments[key] as? NSNumber)?.doubleValue, value.isFinite else {
                throw CommandLineTool.usage("\(key) must be a number.")
            }
            return value
        }
        func optional(_ key: String) -> String? {
            (arguments[key] as? NSNumber).map { "\($0)" }
        }
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw CommandLineTool.usage("\(key) is required.")
            }
            return value
        }

        // The command line parser already checks ranges and names, so tool calls go through it.
        var line: [String]
        switch name {
        case "list_devices": return .listDevices
        case "screenshot": return .screenshot
        case "open_url": return .openURL(try string("url"))
        case "device_info": line = ["info"]
        case "press_home": line = ["home"]
        case "tap":
            line = ["tap", "\(try number("x"))", "\(try number("y"))"]
            if let count = optional("count") { line += ["--count", count] }
        case "long_press":
            line = ["longpress", "\(try number("x"))", "\(try number("y"))"]
            if let duration = optional("duration") { line += ["--duration", duration] }
        case "swipe":
            line = ["swipe"] + (try ["x1", "y1", "x2", "y2"].map { "\(try number($0))" })
            if let duration = optional("duration") { line += ["--duration", duration] }
        case "type_text":
            line = ["type", "--", try string("text")]
            if arguments["paste"] as? Bool == true { line.insert("--paste", at: 1) }
        case "press_key":
            line = ["key", "--", try string("key")]
            if let modifiers = arguments["modifiers"] as? [String], !modifiers.isEmpty {
                line.insert(contentsOf: ["--mods", modifiers.joined(separator: ",")], at: 1)
            }
            if let count = optional("count") { line.insert(contentsOf: ["--count", count], at: 1) }
        case "rotate": line = ["rotate", try string("to")]
        default: throw CommandLineTool.usage("Unknown tool \(name).")
        }
        return .action(try CommandLineTool.parse(line).command)
    }
}
