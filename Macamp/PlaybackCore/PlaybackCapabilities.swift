import Foundation

struct PlaybackCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: UInt64

    static let playback = Self(rawValue: 1 << 0)
    static let pause = Self(rawValue: 1 << 1)
    static let explicitStop = Self(rawValue: 1 << 2)
    static let seek = Self(rawValue: 1 << 3)
    static let previous = Self(rawValue: 1 << 4)
    static let next = Self(rawValue: 1 << 5)
    static let queueReading = Self(rawValue: 1 << 6)
    static let queueEditing = Self(rawValue: 1 << 7)
    static let shuffle = Self(rawValue: 1 << 8)
    static let `repeat` = Self(rawValue: 1 << 9)
    static let applicationVolume = Self(rawValue: 1 << 10)
    static let catalogueSearch = Self(rawValue: 1 << 11)
    static let userLibrary = Self(rawValue: 1 << 12)
    static let playlists = Self(rawValue: 1 << 13)
    static let localMetadata = Self(rawValue: 1 << 14)
    static let artwork = Self(rawValue: 1 << 15)
    static let pcmAudio = Self(rawValue: 1 << 16)
    static let frequencySpectrum = Self(rawValue: 1 << 17)
    static let waveform = Self(rawValue: 1 << 18)
    static let nativeEqualizer = Self(rawValue: 1 << 19)
    static let remoteDeviceControl = Self(rawValue: 1 << 20)
    static let backgroundPlayback = Self(rawValue: 1 << 21)

    static let basicTransport: Self = [.playback, .pause, .previous, .next]

    var labels: [String] {
        let values: [(Self, String)] = [
            (.playback, "Playback"), (.pause, "Pause"), (.explicitStop, "Stop"),
            (.seek, "Seek"), (.previous, "Previous"), (.next, "Next"),
            (.queueReading, "Queue reading"), (.queueEditing, "Queue editing"),
            (.shuffle, "Shuffle"), (.repeat, "Repeat"), (.applicationVolume, "App volume"),
            (.catalogueSearch, "Catalogue search"), (.userLibrary, "Music library"),
            (.playlists, "Playlists"), (.localMetadata, "Local metadata"),
            (.artwork, "Artwork"), (.pcmAudio, "PCM audio"),
            (.frequencySpectrum, "Spectrum"), (.waveform, "Waveform"),
            (.nativeEqualizer, "Equalizer"), (.remoteDeviceControl, "Remote devices"),
            (.backgroundPlayback, "Background playback")
        ]
        return values.compactMap { contains($0.0) ? $0.1 : nil }
    }
}
