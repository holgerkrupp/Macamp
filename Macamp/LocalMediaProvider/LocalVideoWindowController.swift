import AVKit
import AppKit

@MainActor
final class LocalVideoWindowController: NSWindowController, NSWindowDelegate {
    private let playerView = AVPlayerView()
    private let docking = WindowDockingController()
    private let relatedWindows: () -> [NSWindow]
    private var displayedItemID: PlaybackItemID?
    private var dismissedItemID: PlaybackItemID?

    init(player: AVPlayer, relatedWindows: @escaping () -> [NSWindow]) {
        self.relatedWindows = relatedWindows
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        window.contentView = playerView
        window.title = "Macamp Video"
        window.minSize = CGSize(width: 320, height: 180)
        window.aspectRatio = CGSize(width: 16, height: 9)
        window.setFrameAutosaveName("MacampLocalVideoWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(currentItem: PlaybackItem?, isActive: Bool) {
        guard isActive, let item = currentItem, item.mediaKind == .localVideo else {
            displayedItemID = nil
            dismissedItemID = nil
            window?.orderOut(nil)
            return
        }
        guard displayedItemID != item.id else { return }
        displayedItemID = item.id
        dismissedItemID = nil
        window?.title = item.title
        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        }
        updateAspectRatio(for: item)
    }

    func showCurrentItemIfAvailable(_ item: PlaybackItem?) {
        guard let item, item.mediaKind == .localVideo,
              item.id == displayedItemID, item.id != dismissedItemID,
              let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dismissedItemID = displayedItemID
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = window.screen else { return }
        let others = relatedWindows().filter { $0 !== window && $0.isVisible }
        let origin = docking.snappedOrigin(
            for: window.frame,
            near: others.map(\.frame),
            screen: screen.visibleFrame,
            scale: 1
        )
        if abs(origin.x - window.frame.origin.x) > 0.5 || abs(origin.y - window.frame.origin.y) > 0.5 {
            window.setFrameOrigin(origin)
        }
        docking.update(window: window)
    }

    private func updateAspectRatio(for item: PlaybackItem) {
        guard let url = item.sourceURL else { return }
        let itemID = item.id
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize),
                  size.width > 0, size.height > 0,
                  let self, self.displayedItemID == itemID else { return }
            self.window?.aspectRatio = size
        }
    }
}
