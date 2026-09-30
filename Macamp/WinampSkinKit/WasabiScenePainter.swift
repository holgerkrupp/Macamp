import AppKit

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
