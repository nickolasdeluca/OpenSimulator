# AGENTS.md

Guidance for AI coding agents working on OpenSimulator. Read `README.md` first for what the app
does and how it is laid out.

## Project

A native macOS app (AppKit, SwiftUI for sheets, Metal) that brings back the classic iOS Simulator
for Xcode 27. Its whole point is to use as little of the Mac as possible, so treat CPU, GPU and
memory cost as part of every change.

```
Sources/SimBridge/       Objective-C bridge to Xcode's private CoreSimulator and SimulatorKit
Sources/SimulatorCore/   simctl wrapper and pure logic; everything testable lives here
Sources/OpenSimulator/   The app: windows, menus, sheets, renderer, store, preferences
Tests/SimulatorCoreTests Swift Testing tests for SimulatorCore
scripts/                 build-app.sh, notarize.sh
packaging/               Info.plist template and the Icon Composer app icon
```

## Build and test

```sh
swift build                 # debug build
swift test                  # all tests must pass before you commit
scripts/build-app.sh        # build/OpenSimulator.app, ad hoc signed
scripts/notarize.sh         # Developer ID sign, notarize, staple, write build/OpenSimulator.zip
```

The build number is the commit count, so build after committing when the number matters.

## Code

- Match the surrounding code: its naming, comment density and idiom. Comments explain why, not what.
- Put logic that can be tested in `SimulatorCore` and give it tests. Keep the app target thin.
- Use `simctl` for anything it can do. Private API is only for the screen and input.
- Private frameworks are loaded from the selected Xcode at runtime. Never link or bundle them, and
  check every selector before calling it, so a renamed one disables a feature instead of crashing.
- Never add a render loop or polling. Redraw on new frames, react to CoreSimulator notifications,
  and stop work when a window can't be seen.
- When credit is due to another project, add it to `THIRD_PARTY_NOTICES.md`.

## Lightweight simulators

`ServiceGroup` in `Sources/SimulatorCore/BackgroundServices.swift` turns iOS services off with
`launchctl disable`. A wrong label can leave a device unable to boot or burning CPU, so:

- Before adding a label, boot a device with it disabled. Confirm `simctl bootstatus` finishes,
  then let the device settle for at least 90 seconds and check both memory and CPU of the
  simulator's processes, and the log rate (`simctl spawn <udid> log stream`). A service other
  processes depend on shows up as a retry loop in the logs, not as a memory cost.
- Known services that must stay on: `nanoregistryd` (boot hangs at data migration) and `sleepd`
  (SpringBoard, mobiletimerd and healthd retry it in a tight loop).
- When removing a label from a group, add it to `ServiceGroup.retiredLabels` and bump
  `currentServiceGroupsVersion` in `Preferences.swift`, so devices set up with the old list are
  fixed at their next boot.
- Each label belongs to exactly one group. The tests check this.

## Memory figures

The UI shows resident memory (`ri_resident_size`) with footprint (`ri_phys_footprint`) in the
tooltip. Footprint counts compressed and swapped pages at full size, so it can far exceed physical
RAM. Say which one you mean when reporting numbers.

## Testing against real simulators

- `swift test` covers parsing and logic. For anything that touches a device, also try it on a
  booted simulator and say plainly what you did and didn't check.
- Prefer a throwaway device (`simctl clone` or `create`). If you boot, change or fill one of the
  user's devices, put it back: remove files you copied, restore services, and shut down anything
  you booted.
- Never erase or delete a device you didn't create.

## Secrets

Notarization credentials live in `.env` (see `.env.example`), which git ignores along with `*.p8`.
Never commit, print or log their values, and never look for them elsewhere. If notarization lacks
credentials, stop and ask.

## Commits

- Conventional Commits: `feat:`, `fix:`, `docs:`, `build:`, `chore:`, with a lowercase summary.
  Explain the why in the body when it isn't obvious.
- No AI attribution. Do not add `Co-Authored-By` lines naming a model, or "Generated with" footers,
  to commits, pull requests or release notes.
- Commit, push, tag or release only when asked.
- Update `README.md` in the same commit when a feature, shortcut or requirement changes.

## Releases

1. Raise the version in `VERSION` and commit.
2. Run `scripts/notarize.sh`, then check the zip: unzip it and run
   `spctl -a -vv OpenSimulator.app` (expect "Notarized Developer ID") and
   `xcrun stapler validate OpenSimulator.app`.
3. Tag `vX.Y.Z` with an annotated tag, push it, and create the GitHub release with
   `gh release create vX.Y.Z build/OpenSimulator.zip`, with notes covering what changed, install
   steps and requirements.
4. To install locally, quit OpenSimulator, replace `/Applications/OpenSimulator.app` with the new
   build, and relaunch. Quitting shuts down running simulators when that setting is on, so check
   for booted devices first.
