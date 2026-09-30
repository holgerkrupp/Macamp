import AppKit

/// The product/window identity that Macamp owns.  Compatibility terminology
/// such as ``WinampSkinKit`` and ``Winamp-compatible`` deliberately stays out
/// of this model: those names describe the file format, not the product shown
/// to the user.
enum MacampWindowBranding: Sendable, Equatable {
    case player
    case playlist
    case equalizer

    var title: String {
        switch self {
        case .player: "MACAMP"
        case .playlist: "MACAMP PLAYLIST"
        case .equalizer: "MACAMP EQUALIZER"
        }
    }
}

enum SkinTextSemantic: Sendable, Equatable {
    case branding
    case staticUI
    case mediaMetadata
    case technical
}

enum BrandingText {
    /// Rebrands text at the final UI boundary. Source XML, MAKI bytecode,
    /// identifiers, file paths, image resources and media metadata are never
    /// rewritten by this helper.
    static func replacingWinamp(in value: String) -> String {
        replacingWinamp(in: value, semantic: .branding)
    }

    static func replacingWinamp(in value: String, semantic: SkinTextSemantic) -> String {
        guard semantic == .branding || semantic == .staticUI else { return value }
        return value.replacingOccurrences(
            of: "winamp",
            with: "Macamp",
            options: [.caseInsensitive]
        )
    }
}

enum ClassicBrandedWindow: Sendable, Equatable {
    case main
    case playlist
    case equalizer

    var branding: MacampWindowBranding {
        switch self {
        case .main: .player
        case .playlist: .playlist
        case .equalizer: .equalizer
        }
    }
}

struct ClassicBrandingLayout: Sendable, Equatable {
    let titleRect: CGRect
    let alignment: NSTextAlignment
}

/// Canonical title geometry for Classic chrome. These rectangles are layout
/// data, not an attempt to recognize arbitrary bitmap artwork.
enum ClassicBrandingRenderer {
    static func layout(
        for window: ClassicBrandedWindow,
        size: CGSize,
        shaded: Bool = false
    ) -> ClassicBrandingLayout {
        switch window {
        case .main:
            ClassicBrandingLayout(
                titleRect: CGRect(x: 34, y: 0, width: max(0, size.width - 68), height: min(14, size.height)),
                alignment: .center
            )
        case .playlist:
            if shaded {
                ClassicBrandingLayout(
                    titleRect: CGRect(x: 25, y: 0, width: max(0, size.width - 75), height: min(14, size.height)),
                    alignment: .center
                )
            } else {
                ClassicBrandingLayout(
                    titleRect: CGRect(x: max(0, (size.width - 100) / 2), y: 0, width: min(100, size.width), height: min(20, size.height)),
                    alignment: .center
                )
            }
        case .equalizer:
            ClassicBrandingLayout(
                titleRect: CGRect(x: 30, y: 0, width: max(0, size.width - 60), height: min(14, size.height)),
                alignment: .center
            )
        }
    }

    /// Paints a title over the skin's existing chrome. The background is
    /// reconstructed by tiling a narrow adjacent/edge strip of the same
    /// chrome, so the imported atlas remains unchanged and controls outside
    /// the title region retain their original pixels.
    @MainActor
    static func draw(
        window: ClassicBrandedWindow,
        layout: ClassicBrandingLayout,
        sourceRect: CGRect,
        destinationRect: CGRect,
        drawSprite: (CGRect, CGRect) -> Bool,
        drawTextSprite: (Character, CGRect) -> Bool
    ) {
        guard !layout.titleRect.isEmpty, !sourceRect.isEmpty, !destinationRect.isEmpty else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: layout.titleRect).addClip()

        let sourcePerDestinationX = sourceRect.width / max(1, destinationRect.width)
        let titleLocalMinX = max(0, layout.titleRect.minX - destinationRect.minX)
        let sampleWidth = min(8, sourceRect.width)
        let sampleX: CGFloat
        if titleLocalMinX >= sampleWidth {
            // Use the clean edge of the semantic title region. Sampling the
            // source origin would copy the Classic menu/icon controls into
            // every tile of the replacement background.
            sampleX = min(
                sourceRect.maxX - sampleWidth,
                sourceRect.minX + titleLocalMinX * sourcePerDestinationX
            )
        } else {
            sampleX = sourceRect.maxX - sampleWidth
        }
        let sample = CGRect(x: sampleX, y: sourceRect.minY, width: sampleWidth, height: sourceRect.height)
        let destinationSampleWidth = max(1, sample.width / max(0.001, sourcePerDestinationX))
        var x = layout.titleRect.minX
        while x < layout.titleRect.maxX {
            let width = min(destinationSampleWidth, layout.titleRect.maxX - x)
            let fraction = width / max(0.001, destinationSampleWidth)
            let sourceWidth = max(0.001, sample.width * fraction)
            _ = drawSprite(
                CGRect(x: sample.minX, y: sample.minY, width: sourceWidth, height: sample.height),
                CGRect(x: x, y: layout.titleRect.minY, width: width, height: layout.titleRect.height)
            )
            x += width
        }

        let title = window.branding.title
        let glyphWidth: CGFloat = 5
        let glyphHeight = min(6, max(1, layout.titleRect.height - 2))
        let titleWidth = CGFloat(title.count) * glyphWidth
        let startX: CGFloat = switch layout.alignment {
        case .center: layout.titleRect.midX - titleWidth / 2
        case .right: layout.titleRect.maxX - titleWidth
        default: layout.titleRect.minX
        }
        let glyphY = layout.titleRect.midY - glyphHeight / 2
        var drewSkinGlyph = false
        for (index, character) in title.enumerated() {
            let frame = CGRect(x: startX + CGFloat(index) * glyphWidth, y: glyphY, width: glyphWidth, height: glyphHeight)
            drewSkinGlyph = drawTextSprite(character, frame) || drewSkinGlyph
        }
        if !drewSkinGlyph {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = layout.alignment
            title.draw(
                in: layout.titleRect,
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(6, layout.titleRect.height - 3), weight: .regular),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: paragraph
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
