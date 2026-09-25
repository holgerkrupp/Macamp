import Foundation

@MainActor
final class SimulatedAudioAnalysisSource: AudioAnalysisSource {
    let mode: AudioAnalysisMode = .simulated
    private let coordinator: PlaybackCoordinator
    private var task: Task<Void, Never>?
    private var continuations: [AsyncStream<VisualizationAudioData>.Continuation] = []
    private var frameIndex: UInt64 = 0
    private var frameRate = 30
    private var intensity = 0.7

    init(coordinator: PlaybackCoordinator) { self.coordinator = coordinator }
    deinit { task?.cancel() }

    func start() async throws {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let playing = self.coordinator.state.isPlaying
                let data: VisualizationAudioData = playing ? .simulated(self.makeFrame()) : .silent
                self.continuations.forEach { $0.yield(data) }
                try? await Task.sleep(for: .milliseconds(max(16, 1_000 / self.frameRate)))
            }
        }
    }

    func stop() async { task?.cancel(); task = nil }

    func frames() -> AsyncStream<VisualizationAudioData> {
        let pair = AsyncStream<VisualizationAudioData>.makeStream(bufferingPolicy: .bufferingNewest(2))
        continuations.append(pair.continuation)
        return pair.stream
    }

    func frame(at index: UInt64, seed: UInt64) -> SimulatedFrame { makeFrame(index: index, seed: seed) }

    func configure(frameRate: Int, intensity: Double) {
        self.frameRate = min(max(frameRate, 15), 60)
        self.intensity = min(max(intensity, 0), 1)
    }

    private func makeFrame() -> SimulatedFrame {
        defer { frameIndex &+= 1 }
        let itemSeed = coordinator.state.currentItem?.id.rawValue.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) } ?? 0x4D4143414D50
        return makeFrame(index: frameIndex, seed: itemSeed)
    }

    private func makeFrame(index: UInt64, seed: UInt64) -> SimulatedFrame {
        let time = Float(index) / 30
        let bands = (0..<48).map { band -> Float in
            let x = Float(band) / 47
            let beat = max(0, sin(time * 5.2 + Float(seed % 17)))
            let harmonic = (sin(time * (1.7 + x * 2.1) + x * 18 + Float(seed % 31)) + 1) * 0.5
            let scale = Float(0.35 + intensity * 0.9)
            return min(1, (0.16 + 0.62 * harmonic + 0.22 * beat) * (1 - x * 0.45) * scale)
        }
        let waveform = (0..<96).map { sample -> Float in
            let x = Float(sample) / 95
            return sin(x * 25 + time * 3.1) * (0.35 + 0.18 * sin(time * 2.3 + x * 5)) * Float(0.35 + intensity * 0.9)
        }
        return SimulatedFrame(bands: bands, waveform: waveform, seed: seed)
    }
}

/// Future local playback feeds decoded buffers here. It deliberately does not capture
/// microphone or system audio and drops frames rather than blocking an audio callback.
final class LocalPCMAudioAnalysisSource: AudioAnalysisSource, @unchecked Sendable {
    let mode: AudioAnalysisMode = .pcm
    @MainActor func start() async throws { }
    @MainActor func stop() async { }
    @MainActor func frames() -> AsyncStream<VisualizationAudioData> { AsyncStream { $0.finish() } }
}
