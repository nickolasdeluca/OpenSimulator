import Foundation
import Testing
@testable import SimulatorCore

struct SensitiveURLTests {
    @Test func helperIsRebuiltOnlyWhenItsInputsChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("open-sensitive-url.m")
        let entitlements = folder.appendingPathComponent("open-sensitive-url.entitlements")
        let cache = folder.appendingPathComponent("Cache")
        try Data("int main(void) { return 0; }".utf8).write(to: source)
        try Data("<plist/>".utf8).write(to: entitlements)

        let first = try Simctl.sensitiveURLHelperLocation(source: source, entitlements: entitlements, cache: cache)
        let again = try Simctl.sensitiveURLHelperLocation(source: source, entitlements: entitlements, cache: cache)
        #expect(first == again)
        #expect(first.deletingLastPathComponent().path == cache.path)
        #expect(first.lastPathComponent.hasPrefix("open-sensitive-url-"))

        try Data("int main(void) { return 1; }".utf8).write(to: source)
        #expect(try Simctl.sensitiveURLHelperLocation(source: source, entitlements: entitlements, cache: cache) != first)

        try Data("<plist></plist>".utf8).write(to: entitlements)
        let changedEntitlements = try Simctl.sensitiveURLHelperLocation(source: source, entitlements: entitlements, cache: cache)
        #expect(changedEntitlements != first)
    }
}
