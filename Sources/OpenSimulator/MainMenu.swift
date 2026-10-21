import AppKit

/// The menu bar, laid out after the classic Simulator's, with its shortcuts. Device actions have a
/// nil target, so they reach whichever device window is key through the responder chain.
@MainActor
enum MainMenu {
    static func build(app: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(app)))
        main.addItem(submenu(fileMenu(app)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(deviceMenu()))
        main.addItem(submenu(ioMenu()))
        main.addItem(submenu(featuresMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func appMenu(_ app: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "OpenSimulator")
        menu.addItem(item("About OpenSimulator", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: app))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide OpenSimulator", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit OpenSimulator", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(_ app: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Simulator…", #selector(AppDelegate.newSimulator(_:)), "n", target: app))
        let open = NSMenuItem(title: "Open Simulator", action: nil, keyEquivalent: "")
        let chooser = NSMenu(title: "Open Simulator")
        chooser.delegate = app
        open.submenu = chooser
        menu.addItem(open)
        menu.addItem(item("Device Manager", #selector(AppDelegate.showManager(_:)), "2", [.command, .shift], target: app))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save Screen", #selector(DeviceWindowController.saveScreen(_:)), "s"))
        menu.addItem(item("Send Files…", #selector(DeviceWindowController.sendFiles(_:)), "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Shut Down", #selector(DeviceWindowController.shutDownDevice(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Screen", #selector(DeviceWindowController.copyScreen(_:)), "c", [.command, .control]))
        menu.addItem(item("Type Pasteboard", #selector(DeviceWindowController.typePasteboard(_:)), "v", [.command, .option]))
        return menu
    }

    private static func deviceMenu() -> NSMenu {
        let menu = NSMenu(title: "Device")
        menu.addItem(item("Rotate Left", #selector(DeviceWindowController.rotateLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        menu.addItem(item("Rotate Right", #selector(DeviceWindowController.rotateRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        menu.addItem(item("Shake", #selector(DeviceWindowController.shake(_:)), "z", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Home", #selector(DeviceWindowController.pressHome(_:)), "h", [.command, .shift]))
        menu.addItem(item("Swipe Home", #selector(DeviceWindowController.swipeHome(_:))))
        menu.addItem(item("App Switcher", #selector(DeviceWindowController.showAppSwitcher(_:)), "h", [.command, .shift, .control]))
        menu.addItem(item("Lock", #selector(DeviceWindowController.pressLock(_:)), "l"))
        menu.addItem(item("Siri", #selector(DeviceWindowController.pressSiri(_:)), "h", [.command, .shift, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Restart", #selector(DeviceWindowController.restartDevice(_:))))
        menu.addItem(item("Erase All Content and Settings…", #selector(DeviceWindowController.eraseDevice(_:))))
        return menu
    }

    private static func ioMenu() -> NSMenu {
        let menu = NSMenu(title: "I/O")
        menu.addItem(item("Connect Hardware Keyboard", #selector(DeviceWindowController.toggleHardwareKeyboard(_:)), "k", [.command, .shift]))
        menu.addItem(item("Keyboard Settings", #selector(DeviceWindowController.openKeyboardSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Volume Up", #selector(DeviceWindowController.volumeUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        menu.addItem(item("Volume Down", #selector(DeviceWindowController.volumeDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        return menu
    }

    private static func featuresMenu() -> NSMenu {
        let menu = NSMenu(title: "Features")
        menu.addItem(item("Toggle Appearance", #selector(DeviceWindowController.toggleAppearance(_:)), "a", [.command, .shift]))
        menu.addItem(item("Open URL…", #selector(DeviceWindowController.openURL(_:)), "u", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Simulate Memory Warning", #selector(DeviceWindowController.simulateMemoryWarning(_:)), "m", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        for mode in ScaleMode.allCases {
            let entry = item(mode.title, #selector(DeviceWindowController.setScaleMode(_:)), mode.keyEquivalent)
            entry.representedObject = mode
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Show Device Bezels", #selector(DeviceWindowController.toggleBezel(_:))))
        menu.addItem(item("Stay On Top", #selector(DeviceWindowController.toggleStayOnTop(_:)), "t", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
