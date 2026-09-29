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
    private var refreshTask: Task<Void, Never>?
    private var makiRuntime: MakiRuntime?
    private var runtimeCatalog: SkinAssetCatalog?
    private var lastMakiPlaybackState: Bool?
    private var drawerAnimationTasks: [ModernDrawerRole: Task<Void, Never>] = [:]
    private var pressedControl: SkinControlID?
    private var activeControl: SkinControlDefinition?
    private var hoveredObjectID: String?
    private var balanceValue = 0.5
    private var drawerTargets: [ModernDrawerRole: Double] = [.left: 1, .right: 1]
    private var drawerAnimations: [ModernDrawerRole: DrawerAnimation] = [:]
    private var drawerAnimationTargets: [ModernDrawerRole: String] = [:]
    private var genericAnimationTasks: [String: Task<Void, Never>] = [:]
    private var genericFrames: [String: CGRect] = [:]
    private var genericAlphas: [String: CGFloat] = [:]
    private var activeLayoutID: String?
    private var redockSuspended = false
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var remoteArtwork: NSImage?
    private var artworkRequestID = UUID()
    private(set) var scale: Int

    private struct DrawerAnimation {
        var from: Double
        var to: Double
        var startedAt: TimeInterval
        var duration: TimeInterval
    }

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
        scale = settings.skinScale
        let canvas = skinStore.activeCatalog.canvasSize
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))))
        bounds = CGRect(origin: .zero, size: canvas)
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
        drawerAnimationTasks.values.forEach { $0.cancel() }
        genericAnimationTasks.values.forEach { $0.cancel() }
    }

    func updateScale(_ value: Int) {
        scale = min(max(value, 1), 4)
        drawerAnimationTasks.values.forEach { $0.cancel() }
        drawerAnimationTasks.removeAll()
        drawerAnimations.removeAll()
        genericAnimationTasks.values.forEach { $0.cancel() }
        genericAnimationTasks.removeAll()
        genericFrames.removeAll()
        genericAlphas.removeAll()
        activeLayoutID = skinStore.activeCatalog.modernLayouts.first(where: { $0.initiallyVisible })?.id
        redockSuspended = false
        let initialProgress = skinStore.activeCatalog.makiPrograms.isEmpty ? 1.0 : 0.0
        drawerTargets = [.left: initialProgress, .right: initialProgress]
        let canvas = skinStore.activeCatalog.canvasSize
        frame.size = CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))
        bounds = CGRect(origin: .zero, size: canvas)
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
        if skinStore.activeCatalog.format == .classic { drawTransportControls() }
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
        if skinStore.activeCatalog.format == .classic, point.x > 263, point.y < 13 { window?.close(); return }
        let candidates = skinStore.activeCatalog.controls.filter { control in
            if let role = control.drawerRole, drawerProgress(for: role) <= 0.001 { return false }
            if let elementID = control.elementID {
                let scriptedVisibility = makiRuntime?.isVisible(objectID: elementID)
                if scriptedVisibility == false || scriptedVisibility == nil && !control.initiallyVisible { return false }
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

    private func drawModernLayers(drawerRole: ModernDrawerRole?) {
        for layer in skinStore.activeCatalog.modernLayers where layer.drawerRole == drawerRole && layer.elementID != nil {
            guard isElementVisible(layer.elementID, initiallyVisible: layer.initiallyVisible),
                  let path = skinStore.activeCatalog.modernBitmapFiles[layer.imageID.lowercased()],
                  let image = skinStore.activeCatalog.images[path.lowercased()] else { continue }
            guard var logicalFrame = effectiveFrame(for: layer) else { continue }
            let declaredSource = skinStore.activeCatalog.modernBitmapSourceRects[layer.imageID.lowercased()]
            if logicalFrame.width <= 0 { logicalFrame.size.width = declaredSource?.width ?? image.size.width }
            if logicalFrame.height <= 0 { logicalFrame.size.height = declaredSource?.height ?? image.size.height }
            guard logicalFrame.width > 0, logicalFrame.height > 0 else { continue }
            let frame = translated(logicalFrame, for: drawerRole)
            let source = if let declaredSource {
                CGRect(
                    x: declaredSource.minX,
                    y: image.size.height - declaredSource.maxY,
                    width: min(declaredSource.width, image.size.width - declaredSource.minX),
                    height: min(declaredSource.height, declaredSource.maxY - declaredSource.minY)
                )
            } else if layer.cropToFirstFrame, frame.width > 0, frame.height > 0 {
                CGRect(
                    x: 0,
                    y: max(0, image.size.height - frame.height),
                    width: min(image.size.width, frame.width),
                    height: min(image.size.height, frame.height)
                )
            } else {
                CGRect(origin: .zero, size: image.size)
            }
            image.draw(in: frame, from: source, operation: .sourceOver, fraction: runtimeOpacity(for: layer), respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
    }

    private func drawModernScene() {
        let catalog = skinStore.activeCatalog
        let scene = catalog.scene
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if WasabiScenePainter.renderNodes(in: scene).isEmpty {
            if let image = catalog.modernBaseImage ?? catalog.mainImage {
                context.interpolationQuality = .none
                image.draw(in: CGRect(origin: .zero, size: catalog.canvasSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
            return
        }

        WasabiScenePainter.paint(scene, in: context) { node in
            guard isElementVisible(node.id, initiallyVisible: true) else { return }
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

    private func drawModernDrawers() {
        let canvas = skinStore.activeCatalog.canvasSize
        for drawer in skinStore.activeCatalog.drawers {
            NSGraphicsContext.saveGraphicsState()
            if let occlusion = skinStore.activeCatalog.modernOcclusionFrame {
                let clip: CGRect = switch drawer.role {
                case .left:
                    CGRect(x: 0, y: 0, width: max(0, occlusion.minX), height: canvas.height)
                case .right:
                    CGRect(x: min(canvas.width, occlusion.maxX), y: 0, width: max(0, canvas.width - occlusion.maxX), height: canvas.height)
                }
                NSBezierPath(rect: clip).addClip()
            }
            let offset = drawerOffset(for: drawer)
            if let image = skinStore.activeCatalog.drawerImages[drawer.role] {
                image.draw(
                    in: CGRect(x: offset.x, y: offset.y, width: canvas.width, height: canvas.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.none]
                )
            }
            drawModernLayers(drawerRole: drawer.role)
            drawModernContent(drawerRole: drawer.role)
            drawMakiControlState(drawerRole: drawer.role)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawModernContent(drawerRole: ModernDrawerRole?) {
        for region in skinStore.activeCatalog.contentRegions where region.drawerRole == drawerRole {
            guard isElementVisible(region.elementID, initiallyVisible: region.initiallyVisible) else { continue }
            let frame = translated(effectiveFrame(for: region), for: drawerRole)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: frame).addClip()
            switch region.role {
            case .albumArt:
                drawAlbumArt(in: frame)
            case .visualization:
                drawSimulatedVisualization(in: frame)
            case .playlist:
                drawPlaylist(in: frame)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMakiControlState(drawerRole: ModernDrawerRole?) {
        for control in skinStore.activeCatalog.controls where control.drawerRole == drawerRole {
            guard let elementID = control.elementID?.lowercased() else { continue }
            guard isElementVisible(elementID, initiallyVisible: control.initiallyVisible),
                  let image = skinStore.activeCatalog.makiControlImages[elementID] else { continue }
            image.draw(
                in: control.orientation == nil
                    ? effectiveFrame(for: control)
                    : sliderThumbFrame(for: control, imageSize: image.size),
                from: .zero,
                operation: .sourceOver,
                fraction: runtimeOpacity(for: elementID),
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
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
            if hasDrawer(.right) { toggleDrawer(.right) } else { playlistToggle() }
        case .toggleEqualizer:
            if hasDrawer(.left) { toggleDrawer(.left) } else { equalizerToggle() }
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
        let icons: [SkinControlID: String] = [.previous: "⏮", .play: "▶", .pause: "Ⅱ", .stop: "■", .next: "⏭", .open: "⌃", .shuffle: "SHUF", .repeat: "REP", .equalizer: "EQ", .playlist: "PL"]
        for control in skinStore.activeCatalog.controls where control.id != .seek && control.id != .volume && control.id != .visualization {
            let pressed = pressedControl == control.id
            if let sprite = pressed ? control.pressedSprite ?? control.normalSprite : control.normalSprite,
               drawClassicSprite(sprite, in: control.frame) { continue }
            let enabled = capability(for: control.action).map(coordinator.capabilities.contains) ?? true
            let color = enabled ? NSColor(calibratedWhite: pressed ? 0.22 : 0.14, alpha: 0.92) : NSColor(calibratedWhite: 0.1, alpha: 0.5)
            color.setFill(); control.frame.fill()
            (enabled ? NSColor.systemGreen : NSColor.disabledControlTextColor).setStroke(); NSBezierPath(rect: control.frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: control.id == .shuffle || control.id == .repeat ? 6 : 9, weight: .bold), .foregroundColor: enabled ? NSColor.systemGreen : NSColor.disabledControlTextColor]
            let text = icons[control.id] ?? ""
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: control.frame.midX - size.width / 2, y: control.frame.midY - size.height / 2), withAttributes: attributes)
        }
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        CGRect(x: 16, y: 72, width: 248, height: 10).fill(); CGRect(x: 107, y: 57, width: 68, height: 10).fill()
        NSColor.systemGreen.setFill()
        let progress = coordinator.state.duration.map { max(0, min(1, coordinator.state.elapsed.secondsValue / max(0.001, $0.secondsValue))) } ?? 0
        CGRect(x: 16, y: 72, width: 248 * progress, height: 10).fill()
        let volume = coordinator.capabilities.contains(.applicationVolume) ? coordinator.state.volume : 0
        CGRect(x: 107, y: 57, width: 68 * volume, height: 10).fill()
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
           WasabiScenePainter.renderNodes(in: skinStore.activeCatalog.scene).contains(where: { $0.kind == .text || $0.kind == .songTicker }) { return }
        if skinStore.activeCatalog.format == .classic {
            title.prefix(33).uppercased().draw(at: CGPoint(x: 111, y: 24), withAttributes: attributes)
            time.draw(at: CGPoint(x: 40, y: 24), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.systemGreen])
            "SIM VIS".draw(at: CGPoint(x: 40, y: 47), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 6, weight: .medium), .foregroundColor: NSColor.systemGreen])
            drawClassicTechnicalValue(technicalBitrate, in: CGRect(x: 108, y: 45, width: 22, height: 12))
            drawClassicTechnicalValue(technicalFrequency, in: CGRect(x: 151, y: 45, width: 20, height: 12))
            NSColor.systemRed.setFill(); CGRect(x: 263, y: 3, width: 8, height: 7).fill()
        } else {
            for region in skinStore.activeCatalog.textRegions {
                guard isElementVisible(region.elementID, initiallyVisible: region.initiallyVisible) else { continue }
                let frame = translated(effectiveFrame(for: region), for: region.drawerRole)
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
        if skinStore.activeCatalog.contentRegions.contains(where: { translated($0.frame, for: $0.drawerRole).contains(point) }) { return true }
        if skinStore.activeCatalog.drawers.contains(where: { drawer in
            drawer.expandedFrame.offsetBy(dx: drawerOffset(for: drawer).x, dy: drawerOffset(for: drawer).y).contains(point)
        }) { return true }
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

    private func hasDrawer(_ role: ModernDrawerRole) -> Bool {
        skinStore.activeCatalog.drawers.contains { $0.role == role }
    }

    private func effectiveFrame(for control: SkinControlDefinition) -> CGRect {
        translated(effectiveFrame(control.frame, elementID: control.elementID), for: control.drawerRole)
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
           let sceneFrame = WasabiScenePainter.renderNodes(in: skinStore.activeCatalog.scene)
            .first(where: { $0.id == elementID.lowercased() })?.worldFrame {
            return sceneFrame
        }
        var result = frame
        if let generic = genericFrames[elementID.lowercased()] { result = generic }
        if let value = runtimeNumber(elementID, "x") { result.origin.x = value }
        if let value = runtimeNumber(elementID, "y") { result.origin.y = value }
        if let value = runtimeNumber(elementID, "w"), value > 0 { result.size.width = value }
        if let value = runtimeNumber(elementID, "h"), value > 0 { result.size.height = value }
        return result
    }

    private func hitObject(at point: CGPoint) -> WasabiObjectNode? {
        if skinStore.activeCatalog.format == .modern,
           let sceneNode = skinStore.activeCatalog.scene.hitTest(point),
           let node = WasabiScenePainter.renderNodes(in: skinStore.activeCatalog.scene)
            .first(where: { $0.handle == sceneNode.handle }),
           isElementVisible(node.id, initiallyVisible: true) {
            return WasabiObjectNode(
                id: node.id,
                kind: node.kind,
                frame: node.worldFrame,
                parentID: nil,
                initiallyVisible: true,
                attributes: node.attributes,
                zIndex: node.zIndex
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

    private func runtimeOpacity(for layer: ModernSkinLayer) -> CGFloat {
        guard let elementID = layer.elementID else { return CGFloat(layer.opacity) }
        return runtimeOpacity(for: elementID) * CGFloat(layer.opacity)
    }

    private func runtimeOpacity(for objectID: String) -> CGFloat {
        if let value = genericAlphas[objectID.lowercased()] { return value }
        guard let value = runtimeNumber(objectID, "alpha") else { return 1 }
        return value > 1 ? min(max(value / 255, 0), 1) : min(max(value, 0), 1)
    }

    private func sliderThumbFrame(for control: SkinControlDefinition, imageSize: CGSize) -> CGRect {
        let track = effectiveFrame(for: control)
        let value = sliderValue(for: control)
        switch control.orientation {
        case .vertical:
            return CGRect(
                x: track.midX - imageSize.width / 2,
                y: track.minY + CGFloat(value) * max(0, track.height - imageSize.height),
                width: imageSize.width,
                height: imageSize.height
            )
        case .horizontal:
            return CGRect(
                x: track.minX + CGFloat(value) * max(0, track.width - imageSize.width),
                y: track.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )
        case nil:
            return track
        }
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

    private func translated(_ frame: CGRect, for role: ModernDrawerRole?) -> CGRect {
        guard let role, let drawer = skinStore.activeCatalog.drawers.first(where: { $0.role == role }) else { return frame }
        let offset = drawerOffset(for: drawer)
        return frame.offsetBy(dx: offset.x, dy: offset.y)
    }

    private func drawerOffset(for drawer: ModernDrawerDescriptor) -> CGPoint {
        let progress = CGFloat(drawerProgress(for: drawer.role))
        let current = CGPoint(
            x: drawer.collapsedOrigin.x + (drawer.expandedFrame.minX - drawer.collapsedOrigin.x) * progress,
            y: drawer.collapsedOrigin.y + (drawer.expandedFrame.minY - drawer.collapsedOrigin.y) * progress
        )
        return CGPoint(x: current.x - drawer.expandedFrame.minX, y: current.y - drawer.expandedFrame.minY)
    }

    private func drawerProgress(for role: ModernDrawerRole) -> Double {
        guard let animation = drawerAnimations[role] else { return drawerTargets[role] ?? 1 }
        let elapsed = Date.timeIntervalSinceReferenceDate - animation.startedAt
        let linear = min(max(elapsed / animation.duration, 0), 1)
        let eased = linear * linear * (3 - 2 * linear)
        return animation.from + (animation.to - animation.from) * eased
    }

    // Kept internal so the renderer regression suite can assert the state that
    // drives drawing without reaching into AppKit's private backing surfaces.
    var drawerProgressForTesting: [ModernDrawerRole: Double] {
        Dictionary(uniqueKeysWithValues: ModernDrawerRole.allCases.map { ($0, drawerProgress(for: $0)) })
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

    private func toggleDrawer(_ role: ModernDrawerRole) {
        let target = (drawerTargets[role] ?? 1) > 0.5 ? 0.0 : 1.0
        animateDrawer(role, to: target, duration: 0.28)
    }

    private func animateDrawer(_ role: ModernDrawerRole, to target: Double, duration: TimeInterval) {
        let current = drawerProgress(for: role)
        let clampedDuration = min(max(duration, 0.05), 2)
        drawerTargets[role] = target
        drawerAnimationTargets.removeValue(forKey: role)
        drawerAnimations[role] = DrawerAnimation(
            from: current,
            to: target,
            startedAt: Date.timeIntervalSinceReferenceDate,
            duration: clampedDuration
        )
        drawerAnimationTasks[role]?.cancel()
        drawerAnimationTasks[role] = Task { [weak self] in
            let frameCount = max(1, Int(ceil(clampedDuration / 0.016)) + 1)
            for _ in 0..<frameCount {
                guard !Task.isCancelled else { return }
                self?.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.drawerAnimations.removeValue(forKey: role)
            self?.drawerAnimationTasks.removeValue(forKey: role)
            self?.needsDisplay = true
            if let objectID = self?.drawerAnimationTargets.removeValue(forKey: role) {
                self?.makiTargetReached(objectID: objectID)
            }
        }
    }

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
        makiRuntime = nil
        lastMakiPlaybackState = nil
        drawerAnimationTasks.values.forEach { $0.cancel() }
        drawerAnimationTasks.removeAll()
        drawerAnimations.removeAll()
        let initialProgress = catalog.makiPrograms.isEmpty ? 1.0 : 0.0
        drawerTargets = [.left: initialProgress, .right: initialProgress]
        guard !catalog.makiPrograms.isEmpty else { return }
        makiRuntime = MakiRuntime(programs: catalog.makiPrograms, bindings: catalog.makiBindings, host: self, limits: .init(), skinID: catalog.name, persistentState: .standard, scene: catalog.scene)
        makiRuntime?.start()
    }

    private func capability(for action: SkinAction) -> PlaybackCapabilities? {
        switch action { case .play: .playback; case .pause: .pause; case .stop: .explicitStop; case .previous: .previous; case .next: .next; case .seek: .seek; case .setVolume: .applicationVolume; case .toggleShuffle: .shuffle; case .cycleRepeat: .repeat; default: nil }
    }
}

extension SkinRendererView: MakiRuntimeHost {
    func makiPlaybackStatus() -> Int { coordinator.state.isPlaying ? 1 : 0 }

    func makiXMLParameter(objectID: String, name: String) -> String? {
        guard name == "x" else { return nil }
        let normalized = objectID.lowercased()
        let role: ModernDrawerRole? = normalized.contains("leftdrawer") ? .left : normalized.contains("rightdrawer") ? .right : nil
        guard let role, let drawer = skinStore.activeCatalog.drawers.first(where: { $0.role == role }) else { return nil }
        if normalized.contains("coords") { return String(Double(drawer.expandedFrame.minX)) }
        if normalized == "\(role.rawValue)drawer" { return String(Double(drawer.collapsedOrigin.x)) }
        return nil
    }

    func makiVisibilityChanged(objectID: String, isVisible: Bool) { needsDisplay = true }

    func makiTargetChanged(objectID: String, x: Double, speed: Double) {
        let normalized = objectID.lowercased()
        let role: ModernDrawerRole? = normalized.contains("leftdrawer") ? .left : normalized.contains("rightdrawer") ? .right : nil
        guard let role, let drawer = skinStore.activeCatalog.drawers.first(where: { $0.role == role }) else { return }
        let expandedDistance = abs(x - Double(drawer.expandedFrame.minX))
        let collapsedDistance = abs(x - Double(drawer.collapsedOrigin.x))
        let target: Double = expandedDistance <= collapsedDistance ? 1 : 0
        if abs(drawerProgress(for: role) - target) < 0.001 {
            drawerTargets[role] = target
            makiTargetReached(objectID: objectID)
            return
        }
        animateDrawer(role, to: target, duration: speed)
        drawerAnimationTargets[role] = objectID
    }

    func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
        let key = objectID.lowercased()
        if (key.contains("leftdrawer") || key.contains("rightdrawer")), let x {
            makiTargetChanged(objectID: objectID, x: x, speed: speed)
            return
        }
        guard let node = skinStore.activeCatalog.objectTree.object(id: key) else {
            makiTargetChanged(objectID: objectID, x: x ?? 0, speed: speed)
            return
        }
        var target = genericFrames[key] ?? node.frame
        if let x { target.origin.x = x }
        if let y { target.origin.y = y }
        if let width, width > 0 { target.size.width = width }
        if let height, height > 0 { target.size.height = height }
        let start = genericFrames[key] ?? node.frame
        genericAnimationTasks[key]?.cancel()
        let duration = min(max(speed, 0.05), 2)
        let started = Date.timeIntervalSinceReferenceDate
        genericAnimationTasks[key] = Task { [weak self] in
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
                self?.genericFrames[key] = frame
                if let alpha { self?.genericAlphas[key] = CGFloat(alpha > 1 ? alpha / 255 : alpha) }
                self?.needsDisplay = true
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.genericFrames[key] = target
            self?.genericAnimationTasks.removeValue(forKey: key)
            self?.needsDisplay = true
            self?.makiTargetReached(objectID: objectID)
        }
    }

    func makiLayoutSwitched(containerID: String, layoutID: String) {
        guard skinStore.activeCatalog.modernLayouts.contains(where: { $0.id.caseInsensitiveCompare(layoutID) == .orderedSame }) else {
            makiRuntime?.recordExternalDiagnostic("Unsupported layout \(layoutID) requested by \(containerID).")
            return
        }
        activeLayoutID = layoutID.lowercased()
        needsDisplay = true
    }

    func makiLayoutResized(objectID: String, frame: CGRect) {
        guard frame.width > 0, frame.height > 0, frame.width <= 2_048, frame.height <= 2_048 else {
            makiRuntime?.recordExternalDiagnostic("Rejected unsafe layout resize for \(objectID).")
            return
        }
        genericFrames[objectID.lowercased()] = frame
        needsDisplay = true
    }

    func makiRedock(objectID: String, before: Bool) {
        redockSuspended = before
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
