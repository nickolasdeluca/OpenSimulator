import CoreGraphics
import Foundation
import Testing
@testable import SimulatorCore

struct DeviceChromeTests {
    let json = """
    {"identifier":"test.phone","images":{"composite":"PhoneComposite",
     "sizing":{"leftWidth":18,"rightWidth":18,"topHeight":18,"bottomHeight":18},
     "devicePadding":{"top":0,"left":9,"bottom":0,"right":9}},
     "paths":{"simpleOutsideBorder":{"cornerRadiusX":80}},
     "inputs":[{"name":"power","type":"button","image":"X_Power BTN","anchor":"right",
                "offsets":{"normal":{"x":-8,"y":262},"rollover":{"x":-3,"y":262}}},
               {"name":"ignored","type":"switch","image":"x","anchor":"left"}]}
    """

    var chrome: DeviceChrome {
        DeviceChrome.parse(json: Data(json.utf8), bundle: URL(fileURLWithPath: "/tmp/test.devicechrome"))!
    }

    @Test func parsesInsetsPaddingAndButtons() {
        let chrome = chrome
        #expect(chrome.insets == .init(left: 18, right: 18, top: 18, bottom: 18))
        #expect(chrome.devicePadding.left == 9)
        #expect(chrome.cornerRadius == 80)
        #expect(chrome.composite == "PhoneComposite")
        #expect(chrome.buttons.map(\.name) == ["power"])
    }

    @Test func bodyWithoutArtworkIsRejected() {
        #expect(DeviceChrome.parse(json: Data(#"{"images":{}}"#.utf8), bundle: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func layoutPutsTheScreenInsideTheBody() {
        let screen = CGSize(width: 402, height: 874)
        let upright = DeviceLayout.uprightSize(screen: screen, chrome: chrome)
        #expect(upright == CGSize(width: 402 + 36 + 18, height: 874 + 36))
        #expect(DeviceLayout.screenRect(upright: upright, chrome: chrome) == CGRect(x: 27, y: 18, width: 402, height: 874))
        #expect(DeviceLayout.uprightSize(screen: screen, chrome: nil) == screen)
    }

    @Test func rightButtonStandsProudOfTheBody() {
        let upright = CGSize(width: 456, height: 910)
        let rect = DeviceLayout.buttonRect(chrome.buttons[0], imageSize: CGSize(width: 16, height: 101),
                                           upright: upright, chrome: chrome, hovered: false)
        #expect(rect.maxX > upright.width - 9)
        #expect(abs(rect.maxY - CGFloat(910 - 262)) < 0.001)
    }

    @Test func landscapeTransformTurnsTheDeviceSideways() {
        let upright = CGSize(width: 100, height: 200)
        let transform = DeviceLayout.transform(viewSize: CGSize(width: 200, height: 100), upright: upright, orientation: .landscapeLeft)
        let placed = CGRect(origin: .zero, size: upright).applying(transform)
        #expect(abs(placed.width - 200) < 0.001 && abs(placed.height - 100) < 0.001)
    }

    @Test func findsInstalledChromeForAnInstalledDeviceType() throws {
        // Only meaningful on a Mac with Xcode's device types; otherwise there is nothing to find.
        let identifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
        guard DeviceChrome.bundle(withIdentifier: identifier, extension: "simdevicetype",
                                  in: DeviceChrome.deviceTypesDirectory) != nil else { return }
        let chrome = try #require(DeviceChrome.forDeviceType(identifier))
        #expect(chrome.composite != nil || chrome.slices != nil)
    }
}
