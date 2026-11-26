import AppKit
import SimulatorCore

/// Looks for a newer release when the app opens and once a day, and installs it when the person
/// asks. Only a release build checks: a build signed ad hoc is someone's work in progress.
@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case available(ReleaseManifest)
        case installing(ReleaseManifest)
        case failed(ReleaseManifest, String)
    }

    @Published private(set) var state: State = .idle
    /// Hidden from the device list until the next check finds something else.
    @Published private(set) var dismissedVersion: String?

    let isEnabled = Updates.isSigned(Bundle.main.bundleURL)
    private var timer: Timer?
    private var isChecking = false
    /// Set while quitting to restart into the update, so running simulators are kept.
    private(set) var isRelaunching = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// What the device list shows, if anything.
    var banner: State? {
        switch state {
        case .idle: nil
        case .available(let manifest) where manifest.version == dismissedVersion: nil
        default: state
        }
    }

    func start() {
        guard isEnabled else { return }
        scheduleChecks()
    }

    /// Follows the setting; a check also runs right away when it is turned on.
    func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, Preferences.checkForUpdates else { return }
        Task { await check(userInitiated: false) }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Check for Updates… in the app menu, which answers even when there is nothing new.
    @objc func checkFromMenu(_ sender: Any?) {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking, !isInstalling else { return }
        guard isEnabled else {
            if userInitiated { inform("Updates are off for this build", "Only release builds update themselves.") }
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            if let manifest = try await Updates.check(currentVersion: Self.currentVersion) {
                state = .available(manifest)
                if userInitiated {
                    dismissedVersion = nil
                    NotificationCenter.default.post(name: .showUpdate, object: nil)
                }
            } else {
                if case .available = state { state = .idle }
                if userInitiated {
                    inform("OpenSimulator is up to date", "Version \(Self.currentVersion) is the latest release.")
                }
            }
        } catch {
            // A quiet check that fails says nothing: the next one will try again.
            if userInitiated { inform("Can't check for updates", error.localizedDescription) }
        }
    }

    func dismiss() {
        switch state {
        case .available(let manifest), .failed(let manifest, _):
            state = .available(manifest)
            dismissedVersion = manifest.version
        default: break
        }
    }

    private var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    func install() {
        let manifest: ReleaseManifest
        switch state {
        case .available(let offered), .failed(let offered, _): manifest = offered
        default: return
        }
        state = .installing(manifest)
        let app = Bundle.main.bundleURL
        Task {
            do {
                try await Updates.install(manifest, replacing: app)
                try Updates.relaunch(app, after: ProcessInfo.processInfo.processIdentifier)
                isRelaunching = true
                NSApp.terminate(nil)
            } catch {
                state = .failed(manifest, error.localizedDescription)
            }
        }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension Notification.Name {
    static let showUpdate = Notification.Name("OpenSimulator.showUpdate")
}
