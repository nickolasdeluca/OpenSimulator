import CryptoKit
import Foundation
import Testing
@testable import SimulatorCore

struct UpdatesTests {
    private let hash = String(repeating: "a", count: 64)

    private func manifest(_ version: String, _ url: String, _ sha256: String) -> Data {
        Data(#"{"version":"\#(version)","url":"\#(url)","sha256":"\#(sha256)"}"#.utf8)
    }

    private var releaseURL: String { Updates.downloadPrefix + "v1.2.3/OpenSimulator.zip" }

    @Test func comparesVersionsNumerically() {
        #expect(Updates.isNewer("0.10.0", than: "0.9.9"))
        #expect(Updates.isNewer("1.0.0", than: "0.99.99"))
        #expect(Updates.isNewer("0.4.3", than: "0.4.2"))
        #expect(!Updates.isNewer("0.4.2", than: "0.4.2"))
        #expect(!Updates.isNewer("0.3.9", than: "0.4.2"))
    }

    @Test func malformedVersionsAreNeverNewer() {
        for candidate in ["9.9", "9.9.9-beta", "9.9.9.9", "", "1..2", "-1.0.0"] {
            #expect(!Updates.isNewer(candidate, than: "0.1.0"), "\(candidate)")
        }
    }

    @Test func acceptsAValidManifest() throws {
        let parsed = try Updates.parseManifest(manifest("1.2.3", releaseURL, hash))
        #expect(parsed.version == "1.2.3")
        #expect(parsed.url.absoluteString == releaseURL)
    }

    @Test func refusesDownloadsOutsideTheProjectsReleases() {
        for url in [
            "https://example.com/OpenSimulator.zip",
            "http://github.com/ndworks-dev/OpenSimulator/releases/download/v1/OpenSimulator.zip",
            "https://github.com/someone/OpenSimulator/releases/download/v1/OpenSimulator.zip",
        ] {
            #expect(throws: UpdateFailure.self, "\(url)") { try Updates.parseManifest(manifest("1.2.3", url, hash)) }
        }
    }

    @Test func refusesInvalidChecksumsAndVersions() {
        #expect(throws: UpdateFailure.self) { try Updates.parseManifest(manifest("1.2.3", releaseURL, "abc")) }
        #expect(throws: UpdateFailure.self) {
            try Updates.parseManifest(manifest("1.2.3", releaseURL, String(repeating: "z", count: 64)))
        }
        #expect(throws: UpdateFailure.self) { try Updates.parseManifest(manifest("latest", releaseURL, hash)) }
        #expect(throws: UpdateFailure.self) { try Updates.parseManifest(Data("not json".utf8)) }
    }

    // MARK: Installing

    /// A folder holding `OpenSimulator.app`, signed ad hoc with `identifier`, and a zip of it.
    private func fixture(identifier: String, marker: String) throws -> (folder: URL, app: URL, archive: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = folder.appendingPathComponent("source/OpenSimulator.app")
        let executable = source.appendingPathComponent("Contents/MacOS/OpenSimulator")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>"#
            + "<key>CFBundleIdentifier</key><string>\(identifier)</string>"
            + "<key>CFBundleExecutable</key><string>OpenSimulator</string>"
            + "<key>CFBundleShortVersionString</key><string>\(marker)</string></dict></plist>"
        try Data(plist.utf8).write(to: source.appendingPathComponent("Contents/Info.plist"))
        let sign = try ProcessRunner.runSync("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        #expect(sign.status == 0, "\(sign.error)")
        let archive = folder.appendingPathComponent("OpenSimulator.zip")
        let zip = try ProcessRunner.runSync("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        #expect(zip.status == 0)
        return (folder, source, archive)
    }

    private func installed(_ marker: String, at app: URL) throws -> Bool {
        let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return String(decoding: plist, as: UTF8.self).contains(marker)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func installsASignedArchiveInPlaceOfTheApp() async throws {
        let update = try fixture(identifier: "test.opensimulator", marker: "new-build")
        let current = try fixture(identifier: "test.opensimulator", marker: "old-build")
        defer {
            try? FileManager.default.removeItem(at: update.folder)
            try? FileManager.default.removeItem(at: current.folder)
        }
        let staging = try Updates.stagingFolder(for: current.app)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await Updates.apply(archive: update.archive, sha256: try sha256(update.archive), replacing: current.app,
                                staging: staging, requirement: #"identifier "test.opensimulator""#)
        #expect(try installed("new-build", at: current.app))
    }

    @Test func keepsTheAppWhenTheChecksumOrSignatureIsWrong() async throws {
        let update = try fixture(identifier: "someone.else", marker: "new-build")
        let current = try fixture(identifier: "test.opensimulator", marker: "old-build")
        defer {
            try? FileManager.default.removeItem(at: update.folder)
            try? FileManager.default.removeItem(at: current.folder)
        }
        let staging = try Updates.stagingFolder(for: current.app)
        defer { try? FileManager.default.removeItem(at: staging) }
        let requirement = #"identifier "test.opensimulator""#

        await #expect(throws: UpdateFailure.self) {
            try await Updates.apply(archive: update.archive, sha256: hash, replacing: current.app,
                                    staging: staging, requirement: requirement)
        }
        await #expect(throws: UpdateFailure.self) {
            try await Updates.apply(archive: update.archive, sha256: try sha256(update.archive),
                                    replacing: current.app, staging: staging, requirement: requirement)
        }
        #expect(try installed("old-build", at: current.app))
    }

    @Test func adHocBuildsDoNotPassTheReleaseRequirement() throws {
        let build = try fixture(identifier: "com.nickolasdeluca.OpenSimulator", marker: "dev")
        defer { try? FileManager.default.removeItem(at: build.folder) }
        #expect(!Updates.isSigned(build.app))
        #expect(Updates.isSigned(build.app, requirement: #"identifier "com.nickolasdeluca.OpenSimulator""#))
    }
}
