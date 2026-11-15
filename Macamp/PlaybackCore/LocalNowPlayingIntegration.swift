import AppKit
import Foundation
import MediaPlayer

@MainActor
final class LocalNowPlayingIntegration {
    private weak var coordinator: PlaybackCoordinator?
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var targetTokens: [(MPRemoteCommand, Any)] = []
    private var isPublishingLocalInfo = false

    init(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
        update()
    }

    func update() {
        guard let coordinator else { return }
        let controlsLocalPlayback = coordinator.activeProviderID == .localMedia
        if controlsLocalPlayback { registerCommands() }
        else { unregisterCommands() }
        guard controlsLocalPlayback,
              let item = coordinator.state.currentItem,
              item.providerID == .localMedia,
              ![.stopped, .unavailable, .failed].contains(coordinator.state.status) else {
            if isPublishingLocalInfo { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
            isPublishingLocalInfo = false
            setCommandsEnabled(false)
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.info(for: item, state: coordinator.state)
        isPublishingLocalInfo = true
        setCommandsEnabled(true, capabilities: coordinator.capabilities)
    }

    static func info(for item: PlaybackItem, state: PlaybackState) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed.secondsValue,
            MPNowPlayingInfoPropertyPlaybackRate: state.status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: item.mediaKind == .radioStation
        ]
        if let artist = item.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = item.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = state.duration { info[MPMediaItemPropertyPlaybackDuration] = duration.secondsValue }
        if case let .embedded(data)? = item.artwork, let image = NSImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return info
    }

    private func setCommandsEnabled(_ enabled: Bool, capabilities: PlaybackCapabilities = []) {
        commandCenter.playCommand.isEnabled = enabled && capabilities.contains(.playback)
        commandCenter.pauseCommand.isEnabled = enabled && capabilities.contains(.pause)
        commandCenter.togglePlayPauseCommand.isEnabled = enabled && (capabilities.contains(.playback) || capabilities.contains(.pause))
        commandCenter.stopCommand.isEnabled = enabled && capabilities.contains(.explicitStop)
        commandCenter.nextTrackCommand.isEnabled = enabled && capabilities.contains(.next)
        commandCenter.previousTrackCommand.isEnabled = enabled && capabilities.contains(.previous)
        commandCenter.changePlaybackPositionCommand.isEnabled = enabled && capabilities.contains(.seek)
    }

    private func registerCommands() {
        guard targetTokens.isEmpty else { return }
        add(commandCenter.playCommand) { [weak self] in self?.perform(.play) ?? .commandFailed }
        add(commandCenter.pauseCommand) { [weak self] in self?.perform(.pause) ?? .commandFailed }
        add(commandCenter.togglePlayPauseCommand) { [weak self] in self?.perform(.toggle) ?? .commandFailed }
        add(commandCenter.stopCommand) { [weak self] in self?.perform(.stop) ?? .commandFailed }
        add(commandCenter.nextTrackCommand) { [weak self] in self?.perform(.next) ?? .commandFailed }
        add(commandCenter.previousTrackCommand) { [weak self] in self?.perform(.previous) ?? .commandFailed }
        let token = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.seek(to: event.positionTime) ?? .commandFailed
        }
        targetTokens.append((commandCenter.changePlaybackPositionCommand, token))
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        targetTokens.append((command, command.addTarget { _ in handler() }))
    }

    private func unregisterCommands() {
        targetTokens.forEach { $0.0.removeTarget($0.1) }
        targetTokens.removeAll()
        setCommandsEnabled(false)
    }

    private func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard let coordinator, coordinator.activeProviderID == .localMedia else { return .commandFailed }
        let supported: Bool = switch action {
        case .play: coordinator.capabilities.contains(.playback)
        case .pause: coordinator.capabilities.contains(.pause)
        case .toggle: coordinator.capabilities.contains(.playback) || coordinator.capabilities.contains(.pause)
        case .stop: coordinator.capabilities.contains(.explicitStop)
        case .next: coordinator.capabilities.contains(.next)
        case .previous: coordinator.capabilities.contains(.previous)
        }
        guard supported else { return .commandFailed }
        Task { @MainActor in
            switch action {
            case .play: await coordinator.play()
            case .pause: await coordinator.pause()
            case .toggle:
                if coordinator.state.status == .playing { await coordinator.pause() }
                else { await coordinator.play() }
            case .stop: await coordinator.stop()
            case .next: await coordinator.next()
            case .previous: await coordinator.previous()
            }
        }
        return .success
    }

    private func seek(to seconds: Double) -> MPRemoteCommandHandlerStatus {
        guard let coordinator, coordinator.activeProviderID == .localMedia,
              coordinator.capabilities.contains(.seek), seconds.isFinite, seconds >= 0 else { return .commandFailed }
        Task { @MainActor in await coordinator.seek(to: .seconds(seconds)) }
        return .success
    }

    private enum Action { case play, pause, toggle, stop, next, previous }
}
