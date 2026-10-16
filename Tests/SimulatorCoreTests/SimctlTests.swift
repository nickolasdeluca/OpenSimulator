import Foundation
import Testing
@testable import SimulatorCore

struct SimctlTests {
    @Test func decodesRuntimesWithSupportedDeviceTypes() throws {
        let json = """
        {"runtimes":[{"isAvailable":true,"version":"27.1","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1",
        "platform":"iOS","name":"iOS 27.1","supportedDeviceTypes":[{"name":"iPhone Duo","productFamily":"iPhone",
        "identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-Duo","bundlePath":"/x"}]}]}
        """
        let runtimes = try Simctl.decodeRuntimes(Data(json.utf8))
        #expect(runtimes.count == 1)
        #expect(runtimes[0].name == "iOS 27.1")
        #expect(runtimes[0].supportedDeviceTypes?.map(\.name) == ["iPhone Duo"])
    }

    @Test func decodesDeviceTypes() throws {
        let json = """
        {"devicetypes":[{"productFamily":"iPhone","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
        "name":"iPhone 18 Pro","minRuntimeVersion":1769472}]}
        """
        let types = try Simctl.decodeDeviceTypes(Data(json.utf8))
        #expect(types.first?.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro")
    }

    @Test func errorBoilerplateIsRemoved() {
        let raw = "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=403):\nIncompatible device\n"
        #expect(Simctl.cleanError(raw) == "Incompatible device")
    }
}
