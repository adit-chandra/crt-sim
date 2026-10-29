import AppKit
import CRTCore

enum MainMenu {
    private static let subtitleDelegate = SubtitleMenuDelegate()
    private static let audioDelegate = AudioMenuDelegate()
    static func make() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CRT Sim"
        let main = NSMenu()

        let app = submenu(of: main, title: appName)
        app.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(item("Services", submenu: services))
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(of: main, title: "File")
        file.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // NSDocumentController fills in any submenu containing a Clear Menu item.
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        file.addItem(item("Open Recent", submenu: recent))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        let view = submenu(of: main, title: "View")
        view.addItem(item("Play", #selector(PlayerWindowController.togglePlayPause(_:)), " ", []))
        view.addItem(item("Skip Back 10 Seconds", #selector(PlayerWindowController.skipBackward(_:)),
                          key(NSLeftArrowFunctionKey), []))
        view.addItem(item("Skip Forward 10 Seconds", #selector(PlayerWindowController.skipForward(_:)),
                          key(NSRightArrowFunctionKey), []))
        view.addItem(item("Loop", #selector(PlayerWindowController.toggleLoop(_:)), "l", [.command, .option]))
        let audio = NSMenu(title: "Audio Track")
        audio.delegate = audioDelegate
        audio.addItem(item("No Media Open", nil))
        view.addItem(item("Audio Track", submenu: audio))
        let subtitles = NSMenu(title: "Subtitles")
        subtitles.delegate = subtitleDelegate
        subtitles.addItem(item("Load Subtitle File…", #selector(PlayerWindowController.openSubtitle(_:)),
                               "o", [.command, .option]))
        view.addItem(item("Subtitles", submenu: subtitles))
        view.addItem(.separator())
        view.addItem(item("CRT Effect", #selector(PlayerWindowController.toggleCRTEffect(_:)), "e"))
        let presets = NSMenu(title: "CRT Preset")
        for preset in CRTPreset.all {
            let presetItem = item(preset.name, #selector(PlayerWindowController.applyPreset(_:)))
            presetItem.representedObject = preset.id
            presets.addItem(presetItem)
        }
        presets.addItem(.separator())
        presets.addItem(item("Previous Preset", #selector(PlayerWindowController.previousPreset(_:)), "["))
        presets.addItem(item("Next Preset", #selector(PlayerWindowController.nextPreset(_:)), "]"))
        view.addItem(item("CRT Preset", submenu: presets))
        view.addItem(item("Glass Pane", #selector(PlayerWindowController.toggleGlassPane(_:)), "g", [.command, .option]))
        view.addItem(item("CRT Settings…", #selector(PlayerWindowController.showCRTSettings(_:)), "i"))
        view.addItem(.separator())
        view.addItem(item("Float on Top", #selector(PlayerWindowController.toggleFloatOnTop(_:)), "t", [.command, .option]))
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let window = submenu(of: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        NSApp.helpMenu = submenu(of: main, title: "Help")
        return main
    }

    private static func submenu(of menu: NSMenu, title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        menu.addItem(item(title, submenu: submenu))
        return submenu
    }

    private static func item(_ title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ keyEquivalent: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }
}

private final class AudioMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let controller = NSApp.mainWindow?.windowController as? PlayerWindowController {
            controller.populateAudioMenu(menu)
        } else {
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: "No Media Open", action: nil, keyEquivalent: ""))
        }
    }
}

private final class SubtitleMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let controller = NSApp.mainWindow?.windowController as? PlayerWindowController {
            controller.populateSubtitleMenu(menu)
        } else {
            menu.removeAllItems()
            menu.addItem(NSMenuItem(title: "No Media Open", action: nil, keyEquivalent: ""))
        }
    }
}
