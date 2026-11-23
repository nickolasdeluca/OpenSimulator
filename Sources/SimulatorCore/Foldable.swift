import Foundation

/// How far a foldable such as the iPhone Duo is opened. iOS picks the panel it draws on from the
/// hinge angle, which `Helpers/set-hinge-angle.m` reports from inside the device the way Device Hub
/// does.
public enum HingePosture: String, CaseIterable, Sendable {
    case closed
    case partiallyOpen
    case open

    /// The angles Device Hub sends for its three postures.
    public var degrees: Int {
        switch self {
        case .closed: 0
        case .partiallyOpen: 130
        case .open: 180
        }
    }

    public var title: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "Partially Open"
        case .open: "Open"
        }
    }

    /// Closed shows the cover; partly or fully open, iOS moves to the inner panel.
    public var showsInnerPanel: Bool { self != .closed }
}

extension Simctl {
    public static func hingeHelper(source: URL) -> GuestHelper {
        GuestHelper(name: "set-hinge-angle", source: source, frameworks: ["Foundation", "IOKit"])
    }

    public func setHinge(_ udid: String, _ posture: HingePosture, helper: URL) async throws {
        try await run(["spawn", udid, helper.path, String(posture.degrees)])
    }
}
