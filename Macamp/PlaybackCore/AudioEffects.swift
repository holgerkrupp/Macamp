import AVFoundation
import Foundation

struct AudioEffectCapabilities: OptionSet, Sendable {
    let rawValue: UInt8
    static let enable = Self(rawValue: 1 << 0)
    static let preamp = Self(rawValue: 1 << 1)
    static let equalizerBands = Self(rawValue: 1 << 2)
    static let pitch = Self(rawValue: 1 << 3)
    static let tempo = Self(rawValue: 1 << 4)
    static let reverb = Self(rawValue: 1 << 5)
    static let crossfade = Self(rawValue: 1 << 6)
}

struct EqualizerBand: Hashable, Codable, Sendable {
    var centerFrequency: Float

    static let winamp10: [Self] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
        .map { Self(centerFrequency: Float($0)) }
}
/// The single Winamp-style profile shared by every UI surface. Gains are kept
/// in dB and bounded to the range exposed by the classic controls.
struct AudioEffectState: Equatable, Codable, Sendable {
    var isEnabled = false
    var preampGain: Float = 0
    var pitchSemitones: Float = 0
    var tempoRate: Float = 1
    var reverbMix: Float = 0
    var advancedEffectsEnabled = false
    var crossfadeDuration: Float = 0
    private(set) var bandGains: [EqualizerBand: Float] = [:]

    init(
        isEnabled: Bool = false,
        preampGain: Float = 0,
        pitchSemitones: Float = 0,
        tempoRate: Float = 1,
        reverbMix: Float = 0,
        advancedEffectsEnabled: Bool = false,
        crossfadeDuration: Float = 0,
        bandGains: [EqualizerBand: Float] = [:]
    ) {
        self.isEnabled = isEnabled
        self.preampGain = Self.validGain(preampGain)
        self.pitchSemitones = Self.validPitch(pitchSemitones)
        self.tempoRate = Self.validTempo(tempoRate)
        self.reverbMix = Self.validReverb(reverbMix)
        self.advancedEffectsEnabled = advancedEffectsEnabled
        self.crossfadeDuration = Self.validCrossfade(crossfadeDuration)
        self.bandGains = Dictionary(uniqueKeysWithValues: EqualizerBand.winamp10.map { band in
            (band, Self.validGain(bandGains[band] ?? 0))
        })
    }

    func gain(for band: EqualizerBand) -> Float {
        bandGains[band] ?? 0
    }

    mutating func setGain(_ value: Float, for band: EqualizerBand) {
        guard EqualizerBand.winamp10.contains(band) else { return }
        bandGains[band] = Self.validGain(value)
    }

    mutating func validate() {
        preampGain = Self.validGain(preampGain)
        pitchSemitones = Self.validPitch(pitchSemitones)
        tempoRate = Self.validTempo(tempoRate)
        reverbMix = Self.validReverb(reverbMix)
        crossfadeDuration = Self.validCrossfade(crossfadeDuration)
        bandGains = Dictionary(uniqueKeysWithValues: EqualizerBand.winamp10.map { band in
            (band, Self.validGain(bandGains[band] ?? 0))
        })
    }

    private static func validGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return 0 }
        return min(max(gain, -12), 12)
    }

    private static func validPitch(_ value: Float) -> Float { value.isFinite ? min(max(value, -12), 12) : 0 }
    private static func validTempo(_ value: Float) -> Float { value.isFinite ? min(max(value, 0.5), 2) : 1 }
    private static func validReverb(_ value: Float) -> Float { value.isFinite ? min(max(value, 0), 100) : 0 }
    private static func validCrossfade(_ value: Float) -> Float { value.isFinite ? min(max(value, 0), 12) : 0 }

    private enum CodingKeys: String, CodingKey { case isEnabled, preampGain, pitchSemitones, tempoRate, reverbMix, advancedEffectsEnabled, crossfadeDuration, bandGains }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            preampGain: try values.decodeIfPresent(Float.self, forKey: .preampGain) ?? 0,
            pitchSemitones: try values.decodeIfPresent(Float.self, forKey: .pitchSemitones) ?? 0,
            tempoRate: try values.decodeIfPresent(Float.self, forKey: .tempoRate) ?? 1,
            reverbMix: try values.decodeIfPresent(Float.self, forKey: .reverbMix) ?? 0,
            advancedEffectsEnabled: try values.decodeIfPresent(Bool.self, forKey: .advancedEffectsEnabled) ?? false,
            crossfadeDuration: try values.decodeIfPresent(Float.self, forKey: .crossfadeDuration) ?? 0,
            bandGains: try values.decodeIfPresent([EqualizerBand: Float].self, forKey: .bandGains) ?? [:]
        )
    }
}

@MainActor
protocol AudioEffectController: AnyObject {
    var effectCapabilities: AudioEffectCapabilities { get }
    var effectState: AudioEffectState { get }
    var effectUnavailableReason: String? { get }
    func setEnabled(_ enabled: Bool) async throws
    func setPreampGain(_ value: Float) async throws
    func setBandGain(_ value: Float, band: EqualizerBand) async throws
    func setPitchSemitones(_ value: Float) async throws
    func setTempoRate(_ value: Float) async throws
    func setReverbMix(_ value: Float) async throws
    func setAdvancedEffectsEnabled(_ enabled: Bool) async throws
    func setCrossfadeDuration(_ value: Float) async throws
}

extension AudioEffectController {
    func setPitchSemitones(_ value: Float) async throws { throw ProviderError.unsupported("pitch") }
    func setTempoRate(_ value: Float) async throws { throw ProviderError.unsupported("tempo") }
    func setReverbMix(_ value: Float) async throws { throw ProviderError.unsupported("reverb") }
    func setAdvancedEffectsEnabled(_ enabled: Bool) async throws { throw ProviderError.unsupported("local effects bypass") }
    func setCrossfadeDuration(_ value: Float) async throws { throw ProviderError.unsupported("crossfade") }
}

/// Apple Music does not expose protected decoded audio to this app, so its skinned EQ
/// can only be visual. Calls fail explicitly instead of implying that DSP is active.
final class UnsupportedAudioEffectController: AudioEffectController {
    let effectCapabilities: AudioEffectCapabilities = []
    let effectState = AudioEffectState()
    let effectUnavailableReason: String? = "Equalizer unavailable for this provider's audio source."
    func setEnabled(_ enabled: Bool) async throws { throw ProviderError.unsupported("audio effects") }
    func setPreampGain(_ value: Float) async throws { throw ProviderError.unsupported("preamp gain") }
    func setBandGain(_ value: Float, band: EqualizerBand) async throws { throw ProviderError.unsupported("equalizer bands") }
}

/// Applies the app's production Winamp-style band layout and state to the
/// AVAudioUnitEQ used for decoded local playback.
enum LocalFileEqualizerDSP {
    static func configure(_ equalizer: AVAudioUnitEQ, state: AudioEffectState) {
        precondition(equalizer.bands.count == EqualizerBand.winamp10.count)
        for (index, band) in equalizer.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EqualizerBand.winamp10[index].centerFrequency
            band.bandwidth = 1
            band.gain = state.gain(for: EqualizerBand.winamp10[index])
            band.bypass = false
        }
        equalizer.globalGain = state.preampGain
        equalizer.bypass = !state.isEnabled
    }
}

enum LocalFileAudioEffectsDSP {
    static func configure(timePitch: AVAudioUnitTimePitch, reverb: AVAudioUnitReverb, state: AudioEffectState) {
        timePitch.pitch = state.advancedEffectsEnabled ? state.pitchSemitones * 100 : 0
        timePitch.rate = state.advancedEffectsEnabled ? state.tempoRate : 1
        reverb.wetDryMix = state.advancedEffectsEnabled ? state.reverbMix : 0
    }
}
