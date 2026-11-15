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

struct VisualizationAnalysisFrame: Equatable, Sendable {
    var bands: [Float]
    var waveform: [Float]
    var pcm: [Float] = []
}

enum InlineVisualizationMode: String, CaseIterable, Sendable {
    case spectrum
    case waveform
}

struct PeakHoldEnvelope: Equatable, Sendable {
    private(set) var values: [Float] = []

    mutating func update(_ bands: [Float]?, decay: Float = 0.025) {
        guard let bands, !bands.isEmpty else {
            values = []
            return
        }
        if values.count != bands.count { values = Array(repeating: 0, count: bands.count) }
        let boundedDecay = decay.isFinite ? min(max(decay, 0), 1) : 0
        for index in bands.indices {
            let level = bands[index].isFinite ? min(max(bands[index], 0), 1) : 0
            values[index] = max(level, max(0, values[index] - boundedDecay))
        }
    }
}

enum VisualizationAudioData: Sendable {
    case pcm(PCMFrame)
    case spectrum(SpectrumFrame)
    case waveform(WaveformFrame)
    case simulated(SimulatedFrame)
    case analysis(VisualizationAnalysisFrame)
    case unavailable(String)
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
