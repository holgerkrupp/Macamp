import Foundation
import Testing
@testable import Macamp

@Suite
@MainActor
struct VisualizationTests {
    @Test func simulatedFramesAreDeterministic() {
        let coordinator = PlaybackCoordinator(playlistStore: makeIsolatedUnifiedPlaylistStore())
        let source = SimulatedAudioAnalysisSource(coordinator: coordinator)
        #expect(source.frame(at: 42, seed: 99) == source.frame(at: 42, seed: 99))
        #expect(source.frame(at: 43, seed: 99) != source.frame(at: 42, seed: 99))
    }

    @Test func presetRoundTrips() throws {
        let preset = VisualizationPreset(engineIdentifier: "spectrum", frameRate: 60, seed: 123)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(VisualizationPreset.self, from: data)
        #expect(try decoded.validated() == preset)
    }

    @Test func unsupportedPresetVersionIsRejected() {
        let preset = VisualizationPreset(version: 999, engineIdentifier: "future")
        #expect(throws: ProviderError.self) { try preset.validated() }
    }

    @Test func pcmAnalyzerReturnsSafeSilence() {
        let silent = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: Array(repeating: 0, count: 2_048), sampleRate: 44_100))
        #expect(silent.bands.count == 48)
        #expect(silent.waveform.count == 96)
        #expect(silent.bands.allSatisfy { $0.isFinite && $0 == 0 })
        #expect(silent.waveform.allSatisfy { $0.isFinite && $0 == 0 })
        #expect(silent.pcm == Array(repeating: Float.zero, count: 1_024))

        let short = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: [0.25], sampleRate: 48_000))
        #expect(short.bands.count == 48)
        #expect(short.waveform.count == 96)
        #expect(short.bands.allSatisfy { $0.isFinite })
        #expect(short.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
    }

    @Test func visualizerPCMRetainsTheNewestContiguousSamples() {
        let samples = (0..<2_048).map { Float($0) / 2_048 }
        let frame = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: samples, sampleRate: 48_000))
        #expect(frame.pcm == Array(samples.suffix(1_024)))
    }

    @Test func classicPeakHoldConsumesAnalyzedPCMFramesAndClearsWhenUnavailable() {
        let bands = [Float](arrayLiteral: 0.8, 0.25, 0.05)
        let view = VisualizationRenderView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        view.mode = .classicPeakHold
        view.update(.analysis(VisualizationAnalysisFrame(bands: bands, waveform: [0, 0.5, 0])))

        #expect(view.peakHoldBands == bands)

        view.update(.analysis(VisualizationAnalysisFrame(bands: [0.1, 0.1, 0.1], waveform: [0, 0, 0])))
        #expect(abs(view.peakHoldBands[0] - 0.775) < 0.0001)
        #expect(abs(view.peakHoldBands[1] - 0.225) < 0.0001)

        view.update(.unavailable("Hosted audio does not expose PCM."))
        #expect(view.peakHoldBands.isEmpty)
    }

    @Test func inlineVisualizationModeCanSwitchAndPeakHoldClearsOnSilence() {
        let store = VisualizationFrameStore()
        store.update(.analysis(VisualizationAnalysisFrame(bands: [0.5, 0.2], waveform: [0, 0.5, 0])))
        #expect(store.peakHoldBands == [0.5, 0.2])

        store.selectInlineMode(.waveform)
        #expect(store.inlineMode == .waveform)
        store.toggleInlineMode()
        #expect(store.inlineMode == .spectrum)

        store.update(.silent)
        #expect(store.peakHoldBands.isEmpty)
    }

    @Test func pcmAnalyzerPlacesTonesInExpectedLogBands() {
        let sampleCount = 2_048
        let frequencies: [(hertz: Double, expectedBand: Int)] = [
            (100, 10), (1_000, 26), (10_000, 42)
        ]

        for sampleRate in [44_100.0, 48_000.0] {
            for tone in frequencies {
                let samples = (0..<sampleCount).map { index in
                    Float(0.7 * sin(2 * Double.pi * tone.hertz * Double(index) / sampleRate))
                }
                let frame = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: samples, sampleRate: sampleRate))
                let dominantBand = frame.bands.indices.max(by: { frame.bands[$0] < frame.bands[$1] })!

                #expect(abs(dominantBand - tone.expectedBand) <= 2, "\(tone.hertz) Hz at \(sampleRate) Hz peaked in band \(dominantBand)")
                #expect(frame.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
                #expect(frame.waveform.count == 96)
                #expect(frame.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
            }
        }
    }
}
