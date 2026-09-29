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
