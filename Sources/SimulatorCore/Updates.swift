import CryptoKit
import Foundation
import Security

/// What the latest release publishes as `latest.json`, next to `OpenSimulator.zip`.
public struct ReleaseManifest: Decodable, Equatable, Sendable {
    public let version: String
    public let url: URL
    public let sha256: String
}

public struct UpdateFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Updates from the latest release published on GitHub. The manifest names the version and the
/// archive's hash; authenticity comes from the code signature, so only an app signed with this
/// project's Developer ID is ever installed.
public enum Updates {
    public static let releasesPage = URL(string: "https://github.com/ndworks-dev/OpenSimulator/releases/latest")!
    static let manifestURL =
        URL(string: "https://github.com/ndworks-dev/OpenSimulator/releases/latest/download/latest.json")!
    static let downloadPrefix = "https://github.com/ndworks-dev/OpenSimulator/releases/download/"
    public static let requirement = #"anchor apple generic and identifier "com.nickolasdeluca.OpenSimulator" "#
        + #"and certificate leaf[subject.OU] = "3BRKN94K4H""#
    /// Far above the app's size, so a runaway download is cut short.
    static let maximumArchiveBytes = 100 * 1024 * 1024

    static func version(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Malformed versions are never newer, so a bad manifest can't offer an update.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = version(candidate), let current = version(current) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }

    public static func parseManifest(_ data: Data) throws -> ReleaseManifest {
        let manifest: ReleaseManifest
        do {
            manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        } catch {
            throw UpdateFailure("The release's manifest can't be read.")
        }
        guard version(manifest.version) != nil else {
            throw UpdateFailure("The release's manifest has an invalid version.")
        }
        guard manifest.url.absoluteString.hasPrefix(downloadPrefix) else {
            throw UpdateFailure("The release's manifest points outside this project's releases.")
        }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy(\.isHexDigit) else {
            throw UpdateFailure("The release's manifest has an invalid checksum.")
        }
        return manifest
    }

    /// The latest release, when it is newer than `currentVersion`.
    public static func check(currentVersion: String) async throws -> ReleaseManifest? {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateFailure("The latest release can't be reached right now.")
        }
        let manifest = try parseManifest(data)
        return isNewer(manifest.version, than: currentVersion) ? manifest : nil
    }

    /// Whether the app at `url` is intact and satisfies `requirement`.
    public static func isSigned(_ url: URL, requirement: String = requirement) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
    }

    /// Downloads the release and puts it in place of `app`.
    public static func install(_ manifest: ReleaseManifest, replacing app: URL) async throws {
        let staging = try stagingFolder(for: app)
        defer { try? FileManager.default.removeItem(at: staging) }
        let (download, response) = try await URLSession.shared.download(from: manifest.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateFailure("The update can't be downloaded right now.")
        }
        let archive = staging.appendingPathComponent("OpenSimulator.zip")
        try FileManager.default.moveItem(at: download, to: archive)
        try await apply(archive: archive, sha256: manifest.sha256, replacing: app, staging: staging)
    }

    /// Installs a downloaded archive with every check an update gets. `requirement` is only
    /// replaced by tests.
    static func apply(
        archive: URL, sha256: String, replacing app: URL, staging: URL, requirement: String = requirement
    ) async throws {
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumArchiveBytes else { throw UpdateFailure("The download is larger than any release.") }
        let digest = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else {
            throw UpdateFailure("The download doesn't match the release's checksum.")
        }

        let unpacked = staging.appendingPathComponent("unpacked")
        let result = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        guard result.status == 0 else { throw UpdateFailure("The download can't be unpacked.") }
        let replacement = unpacked.appendingPathComponent(app.lastPathComponent)
        guard isSigned(replacement, requirement: requirement) else {
            throw UpdateFailure("The update's signature was refused.")
        }

        let previous = staging.appendingPathComponent("previous.app")
        do {
            try FileManager.default.moveItem(at: app, to: previous)
        } catch {
            throw UpdateFailure("OpenSimulator can't be replaced in \(app.deletingLastPathComponent().path).")
        }
        do {
            try FileManager.default.moveItem(at: replacement, to: app)
        } catch {
            try? FileManager.default.moveItem(at: previous, to: app)
            throw UpdateFailure("OpenSimulator can't be replaced in \(app.deletingLastPathComponent().path).")
        }
    }

    /// Beside the app, so putting the new one in place is a rename on the same volume.
    static func stagingFolder(for app: URL) throws -> URL {
        let folder = app.deletingLastPathComponent()
            .appendingPathComponent(".opensimulator-update-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw UpdateFailure("OpenSimulator can't write to \(app.deletingLastPathComponent().path).")
        }
        return folder
    }

    /// Opens `app` again once the process `pid` has exited.
    public static func relaunch(_ app: URL, after pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
                             "opensimulator-relaunch", String(pid), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
