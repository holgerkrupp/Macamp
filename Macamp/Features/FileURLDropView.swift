import AppKit
import Foundation

/// Parses Finder-style file URL drops without imposing media-import policy.
/// Directories and playlists are intentionally passed through for the media service to handle.
enum FileURLDropPayloadParser {
    enum PayloadError: Error, Equatable {
        case emptyPayload
        case nonFileURL
        case unsupportedArchive(URL)
    }

    /// Common archive and disk-image formats that the player cannot import as media.
    private static let unsupportedArchiveExtensions: Set<String> = [
        "7z", "ace", "arj", "bz", "bz2", "cab", "dmg", "gz", "iso", "lz",
        "lzma", "rar", "sit", "sitx", "tar", "tbz", "tbz2", "tgz", "txz",
        "wsz", "xz", "zip", "z", "zst"
    ]

    /// Returns standardized file URLs in the order supplied, preserving duplicate entries.
    static func parse(_ urls: [URL]) -> Result<[URL], PayloadError> {
        guard !urls.isEmpty else { return .failure(.emptyPayload) }

        var normalized: [URL] = []
        normalized.reserveCapacity(urls.count)

        for url in urls {
            guard url.isFileURL else { return .failure(.nonFileURL) }
            let fileURL = url.standardizedFileURL
            guard !unsupportedArchiveExtensions.contains(fileURL.pathExtension.lowercased()) else {
                return .failure(.unsupportedArchive(fileURL))
            }
            normalized.append(fileURL)
        }

        return .success(normalized)
    }

    /// Reads only the `.fileURL` representation used by Finder file drags.
    static func read(from pasteboard: NSPasteboard) -> Result<[URL], PayloadError> {
        guard pasteboard.types?.contains(.fileURL) == true else { return .failure(.emptyPayload) }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        let urls = objects.map { $0 as URL }
        guard !urls.isEmpty else { return .failure(.emptyPayload) }
        guard urls.allSatisfy(\.isFileURL) else { return .failure(.nonFileURL) }

        // Let the shared importer report unsupported files in mixed drops.
        // Reject a skin/archive-only drop, but do not discard valid music next
        // to an archive in the same Finder selection.
        let hasNonArchiveEntry = urls.contains { !unsupportedArchiveExtensions.contains($0.pathExtension.lowercased()) }
        guard hasNonArchiveEntry else { return parse(urls) }
        return .success(urls.map(\.standardizedFileURL))
    }
}

/// Optional bridge for a skinned view to show its own subtle drag-enter/exit state.
/// Implementations should avoid replacing the view's transparent background or artwork.
@MainActor
protocol FileURLDropFeedback: AnyObject {
    func fileURLDropView(_ view: FileURLDropView, didChangeHoverState isHovering: Bool)
}

/// A small AppKit destination that forwards valid Finder file drops to an injected callback.
/// The view registers only for file URLs; it does not participate in window dragging.
@MainActor
final class FileURLDropView: NSView {
    var onFileURLsDropped: (([URL]) -> Void)?
    weak var feedback: (any FileURLDropFeedback)?

    private var isShowingDropFeedback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = Self.readDrop(from: sender) != nil
        setDropFeedback(acceptsDrop)
        return acceptsDrop ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsDrop = Self.readDrop(from: sender) != nil
        setDropFeedback(acceptsDrop)
        return acceptsDrop ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropFeedback(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.readDrop(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = Self.readDrop(from: sender), let onFileURLsDropped else {
            setDropFeedback(false)
            return false
        }
        onFileURLsDropped(urls)
        setDropFeedback(false)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDropFeedback(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isShowingDropFeedback else { return }

        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        outline.stroke()
    }

    private static func readDrop(from sender: NSDraggingInfo) -> [URL]? {
        guard case let .success(urls) = FileURLDropPayloadParser.read(from: sender.draggingPasteboard) else {
            return nil
        }
        return urls
    }

    private func setDropFeedback(_ isActive: Bool) {
        guard isShowingDropFeedback != isActive else { return }
        isShowingDropFeedback = isActive
        needsDisplay = true
        feedback?.fileURLDropView(self, didChangeHoverState: isActive)
    }
}
