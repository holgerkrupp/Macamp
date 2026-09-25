import CoreGraphics
import Foundation

enum AudioAnalysisMode: String, Codable, Sendable { case simulated, pcm, spectrum, waveform, unavailable }

struct SimulatedFrame: Equatable, Sendable {
    var bands: [Float]
    var waveform: [Float]
    var seed: UInt64
}

struct SpectrumFrame: Equatable, Sendable { var magnitudes: [Float] }
struct WaveformFrame: Equatable, Sendable { var samples: [Float] }
struct PCMFrame: @unchecked Sendable { var samples: [Float]; var sampleRate: Double }

enum VisualizationAudioData: Sendable {
    case pcm(PCMFrame)
    case spectrum(SpectrumFrame)
    case waveform(WaveformFrame)
    case simulated(SimulatedFrame)
    case silent
}

struct VisualizationPreset: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var engineIdentifier: String
    var frameRate = 30
    var motionIntensity = 0.7
    var smoothing = 0.65
    var peakDecay = 0.03
    var seed: UInt64 = 0x4D4143414D50

    func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw ProviderError(code: .invalidResponse, message: "Visualization preset version \(version) is not supported.")
        }
        return self
    }
}

protocol AudioAnalysisSource: AnyObject {
    var mode: AudioAnalysisMode { get }
    @MainActor func start() async throws
    @MainActor func stop() async
    @MainActor func frames() -> AsyncStream<VisualizationAudioData>
}
