import Foundation

/// Links `simctl openurl` refuses, such as Settings pages, opened by `Helpers/open-sensitive-url.m`
/// running inside the device.
extension Simctl {
    /// Settings pages, by the links Settings itself handles.
    public enum SettingsPage: String, Sendable {
        case keyboard = "prefs:root=General&path=Keyboard"
    }

    public static func sensitiveURLHelper(source: URL, entitlements: URL) -> GuestHelper {
        GuestHelper(name: "open-sensitive-url", source: source, entitlements: entitlements,
                    frameworks: ["Foundation", "MobileCoreServices"])
    }

    /// Opens a link `openurl` refuses by running `helper` inside the device.
    public func openSensitiveURL(_ udid: String, _ url: String, helper: URL) async throws {
        try await run(["spawn", udid, helper.path, url])
    }
}
