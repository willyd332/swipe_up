import Cocoa

/// Draws one tile per space with its name underneath. Click a tile to switch; right-click (or
/// Control-click) the picture for an image menu, or the name to rename it.
final class TilesView: NSView {
    var spaces: [Space] = [] { didSet { needsDisplay = true } }
    var thumbnails: [Int: CGImage] = [:] { didSet { needsDisplay = true } }
    var onPick: (Space) -> Void = { _ in }
    var onChooseImage: (Space) -> Void = { _ in }
    var onRemoveImage: (Space) -> Void = { _ in }
    var onRename: (Space, NSRect) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
    private let store: TileStore

    private static let labelHeight: CGFloat = 26
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white,
    ]
    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.lightGray,
    ]

    init(store: TileStore) {
        self.store = store
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let (space, _, labelRect) = hit(event) else { return onDismiss() }
        if event.modifierFlags.contains(.control) {
            secondaryClick(space, labelRect: labelRect, at: event)
        } else {
            onPick(space)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let (space, _, labelRect) = hit(event) else { return }
        secondaryClick(space, labelRect: labelRect, at: event)
    }

    /// Frame of the name label under a tile, in view coordinates; also where the rename field goes.
    static func labelRect(below tile: NSRect) -> NSRect {
        NSRect(x: tile.minX, y: tile.minY - labelHeight - 4, width: tile.width, height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, (space, rect)) in zip(spaces, tileRects()).enumerated() {
            NSColor.darkGray.setFill()
            rect.fill()
            if let image = store.image(for: space.key) {
                drawAspectFill(image, in: rect)
            } else if let thumbnail = thumbnails[space.id] {
                NSGraphicsContext.current?.cgContext.draw(thumbnail, in: rect)
            } else {
                let hint = "right-click to set image" as NSString
                let size = hint.size(withAttributes: Self.hintAttributes)
                hint.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: Self.hintAttributes)
            }
            if space.isCurrent {
                let outline = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
                outline.lineWidth = 4
                NSColor.systemBlue.setStroke()
                outline.stroke()
            }
            let label = "\(index + 1)  \(store.name(for: space))" as NSString
            label.draw(in: Self.labelRect(below: rect), withAttributes: Self.labelAttributes)
        }
        let help = "Click: switch    Right-click picture: image menu    Right-click name: rename    Esc: close" as NSString
        let size = help.size(withAttributes: Self.hintAttributes)
        help.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 40), withAttributes: Self.hintAttributes)
    }

    private func secondaryClick(_ space: Space, labelRect: NSRect, at event: NSEvent) {
        if labelRect.contains(convert(event.locationInWindow, from: nil)) {
            return onRename(space, labelRect)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction("Choose Image…") { [weak self] in self?.onChooseImage(space) })
        let remove = MenuAction("Remove Image") { [weak self] in self?.onRemoveImage(space) }
        remove.isEnabled = store.hasImage(for: space.key)
        menu.addItem(remove)
        menu.addItem(MenuAction("Rename") { [weak self] in self?.onRename(space, labelRect) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func tileRects() -> [NSRect] {
        let count = spaces.count
        guard count > 0, bounds.width > 0 else { return [] }
        let columns = min(count, 4)
        let rows = (count + columns - 1) / columns
        let gap: CGFloat = 36, labelBand: CGFloat = 30
        let width = min(380, (bounds.width - 120 - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let height = width * bounds.height / bounds.width
        let gridHeight = CGFloat(rows) * (height + labelBand) + CGFloat(rows - 1) * gap
        let top = bounds.midY + gridHeight / 2
        return (0..<count).map { i in
            let row = i / columns, column = i % columns
            let inRow = min(columns, count - row * columns)
            let rowWidth = CGFloat(inRow) * width + CGFloat(inRow - 1) * gap
            let x = bounds.midX - rowWidth / 2 + CGFloat(column) * (width + gap)
            let y = top - CGFloat(row) * (height + labelBand + gap) - height
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    private func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let crop = NSSize(width: rect.width / scale, height: rect.height / scale)
        let source = NSRect(x: (size.width - crop.width) / 2, y: (size.height - crop.height) / 2, width: crop.width, height: crop.height)
        image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
    }

    /// The space whose picture or name is under the event, with both rects.
    private func hit(_ event: NSEvent) -> (Space, NSRect, NSRect)? {
        let point = convert(event.locationInWindow, from: nil)
        for (space, tile) in zip(spaces, tileRects()) {
            let label = Self.labelRect(below: tile)
            if tile.contains(point) || label.contains(point) { return (space, tile, label) }
        }
        return nil
    }
}

/// Menu item that runs a closure, so the menu needs no selector plumbing.
private final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
