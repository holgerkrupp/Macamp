import AppKit

/// A Wasabi bitmap font is a glyph table, not a native font face. The table
/// uses three rows: letters, punctuation/digits, and extended/fallback glyphs.
struct ModernBitmapFontResource: Sendable, Equatable {
    var id: String
    var imageID: String
    var filePath: String?
    var charWidth: Int
    var charHeight: Int
    var horizontalSpacing: Int
    var verticalSpacing: Int
}

struct ModernBitmapGlyphPlacement: Sendable, Equatable {
    var sourceRect: CGRect
    var destinationRect: CGRect
}

enum ModernBitmapFontPainter {
    /// Returns a source rectangle in the bitmap's top-left coordinate space.
    /// Keeping this mapping independent of AppKit makes the Wasabi table
    /// convention testable without relying on a particular display backend.
    static func sourceRect(
        for character: Character,
        resource: ModernBitmapFontResource,
        imageSize: CGSize
    ) -> CGRect? {
        guard resource.charWidth > 0, resource.charHeight > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scalar = character.unicodeScalars.first?.value ?? 0x20
        let location: (column: Int, row: Int)
        switch scalar {
        case 65...90: location = (Int(scalar - 65), 0) // A-Z
        case 97...122: location = (Int(scalar - 97), 0) // a-z share capitals
        case 32: location = (30, 0)
        case 48...57: location = (Int(scalar - 48), 1)
        case 46: location = (11, 1)
        case 58: location = (12, 1)
        case 40: location = (13, 1)
        case 41: location = (14, 1)
        case 45: location = (15, 1)
        case 39, 96: location = (16, 1)
        case 33: location = (17, 1)
        case 95: location = (18, 1)
        case 43: location = (19, 1)
        case 92: location = (20, 1)
        case 47: location = (21, 1)
        case 91, 123, 60: location = (22, 1)
        case 93, 125, 62: location = (23, 1)
        case 126, 94: location = (24, 1)
        case 38: location = (25, 1)
        case 37: location = (26, 1)
        case 44: location = (27, 1)
        case 61: location = (28, 1)
        case 36: location = (29, 1)
        case 0x00E4, 0x00C4: location = (0, 2)
        case 0x00F6, 0x00D6: location = (1, 2)
        case 0x00FC, 0x00DC: location = (2, 2)
        case 63: location = (3, 2)
        case 42: location = (4, 2)
        case 34: location = (26, 0)
        case 64: location = (27, 0)
        default: location = (30, 0)
        }

        let rect = CGRect(
            x: CGFloat(location.column * resource.charWidth),
            y: CGFloat(location.row * resource.charHeight),
            width: CGFloat(resource.charWidth),
            height: CGFloat(resource.charHeight)
        )
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        guard imageBounds.contains(rect) else { return nil }
        return rect
    }

    static func placements(
        for text: String,
        in frame: CGRect,
        resource: ModernBitmapFontResource,
        imageSize: CGSize,
        alignment: NSTextAlignment
    ) -> [ModernBitmapGlyphPlacement] {
        guard resource.charWidth > 0, resource.charHeight > 0 else { return [] }
        let scale = min(1, frame.height / CGFloat(resource.charHeight))
        guard scale > 0 else { return [] }
        let glyphWidth = CGFloat(resource.charWidth) * scale
        let glyphHeight = CGFloat(resource.charHeight) * scale
        let advance = CGFloat(resource.charWidth + resource.horizontalSpacing) * scale
        let textWidth = max(0, CGFloat(text.count) * advance - CGFloat(resource.horizontalSpacing) * scale)
        let startX: CGFloat = switch alignment {
        case .center: frame.minX + (frame.width - textWidth) / 2
        case .right: frame.maxX - textWidth
        default: frame.minX
        }
        let y = frame.minY + (frame.height - glyphHeight) / 2

        return text.enumerated().compactMap { index, character in
            guard let source = sourceRect(for: character, resource: resource, imageSize: imageSize) else { return nil }
            return ModernBitmapGlyphPlacement(
                sourceRect: source,
                destinationRect: CGRect(x: startX + CGFloat(index) * advance, y: y, width: glyphWidth, height: glyphHeight)
            )
        }
    }

    @MainActor
    static func draw(
        _ text: String,
        in frame: CGRect,
        image: NSImage,
        resource: ModernBitmapFontResource,
        alignment: NSTextAlignment,
        alpha: CGFloat
    ) {
        for placement in placements(for: text, in: frame, resource: resource, imageSize: image.size, alignment: alignment) {
            let appKitSource = CGRect(
                x: placement.sourceRect.minX,
                y: image.size.height - placement.sourceRect.maxY,
                width: placement.sourceRect.width,
                height: placement.sourceRect.height
            )
            image.draw(
                in: placement.destinationRect,
                from: appKitSource,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
    }
}
