import AppKit
import QuickLookThumbnailing

/// The file shelf on the GoldWare Voice indicator: drop a file, screenshot, or image on the pill to park
/// it there, then drag it back out wherever it is needed. Files are shelved by reference (the original
/// stays where it is); only things that arrive without a file of their own (a pasted image, a promised
/// file from a browser or the screenshot thumbnail) are saved into `shelf/` in the data folder.
final class ShelfStore {
    static let maxItems = 8
    private(set) var items: [URL] = []        // newest first
    var onChange: () -> Void = {}
    /// Off for previews: nothing is read from or written to the real shelf.
    private let persists: Bool
    private var thumbnails: [URL: NSImage] = [:]
    private let dir = Paths.dataDir.appendingPathComponent("shelf", isDirectory: true)
    private let promiseQueue = OperationQueue()

    init(persists: Bool = true) {
        self.persists = persists
        guard persists else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        items = (UserDefaults.standard.stringArray(forKey: "shelfItems") ?? []).map { URL(fileURLWithPath: $0) }
        prune()
        // Anything saved for the shelf that is no longer on it goes away at launch.
        let kept = Set(items.map { $0.standardizedFileURL.path })
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(where: { $0.hasPrefix(f.standardizedFileURL.path) }) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// True when the pasteboard holds something the shelf can take.
    static func canAccept(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: dropTypes) != nil
    }

    /// Takes files, promised files, or image data off a drop. Returns false when there was nothing usable.
    @discardableResult
    func accept(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach(add)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            for promise in promises {
                // A folder per drop, so two promised files with the same name cannot collide.
                let into = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
                promise.receivePromisedFiles(atDestination: into, options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { self.add(url) }
                }
            }
            return true
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
            let url = dir.appendingPathComponent("Image \(stamp.string(from: Date())).png")
            guard (try? png.write(to: url)) != nil else { return false }
            add(url)
            return true
        }
        return false
    }

    func add(_ url: URL) {
        items.removeAll { $0 == url }
        items.insert(url, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        thumbnails[url] = nil
        // A copy the shelf made itself is not deleted here: the app it was dropped into may still be
        // reading it. Unreferenced copies are cleared at the next launch.
        save()
    }

    /// Drops items whose file was moved or deleted since they were shelved.
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    /// A thumbnail for the pill: the file's icon at once, then a real preview when Quick Look has one.
    func thumbnail(for url: URL) -> NSImage {
        if let t = thumbnails[url] { return t }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        thumbnails[url] = icon
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                guard self.items.contains(url) else { return }
                self.thumbnails[url] = rep.nsImage
                self.onChange()
            }
        }
        return icon
    }

    private func save() {
        if persists { UserDefaults.standard.set(items.map(\.path), forKey: "shelfItems") }
        onChange()
    }
}
