import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SkinWindowController: NSWindowController {
    private let settings: SettingsStore
    private let renderer: SkinRendererView
    private let host: WinampSkinWindowHost
    private let auxiliaryWindows: SkinAuxiliaryWindowController

    init(
        coordinator: PlaybackCoordinator,
        skinStore: SkinLibraryStore,
        settings: SettingsStore,
        openMedia: @escaping () -> Void,
        visualizationToggle: @escaping () -> Void
    ) {
        self.settings = settings
        let auxiliaryWindows = SkinAuxiliaryWindowController(coordinator: coordinator, skinStore: skinStore)
        self.auxiliaryWindows = auxiliaryWindows
        let scale = settings.skinScale
        let canvas = skinStore.activeCatalog.canvasSize
        renderer = SkinRendererView(
            coordinator: coordinator,
            skinStore: skinStore,
            settings: settings,
            openMedia: openMedia,
            playlistToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.togglePlaylist() },
            equalizerToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.toggleEqualizer() },
            visualizationToggle: visualizationToggle
        )
        let shadeSize = skinStore.activeCatalog.format == .classic ? CGSize(width: canvas.width, height: 14) : nil
        host = WinampSkinWindowHost(normalLogicalSize: canvas, shadeLogicalSize: shadeSize, scale: CGFloat(scale))
        renderer.windowHost = host
        host.setContentView(renderer)
        host.onShadeStateChange = { [weak renderer] _ in renderer?.needsDisplay = true }
        host.regionPath = renderer.regionPath
        host.window.hasShadow = settings.playerShadow
        host.window.level = settings.playerFloating ? .floating : .normal
        super.init(window: host.window)
        host.onLogicalFrameChange = { [weak settings] frame in
            settings?.savePlayerLogicalFrame(frame)
        }
        if let restored = settings.restoredPlayerLogicalFrame() {
            host.setLogicalFrame(restored, display: false, clampedToVisibleScreens: true)
        } else if let restored = settings.restoredPlayerFrame() {
            let logical = WinampSkinWindowGeometry.logicalFrame(for: restored, scale: CGFloat(scale))
            host.setLogicalFrame(logical, display: false, clampedToVisibleScreens: true)
        } else {
            host.window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) } else { showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    func applySettings() {
        guard let window else { return }
        renderer.updateScale(settings.skinScale)
        host.setScale(CGFloat(settings.skinScale))
        host.regionPath = renderer.regionPath
        window.hasShadow = settings.playerShadow
        window.level = settings.playerFloating ? .floating : .normal
    }
}

@MainActor
private final class SkinAuxiliaryWindowController: NSObject {
    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    private var playlistHost: WinampSkinWindowHost?
    private var equalizerHost: WinampSkinWindowHost?
    private let docking = WindowDockingController()

    init(coordinator: PlaybackCoordinator, skinStore: SkinLibraryStore) {
        self.coordinator = coordinator
        self.skinStore = skinStore
    }

    func togglePlaylist() {
        if let playlistHost, playlistHost.window.isVisible {
            playlistHost.window.orderOut(nil)
            return
        }
        let host = playlistHost ?? makePlaylistHost()
        playlistHost = host
        present(host)
    }

    private func makePlaylistHost() -> WinampSkinWindowHost {
        let host = WinampSkinWindowHost(
            normalLogicalSize: ClassicPlaylistSurface.defaultSize,
            shadeLogicalSize: CGSize(width: ClassicPlaylistSurface.defaultSize.width, height: 14),
            scale: 1,
            allowsResize: true
        )
        host.resizeGrid = CGSize(width: 25, height: 29)
        host.minimumLogicalSize = CGSize(width: 275, height: 116)
        let surface = ClassicPlaylistSurface(coordinator: coordinator, skinStore: skinStore)
        surface.windowHost = host
        host.setContentView(surface)
        host.onActivityStateChange = { [weak surface] state in
            surface?.isActive = state == .active
            surface?.needsDisplay = true
        }
        host.onShadeStateChange = { [weak surface] _ in surface?.needsDisplay = true }
        host.window.isReleasedWhenClosed = false
        host.window.minSize = CGSize(width: 275, height: 116)
        host.window.center()
        return host
    }

    func toggleEqualizer() {
        if let equalizerHost, equalizerHost.window.isVisible {
            equalizerHost.window.orderOut(nil)
            return
        }
        let host = equalizerHost ?? makeEqualizerHost()
        equalizerHost = host
        present(host)
    }

    private func makeEqualizerHost() -> WinampSkinWindowHost {
        let host = WinampSkinWindowHost(
            normalLogicalSize: CGSize(width: 275, height: 116),
            shadeLogicalSize: CGSize(width: 275, height: 14),
            scale: 1,
            allowsResize: false
        )
        let surface = ClassicEqualizerSurface(coordinator: coordinator, skinStore: skinStore)
        surface.windowHost = host
        host.setContentView(surface)
        host.regionPath = skinStore.activeCatalog.equalizerRegionPath
        host.onActivityStateChange = { [weak surface] state in
            surface?.isActive = state == .active
            surface?.needsDisplay = true
        }
        let store = skinStore
        host.onShadeStateChange = { [weak host, weak surface] shaded in
            host?.regionPath = shaded ? store.activeCatalog.equalizerShadeRegionPath : store.activeCatalog.equalizerRegionPath
            surface?.needsDisplay = true
        }
        host.window.isReleasedWhenClosed = false
        host.window.center()
        return host
    }

    private func makeHost(title: String, size: CGSize, rootView: AnyView, background: NSImage?) -> WinampSkinWindowHost {
        let host = WinampSkinWindowHost(normalLogicalSize: size, scale: 1, allowsResize: true)
        host.window.title = title
        host.window.isReleasedWhenClosed = false
        host.window.minSize = CGSize(width: min(360, size.width), height: min(240, size.height))
        let container = ClassicSkinPanelView(background: background)
        let hosted = NSHostingView(rootView: rootView)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.wantsLayer = true
        hosted.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        host.setContentView(container)
        host.onLogicalFrameChange = { [weak self, weak window = host.window] _ in
            guard let window else { return }
            self?.docking.update(window: window)
        }
        host.window.center()
        return host
    }

    private func present(_ host: WinampSkinWindowHost) {
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum ClassicPanelKind { case equalizer, playlist }

private extension SkinLibraryStore {
    func classicPanelImage(kind: ClassicPanelKind) -> NSImage? {
        let name = kind == .equalizer ? activeCatalog.classicAssets?.equalizer : activeCatalog.classicAssets?.playlist
        guard let name else { return nil }
        return activeCatalog.images[name.lowercased()] ?? activeCatalog.images.first(where: { $0.key.hasSuffix("/\(name.lowercased())") })?.value
    }

    func classicPanelSize(kind: ClassicPanelKind, fallback: CGSize) -> CGSize {
        classicPanelImage(kind: kind)?.size ?? fallback
    }
}

private final class ClassicSkinPanelView: NSView {
    private let background: NSImage?

    init(background: NSImage?) {
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let background else { return }
        background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor
final class ClassicPlaylistSurface: NSView {
    static let defaultSize = CGSize(width: 275, height: 232)

    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    weak var windowHost: WinampSkinWindowHost?
    private var scrollOffset = 0
    private var rowHeight: CGFloat = 13
    private var selectedIndex: Int?
    private var draggingScrollbar = false
    var isActive = true

    override var isFlipped: Bool { true }

    init(coordinator: PlaybackCoordinator, skinStore: SkinLibraryStore) {
        self.coordinator = coordinator
        self.skinStore = skinStore
        super.init(frame: CGRect(origin: .zero, size: Self.defaultSize))
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityRole(.list)
        setAccessibilityLabel("Winamp Playlist")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        let width = bounds.width
        let height = bounds.height
        if windowHost?.isShaded == true {
            _ = drawSprite(source: CGRect(x: 72, y: isActive ? 42 : 57, width: 25, height: 14), in: CGRect(x: 0, y: 0, width: 25, height: 14))
            tile(source: CGRect(x: 72, y: isActive ? 57 : 42, width: 25, height: 14), in: CGRect(x: 25, y: 0, width: max(0, width - 75), height: 14))
            _ = drawSprite(source: CGRect(x: 99, y: isActive ? 42 : 57, width: 50, height: 14), in: CGRect(x: max(25, width - 50), y: 0, width: 50, height: 14))
            return
        }
        let topSourceY: CGFloat = isActive ? 0 : 21
        guard drawSprite(source: CGRect(x: 0, y: topSourceY, width: 25, height: 20), in: CGRect(x: 0, y: 0, width: 25, height: 20)) else {
            NSColor(calibratedWhite: 0.06, alpha: 1).setFill(); bounds.fill(); return
        }
        tile(source: CGRect(x: 127, y: topSourceY, width: 25, height: 20), in: CGRect(x: 25, y: 0, width: max(0, width - 50), height: 20))
        let titleWidth: CGFloat = 100
        _ = drawSprite(source: CGRect(x: 26, y: topSourceY, width: 100, height: 20), in: CGRect(x: (width - titleWidth) / 2, y: 0, width: titleWidth, height: 20))
        _ = drawSprite(source: CGRect(x: 153, y: topSourceY, width: 25, height: 20), in: CGRect(x: max(0, width - 25), y: 0, width: 25, height: 20))

        let bottomHeight: CGFloat = 38
        let middleFrame = CGRect(x: 0, y: 20, width: width, height: max(0, height - 20 - bottomHeight))
        tile(source: CGRect(x: 0, y: 42, width: 12, height: 29), in: CGRect(x: 0, y: middleFrame.minY, width: 12, height: middleFrame.height))
        tile(source: CGRect(x: 31, y: 42, width: 20, height: 29), in: CGRect(x: max(12, width - 20), y: middleFrame.minY, width: 20, height: middleFrame.height))
        drawRows(in: CGRect(x: 12, y: 23, width: max(0, width - 32), height: max(0, middleFrame.height - 6)))

        let bottomY = max(20, height - bottomHeight)
        _ = drawSprite(source: CGRect(x: 0, y: 72, width: 125, height: 38), in: CGRect(x: 0, y: bottomY, width: min(125, width), height: bottomHeight))
        tile(source: CGRect(x: 179, y: 0, width: 25, height: 38), in: CGRect(x: 125, y: bottomY, width: max(0, width - 275), height: bottomHeight))
        _ = drawSprite(source: CGRect(x: 126, y: 72, width: 150, height: 38), in: CGRect(x: max(0, width - 150), y: bottomY, width: min(150, width), height: bottomHeight))
        if width >= 225 { _ = drawSprite(source: CGRect(x: 205, y: 0, width: 75, height: 38), in: CGRect(x: width - 225, y: bottomY, width: 75, height: bottomHeight)) }
        drawScrollbar(in: middleFrame)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 20, point.x >= bounds.width - 50 {
            if point.x >= bounds.width - 12 {
                window?.close()
            } else {
                windowHost?.setShaded(windowHost?.isShaded != true)
            }
            return
        }
        let middleBottom = max(20, bounds.height - 38)
        if windowHost?.isShaded != true, point.x >= bounds.width - 18, point.x < bounds.width - 10,
           point.y >= 20, point.y < middleBottom {
            draggingScrollbar = true
            updateScrollOffset(for: point.y, middleFrame: CGRect(x: 0, y: 20, width: bounds.width, height: max(0, middleBottom - 20)))
            needsDisplay = true
            return
        }
        guard point.y >= 23, point.y < middleBottom, point.x >= 12, point.x < bounds.width - 20 else { return }
        let index = scrollOffset + max(0, Int((point.y - 23) / rowHeight))
        guard coordinator.queue.items.indices.contains(index) else { return }
        selectedIndex = index
        window?.makeFirstResponder(self)
        if event.clickCount > 1 {
            Task { await coordinator.play(items: coordinator.queue.items, startingAt: index) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingScrollbar else { return }
        let point = convert(event.locationInWindow, from: nil)
        let middleBottom = max(20, bounds.height - 38)
        updateScrollOffset(for: point.y, middleFrame: CGRect(x: 0, y: 20, width: bounds.width, height: max(0, middleBottom - 20)))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        draggingScrollbar = false
    }

    override func scrollWheel(with event: NSEvent) {
        let visible = max(1, Int(max(0, bounds.height - 58) / rowHeight))
        let maximum = max(0, coordinator.queue.items.count - visible)
        scrollOffset = min(maximum, max(0, scrollOffset + (event.scrollingDeltaY > 0 ? 3 : -3)))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let items = coordinator.queue.items
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? coordinator.queue.currentIndex ?? 0
        switch event.keyCode {
        case 125: selectedIndex = min(items.count - 1, current + 1)
        case 126: selectedIndex = max(0, current - 1)
        case 36, 76:
            selectedIndex = min(items.count - 1, max(0, current))
            if let selectedIndex { Task { await coordinator.play(items: items, startingAt: selectedIndex) } }
        default:
            super.keyDown(with: event)
            return
        }
        ensureSelectionVisible()
        needsDisplay = true
    }

    private func ensureSelectionVisible() {
        guard let selectedIndex else { return }
        let visible = max(1, Int(max(0, bounds.height - 58) / rowHeight))
        if selectedIndex < scrollOffset { scrollOffset = selectedIndex }
        if selectedIndex >= scrollOffset + visible { scrollOffset = selectedIndex - visible + 1 }
        scrollOffset = min(max(0, coordinator.queue.items.count - visible), max(0, scrollOffset))
    }

    private func updateScrollOffset(for y: CGFloat, middleFrame: CGRect) {
        let visible = max(1, Int(max(0, middleFrame.height - 6) / rowHeight))
        let itemCount = coordinator.queue.items.count
        let thumbHeight = max(18, middleFrame.height * min(1, CGFloat(visible) / CGFloat(max(1, itemCount))))
        let available = max(1, middleFrame.height - thumbHeight)
        let fraction = min(1, max(0, (y - middleFrame.minY - thumbHeight / 2) / available))
        scrollOffset = Int((fraction * CGFloat(max(0, itemCount - visible))).rounded())
    }

    private func drawRows(in frame: CGRect) {
        let items = coordinator.queue.items
        let visibleCount = max(0, Int(frame.height / rowHeight))
        let textColor = playlistTextColor()
        for index in 0..<min(visibleCount, max(0, items.count - scrollOffset)) {
            let itemIndex = index + scrollOffset
            let row = CGRect(x: frame.minX, y: frame.minY + CGFloat(index) * rowHeight, width: frame.width, height: rowHeight)
            if itemIndex == selectedIndex || itemIndex == coordinator.queue.currentIndex {
                NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.45, alpha: 1).setFill(); row.fill()
            }
            let duration = items[itemIndex].duration.map { String(format: "%d:%02d", Int($0.secondsValue) / 60, Int($0.secondsValue) % 60) } ?? ""
            let title = "\(itemIndex + 1). \(items[itemIndex].title)"
            let text = duration.isEmpty ? title : "\(title)  \(duration)"
            text.draw(in: row.insetBy(dx: 2, dy: 0), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: textColor
            ])
        }
    }

    private func drawScrollbar(in frame: CGRect) {
        guard frame.height > 0 else { return }
        let track = CGRect(x: bounds.width - 18, y: frame.minY, width: 8, height: frame.height)
        let itemCount = max(1, coordinator.queue.items.count)
        let visible = max(1, Int(frame.height / rowHeight))
        let thumbHeight = max(18, frame.height * min(1, CGFloat(visible) / CGFloat(itemCount)))
        let available = max(0, frame.height - thumbHeight)
        let ratio = itemCount <= visible ? 0 : CGFloat(scrollOffset) / CGFloat(max(1, itemCount - visible))
        let thumb = CGRect(x: track.minX, y: track.minY + available * ratio, width: 8, height: thumbHeight)
        _ = drawSprite(source: CGRect(x: 52, y: 53, width: 8, height: 18), in: thumb)
    }

    private func playlistTextColor() -> NSColor {
        guard let data = skinStore.activeCatalog.classicPlaylistText,
              let text = String(data: data, encoding: .ascii) else { return .white }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased().contains("text") else { continue }
            let values = parts[1].split { !$0.isNumber }.compactMap { Double($0) }
            if values.count >= 3 { return NSColor(calibratedRed: CGFloat(values[0] / 255), green: CGFloat(values[1] / 255), blue: CGFloat(values[2] / 255), alpha: 1) }
        }
        return .white
    }

    private func tile(source: CGRect, in destination: CGRect) {
        guard destination.width > 0, destination.height > 0 else { return }
        var x = destination.minX
        while x < destination.maxX {
            let width = min(source.width, destination.maxX - x)
            _ = drawSprite(source: CGRect(x: source.minX, y: source.minY, width: width, height: source.height), in: CGRect(x: x, y: destination.minY, width: width, height: destination.height))
            x += source.width
        }
    }

    @discardableResult
    private func drawSprite(source: CGRect, in destination: CGRect) -> Bool {
        guard let image = skinStore.activeCatalog.images["pledit.bmp"] ?? skinStore.activeCatalog.images.first(where: { $0.key.hasSuffix("/pledit.bmp") })?.value,
              source.minX >= 0, source.minY >= 0, source.maxX <= image.size.width, source.maxY <= image.size.height else { return false }
        let flipped = CGRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
        image.draw(in: destination, from: flipped, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        return true
    }
}

private struct SkinPlaylistView: View {
    @Bindable var coordinator: PlaybackCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlist").font(.title2.bold())
                    Text("\(coordinator.queue.items.count) tracks · \(coordinator.activeProviderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()
            if coordinator.queue.items.isEmpty {
                ContentUnavailableView(
                    "Playlist is empty",
                    systemImage: "music.note.list",
                    description: Text("Play a library item or open local files to create a queue.")
                )
            } else {
                List(Array(coordinator.queue.items.enumerated()), id: \.offset) { index, item in
                    Button {
                        Task { await coordinator.play(items: coordinator.queue.items, startingAt: index) }
                    } label: {
                        HStack {
                            Image(systemName: index == coordinator.queue.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.artist ?? item.albumTitle ?? "Unknown artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let duration = item.duration {
                                Text(Self.time(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    private static func time(_ duration: Duration) -> String {
        let seconds = Int(duration.secondsValue)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Native Classic EQ surface. EQMAIN.BMP is a sprite atlas: its first 275x116
/// pixels are the window background, while the remaining strips contain the
/// title, buttons, slider tracks and thumbs. Keep all drawing in logical
/// Winamp pixels and let WinampSkinWindowHost perform the screen conversion.
@MainActor
private final class ClassicEqualizerSurface: NSView {
    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    weak var windowHost: WinampSkinWindowHost?
    var isActive = true
    private let bands = EqualizerBand.winamp10

    override var isFlipped: Bool { true }

    init(coordinator: PlaybackCoordinator, skinStore: SkinLibraryStore) {
        self.coordinator = coordinator
        self.skinStore = skinStore
        super.init(frame: CGRect(x: 0, y: 0, width: 275, height: 116))
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityRole(.group)
        setAccessibilityLabel("Winamp Equalizer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        let shaded = windowHost?.isShaded == true
        if shaded {
            if !drawSprite(asset: "eq_ex.bmp", source: CGRect(x: 0, y: isActive ? 0 : 15, width: 275, height: 14), in: CGRect(x: 0, y: 0, width: 275, height: 14)) {
                _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 0, y: isActive ? 134 : 149, width: 275, height: 14), in: CGRect(x: 0, y: 0, width: 275, height: 14))
            }
            return
        }

        guard drawSprite(asset: "eqmain.bmp", source: CGRect(x: 0, y: 0, width: 275, height: 116), in: CGRect(x: 0, y: 0, width: 275, height: 116)) else {
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            bounds.fill()
            return
        }
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 0, y: isActive ? 134 : 149, width: 275, height: 14), in: CGRect(x: 0, y: 0, width: 275, height: 14))

        let enabled = coordinator.audioEffectState.isEnabled
        let onX: CGFloat = enabled ? 69 : 10
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: onX, y: 119, width: 26, height: 12), in: CGRect(x: 14, y: 18, width: 26, height: 12))
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 36, y: 119, width: 32, height: 12), in: CGRect(x: 40, y: 18, width: 32, height: 12))
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 224, y: 164, width: 44, height: 12), in: CGRect(x: 217, y: 18, width: 44, height: 12))

        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 13, y: 164, width: 209, height: 129), in: CGRect(x: 13, y: 38, width: 209, height: 129))
        drawSliderThumb(gain: coordinator.audioEffectState.preampGain, at: CGPoint(x: 21, y: 38))
        for (index, band) in bands.enumerated() {
            let gain = coordinator.audioEffectState.bandGains[band] ?? 0
            drawSliderThumb(gain: gain, at: CGPoint(x: 78 + CGFloat(index * 18), y: 38))
        }
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 0, y: 294, width: 113, height: 19), in: CGRect(x: 86, y: 17, width: 113, height: 19))
        drawGraph()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 14, point.x >= 264 { window?.close(); return }
        if point.y < 14, point.x >= 254 {
            windowHost?.setShaded(true)
            return
        }
        if point.x >= 14, point.x < 40, point.y >= 18, point.y < 30 {
            Task { await coordinator.setEqualizerEnabled(!coordinator.audioEffectState.isEnabled); needsDisplay = true }
            return
        }
        if point.x >= 40, point.x < 72, point.y >= 18, point.y < 30 {
            Task { await coordinator.resetEqualizer(); needsDisplay = true }
            return
        }
        if point.x >= 217, point.x < 261, point.y >= 18, point.y < 31 {
            if event.modifierFlags.contains(.option) {
                saveEQPreset()
            } else {
                loadEQPreset()
            }
            return
        }
        if point.x >= 21, point.x < 32, point.y >= 38, point.y < 101 {
            let gain = gain(at: point.y)
            Task { await coordinator.setPreampGain(Float(gain)); needsDisplay = true }
            return
        }
        for index in bands.indices {
            let x = 78 + CGFloat(index * 18)
            guard point.x >= x, point.x < x + 11, point.y >= 38, point.y < 101 else { continue }
            let gain = gain(at: point.y)
            Task { await coordinator.setEqualizerBand(index: index, gain: Float(gain)); needsDisplay = true }
            return
        }
    }

    private func gain(at y: CGFloat) -> Double {
        let fraction = max(0, min(1, (y - 38) / 51))
        return 12 - Double(fraction) * 24
    }

    private func drawSliderThumb(gain: Float, at origin: CGPoint) {
        let fraction = max(0, min(1, (Double(gain) + 12) / 24))
        let y = origin.y + CGFloat((1 - fraction) * 51)
        _ = drawSprite(asset: "eqmain.bmp", source: CGRect(x: 0, y: isActive ? 176 : 164, width: 11, height: 11), in: CGRect(x: origin.x, y: y, width: 11, height: 11))
    }

    private func drawGraph() {
        let values = [coordinator.audioEffectState.preampGain] + bands.map { coordinator.audioEffectState.bandGains[$0] ?? 0 }
        guard values.count > 1 else { return }
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let x = 87 + CGFloat(index) * 10
            let y = 26 - CGFloat((Double(value) + 12) / 24 * 15)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
        }
        NSColor(calibratedRed: 0.55, green: 0.9, blue: 0.2, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func loadEQPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let file = try? WinampEQF.decode(data),
              let preset = file.presets.first else { return }
        Task {
            await coordinator.setPreampGain(WinampEQF.gainDB(fromWinamp: preset.preamp))
            for (index, value) in preset.bands.enumerated() {
                await coordinator.setEqualizerBand(index: index, gain: WinampEQF.gainDB(fromWinamp: value))
            }
            needsDisplay = true
        }
    }

    private func saveEQPreset() {
        let state = coordinator.audioEffectState
        let bands = EqualizerBand.winamp10.map { value in
            UInt8(min(63, max(0, Int(((12 - (state.bandGains[value] ?? 0)) / 24 * 63).rounded()))))
        }
        let preamp = UInt8(min(63, max(0, Int(((12 - state.preampGain) / 24 * 63).rounded()))))
        guard let preset = try? WinampEQPreset(name: "Macamp", bands: bands, preamp: preamp),
              let data = try? WinampEQF.encode(WinampEQPresetFile(presets: [preset])) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "macamp.eqf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    private func drawSprite(asset: String, source: CGRect, in destination: CGRect) -> Bool {
        guard let image = skinStore.activeCatalog.images[asset] ?? skinStore.activeCatalog.images.first(where: { $0.key.hasSuffix("/\(asset)") })?.value,
              source.minX >= 0, source.minY >= 0, source.maxX <= image.size.width, source.maxY <= image.size.height else { return false }
        let flipped = CGRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
        image.draw(in: destination, from: flipped, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        return true
    }
}

private struct SkinEqualizerView: View {
    @Bindable var coordinator: PlaybackCoordinator
    private let bands = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer").font(.title2.bold())
                    Text(coordinator.activeProviderName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { Task { await coordinator.resetEqualizer() } }
                    .disabled(!coordinator.audioEffectCapabilities.contains(.equalizerBands))
                Toggle("On", isOn: Binding(
                    get: { coordinator.audioEffectState.isEnabled },
                    set: { value in Task { await coordinator.setEqualizerEnabled(value) } }
                ))
                .disabled(!coordinator.audioEffectCapabilities.contains(.enable))
            }

            HStack(alignment: .bottom, spacing: 9) {
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    VStack(spacing: 6) {
                        Slider(value: Binding(
                            get: {
                                Double(coordinator.audioEffectState.bandGains[EqualizerBand.winamp10[index]] ?? 0)
                            },
                            set: { value in
                                Task { await coordinator.setEqualizerBand(index: index, gain: Float(value)) }
                            }
                        ), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 112)
                            .disabled(!coordinator.audioEffectCapabilities.contains(.equalizerBands))
                        Text(band).font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Label(
                coordinator.audioEffectCapabilities.contains(.equalizerBands)
                    ? "The bands process local-file audio in Macamp."
                    : "Visual only: the active provider does not expose decoded audio for EQ processing.",
                systemImage: coordinator.audioEffectCapabilities.contains(.equalizerBands) ? "checkmark.circle" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// Owns snap policy independently of playback and rendering. Additional classic windows
/// can register here without changing transport code.
@MainActor
final class WindowDockingController {
    var isEnabled = true
    var snapDistance: CGFloat = 10
    private(set) var registeredPanelFrames: [ObjectIdentifier: CGRect] = [:]

    func snappedOrigin(for movingFrame: CGRect, near otherFrames: [CGRect], screen: CGRect, scale: Int) -> CGPoint {
        guard isEnabled else { return movingFrame.origin }
        let threshold = snapDistance * CGFloat(scale)
        var origin = movingFrame.origin
        let candidatesX = otherFrames.flatMap { [$0.minX - movingFrame.width, $0.maxX, $0.minX, $0.maxX - movingFrame.width] } + [screen.minX, screen.maxX - movingFrame.width]
        let candidatesY = otherFrames.flatMap { [$0.minY - movingFrame.height, $0.maxY, $0.minY, $0.maxY - movingFrame.height] } + [screen.minY, screen.maxY - movingFrame.height]
        if let x = candidatesX.min(by: { abs($0 - origin.x) < abs($1 - origin.x) }), abs(x - origin.x) <= threshold { origin.x = x }
        if let y = candidatesY.min(by: { abs($0 - origin.y) < abs($1 - origin.y) }), abs(y - origin.y) <= threshold { origin.y = y }
        return origin
    }

    func update(window: NSWindow) {
        registeredPanelFrames[ObjectIdentifier(window)] = window.frame
    }
}
