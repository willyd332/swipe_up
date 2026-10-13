import Cocoa

// Space enumeration uses private SkyLight calls, resolved at runtime so no private headers are needed.
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64

private func skylightSymbol<T>(_ name: String, as type: T.Type) -> T {
    guard let pointer = dlsym(skylight, name) else {
        fatalError("space-overview: SkyLight symbol \(name) not found on this macOS version")
    }
    return unsafeBitCast(pointer, to: type)
}

struct Space {
    enum Kind {
        case desktop(number: Int)
        case fullScreen(pid: pid_t, windowID: CGWindowID?)
    }

    let id: Int
    let kind: Kind
    /// Image-mapping key: desktops keep their uuid across reboots; full-screen spaces are
    /// recreated on every entry into full screen, so they are keyed by app name instead.
    let key: String
    let label: String
    let isCurrent: Bool
}

enum Spaces {
    private static let mainConnection = skylightSymbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copyManagedDisplaySpaces = skylightSymbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    // The "Current Space" entry in the copied layout can lag behind; this call is the live value.
    private static let currentSpace = skylightSymbol("CGSManagedDisplayGetCurrentSpace", as: CurrentSpaceFn.self)

    /// Spaces of the display under the mouse, in Mission Control order.
    static func list() -> [Space] {
        let connection = mainConnection()
        guard let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]],
              let display = displays.first(where: { ($0["Display Identifier"] as? String) == mouseDisplayUUID() }) ?? displays.first,
              let displayID = display["Display Identifier"] as? String
        else { return [] }

        let currentID = Int(currentSpace(connection, displayID as CFString))
        var desktopNumber = 0
        return (display["Spaces"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["ManagedSpaceID"] as? Int else { return nil }
            if (raw["type"] as? Int) == 4 {
                let tiles = (raw["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
                guard let pid = raw["pid"] as? pid_t ?? tiles.first?["pid"] as? pid_t else { return nil }
                let windowID = (raw["fs_wid"] as? Int ?? tiles.first?["TileWindowID"] as? Int).map { CGWindowID($0) }
                let apps = appNames(tiles: tiles, pid: pid)
                return Space(id: id, kind: .fullScreen(pid: pid, windowID: windowID), key: "app:" + apps,
                             label: apps, isCurrent: id == currentID)
            }
            desktopNumber += 1
            let uuid = raw["uuid"] as? String ?? "id:\(id)"
            return Space(id: id, kind: .desktop(number: desktopNumber), key: "desktop:" + uuid,
                         label: "Desktop \(desktopNumber)", isCurrent: id == currentID)
        }
    }

    private static func appNames(tiles: [[String: Any]], pid: pid_t) -> String {
        let names = tiles.compactMap { $0["appName"] as? String }
        if !names.isEmpty { return names.joined(separator: " | ") }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Full screen"
    }

    private static func mouseDisplayUUID() -> String? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
