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

        let short = VisualizationPCMAnalyzer.analyze(PCMFrame(samples: [0.25], sampleRate: 48_000))
        #expect(short.bands.count == 48)
        #expect(short.waveform.count == 96)
        #expect(short.bands.allSatisfy { $0.isFinite })
        #expect(short.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
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
