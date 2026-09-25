import AppKit

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
    private var refreshTask: Task<Void, Never>?
    private var makiRuntime: MakiRuntime?
    private var runtimeCatalog: SkinAssetCatalog?
    private var lastMakiPlaybackState: Bool?
    private var drawerAnimationTasks: [ModernDrawerRole: Task<Void, Never>] = [:]
    private var pressedControl: SkinControlID?
    private var activeControl: SkinControlDefinition?
    private var balanceValue = 0.5
    private var drawerTargets: [ModernDrawerRole: Double] = [.left: 1, .right: 1]
    private var drawerAnimations: [ModernDrawerRole: DrawerAnimation] = [:]
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
        visualizationToggle: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.skinStore = skinStore
        self.settings = settings
        self.openMedia = openMedia
        self.playlistToggle = playlistToggle
        self.equalizerToggle = equalizerToggle
        self.visualizationToggle = visualizationToggle
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
                self?.needsDisplay = true
                self?.setAccessibilityValue(self?.coordinator.state.currentItem.map { "\($0.title), \($0.artist ?? "Unknown artist")" } ?? "Nothing playing")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        refreshTask?.cancel()
        drawerAnimationTasks.values.forEach { $0.cancel() }
    }

    func updateScale(_ value: Int) {
        scale = min(max(value, 1), 4)
        drawerAnimationTasks.values.forEach { $0.cancel() }
        drawerAnimationTasks.removeAll()
        drawerAnimations.removeAll()
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
        if skinStore.activeCatalog.format == .modern { drawModernDrawers() }
        if let image = skinStore.activeCatalog.modernBaseImage ?? skinStore.activeCatalog.mainImage {
            NSGraphicsContext.current?.imageInterpolation = .none
            image.draw(in: CGRect(origin: .zero, size: skinStore.activeCatalog.canvasSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        if skinStore.activeCatalog.format == .modern { drawModernContent(drawerRole: nil) }
        if skinStore.activeCatalog.format == .modern { drawMakiControlState(drawerRole: nil) }
        if skinStore.activeCatalog.format == .classic { drawTransportControls() }
        drawMetadata()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if settings.clickThroughTransparentPixels, !isVisible(at: logical(point)) { return nil }
        return self
    }

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
        let control = candidates.first(where: { coordinator.state.isPlaying ? $0.action == .pause : $0.action == .play }) ?? candidates.first
        if let control {
            pressedControl = control.id
            activeControl = control
            needsDisplay = true
            let frame = effectiveFrame(for: control)
            Task { await activate(control, point: point, frame: frame) }
        } else if point.y < 18 {
            window?.performDrag(with: event)
        }
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
            drawModernContent(drawerRole: drawer.role)
            drawMakiControlState(drawerRole: drawer.role)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawModernContent(drawerRole: ModernDrawerRole?) {
        for region in skinStore.activeCatalog.contentRegions where region.drawerRole == drawerRole {
            if let elementID = region.elementID {
                let scriptedVisibility = makiRuntime?.isVisible(objectID: elementID)
                if scriptedVisibility == false || scriptedVisibility == nil && !region.initiallyVisible { continue }
            } else if !region.initiallyVisible {
                continue
            }
            let frame = translated(region.frame, for: drawerRole)
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
            let scriptedVisibility = makiRuntime?.isVisible(objectID: elementID)
            guard scriptedVisibility ?? control.initiallyVisible,
                  let image = skinStore.activeCatalog.makiControlImages[elementID] else { continue }
            image.draw(
                in: control.orientation == nil
                    ? effectiveFrame(for: control)
                    : sliderThumbFrame(for: control, imageSize: image.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
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
        case .remote, nil: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
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
        Task { await activate(control, point: point, frame: frame) }
    }

    override func mouseUp(with event: NSEvent) {
        pressedControl = nil
        activeControl = nil
        needsDisplay = true
    }

    private func activate(_ control: SkinControlDefinition, point: CGPoint, frame: CGRect) async {
        if let elementID = control.elementID, makiRuntime?.dispatchClick(objectID: elementID) == true { return }
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
        default: break
        }
    }

    private func drawTransportControls() {
        let icons: [SkinControlID: String] = [.previous: "⏮", .play: "▶", .pause: "Ⅱ", .stop: "■", .next: "⏭", .open: "⌃", .shuffle: "SHUF", .repeat: "REP"]
        for control in skinStore.activeCatalog.controls where control.id != .seek && control.id != .volume && control.id != .visualization {
            let enabled = capability(for: control.action).map(coordinator.capabilities.contains) ?? true
            let color = enabled ? NSColor(calibratedWhite: pressedControl == control.id ? 0.22 : 0.14, alpha: 0.92) : NSColor(calibratedWhite: 0.1, alpha: 0.5)
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

    private func drawMetadata() {
        let item = coordinator.state.currentItem
        let title = item.map { "\($0.artist ?? "UNKNOWN") - \($0.title)" } ?? "MACAMP — READY"
        let elapsed = Int(coordinator.state.elapsed.secondsValue)
        let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .medium), .foregroundColor: NSColor.systemGreen]
        if skinStore.activeCatalog.format == .classic {
            title.prefix(33).uppercased().draw(at: CGPoint(x: 111, y: 24), withAttributes: attributes)
            time.draw(at: CGPoint(x: 40, y: 24), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.systemGreen])
            "SIM VIS".draw(at: CGPoint(x: 40, y: 47), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 6, weight: .medium), .foregroundColor: NSColor.systemGreen])
            NSColor.systemRed.setFill(); CGRect(x: 263, y: 3, width: 8, height: 7).fill()
        } else {
            for region in skinStore.activeCatalog.textRegions {
                let frame = translated(region.frame, for: region.drawerRole)
                let text: String = switch region.role {
                case .songTitle: title
                case .elapsedTime: time
                case .remainingTime:
                    if let duration = coordinator.state.duration {
                        "-\(formatted(max(0, duration.secondsValue - coordinator.state.elapsed.secondsValue)))"
                    } else { "--:--" }
                }
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

    private func logical(_ point: CGPoint) -> CGPoint { point }
    private func isVisible(at point: CGPoint) -> Bool {
        if let region = skinStore.activeCatalog.regionPath { return region.contains(point) }
        if skinStore.activeCatalog.contentRegions.contains(where: { translated($0.frame, for: $0.drawerRole).contains(point) }) { return true }
        if skinStore.activeCatalog.drawers.contains(where: { drawer in
            drawer.expandedFrame.offsetBy(dx: drawerOffset(for: drawer).x, dy: drawerOffset(for: drawer).y).contains(point)
        }) { return true }
        guard let image = skinStore.activeCatalog.modernBaseImage ?? skinStore.activeCatalog.mainImage,
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
        translated(control.frame, for: control.drawerRole)
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

    private func toggleDrawer(_ role: ModernDrawerRole) {
        let target = (drawerTargets[role] ?? 1) > 0.5 ? 0.0 : 1.0
        animateDrawer(role, to: target, duration: 0.28)
    }

    private func animateDrawer(_ role: ModernDrawerRole, to target: Double, duration: TimeInterval) {
        let current = drawerProgress(for: role)
        let clampedDuration = min(max(duration, 0.05), 2)
        drawerTargets[role] = target
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
        makiRuntime = MakiRuntime(programs: catalog.makiPrograms, bindings: catalog.makiBindings, host: self)
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
        animateDrawer(role, to: expandedDistance <= collapsedDistance ? 1 : 0, duration: speed)
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

    func makiRuntimeNeedsDisplay() { needsDisplay = true }
}
