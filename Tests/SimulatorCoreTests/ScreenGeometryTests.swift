import CoreGraphics
import Testing
@testable import SimulatorCore

struct ScreenGeometryTests {
    let pixels = CGSize(width: 1206, height: 2622)

    @Test func fittedRectLetterboxes() {
        let rect = ScreenGeometry.fittedRect(container: CGSize(width: 200, height: 100), content: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    @Test func viewCornersMapToFramebufferCorners() {
        let view = CGSize(width: 402, height: 874)
        // AppKit's origin is bottom left; the device's is top left.
        let topLeft = ScreenGeometry.normalizedPoint(viewPoint: CGPoint(x: 0, y: 874), viewSize: view, pixelSize: pixels, orientation: .portrait)
        let bottomRight = ScreenGeometry.normalizedPoint(viewPoint: CGPoint(x: 402, y: 0), viewSize: view, pixelSize: pixels, orientation: .portrait)
        #expect(topLeft == CGPoint(x: 0, y: 0))
        #expect(bottomRight == CGPoint(x: 1, y: 1))
    }

    @Test func pointsOffTheGlassAreClamped() {
        let view = CGSize(width: 402, height: 874)
        let point = ScreenGeometry.normalizedPoint(viewPoint: CGPoint(x: -50, y: -50), viewSize: view, pixelSize: pixels, orientation: .portrait)
        #expect(point == CGPoint(x: 0, y: 1))
    }

    @Test func rotationRoundTripsThroughEveryOrientation() {
        // Turning the shown point back to portrait and comparing against a direct derivation.
        let shown = CGPoint(x: 0.25, y: 0.1)
        #expect(ScreenGeometry.portraitPoint(fromShown: shown, orientation: .portrait) == shown)
        #expect(ScreenGeometry.portraitPoint(fromShown: shown, orientation: .portraitUpsideDown) == CGPoint(x: 0.75, y: 0.9))
        #expect(ScreenGeometry.portraitPoint(fromShown: shown, orientation: .landscapeLeft) == CGPoint(x: 0.1, y: 0.75))
        #expect(ScreenGeometry.portraitPoint(fromShown: shown, orientation: .landscapeRight) == CGPoint(x: 0.9, y: 0.25))
    }

    @Test func landscapeViewUsesSwappedAspect() {
        // A landscape window is the portrait framebuffer turned, so its centre is still the centre.
        let view = CGSize(width: 874, height: 402)
        let centre = ScreenGeometry.normalizedPoint(viewPoint: CGPoint(x: 437, y: 201), viewSize: view, pixelSize: pixels, orientation: .landscapeLeft)
        #expect(abs(centre.x - 0.5) < 0.001 && abs(centre.y - 0.5) < 0.001)
    }

    @Test func bottomEdgeIsDetected() {
        #expect(ScreenGeometry.edge(forPortraitPoint: CGPoint(x: 0.5, y: 0.995)) == .bottom)
        #expect(ScreenGeometry.edge(forPortraitPoint: CGPoint(x: 0.5, y: 0.5)) == .none)
    }

    @Test func orientationRotationsCycle() {
        var orientation = DeviceOrientation.portrait
        for _ in 0..<4 { orientation = orientation.rotatedLeft }
        #expect(orientation == .portrait)
        #expect(DeviceOrientation.portrait.rotatedRight == .landscapeLeft)
        #expect(DeviceOrientation.landscapeLeft.displayedSize(portrait: pixels) == CGSize(width: 2622, height: 1206))
    }
}
