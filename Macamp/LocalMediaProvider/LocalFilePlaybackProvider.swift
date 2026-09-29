import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class LocalFilePlaybackProvider: QueueEditingPlaybackProvider, AudioEffectController {
    let id: PlaybackProviderID = .localMedia
    let displayName = "Local Files"
    let capabilities: PlaybackCapabilities = [
        .playback, .pause, .explicitStop, .seek, .previous, .next,
        .queueReading, .queueEditing, .shuffle, .repeat, .applicationVolume,
        .playlists, .localMetadata, .artwork, .backgroundPlayback, .nativeEqualizer
    ]
    let effectCapabilities: AudioEffectCapabilities = [.enable, .preamp, .equalizerBands]
    private(set) var effectState = AudioEffectState()

    private(set) var authenticationState: ProviderAuthenticationState = .authorized
    private(set) var state = PlaybackState(status: .stopped, providerID: .localMedia)
    private(set) var queue = PlaybackQueue()
    private(set) var libraryItems: [PlaybackItem] = []
    private(set) var importWarnings: [String] = []
    private(set) var isImporting = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let audioPlayerNode = AVAudioPlayerNode()
    @ObservationIgnored private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerBand.winamp10.count)
    @ObservationIgnored private var audioFile: AVAudioFile?
    @ObservationIgnored private var scheduledStartFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var usesAudioEngine = false
    @ObservationIgnored private let bookmarkStore: LocalMediaBookmarkStore
    @ObservationIgnored private var locations: [PlaybackItemID: URL] = [:]
    @ObservationIgnored private var continuations: [UUID: AsyncStream<ProviderSnapshot>.Continuation] = [:]
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURLs: [URL] = []
    @ObservationIgnored private var didRestoreBookmarks = false
    @ObservationIgnored private var handledCurrentEnd = false

    init(bookmarkStore: LocalMediaBookmarkStore = LocalMediaBookmarkStore()) {
        self.bookmarkStore = bookmarkStore
        player.volume = 1
        audioPlayerNode.volume = 1
        audioEngine.attach(audioPlayerNode)
        audioEngine.attach(equalizer)
        audioEngine.connect(audioPlayerNode, to: equalizer, format: nil)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format: nil)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerBand.winamp10[index].centerFrequency
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizer.bypass = true
    }

    deinit { progressTask?.cancel() }

    func snapshots() -> AsyncStream<ProviderSnapshot> {
        let id = UUID()
        let pair = AsyncStream<ProviderSnapshot>.makeStream()
        continuations[id] = pair.continuation
        pair.continuation.yield(snapshot)
        return pair.stream
    }

    func restoreLibrary() async {
        guard !didRestoreBookmarks else { return }
        didRestoreBookmarks = true
        let urls = bookmarkStore.resolveAll()
        guard !urls.isEmpty else { return }
        await importURLs(urls, persistBookmarks: false)
    }

    @discardableResult
    func importURLs(_ urls: [URL], persistBookmarks: Bool = true) async -> [PlaybackItem] {
        guard !urls.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            beginAccessing(url)
            if persistBookmarks {
                do { try bookmarkStore.add(url) }
                catch { importWarnings.append("Could not remember \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        let report = await LocalMediaImporter.importURLs(urls)
        locations.merge(report.locations) { _, replacement in replacement }
        for item in report.items where !libraryItems.contains(where: { $0.id == item.id }) {
            libraryItems.append(item)
        }
        importWarnings.append(contentsOf: report.warnings)
        importWarnings = Array(importWarnings.suffix(20))
        return report.items
    }

    func clearLibrary() async {
        try? await stop()
        bookmarkStore.removeAll()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        libraryItems.removeAll()
        locations.removeAll()
        queue = PlaybackQueue()
        state.currentItem = nil
        state.duration = nil
        importWarnings.removeAll()
        publish()
    }

    func authorize() async throws {
        authenticationState = .authorized
        publish()
    }

    func disconnect() async {
        try? await stop()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        publish()
    }

    func play() async throws {
        if queue.currentItem == nil {
            guard !libraryItems.isEmpty else {
                throw ProviderError(code: .itemUnavailable, message: "Add an MP3 file or playlist before starting playback.")
            }
            try await play(items: libraryItems, startingAt: 0)
            return
        }
        if let duration = state.duration?.secondsValue,
           state.elapsed.secondsValue >= duration - 0.15 {
            try seekPlayer(to: .zero, resume: false)
            state.elapsed = .zero
            handledCurrentEnd = false
        }
        if usesAudioEngine {
            if !audioEngine.isRunning { try audioEngine.start() }
            audioPlayerNode.play()
        } else {
            player.play()
        }
        state.status = .playing
        state.playbackRate = 1
        startProgressUpdates()
        publish()
    }

    func pause() async throws {
        updateElapsed()
        if usesAudioEngine { audioPlayerNode.pause() } else { player.pause() }
        state.status = .paused
        state.playbackRate = 0
        stopProgressUpdates()
        publish()
    }

    func stop() async throws {
        if usesAudioEngine { audioPlayerNode.stop() } else { player.pause() }
        try seekPlayer(to: .zero, resume: false)
        state.status = .stopped
        state.playbackRate = 0
        state.elapsed = .zero
        stopProgressUpdates()
        publish()
    }

    func play(item: PlaybackItem) async throws {
        try await play(items: [item], startingAt: 0)
    }

    func play(items: [PlaybackItem], startingAt index: Int) async throws {
        guard items.indices.contains(index) else {
            throw ProviderError(code: .itemUnavailable, message: "That queue position is unavailable.")
        }
        for item in items where locations[item.id] == nil {
            if let url = URL(string: item.providerItemID), ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") {
                locations[item.id] = url
            }
        }
        queue = PlaybackQueue(items: items, currentIndex: index)
        try loadCurrentItem(autoplay: true)
    }

    func removeQueueItems(at offsets: IndexSet) async throws {
        let removed = offsets.filter { queue.items.indices.contains($0) }
        guard !removed.isEmpty else { return }
        let current = queue.currentIndex
        if current.map(removed.contains) == true { try await stop() }
        queue.items = queue.items.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
        if queue.items.isEmpty {
            queue.currentIndex = nil
            state.currentItem = nil
            state.duration = nil
            state.elapsed = .zero
        } else if let current {
            let removedBefore = removed.filter { $0 < current }.count
            queue.currentIndex = removed.contains(current) ? min(current - removedBefore, queue.items.count - 1) : current - removedBefore
            if let item = queue.currentItem {
                state.currentItem = item
                state.duration = item.duration
            }
        }
        publish()
    }

    func clearQueue() async throws {
        try await stop()
        queue = PlaybackQueue()
        state.currentItem = nil
        state.duration = nil
        publish()
    }

    func seek(to position: Duration) async throws {
        guard usesAudioEngine ? audioFile != nil : player.currentItem != nil else { throw ProviderError(code: .itemUnavailable, message: "Nothing is loaded.") }
        let maximum = state.duration?.secondsValue ?? position.secondsValue
        let target = Duration.seconds(min(max(position.secondsValue, 0), maximum))
        try seekPlayer(to: target, resume: state.status == .playing)
        state.elapsed = target
        handledCurrentEnd = false
        publish()
    }

    func skipToNext() async throws {
        try advance(manual: true)
    }

    func skipToPrevious() async throws {
        if state.elapsed.secondsValue > 3 {
            try await seek(to: .zero)
            return
        }
        guard !queue.items.isEmpty else { throw ProviderError(code: .itemUnavailable, message: "The queue is empty.") }
        let current = queue.currentIndex ?? 0
        let index = current > 0 ? current - 1 : (state.repeatMode == .all ? queue.items.count - 1 : 0)
        queue.currentIndex = index
        try loadCurrentItem(autoplay: state.status == .playing)
    }

    func setVolume(_ volume: Double) async throws {
        state.volume = min(max(volume, 0), 1)
        player.volume = Float(state.volume)
        audioPlayerNode.volume = Float(state.volume)
        publish()
    }

    func setEnabled(_ enabled: Bool) async throws {
        effectState.isEnabled = enabled
        equalizer.bypass = !enabled
        publish()
    }

    func setPreampGain(_ value: Float) async throws {
        let gain = min(max(value, -12), 12)
        effectState.preampGain = gain
        equalizer.globalGain = gain
        publish()
    }

    func setBandGain(_ value: Float, band: EqualizerBand) async throws {
        guard let index = EqualizerBand.winamp10.firstIndex(of: band) else {
            throw ProviderError.unsupported("that equalizer band")
        }
        let gain = min(max(value, -12), 12)
        effectState.bandGains[band] = gain
        equalizer.bands[index].gain = gain
        if !effectState.isEnabled {
            effectState.isEnabled = true
            equalizer.bypass = false
        }
        publish()
    }

    func setShuffleMode(_ mode: ShuffleMode) async throws {
        state.shuffleMode = mode
        publish()
    }

    func setRepeatMode(_ mode: RepeatMode) async throws {
        state.repeatMode = mode
        publish()
    }

    private func loadCurrentItem(autoplay: Bool) throws {
        guard let item = queue.currentItem, let url = locations[item.id] else {
            throw ProviderError(code: .itemUnavailable, message: "The selected local file is no longer available.")
        }
        audioPlayerNode.stop()
        player.pause()
        if url.isFileURL {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            usesAudioEngine = true
            player.replaceCurrentItem(with: nil)
            try scheduleAudioFile(from: 0, autoplay: autoplay)
        } else {
            audioFile = nil
            usesAudioEngine = false
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        state.currentItem = item
        if let file = audioFile {
            state.duration = .seconds(Double(file.length) / file.processingFormat.sampleRate)
        } else {
            state.duration = item.duration
        }
        state.elapsed = .zero
        state.lastError = nil
        handledCurrentEnd = false
        if autoplay {
            if !usesAudioEngine { player.play() }
            state.status = .playing
            state.playbackRate = 1
            startProgressUpdates()
        } else {
            state.status = .paused
            state.playbackRate = 0
            stopProgressUpdates()
        }
        publish()
    }

    private func advance(manual: Bool) throws {
        guard !queue.items.isEmpty else { throw ProviderError(code: .itemUnavailable, message: "The queue is empty.") }
        if !manual, state.repeatMode == .one {
            queue.currentIndex = queue.currentIndex ?? 0
            try loadCurrentItem(autoplay: true)
            return
        }
        let current = queue.currentIndex ?? 0
        let nextIndex: Int?
        if state.shuffleMode == .songs, queue.items.count > 1 {
            nextIndex = (queue.items.indices.filter { $0 != current }).randomElement()
        } else if current + 1 < queue.items.count {
            nextIndex = current + 1
        } else if state.repeatMode == .all {
            nextIndex = 0
        } else {
            nextIndex = nil
        }
        guard let nextIndex else {
            if usesAudioEngine { audioPlayerNode.stop() } else { player.pause() }
            state.status = .stopped
            state.playbackRate = 0
            stopProgressUpdates()
            publish()
            return
        }
        queue.currentIndex = nextIndex
        try loadCurrentItem(autoplay: true)
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.updateProgress()
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func updateProgress() {
        if !usesAudioEngine {
            guard let currentItem = player.currentItem else { return }
            if currentItem.status == .failed {
                let message = currentItem.error?.localizedDescription ?? "AVFoundation could not play this item."
                state.lastError = ProviderError(code: .playbackFailed, message: message)
                state.status = .failed
                state.playbackRate = 0
                stopProgressUpdates()
                publish()
                return
            }
            if state.duration == nil {
                let seconds = currentItem.duration.seconds
                if seconds.isFinite && seconds >= 0 { state.duration = .seconds(seconds) }
            }
        }
        updateElapsed()
        publish()
        if let duration = state.duration?.secondsValue,
           duration > 0,
           state.elapsed.secondsValue >= duration - 0.15,
           !handledCurrentEnd {
            handledCurrentEnd = true
            try? advance(manual: false)
        }
    }

    private func updateElapsed() {
        let seconds: Double
        if usesAudioEngine,
           let file = audioFile,
           let nodeTime = audioPlayerNode.lastRenderTime,
           let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) {
            seconds = Double(scheduledStartFrame) / file.processingFormat.sampleRate
                + Double(playerTime.sampleTime) / playerTime.sampleRate
        } else {
            seconds = player.currentTime().seconds
        }
        if seconds.isFinite && seconds >= 0 { state.elapsed = .seconds(seconds) }
    }

    private func seekPlayer(to position: Duration, resume: Bool) throws {
        if usesAudioEngine {
            try scheduleAudioFile(from: position.secondsValue, autoplay: resume)
        } else {
            player.seek(to: CMTime(seconds: position.secondsValue, preferredTimescale: 600))
        }
    }

    private func scheduleAudioFile(from seconds: Double, autoplay: Bool) throws {
        guard let file = audioFile else { return }
        audioPlayerNode.stop()
        let sampleRate = file.processingFormat.sampleRate
        let start = min(max(AVAudioFramePosition(seconds * sampleRate), 0), file.length)
        scheduledStartFrame = start
        let remaining = max(0, file.length - start)
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        if frameCount > 0 {
            audioPlayerNode.scheduleSegment(file, startingFrame: start, frameCount: frameCount, at: nil)
        }
        audioEngine.prepare()
        if !audioEngine.isRunning { try audioEngine.start() }
        if autoplay, frameCount > 0 { audioPlayerNode.play() }
    }

    private func beginAccessing(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL, !scopedURLs.contains(normalized) else { return }
        _ = normalized.startAccessingSecurityScopedResource()
        scopedURLs.append(normalized)
    }

    private var snapshot: ProviderSnapshot {
        ProviderSnapshot(authenticationState: authenticationState, state: state, queue: queue)
    }

    private func publish() {
        let value = snapshot
        continuations.values.forEach { $0.yield(value) }
    }
}
