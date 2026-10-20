import Foundation

/// iOS background services that most apps never touch, grouped by the feature they serve. A
/// lightweight simulator turns groups off with `launchctl disable`, which the device remembers
/// across restarts until it is erased.
public enum ServiceGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case siri
    case intelligence
    case mediaAnalysis
    case fitness
    case home
    case watch
    case appServices
    case analytics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .siri: "Siri and Dictation"
        case .intelligence: "Apple Intelligence and Suggestions"
        case .mediaAnalysis: "Photo and Video Analysis"
        case .fitness: "Fitness and Sleep"
        case .home: "Home"
        case .watch: "Apple Watch Pairing"
        case .appServices: "News, Weather, Wallet, Game Center, CarPlay"
        case .analytics: "Ads, Analytics and Location History"
        }
    }

    /// What stops working, for apps that need it.
    public var breaks: String {
        switch self {
        case .siri: "Siri, App Intents run by voice, dictation and speech recognition."
        case .intelligence: "Foundation Models, Writing Tools and Siri Suggestions."
        case .mediaAnalysis: "Photos search and Memories, Live Text and Visual Look Up."
        case .fitness: "The Fitness app, activity sharing and sleep schedules. HealthKit itself stays on."
        case .home: "HomeKit."
        case .watch: "Pairing a watch simulator and WatchConnectivity."
        case .appServices: "WeatherKit, GameKit, PassKit, FinanceKit and CarPlay."
        case .analytics: "Promoted content, Significant Locations and visit monitoring."
        }
    }

    /// `launchd` labels in the iOS runtime.
    public var labels: [String] {
        switch self {
        case .siri:
            ["com.apple.assistantd", "com.apple.assistant_cdmd", "com.apple.siri.context.service",
             "com.apple.siriactionsd", "com.apple.siriinferenced", "com.apple.siriknowledged",
             "com.apple.sirittsd", "com.apple.corespeechd", "com.apple.voicebankingd"]
        case .intelligence:
            ["com.apple.generativeexperiencesd", "com.apple.modelmanagerd", "com.apple.modelcatalogd",
             "com.apple.textunderstandingd", "com.apple.suggestd", "com.apple.spotlightknowledged.updater"]
        case .mediaAnalysis:
            ["com.apple.mediaanalysisd", "com.apple.photoanalysisd"]
        case .fitness:
            ["com.apple.fitnesscoachingd", "com.apple.fitnessintelligenced", "com.apple.activityawardsd",
             "com.apple.activitysharingd", "com.apple.sleepd"]
        case .home:
            ["com.apple.homed", "com.apple.homeeventsd"]
        case .watch:
            // Not nanoregistryd: data migration waits for it on every boot, so with it off the
            // device never finishes booting.
            ["com.apple.nanotimekitcompaniond", "com.apple.nanoregistrylaunchd", "com.apple.nanoprefsyncd.2",
             "com.apple.NPKCompanionAgent"]
        case .appServices:
            ["com.apple.newsd", "com.apple.weatherd", "com.apple.gamed", "com.apple.financed",
             "com.apple.passd", "com.apple.carkitd"]
        case .analytics:
            ["com.apple.ap.promotedcontentd", "com.apple.amsengagementd", "com.apple.biomesyncd",
             "com.apple.routined", "com.apple.triald"]
        }
    }

    /// Groups whose every label is in `disabled`, so a device reads back as what was chosen.
    public static func fullyDisabled(in disabled: Set<String>) -> Set<ServiceGroup> {
        Set(allCases.filter { $0.labels.allSatisfy(disabled.contains) })
    }
}

extension Simctl {
    /// Parses `launchctl print-disabled`, which lists overrides as `"label" => disabled` lines.
    static func parseDisabledServices(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" => ")
            guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "disabled" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: ["\""]))
        }
        return labels
    }

    /// Labels the booted device has disabled.
    public func disabledServices(_ udid: String) async throws -> Set<String> {
        Self.parseDisabledServices(try await run(["spawn", udid, "launchctl", "print-disabled", "system"]))
    }

    /// Disables a service and stops it now, so the change needs no restart. A disabled service
    /// stays stopped: launchd refuses to start it on demand.
    public func disableService(_ udid: String, label: String) async throws {
        try await run(["spawn", udid, "launchctl", "disable", "system/\(label)"])
        // Fails when the service isn't running, which is fine.
        _ = try? await run(["spawn", udid, "launchctl", "bootout", "system/\(label)"])
    }

    /// Clears the override. The service starts again at the next boot.
    public func enableService(_ udid: String, label: String) async throws {
        try await run(["spawn", udid, "launchctl", "enable", "system/\(label)"])
    }

    /// Brings the device's overrides in line with `disabled`, touching only labels in
    /// `ServiceGroup`. Returns true when a service was turned back on, which takes a restart.
    @discardableResult
    public func applyServiceGroups(_ udid: String, disabled: Set<ServiceGroup>) async throws -> Bool {
        let current = try await disabledServices(udid)
        // One task per group keeps the number of spawned processes small.
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for serviceGroup in ServiceGroup.allCases {
                let disable = disabled.contains(serviceGroup)
                group.addTask {
                    var enabledAny = false
                    for label in serviceGroup.labels {
                        if disable, !current.contains(label) {
                            try await disableService(udid, label: label)
                        } else if !disable, current.contains(label) {
                            try await enableService(udid, label: label)
                            enabledAny = true
                        }
                    }
                    return enabledAny
                }
            }
            return try await group.reduce(false) { $0 || $1 }
        }
    }
}
