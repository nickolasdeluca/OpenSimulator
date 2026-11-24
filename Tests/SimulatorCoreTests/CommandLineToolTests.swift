import CoreGraphics
import Foundation
import Testing
@testable import SimulatorCore

struct CommandLineToolTests {
    typealias Tool = CommandLineTool

    func parse(_ line: String...) throws -> Tool.Invocation {
        try Tool.parse(line)
    }

    @Test func parsesTouchesWithDefaults() throws {
        #expect(try parse("tap", "10", "20").command == .tap(CGPoint(x: 10, y: 20), count: 1))
        #expect(try parse("tap", "10.5", "20", "--count", "2").command == .tap(CGPoint(x: 10.5, y: 20), count: 2))
        #expect(try parse("longpress", "1", "2").command == .longPress(CGPoint(x: 1, y: 2), duration: 0.8))
        #expect(try parse("swipe", "1", "2", "3", "4", "--duration", "0.5").command
                == .swipe(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), duration: 0.5))
    }

    @Test func deviceAndJSONCanComeAnywhere() throws {
        let invocation = try parse("--device", "iPad Air", "home", "--json")
        #expect(invocation.device == "iPad Air")
        #expect(invocation.command == .home)
    }

    @Test func keysTakeNamesCharactersAndModifiers() throws {
        #expect(try parse("key", "b", "--mods", "cmd").command
                == .key(.init(usage: 0x05, modifiers: [KeyboardMap.leftCommand]), count: 1))
        #expect(try parse("key", "Return").command == .key(.init(usage: 0x28), count: 1))
        // An uppercase character brings its own Shift.
        #expect(try parse("key", "Z", "--mods", "cmd").command
                == .key(.init(usage: 0x1D, modifiers: [KeyboardMap.leftCommand, KeyboardMap.leftShift]), count: 1))
        #expect(throws: Tool.Failure.self) { try parse("key", "hyper") }
        #expect(throws: Tool.Failure.self) { try parse("key", "a", "--mods", "meta") }
    }

    @Test func doubleDashLetsTextStartWithADash() throws {
        #expect(try parse("type", "--", "-x").command == .type("-x", paste: false))
        #expect(try parse("type", "hi", "--paste").command == .type("hi", paste: true))
    }

    @Test func refusesBadArguments() {
        #expect(throws: Tool.Failure.self) { try parse("tap", "1") }
        #expect(throws: Tool.Failure.self) { try parse("tap", "a", "b") }
        #expect(throws: Tool.Failure.self) { try parse("tap", "1", "2", "--duration", "1") }
        #expect(throws: Tool.Failure.self) { try parse("rotate", "sideways") }
        #expect(throws: Tool.Failure.self) { try parse("fly") }
        #expect(throws: Tool.Failure.self) { try parse("--device") }
    }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try Tool.parse([]).command == .help)
    }

    // MARK: Devices

    let ipad = Tool.Candidate(udid: "AAAA", name: "iPad Air", isBooted: true)
    let phone = Tool.Candidate(udid: "BBBB", name: "iPhone", isBooted: false)
    let otherIpad = Tool.Candidate(udid: "CCCC", name: "iPad Air", isBooted: false)

    @Test func withoutAQueryTheOnlyBootedDeviceIsUsed() throws {
        #expect(try Tool.resolveDevice(nil, among: [ipad, phone]) == ipad)
        #expect(throws: Tool.Failure.self) { try Tool.resolveDevice(nil, among: [phone]) }
        let second = Tool.Candidate(udid: "DDDD", name: "iPhone 2", isBooted: true)
        #expect(throws: Tool.Failure.self) { try Tool.resolveDevice(nil, among: [ipad, second]) }
    }

    @Test func queryMatchesUDIDOrName() throws {
        #expect(try Tool.resolveDevice("aaaa", among: [ipad, phone]) == ipad)
        // A shared name picks the booted one.
        #expect(try Tool.resolveDevice("iPad Air", among: [ipad, otherIpad, phone]) == ipad)
        #expect(throws: Tool.Failure.self) { try Tool.resolveDevice("iPhone", among: [ipad, phone]) }
        #expect(throws: Tool.Failure.self) { try Tool.resolveDevice("Pixel", among: [ipad, phone]) }
    }

    // MARK: Geometry

    @Test func pointsBecomePortraitTouchSpace() {
        let size = CGSize(width: 1000, height: 2000)
        #expect(Tool.touchPoint(CGPoint(x: 250, y: 500), portraitPoints: size, orientation: .portrait)
                == CGPoint(x: 0.25, y: 0.25))
        // In landscape the shown screen is 2000 x 1000; its top left is the portrait bottom left
        // for landscape left.
        #expect(Tool.touchPoint(CGPoint(x: 0, y: 0), portraitPoints: size, orientation: .landscapeLeft)
                == CGPoint(x: 0, y: 1))
        #expect(Tool.touchPoint(CGPoint(x: 1001, y: 0), portraitPoints: size, orientation: .portrait) == nil)
    }

    @Test func orientationIsRememberedPerBoot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("orientation.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = OrientationRecord(url: url)
        #expect(record.orientation(udid: "abc", session: "1") == .portrait)
        record.set(.landscapeRight, udid: "abc", session: "1")
        #expect(record.orientation(udid: "ABC", session: "1") == .landscapeRight)
        #expect(record.orientation(udid: "abc", session: "2") == .portrait)
    }
}
