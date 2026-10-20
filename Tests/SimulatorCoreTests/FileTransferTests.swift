import Foundation
import Testing
@testable import SimulatorCore

struct FileTransferTests {
    @Test func parsesListapps() throws {
        let output = """
        {
            "com.apple.DocumentsApp" =     {
                ApplicationType = System;
                CFBundleDisplayName = Files;
                CFBundleIdentifier = "com.apple.DocumentsApp";
                GroupContainers =         {
                    "group.com.apple.FileProvider.LocalStorage" = "file:///Devices/X/data/Containers/Shared/AppGroup/5E3F/";
                };
            };
            "com.example.notes" =     {
                ApplicationType = User;
                CFBundleName = Notes;
                DataContainer = "file:///Devices/X/data/Containers/Data/Application/A1/";
            };
        }
        """
        let apps = try Simctl.parseInstalledApps(Data(output.utf8))
        #expect(apps.map(\.name) == ["Files", "Notes"])
        #expect(apps[1].isUser)
        #expect(apps[1].documents?.path == "/Devices/X/data/Containers/Data/Application/A1/Documents")
        #expect(Simctl.filesAppFolder(in: apps)?.path == "/Devices/X/data/Containers/Shared/AppGroup/5E3F/File Provider Storage")
    }

    @Test func numbersTakenNames() {
        let taken: Set = ["Report.pdf", "Report 2.pdf", "Folder"]
        #expect(Simctl.availableName(for: "Report.pdf", taken: taken.contains) == "Report 3.pdf")
        #expect(Simctl.availableName(for: "Folder", taken: taken.contains) == "Folder 2")
        #expect(Simctl.availableName(for: "New.txt", taken: taken.contains) == "New.txt")
    }

    @Test func linksToFolder() {
        let link = Simctl.filesAppLink(to: URL(fileURLWithPath: "/a/File Provider Storage"))
        #expect(link == "shareddocuments:///a/File%20Provider%20Storage")
    }
}
