import AppKit
import SimBridge
import SimulatorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: SimulatorStore?
    private var managerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var deviceWindows: [String: DeviceWindowController] = [:]
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = MainMenu.build(app: self)

        do {
            let developerDir = try Xcode.developerDirectory()
            let core = try CoreSimulator.connect(withDeveloperDirectory: developerDir)
            store = SimulatorStore(core: core, simctl: Simctl(developerDirectory: developerDir))
        } catch {
            let alert = NSAlert()
            alert.messageText = "OpenSimulator can't reach the simulators"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        showManager(nil)
        // Devices that were already running get their windows back, the way Simulator reopened them.
        for device in store?.bootedDevices ?? [] {
            openDevice(device.udid)
        }
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showManager(nil) }
        return true
    }

    /// Closing the last window keeps the app running, like Simulator; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Preferences.shutDownOnQuit, let store, !deviceWindows.isEmpty, !isTerminating else {
            return .terminateNow
        }
        isTerminating = true
        let udids = Array(deviceWindows.keys)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for udid in udids where store.device(udid)?.state == .booted {
                    group.addTask { _ = try? await store.simctl.shutdown(udid) }
                }
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Windows

    func openDevice(_ udid: String) {
        guard let store else { return }
        if let existing = deviceWindows[udid] {
            existing.showWindow(nil)
            return
        }
        do {
            let controller = try DeviceWindowController(udid: udid, store: store) { [weak self] closed in
                MainActor.assumeIsolated { _ = self?.deviceWindows.removeValue(forKey: closed.udid) }
            }
            deviceWindows[udid] = controller
            controller.present()
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    @objc func showManager(_ sender: Any?) {
        guard let store else { return }
        if managerWindow == nil {
            let view = DeviceManagerView(store: store) { [weak self] udid in self?.openDevice(udid) }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Simulators"
            window.setContentSize(CGSize(width: 520, height: 460))
            window.styleMask.insert(.fullSizeContentView)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DeviceManager")
            managerWindow = window
            if UserDefaults.standard.string(forKey: "NSWindow Frame DeviceManager") == nil { window.center() }
        }
        managerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func newSimulator(_ sender: Any?) {
        showManager(nil)
        // The sheet belongs to the manager view, which listens for this.
        NotificationCenter.default.post(name: .showNewSimulator, object: nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: File > Open Simulator

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store else { return }
        store.refresh()
        let groups = store.groups
        if groups.isEmpty {
            menu.addItem(NSMenuItem(title: "No Simulators", action: nil, keyEquivalent: ""))
            return
        }
        for group in groups {
            let header = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in group.devices {
                let entry = NSMenuItem(title: device.name, action: #selector(openFromMenu(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = device.udid
                entry.state = device.state == .booted ? .on : .off
                entry.indentationLevel = 1
                menu.addItem(entry)
            }
        }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let udid = sender.representedObject as? String else { return }
        openDevice(udid)
    }
}

extension Notification.Name {
    static let showNewSimulator = Notification.Name("OpenSimulator.showNewSimulator")
}
