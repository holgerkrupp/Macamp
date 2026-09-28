import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let playback = PlaybackCoordinator()
    let providerRegistry = ProviderRegistry()
    let settings = SettingsStore()
    let skins = SkinLibraryStore()
    let appleMusic = AppleMusicPlaybackProvider()
    let preview = MockPlaybackProvider()
    let localMedia = LocalFilePlaybackProvider()
    let spotify: SpotifyPlaybackProvider
    let tidal: TidalPlaybackProvider
    let soundCloud: SoundCloudPlaybackProvider
    let youtube: YouTubePlaybackProvider
    let analysis: SimulatedAudioAnalysisSource

    @ObservationIgnored lazy var visualizations = VisualizationWindowController(source: analysis, settings: settings)
    @ObservationIgnored lazy var classicPlayer = SkinWindowController(
        coordinator: playback, skinStore: skins, settings: settings,
        openMedia: { [weak self] in
            let urls = LocalMediaImportPanel.chooseFilesAndPlaylists()
            guard !urls.isEmpty else { return }
            Task { await self?.importLocalMedia(urls, playImmediately: true) }
        },
        visualizationToggle: { [weak self] in self?.visualizations.toggle() }
    )

    init() {
        let externalConfiguration = ExternalProviderConfiguration.environment
        analysis = SimulatedAudioAnalysisSource(coordinator: playback)
        spotify = SpotifyPlaybackProvider(configuration: externalConfiguration)
        tidal = TidalPlaybackProvider(configuration: externalConfiguration)
        soundCloud = SoundCloudPlaybackProvider(configuration: externalConfiguration)
        youtube = YouTubePlaybackProvider(configuration: externalConfiguration)
        providerRegistry.register(appleMusic, descriptor: .appleMusic)
        providerRegistry.register(preview, descriptor: .preview)
        providerRegistry.register(localMedia, descriptor: .localMedia)
        register(spotify, descriptor: .spotify, configured: spotify.isConfigured)
        register(tidal, descriptor: .tidal, configured: tidal.isConfigured)
        register(soundCloud, descriptor: .soundCloud, configured: soundCloud.isConfigured)
        register(youtube, descriptor: .youtube, configured: youtube.isConfigured)
        providerRegistry.registerUnavailable(.deezer)
        playback.register(appleMusic)
        playback.register(preview)
        playback.register(localMedia)
        if spotify.isConfigured { playback.register(spotify) }
        if tidal.isConfigured { playback.register(tidal) }
        if soundCloud.isConfigured { playback.register(soundCloud) }
        if youtube.isConfigured { playback.register(youtube) }
        let selected = PlaybackProviderID(rawValue: settings.activeProviderID)
        let active = providerRegistry.isAvailable(selected) ? selected : .appleMusic
        if !providerRegistry.isAvailable(selected) { settings.activeProviderID = active.rawValue }
        playback.activate(active)
    }

    private func register(_ provider: any PlaybackProvider, descriptor: ProviderDescriptor, configured: Bool) {
        if configured {
            var descriptor = descriptor
            descriptor.availability = .available
            providerRegistry.register(provider, descriptor: descriptor)
        } else {
            providerRegistry.registerUnavailable(descriptor)
        }
    }

    func selectProvider(_ id: PlaybackProviderID) {
        guard providerRegistry.isAvailable(id) else { return }
        settings.activeProviderID = id.rawValue
        playback.activate(id)
    }

    func importLocalMedia(_ urls: [URL], playImmediately: Bool = false) async {
        let imported = await localMedia.importURLs(urls)
        selectProvider(.localMedia)
        if playImmediately, !imported.isEmpty {
            await playback.play(items: imported, startingAt: 0)
        }
    }
}
