import Foundation

struct AudioEffectCapabilities: OptionSet, Sendable {
    let rawValue: UInt8
    static let enable = Self(rawValue: 1 << 0)
    static let preamp = Self(rawValue: 1 << 1)
    static let equalizerBands = Self(rawValue: 1 << 2)
}

struct EqualizerBand: Hashable, Sendable {
    var centerFrequency: Float

    static let winamp10: [Self] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
        .map { Self(centerFrequency: Float($0)) }
}
struct AudioEffectState: Equatable, Sendable { var isEnabled = false; var preampGain: Float = 0; var bandGains: [EqualizerBand: Float] = [:] }

@MainActor
protocol AudioEffectController: AnyObject {
    var effectCapabilities: AudioEffectCapabilities { get }
    var effectState: AudioEffectState { get }
    func setEnabled(_ enabled: Bool) async throws
    func setPreampGain(_ value: Float) async throws
    func setBandGain(_ value: Float, band: EqualizerBand) async throws
}

/// Apple Music does not expose protected decoded audio to this app, so its skinned EQ
/// can only be visual. Calls fail explicitly instead of implying that DSP is active.
final class UnsupportedAudioEffectController: AudioEffectController {
    let effectCapabilities: AudioEffectCapabilities = []
    let effectState = AudioEffectState()
    func setEnabled(_ enabled: Bool) async throws { throw ProviderError.unsupported("audio effects") }
    func setPreampGain(_ value: Float) async throws { throw ProviderError.unsupported("preamp gain") }
    func setBandGain(_ value: Float, band: EqualizerBand) async throws { throw ProviderError.unsupported("equalizer bands") }
}
