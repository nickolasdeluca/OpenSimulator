import Foundation
import Testing
@testable import SimulatorCore

struct ResourceMonitorTests {
    @Test func findsTheDeviceInLaunchdSimArguments() {
        let udid = "0A1B2C3D-0000-1111-2222-333344445555"
        let args = "/Library/.../launchd_sim\n/Users/me/Library/Developer/CoreSimulator/Devices/0a1b2c3d-0000-1111-2222-333344445555/data/var/run/launchd_bootstrap.plist"
        #expect(ResourceMonitor.matchUDID(in: args, among: [udid]) == udid)
        #expect(ResourceMonitor.matchUDID(in: args, among: ["FFFFFFFF-0000-1111-2222-333344445555"]) == nil)
    }

    @Test func samplingThisMachineDoesNotCrash() {
        // No simulator needs to be running: an unknown UDID simply yields nothing.
        let monitor = ResourceMonitor()
        #expect(monitor.sample(udids: ["00000000-0000-0000-0000-000000000000"]).isEmpty)
        #expect(!ResourceMonitor.allProcesses().isEmpty)
    }
}
