import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class DependencyContainer {
    let playback: PlaybackCoordinator
    let mediaImport: MediaImportService
    let providerRegistry = ProviderRegistry()
    let settings = SettingsStore()
    let skins = SkinLibraryStore()
    let appleMusic = AppleMusicPlaybackProvider()
    let preview = MockPlaybackProvider()
    let localMedia: LocalFilePlaybackProvider
    let spotify: SpotifyPlaybackProvider
    let tidal: TidalPlaybackProvider
    let soundCloud: SoundCloudPlaybackProvider
    let youtube: YouTubePlaybackProvider
    let localPCMAnalysis = LocalPCMAudioAnalysisSource()
    let visualizationFrames = VisualizationFrameStore()

    @ObservationIgnored lazy var musicCatalogPicker = MusicCatalogPickerWindowController(dependencies: self)
    func showMusicCatalogPicker() { musicCatalogPicker.show() }

    @ObservationIgnored lazy var visualizations = VisualizationWindowController(
        source: localPCMAnalysis, coordinator: playback, frameStore: visualizationFrames, settings: settings
    )
    @ObservationIgnored lazy var classicPlayer = SkinWindowController(
        coordinator: playback, skinStore: skins, settings: settings, visualizationFrames: visualizationFrames,
        openMedia: { [weak self] in
            self?.chooseAndImportMedia(action: .replaceAndPlay, kind: .files)
        },
        visualizationToggle: { [weak self] in self?.visualizations.toggle() },
        mediaAction: { [weak self] action in self?.requestSkinMediaImport(action) },
        onDroppedURLs: { [weak self] urls in
            Task { await self?.importMediaURLs(urls, action: .appendToQueue) }
        },
        choosePlaylistURLs: { kind in
            switch kind {
            case .files: ApplicationMediaImportPanel.chooseFiles()
            case .folder: ApplicationMediaImportPanel.chooseFolder()
            case .playlist: ApplicationMediaImportPanel.choosePlaylists()
            }
        },
        importPlaylistURLs: { [weak self] urls, action in
            Task { await self?.importMediaURLs(urls, action: action) }
        },
        onAddFromService: { [weak self] in self?.showMusicCatalogPicker() }
    )

    init() {
        let sessionStore = PlaybackSessionStore()
        playback = PlaybackCoordinator(sessionStore: sessionStore, settingsStore: settings)
        localMedia = LocalFilePlaybackProvider(sessionStore: sessionStore, settingsStore: settings, analysisSource: localPCMAnalysis)
        mediaImport = MediaImportService(playback: playback, localMedia: localMedia)
        let externalConfiguration = ExternalProviderConfiguration.environment
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
        visualizationFrames.start(source: localPCMAnalysis, coordinator: playback)
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
        let action: MediaImportAction = playImmediately ? .replaceAndPlay : .addToLibrary
        _ = await mediaImport.importURLs(urls, action: action)
    }

    func requestSkinMediaImport(_ action: SkinAction) {
        if action == .addFromService {
            showMusicCatalogPicker()
            return
        }
        let importAction: MediaImportAction
        let panelKind: ClassicPlaylistImportKind
        switch action {
        case .addFiles:
            importAction = .appendToQueue
            panelKind = .files
        case .addFolder:
            importAction = .appendToQueue
            panelKind = .folder
        case .addPlaylist:
            importAction = .appendToQueue
            panelKind = .playlist
        default:
            return
        }
        chooseAndImportMedia(action: importAction, kind: panelKind)
    }

    private func chooseAndImportMedia(action: MediaImportAction, kind: ClassicPlaylistImportKind) {
        let urls: [URL]
        switch kind {
        case .files: urls = ApplicationMediaImportPanel.chooseFilesAndFolders()
        case .folder: urls = ApplicationMediaImportPanel.chooseFolder()
        case .playlist: urls = ApplicationMediaImportPanel.choosePlaylists()
        }
        guard !urls.isEmpty else { return }
        Task { await importMediaURLs(urls, action: action) }
    }

    func importMediaURLs(_ urls: [URL], action: MediaImportAction) async {
        let result = await mediaImport.importURLs(urls, action: action)
        guard !result.warnings.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Some items could not be added"
        alert.informativeText = result.warnings.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let offersSourceSwitch = result.warnings.contains { $0.localizedCaseInsensitiveContains("switch to the local files") }
        if offersSourceSwitch { alert.addButton(withTitle: "Switch to Local Files") }
        let response = alert.runModal()
        if offersSourceSwitch, response == .alertSecondButtonReturn { selectProvider(.localMedia) }
    }
}
