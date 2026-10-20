import Foundation

/// An app installed on a device, from `simctl listapps`.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    /// Installed by the user rather than part of iOS.
    public let isUser: Bool
    public let dataContainer: URL?
    public let groupContainers: [String: URL]

    public var id: String { bundleID }

    /// Where the app keeps its documents. Files the app shares appear in the Files app too.
    public var documents: URL? { dataContainer?.appendingPathComponent("Documents", isDirectory: true) }
}

/// Copies Mac files into a device. Device storage is a plain folder on the Mac, so a copy is all it
/// takes, and the device sees new files right away.
extension Simctl {
    static let filesAppID = "com.apple.DocumentsApp"
    static let localStorageGroup = "group.com.apple.FileProvider.LocalStorage"

    /// `listapps` prints an old-style property list keyed by bundle identifier.
    static func parseInstalledApps(_ data: Data) throws -> [InstalledApp] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            return []
        }
        return plist.map { bundleID, info in
            let groups = (info["GroupContainers"] as? [String: String] ?? [:]).compactMapValues(URL.init(string:))
            return InstalledApp(
                bundleID: bundleID,
                name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID,
                isUser: info["ApplicationType"] as? String == "User",
                dataContainer: (info["DataContainer"] as? String).flatMap(URL.init(string:)),
                groupContainers: groups
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func installedApps(_ udid: String) async throws -> [InstalledApp] {
        try Self.parseInstalledApps(Data(try await run(["listapps", udid]).utf8))
    }

    /// The folder the Files app shows as On My iPhone (or iPad).
    public static func filesAppFolder(in apps: [InstalledApp]) -> URL? {
        apps.first { $0.bundleID == filesAppID }?.groupContainers[localStorageGroup]?
            .appendingPathComponent("File Provider Storage", isDirectory: true)
    }

    /// A Files app link that opens `folder` on the device.
    public static func filesAppLink(to folder: URL) -> String {
        "shareddocuments://" + (folder.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.path)
    }

    /// Copies files and folders into `folder`, numbering names that are taken the way Finder does.
    /// Returns the copies.
    @discardableResult
    public static func copy(_ files: [URL], into folder: URL) throws -> [URL] {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.map { file in
            let name = availableName(for: file.lastPathComponent) {
                manager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            let destination = folder.appendingPathComponent(name)
            try manager.copyItem(at: file, to: destination)
            return destination
        }
    }

    /// `Report.pdf`, then `Report 2.pdf`, `Report 3.pdf` and so on.
    static func availableName(for name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !taken(candidate) { return candidate }
            number += 1
        }
    }
}
