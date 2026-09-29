import AppKit
import SwiftUI

@MainActor
final class SkinWindowController: NSWindowController, NSWindowDelegate {
    private let settings: SettingsStore
    private let renderer: SkinRendererView
    private let auxiliaryWindows: SkinAuxiliaryWindowController

    init(
        coordinator: PlaybackCoordinator,
        skinStore: SkinLibraryStore,
        settings: SettingsStore,
        openMedia: @escaping () -> Void,
        visualizationToggle: @escaping () -> Void
    ) {
        self.settings = settings
        let auxiliaryWindows = SkinAuxiliaryWindowController(coordinator: coordinator, skinStore: skinStore)
        self.auxiliaryWindows = auxiliaryWindows
        let scale = settings.skinScale
        let canvas = skinStore.activeCatalog.canvasSize
        let size = CGSize(width: canvas.width * CGFloat(scale), height: canvas.height * CGFloat(scale))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = settings.playerShadow
        window.level = settings.playerFloating ? .floating : .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.title = "Classic Macamp Player"
        renderer = SkinRendererView(
            coordinator: coordinator,
            skinStore: skinStore,
            settings: settings,
            openMedia: openMedia,
            playlistToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.togglePlaylist() },
            equalizerToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.toggleEqualizer() },
            visualizationToggle: visualizationToggle
        )
        window.contentView = renderer
        super.init(window: window)
        window.delegate = self
        applyRegionMask()
        if let restored = settings.restoredPlayerFrame() { window.setFrame(Self.corrected(restored, size: size), display: false) }
        else { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) } else { showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    func applySettings() {
        guard let window else { return }
        renderer.updateScale(settings.skinScale)
        window.setContentSize(renderer.frame.size)
        applyRegionMask()
        window.hasShadow = settings.playerShadow
        window.level = settings.playerFloating ? .floating : .normal
    }

    func windowDidMove(_ notification: Notification) { if let frame = window?.frame { settings.savePlayerFrame(frame) } }

    private func applyRegionMask() {
        guard let window, let contentView = window.contentView else { return }
        guard let region = renderer.regionPath else {
            contentView.layer?.mask = nil
            return
        }
        contentView.wantsLayer = true
        let mask = CAShapeLayer()
        mask.fillRule = .nonZero
        let size = contentView.bounds.size
        var transform = CGAffineTransform(translationX: 0, y: size.height)
            .scaledBy(x: 1, y: -1)
        mask.path = region.cgPath.copy(using: &transform)
        mask.frame = contentView.bounds
        contentView.layer?.mask = mask
    }

    private static func corrected(_ frame: CGRect, size: CGSize) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let screen = screens.first(where: { $0.intersects(frame) }) ?? NSScreen.main?.visibleFrame else { return CGRect(origin: frame.origin, size: size) }
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width), y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }
}

@MainActor
private final class SkinAuxiliaryWindowController: NSObject, NSWindowDelegate {
    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    private var playlistPanel: NSPanel?
    private var equalizerPanel: NSPanel?
    private let docking = WindowDockingController()

    init(coordinator: PlaybackCoordinator, skinStore: SkinLibraryStore) {
        self.coordinator = coordinator
        self.skinStore = skinStore
    }

    func togglePlaylist() {
        if let playlistPanel, playlistPanel.isVisible {
            playlistPanel.orderOut(nil)
            return
        }
        let panel = playlistPanel ?? makePanel(
            title: "Macamp Playlist",
            size: skinStore.classicPanelSize(kind: .playlist, fallback: CGSize(width: 430, height: 360)),
            rootView: AnyView(SkinPlaylistView(coordinator: coordinator)),
            background: skinStore.classicPanelImage(kind: .playlist)
        )
        playlistPanel = panel
        present(panel)
    }

    func toggleEqualizer() {
        if let equalizerPanel, equalizerPanel.isVisible {
            equalizerPanel.orderOut(nil)
            return
        }
        let panel = equalizerPanel ?? makePanel(
            title: "Macamp Equalizer",
            size: skinStore.classicPanelSize(kind: .equalizer, fallback: CGSize(width: 460, height: 300)),
            rootView: AnyView(SkinEqualizerView(coordinator: coordinator)),
            background: skinStore.classicPanelImage(kind: .equalizer)
        )
        equalizerPanel = panel
        present(panel)
    }

    private func makePanel(title: String, size: CGSize, rootView: AnyView, background: NSImage?) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: min(360, size.width), height: min(240, size.height))
        let container = ClassicSkinPanelView(background: background)
        let hosted = NSHostingView(rootView: rootView)
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.wantsLayer = true
        hosted.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        panel.delegate = self
        panel.center()
        return panel
    }

    private func present(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        docking.update(panel: panel)
    }
}

private enum ClassicPanelKind { case equalizer, playlist }

private extension SkinLibraryStore {
    func classicPanelImage(kind: ClassicPanelKind) -> NSImage? {
        let name = kind == .equalizer ? activeCatalog.classicAssets?.equalizer : activeCatalog.classicAssets?.playlist
        guard let name else { return nil }
        return activeCatalog.images[name.lowercased()] ?? activeCatalog.images.first(where: { $0.key.hasSuffix("/\(name.lowercased())") })?.value
    }

    func classicPanelSize(kind: ClassicPanelKind, fallback: CGSize) -> CGSize {
        classicPanelImage(kind: kind)?.size ?? fallback
    }
}

private final class ClassicSkinPanelView: NSView {
    private let background: NSImage?

    init(background: NSImage?) {
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let background else { return }
        background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

private struct SkinPlaylistView: View {
    @Bindable var coordinator: PlaybackCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlist").font(.title2.bold())
                    Text("\(coordinator.queue.items.count) tracks · \(coordinator.activeProviderName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()
            if coordinator.queue.items.isEmpty {
                ContentUnavailableView(
                    "Playlist is empty",
                    systemImage: "music.note.list",
                    description: Text("Play a library item or open local files to create a queue.")
                )
            } else {
                List(Array(coordinator.queue.items.enumerated()), id: \.offset) { index, item in
                    Button {
                        Task { await coordinator.play(items: coordinator.queue.items, startingAt: index) }
                    } label: {
                        HStack {
                            Image(systemName: index == coordinator.queue.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.artist ?? item.albumTitle ?? "Unknown artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let duration = item.duration {
                                Text(Self.time(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    private static func time(_ duration: Duration) -> String {
        let seconds = Int(duration.secondsValue)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SkinEqualizerView: View {
    @Bindable var coordinator: PlaybackCoordinator
    private let bands = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer").font(.title2.bold())
                    Text(coordinator.activeProviderName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { Task { await coordinator.resetEqualizer() } }
                    .disabled(!coordinator.audioEffectCapabilities.contains(.equalizerBands))
                Toggle("On", isOn: Binding(
                    get: { coordinator.audioEffectState.isEnabled },
                    set: { value in Task { await coordinator.setEqualizerEnabled(value) } }
                ))
                .disabled(!coordinator.audioEffectCapabilities.contains(.enable))
            }

            HStack(alignment: .bottom, spacing: 9) {
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    VStack(spacing: 6) {
                        Slider(value: Binding(
                            get: {
                                Double(coordinator.audioEffectState.bandGains[EqualizerBand.winamp10[index]] ?? 0)
                            },
                            set: { value in
                                Task { await coordinator.setEqualizerBand(index: index, gain: Float(value)) }
                            }
                        ), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 112)
                            .disabled(!coordinator.audioEffectCapabilities.contains(.equalizerBands))
                        Text(band).font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Label(
                coordinator.audioEffectCapabilities.contains(.equalizerBands)
                    ? "The bands process local-file audio in Macamp."
                    : "Visual only: the active provider does not expose decoded audio for EQ processing.",
                systemImage: coordinator.audioEffectCapabilities.contains(.equalizerBands) ? "checkmark.circle" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 260)
    }
}

/// Owns snap policy independently of playback and rendering. Additional classic windows
/// can register here without changing transport code.
@MainActor
final class WindowDockingController {
    var isEnabled = true
    var snapDistance: CGFloat = 10
    private(set) var registeredPanelFrames: [ObjectIdentifier: CGRect] = [:]

    func snappedOrigin(for movingFrame: CGRect, near otherFrames: [CGRect], screen: CGRect, scale: Int) -> CGPoint {
        guard isEnabled else { return movingFrame.origin }
        let threshold = snapDistance * CGFloat(scale)
        var origin = movingFrame.origin
        let candidatesX = otherFrames.flatMap { [$0.minX - movingFrame.width, $0.maxX, $0.minX, $0.maxX - movingFrame.width] } + [screen.minX, screen.maxX - movingFrame.width]
        let candidatesY = otherFrames.flatMap { [$0.minY - movingFrame.height, $0.maxY, $0.minY, $0.maxY - movingFrame.height] } + [screen.minY, screen.maxY - movingFrame.height]
        if let x = candidatesX.min(by: { abs($0 - origin.x) < abs($1 - origin.x) }), abs(x - origin.x) <= threshold { origin.x = x }
        if let y = candidatesY.min(by: { abs($0 - origin.y) < abs($1 - origin.y) }), abs(y - origin.y) <= threshold { origin.y = y }
        return origin
    }

    func update(panel: NSPanel) {
        registeredPanelFrames[ObjectIdentifier(panel)] = panel.frame
    }
}
