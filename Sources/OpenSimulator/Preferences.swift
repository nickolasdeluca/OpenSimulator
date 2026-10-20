import Foundation
import SimulatorCore

/// User settings, all in standard UserDefaults. The defaults lean towards using as little of the
/// Mac as possible, which is the point of this app.
enum Preferences {
    enum Key {
        static let shutDownOnClose = "ShutDownOnWindowClose"
        static let shutDownOnQuit = "ShutDownOnQuit"
        static let pauseWhenHidden = "PauseRenderingWhenHidden"
        static let frameRateLimit = "FrameRateLimit"
        static let showBezel = "ShowDeviceBezel"
        static let hardwareKeyboard = "ConnectHardwareKeyboard"
        static let scaleMode = "ScaleMode"
        static let screenshotFolder = "ScreenshotFolder"
        static let disabledServiceGroups = "DisabledServiceGroups"
        static let servicesToApply = "ServiceGroupsToApply"
        static let serviceGroupsVersion = "ServiceGroupsVersion"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.shutDownOnClose: true,
            Key.shutDownOnQuit: true,
            Key.pauseWhenHidden: true,
            Key.frameRateLimit: 60,
            Key.showBezel: true,
            Key.hardwareKeyboard: true,
            Key.scaleMode: ScaleMode.pointAccurate.rawValue,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var shutDownOnClose: Bool { defaults.bool(forKey: Key.shutDownOnClose) }
    static var shutDownOnQuit: Bool { defaults.bool(forKey: Key.shutDownOnQuit) }
    static var pauseWhenHidden: Bool { defaults.bool(forKey: Key.pauseWhenHidden) }
    static var frameRateLimit: Int { max(defaults.integer(forKey: Key.frameRateLimit), 1) }
    static var showBezel: Bool {
        get { defaults.bool(forKey: Key.showBezel) }
        set { defaults.set(newValue, forKey: Key.showBezel) }
    }
    static var hardwareKeyboard: Bool {
        get { defaults.bool(forKey: Key.hardwareKeyboard) }
        set { defaults.set(newValue, forKey: Key.hardwareKeyboard) }
    }
    static var scaleMode: ScaleMode {
        get { ScaleMode(rawValue: defaults.string(forKey: Key.scaleMode) ?? "") ?? .pointAccurate }
        set { defaults.set(newValue.rawValue, forKey: Key.scaleMode) }
    }

    /// Service groups the person turned off, by device UDID.
    static func disabledServiceGroups(for udid: String) -> Set<ServiceGroup> {
        let all = defaults.dictionary(forKey: Key.disabledServiceGroups) as? [String: [String]] ?? [:]
        return Set((all[udid] ?? []).compactMap(ServiceGroup.init(rawValue:)))
    }

    static func setDisabledServiceGroups(_ groups: Set<ServiceGroup>, for udid: String) {
        var all = defaults.dictionary(forKey: Key.disabledServiceGroups) as? [String: [String]] ?? [:]
        all[udid] = groups.isEmpty ? nil : groups.map(\.rawValue).sorted()
        defaults.set(all, forKey: Key.disabledServiceGroups)
    }

    /// Devices whose service groups still have to be applied, which happens once they are booted.
    static var servicesToApply: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.servicesToApply) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.servicesToApply) }
    }

    /// Bump when `ServiceGroup`'s labels change, so devices set up with the old list are applied
    /// again at their next boot. 2 retired sleepd.
    private static let currentServiceGroupsVersion = 2

    static func reapplyServiceGroupsIfChanged() {
        guard defaults.integer(forKey: Key.serviceGroupsVersion) < currentServiceGroupsVersion else { return }
        let all = defaults.dictionary(forKey: Key.disabledServiceGroups) as? [String: [String]] ?? [:]
        servicesToApply.formUnion(all.keys)
        defaults.set(currentServiceGroupsVersion, forKey: Key.serviceGroupsVersion)
    }

    static var screenshotFolder: URL {
        if let path = defaults.string(forKey: Key.screenshotFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// The classic Simulator's Window menu sizes.
enum ScaleMode: String, CaseIterable {
    case physicalSize
    case pointAccurate
    case pixelAccurate
    case fitScreen

    var title: String {
        switch self {
        case .physicalSize: "Physical Size"
        case .pointAccurate: "Point Accurate"
        case .pixelAccurate: "Pixel Accurate"
        case .fitScreen: "Fit Screen"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .physicalSize: "1"
        case .pointAccurate: "2"
        case .pixelAccurate: "3"
        case .fitScreen: "4"
        }
    }
}
