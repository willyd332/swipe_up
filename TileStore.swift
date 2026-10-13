import Cocoa

/// Per-space customizations keyed by Space.key: an image path and a display name.
final class TileStore {
    private let images = JSONMap(file: "images.json")
    private let names = JSONMap(file: "names.json")
    private var imageCache: [String: NSImage] = [:]

    func image(for key: String) -> NSImage? {
        guard let path = images[key] else { return nil }
        if let cached = imageCache[path] { return cached }
        let image = NSImage(contentsOfFile: path)
        imageCache[path] = image
        return image
    }

    func hasImage(for key: String) -> Bool { images[key] != nil }

    func setImage(_ path: String, for key: String) { images[key] = path }

    func removeImage(for key: String) { images[key] = nil }

    func name(for space: Space) -> String { names[space.key] ?? space.label }

    /// An empty name clears the custom one, so the tile falls back to "Desktop N" or the app name.
    func setName(_ name: String, for key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[key] = trimmed.isEmpty ? nil : trimmed
    }
}

/// A [String: String] mirrored to one JSON file in Application Support/SpaceOverview.
private final class JSONMap {
    private let fileURL: URL
    private var values: [String: String] = [:]

    init(file: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("SpaceOverview/\(file)")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        } catch {
            fputs("space-overview: could not read \(fileURL.path): \(error.localizedDescription)\n", stderr)
        }
    }

    subscript(key: String) -> String? {
        get { values[key] }
        set {
            values[key] = newValue
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(values).write(to: fileURL, options: .atomic)
        } catch {
            fputs("space-overview: could not save \(fileURL.path): \(error.localizedDescription)\n", stderr)
        }
    }
}
