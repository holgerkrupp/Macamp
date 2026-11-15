import AVFoundation
import Foundation
@testable import Macamp

func writeSilentWaveFixture(to url: URL, duration: TimeInterval = 0.1) throws {
    let sampleRate = 44_100.0
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ])
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        throw ProviderError(code: .unknown, message: "Could not create test audio buffer.")
    }
    buffer.frameLength = frameCount
    try file.write(from: buffer)
}

@MainActor
func makeIsolatedUnifiedPlaylistStore() -> UnifiedPlaylistStore {
    let suiteName = "MacampTests.UnifiedPlaylist.\(UUID().uuidString)"
    return UnifiedPlaylistStore(defaults: UserDefaults(suiteName: suiteName)!, storageKey: "playlist")
}
