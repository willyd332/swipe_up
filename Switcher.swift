import Cocoa

// _AXUIElementGetWindow maps an accessibility window to its window-server id; private but stable for years.
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let axGetWindow: AXGetWindowFn? = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: AXGetWindowFn.self) }

// Live symbolic-hotkey calls: editing com.apple.symbolichotkeys only takes effect at next login.
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private typealias GetHotKeyValueFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
private typealias IsHotKeyEnabledFn = @convention(c) (Int32) -> Bool
private typealias SetHotKeyValueFn = @convention(c) (Int32, UInt16, UInt16, UInt32) -> Int32
private typealias SetHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32
private let getHotKeyValue = dlsym(skylight, "CGSGetSymbolicHotKeyValue").map { unsafeBitCast($0, to: GetHotKeyValueFn.self) }
private let isHotKeyEnabled = dlsym(skylight, "CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: IsHotKeyEnabledFn.self) }
private let setHotKeyValue = dlsym(skylight, "CGSSetSymbolicHotKeyValue").map { unsafeBitCast($0, to: SetHotKeyValueFn.self) }
private let setHotKeyEnabled = dlsym(skylight, "CGSSetSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: SetHotKeyEnabledFn.self) }

/// Jumps straight to a space with exactly one action per click: no stepping, no polling, no retries.
/// Desktops: one "Switch to Desktop N" shortcut, rebound to Control-Option-Shift-N while the app runs.
/// Full-screen spaces: raise that app's full-screen window and make the app frontmost; macOS follows it.
enum Switcher {
    private static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]  // 1...9
    private static let modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)] = [
        (59, .maskControl), (58, .maskAlternate), (56, .maskShift),
    ]
    private static let firstDesktopHotKey: Int32 = 118  // "Switch to Desktop 1"; 119 is Desktop 2, and so on
    private static var lastSwitch = Date.distantPast
    private static var shortcutsInstalled = false
    private static var savedShortcuts: [(hotKey: Int32, char: UInt16, keyCode: UInt16, mask: UInt32, enabled: Bool)] = []

    /// Binds and enables "Switch to Desktop 1-9" for this login session, remembering the previous
    /// bindings for restoreShortcuts(). Returns false if the window server refused.
    @discardableResult
    static func installShortcuts() -> Bool {
        guard let getHotKeyValue, let isHotKeyEnabled, let setHotKeyValue, let setHotKeyEnabled else { return false }
        let mask = UInt32(modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }.rawValue)
        savedShortcuts = []
        shortcutsInstalled = digitKeyCodes.enumerated().allSatisfy { index, keyCode in
            let hotKey = firstDesktopHotKey + Int32(index)
            var char: UInt16 = 0, oldKeyCode: UInt16 = 0, oldMask: UInt32 = 0
            if getHotKeyValue(hotKey, &char, &oldKeyCode, &oldMask) == 0 {
                savedShortcuts.append((hotKey, char, oldKeyCode, oldMask, isHotKeyEnabled(hotKey)))
            }
            return setHotKeyValue(hotKey, 0xFFFF, keyCode, mask) == 0 && setHotKeyEnabled(hotKey, true) == 0
        }
        return shortcutsInstalled
    }

    /// Puts back the bindings that were live before installShortcuts().
    static func restoreShortcuts() {
        guard let setHotKeyValue, let setHotKeyEnabled else { return }
        for saved in savedShortcuts {
            _ = setHotKeyValue(saved.hotKey, saved.char, saved.keyCode, saved.mask)
            _ = setHotKeyEnabled(saved.hotKey, saved.enabled)
        }
        savedShortcuts = []
        shortcutsInstalled = false
    }

    static func go(to space: Space) {
        // A double click or a held key must not queue a second transition behind the first.
        guard !space.isCurrent, Date().timeIntervalSince(lastSwitch) > 0.5 else { return }
        lastSwitch = Date()

        switch space.kind {
        case .desktop(let number):
            // Without the binding the chord would land in the frontmost app as a keystroke.
            guard shortcutsInstalled, number <= digitKeyCodes.count else {
                fputs("space-overview: no switch shortcut for desktop \(number)\n", stderr)
                return
            }
            pressShortcut(digitKeyCodes[number - 1])
        case .fullScreen(let pid, let windowID):
            focusFullScreen(pid: pid, windowID: windowID)
        }
    }

    /// Posts modifier down, key down/up, modifier up, so no modifier stays held afterwards.
    /// Modifiers the user is physically holding are left alone rather than released under them.
    private static func pressShortcut(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let held = CGEventSource.flagsState(.hidSystemState)
        let toPress = modifiers.filter { !held.contains($0.flag) }
        var flags = held.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        for modifier in toPress {
            flags.insert(modifier.flag)
            post(source, modifier.keyCode, down: true, flags: flags, isModifier: true)
        }
        post(source, keyCode, down: true, flags: flags, isModifier: false)
        post(source, keyCode, down: false, flags: flags, isModifier: false)
        for modifier in toPress.reversed() {
            flags.remove(modifier.flag)
            post(source, modifier.keyCode, down: false, flags: flags, isModifier: true)
        }
    }

    private static func post(_ source: CGEventSource?, _ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, isModifier: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        if isModifier { event.type = .flagsChanged }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func focusFullScreen(pid: pid_t, windowID: CGWindowID?) {
        let axApp = AXUIElementCreateApplication(pid)
        // Raise the full-screen window first so an app with other ordinary windows lands on the right one.
        if let windowID, let axGetWindow {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success {
                for window in value as? [AXUIElement] ?? [] {
                    var id: CGWindowID = 0
                    if axGetWindow(window, &id) == .success, id == windowID {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        break
                    }
                }
            }
        }
        // Frontmost via accessibility: unlike a relaunch request, it never makes the app open a new window.
        if AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }
}
