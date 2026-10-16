import CoreGraphics

/// How the device is turned relative to its portrait framebuffer, which never rotates itself.
public enum DeviceOrientation: Int, Sendable, CaseIterable {
    case portrait
    case landscapeLeft
    case portraitUpsideDown
    case landscapeRight

    /// Clockwise turn applied to the portrait image to get what the window shows.
    public var quarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Rotate Left in the classic Simulator: the device turns counter-clockwise.
    public var rotatedLeft: DeviceOrientation {
        switch self {
        case .portrait: .landscapeRight
        case .landscapeRight: .portraitUpsideDown
        case .portraitUpsideDown: .landscapeLeft
        case .landscapeLeft: .portrait
        }
    }

    public var rotatedRight: DeviceOrientation { rotatedLeft.rotatedLeft.rotatedLeft }

    /// The value the guest's workspace port expects.
    public var gsEventValue: UInt32 {
        switch self {
        case .portrait: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        case .landscapeLeft: 4
        }
    }

    public func displayedSize(portrait size: CGSize) -> CGSize {
        isLandscape ? CGSize(width: size.height, height: size.width) : size
    }
}
