import CoreGraphics

/// The swipe up from the bottom edge that Face ID devices use instead of a Home button, in the
/// coordinates the window shows. The guest tells "go home" from "app switcher" by speed at lift: a
/// flick goes home, a contact that comes to rest opens the switcher.
public enum HomeGesture {
    public static func homePath(steps: Int = 14) -> [CGPoint] {
        line(from: CGPoint(x: 0.5, y: 0.995), to: CGPoint(x: 0.5, y: 0.45), steps: steps)
    }

    public static func appSwitcherPath(steps: Int = 14) -> [CGPoint] {
        let stroke = line(from: CGPoint(x: 0.5, y: 0.995), to: CGPoint(x: 0.5, y: 0.6), steps: steps)
        // Tiny alternating moves so the contact is genuinely at rest rather than lifted mid-flight.
        let settle = (1...15).map { index in
            CGPoint(x: 0.5, y: 0.6 + (index.isMultiple(of: 2) ? 0.001 : -0.001))
        }
        return stroke + settle
    }

    public static func line(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        let count = max(steps, 1)
        return (0...count).map { index in
            let t = CGFloat(index) / CGFloat(count)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }
}
