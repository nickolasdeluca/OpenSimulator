import CoreGraphics
import Foundation
import Testing
@testable import SimulatorCore

struct AgentActivityTests {
    @Test func eventsSurviveTheTrip() {
        let events: [AgentActivity.Event] = [
            .touch(CGPoint(x: 0.25, y: 0.75), .move),
            .keys("⌘B"),
            .rotated(.landscapeLeft),
            .session(pid: 4242, active: true),
        ]
        for event in events {
            // Distributed notifications carry property lists, so the user info is round-tripped
            // through one, as the system does.
            let data = try? PropertyListSerialization.data(fromPropertyList: event.userInfo, format: .binary, options: 0)
            let back = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [AnyHashable: Any] }
            #expect(AgentActivity.Event(userInfo: back) == event)
        }
        #expect(AgentActivity.Event(userInfo: ["kind": "touch"]) == nil)
    }

    @Test func captionsReadLikeShortcuts() {
        let cmd = KeyboardMap.leftCommand, shift = KeyboardMap.leftShift
        #expect(AgentActivity.caption(for: .init(usage: 0x05, modifiers: [cmd])) == "⌘B")
        #expect(AgentActivity.caption(for: .init(usage: 0x1D, modifiers: [cmd, shift])) == "⇧⌘Z")
        #expect(AgentActivity.caption(for: .init(usage: 0x28)) == "Return")
        #expect(AgentActivity.caption(for: .init(usage: 0x2A)) == "Delete")
        #expect(AgentActivity.caption(for: .init(usage: 0x3B)) == "F2")
    }

    @Test func shownPointUndoesPortraitPoint() {
        let shown = CGPoint(x: 0.2, y: 0.7)
        for orientation in DeviceOrientation.allCases {
            let native = ScreenGeometry.portraitPoint(fromShown: shown, orientation: orientation)
            let back = ScreenGeometry.shownPoint(fromPortrait: native, orientation: orientation)
            #expect(abs(back.x - shown.x) < 1e-9 && abs(back.y - shown.y) < 1e-9)
        }
    }

    @Test func stoppingLastsForOneBoot() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("agent-stopped.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let list = AgentBlockList(url: url)
        list.setBlocked(true, udid: "abc", session: "1")
        #expect(list.isBlocked(udid: "ABC", session: "1"))
        #expect(!list.isBlocked(udid: "abc", session: "2"))
        list.setBlocked(false, udid: "abc", session: "1")
        #expect(!list.isBlocked(udid: "abc", session: "1"))
    }
}

struct MCPServerTests {
    final class Calls {
        var received: [(String?, MCPServer.Command)] = []
    }

    func server(_ calls: Calls = Calls()) -> MCPServer {
        MCPServer(version: "1.0") { device, command in
            calls.received.append((device, command))
            if case .action(.home) = command { throw CommandLineTool.Failure("Stopped by the person.") }
            return [.text("ok")]
        }
    }

    func reply(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let text = try #require(server.handle(line: line))
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func initializeEchoesTheProtocolAndNamesTheClient() throws {
        let server = server()
        let answer = try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"claude-code"}}}"#)
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(server.clientName == "claude-code")
    }

    @Test func notificationsGetNoReply() {
        #expect(server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server().handle(line: "") == nil)
    }

    @Test func everyToolHasASchema() throws {
        let answer = try reply(server(), #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        let tools = try #require((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 11)
        for tool in tools {
            #expect(tool["name"] is String)
            #expect((tool["inputSchema"] as? [String: Any])?["type"] as? String == "object")
        }
    }

    @Test func toolCallsBecomeCommands() throws {
        let calls = Calls()
        let server = server(calls)
        let answer = try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tap","arguments":{"x":10,"y":20.5,"count":2,"device":"iPad"}}}"#)
        #expect((answer["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(calls.received.first?.0 == "iPad")
        #expect(calls.received.first?.1 == .action(.tap(CGPoint(x: 10, y: 20.5), count: 2)))

        _ = try reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"press_key","arguments":{"key":"b","modifiers":["cmd"]}}}"#)
        #expect(calls.received.last?.1 == .action(.key(.init(usage: 0x05, modifiers: [KeyboardMap.leftCommand]), count: 1)))

        _ = try reply(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"type_text","arguments":{"text":"-Olá","paste":true}}}"#)
        #expect(calls.received.last?.1 == .action(.type("-Olá", paste: true)))
    }

    @Test func badArgumentsAndFailuresAreToolErrors() throws {
        let calls = Calls()
        let server = server(calls)
        let bad = try reply(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tap","arguments":{"x":"left"}}}"#)
        #expect((bad["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(calls.received.isEmpty)

        let stopped = try reply(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"press_home","arguments":{}}}"#)
        let result = try #require(stopped["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("Stopped") == true)
    }

    @Test func unknownMethodsAreProtocolErrors() throws {
        let answer = try reply(server(), #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}
