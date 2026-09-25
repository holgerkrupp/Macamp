import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let playback = PlaybackCoordinator()
    let settings = SettingsStore()
    let skins = SkinLibraryStore()
    let appleMusic = AppleMusicPlaybackProvider()
    let preview = MockPlaybackProvider()
    let localMedia = LocalFilePlaybackProvider()
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
        analysis = SimulatedAudioAnalysisSource(coordinator: playback)
        playback.register(appleMusic)
        playback.register(preview)
        playback.register(localMedia)
        let selected = PlaybackProviderID(rawValue: settings.activeProviderID)
        playback.activate([.appleMusic, .preview, .localMedia].contains(selected) ? selected : .appleMusic)
    }

    func selectProvider(_ id: PlaybackProviderID) {
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
