import CryptoKit
import Foundation

/// Links `simctl openurl` refuses, such as Settings pages, opened by `Helpers/open-sensitive-url.m`
/// running inside the device. The app ships that file as source and builds it here on first use:
/// the notary service leaves simulator code out of the app's ticket, so a prebuilt helper would
/// make Gatekeeper reject the whole app.
extension Simctl {
    /// Settings pages, by the links Settings itself handles.
    public enum SettingsPage: String, Sendable {
        case keyboard = "prefs:root=General&path=Keyboard"
    }

    /// Where the helper built from these inputs lives. The name carries a hash of them, so an app
    /// update that changes the source builds it again.
    static func sensitiveURLHelperLocation(source: URL, entitlements: URL, cache: URL) throws -> URL {
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: source))
        hash.update(data: try Data(contentsOf: entitlements))
        let digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return cache.appendingPathComponent("open-sensitive-url-\(digest)")
    }

    /// Returns the helper, building it into `cache` with the selected Xcode if it isn't there yet.
    public func sensitiveURLHelper(source: URL, entitlements: URL, cache: URL) async throws -> URL {
        let helper = try Self.sensitiveURLHelperLocation(source: source, entitlements: entitlements, cache: cache)
        if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Built under another name, so a half-written file is never taken for the helper.
        let partial = cache.appendingPathComponent(UUID().uuidString)
        let result = try await ProcessRunner.run("/usr/bin/xcrun", [
            "--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-mios-simulator-version-min=16.0",
            "-fobjc-arc", "-Os", "-framework", "Foundation", "-framework", "MobileCoreServices",
            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
            "-Xlinker", entitlements.path,
            source.path, "-o", partial.path,
        ], environment: ["DEVELOPER_DIR": developerDirectory])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw ProcessFailure(command: "Building the Settings helper", status: result.status, message: result.error)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: helper)
        } catch {
            // Another build got there first, with the same result.
            try? FileManager.default.removeItem(at: partial)
        }
        return helper
    }

    /// Opens a link `openurl` refuses by running `helper` inside the device.
    public func openSensitiveURL(_ udid: String, _ url: String, helper: URL) async throws {
        try await run(["spawn", udid, helper.path, url])
    }
}
