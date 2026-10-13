import Cocoa

// Window capture and window-to-space lookup are private SkyLight calls, resolved at runtime.
private let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private typealias MainConnectionFn = @convention(c) () -> Int32
private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias CaptureWindowListFn = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?
private let mainConnection = dlsym(skylight, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnectionFn.self) }
private let copySpacesForWindows = dlsym(skylight, "SLSCopySpacesForWindows").map { unsafeBitCast($0, to: CopySpacesForWindowsFn.self) }
// Unlike public capture APIs, this still returns the contents of windows on spaces not in view.
private let captureWindowList = dlsym(skylight, "CGSHWCaptureWindowList").map { unsafeBitCast($0, to: CaptureWindowListFn.self) }

private let allSpacesMask: Int32 = 0x7
private let captureOptions: UInt32 = 1 << 11 | 1 << 9  // ignore global clip shape, nominal resolution

/// Mission-Control-style pictures of spaces: each space's windows drawn back to front at their
/// screen positions over the wallpaper. Needs Screen Recording access for the app or terminal that launches it.
enum Thumbnails {
    struct Request {
        let spaceIDs: Set<Int>
        let displayBounds: CGRect  // global coordinates, top-left origin
        let wallpaper: CGImage?
        let visiblePIDs: Set<pid_t>  // regular, unhidden apps; drops menu-bar agents and system chrome
        let pixelWidth: Int
    }

    /// Captures each window once and renders every requested space. Slow-ish; call off the main thread.
    static func render(_ request: Request) -> [Int: CGImage] {
        guard let mainConnection, let copySpacesForWindows, let captureWindowList else { return [:] }
        let connection = mainConnection()
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        // Front-to-back window order per space.
        var windowsBySpace: [Int: [(id: CGWindowID, frame: CGRect)]] = [:]
        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, request.visiblePIDs.contains(pid),
                  let id = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width >= 40, frame.height >= 40, frame.intersects(request.displayBounds),
                  let spaces = copySpacesForWindows(connection, allSpacesMask, [id] as CFArray)?.takeRetainedValue() as? [Int]
            else { continue }
            for space in spaces where request.spaceIDs.contains(space) {
                windowsBySpace[space, default: []].append((CGWindowID(id), frame))
            }
        }

        var captures: [CGWindowID: CGImage] = [:]
        func capture(_ id: CGWindowID) -> CGImage? {
            if let cached = captures[id] { return cached }
            var windowID = id
            let image = (captureWindowList(connection, &windowID, 1, captureOptions)?.takeRetainedValue() as? [CGImage])?.first
            captures[id] = image
            return image
        }

        let bounds = request.displayBounds
        let scale = CGFloat(request.pixelWidth) / bounds.width
        let height = Int(bounds.height * scale)
        var results: [Int: CGImage] = [:]
        for spaceID in request.spaceIDs {
            guard let context = CGContext(data: nil, width: request.pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { continue }
            let canvas = CGRect(x: 0, y: 0, width: request.pixelWidth, height: height)
            if let wallpaper = request.wallpaper {
                context.draw(wallpaper, in: aspectFill(CGSize(width: wallpaper.width, height: wallpaper.height), in: canvas))
            } else {
                context.setFillColor(gray: 0.25, alpha: 1)
                context.fill(canvas)
            }
            for window in (windowsBySpace[spaceID] ?? []).reversed() {
                guard let image = capture(window.id) else { continue }
                // Window frames are top-left origin; the bitmap context is bottom-left.
                let rect = CGRect(x: (window.frame.minX - bounds.minX) * scale,
                                  y: CGFloat(height) - (window.frame.maxY - bounds.minY) * scale,
                                  width: window.frame.width * scale, height: window.frame.height * scale)
                context.draw(image, in: rect)
            }
            results[spaceID] = context.makeImage()
        }
        return results
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = max(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
