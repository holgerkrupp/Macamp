import AppKit
import Foundation
import ImageIO

enum SkinAction: String, Sendable {
    case previous, play, pause, stop, next, open, seek, setVolume, setBalance
    case setEqualizerBand, resetEqualizer
    case toggleShuffle, cycleRepeat, togglePlaylist, toggleEqualizer, toggleVisualization
    case windowshade, minimize, close
}

enum SkinControlOrientation: Sendable {
    case horizontal, vertical
}

enum SkinControlID: String, Sendable {
    case previous, play, pause, stop, next, open, seek, volume, shuffle, `repeat`
    case playlist, equalizer, visualization, minimize, close
}

struct SpriteReference: Sendable {
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
            controls = ClassicSkinControls.main
            textRegions = []
            contentRegions = []
            drawers = []
            modernLayers = []
            modernBitmapFiles = [:]
            modernBitmapSourceRects = [:]
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
        .init(id: .next, frame: CGRect(x: 108, y: 88, width: 23, height: 18), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .next),
        .init(id: .open, frame: CGRect(x: 136, y: 89, width: 22, height: 16), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .open),
        .init(id: .seek, frame: CGRect(x: 16, y: 72, width: 248, height: 10), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .seek),
        .init(id: .volume, frame: CGRect(x: 107, y: 57, width: 68, height: 10), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .setVolume),
        .init(id: .shuffle, frame: CGRect(x: 164, y: 89, width: 46, height: 15), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .toggleShuffle),
        .init(id: .repeat, frame: CGRect(x: 210, y: 89, width: 28, height: 15), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .cycleRepeat),
        .init(id: .visualization, frame: CGRect(x: 24, y: 43, width: 72, height: 16), normalSprite: nil, pressedSprite: nil, disabledSprite: nil, action: .toggleVisualization)
    ]
}
