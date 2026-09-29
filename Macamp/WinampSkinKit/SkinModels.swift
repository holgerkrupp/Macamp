import AppKit
import Foundation
import ImageIO

enum SkinAction: String, Sendable, Equatable {
    case none, scripted
    case previous, play, pause, stop, next, open, seek, setVolume, setBalance
    case setEqualizerBand, resetEqualizer
    case toggleShuffle, cycleRepeat, togglePlaylist, toggleEqualizer, toggleVisualization
    case windowshade, minimize, close
}

nonisolated enum SkinControlOrientation: Sendable, Equatable {
    case horizontal, vertical
}

enum SkinControlID: String, Sendable, Equatable {
    case scripted
    case previous, play, pause, stop, next, open, seek, volume, shuffle, `repeat`
    case playlist, equalizer, visualization, minimize, close
}

struct SpriteReference: Sendable, Equatable {
    var assetName: String
    var sourceRect: CGRect
}

struct SkinControlDefinition: Sendable {
    let id: SkinControlID
    let frame: CGRect
    let normalSprite: SpriteReference?
    let pressedSprite: SpriteReference?
    let disabledSprite: SpriteReference?
    let action: SkinAction
    var elementID: String? = nil
    var initiallyVisible: Bool = true
    var drawerRole: ModernDrawerRole? = nil
    var parameter: Int? = nil
    var orientation: SkinControlOrientation? = nil
}

/// The fixed Classic main-window table is data, not renderer inference.  The
/// source rectangles are kept in the same logical coordinate system as the
/// Winamp atlases; callers crop these sprites and never stretch an atlas as a
/// whole.
enum ClassicSpriteSheet: String, Sendable {
    case main = "main.bmp"
    case cbuttons = "cbuttons.bmp"
    case titlebar = "titlebar.bmp"
    case shufrep = "shufrep.bmp"
    case volume = "volume.bmp"
    case balance = "balance.bmp"
    case posbar = "posbar.bmp"
    case numbers = "numbers.bmp"
    case numsExtra = "nums_ex.bmp"
    case playPause = "playpaus.bmp"
    case monoStereo = "monoster.bmp"
    case text = "text.bmp"
}

struct ClassicElementDescriptor: Sendable, Equatable {
    let id: SkinControlID
    let frame: CGRect
    let normal: SpriteReference
    let pressed: SpriteReference?
    let active: SpriteReference?
    let activePressed: SpriteReference?
    let action: SkinAction
}

/// A resolved Classic slider state.  The track and thumb remain sprite
/// references so the renderer can crop the skin's atlas without scaling or
/// synthesizing replacement pixels.
struct ClassicSliderPlacement: Equatable, Sendable {
    let track: SpriteReference
    let thumb: SpriteReference
    let thumbFrame: CGRect
}

enum ClassicSpriteCatalog {
    private static func sprite(_ sheet: ClassicSpriteSheet, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> SpriteReference {
        SpriteReference(assetName: sheet.rawValue, sourceRect: CGRect(x: x, y: y, width: width, height: height))
    }

    static let main: [SkinControlID: ClassicElementDescriptor] = [
        .previous: .init(id: .previous, frame: CGRect(x: 16, y: 88, width: 23, height: 18), normal: sprite(.cbuttons, 0, 0, 23, 18), pressed: sprite(.cbuttons, 0, 18, 23, 18), active: nil, activePressed: nil, action: .previous),
        .play: .init(id: .play, frame: CGRect(x: 39, y: 88, width: 23, height: 18), normal: sprite(.cbuttons, 23, 0, 23, 18), pressed: sprite(.cbuttons, 23, 18, 23, 18), active: nil, activePressed: nil, action: .play),
        .pause: .init(id: .pause, frame: CGRect(x: 62, y: 88, width: 23, height: 18), normal: sprite(.cbuttons, 46, 0, 23, 18), pressed: sprite(.cbuttons, 46, 18, 23, 18), active: nil, activePressed: nil, action: .pause),
        .stop: .init(id: .stop, frame: CGRect(x: 85, y: 88, width: 23, height: 18), normal: sprite(.cbuttons, 69, 0, 23, 18), pressed: sprite(.cbuttons, 69, 18, 23, 18), active: nil, activePressed: nil, action: .stop),
        .next: .init(id: .next, frame: CGRect(x: 108, y: 88, width: 22, height: 18), normal: sprite(.cbuttons, 92, 0, 22, 18), pressed: sprite(.cbuttons, 92, 18, 22, 18), active: nil, activePressed: nil, action: .next),
        .open: .init(id: .open, frame: CGRect(x: 136, y: 89, width: 22, height: 16), normal: sprite(.cbuttons, 114, 0, 22, 16), pressed: sprite(.cbuttons, 114, 16, 22, 16), active: nil, activePressed: nil, action: .open),
        .shuffle: .init(id: .shuffle, frame: CGRect(x: 164, y: 89, width: 47, height: 15), normal: sprite(.shufrep, 28, 0, 47, 15), pressed: sprite(.shufrep, 28, 15, 47, 15), active: sprite(.shufrep, 28, 30, 47, 15), activePressed: sprite(.shufrep, 28, 45, 47, 15), action: .toggleShuffle),
        .repeat: .init(id: .repeat, frame: CGRect(x: 210, y: 89, width: 28, height: 15), normal: sprite(.shufrep, 0, 0, 28, 15), pressed: sprite(.shufrep, 0, 15, 28, 15), active: sprite(.shufrep, 0, 30, 28, 15), activePressed: sprite(.shufrep, 0, 45, 28, 15), action: .cycleRepeat),
        .equalizer: .init(id: .equalizer, frame: CGRect(x: 219, y: 58, width: 23, height: 12), normal: sprite(.shufrep, 0, 61, 23, 12), pressed: sprite(.shufrep, 46, 61, 23, 12), active: sprite(.shufrep, 0, 73, 23, 12), activePressed: sprite(.shufrep, 46, 73, 23, 12), action: .toggleEqualizer),
        .playlist: .init(id: .playlist, frame: CGRect(x: 242, y: 58, width: 23, height: 12), normal: sprite(.shufrep, 23, 61, 23, 12), pressed: sprite(.shufrep, 69, 61, 23, 12), active: sprite(.shufrep, 23, 73, 23, 12), activePressed: sprite(.shufrep, 69, 73, 23, 12), action: .togglePlaylist),
        .seek: .init(id: .seek, frame: CGRect(x: 16, y: 72, width: 248, height: 10), normal: sprite(.posbar, 0, 0, 248, 10), pressed: sprite(.posbar, 278, 0, 29, 10), active: sprite(.posbar, 248, 0, 29, 10), activePressed: nil, action: .seek),
        .volume: .init(id: .volume, frame: CGRect(x: 107, y: 57, width: 68, height: 10), normal: sprite(.volume, 0, 0, 68, 420), pressed: sprite(.volume, 15, 422, 14, 11), active: sprite(.volume, 0, 422, 14, 11), activePressed: nil, action: .setVolume)
    ]

    /// Winamp's VOLUME.BMP contains 28 68x10 track frames on a 15-pixel
    /// stride, followed by the two 14x11 thumbs.  The track frame is selected
    /// independently of the thumb state; this is the same atlas contract used
    /// by the Classic player and avoids stretching the complete 68x420 strip.
    static let volumeTrackFrameCount = 28
    static let volumeTrackStride: CGFloat = 15
    static let volumeTrackHeight: CGFloat = 10

    static func seekPlacement(progress: Double, pressed: Bool) -> ClassicSliderPlacement? {
        guard let descriptor = main[.seek],
              let thumb = (pressed ? descriptor.pressed : descriptor.active) ?? descriptor.pressed else { return nil }
        let normalized = min(max(progress, 0), 1)
        let thumbSize = thumb.sourceRect.size
        let x = descriptor.frame.minX + normalized * max(0, descriptor.frame.width - thumbSize.width)
        let thumbFrame = CGRect(x: x, y: descriptor.frame.minY, width: thumbSize.width, height: thumbSize.height)
        return ClassicSliderPlacement(track: descriptor.normal, thumb: thumb, thumbFrame: thumbFrame)
    }

    static func volumePlacement(value: Double, pressed: Bool) -> ClassicSliderPlacement? {
        guard let descriptor = main[.volume],
              let thumb = (pressed ? descriptor.pressed : descriptor.active) ?? descriptor.pressed else { return nil }
        let normalized = min(max(value, 0), 1)
        // The first visible frame is the quietest frame.  Winamp's original
        // CSS/skin tables address the 28 frames as round(value * 28) - 1;
        // clamping makes the zero endpoint deterministic as well.
        let frameIndex = min(
            volumeTrackFrameCount - 1,
            max(0, Int((normalized * Double(volumeTrackFrameCount)).rounded()) - 1)
        )
        let trackSource = descriptor.normal.sourceRect.offsetBy(dx: 0, dy: CGFloat(frameIndex) * volumeTrackStride)
        let thumbSize = thumb.sourceRect.size
        let x = descriptor.frame.minX + normalized * max(0, descriptor.frame.width - thumbSize.width)
        let thumbFrame = CGRect(x: x, y: descriptor.frame.minY, width: thumbSize.width, height: thumbSize.height)
        return ClassicSliderPlacement(
            track: SpriteReference(assetName: descriptor.normal.assetName, sourceRect: CGRect(x: trackSource.minX, y: trackSource.minY, width: trackSource.width, height: volumeTrackHeight)),
            thumb: thumb,
            thumbFrame: thumbFrame
        )
    }
}

struct SkinValidationReport: Equatable, Sendable {
    var errors: [String] = []
    var warnings: [String] = []
    var isValid: Bool { errors.isEmpty }
}

enum SkinFormat: String, Codable, Sendable {
    case classic
    case modern

    var displayName: String { self == .classic ? "Classic" : "Modern (safe subset)" }
}

enum ModernDrawerRole: String, CaseIterable, Hashable, Sendable {
    case left, right
}

struct ModernDrawerDescriptor: Sendable {
    var role: ModernDrawerRole
    var expandedFrame: CGRect
    var collapsedOrigin: CGPoint
}

struct ModernWindowRegionShape: Sendable, Equatable {
    var frame: CGRect
    var additive: Bool
    var drawerRole: ModernDrawerRole? = nil
}

struct ModernWindowRegionDescriptor: Sendable, Equatable {
    var shapes: [ModernWindowRegionShape] = []
    var desktopAlpha = false
    var usesBitmapAlpha = false
}

struct ModernMakiBinding: Sendable, Equatable {
    var path: String
    var groupID: String
    var parameter: String?
}

/// The stable object identity exposed to MAKI.  Keeping this separate from the
/// renderer's flattened arrays is important: scripts address Wasabi objects,
/// not pixels or the native controls that happen to render them.
nonisolated enum WasabiObjectKind: String, Sendable {
    case container, layout, group, button, slider, layer, animatedLayer, text, songTicker, content, unknown
}

nonisolated struct WasabiObjectNode: Sendable, Equatable {
    var id: String
    var kind: WasabiObjectKind
    var frame: CGRect
    var parentID: String?
    var children: [String] = []
    var initiallyVisible = true
    var attributes: [String: String] = [:]
    var zIndex: Int = 0
}

nonisolated struct WasabiObjectTree: Sendable, Equatable {
    var rootID: String = "main"
    private(set) var nodes: [String: WasabiObjectNode] = [:]

    init() {}

    mutating func insert(_ node: WasabiObjectNode) {
        let key = node.id.lowercased()
        var value = node
        value.id = key
        nodes[key] = value
        if let parentID = value.parentID?.lowercased(), nodes[parentID] != nil,
           !nodes[parentID]!.children.contains(key) {
            nodes[parentID]!.children.append(key)
        }
    }

    func object(id: String) -> WasabiObjectNode? { nodes[id.lowercased()] }

    func hitTest(_ point: CGPoint, visible: (WasabiObjectNode) -> Bool = { $0.initiallyVisible }) -> WasabiObjectNode? {
        nodes.values
            .filter { $0.kind != .container && $0.kind != .layout && $0.kind != .group && $0.frame.contains(point) && visible($0) }
            .sorted { $0.zIndex > $1.zIndex }
            .first
    }

    var objectCount: Int { nodes.count }
    var eventObjectIDs: [String] { nodes.values.filter { $0.kind == .button || $0.kind == .slider || $0.kind == .layer }.map(\.id).sorted() }
}

/// A live, value-semantic Wasabi scene. Nodes retain local geometry and
/// ownership; world geometry is resolved by walking the same parent chain used
/// by rendering, hit testing and (in the next runtime migration) MAKI.
nonisolated struct WasabiHandle: Hashable, Sendable, Equatable {
    let rawValue: UInt64
}

nonisolated struct WasabiSceneNode: Sendable, Equatable {
    let handle: WasabiHandle
    var id: String
    var originalID: String
    var kind: WasabiObjectKind
    var localFrame: CGRect
    var parent: WasabiHandle?
    var children: [WasabiHandle] = []
    var visible = true
    var alpha: CGFloat = 1
    var ghost = false
    var zIndex = 0
    var attributes: [String: String] = [:]
}

nonisolated struct WasabiScene: Sendable, Equatable {
    private(set) var nodes: [WasabiHandle: WasabiSceneNode] = [:]
    private(set) var handlesByID: [String: [WasabiHandle]] = [:]
    private(set) var rootHandles: [WasabiHandle] = []
    private(set) var activeLayoutByContainer: [WasabiHandle: WasabiHandle] = [:]
    private var nextRawHandle: UInt64 = 1

    var allNodes: [WasabiSceneNode] {
        nodes.values.sorted { $0.handle.rawValue < $1.handle.rawValue }
    }

    init() {}

    @discardableResult
    mutating func addNode(
        id rawID: String,
        kind: WasabiObjectKind,
        localFrame: CGRect,
        parent: WasabiHandle? = nil,
        visible: Bool = true,
        alpha: CGFloat = 1,
        ghost: Bool = false,
        zIndex: Int = 0,
        attributes: [String: String] = [:]
    ) -> WasabiHandle {
        let handle = WasabiHandle(rawValue: nextRawHandle)
        nextRawHandle += 1
        let originalID = rawID.isEmpty ? "node-\(handle.rawValue)" : rawID
        let id = originalID.lowercased()
        let node = WasabiSceneNode(
            handle: handle,
            id: id,
            originalID: originalID,
            kind: kind,
            localFrame: localFrame,
            parent: parent,
            visible: visible,
            alpha: min(max(alpha, 0), 1),
            ghost: ghost,
            zIndex: zIndex,
            attributes: attributes
        )
        nodes[handle] = node
        handlesByID[id, default: []].append(handle)
        if let parent, nodes[parent] != nil {
            nodes[parent]!.children.append(handle)
        } else {
            rootHandles.append(handle)
        }
        return handle
    }

    func node(_ handle: WasabiHandle) -> WasabiSceneNode? { nodes[handle] }

    func handles(for id: String) -> [WasabiHandle] { handlesByID[id.lowercased()] ?? [] }

    func firstHandle(for id: String) -> WasabiHandle? { handles(for: id).first }

    func worldFrame(of handle: WasabiHandle) -> CGRect? {
        worldFrame(of: handle, visiting: [])
    }

    private func worldFrame(of handle: WasabiHandle, visiting: Set<WasabiHandle>) -> CGRect? {
        guard let node = nodes[handle], !visiting.contains(handle) else { return nil }
        var next = visiting
        next.insert(handle)
        guard let parent = node.parent, let parentFrame = worldFrame(of: parent, visiting: next) else {
            return node.localFrame
        }
        return node.localFrame.offsetBy(dx: parentFrame.minX, dy: parentFrame.minY)
    }

    func effectiveVisible(_ handle: WasabiHandle) -> Bool {
        guard let node = nodes[handle] else { return false }
        guard node.visible else { return false }
        guard let parent = node.parent else { return true }
        return effectiveVisible(parent)
    }

    func effectiveAlpha(_ handle: WasabiHandle) -> CGFloat {
        guard let node = nodes[handle] else { return 0 }
        guard let parent = node.parent else { return node.alpha }
        return node.alpha * effectiveAlpha(parent)
    }

    mutating func setLocalFrame(_ frame: CGRect, for handle: WasabiHandle) {
        guard var node = nodes[handle] else { return }
        node.localFrame = frame
        nodes[handle] = node
    }

    mutating func setVisible(_ visible: Bool, for handle: WasabiHandle) {
        guard var node = nodes[handle] else { return }
        node.visible = visible
        nodes[handle] = node
    }

    mutating func setActiveLayout(_ layout: WasabiHandle, for container: WasabiHandle) {
        guard nodes[layout]?.kind == .layout, nodes[container]?.kind == .container else { return }
        activeLayoutByContainer[container] = layout
    }

    func isInActiveLayout(_ handle: WasabiHandle) -> Bool {
        var cursor = handle
        var visited: Set<WasabiHandle> = []
        while let node = nodes[cursor], !visited.contains(cursor) {
            visited.insert(cursor)
            if node.kind == .layout, let container = node.parent {
                return activeLayoutByContainer[container].map { $0 == node.handle } ?? true
            }
            guard let parent = node.parent else { return true }
            cursor = parent
        }
        return false
    }

    func hitTest(_ point: CGPoint) -> WasabiSceneNode? {
        nodes.values
            .filter { node in
                node.kind != .container && node.kind != .layout && node.kind != .group &&
                !node.ghost && effectiveVisible(node.handle) && effectiveAlpha(node.handle) > 0 &&
                isInActiveLayout(node.handle) && (worldFrame(of: node.handle)?.contains(point) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
                return lhs.handle.rawValue > rhs.handle.rawValue
            }
            .first
    }

    /// Compatibility projection for the pre-#35 callers. It intentionally
    /// derives from the live hierarchy rather than making the old dictionary
    /// authoritative.
    var compatibilityTree: WasabiObjectTree {
        var tree = WasabiObjectTree()
        if let root = rootHandles.first, let rootNode = nodes[root] { tree.rootID = rootNode.id }
        for node in nodes.values {
            let parentID = node.parent.flatMap { nodes[$0]?.id }
            tree.insert(WasabiObjectNode(
                id: node.id,
                kind: node.kind,
                frame: worldFrame(of: node.handle) ?? node.localFrame,
                parentID: parentID,
                initiallyVisible: effectiveVisible(node.handle),
                attributes: node.attributes,
                zIndex: node.zIndex
            ))
        }
        return tree
    }
}

nonisolated struct ModernLayoutDescriptor: Sendable, Equatable {
    var id: String
    var frame: CGRect
    var containerID: String
    var initiallyVisible: Bool
}

nonisolated struct ClassicSkinAssetDescriptor: Sendable, Equatable {
    var main: String = "main.bmp"
    var controls: String? = "cbuttons.bmp"
    var shuffleRepeat: String? = "shufrep.bmp"
    var volume: String? = "volume.bmp"
    var balance: String? = "balance.bmp"
    var position: String? = "posbar.bmp"
    var numbers: String? = "numbers.bmp"
    var extendedNumbers: String? = "nums_ex.bmp"
    var playPause: String? = "playpaus.bmp"
    var monoStereo: String? = "monoster.bmp"
    var equalizer: String? = "eqmain.bmp"
    var equalizerExtended: String? = "eq_ex.bmp"
    var playlist: String? = "pledit.bmp"
    var playlistText: String? = "pledit.txt"
    var text: String? = "text.bmp"

    func availableFiles(in files: [String: Data]) -> Set<String> {
        Set(files.keys.map { ($0 as NSString).lastPathComponent.lowercased() })
    }
}

nonisolated struct WasabiCompatibilityReport: Sendable, Equatable {
    var objectCounts: [String: Int] = [:]
    var boundMakiPrograms: [String] = []
    var unsupportedHostCalls: [String] = []
    var unsupportedOpcodes: [String] = []
    var interactiveObjectsWithoutBehavior: [String] = []
    var registeredEvents: [String] = []
    var targetAnimations: [String] = []
}

struct ModernSkinLayer: Sendable {
    var imageID: String
    var frame: CGRect
    var elementID: String? = nil
    var opacity: Double = 1
    var cropToFirstFrame = false
    var action: SkinAction? = nil
    var initiallyVisible = true
    var drawerRole: ModernDrawerRole? = nil
    var sysRegion: Int? = nil

    var isSystemRegion: Bool { sysRegion != nil && sysRegion != 0 }
}

enum ModernSkinTextRole: Sendable {
    case songTitle, elapsedTime, remainingTime, bitrate, frequency, channels, fileExtension
}

struct ModernSkinTextRegion: Sendable {
    var role: ModernSkinTextRole
    var frame: CGRect
    var elementID: String? = nil
    var initiallyVisible = true
    var fontSize: Double
    var red: Double
    var green: Double
    var blue: Double
    var alignment: String
    var drawerRole: ModernDrawerRole? = nil
}

enum ModernSkinContentRole: Sendable {
    case albumArt, visualization, playlist
}

struct ModernSkinContentRegion: Sendable {
    var role: ModernSkinContentRole
    var frame: CGRect
    var elementID: String? = nil
    var initiallyVisible = true
    var drawerRole: ModernDrawerRole? = nil
}

struct ModernSkinDescriptor: Sendable {
    var name: String?
    var author: String?
    var screenshotPath: String?
    var canvasSize: CGSize = CGSize(width: 275, height: 116)
    var bitmapFiles: [String: String] = [:]
    var bitmapSourceRects: [String: CGRect] = [:]
    var layers: [ModernSkinLayer] = []
    var controls: [SkinControlDefinition] = []
    var textRegions: [ModernSkinTextRegion] = []
    var contentRegions: [ModernSkinContentRegion] = []
    var drawers: [ModernDrawerDescriptor] = []
    var makiBindings: [ModernMakiBinding] = []
    var layouts: [ModernLayoutDescriptor] = []
    var scene = WasabiScene()
    var objectTree = WasabiObjectTree()
    var windowRegion: ModernWindowRegionDescriptor?
}

struct LoadedSkinArchive: Sendable {
    var format: SkinFormat
    var files: [String: Data]
    var report: SkinValidationReport
    var modern: ModernSkinDescriptor?
}

struct ImportedSkin: Identifiable, Sendable {
    var id: String
    var name: String
    var directory: URL
    var originalArchive: URL
    var format: SkinFormat
    var report: SkinValidationReport
}

@MainActor
final class SkinAssetCatalog {
    let name: String
    let images: [String: NSImage]
    let report: SkinValidationReport
    let regionPath: NSBezierPath?
    let format: SkinFormat
    let canvasSize: CGSize
    let controls: [SkinControlDefinition]
    let textRegions: [ModernSkinTextRegion]
    let contentRegions: [ModernSkinContentRegion]
    let drawers: [ModernDrawerDescriptor]
    let makiPrograms: [MakiProgram]
    let makiBindings: [ModernMakiBinding]
    let makiControlImages: [String: NSImage]
    let drawerImages: [ModernDrawerRole: NSImage]
    let modernBaseImage: NSImage?
    let modernOcclusionFrame: CGRect?
    let modernWindowUsesBitmapAlpha: Bool
    let modernLayers: [ModernSkinLayer]
    let modernBitmapFiles: [String: String]
    let modernBitmapSourceRects: [String: CGRect]
    let modernLayouts: [ModernLayoutDescriptor]
    let scene: WasabiScene
    let objectTree: WasabiObjectTree
    let classicAssets: ClassicSkinAssetDescriptor?
    private let renderedMainImage: NSImage?

    var mainImage: NSImage? { renderedMainImage }

    init(name: String, files: [String: Data], report: SkinValidationReport, format: SkinFormat = .classic, modern: ModernSkinDescriptor? = nil) {
        self.name = name
        self.report = report
        self.format = format
        let loadedImages = files.reduce(into: [String: NSImage]()) { result, pair in
            let imageExtensions: Set<String> = ["bmp", "png", "jpg", "jpeg", "gif", "tif", "tiff"]
            guard imageExtensions.contains((pair.key as NSString).pathExtension.lowercased()) else { return }
            if let image = Self.safeImage(data: pair.value, applyChromaKey: format == .classic) {
                result[pair.key.lowercased()] = image
            }
        }
        images = loadedImages
        if format == .modern, let modern {
            if modern.layers.isEmpty, let screenshot = modern.screenshotPath, let image = loadedImages[screenshot.lowercased()] {
                canvasSize = image.size
            } else {
                canvasSize = modern.canvasSize
            }
            let resolvedControls = modern.controls.map { control in
                var frame = control.frame
                if let imageID = control.normalSprite?.assetName,
                   let path = modern.bitmapFiles[imageID.lowercased()], let image = loadedImages[path.lowercased()] {
                    let source = modern.bitmapSourceRects[imageID.lowercased()]
                    if frame.width <= 0 { frame.size.width = source?.width ?? image.size.width }
                    if frame.height <= 0 { frame.size.height = source?.height ?? image.size.height }
                }
                return SkinControlDefinition(
                    id: control.id,
                    frame: frame,
                    normalSprite: control.normalSprite,
                    pressedSprite: control.pressedSprite,
                    disabledSprite: control.disabledSprite,
                    action: control.action,
                    elementID: control.elementID,
                    initiallyVisible: control.initiallyVisible,
                    drawerRole: control.drawerRole,
                    parameter: control.parameter,
                    orientation: control.orientation
                )
            }
            controls = resolvedControls
            textRegions = modern.textRegions
            contentRegions = modern.contentRegions
            drawers = modern.drawers
            modernLayers = modern.layers
            modernBitmapFiles = modern.bitmapFiles
            modernBitmapSourceRects = modern.bitmapSourceRects
            modernLayouts = modern.layouts
            scene = modern.scene
            objectTree = modern.scene.compatibilityTree
            classicAssets = nil
            makiBindings = modern.makiBindings
            makiPrograms = Array(Set(modern.makiBindings.map { $0.path.lowercased() })).sorted().compactMap { path in
                files[path].flatMap { try? MakiDecoder.decode($0, path: path) }
            }
            makiControlImages = Dictionary(resolvedControls.compactMap { control in
                guard let elementID = control.elementID?.lowercased(),
                      let imageID = control.normalSprite?.assetName.lowercased(),
                      let image = Self.renderedSprite(
                        imageID: imageID,
                        size: control.orientation == nil ? control.frame.size : .zero,
                        descriptor: modern,
                        images: loadedImages
                      ) else { return nil }
                return (elementID, image)
            }, uniquingKeysWith: { first, _ in first })
            let occlusionFrames = modern.layers
                .filter { $0.drawerRole == nil && ($0.sysRegion ?? 0) > 0 }
                .compactMap { Self.resolvedFrame(for: $0, descriptor: modern, images: loadedImages) }
            modernOcclusionFrame = occlusionFrames.reduce(nil as CGRect?) { partial, frame in
                partial.map { $0.union(frame) } ?? frame
            }
            modernWindowUsesBitmapAlpha = modern.windowRegion?.usesBitmapAlpha ?? false
            // With desktopalpha, native bitmap alpha is the silhouette. The
            // sysregion shapes remain useful for occlusion but must not clip the
            // alpha-backed window down to their small bounding rectangles.
            let windowRegionPath = modern.windowRegion.flatMap { $0.usesBitmapAlpha ? nil : Self.regionPath($0) }
            regionPath = windowRegionPath
            renderedMainImage = Self.renderModern(
                modern,
                images: loadedImages,
                layers: modern.layers.filter(\.initiallyVisible),
                allowScreenshotFallback: true,
                clipPath: windowRegionPath
            ) ?? NSImage(size: canvasSize, flipped: true) { _ in true }
            modernBaseImage = Self.renderModern(
                modern,
                images: loadedImages,
                layers: modern.layers.filter { $0.drawerRole == nil && $0.elementID == nil && $0.initiallyVisible }
            ) ?? NSImage(size: canvasSize, flipped: true) { _ in true }
            drawerImages = Dictionary(uniqueKeysWithValues: ModernDrawerRole.allCases.compactMap { role in
                Self.renderModern(modern, images: loadedImages, layers: modern.layers.filter { $0.drawerRole == role && $0.elementID == nil && $0.initiallyVisible }).map { (role, $0) }
            })
        } else {
            canvasSize = CGSize(width: 275, height: 116)
            let classic = ClassicSkinControls.main.map { control -> SkinControlDefinition in
                let descriptor = ClassicSpriteCatalog.main[control.id]
                return SkinControlDefinition(id: control.id, frame: control.frame, normalSprite: descriptor?.normal, pressedSprite: descriptor?.pressed, disabledSprite: control.disabledSprite, action: control.action, elementID: control.elementID, initiallyVisible: control.initiallyVisible, drawerRole: control.drawerRole, parameter: control.parameter, orientation: control.orientation)
            }
            controls = classic
            textRegions = []
            contentRegions = []
            drawers = []
            modernLayers = []
            modernBitmapFiles = [:]
            modernBitmapSourceRects = [:]
            modernLayouts = []
            scene = WasabiScene()
            objectTree = WasabiObjectTree()
            classicAssets = ClassicSkinAssetDescriptor()
            makiPrograms = []
            makiBindings = []
            makiControlImages = [:]
            drawerImages = [:]
            modernBaseImage = nil
            modernOcclusionFrame = nil
            modernWindowUsesBitmapAlpha = false
            let regionData = Self.file(named: "region.txt", in: files)
            regionPath = regionData.flatMap(RegionParser.parse)
            renderedMainImage = Self.image(named: "main.bmp", in: loadedImages)
        }
    }

    private static func file(named name: String, in files: [String: Data]) -> Data? {
        files.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame || key.lowercased().hasSuffix("/\(name.lowercased())")
        }?.value
    }

    private static func safeImage(data: Data, applyChromaKey: Bool) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 32_000_000 else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if applyChromaKey, let masked = applyWinampChromaKey(to: cgImage) {
            let maskedImage = NSImage(cgImage: masked, size: CGSize(width: width, height: height))
            maskedImage.size = CGSize(width: width, height: height)
            return maskedImage
        }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
        // Winamp XML coordinates are always physical asset pixels. NSImage otherwise
        // converts PNGs carrying (for example) 96-DPI metadata into smaller AppKit
        // point sizes, which separates the bitmap from its XML-positioned controls.
        image.size = CGSize(width: width, height: height)
        return image
    }

    private static func image(named name: String, in images: [String: NSImage]) -> NSImage? {
        images[name] ?? images.first { $0.key.hasSuffix("/\(name)") }?.value
    }

    private static func renderedSprite(
        imageID: String,
        size requestedSize: CGSize,
        descriptor: ModernSkinDescriptor,
        images: [String: NSImage]
    ) -> NSImage? {
        guard let path = descriptor.bitmapFiles[imageID], let sourceImage = images[path.lowercased()] else { return nil }
        let source = descriptor.bitmapSourceRects[imageID]
        let size = CGSize(
            width: requestedSize.width > 0 ? requestedSize.width : source?.width ?? sourceImage.size.width,
            height: requestedSize.height > 0 ? requestedSize.height : source?.height ?? sourceImage.size.height
        )
        guard size.width > 0, size.height > 0 else { return nil }
        return NSImage(size: size, flipped: true) { rect in
            let sourceRect = source.map {
                CGRect(x: $0.minX, y: sourceImage.size.height - $0.maxY, width: $0.width, height: $0.height)
            } ?? CGRect(origin: .zero, size: sourceImage.size)
            sourceImage.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            return true
        }
    }

    private static func renderModern(
        _ descriptor: ModernSkinDescriptor,
        images: [String: NSImage],
        layers: [ModernSkinLayer],
        allowScreenshotFallback: Bool = false,
        clipPath: NSBezierPath? = nil
    ) -> NSImage? {
        if layers.isEmpty, allowScreenshotFallback, let screenshot = descriptor.screenshotPath {
            return images[screenshot.lowercased()]
        }
        guard !layers.isEmpty else { return nil }
        return NSImage(size: descriptor.canvasSize, flipped: true) { _ in
            NSGraphicsContext.current?.imageInterpolation = .none
            clipPath?.addClip()
            var renderedControlFrames: [CGRect] = []
            for layer in layers {
                guard layer.initiallyVisible else { continue }
                if layer.action != nil, renderedControlFrames.contains(layer.frame.integral) { continue }
                guard let path = descriptor.bitmapFiles[layer.imageID.lowercased()], let image = images[path.lowercased()] else { continue }
                guard let frame = resolvedFrame(for: layer, descriptor: descriptor, images: images) else { continue }
                let source = descriptor.bitmapSourceRects[layer.imageID.lowercased()]
                let sourceRect: CGRect
                if let source {
                    sourceRect = CGRect(x: source.minX, y: image.size.height - source.maxY, width: source.width, height: source.height)
                } else if layer.cropToFirstFrame, frame.width > 0, frame.height > 0,
                          image.size.width >= frame.width, image.size.height >= frame.height {
                    sourceRect = CGRect(x: 0, y: image.size.height - frame.height, width: frame.width, height: frame.height)
                } else {
                    sourceRect = CGRect(origin: .zero, size: image.size)
                }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let renderedImage = sourceRect == CGRect(origin: .zero, size: image.size)
                    ? cgImage
                    : cgImage.cropping(to: sourceRect) ?? cgImage
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState()
                context?.interpolationQuality = .none
                context?.setAlpha(CGFloat(layer.opacity))
                context?.draw(renderedImage, in: frame)
                context?.restoreGState()
                if layer.action != nil { renderedControlFrames.append(layer.frame.integral) }
            }
            return true
        }
    }

    private static func regionPath(_ descriptor: ModernWindowRegionDescriptor) -> NSBezierPath? {
        guard !descriptor.shapes.isEmpty else { return nil }
        let path = NSBezierPath()
        path.windingRule = .nonZero
        for shape in descriptor.shapes where !shape.frame.isEmpty {
            let frame = shape.frame
            let points: [CGPoint] = shape.additive
                ? [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
                : [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.minY)]
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
        }
        return path.isEmpty ? nil : path
    }

    private static func resolvedFrame(
        for layer: ModernSkinLayer,
        descriptor: ModernSkinDescriptor,
        images: [String: NSImage]
    ) -> CGRect? {
        guard let path = descriptor.bitmapFiles[layer.imageID.lowercased()],
              let image = images[path.lowercased()] else { return nil }
        var frame = layer.frame
        let source = descriptor.bitmapSourceRects[layer.imageID.lowercased()]
        if frame.width <= 0 { frame.size.width = source?.width ?? image.size.width }
        if frame.height <= 0 { frame.size.height = source?.height ?? image.size.height }
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    static func fallback() -> SkinAssetCatalog {
        let size = NSSize(width: 275, height: 116)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.16, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.34, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 275, height: 14).fill()
            NSColor(calibratedRed: 0.25, green: 0.9, blue: 0.46, alpha: 1).setStroke()
            let bezel = NSBezierPath(rect: NSRect(x: 4.5, y: 18.5, width: 266, height: 91)); bezel.lineWidth = 1; bezel.stroke()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let bmp = rep.representation(using: .bmp, properties: [:]) else {
            return SkinAssetCatalog(name: "Macamp Night", files: [:], report: .init(errors: ["Fallback image generation failed."]))
        }
        return SkinAssetCatalog(name: "Macamp Night", files: ["main.bmp": bmp], report: .init())
    }
}

func applyWinampChromaKey(to image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = width * 4
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    for index in stride(from: 0, to: width * height * 4, by: 4) {
        let isMagenta = pixels[index] == 255 && pixels[index + 1] == 0 && pixels[index + 2] == 255
        if isMagenta {
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = 0
        }
    }
    return context.makeImage()
}

enum ClassicSkinControls {
    static let main: [SkinControlDefinition] = [
        .init(id: .previous, frame: CGRect(x: 16, y: 88, width: 23, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .previous),
        .init(id: .play, frame: CGRect(x: 39, y: 88, width: 23, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .play),
        .init(id: .pause, frame: CGRect(x: 62, y: 88, width: 23, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .pause),
        .init(id: .stop, frame: CGRect(x: 85, y: 88, width: 23, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .stop),
        .init(id: .next, frame: CGRect(x: 108, y: 88, width: 22, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .next),
        .init(id: .open, frame: CGRect(x: 136, y: 89, width: 22, height: 16), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .open),
        .init(id: .seek, frame: CGRect(x: 16, y: 72, width: 248, height: 10), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .seek),
        .init(id: .volume, frame: CGRect(x: 107, y: 57, width: 68, height: 10), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .setVolume),
        .init(id: .shuffle, frame: CGRect(x: 164, y: 89, width: 47, height: 15), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .toggleShuffle),
        .init(id: .repeat, frame: CGRect(x: 210, y: 89, width: 28, height: 15), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .cycleRepeat),
        .init(id: .equalizer, frame: CGRect(x: 219, y: 58, width: 23, height: 12), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .toggleEqualizer),
        .init(id: .playlist, frame: CGRect(x: 242, y: 58, width: 23, height: 12), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .togglePlaylist),
        .init(id: .visualization, frame: CGRect(x: 24, y: 43, width: 72, height: 16), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .toggleVisualization)
    ]
}

@MainActor
extension SkinAssetCatalog {
    func compatibilitySmokeReport(runtime: MakiRuntime? = nil) -> WasabiCompatibilityReport {
        var counts: [String: Int] = [:]
        for node in objectTree.nodes.values { counts[node.kind.rawValue, default: 0] += 1 }
        let behavioralIDs = Set(controls.compactMap { $0.elementID?.lowercased() })
        let interactiveWithoutBehavior = objectTree.eventObjectIDs.filter { !behavioralIDs.contains($0.lowercased()) && makiPrograms.isEmpty }
        return WasabiCompatibilityReport(
            objectCounts: counts,
            boundMakiPrograms: makiPrograms.map(\.path).sorted(),
            unsupportedHostCalls: runtime?.diagnostics.filter { $0.contains("host call") } ?? [],
            unsupportedOpcodes: runtime?.diagnostics.filter { $0.contains("opcode") } ?? [],
            interactiveObjectsWithoutBehavior: interactiveWithoutBehavior,
            registeredEvents: runtime?.registeredEventNames ?? [],
            targetAnimations: runtime?.targetAnimationObjectIDs ?? []
        )
    }
}
