import AppKit

@MainActor
protocol SkinArtworkLoader {
    func image(for url: URL) async -> NSImage?
}

@MainActor
final class URLSessionSkinArtworkLoader: SkinArtworkLoader {
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

@MainActor
final class SkinRendererView: NSView {
    static let fallbackLogicalSize = CGSize(width: 275, height: 116)
    override var isFlipped: Bool { true }

    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    private let settings: SettingsStore
    private let openMedia: () -> Void
    private let playlistToggle: () -> Void
    private let equalizerToggle: () -> Void
    private let visualizationToggle: () -> Void
    private let artworkLoader: any SkinArtworkLoader
    var regionPath: NSBezierPath? { skinStore.activeCatalog.regionPath }
    weak var windowHost: WinampSkinWindowHost?
    private var refreshTask: Task<Void, Never>?
    private var makiRuntime: MakiRuntime?
    private var runtimeCatalog: SkinAssetCatalog?
    private var liveScene: WasabiScene
    private var lastMakiPlaybackState: Bool?
    private var pressedControl: SkinControlID?
    private var activeControl: SkinControlDefinition?
    private var hoveredObjectID: String?
    private var balanceValue = 0.5
    private var sceneAnimationTasks: [WasabiHandle: Task<Void, Never>] = [:]
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var remoteArtwork: NSImage?
    private var artworkRequestID = UUID()
    private(set) var scale: Int

    init(
        coordinator: PlaybackCoordinator,
        skinStore: SkinLibraryStore,
        settings: SettingsStore,
        openMedia: @escaping () -> Void,
        playlistToggle: @escaping () -> Void,
        equalizerToggle: @escaping () -> Void,
        visualizationToggle: @escaping () -> Void,
        artworkLoader: any SkinArtworkLoader = URLSessionSkinArtworkLoader()
    ) {
        self.coordinator = coordinator
        self.skinStore = skinStore
        self.settings = settings
        self.openMedia = openMedia
        self.playlistToggle = playlistToggle
        self.equalizerToggle = equalizerToggle
        self.visualizationToggle = visualizationToggle
        self.artworkLoader = artworkLoader
        self.liveScene = skinStore.activeCatalog.scene
        scale = settings.skinScale
        let canvas = skinStore.activeCatalog.canvasSize
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))))
        bounds = CGRect(origin: .zero, size: canvas)
        autoresizingMask = [.width, .height]
        configureMakiRuntimeIfNeeded()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Classic Macamp player")
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.updateMakiPlaybackState()
                self?.updateRemoteArtwork()
                self?.needsDisplay = true
                self?.setAccessibilityValue(self?.coordinator.state.currentItem.map { "\($0.title), \($0.artist ?? "Unknown artist")" } ?? "Nothing playing")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        refreshTask?.cancel()
        artworkTask?.cancel()
        sceneAnimationTasks.values.forEach { $0.cancel() }
    }

    func updateScale(_ value: Int) {
        scale = min(max(value, 1), 4)
        sceneAnimationTasks.values.forEach { $0.cancel() }
        sceneAnimationTasks.removeAll()
        let canvas = skinStore.activeCatalog.canvasSize
        frame.size = CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))
        bounds = CGRect(origin: .zero, size: canvas)
        // The renderer and the borderless host share one logical-pixel
        // coordinate system. Keep the host in lockstep when a skin scale is
        // changed while the window is already live.
        windowHost?.setScale(CGFloat(scale))
        configureMakiRuntimeIfNeeded()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        configureMakiRuntimeIfNeeded()
        NSGraphicsContext.saveGraphicsState()
        if skinStore.activeCatalog.format == .modern {
            drawModernScene()
        } else if let image = skinStore.activeCatalog.mainImage {
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: CGRect(origin: .zero, size: skinStore.activeCatalog.canvasSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        if skinStore.activeCatalog.format == .classic {
            drawClassicChrome()
            drawTransportControls()
            drawClassicMetadata()
            drawClassicVisualization()
        }
        drawMetadata()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if settings.clickThroughTransparentPixels, !isVisible(at: logical(point)) { return nil }
        return self
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = logical(convert(event.locationInWindow, from: nil))
        if skinStore.activeCatalog.format == .classic, point.y < 14 {
            if point.x >= 264 { window?.close(); return }
            if point.x >= 254 {
                windowHost?.setShaded(true)
                return
            }
        }
        let candidates = skinStore.activeCatalog.controls.filter { control in
            if let elementID = control.elementID {
                guard let handle = liveScene.firstHandle(for: elementID) else { return false }
                guard liveScene.effectiveVisible(handle), liveScene.isInActiveLayout(handle) else { return false }
            } else if !control.initiallyVisible { return false }
            return effectiveFrame(for: control).contains(point)
        }
        let object = hitObject(at: point)
        let mouseDownHandled = object.flatMap { makiRuntime?.dispatchMouseDown(objectID: $0.id) } ?? false
        let control = candidates.first(where: { coordinator.state.isPlaying ? $0.action == .pause : $0.action == .play }) ?? candidates.first
        if let control {
            pressedControl = control.id
            activeControl = control
            needsDisplay = true
            let frame = effectiveFrame(for: control)
            Task { await activate(control, point: point, frame: frame) }
        } else {
            if !mouseDownHandled { window?.performDrag(with: event) }
        }
    }

    /// Deterministic logical-coordinate input used by compatibility fixtures.
    /// It enters the same object hit-test and MAKI event path as AppKit input.
    @discardableResult
    func injectMouseDown(at point: CGPoint) -> String? {
        let object = hitObject(at: point)
        _ = object.flatMap { makiRuntime?.dispatchMouseDown(objectID: $0.id) }
        guard let control = skinStore.activeCatalog.controls.first(where: { effectiveFrame(for: $0).contains(point) && isElementVisible($0.elementID, initiallyVisible: $0.initiallyVisible) }) else { return object?.id }
        pressedControl = control.id
        activeControl = control
        Task { await activate(control, point: point, frame: effectiveFrame(for: control)) }
        return object?.id ?? control.elementID
    }

    func injectMouseDrag(at point: CGPoint) {
        guard let control = activeControl, control.orientation != nil else { return }
        if let elementID = control.elementID {
            let frame = effectiveFrame(for: control)
            let value = Int((sliderValueFrom(point, frame: frame, orientation: control.orientation) * 255).rounded())
            _ = makiRuntime?.dispatchSliderPosition(objectID: elementID, value: value, posted: true)
        }
        Task { await activate(control, point: point, frame: effectiveFrame(for: control)) }
    }

    func injectMouseUp(at point: CGPoint) {
        if let object = hitObject(at: point) { _ = makiRuntime?.dispatchMouseUp(objectID: object.id) }
        pressedControl = nil
        activeControl = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let object = hitObject(at: logical(convert(event.locationInWindow, from: nil)))
        if object?.id != hoveredObjectID {
            if let hoveredObjectID { _ = makiRuntime?.dispatchMouseLeave(objectID: hoveredObjectID) }
            if let object { _ = makiRuntime?.dispatchMouseEnter(objectID: object.id) }
            hoveredObjectID = object?.id
        }
    }

    private func drawModernScene() {
        let catalog = skinStore.activeCatalog
        let scene = liveScene
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if WasabiScenePainter.renderNodes(in: scene).isEmpty {
            if let image = catalog.modernBaseImage ?? catalog.mainImage {
                context.interpolationQuality = .none
                image.draw(in: CGRect(origin: .zero, size: catalog.canvasSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
            return
        }

        WasabiScenePainter.paint(scene, in: context) { node in
            let localFrame = CGRect(origin: .zero, size: node.localFrame.size)
            switch node.kind {
            case .layer, .animatedLayer:
                drawSceneLayer(node, in: localFrame)
            case .button, .slider:
                drawSceneControl(node, in: localFrame)
            case .content:
                drawSceneContent(node, in: localFrame)
            case .text, .songTicker:
                drawSceneText(node, in: localFrame)
            case .container, .layout, .group, .unknown:
                break
            }
        }
    }

    private func drawSceneLayer(_ node: WasabiSceneRenderNode, in frame: CGRect) {
        guard let imageID = node.attributes["image"],
              let path = skinStore.activeCatalog.modernBitmapFiles[imageID.lowercased()],
              let image = skinStore.activeCatalog.images[path.lowercased()] else { return }
        let declaredSource = skinStore.activeCatalog.modernBitmapSourceRects[imageID.lowercased()]
        let source: CGRect
        if let declaredSource {
            source = CGRect(
                x: declaredSource.minX,
                y: image.size.height - declaredSource.maxY,
                width: min(declaredSource.width, image.size.width - declaredSource.minX),
                height: min(declaredSource.height, declaredSource.maxY - declaredSource.minY)
            )
        } else if node.kind == .animatedLayer, frame.width > 0, frame.height > 0 {
            source = CGRect(
                x: 0,
                y: max(0, image.size.height - frame.height),
                width: min(image.size.width, frame.width),
                height: min(image.size.height, frame.height)
            )
        } else {
            source = CGRect(origin: .zero, size: image.size)
        }
        image.draw(in: frame, from: source, operation: .sourceOver, fraction: node.alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }

    private func drawSceneControl(_ node: WasabiSceneRenderNode, in frame: CGRect) {
        guard let image = skinStore.activeCatalog.makiControlImages[node.id] else { return }
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: node.alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }

    private func drawSceneContent(_ node: WasabiSceneRenderNode, in frame: CGRect) {
        guard let role = node.attributes["role"] else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        switch role {
        case "albumArt": drawAlbumArt(in: frame)
        case "visualization": drawSimulatedVisualization(in: frame)
        case "playlist": drawPlaylist(in: frame)
        default: break
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSceneText(_ node: WasabiSceneRenderNode, in frame: CGRect) {
        guard let role = node.attributes["role"] else { return }
        let item = coordinator.state.currentItem
        let title = item.map { "\($0.artist ?? "UNKNOWN") - \($0.title)" } ?? "MACAMP — READY"
        let elapsed = Int(coordinator.state.elapsed.secondsValue)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let text: String = switch role {
        case "songTitle": title
        case "elapsedTime": time
        case "remainingTime":
            if let duration = coordinator.state.duration { "-\(formatted(max(0, duration.secondsValue - coordinator.state.elapsed.secondsValue)))" } else { "--:--" }
        case "bitrate": technicalBitrate
        case "frequency": technicalFrequency
        case "channels": technicalChannels
        case "fileExtension": technicalExtension
        default: ""
        }
        guard !text.isEmpty else { return }
        let alignment: NSTextAlignment = switch node.attributes["align"] {
        case "center": .center
        case "right": .right
        default: .left
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        if let fontID = node.attributes["font"],
           !fontID.isEmpty,
           let resource = skinStore.activeCatalog.modernBitmapFonts[fontID.lowercased()],
           let path = skinStore.activeCatalog.modernBitmapFiles[resource.imageID.lowercased()] ?? resource.filePath,
           let image = skinStore.activeCatalog.images[path.lowercased()] {
            ModernBitmapFontPainter.draw(
                text,
                in: frame,
                image: image,
                resource: resource,
                alignment: alignment,
                alpha: node.alpha
            )
            return
        }
        let fontSize = min(max(Double(node.attributes["fontSize"] ?? "9") ?? 9, 5), 36)
        let red = CGFloat(Double(node.attributes["red"] ?? "1") ?? 1)
        let green = CGFloat(Double(node.attributes["green"] ?? "1") ?? 1)
        let blue = CGFloat(Double(node.attributes["blue"] ?? "1") ?? 1)
        text.draw(in: frame, withAttributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(fontSize)),
            .foregroundColor: NSColor(calibratedRed: red, green: green, blue: blue, alpha: node.alpha),
            .paragraphStyle: paragraph
        ])
    }

    private func drawAlbumArt(in frame: CGRect) {
        let artwork = coordinator.state.currentItem?.artwork
        let image: NSImage? = switch artwork {
        case let .embedded(data): NSImage(data: data)
        case let .systemSymbol(name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .remote: remoteArtwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        case nil: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        }
        NSColor(calibratedWhite: 0.03, alpha: 0.65).setFill()
        frame.fill()
        guard let image else { return }
        let imageRatio = image.size.width / max(1, image.size.height)
        let frameRatio = frame.width / max(1, frame.height)
        let destination: CGRect
        if imageRatio > frameRatio {
            let height = frame.width / imageRatio
            destination = CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
        } else {
            let width = frame.height * imageRatio
            destination = CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
        }
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func updateRemoteArtwork() {
        guard case let .remote(url) = coordinator.state.currentItem?.artwork else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkURL = nil
            remoteArtwork = nil
            return
        }
        guard artworkURL != url else { return }
        artworkTask?.cancel()
        artworkURL = url
        remoteArtwork = nil
        let requestID = UUID()
        artworkRequestID = requestID
        artworkTask = Task { [weak self, artworkLoader] in
            let image = await artworkLoader.image(for: url)
            guard !Task.isCancelled else { return }
            self?.setRemoteArtwork(image, for: url, requestID: requestID)
        }
    }

    private func setRemoteArtwork(_ image: NSImage?, for url: URL, requestID: UUID) {
        guard requestID == artworkRequestID, artworkURL == url else { return }
        remoteArtwork = image
        needsDisplay = true
    }

    private func drawSimulatedVisualization(in frame: CGRect) {
        NSColor(calibratedWhite: 0.01, alpha: 0.72).setFill()
        frame.fill()
        let barCount = max(8, min(32, Int(frame.width / 7)))
        let spacing = max(1, frame.width / CGFloat(barCount * 3))
        let barWidth = max(1, (frame.width - spacing * CGFloat(barCount + 1)) / CGFloat(barCount))
        let phase = coordinator.state.elapsed.secondsValue * (coordinator.state.isPlaying ? 2.2 : 0.25)
        for index in 0..<barCount {
            let harmonic = sin(Double(index) * 0.73 + phase) * 0.28 + sin(Double(index) * 0.19 - phase * 0.7) * 0.17
            let level = min(max(0.12 + harmonic + Double(index % 5) * 0.08, 0.06), 0.94)
            let height = frame.height * CGFloat(level)
            NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 0.82).setFill()
            CGRect(
                x: frame.minX + spacing + CGFloat(index) * (barWidth + spacing),
                y: frame.maxY - height,
                width: barWidth,
                height: height
            ).fill()
        }
    }

    private func drawPlaylist(in frame: CGRect) {
        NSColor(calibratedWhite: 0.01, alpha: 0.72).setFill()
        frame.fill()
        let font = NSFont.monospacedSystemFont(ofSize: max(6, min(10, frame.height / 12)), weight: .medium)
        let lineHeight = font.pointSize + 2
        let maximumLines = max(1, Int((frame.height - 6) / lineHeight))
        let current = coordinator.queue.currentIndex ?? 0
        let start = max(0, min(current - maximumLines / 2, max(0, coordinator.queue.items.count - maximumLines)))
        for (offset, item) in coordinator.queue.items.dropFirst(start).prefix(maximumLines).enumerated() {
            let index = start + offset
            let color = index == current ? NSColor.white : NSColor(calibratedRed: 0.35, green: 1, blue: 0.45, alpha: 1)
            let title = "\(index + 1). \(item.artist.map { "\($0) - " } ?? "")\(item.title)"
            title.draw(
                in: CGRect(x: frame.minX + 4, y: frame.minY + 3 + CGFloat(offset) * lineHeight, width: frame.width - 8, height: lineHeight),
                withAttributes: [.font: font, .foregroundColor: color]
            )
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let control = activeControl, control.orientation != nil else { return }
        let point = logical(convert(event.locationInWindow, from: nil))
        let frame = effectiveFrame(for: control)
        if let elementID = control.elementID {
            let value = Int((sliderValueFrom(point, frame: frame, orientation: control.orientation) * 255).rounded())
            _ = makiRuntime?.dispatchSliderPosition(objectID: elementID, value: value, posted: true)
        }
        Task { await activate(control, point: point, frame: frame) }
    }

    override func mouseUp(with event: NSEvent) {
        if let object = hitObject(at: logical(convert(event.locationInWindow, from: nil))) {
            _ = makiRuntime?.dispatchMouseUp(objectID: object.id)
            if object.kind == .slider { _ = makiRuntime?.dispatchSliderPosition(objectID: object.id, value: 0, final: true) }
        }
        pressedControl = nil
        activeControl = nil
        needsDisplay = true
    }

    private func activate(_ control: SkinControlDefinition, point: CGPoint, frame: CGRect) async {
        switch control.action {
        case .previous: await coordinator.previous()
        case .play: await coordinator.play()
        case .pause: await coordinator.pause()
        case .stop: await coordinator.stop()
        case .next: await coordinator.next()
        case .open: openMedia()
        case .seek:
            let fraction = (point.x - frame.minX) / frame.width
            if let duration = coordinator.state.duration { await coordinator.seek(to: .seconds(duration.secondsValue * fraction)) }
        case .setVolume:
            await coordinator.setVolume(horizontalFraction(point, frame: frame))
        case .setBalance:
            balanceValue = horizontalFraction(point, frame: frame)
            needsDisplay = true
        case .setEqualizerBand:
            guard let parameter = control.parameter else { break }
            let fraction = min(max((point.y - frame.minY) / max(1, frame.height), 0), 1)
            await coordinator.setEqualizerBand(index: max(0, parameter - 1), gain: Float(12 - fraction * 24))
            needsDisplay = true
        case .resetEqualizer:
            await coordinator.resetEqualizer()
            needsDisplay = true
        case .toggleShuffle: await coordinator.setShuffle(coordinator.state.shuffleMode == .off ? .songs : .off)
        case .cycleRepeat:
            let next: RepeatMode = switch coordinator.state.repeatMode { case .off: .all; case .all: .one; case .one: .off }
            await coordinator.setRepeat(next)
        case .togglePlaylist:
            playlistToggle()
        case .toggleEqualizer:
            equalizerToggle()
        case .toggleVisualization: visualizationToggle()
        case .close: window?.close()
        case .minimize: window?.miniaturize(nil)
        case .windowshade: break
        case .none, .scripted: break
        }
        // Declarative behavior and MAKI are both part of a Winamp Button's
        // lifecycle. A handled script event must not swallow the XML action.
        if let elementID = control.elementID { _ = makiRuntime?.dispatchClick(objectID: elementID) }
    }

    private func drawTransportControls() {
        for control in skinStore.activeCatalog.controls where control.id != .seek && control.id != .volume && control.id != .balance && control.id != .visualization {
            let pressed = pressedControl == control.id
            if let sprite = classicSprite(for: control, pressed: pressed),
               drawClassicSprite(sprite, in: control.frame) { continue }
            let enabled = capability(for: control.action).map(coordinator.capabilities.contains) ?? true
            let color = enabled ? NSColor(calibratedWhite: pressed ? 0.22 : 0.14, alpha: 0.92) : NSColor(calibratedWhite: 0.1, alpha: 0.5)
            color.setFill(); control.frame.fill()
            NSColor.disabledControlTextColor.setStroke(); NSBezierPath(rect: control.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        let progress = coordinator.state.duration.map { max(0, min(1, coordinator.state.elapsed.secondsValue / max(0.001, $0.secondsValue))) } ?? 0
        let volume = coordinator.capabilities.contains(.applicationVolume) ? coordinator.state.volume : 0
        if let seek = ClassicSpriteCatalog.seekPlacement(progress: progress, pressed: pressedControl == .seek) {
            _ = drawClassicSprite(seek.track, in: ClassicSpriteCatalog.main[.seek]?.frame ?? .zero)
            _ = drawClassicSprite(seek.thumb, in: seek.thumbFrame)
        }
        if let volume = ClassicSpriteCatalog.volumePlacement(value: volume, pressed: pressedControl == .volume) {
            _ = drawClassicSprite(volume.track, in: ClassicSpriteCatalog.main[.volume]?.frame ?? .zero)
            _ = drawClassicSprite(volume.thumb, in: volume.thumbFrame)
        }
        if let balance = ClassicSpriteCatalog.balancePlacement(value: balanceValue, pressed: pressedControl == .balance) {
            _ = drawClassicSprite(balance.track, in: ClassicSpriteCatalog.main[.balance]?.frame ?? .zero)
            _ = drawClassicSprite(balance.thumb, in: balance.thumbFrame)
        }
    }

    private func classicSprite(for control: SkinControlDefinition, pressed: Bool) -> SpriteReference? {
        if pressed { return control.pressedSprite ?? control.normalSprite }
        switch control.id {
        case .shuffle:
            return coordinator.state.shuffleMode == .off ? control.normalSprite : ClassicSpriteCatalog.main[.shuffle]?.active
        case .repeat:
            return coordinator.state.repeatMode == .off ? control.normalSprite : ClassicSpriteCatalog.main[.repeat]?.active
        default:
            return control.normalSprite
        }
    }

    private func drawClassicChrome() {
        let titleBar: SpriteReference
        if windowHost?.isShaded == true {
            titleBar = (window?.isKeyWindow ?? true) ? ClassicSpriteCatalog.activeShadeTitleBar : ClassicSpriteCatalog.inactiveShadeTitleBar
        } else {
            titleBar = (window?.isKeyWindow ?? true) ? ClassicSpriteCatalog.activeTitleBar : ClassicSpriteCatalog.inactiveTitleBar
        }
        _ = drawClassicSprite(titleBar, in: CGRect(x: 0, y: 0, width: 275, height: 14))
    }

    private func drawClassicSprite(_ sprite: SpriteReference, in frame: CGRect) -> Bool {
        guard skinStore.activeCatalog.format == .classic,
              let image = skinStore.activeCatalog.images[sprite.assetName.lowercased()] ?? skinStore.activeCatalog.images.first(where: { $0.key.hasSuffix("/\(sprite.assetName.lowercased())") })?.value else { return false }
        let source = sprite.sourceRect
        guard !source.isEmpty else { return false }
        let flippedSource = CGRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
        image.draw(in: frame, from: flippedSource, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return true
    }

    private func drawMetadata() {
        let item = coordinator.state.currentItem
        let title = item.map { "\($0.artist ?? "UNKNOWN") - \($0.title)" } ?? "MACAMP — READY"
        let elapsed = Int(coordinator.state.elapsed.secondsValue)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium), .foregroundColor: NSColor.systemGreen]
        if skinStore.activeCatalog.format == .modern,
           WasabiScenePainter.renderNodes(in: liveScene).contains(where: { $0.kind == .text || $0.kind == .songTicker }) { return }
        if skinStore.activeCatalog.format == .classic {
            // Classic metadata is painted by drawClassicMetadata after the
            // titlebar and before the Modern text path reaches this branch.
        } else {
            for region in skinStore.activeCatalog.textRegions {
                guard isElementVisible(region.elementID, initiallyVisible: region.initiallyVisible) else { continue }
                let frame = effectiveFrame(for: region)
                let fallbackText: String = switch region.role {
                case .songTitle: title
                case .elapsedTime: time
                case .remainingTime:
                    if let duration = coordinator.state.duration {
                        "-\(formatted(max(0, duration.secondsValue - coordinator.state.elapsed.secondsValue)))"
                    } else { "--:--" }
                case .bitrate: technicalBitrate
                case .frequency: technicalFrequency
                case .channels: technicalChannels
                case .fileExtension: technicalExtension
                }
                let text = region.elementID.flatMap { objectID in
                    makiRuntime?.text(objectID: objectID).flatMap { $0.isEmpty ? nil : $0 }
                } ?? fallbackText
                let alignment: NSTextAlignment = switch region.alignment {
                case "center": .center
                case "right": .right
                default: .left
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                text.draw(
                    in: frame,
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: CGFloat(min(max(region.fontSize, 5), 36))),
                        .foregroundColor: NSColor(calibratedRed: CGFloat(region.red), green: CGFloat(region.green), blue: CGFloat(region.blue), alpha: 1),
                        .paragraphStyle: paragraph
                    ]
                )
            }
        }
    }

    private func drawClassicMetadata() {
        let item = coordinator.state.currentItem
        let title = item.map { "\($0.artist ?? "UNKNOWN") - \($0.title)" } ?? "MACAMP — READY"
        let elapsed = Int(coordinator.state.elapsed.secondsValue)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let titleFrame = CGRect(x: 110, y: 27, width: 155, height: 9)
        if !drawClassicText(title, in: titleFrame, alignment: .center) {
            String(title.prefix(31)).draw(at: CGPoint(x: titleFrame.minX, y: titleFrame.minY), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: NSColor.systemGreen
            ])
        }
        if !drawClassicTime(time, in: CGRect(x: 33, y: 24, width: 70, height: 18)) {
            time.draw(at: CGPoint(x: 40, y: 24), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.systemGreen
            ])
        }
        if !drawClassicText(technicalBitrate, in: CGRect(x: 109, y: 43, width: 17, height: 9), alignment: .left) {
            drawClassicTechnicalValue(technicalBitrate, in: CGRect(x: 109, y: 43, width: 17, height: 9))
        }
        if !drawClassicText(technicalFrequency, in: CGRect(x: 154, y: 43, width: 12, height: 9), alignment: .left) {
            drawClassicTechnicalValue(technicalFrequency, in: CGRect(x: 154, y: 43, width: 12, height: 9))
        }
        let statusSprite: SpriteReference = switch coordinator.state.status {
        case .playing: ClassicSpriteCatalog.playStatus
        case .paused: ClassicSpriteCatalog.pauseStatus
        case .connecting, .buffering: ClassicSpriteCatalog.workingStatus
        case .failed, .interrupted: ClassicSpriteCatalog.failedStatus
        default: ClassicSpriteCatalog.stoppedStatus
        }
        _ = drawClassicSprite(statusSprite, in: CGRect(x: 26, y: 28, width: statusSprite.sourceRect.width, height: statusSprite.sourceRect.height))

        let channels = coordinator.state.currentItem?.channelCount ?? 0
        _ = drawClassicSprite(channels == 1 ? ClassicSpriteCatalog.monoActive : ClassicSpriteCatalog.monoInactive, in: CGRect(x: 212, y: 41, width: 27, height: 12))
        _ = drawClassicSprite(channels > 1 ? ClassicSpriteCatalog.stereoActive : ClassicSpriteCatalog.stereoInactive, in: CGRect(x: 239, y: 41, width: 29, height: 12))
    }

    private func drawClassicText(_ value: String, in frame: CGRect, alignment: NSTextAlignment) -> Bool {
        guard skinStore.activeCatalog.images.keys.contains(where: { $0.hasSuffix("/text.bmp") || $0 == "text.bmp" }) else { return false }
        let characters = Array(value)
        let maximumCount = max(0, Int(frame.width / 5))
        let shown = Array(characters.prefix(maximumCount))
        let width = CGFloat(shown.count * 5)
        let startX: CGFloat = switch alignment {
        case .center: frame.midX - width / 2
        case .right: frame.maxX - width
        default: frame.minX
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        for (index, character) in shown.enumerated() {
            guard let sprite = ClassicSpriteCatalog.textSprite(for: character) else { continue }
            _ = drawClassicSprite(sprite, in: CGRect(x: startX + CGFloat(index * 5), y: frame.minY, width: 5, height: 6))
        }
        NSGraphicsContext.restoreGraphicsState()
        return true
    }

    private func drawClassicTime(_ value: String, in frame: CGRect) -> Bool {
        let sheet: ClassicSpriteSheet
        if skinStore.activeCatalog.images.keys.contains(where: { $0.hasSuffix("/nums_ex.bmp") || $0 == "nums_ex.bmp" }) {
            sheet = .numsExtra
        } else if skinStore.activeCatalog.images.keys.contains(where: { $0.hasSuffix("/numbers.bmp") || $0 == "numbers.bmp" }) {
            sheet = .numbers
        } else {
            return false
        }
        let characters = Array(value)
        let glyphWidth: CGFloat = 9
        let spacing: CGFloat = 3
        let totalWidth = CGFloat(characters.count) * glyphWidth + CGFloat(max(0, characters.count - 1)) * spacing
        var x = frame.maxX - totalWidth
        for character in characters {
            if let sprite = ClassicSpriteCatalog.bigNumberSprite(for: character, sheet: sheet) {
                _ = drawClassicSprite(sprite, in: CGRect(x: x, y: frame.minY + 1, width: glyphWidth, height: 13))
            } else if let sprite = ClassicSpriteCatalog.textSprite(for: character), character == ":" {
                guard skinStore.activeCatalog.images.keys.contains(where: { $0.hasSuffix("/text.bmp") || $0 == "text.bmp" }) else { return false }
                _ = drawClassicSprite(sprite, in: CGRect(x: x + 2, y: frame.minY + 4, width: 5, height: 6))
            } else {
                return false
            }
            x += glyphWidth + spacing
        }
        return true
    }

    private func drawClassicVisualization() {
        let frame = CGRect(x: 24, y: 43, width: 72, height: 16)
        let palette = skinStore.activeCatalog.classicVisualizationPalette
        let colors: [NSColor]
        if let palette {
            colors = palette.spectrum.map { NSColor(calibratedRed: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1) }
            NSColor(calibratedRed: CGFloat(palette.background.red) / 255, green: CGFloat(palette.background.green) / 255, blue: CGFloat(palette.background.blue) / 255, alpha: 1).setFill()
            frame.fill()
        } else {
            colors = [NSColor.systemGreen]
        }
        let barCount = 12
        let spacing = CGFloat(2)
        let barWidth = max(1, (frame.width - spacing * CGFloat(barCount + 1)) / CGFloat(barCount))
        let phase = coordinator.state.elapsed.secondsValue * (coordinator.state.isPlaying ? 2.2 : 0.25)
        for index in 0..<barCount {
            let harmonic = sin(Double(index) * 0.73 + phase) * 0.28 + sin(Double(index) * 0.19 - phase * 0.7) * 0.17
            let level = min(max(0.12 + harmonic + Double(index % 5) * 0.08, 0.06), 0.94)
            let height = frame.height * CGFloat(level)
            colors[index % max(1, colors.count)].setFill()
            CGRect(x: frame.minX + spacing + CGFloat(index) * (barWidth + spacing), y: frame.maxY - height, width: barWidth, height: height).fill()
        }
    }

    private func formatted(_ seconds: Double) -> String {
        let value = Int(seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var technicalBitrate: String {
        coordinator.state.currentItem?.bitrateKbps.map(String.init) ?? "--"
    }

    private var technicalFrequency: String {
        guard let sampleRate = coordinator.state.currentItem?.sampleRateHz else { return "--" }
        let khz = Double(sampleRate) / 1_000
        return khz.rounded() == khz ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
    }

    private var technicalChannels: String {
        coordinator.state.currentItem?.channelCount.map(String.init) ?? "--"
    }

    private var technicalExtension: String {
        coordinator.state.currentItem?.fileExtension?.uppercased() ?? "--"
    }

    private func drawClassicTechnicalValue(_ value: String, in frame: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        value.draw(
            in: frame,
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 6, weight: .medium),
                .foregroundColor: NSColor.systemGreen,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func logical(_ point: CGPoint) -> CGPoint { point }
    private func isVisible(at point: CGPoint) -> Bool {
        if let region = skinStore.activeCatalog.regionPath, !region.contains(point) { return false }
        if skinStore.activeCatalog.format == .modern, liveScene.hitTest(point) != nil { return true }
        if skinStore.activeCatalog.contentRegions.contains(where: { $0.frame.contains(point) }) { return true }
        if skinStore.activeCatalog.modernWindowUsesBitmapAlpha {
            return isOpaquePixel(at: point)
        }
        if skinStore.activeCatalog.regionPath != nil { return true }
        return isOpaquePixel(at: point)
    }

    private func isOpaquePixel(at point: CGPoint) -> Bool {
        guard let image = skinStore.activeCatalog.mainImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return true }
        let canvas = skinStore.activeCatalog.canvasSize
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / max(1, canvas.width))
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / max(1, canvas.height))
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return false }
        return (bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)?.alphaComponent ?? 1) > 0.08
    }

    private func effectiveFrame(for control: SkinControlDefinition) -> CGRect {
        effectiveFrame(control.frame, elementID: control.elementID)
    }

    private func effectiveFrame(for layer: ModernSkinLayer) -> CGRect? {
        effectiveFrame(layer.frame, elementID: layer.elementID)
    }

    private func effectiveFrame(for region: ModernSkinContentRegion) -> CGRect {
        effectiveFrame(region.frame, elementID: region.elementID)
    }

    private func effectiveFrame(for region: ModernSkinTextRegion) -> CGRect {
        effectiveFrame(region.frame, elementID: region.elementID)
    }

    private func effectiveFrame(_ frame: CGRect, elementID: String?) -> CGRect {
        guard let elementID else { return frame }
        if skinStore.activeCatalog.format == .modern,
           let handle = liveScene.firstHandle(for: elementID),
           let sceneFrame = liveScene.worldFrame(of: handle) {
            return sceneFrame
        }
        guard skinStore.activeCatalog.format != .modern else { return frame }
        var result = frame
        if let value = runtimeNumber(elementID, "x") { result.origin.x = value }
        if let value = runtimeNumber(elementID, "y") { result.origin.y = value }
        if let value = runtimeNumber(elementID, "w"), value > 0 { result.size.width = value }
        if let value = runtimeNumber(elementID, "h"), value > 0 { result.size.height = value }
        return result
    }

    private func hitObject(at point: CGPoint) -> WasabiObjectNode? {
        if skinStore.activeCatalog.format == .modern,
           let sceneNode = liveScene.hitTest(point),
           let worldFrame = liveScene.worldFrame(of: sceneNode.handle) {
            return WasabiObjectNode(
                id: sceneNode.id,
                kind: sceneNode.kind,
                frame: worldFrame,
                parentID: nil,
                initiallyVisible: true,
                attributes: sceneNode.attributes,
                zIndex: sceneNode.zIndex
            )
        }
        // Compatibility fallback for hand-built descriptors that predate the
        // live scene, and for Classic callers.
        let tree = skinStore.activeCatalog.objectTree
        let candidates = tree.nodes.values.filter { node in
            guard node.kind != .container, node.kind != .layout, node.kind != .group else { return false }
            guard isElementVisible(node.id, initiallyVisible: node.initiallyVisible) else { return false }
            return effectiveFrame(node.frame, elementID: node.id).contains(point)
        }
        return candidates.sorted { $0.zIndex > $1.zIndex }.first
    }

    private func sliderValueFrom(_ point: CGPoint, frame: CGRect, orientation: SkinControlOrientation?) -> Double {
        switch orientation {
        case .vertical: return min(max((point.y - frame.minY) / max(1, frame.height), 0), 1)
        case .horizontal, nil: return horizontalFraction(point, frame: frame)
        }
    }

    private func runtimeNumber(_ objectID: String, _ name: String) -> CGFloat? {
        guard let value = makiRuntime?.xmlParameter(objectID: objectID, name: name) else { return nil }
        return Double(value).map { CGFloat($0) }
    }

    private func isElementVisible(_ objectID: String?, initiallyVisible: Bool) -> Bool {
        guard let objectID else { return initiallyVisible }
        if let value = makiRuntime?.isVisible(objectID: objectID) { return value }
        if let value = runtimeNumber(objectID, "visible") { return value > 0 }
        if let value = runtimeNumber(objectID, "alpha") { return value > 0 }
        return initiallyVisible
    }

    private func sliderValue(for control: SkinControlDefinition) -> Double {
        switch control.action {
        case .seek:
            return coordinator.state.duration.map {
                min(max(coordinator.state.elapsed.secondsValue / max(0.001, $0.secondsValue), 0), 1)
            } ?? 0
        case .setVolume:
            return coordinator.state.volume
        case .setBalance:
            return balanceValue
        case .setEqualizerBand:
            guard let parameter = control.parameter,
                  EqualizerBand.winamp10.indices.contains(parameter - 1) else { return 0.5 }
            let gain = coordinator.audioEffectState.bandGains[EqualizerBand.winamp10[parameter - 1]] ?? 0
            return Double((12 - gain) / 24)
        default:
            return 0.5
        }
    }

    private func horizontalFraction(_ point: CGPoint, frame: CGRect) -> Double {
        min(max((point.x - frame.minX) / max(1, frame.width), 0), 1)
    }

    var metadataStringsForTesting: [String] {
        let item = coordinator.state.currentItem
        let title = item.map { "\($0.artist ?? "UNKNOWN") - \($0.title)" } ?? "MACAMP — READY"
        let elapsed = Int(coordinator.state.elapsed.secondsValue)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let remaining: String
        if let duration = coordinator.state.duration {
            remaining = "-\(formatted(max(0, duration.secondsValue - coordinator.state.elapsed.secondsValue)))"
        } else {
            remaining = "--:--"
        }
        return [title, time, remaining, technicalBitrate, technicalFrequency]
    }

    var liveSceneForTesting: WasabiScene { liveScene }

    private func updateMakiPlaybackState() {
        let current = coordinator.state.isPlaying
        defer { lastMakiPlaybackState = current }
        guard let previous = lastMakiPlaybackState, previous != current else { return }
        makiRuntime?.dispatchSystemEvent(current ? "onPlay" : "onPause")
    }

    private func configureMakiRuntimeIfNeeded() {
        let catalog = skinStore.activeCatalog
        guard runtimeCatalog !== catalog else { return }
        runtimeCatalog = catalog
        liveScene = catalog.scene
        makiRuntime = nil
        lastMakiPlaybackState = nil
        sceneAnimationTasks.values.forEach { $0.cancel() }
        sceneAnimationTasks.removeAll()
        guard !catalog.makiPrograms.isEmpty else { return }
        makiRuntime = MakiRuntime(programs: catalog.makiPrograms, bindings: catalog.makiBindings, host: self, limits: .init(), skinID: catalog.name, persistentState: .standard, scene: liveScene)
        makiRuntime?.start()
    }

    private func capability(for action: SkinAction) -> PlaybackCapabilities? {
        switch action { case .play: .playback; case .pause: .pause; case .stop: .explicitStop; case .previous: .previous; case .next: .next; case .seek: .seek; case .setVolume: .applicationVolume; case .toggleShuffle: .shuffle; case .cycleRepeat: .repeat; default: nil }
    }
}

extension SkinRendererView: MakiRuntimeHost {
    func makiPlaybackStatus() -> Int { coordinator.state.isPlaying ? 1 : 0 }

    func makiXMLParameter(objectID: String, name: String) -> String? {
        guard let handle = liveScene.firstHandle(for: objectID),
              let node = liveScene.node(handle) else { return nil }
        switch name.lowercased() {
        case "x": return String(Double(node.localFrame.minX))
        case "y": return String(Double(node.localFrame.minY))
        case "w", "width": return String(Double(node.localFrame.width))
        case "h", "height": return String(Double(node.localFrame.height))
        case "alpha": return String(Double(liveScene.effectiveAlpha(handle)))
        case "visible": return liveScene.effectiveVisible(handle) ? "1" : "0"
        default: return nil
        }
    }

    func makiVisibilityChanged(objectID: String, isVisible: Bool) {
        if let handle = liveScene.firstHandle(for: objectID) {
            liveScene.setVisible(isVisible, for: handle)
        }
        needsDisplay = true
    }

    func makiTargetChanged(objectID: String, x: Double, speed: Double) {
        makiTargetGeometryChanged(objectID: objectID, x: x, y: nil, width: nil, height: nil, alpha: nil, speed: speed)
    }

    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
        guard let handle = liveScene.firstHandle(for: objectID),
              let node = liveScene.node(handle) else { return }
        var target = node.localFrame
        if let x { target.origin.x = x }
        if let y { target.origin.y = y }
        if let width, width > 0 { target.size.width = width }
        if let height, height > 0 { target.size.height = height }
        let start = node.localFrame
        let duration = min(max(speed, 0.05), 2)
        let started = Date.timeIntervalSinceReferenceDate
        sceneAnimationTasks[handle]?.cancel()
        sceneAnimationTasks[handle] = Task { [weak self] in
            let frameCount = max(1, Int(ceil(duration / 0.016)) + 1)
            for _ in 0..<frameCount {
                guard !Task.isCancelled else { return }
                let progress = min(max((Date.timeIntervalSinceReferenceDate - started) / duration, 0), 1)
                let eased = progress * progress * (3 - 2 * progress)
                var frame = start
                frame.origin.x += (target.origin.x - start.origin.x) * CGFloat(eased)
                frame.origin.y += (target.origin.y - start.origin.y) * CGFloat(eased)
                frame.size.width += (target.width - start.width) * CGFloat(eased)
                frame.size.height += (target.height - start.height) * CGFloat(eased)
                self?.liveScene.setLocalFrame(frame, for: handle)
                if let alpha { self?.liveScene.setAlpha(CGFloat(alpha > 1 ? alpha / 255 : alpha), for: handle) }
                self?.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.liveScene.setLocalFrame(target, for: handle)
            if let alpha { self?.liveScene.setAlpha(CGFloat(alpha > 1 ? alpha / 255 : alpha), for: handle) }
            self?.sceneAnimationTasks.removeValue(forKey: handle)
            self?.needsDisplay = true
            self?.makiTargetReached(objectID: objectID)
        }
    }

    func makiLayoutSwitched(containerID: String, layoutID: String) {
        guard let container = liveScene.firstHandle(for: containerID),
              let layout = liveScene.layoutHandle(id: layoutID, in: container) else {
            makiRuntime?.recordExternalDiagnostic("Unsupported layout \(layoutID) requested by \(containerID).")
            return
        }
        liveScene.setActiveLayout(layout, for: container)
        if let size = liveScene.node(layout)?.localFrame.size {
            windowHost?.resizeLogicalWindow(to: size)
        }
        needsDisplay = true
    }

    func makiLayoutResized(objectID: String, frame: CGRect) {
        guard frame.width > 0, frame.height > 0, frame.width <= 2_048, frame.height <= 2_048 else {
            makiRuntime?.recordExternalDiagnostic("Rejected unsafe layout resize for \(objectID).")
            return
        }
        guard let handle = liveScene.firstHandle(for: objectID),
              let node = liveScene.node(handle), node.kind == .layout || node.kind == .container else { return }
        liveScene.setLocalFrame(frame, for: handle)
        windowHost?.resizeLogicalWindow(to: frame.size)
        needsDisplay = true
    }

    func makiRedock(objectID: String, before: Bool) {
        if before { windowHost?.beforeRedock() } else { windowHost?.redock() }
        needsDisplay = true
    }

    func makiVolumeChanged(_ value: Double) {
        Task { await coordinator.setVolume(min(max(value, 0), 1)) }
    }

    func makiEQBandChanged(index: Int, value: Int) {
        let normalizedIndex = EqualizerBand.winamp10.indices.contains(index) ? index : index - 1
        guard EqualizerBand.winamp10.indices.contains(normalizedIndex) else { return }
        let gain = Float(12 - Double(min(max(value, 0), 255)) / 255 * 24)
        Task { await coordinator.setEqualizerBand(index: normalizedIndex, gain: gain) }
    }

    func makiEQBandValue(index: Int) -> Int {
        let normalizedIndex = EqualizerBand.winamp10.indices.contains(index) ? index : index - 1
        guard EqualizerBand.winamp10.indices.contains(normalizedIndex),
              let gain = coordinator.audioEffectState.bandGains[EqualizerBand.winamp10[normalizedIndex]] else { return 128 }
        return Int(((Double(gain) + 12) / 24 * 255).rounded())
    }

    func makiEQPreampValue() -> Int {
        Int(((Double(coordinator.audioEffectState.preampGain) + 12) / 24 * 255).rounded())
    }

    func makiEQEnabled() -> Bool { coordinator.audioEffectState.isEnabled }

    func makiEQEnabledChanged(_ enabled: Bool) { Task { await coordinator.setEqualizerEnabled(enabled) } }

    func makiEQPreampChanged(value: Int) {
        let gain = Float(Double(min(max(value, 0), 255)) / 255 * 24 - 12)
        Task { await coordinator.setPreampGain(gain) }
    }

    func makiRuntimeNeedsDisplay() { needsDisplay = true }

    func makiPlaybackItem() -> PlaybackItem? { coordinator.state.currentItem }
    func makiElapsed() -> Duration { coordinator.state.elapsed }
    func makiDuration() -> Duration? { coordinator.state.duration }
    func makiText(objectID: String) -> String? { makiRuntime?.text(objectID: objectID) }
    func makiSetText(objectID: String, text: String) { needsDisplay = true }
    func makiTargetReached(objectID: String) { makiRuntime?.targetReached(objectID: objectID) }
}
