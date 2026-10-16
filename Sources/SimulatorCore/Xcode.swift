import Foundation

/// Where the selected Xcode lives. CoreSimulator is loaded from it, and `simctl` runs from it.
public enum Xcode {
    public struct NotFound: LocalizedError {
        public var errorDescription: String? {
            "No Xcode is selected. Install Xcode, then run `sudo xcode-select -s /Applications/Xcode.app`."
        }
    }

    /// `$DEVELOPER_DIR` first, then `xcode-select -p`, then the default install location.
    public static func developerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        if let result = try? ProcessRunner.runSync("/usr/bin/xcode-select", ["-p"]), result.status == 0 {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // The Command Line Tools have no simulators.
            if !path.isEmpty, !path.hasPrefix("/Library/Developer/CommandLineTools"),
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let fallback = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.fileExists(atPath: fallback) { return fallback }
        throw NotFound()
    }
}
