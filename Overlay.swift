import Cocoa
import UniformTypeIdentifiers

/// Borderless panel that takes key events without activating the app, Spotlight-style.
private final class OverlayPanel: NSPanel {
    var onKey: (NSEvent) -> Void = { _ in }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey(event) }
}

final class Overlay: NSObject, NSTextFieldDelegate {
    private let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let store = TileStore()
    private lazy var tilesView = TilesView(store: store)
    /// True while the image picker is up, so a swipe cannot cover it with the overlay.
    private var isPicking = false
    private var rename: (field: NSTextField, key: String)?
    /// Last rendered window thumbnails by space id; shown at once, then replaced by a fresh render.
    private var thumbnailCache: [Int: CGImage] = [:]
    private var renderGeneration = 0
    private var screen: NSScreen?

    override init() {
        super.init()
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = tilesView
        panel.onKey = { [weak self] event in self?.handleKey(event) }
        tilesView.onPick = { [weak self] space in self?.pick(space) }
        tilesView.onChooseImage = { [weak self] space in self?.chooseImage(for: space) }
        tilesView.onRemoveImage = { [weak self] space in self?.removeImage(for: space) }
        tilesView.onRename = { [weak self] space, rect in self?.beginRename(space, in: rect) }
        tilesView.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let mouse = NSEvent.mouseLocation
        guard !isPicking,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        self.screen = screen
        let spaces = Spaces.list()
        tilesView.spaces = spaces
        tilesView.thumbnails = thumbnailCache
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        refreshThumbnails(for: spaces.filter { !store.hasImage(for: $0.key) }, on: screen)
    }

    /// Only orders the panel out. Handing focus back here, while a switch is in flight, is what
    /// pulled the screen to another space; the picker hands focus back itself.
    func hide() {
        finishRename(save: true)
        panel.orderOut(nil)
    }

    private func pick(_ space: Space) {
        hide()
        Switcher.go(to: space)
    }

    // MARK: Thumbnails

    private func refreshThumbnails(for spaces: [Space], on screen: NSScreen) {
        guard !spaces.isEmpty,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }
        let visiblePIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
            .map(\.processIdentifier))
        let request = Thumbnails.Request(
            spaceIDs: Set(spaces.map(\.id)),
            displayBounds: CGDisplayBounds(displayID),
            wallpaper: wallpaper(for: screen),
            visiblePIDs: visiblePIDs,
            pixelWidth: 800)
        renderGeneration += 1
        let generation = renderGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let images = Thumbnails.render(request)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.renderGeneration else { return }
                self.thumbnailCache.merge(images) { _, new in new }
                if self.isVisible { self.tilesView.thumbnails = self.thumbnailCache }
            }
        }
    }

    private func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        // Downsample on load; a full-size HEIC wallpaper is far bigger than a tile needs.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    // MARK: Renaming

    private func beginRename(_ space: Space, in rect: NSRect) {
        finishRename(save: true)
        let field = NSTextField(frame: rect)
        field.stringValue = store.name(for: space)
        field.font = .systemFont(ofSize: 15, weight: .medium)
        field.textColor = .white
        field.backgroundColor = NSColor(white: 0.2, alpha: 1)
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        tilesView.addSubview(field)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        rename = (field, space.key)
    }

    /// Enter saves, Escape cancels; closing the overlay or clicking elsewhere saves. An empty name restores the default.
    private func finishRename(save: Bool) {
        guard let (field, key) = rename else { return }
        rename = nil
        if save { store.setName(field.stringValue, for: key) }
        field.removeFromSuperview()
        panel.makeFirstResponder(nil)
        tilesView.needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishRename(save: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishRename(save: false)
            return true
        default:
            return false
        }
    }

    // MARK: Images

    /// Drops the custom image; the tile goes back to the window thumbnail.
    private func removeImage(for space: Space) {
        store.removeImage(for: space.key)
        tilesView.needsDisplay = true
        if let screen { refreshThumbnails(for: tilesView.spaces.filter { !store.hasImage(for: $0.key) }, on: screen) }
    }

    private func chooseImage(for space: Space) {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let title = store.name(for: space)
        isPicking = true
        hide()
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        // Open on the space in view, full-screen ones included, instead of pulling the screen to a desktop.
        picker.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        picker.allowedContentTypes = [.image]
        picker.message = "Image for \(title)"
        picker.begin { [weak self] response in
            if response == .OK, let url = picker.url {
                self?.store.setImage(url.path, for: space.key)
            }
            Overlay.returnFocus(to: previousApp)
            self?.isPicking = false
            // Re-show after focus has moved, so the panel keeps the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.show() }
        }
    }

    /// Hands focus back only to an app with a window in view; activating one whose windows are
    /// all on other spaces would switch spaces.
    private static func returnFocus(to app: NSRunningApplication?) {
        guard let app else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hasVisibleWindow = windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard hasVisibleWindow else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current, options: [])
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53 { return hide() }  // Escape
        guard let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
              digit >= 1, digit <= tilesView.spaces.count
        else { return }
        pick(tilesView.spaces[digit - 1])
    }
}
