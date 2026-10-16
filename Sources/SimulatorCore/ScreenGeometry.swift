import CoreGraphics

/// Pure conversions between a window's view coordinates and the device's normalized touch space.
public enum ScreenGeometry {
    /// The aspect-fit rectangle for `content` inside `container`, centred.
    public static func fittedRect(container: CGSize, content: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, content.width > 0, content.height > 0 else {
            return .zero
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// A point in AppKit view coordinates (origin bottom left) to the portrait framebuffer's
    /// normalized space (origin top left), clamped to the screen so a drag that strays off the glass
    /// stays a contact at the edge.
    public static func normalizedPoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        pixelSize: CGSize,
        orientation: DeviceOrientation
    ) -> CGPoint {
        let shownSize = orientation.displayedSize(portrait: pixelSize)
        let screen = fittedRect(container: viewSize, content: shownSize)
        guard screen.width > 0, screen.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = min(max((viewPoint.x - screen.minX) / screen.width, 0), 1)
        let y = min(max(1 - (viewPoint.y - screen.minY) / screen.height, 0), 1)
        return portraitPoint(fromShown: CGPoint(x: x, y: y), orientation: orientation)
    }

    /// Undoes the turn the window applies, so the digitizer gets portrait-native coordinates.
    public static func portraitPoint(fromShown shown: CGPoint, orientation: DeviceOrientation) -> CGPoint {
        switch orientation {
        case .portrait: shown
        case .landscapeLeft: CGPoint(x: shown.y, y: 1 - shown.x)
        case .portraitUpsideDown: CGPoint(x: 1 - shown.x, y: 1 - shown.y)
        case .landscapeRight: CGPoint(x: 1 - shown.y, y: shown.x)
        }
    }

    /// The edge a contact starting at a portrait-native point is on, so a drag up from the bottom
    /// is the system home gesture, as on a real device.
    public static func edge(forPortraitPoint point: CGPoint, threshold: CGFloat = 0.02) -> EdgeKind {
        if point.y >= 1 - threshold { return .bottom }
        if point.y <= threshold { return .top }
        if point.x <= threshold { return .left }
        if point.x >= 1 - threshold { return .right }
        return .none
    }

    public enum EdgeKind: Sendable { case none, top, left, bottom, right }
}
