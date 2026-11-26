# OpenSimulator

The classic iOS Simulator, back as a small native Mac app.

Xcode 27 replaced Simulator.app with Device Hub. OpenSimulator brings back the old workflow: one
plain window per device, the same menus and shortcuts, and a list of your simulators. It uses the
simulators Xcode already installs, so anything you create here also shows up in Xcode, `simctl`
and Device Hub.

It is built to stay out of your Mac's way:

- **Nothing runs while nothing changes.** There is no render loop. The screen redraws only when
  the device sends a new frame, so a still screen costs no CPU or GPU.
- **Zero-copy frames.** The window draws straight from the `IOSurface` the simulator renders into.
  Frames are never copied through the CPU.
- **Hidden windows stop drawing.** Minimize a window, cover it, or switch Spaces, and it
  disconnects from the frame stream until you can see it again.
- **Closing a window shuts the device down** (you can turn this off). A booted simulator holds
  1 to 2 GB of memory whether or not a window shows it.
- **You can see the cost.** The device list shows memory and CPU for each running simulator,
  counting every process it runs on your Mac.
- **Lightweight simulators.** Turn on Lightweight when you create a simulator to switch off iOS
  background services most apps never use: Siri, Apple Intelligence, photo analysis, Fitness,
  Home, Watch pairing, News, Weather, Wallet, Game Center, CarPlay and analytics. It saved 14–26%
  of the simulator's memory in testing. Each group lists what it breaks, and Background Services
  in a device's menu turns groups back on.
- **Frame rate limit.** Cap drawing at 30 or 15 fps in Settings if you don't need 60.
- **Small app.** AppKit and Metal, no web views and no helper daemons. About 30 MB at idle.

## Requirements

- macOS 14 or later on Apple silicon or Intel
- Xcode 26 or 27 with at least one iOS simulator runtime installed

## Download

[Download the latest release](https://ndworks.dev/opensimulator/download), unzip it and move
`OpenSimulator.app` to Applications. The app is signed with a Developer ID and notarized by Apple.

## Build and run

```sh
scripts/build-app.sh          # builds build/OpenSimulator.app (release)
open build/OpenSimulator.app
```

For development, `swift build` and `swift test` work as usual, and `swift run OpenSimulator`
starts the app without bundling it.

### Notarized build for sharing

`scripts/notarize.sh` signs the app with your Developer ID certificate, sends it to Apple's notary
service, staples the ticket and writes `build/OpenSimulator.zip`, which opens on any Mac without a
Gatekeeper warning.

It reads its credentials from a `.env` file in the repository root, which git ignores. Copy
`.env.example` to `.env` and fill in either an App Store Connect API key or an Apple ID with an
app-specific password. Then run `scripts/notarize.sh` with no arguments. The same variables also
work when set in the environment, or you can store a keychain profile once with
`xcrun notarytool store-credentials OpenSimulator` instead.

OpenSimulator uses the Xcode chosen by `xcode-select -p`. To use a different one, set
`DEVELOPER_DIR` before you launch it.

## Using it

| Action | Shortcut |
|---|---|
| Device Manager | ⇧⌘2 |
| New Simulator | ⌘N |
| Home / Swipe Home / App Switcher | ⇧⌘H / Device menu / ⌃⇧⌘H |
| Lock | ⌘L |
| Rotate Left / Right | ⌘← / ⌘→ |
| Shake | ⌃⌘Z |
| Save Screen (to Desktop) | ⌘S |
| Send Files (to the Files app or one of your apps) | ⇧⌘O |
| Copy Screen | ⌃⌘C |
| Paste Mac clipboard into the device | ⌘V |
| Copy device selection to the Mac | ⌘C |
| Type Pasteboard as keystrokes | ⌥⌘V |
| Connect Hardware Keyboard | ⇧⌘K |
| Keyboard Settings (Settings › General › Keyboard) | I/O menu |
| Toggle Light/Dark Appearance | ⇧⌘A |
| Open URL | ⇧⌘U |
| Simulate Memory Warning | ⇧⌘M |
| Physical Size / Point Accurate / Pixel Accurate / Fit Screen | ⌘1 / ⌘2 / ⌘3 / ⌘4 |
| Show Device Bezels | Window menu |
| Show Bottom Bar | ⌥⌘B |
| Fold or unfold an iPhone Duo | Device › Hinge, or the bottom bar |
| Stay On Top | ⌥⌘T |

- Each device opens in its own frame, using the artwork Xcode installs in
  `/Library/Developer/DeviceKit`. Click the side buttons, or drag the frame to move the window.
  Turn the frame off with Window › Show Device Bezels.
- The bar under the device has Home, App Switcher, Save Screen and Rotate, and on an iPhone Duo
  its three hinge postures: closed, partially open and open. Hide it with Window › Show Bottom Bar.
- Opening an iPhone Duo moves iOS to its inner panel, and the window follows. The inner panel is
  shown without a frame, since Xcode only installs artwork for the closed device.
- Each device remembers its window size, whether you picked it from the Window menu or dragged a
  corner. Devices you open for the first time use the size set in Settings.
- Click to tap and drag to swipe. A drag that starts at the bottom edge acts as the home gesture.
- Hold ⌥ to pinch: the pointer is one finger and its mirror image across the center is the
  other. A trackpad pinch works too.
- Drop an `.app` on a device window to install it, a photo or video to add it to Photos, or a URL
  to open it. Other files and folders go to the Files app, under On My iPhone, and Files opens to
  show them. Hold ⌥ while dropping to send photos and apps to Files as well.
- File › Send Files… copies files and folders to the Files app or to the Documents folder of an
  app you installed.
- I/O › Keyboard Settings opens Settings › General › Keyboard, where Auto-Correction, Check
  Spelling and the other keyboard switches are. On iOS 26.5 simulators, tapping Keyboard in
  Settings shows a blank page, so this is the way to reach them.

## Agents

An agent such as Claude Code can use the device you have open, and you watch it work, the way
Claude in Chrome works in a browser tab. The app ships `opensim`, a command line tool and MCP
server, in `OpenSimulator.app/Contents/Helpers/opensim`.

- Before its first action the agent brings up the device's window. If OpenSimulator isn't
  running, it starts.
- Each touch shows as a dot on the screen, and typed text and shortcuts show as a caption. While
  the agent is at work the screen has an orange border and a banner.
- **Stop** in the banner refuses the agent's next commands, and the agent is told you stopped it.
  **Allow** lets it go on. A restart of the device also clears it.
- When the agent turns the device, the window turns with it.

To give Claude Code the tools:

```sh
claude mcp add opensim -- /Applications/OpenSimulator.app/Contents/Helpers/opensim mcp
```

The tools are `list_devices`, `screenshot`, `device_info`, `tap`, `long_press`, `swipe`,
`type_text`, `press_key`, `rotate`, `press_home` and `open_url`. The screenshot has one pixel per
point, so the agent taps a position it sees in the image as is.

### Command line

The same actions work from a shell or a script:

```sh
ln -s /Applications/OpenSimulator.app/Contents/Helpers/opensim ~/.local/bin/opensim

opensim tap 400 220                     # points, origin top left, current orientation
opensim tap 400 220 --count 2           # double tap
opensim longpress 400 220 --duration 0.8
opensim swipe 500 900 500 300 --duration 0.3
opensim type "Olá, café"                # US hardware keyboard; accents through Option dead keys
opensim type "€ 😀" --paste             # anything else: simctl pbcopy, then ⌘V
opensim key b --mods cmd                # return, escape, delete, tab, arrows, f1…f12, any character
opensim rotate left                     # or right, portrait, landscape-left, landscape-right, upside-down
opensim home
opensim info                            # {"width": 1024, "height": 1366, "scale": 2, "orientation": "portrait", …}
```

Every command takes `--device <UDID|name>`, which can be left out when exactly one simulator is
booted. It prints nothing on success, and errors go to stderr with exit status 1 (failed),
2 (bad arguments), 3 (device missing or not booted), 4 (not supported by this Xcode) or 5 (stopped
from the window). Booting, screenshots and the pasteboard are left to `xcrun simctl`.

Nothing in iOS reports which way the device is turned, so the orientation is the last one
`opensim` or the app set during the current boot. `opensim` tells the app what it does through
local distributed notifications: no network port, and nothing runs while no agent does.

## How it works

Device lifecycle (create, boot, shut down, erase, delete), screenshots, URLs, installs and
appearance all go through `xcrun simctl`, which is public and stable.

The screen and input need Xcode's private frameworks, which OpenSimulator loads from the selected
Xcode when it starts. Nothing private is linked or bundled:

- **CoreSimulator** lists devices and sends change notifications, so the app never polls. It also
  provides each device's display port, which gives the framebuffer as an `IOSurface` with a
  callback on every redraw.
- **SimulatorKit** builds Indigo HID messages for touch, keyboard and hardware buttons.
  Rotation is a GSEvent sent to the guest's `PurpleWorkspacePort`.

A few things only the guest can do. Their tools ship as source in `Helpers/`, are built for the
simulator with the selected Xcode on first use, and run with `simctl spawn`: one opens Settings
links `simctl openurl` refuses, and one sets an iPhone Duo's hinge angle with the same
vendor-defined HID event Device Hub sends, which is what makes iOS switch panels.

All of this is in `Sources/SimBridge`. Every selector is checked before it is used, so a future
Xcode that renames something makes one feature report that it's unavailable instead of crashing.

`simctl openurl` refuses Settings links. For those, the app builds a small helper,
`Helpers/open-sensitive-url.m`, for the simulator with your Xcode the first time it's needed, and
runs it inside the device with `simctl spawn`. It asks the device's LaunchServices to open the
link the way SpringBoard would. The app carries it as source because Apple's notarization leaves
simulator code out, and Gatekeeper would then reject the app.

```
Sources/
  SimBridge/       Objective-C bridge to CoreSimulator and SimulatorKit (private API)
  SimulatorCore/   simctl wrapper, coordinate math, keyboard map, resource monitor
  OpenSimulator/   The app: device manager, device windows, Metal renderer, menus
  opensim/         Command line tool and MCP server for agents
Helpers/           open-sensitive-url, which the app builds for the simulator on first use
Tests/             Unit tests for SimulatorCore
scripts/           build-app.sh
packaging/         Info.plist and AppIcon.icon (Icon Composer; follows light, dark, tinted, clear)
```

## Limitations

- Foldables (iPhone Duo) show their cover screen only, and agents touch only that screen.
- iOS only. tvOS, watchOS and visionOS are not supported.
- This app relies on private Apple frameworks. A new Xcode can break the screen or input until
  the bridge is updated. Device management through `simctl` keeps working either way.
- The app can't be sandboxed, so it can't go on the Mac App Store.

## Acknowledgements

The private framework details come from prior work by OpenDeviceHub, idb and Siniulator. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).

OpenSimulator is an independent project. It is not affiliated with, endorsed by or sponsored by
Apple Inc. Apple, iOS and Xcode are trademarks of Apple Inc., registered in the U.S. and other
countries.
