import Foundation
import Testing
@testable import Macamp

@Suite
@MainActor
struct VisualizationTests {
    @Test func simulatedFramesAreDeterministic() {
        let coordinator = PlaybackCoordinator()
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
}
