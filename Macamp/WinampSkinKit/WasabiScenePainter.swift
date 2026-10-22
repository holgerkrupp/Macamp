import AppKit

/// Winamp XML bitmap rectangles use a top-left origin. Crop the underlying
/// bitmap before handing it to AppKit so a flipped view and an offscreen
/// NSImage context see identical pixels.
enum ModernSkinCoordinateSpace {
    @MainActor
    static func croppedImage(_ image: NSImage, fromTopLeft rect: CGRect) -> NSImage? {
        let imageBounds = CGRect(origin: .zero, size: image.size)
        let clipped = rect.intersection(imageBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        guard clipped != imageBounds else { return image }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scaleX = CGFloat(cgImage.width) / image.size.width
        let scaleY = CGFloat(cgImage.height) / image.size.height
        let pixelRect = CGRect(
            x: clipped.minX * scaleX,
            y: clipped.minY * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        ).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: clipped.size)
    }
}

/// A render visit resolved from the live Wasabi hierarchy. `localFrame` is
/// authored geometry; `worldFrame` is derived for hit testing and diagnostics.
struct WasabiSceneRenderNode: Sendable, Equatable {
    let handle: WasabiHandle
    let id: String
    let kind: WasabiObjectKind
    let localFrame: CGRect
    let worldFrame: CGRect
    let alpha: CGFloat
    let zIndex: Int
    let attributes: [String: String]
}

/// A selected cell from an AnimatedLayer sprite sheet. `sourceRect` uses the
/// same top-left image coordinate system as Modern XML bitmap declarations;
/// the AppKit adapter converts it when it draws the image.
struct WasabiAnimatedLayerFrame: Sendable, Equatable {
    let index: Int
    let count: Int
    let sourceRect: CGRect
}

/// Resolves generic AnimatedLayer state from the live scene node. Wasabi
/// resources conventionally use vertically stacked cells, while the explicit
/// `frameaxis="horizontal"` attribute covers horizontal sheets without
/// introducing skin-specific behavior.
enum WasabiAnimatedLayer {
    static func selection(
        for node: WasabiSceneRenderNode,
        imageSize: CGSize
    ) -> WasabiAnimatedLayerFrame? {
        selection(
            kind: node.kind,
            frame: node.localFrame,
            attributes: node.attributes,
            imageSize: imageSize
        )
    }

    static func selection(
        kind: WasabiObjectKind,
        frame: CGRect,
        attributes: [String: String],
        imageSize: CGSize
    ) -> WasabiAnimatedLayerFrame? {
        guard kind == .animatedLayer,
              frame.width > 0,
              frame.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else { return nil }

        let axis = attributes["frameaxis"]?.lowercased() == "horizontal" ? "horizontal" : "vertical"
        let cellWidth = positiveNumber(
            attributes["framewidth"] ?? attributes["framew"]
        ) ?? frame.width
        let cellHeight = positiveNumber(
            attributes["frameheight"] ?? attributes["frameh"]
        ) ?? frame.height
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        let available = axis == "horizontal"
            ? Int(floor(imageSize.width / cellWidth))
            : Int(floor(imageSize.height / cellHeight))
        guard available > 0 else { return nil }

        let requestedCount = nonNegativeInteger(
            attributes["framecount"] ?? attributes["frames"] ?? attributes["numframes"]
        )
        let count = max(1, min(requestedCount ?? available, available))
        let requestedIndex = nonNegativeInteger(
            attributes["frameindex"] ?? attributes["currentframe"] ?? attributes["frame"]
        ) ?? 0
        let index = min(requestedIndex, count - 1)

        // Frame zero preserves the existing Modern behavior: the first cell
        // is the top-most cell in a vertically stacked bitmap. Subsequent
        // frames walk toward the bottom of the source image.
        let x = axis == "horizontal" ? CGFloat(index) * cellWidth : 0
        let topY = axis == "vertical"
            ? CGFloat(index) * cellHeight
            : 0
        let source = CGRect(x: x, y: topY, width: cellWidth, height: cellHeight)
        guard CGRect(origin: .zero, size: imageSize).contains(source) else { return nil }
        return WasabiAnimatedLayerFrame(index: index, count: count, sourceRect: source)
    }

    private static func positiveNumber(_ value: String?) -> CGFloat? {
        guard let value, let number = Double(value), number > 0 else { return nil }
        return CGFloat(number)
    }

    private static func nonNegativeInteger(_ value: String?) -> Int? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        if number >= Double(Int.max) { return Int.max }
        return max(0, Int(number.rounded(.towardZero)))
    }
}

/// Runtime resource lookup for the scene painter.  Keeping bitmap identity,
/// source cropping and the decoded AppKit image together prevents individual
/// node kinds from silently falling back to the old flattened catalog maps.
@MainActor
final class WasabiResourceRegistry {
    struct Bitmap {
        let id: String
        let image: NSImage
        let sourceRect: CGRect?
    }

    private(set) var bitmaps: [String: Bitmap] = [:]
    let bitmapFonts: [String: ModernBitmapFontResource]
    let fonts: [String: ModernFontResource]
    let gammaSets: [String: ModernGammaSetResource]

    init(catalog: SkinAssetCatalog) {
        for (id, path) in catalog.modernBitmapFiles {
            guard let image = catalog.images[path.lowercased()] else { continue }
            let key = id.lowercased()
            bitmaps[key] = Bitmap(
                id: key,
                image: image,
                sourceRect: catalog.modernBitmapSourceRects[key]
            )
        }
        bitmapFonts = catalog.modernBitmapFonts
        fonts = catalog.modernFonts
        gammaSets = catalog.modernGammaSets
    }

    func bitmap(for id: String?) -> Bitmap? {
        guard let id else { return nil }
        return bitmaps[id.lowercased()]
    }
}

struct WasabiScenePreviewSnapshot {
    let scene: WasabiScene
    let activeObjectIDs: Set<String>
}

/// Walks a Wasabi scene in paint order. Structural nodes establish the
/// transform and visibility scope; drawable nodes are handed to the caller
/// in a context already translated by every local parent frame.
enum WasabiScenePainter {
    static func renderNodes(in scene: WasabiScene) -> [WasabiSceneRenderNode] {
        var result: [WasabiSceneRenderNode] = []
        visit(scene, handles: scene.rootHandles, context: nil) { node in
            result.append(node)
        }
        return result
    }

    @MainActor
    static func paint(
        _ scene: WasabiScene,
        in context: CGContext,
        draw: (WasabiSceneRenderNode) -> Void
    ) {
        visit(scene, handles: scene.rootHandles, context: context, draw: draw)
    }

    @MainActor
    static func previewSnapshot(for catalog: SkinAssetCatalog) -> WasabiScenePreviewSnapshot {
        let host = WasabiPreviewMakiHost(scene: catalog.scene)
        guard !catalog.makiPrograms.isEmpty, !catalog.makiBindings.isEmpty else {
            return WasabiScenePreviewSnapshot(scene: host.scene, activeObjectIDs: [])
        }

        let defaultsDomain = "dev.macamp.preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsDomain) else {
            return WasabiScenePreviewSnapshot(scene: host.scene, activeObjectIDs: [])
        }
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }

        let runtime = MakiRuntime(
            programs: catalog.makiPrograms,
            bindings: catalog.makiBindings,
            host: host,
            limits: .init(),
            skinID: catalog.name,
            persistentState: defaults,
            scene: catalog.scene
        )
        host.runtime = runtime
        runtime.startForPreviewSnapshot()
        let activeObjectIDs = Set(host.scene.allNodes.compactMap { node in
            runtime.isActivated(node.handle) ? node.id : nil
        })
        return WasabiScenePreviewSnapshot(scene: host.scene, activeObjectIDs: activeObjectIDs)
    }

    /// Draw bitmap-backed scene nodes through AppKit's flipped image drawing
    /// path. Modern XML rectangles and sprite crops use a top-left origin;
    /// `respectFlipped: true` keeps those source rectangles in that same
    /// coordinate system when painting into the flipped Wasabi scene.
    @MainActor
    static func drawBitmapNode(
        _ node: WasabiSceneRenderNode,
        resources: WasabiResourceRegistry,
        in frame: CGRect,
        pressedObjectID: String? = nil,
        hoveredObjectID: String? = nil,
        isActive: Bool = false
    ) {
        let bitmap: WasabiResourceRegistry.Bitmap?
        switch node.kind {
        case .layer, .animatedLayer:
            bitmap = resources.bitmap(for: node.attributes["image"])
        case .button, .slider:
            let active = isActive || node.attributes["active"] == "1" || node.attributes["activated"] == "1"
            let imageID: String?
            if node.id == pressedObjectID || node.attributes["pressed"] == "1" {
                imageID = node.attributes["activepressedimage"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? node.attributes["downimage"].flatMap { $0.isEmpty ? nil : $0 }
            } else if node.id == hoveredObjectID {
                imageID = node.attributes["hoverimage"].flatMap { $0.isEmpty ? nil : $0 }
            } else if active {
                imageID = node.attributes["activeimage"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? node.attributes["image"].flatMap { $0.isEmpty ? nil : $0 }
            } else {
                imageID = node.attributes["image"].flatMap { $0.isEmpty ? nil : $0 }
            }
            bitmap = resources.bitmap(for: imageID)
        default:
            return
        }
        guard let bitmap else { return }

        let image = bitmap.image
        let animatedSource = node.kind == .animatedLayer
            ? WasabiAnimatedLayer.selection(for: node, imageSize: image.size)?.sourceRect
            : nil
        let topLeftSource = bitmap.sourceRect ?? animatedSource ?? CGRect(origin: .zero, size: image.size)
        guard let croppedImage = ModernSkinCoordinateSpace.croppedImage(image, fromTopLeft: topLeftSource) else { return }
        croppedImage.draw(
            in: frame,
            from: CGRect(origin: .zero, size: croppedImage.size),
            operation: .sourceOver,
            fraction: node.alpha,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    @MainActor
    static func renderBitmapScene(
        _ scene: WasabiScene,
        resources: WasabiResourceRegistry,
        size: CGSize,
        clipPath: NSBezierPath? = nil,
        activeObjectIDs: Set<String> = []
    ) -> NSImage? {
        let nodes = renderNodes(in: scene)
        let hasBitmapContent = nodes.contains { node in
            switch node.kind {
            case .layer, .animatedLayer:
                resources.bitmap(for: node.attributes["image"]) != nil
            case .button, .slider:
                ["image", "activeimage", "downimage", "activepressedimage", "hoverimage"]
                    .contains { resources.bitmap(for: node.attributes[$0]) != nil }
            default:
                false
            }
        }
        guard size.width > 0, size.height > 0, hasBitmapContent else { return nil }
        return NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .none
            if let clipPath {
                context.addPath(clipPath.cgPath)
                context.clip(using: .winding)
            }
            paint(scene, in: context) { node in
                drawBitmapNode(
                    node,
                    resources: resources,
                    in: CGRect(origin: .zero, size: node.localFrame.size),
                    isActive: activeObjectIDs.contains(node.id)
                )
            }
            return true
        }
    }

    @MainActor
    private final class WasabiPreviewMakiHost: MakiRuntimeHost {
        var scene: WasabiScene
        weak var runtime: MakiRuntime?

        init(scene: WasabiScene) { self.scene = scene }

        func makiPlaybackStatus() -> Int { 0 }

        func makiXMLParameter(objectID: String, name: String) -> String? {
            guard let handle = scene.firstHandle(for: objectID), let node = scene.node(handle) else { return nil }
            switch name.lowercased() {
            case "x": return String(Double(node.localFrame.minX))
            case "y": return String(Double(node.localFrame.minY))
            case "w", "width": return String(Double(node.localFrame.width))
            case "h", "height": return String(Double(node.localFrame.height))
            case "alpha": return String(Double(scene.effectiveAlpha(handle)))
            case "visible": return scene.effectiveVisible(handle) ? "1" : "0"
            default: return nil
            }
        }

        func makiVisibilityChanged(objectID: String, isVisible: Bool) {
            for handle in scene.handles(for: objectID) { scene.setVisible(isVisible, for: handle) }
        }

        func makiTargetChanged(objectID: String, x: Double, speed: Double) {
            guard let handle = scene.firstHandle(for: objectID), var frame = scene.node(handle)?.localFrame else { return }
            frame.origin.x = x
            scene.setLocalFrame(frame, for: handle)
        }

        func makiTargetGeometryChanged(objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
            guard let handle = scene.firstHandle(for: objectID) else { return }
            makiTargetGeometryChanged(receiver: handle, objectID: objectID, x: x, y: y, width: width, height: height, alpha: alpha, speed: speed)
        }

        func makiTargetGeometryChanged(receiver: WasabiHandle, objectID: String, x: Double?, y: Double?, width: Double?, height: Double?, alpha: Double?, speed: Double) {
            guard var frame = scene.node(receiver)?.localFrame else { return }
            if let x { frame.origin.x = x }
            if let y { frame.origin.y = y }
            if let width, width > 0 { frame.size.width = width }
            if let height, height > 0 { frame.size.height = height }
            scene.setLocalFrame(frame, for: receiver)
            if let alpha { scene.setAlpha(CGFloat(alpha > 1 ? alpha / 255 : alpha), for: receiver) }
            runtime?.targetReached(receiver: receiver, objectID: objectID)
        }

        func makiLayoutSwitched(containerID: String, layoutID: String) {
            guard let container = scene.firstHandle(for: containerID),
                  let layout = scene.handles(for: layoutID).first(where: { scene.node($0)?.kind == .layout && scene.node($0)?.parent == container }) else { return }
            scene.setActiveLayout(layout, for: container)
        }

        func makiVolumeChanged(_ value: Double) {}
        func makiEQBandChanged(index: Int, value: Int) {}
        func makiRuntimeNeedsDisplay() {}
    }

    private static func visit(
        _ scene: WasabiScene,
        handles: [WasabiHandle],
        context: CGContext?,
        draw: (WasabiSceneRenderNode) -> Void
    ) {
        let ordered = handles.compactMap { scene.node($0) }.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            return lhs.handle.rawValue < rhs.handle.rawValue
        }

        for node in ordered {
            guard scene.isInActiveLayout(node.handle), scene.effectiveVisible(node.handle),
                  scene.effectiveAlpha(node.handle) > 0,
                  let worldFrame = scene.worldFrame(of: node.handle) else { continue }

            context?.saveGState()
            context?.translateBy(x: node.localFrame.minX, y: node.localFrame.minY)

            if isDrawable(node.kind) {
                draw(WasabiSceneRenderNode(
                    handle: node.handle,
                    id: node.id,
                    kind: node.kind,
                    localFrame: node.localFrame,
                    worldFrame: worldFrame,
                    alpha: scene.effectiveAlpha(node.handle),
                    zIndex: node.zIndex,
                    attributes: node.attributes
                ))
            }

            visit(scene, handles: node.children, context: context, draw: draw)
            context?.restoreGState()
        }
    }

    private static func isDrawable(_ kind: WasabiObjectKind) -> Bool {
        switch kind {
        case .button, .slider, .layer, .animatedLayer, .text, .songTicker, .content:
            true
        case .container, .layout, .group, .unknown:
            false
        }
    }
}
