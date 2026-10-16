import Foundation

public struct SimDeviceTypeInfo: Decodable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let productFamily: String?
    public var id: String { identifier }
}

public struct SimRuntimeInfo: Decodable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    public let version: String?
    public let platform: String?
    public let isAvailable: Bool
    public let supportedDeviceTypes: [SimDeviceTypeInfo]?
    public var id: String { identifier }
}

/// The documented `simctl` tool, for everything that has a stable public command: lifecycle,
/// screenshots, URLs, installs, appearance. Only display and input go through private API.
public struct Simctl: Sendable {
    public let developerDirectory: String

    public init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    @discardableResult
    public func run(_ arguments: [String], input: Data? = nil) async throws -> String {
        let result = try await ProcessRunner.run(
            "/usr/bin/xcrun",
            ["simctl"] + arguments,
            input: input,
            environment: ["DEVELOPER_DIR": developerDirectory]
        )
        guard result.status == 0 else {
            throw ProcessFailure(
                command: "simctl \(arguments.first ?? "")",
                status: result.status,
                message: Self.cleanError(result.error)
            )
        }
        return result.output
    }

    /// simctl prefixes its errors with a domain/code line that means nothing to a person.
    static func cleanError(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("An error was encountered processing the command") && !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: Listing

    struct RuntimeList: Decodable { let runtimes: [SimRuntimeInfo] }
    struct DeviceTypeList: Decodable { let devicetypes: [SimDeviceTypeInfo] }

    public static func decodeRuntimes(_ json: Data) throws -> [SimRuntimeInfo] {
        try JSONDecoder().decode(RuntimeList.self, from: json).runtimes
    }

    public static func decodeDeviceTypes(_ json: Data) throws -> [SimDeviceTypeInfo] {
        try JSONDecoder().decode(DeviceTypeList.self, from: json).devicetypes
    }

    public func runtimes() async throws -> [SimRuntimeInfo] {
        try Self.decodeRuntimes(Data(try await run(["list", "-j", "runtimes"]).utf8))
    }

    public func deviceTypes() async throws -> [SimDeviceTypeInfo] {
        try Self.decodeDeviceTypes(Data(try await run(["list", "-j", "devicetypes"]).utf8))
    }

    // MARK: Lifecycle

    public func boot(_ udid: String) async throws { try await run(["boot", udid]) }
    public func shutdown(_ udid: String) async throws { try await run(["shutdown", udid]) }
    public func shutdownAll() async throws { try await run(["shutdown", "all"]) }
    public func erase(_ udid: String) async throws { try await run(["erase", udid]) }
    public func delete(_ udid: String) async throws { try await run(["delete", udid]) }
    public func rename(_ udid: String, to name: String) async throws { try await run(["rename", udid, name]) }

    /// Returns the new device's UDID.
    public func create(name: String, deviceType: String, runtime: String) async throws -> String {
        try await run(["create", name, deviceType, runtime]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits until the device has finished booting, booting it first if needed.
    public func waitUntilBooted(_ udid: String) async throws {
        try await run(["bootstatus", udid, "-b"])
    }

    // MARK: Device features

    public func screenshot(_ udid: String, to url: URL) async throws {
        try await run(["io", udid, "screenshot", "--type=png", url.path])
    }

    public func openURL(_ udid: String, _ url: String) async throws { try await run(["openurl", udid, url]) }
    public func install(_ udid: String, app: URL) async throws { try await run(["install", udid, app.path]) }
    public func addMedia(_ udid: String, files: [URL]) async throws {
        try await run(["addmedia", udid] + files.map(\.path))
    }

    public enum Appearance: String, Sendable { case light, dark }

    public func appearance(_ udid: String) async throws -> Appearance? {
        Appearance(rawValue: try await run(["ui", udid, "appearance"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func setAppearance(_ udid: String, _ appearance: Appearance) async throws {
        try await run(["ui", udid, "appearance", appearance.rawValue])
    }

    public func copyToDevicePasteboard(_ udid: String, text: String) async throws {
        try await run(["pbcopy", udid], input: Data(text.utf8))
    }

    public func devicePasteboard(_ udid: String) async throws -> String {
        try await run(["pbpaste", udid])
    }

    /// UIKit in the guest listens for this Darwin notification and sends a shake motion event.
    public func shake(_ udid: String) async throws {
        try await run(["spawn", udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
    }
}
