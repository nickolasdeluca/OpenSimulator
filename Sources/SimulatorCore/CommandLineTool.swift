import CoreGraphics
import Foundation

/// The parts of the `opensim` command line tool that don't need a device: parsing, choosing the
/// device, and turning screen points into the digitizer's coordinates.
public enum CommandLineTool {
    public enum Rotation: Equatable, Sendable {
        case left, right
        case to(DeviceOrientation)
    }

    public enum Command: Equatable, Sendable {
        case tap(CGPoint, count: Int)
        case longPress(CGPoint, duration: Double)
        case swipe(from: CGPoint, to: CGPoint, duration: Double)
        case type(String, paste: Bool)
        case key(KeyboardMap.Chord, count: Int)
        case rotate(Rotation)
        case home
        case info
        case help
    }

    public struct Invocation: Equatable, Sendable {
        public var device: String?
        public var command: Command
    }

    /// Exit codes a script can tell apart.
    public enum ExitCode: Int32, Sendable {
        case failure = 1
        case usage = 2
        case device = 3
        case unsupported = 4
        /// The person pressed Stop in the device's window.
        case stopped = 5
    }

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public let code: ExitCode
        public init(_ message: String, code: ExitCode = .failure) {
            self.message = message
            self.code = code
        }
        public var errorDescription: String? { message }
    }

    static func usage(_ message: String) -> Failure { Failure(message, code: .usage) }

    // MARK: Parsing

    /// Options may come anywhere; `--` ends them, so `type -- "-1"` types a leading dash.
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var device: String?
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        let valued: Set<String> = ["--device", "--count", "--duration", "--mods"]
        let switches: Set<String> = ["--json", "--paste", "--help", "-h"]

        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("-") || Double(argument) != nil {
                positional.append(argument)
            } else if argument == "--" {
                optionsEnded = true
            } else if valued.contains(argument) {
                guard index < arguments.count else { throw usage("\(argument) needs a value.") }
                options[argument] = arguments[index]
                index += 1
            } else if switches.contains(argument) {
                flags.insert(argument)
            } else {
                throw usage("Unknown option \(argument).")
            }
        }
        device = options.removeValue(forKey: "--device")
        // Output is always JSON, so --json is accepted everywhere and changes nothing.
        flags.remove("--json")

        if flags.contains("--help") || flags.contains("-h") || positional.first == "help" || positional.isEmpty {
            return Invocation(device: device, command: .help)
        }
        let name = positional.removeFirst()
        var used: Set<String> = []
        func option(_ key: String) -> String? {
            used.insert(key)
            return options[key]
        }
        func flag(_ key: String) -> Bool {
            used.insert(key)
            return flags.contains(key)
        }

        let command: Command
        switch name {
        case "tap":
            let point = try parsePoint(positional, name)
            let count = try integer(option("--count"), "--count", default: 1)
            guard (1...3).contains(count) else { throw usage("--count must be 1, 2 or 3.") }
            command = .tap(point, count: count)
        case "longpress":
            let point = try parsePoint(positional, name)
            command = .longPress(point, duration: try seconds(option("--duration"), default: 0.8))
        case "swipe":
            let numbers = try parseNumbers(positional, count: 4, name, shape: "X1 Y1 X2 Y2")
            command = .swipe(
                from: CGPoint(x: numbers[0], y: numbers[1]),
                to: CGPoint(x: numbers[2], y: numbers[3]),
                duration: try seconds(option("--duration"), default: 0.3))
        case "type":
            guard positional.count == 1 else { throw usage("type takes one argument, the text. Quote it.") }
            guard !positional[0].isEmpty else { throw usage("Nothing to type.") }
            command = .type(positional[0], paste: flag("--paste"))
        case "key":
            guard positional.count == 1 else { throw usage("key takes one key name, e.g. return or b.") }
            let modifiers = try parseModifiers(option("--mods"))
            guard let chord = KeyboardMap.chord(forKeyName: positional[0], modifiers: modifiers) else {
                throw usage("Unknown key \"\(positional[0])\". Use a character, or one of: "
                            + KeyboardMap.usageByKeyName.keys.sorted().joined(separator: ", ") + ".")
            }
            let count = try integer(option("--count"), "--count", default: 1)
            guard count >= 1 else { throw usage("--count must be at least 1.") }
            command = .key(chord, count: count)
        case "rotate":
            guard positional.count == 1, let rotation = rotations[positional[0]] else {
                throw usage("rotate takes left, right, portrait, landscape-left, landscape-right or upside-down.")
            }
            command = .rotate(rotation)
        case "home":
            guard positional.isEmpty else { throw usage("home takes no arguments.") }
            command = .home
        case "info":
            command = .info
        default:
            throw usage("Unknown command \"\(name)\". Run opensim help.")
        }
        if let stray = Set(options.keys).union(flags).subtracting(used).sorted().first {
            throw usage("\(stray) does not apply to \(name).")
        }
        return Invocation(device: device, command: command)
    }

    static let rotations: [String: Rotation] = [
        "left": .left, "right": .right,
        "portrait": .to(.portrait), "upside-down": .to(.portraitUpsideDown),
        "landscape-left": .to(.landscapeLeft), "landscape-right": .to(.landscapeRight),
    ]

    public static func orientationName(_ orientation: DeviceOrientation) -> String {
        rotations.first { $0.value == .to(orientation) }?.key ?? "portrait"
    }

    static func parseNumbers(_ values: [String], count: Int, _ command: String, shape: String) throws -> [Double] {
        guard values.count == count else { throw usage("\(command) takes \(shape), in points.") }
        return try values.map { value in
            guard let number = Double(value), number.isFinite else {
                throw usage("\"\(value)\" is not a number.")
            }
            return number
        }
    }

    static func parsePoint(_ values: [String], _ command: String) throws -> CGPoint {
        let numbers = try parseNumbers(values, count: 2, command, shape: "X Y")
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    static func integer(_ value: String?, _ name: String, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let number = Int(value) else { throw usage("\(name) must be a whole number.") }
        return number
    }

    static func seconds(_ value: String?, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let number = Double(value), number > 0, number <= 30 else {
            throw usage("--duration must be seconds between 0 and 30.")
        }
        return number
    }

    static func parseModifiers(_ value: String?) throws -> [UInt32] {
        guard let value else { return [] }
        var usages: [UInt32] = []
        for name in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            guard let usage = KeyboardMap.modifierUsageByName[name] else {
                throw usage("Unknown modifier \"\(name)\". Use cmd, shift, alt or ctrl.")
            }
            if !usages.contains(usage) { usages.append(usage) }
        }
        return usages
    }

    // MARK: Choosing the device

    public struct Candidate: Equatable, Sendable {
        public let udid: String
        public let name: String
        public let isBooted: Bool
        public init(udid: String, name: String, isBooted: Bool) {
            self.udid = udid
            self.name = name
            self.isBooted = isBooted
        }
    }

    /// The device `query` names, by UDID or exact name, or the only booted one when there is no
    /// query. A name shared by several devices resolves to the booted one, if exactly one is.
    public static func resolveDevice(_ query: String?, among devices: [Candidate]) throws -> Candidate {
        let booted = devices.filter(\.isBooted)
        guard let query else {
            switch booted.count {
            case 1: return booted[0]
            case 0: throw Failure("No simulator is booted. Boot one with xcrun simctl boot.", code: .device)
            default:
                throw Failure("More than one simulator is booted, so pass --device with one of: "
                              + booted.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ") + ".",
                              code: .device)
            }
        }
        let chosen: Candidate
        if let match = devices.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) {
            chosen = match
        } else {
            let named = devices.filter { $0.name == query }
            let namedBooted = named.filter(\.isBooted)
            if named.count == 1 {
                chosen = named[0]
            } else if namedBooted.count == 1 {
                chosen = namedBooted[0]
            } else if named.isEmpty {
                throw Failure("No simulator is named or has the UDID \"\(query)\".", code: .device)
            } else {
                throw Failure("\(named.count) simulators are named \"\(query)\". Pass a UDID instead.", code: .device)
            }
        }
        guard chosen.isBooted else { throw Failure("\(chosen.name) is not booted.", code: .device) }
        return chosen
    }

    // MARK: Geometry

    /// A point on the screen as it is shown, in points, to the portrait framebuffer's normalized
    /// space that touches use. Nil when the point is off the screen.
    public static func touchPoint(
        _ point: CGPoint,
        portraitPoints size: CGSize,
        orientation: DeviceOrientation
    ) -> CGPoint? {
        let shown = orientation.displayedSize(portrait: size)
        guard shown.width > 0, shown.height > 0,
              (0...shown.width).contains(point.x), (0...shown.height).contains(point.y)
        else { return nil }
        let normalized = CGPoint(x: point.x / shown.width, y: point.y / shown.height)
        return ScreenGeometry.portraitPoint(fromShown: normalized, orientation: orientation)
    }
}

/// The orientation each booted device was last turned to, shared by the app and `opensim`.
/// Nothing in the guest reports it, and a device boots in portrait, so an entry counts only for the
/// boot it was written in.
public struct OrientationRecord: Sendable {
    public let url: URL

    public init(url: URL = OrientationRecord.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenSimulator/orientation.json")
    }

    struct Entry: Codable {
        let session: String
        let orientation: Int
    }

    public func orientation(udid: String, session: String) -> DeviceOrientation {
        guard let entry = load()[udid.uppercased()], entry.session == session else { return .portrait }
        return DeviceOrientation(rawValue: entry.orientation) ?? .portrait
    }

    public func set(_ orientation: DeviceOrientation, udid: String, session: String) {
        var entries = load()
        entries[udid.uppercased()] = Entry(session: session, orientation: orientation.rawValue)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
