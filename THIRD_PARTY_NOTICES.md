# Third party notices

OpenSimulator's private framework bridge (`Sources/SimBridge`) relies on facts about Xcode's
CoreSimulator and SimulatorKit that were worked out by the projects below, all MIT licensed.

## OpenDeviceHub

Copyright (c) 2026 Samuel Abada. MIT license. https://github.com/Mastersam07/OpenDeviceHub

The CoreSimulator selectors and protocols declared in `Sources/SimBridge/OSPrivate.h`, the
display port selection and frame callback approach in `OSCoreSimulator.m` and `OSDisplayStream.m`,
and the Metal shader that rotates the portrait framebuffer in
`Sources/OpenSimulator/ScreenRenderer.swift` follow OpenDeviceHub's engine, which verified them on
Xcode 26.5 and Xcode 27. So does reading device frames: finding the `.devicechrome` bundle through
the device type's `chromeIdentifier`, the fields read from `chrome.json`, and the button layout
(including drawing side buttons 2pt further out than their offset) in
`Sources/SimulatorCore/DeviceChrome.swift` and `Sources/OpenSimulator/DeviceChromeView.swift`.

## idb / FBSimulatorControl

Copyright (c) Meta Platforms, Inc. and affiliates. MIT license. https://github.com/facebook/idb

The Indigo single touch message layout and the hardware button constants in
`Sources/SimBridge/OSHIDClient.m`: event sources home `0`, lock `1`, Siri `0x400002`; hardware
target `0x33`; digitizer target `0x32`; down `1` and up `2`; consumer usages `0xe9` and `0xea`;
edge values `0` to `4`.

## Siniulator

Copyright (c) Krzysztof Magiera. MIT license. https://github.com/kmagiera/Siniulator

The argument order of `IndigoHIDMessageForButton` used in `OSHIDClient.m`, and the
`PurpleWorkspacePort` orientation message in `OSCoreSimulator.m`: the 112 byte buffer, the 108 byte
message, the offsets `0`, `4`, `8`, `0x14`, `0x18`, `0x48` and `0x4c`, and the values `0x13`,
`0x7b`, `50 | 0x20000` and `4`.

---

The MIT license, as it applies to each of the works above:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
