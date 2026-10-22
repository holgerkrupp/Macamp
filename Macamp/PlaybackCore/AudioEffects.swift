import Foundation

struct AudioEffectCapabilities: OptionSet, Sendable {
    let rawValue: UInt8
    static let enable = Self(rawValue: 1 << 0)
    static let preamp = Self(rawValue: 1 << 1)
    static let equalizerBands = Self(rawValue: 1 << 2)
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
    private(set) var bandGains: [EqualizerBand: Float] = [:]

    init(isEnabled: Bool = false, preampGain: Float = 0, bandGains: [EqualizerBand: Float] = [:]) {
        self.isEnabled = isEnabled
        self.preampGain = Self.validGain(preampGain)
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
        bandGains = Dictionary(uniqueKeysWithValues: EqualizerBand.winamp10.map { band in
            (band, Self.validGain(bandGains[band] ?? 0))
        })
    }

    private static func validGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return 0 }
        return min(max(gain, -12), 12)
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, preampGain, bandGains }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            preampGain: try values.decodeIfPresent(Float.self, forKey: .preampGain) ?? 0,
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
