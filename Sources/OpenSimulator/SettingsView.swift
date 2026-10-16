import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.Key.shutDownOnClose) private var shutDownOnClose = true
    @AppStorage(Preferences.Key.shutDownOnQuit) private var shutDownOnQuit = true
    @AppStorage(Preferences.Key.pauseWhenHidden) private var pauseWhenHidden = true
    @AppStorage(Preferences.Key.frameRateLimit) private var frameRateLimit = 60
    @AppStorage(Preferences.Key.showBezel) private var showBezel = true
    @AppStorage(Preferences.Key.scaleMode) private var scaleMode = ScaleMode.pointAccurate.rawValue
    @AppStorage(Preferences.Key.screenshotFolder) private var screenshotFolder = ""

    var body: some View {
        Form {
            Section {
                Toggle("Shut down a simulator when its window closes", isOn: $shutDownOnClose)
                Toggle("Shut down open simulators when quitting", isOn: $shutDownOnQuit)
            } header: {
                Text("Lifecycle")
            } footer: {
                Text("A running simulator keeps its memory even with no window. Shutting it down gives that back.")
                    .foregroundStyle(.secondary)
            }

            Section("Rendering") {
                Toggle("Stop drawing when a window is hidden or minimized", isOn: $pauseWhenHidden)
                Picker("Size for newly opened devices", selection: $scaleMode) {
                    ForEach(ScaleMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Frame rate limit", selection: $frameRateLimit) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                    Text("15 fps").tag(15)
                }
                Toggle("Show device bezels", isOn: $showBezel)
            }

            Section("Screenshots") {
                HStack {
                    Text(screenshotFolder.isEmpty ? "Desktop" : (screenshotFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            screenshotFolder = url.path
        }
    }
}
