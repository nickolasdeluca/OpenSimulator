import Foundation
import Testing
@testable import SimulatorCore

struct GuestHelperTests {
    @Test func helperIsRebuiltOnlyWhenItsInputsChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("open-sensitive-url.m")
        let entitlements = folder.appendingPathComponent("open-sensitive-url.entitlements")
        let cache = folder.appendingPathComponent("Cache")
        try Data("int main(void) { return 0; }".utf8).write(to: source)
        try Data("<plist/>".utf8).write(to: entitlements)
        let helper = Simctl.sensitiveURLHelper(source: source, entitlements: entitlements)

        let first = try helper.location(in: cache)
        #expect(try helper.location(in: cache) == first)
        #expect(first.deletingLastPathComponent().path == cache.path)
        #expect(first.lastPathComponent.hasPrefix("open-sensitive-url-"))

        try Data("int main(void) { return 1; }".utf8).write(to: source)
        #expect(try helper.location(in: cache) != first)

        try Data("<plist></plist>".utf8).write(to: entitlements)
        #expect(try helper.location(in: cache) != first)
    }

    @Test func helpersWithoutEntitlementsHashTheirSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("set-hinge-angle.m")
        try Data("int main(void) { return 0; }".utf8).write(to: source)
        let helper = Simctl.hingeHelper(source: source)

        let first = try helper.location(in: folder)
        #expect(first.lastPathComponent.hasPrefix("set-hinge-angle-"))
        try Data("int main(void) { return 2; }".utf8).write(to: source)
        #expect(try helper.location(in: folder) != first)
    }

    @Test func onlyAClosedFoldableShowsItsCover() {
        #expect(HingePosture.closed.showsInnerPanel == false)
        #expect(HingePosture.partiallyOpen.showsInnerPanel)
        #expect(HingePosture.open.showsInnerPanel)
        #expect(HingePosture.allCases.map(\.degrees) == [0, 130, 180])
    }
}
