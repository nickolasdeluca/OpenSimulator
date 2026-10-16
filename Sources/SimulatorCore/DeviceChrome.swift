import CoreGraphics
import Foundation

/// The device body Apple draws around a simulated screen, read from the `.devicechrome` bundles
/// Xcode installs in /Library/Developer/DeviceKit/Chrome. The artwork stays where it is; nothing
/// is copied into the app.
///
/// How the bundles are found and laid out follows OpenDeviceHub (MIT), which measured them against
/// the classic Simulator. See THIRD_PARTY_NOTICES.md.
public struct DeviceChrome: Sendable, Hashable {
    public struct Insets: Sendable, Hashable {
        public var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
        public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
            self.left = left; self.right = right; self.top = top; self.bottom = bottom
        }
    }

    public struct Button: Sendable, Hashable {
        public enum Anchor: String, Sendable { case left, right, top, bottom }
        public let name: String
        public let image: String
        public let imageDown: String
        public let anchor: Anchor
        /// From the anchored edge, in points. y runs down from the top of the body.
        public let offset: CGPoint
        /// Where it slides to under the pointer, which makes a side button look like it rises.
        public let rolloverOffset: CGPoint
        /// Side buttons sit under the body so only the part standing proud shows.
        public let onTop: Bool

        public init(name: String, image: String, imageDown: String, anchor: Anchor,
                    offset: CGPoint, rolloverOffset: CGPoint, onTop: Bool) {
            self.name = name; self.image = image; self.imageDown = imageDown; self.anchor = anchor
            self.offset = offset; self.rolloverOffset = rolloverOffset; self.onTop = onTop
        }
    }

    public struct Slices: Sendable, Hashable {
        public let topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight: String
    }

    public let bundle: URL
    /// The body's thickness around the screen.
    public let insets: Insets
    /// Room either side for buttons that stand proud of the body.
    public let devicePadding: Insets
    /// The body's outside corner radius.
    public let cornerRadius: CGFloat
    /// Newer phones ship one composite body; home-button phones and iPads ship nine slices.
    public let composite: String?
    public let slices: Slices?
    public let buttons: [Button]

    public func resource(_ name: String) -> URL {
        bundle.appendingPathComponent("Contents/Resources/\(name).pdf")
    }

    public var maxInset: CGFloat {
        max(max(insets.left, insets.right), max(insets.top, insets.bottom))
    }
}

// MARK: - Finding and reading bundles

extension DeviceChrome {
    public static let deviceTypesDirectory = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes"
    public static let chromeDirectory = "/Library/Developer/DeviceKit/Chrome"

    /// The chrome for a device type such as `com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro`,
    /// or nil when any step is missing, in which case the window shows the bare screen.
    public static func forDeviceType(
        _ identifier: String,
        deviceTypesDirectory: String = deviceTypesDirectory,
        chromeDirectory: String = chromeDirectory
    ) -> DeviceChrome? {
        guard let deviceType = bundle(withIdentifier: identifier, extension: "simdevicetype", in: deviceTypesDirectory),
              let profile = plist(deviceType.appendingPathComponent("Contents/Resources/profile.plist")),
              let chromeIdentifier = profile["chromeIdentifier"] as? String,
              let chromeBundle = bundle(withIdentifier: chromeIdentifier, extension: "devicechrome", in: chromeDirectory),
              let data = try? Data(contentsOf: chromeBundle.appendingPathComponent("Contents/Resources/chrome.json"))
        else { return nil }
        return parse(json: data, bundle: chromeBundle)
    }

    /// Matched on the identifier inside each bundle, since file names only happen to agree.
    static func bundle(withIdentifier identifier: String, extension pathExtension: String, in directory: String) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
        )) ?? []
        return entries.first { entry in
            entry.pathExtension == pathExtension
                && plist(entry.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == identifier
        }
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Reads Apple's `chrome.json`. Every field is treated as optional so one missing value falls
    /// back rather than losing the whole body.
    public static func parse(json: Data, bundle: URL) -> DeviceChrome? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let images = root["images"] as? [String: Any] ?? [:]
        let sizing = images["sizing"] as? [String: Any] ?? [:]
        let padding = images["devicePadding"] as? [String: Any] ?? [:]
        let border = (root["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any]

        var slices: Slices?
        if let tl = images["topLeft"] as? String, let t = images["top"] as? String,
           let tr = images["topRight"] as? String, let l = images["left"] as? String,
           let r = images["right"] as? String, let bl = images["bottomLeft"] as? String,
           let b = images["bottom"] as? String, let br = images["bottomRight"] as? String {
            slices = Slices(topLeft: tl, top: t, topRight: tr, left: l, right: r, bottomLeft: bl, bottom: b, bottomRight: br)
        }
        let composite = images["composite"] as? String
        guard composite != nil || slices != nil else { return nil }

        let buttons: [Button] = (root["inputs"] as? [[String: Any]] ?? []).compactMap { input in
            guard input["type"] as? String == "button",
                  let name = input["name"] as? String,
                  let image = input["image"] as? String,
                  let anchor = Button.Anchor(rawValue: input["anchor"] as? String ?? "") else { return nil }
            let offsets = input["offsets"] as? [String: Any]
            let normal = offsets?["normal"] as? [String: Any] ?? [:]
            let rollover = offsets?["rollover"] as? [String: Any] ?? normal
            return Button(
                name: name,
                image: image,
                imageDown: input["imageDown"] as? String ?? image,
                anchor: anchor,
                offset: CGPoint(x: number(normal["x"]), y: number(normal["y"])),
                rolloverOffset: CGPoint(x: number(rollover["x"]), y: number(rollover["y"])),
                onTop: input["onTop"] as? Bool ?? false
            )
        }

        return DeviceChrome(
            bundle: bundle,
            insets: Insets(left: number(sizing["leftWidth"]), right: number(sizing["rightWidth"]),
                           top: number(sizing["topHeight"]), bottom: number(sizing["bottomHeight"])),
            devicePadding: Insets(left: number(padding["left"]), right: number(padding["right"]),
                                  top: number(padding["top"]), bottom: number(padding["bottom"])),
            cornerRadius: number(border?["cornerRadiusX"]),
            composite: composite,
            slices: slices,
            buttons: buttons
        )
    }

    private static func number(_ value: Any?) -> CGFloat {
        (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }
}

// MARK: - Layout

/// Where the body, screen and buttons go. Everything is laid out in the device's own upright space
/// (points, origin bottom left) and carried into the window by one transform, so rotating the
/// device turns its body and buttons with it.
public enum DeviceLayout {
    /// Simulator draws side buttons 2pt further out than their stated offset.
    static let sideButtonProtrusion: CGFloat = 2

    /// The whole device upright, in points, or just the screen when there is no chrome.
    public static func uprightSize(screen: CGSize, chrome: DeviceChrome?) -> CGSize {
        guard let chrome else { return screen }
        return CGSize(
            width: screen.width + chrome.insets.left + chrome.insets.right
                + chrome.devicePadding.left + chrome.devicePadding.right,
            height: screen.height + chrome.insets.top + chrome.insets.bottom
                + chrome.devicePadding.top + chrome.devicePadding.bottom
        )
    }

    public static func bodyRect(upright: CGSize, chrome: DeviceChrome) -> CGRect {
        CGRect(
            x: chrome.devicePadding.left,
            y: chrome.devicePadding.bottom,
            width: max(upright.width - chrome.devicePadding.left - chrome.devicePadding.right, 0),
            height: max(upright.height - chrome.devicePadding.top - chrome.devicePadding.bottom, 0)
        )
    }

    public static func screenRect(upright: CGSize, chrome: DeviceChrome?) -> CGRect {
        guard let chrome else { return CGRect(origin: .zero, size: upright) }
        let body = bodyRect(upright: upright, chrome: chrome)
        return CGRect(
            x: body.minX + chrome.insets.left,
            y: body.minY + chrome.insets.bottom,
            width: max(body.width - chrome.insets.left - chrome.insets.right, 0),
            height: max(body.height - chrome.insets.top - chrome.insets.bottom, 0)
        )
    }

    public static func buttonRect(
        _ button: DeviceChrome.Button,
        imageSize: CGSize,
        upright: CGSize,
        chrome: DeviceChrome,
        hovered: Bool
    ) -> CGRect {
        let body = bodyRect(upright: upright, chrome: chrome)
        let offset = hovered ? button.rolloverOffset : button.offset
        let y: CGFloat = switch button.anchor {
        case .left, .right, .top: body.maxY - offset.y - imageSize.height
        case .bottom: body.minY - offset.y - imageSize.height
        }
        let x: CGFloat = switch button.anchor {
        case .left: offset.x - sideButtonProtrusion
        case .right: upright.width - imageSize.width + offset.x + sideButtonProtrusion
        case .top, .bottom: body.midX - imageSize.width / 2 + offset.x
        }
        return CGRect(x: x, y: y, width: imageSize.width, height: imageSize.height)
    }

    /// Upright device space into a view: fitted, centred and turned to the orientation.
    public static func transform(viewSize: CGSize, upright: CGSize, orientation: DeviceOrientation) -> CGAffineTransform {
        let shown = orientation.displayedSize(portrait: upright)
        let placed = ScreenGeometry.fittedRect(container: viewSize, content: shown)
        guard upright.width > 0, !placed.isEmpty else { return .identity }
        let scale = placed.width / shown.width
        return CGAffineTransform.identity
            .translatedBy(x: placed.midX, y: placed.midY)
            // Quarter turns are clockwise on screen, which is negative with y running up.
            .rotated(by: -CGFloat(orientation.quarterTurns) * .pi / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -upright.width / 2, y: -upright.height / 2)
    }
}
