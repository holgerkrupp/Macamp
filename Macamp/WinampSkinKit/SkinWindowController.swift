import AppKit
import SwiftUI

@MainActor
final class SkinWindowController: NSWindowController {
    private let settings: SettingsStore
    private let renderer: SkinRendererView
    private let host: WinampSkinWindowHost
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
        renderer = SkinRendererView(
            coordinator: coordinator,
            skinStore: skinStore,
            settings: settings,
            openMedia: openMedia,
            playlistToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.togglePlaylist() },
            equalizerToggle: { [weak auxiliaryWindows] in auxiliaryWindows?.toggleEqualizer() },
            visualizationToggle: visualizationToggle
        )
        host = WinampSkinWindowHost(normalLogicalSize: canvas, scale: CGFloat(scale))
        renderer.windowHost = host
        host.setContentView(renderer)
        host.regionPath = renderer.regionPath
        host.window.hasShadow = settings.playerShadow
        host.window.level = settings.playerFloating ? .floating : .normal
        super.init(window: host.window)
        host.onLogicalFrameChange = { [weak settings] frame in
            settings?.savePlayerLogicalFrame(frame)
        }
        if let restored = settings.restoredPlayerLogicalFrame() {
            host.setLogicalFrame(restored, display: false, clampedToVisibleScreens: true)
        } else if let restored = settings.restoredPlayerFrame() {
            let logical = WinampSkinWindowGeometry.logicalFrame(for: restored, scale: CGFloat(scale))
            host.setLogicalFrame(logical, display: false, clampedToVisibleScreens: true)
        } else {
            host.window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toggle() {
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) } else { showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    func applySettings() {
        guard let window else { return }
        renderer.updateScale(settings.skinScale)
        host.setScale(CGFloat(settings.skinScale))
        host.regionPath = renderer.regionPath
        window.hasShadow = settings.playerShadow
        window.level = settings.playerFloating ? .floating : .normal
    }
}

@MainActor
private final class SkinAuxiliaryWindowController: NSObject {
    private let coordinator: PlaybackCoordinator
    private let skinStore: SkinLibraryStore
    private var playlistHost: WinampSkinWindowHost?
    private var equalizerHost: WinampSkinWindowHost?
    private let docking = WindowDockingController()

    init(coordinator: PlaybackCoordinator, skinStore: SkinLibraryStore) {
        self.coordinator = coordinator
        self.skinStore = skinStore
    }

    func togglePlaylist() {
        if let playlistHost, playlistHost.window.isVisible {
            playlistHost.window.orderOut(nil)
            return
        }
        let host = playlistHost ?? makeHost(
            title: "Macamp Playlist",
            size: skinStore.classicPanelSize(kind: .playlist, fallback: CGSize(width: 430, height: 360)),
            rootView: AnyView(SkinPlaylistView(coordinator: coordinator)),
            background: skinStore.classicPanelImage(kind: .playlist)
        )
        playlistHost = host
        present(host)
    }

    func toggleEqualizer() {
        if let equalizerHost, equalizerHost.window.isVisible {
            equalizerHost.window.orderOut(nil)
            return
        }
        let host = equalizerHost ?? makeHost(
            title: "Macamp Equalizer",
            size: skinStore.classicPanelSize(kind: .equalizer, fallback: CGSize(width: 460, height: 300)),
            rootView: AnyView(SkinEqualizerView(coordinator: coordinator)),
            background: skinStore.classicPanelImage(kind: .equalizer)
        )
        equalizerHost = host
        present(host)
    }

    private func makeHost(title: String, size: CGSize, rootView: AnyView, background: NSImage?) -> WinampSkinWindowHost {
        let host = WinampSkinWindowHost(normalLogicalSize: size, scale: 1, allowsResize: true)
        host.window.title = title
        host.window.isReleasedWhenClosed = false
        host.window.minSize = CGSize(width: min(360, size.width), height: min(240, size.height))
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
        host.setContentView(container)
        host.onLogicalFrameChange = { [weak self, weak window = host.window] _ in
            guard let window else { return }
            self?.docking.update(window: window)
        }
        host.window.center()
        return host
    }

    private func present(_ host: WinampSkinWindowHost) {
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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

    func update(window: NSWindow) {
        registeredPanelFrames[ObjectIdentifier(window)] = window.frame
    }
}
