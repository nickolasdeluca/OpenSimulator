import CryptoKit
import Foundation

/// A small tool that runs inside a booted simulator with `simctl spawn`, for the few things only
/// the guest can do. The app ships these as source in `Helpers/` and builds them here on first use:
/// the notary service leaves simulator code out of the app's ticket, so a prebuilt helper would
/// make Gatekeeper reject the whole app.
public struct GuestHelper: Sendable {
    public let name: String
    public let source: URL
    /// Read by the guest from the `__entitlements` section, as for apps Xcode builds for the simulator.
    public let entitlements: URL?
    public let frameworks: [String]

    public init(name: String, source: URL, entitlements: URL? = nil, frameworks: [String]) {
        self.name = name
        self.source = source
        self.entitlements = entitlements
        self.frameworks = frameworks
    }

    /// Where the helper built from these inputs lives. The name carries a hash of them, so an app
    /// update that changes the source builds it again.
    func location(in cache: URL) throws -> URL {
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: source))
        if let entitlements { hash.update(data: try Data(contentsOf: entitlements)) }
        hash.update(data: Data(frameworks.joined(separator: ",").utf8))
        let digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("\(name)-\(digest)")
    }
}

extension Simctl {
    /// Returns the helper, building it into `cache` with the selected Xcode if it isn't there yet.
    public func build(_ helper: GuestHelper, cache: URL) async throws -> URL {
        let built = try helper.location(in: cache)
        if FileManager.default.isExecutableFile(atPath: built.path) { return built }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Built under another name, so a half-written file is never taken for the helper.
        let partial = cache.appendingPathComponent(UUID().uuidString)
        // The simulator runs guest code in the Mac's own architecture.
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var arguments = ["--sdk", "iphonesimulator", "clang", "-arch", architecture, "-mios-simulator-version-min=16.0",
                         "-fobjc-arc", "-Os"]
        for framework in helper.frameworks { arguments += ["-framework", framework] }
        if let entitlements = helper.entitlements {
            arguments += ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
                          "-Xlinker", entitlements.path]
        }
        arguments += [helper.source.path, "-o", partial.path]
        let result = try await ProcessRunner.run("/usr/bin/xcrun", arguments,
                                                 environment: ["DEVELOPER_DIR": developerDirectory])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw ProcessFailure(command: "Building \(helper.name)", status: result.status, message: result.error)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: built)
        } catch {
            // Another build got there first, with the same result.
            try? FileManager.default.removeItem(at: partial)
        }
        return built
    }
}
