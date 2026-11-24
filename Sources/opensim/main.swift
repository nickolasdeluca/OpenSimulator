// opensim: lets a script or an agent drive a booted simulator's screen and keyboard while the
// person watches it in OpenSimulator. `opensim mcp` serves the same actions to an agent over the
// Model Context Protocol. Everything simctl already does well is left to simctl.

import Foundation
import SimBridge
import SimulatorCore

/// The version of the app this tool ships in.
let version = Driver.appURL().flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "dev"

let help = """
Usage: opensim <command> [--device <UDID|name>]
       opensim mcp                        Serve these commands to an agent over MCP (stdio)

Coordinates are points on the screen as it is shown, origin top left, in the current
orientation. --device can be left out when exactly one simulator is booted. OpenSimulator
shows the device and each touch and key while it happens, and its Stop button refuses
further commands.

  tap X Y [--count 2]                 Tap; --count 2 double taps, 3 triple taps
  longpress X Y [--duration 0.8]      Touch and hold, in seconds
  swipe X1 Y1 X2 Y2 [--duration 0.3]  Drag from one point to another
  type TEXT [--paste]                 Type on a US hardware keyboard, accents included;
                                      --paste sends it through the pasteboard instead
  key KEY [--mods cmd,shift,alt,ctrl] [--count N]
                                      A character or return, escape, delete, tab, space,
                                      forwarddelete, up, down, left, right, home, end,
                                      pageup, pagedown, f1 to f12
  rotate left|right|portrait|landscape-left|landscape-right|upside-down
  home                                Press the Home button
  info                                Screen size in points, scale and orientation, as JSON

Exit status: 0 done, 1 failed, 2 bad arguments, 3 device missing or not booted,
4 not supported by the selected Xcode, 5 stopped from OpenSimulator.
"""

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("opensim: \(error.localizedDescription)\n".utf8))
    exit(exitCode(for: error).rawValue)
}

func exitCode(for error: Error) -> Tool.ExitCode {
    if let failure = error as? Tool.Failure { return failure.code }
    guard (error as NSError).domain == OSSimBridgeErrorDomain else { return .failure }
    // 4 and 5 are a missing or shut down device, 8 a device still booting, 33 a timeout.
    switch (error as NSError).code {
    case 4, 5, 8: return .device
    case 33: return .failure
    default: return .unsupported
    }
}

func serveMCP() throws -> Never {
    let driver = try Driver()
    driver.announcesSessions = true
    let server = MCPServer(version: version) { device, command in
        switch command {
        case let .action(action):
            let output = try driver.run(action, device: device)
            return [.text(output ?? "Done.")]
        case .screenshot:
            return [.image(try driver.screenshot(device: device), mimeType: "image/jpeg")]
        case let .openURL(url):
            return [.text(try driver.openURL(url, device: device))]
        case .listDevices:
            let devices = driver.bootedDevices().map {
                ["udid": $0.udid, "name": $0.name, "runtime": $0.runtimeName, "deviceType": $0.deviceTypeName]
            }
            return [.text(Driver.json(devices))]
        }
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    while let line = readLine(strippingNewline: true) {
        if let reply = server.handle(line: line) {
            print(reply)
        }
    }
    // The client closed the pipe: the agent is done with the devices.
    driver.endSessions()
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["mcp"] { try serveMCP() }
    let invocation = try Tool.parse(arguments)
    if invocation.command == .help {
        print(help)
        exit(0)
    }
    if let output = try Driver().run(invocation.command, device: invocation.device) {
        print(output)
    }
} catch {
    fail(error)
}
