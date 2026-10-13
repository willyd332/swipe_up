import Cocoa

// Usage: space-overview          run in the background; four-finger swipe up shows the overview
//        space-overview --show   same, but show the overview immediately
//        space-overview --list   print the spaces it sees and exit
// Quit from the menu-bar grid icon.

if CommandLine.arguments.contains("--list") {
    for (index, space) in Spaces.list().enumerated() {
        print("\(index + 1)\t\(space.isCurrent ? "*" : " ")\t\(space.id)\t\(space.label)\t\(space.key)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Switching desktops posts one keyboard shortcut, which macOS only allows with Accessibility access.
let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) {
    fputs("space-overview: no Accessibility access; clicking a tile will not switch spaces until it is granted\n", stderr)
}

if !Switcher.installShortcuts() {
    fputs("space-overview: could not bind the Switch to Desktop shortcuts; desktop tiles will not switch\n", stderr)
}
// Put the previous desktop shortcuts back on Quit and on pkill/Ctrl-C.
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    Switcher.restoreShortcuts()
}
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        Switcher.restoreShortcuts()
        exit(0)
    }
    source.resume()
    return source
}

let overlay = Overlay()
// Four fingers up opens; four down closes; three up closes too, so Mission Control's own
// three-finger swipe can take over straight from the overview.
Gesture.listen { fingers, up in
    switch (fingers, up) {
    case (4, true): if !overlay.isVisible { overlay.show() }
    case (4, false), (3, true): overlay.hide()
    default: break
    }
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    Gesture.restart()
}

final class MenuActions: NSObject {
    @objc func show() { overlay.show() }
    @objc func quit() { NSApp.terminate(nil) }
}
let menuActions = MenuActions()
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Space Overview")
let menu = NSMenu()
menu.addItem(withTitle: "Show Overview", action: #selector(MenuActions.show), keyEquivalent: "").target = menuActions
menu.addItem(withTitle: "Quit Space Overview", action: #selector(MenuActions.quit), keyEquivalent: "").target = menuActions
statusItem.menu = menu

if CommandLine.arguments.contains("--show") { overlay.show() }

app.run()
