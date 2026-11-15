import Foundation
import AudioToolbox
import Testing
@testable import Macamp

private final class RadioTestBundleToken: NSObject {}
private enum RadioDecodeTestEvent: Sendable, Equatable {
    case ready(Double)
    case metadata(String?, String?)
    case unsupported(String)
}

nonisolated private final class RadioTestURLScript: @unchecked Sendable {
    private let lock = NSLock()
    private var audioData = Data()
    private var requestCounter = 0
    private var recordedEvents: [RadioDecodeTestEvent] = []

    func configure(audioData: Data) {
        lock.lock(); defer { lock.unlock() }
        self.audioData = audioData
        requestCounter = 0
        recordedEvents = []
    }

    func nextResponse() -> (data: Data, requestNumber: Int) {
        lock.lock(); defer { lock.unlock() }
        requestCounter += 1
        return (audioData, requestCounter)
    }

    var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounter
    }

    func record(_ event: RadioDecodeTestEvent) {
        lock.lock(); defer { lock.unlock() }
        recordedEvents.append(event)
    }

    var events: [RadioDecodeTestEvent] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }
}

nonisolated private final class RadioTestURLProtocol: URLProtocol {
    static let script = RadioTestURLScript()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "radio.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = Self.script.nextResponse()
        let http = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/mpeg", "icy-metaint": "256"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() {}
}

@Suite("Progressive radio audio")
struct RadioStreamDecoderTests {
    @Test func stripsSplitICYMetadataAndKeepsAudioBytesContiguous() {
        var framer = ICYFramer()
        framer.configure(metaInterval: 4)
        var metadata = Array("StreamTitle='Artist - Song';".utf8)
        while metadata.count % 16 != 0 { metadata.append(0) }
        let first = Data(Array("ABCD".utf8) + [UInt8(metadata.count / 16)] + Array(metadata.prefix(11)))
        let second = Data(Array(metadata.dropFirst(11)) + Array("EFGH".utf8))

        let firstChunks = framer.consume(first)
        let secondChunks = framer.consume(second)
        var audio = Data()
        var stationTitle: String?
        var stationArtist: String?
        for chunk in firstChunks + secondChunks {
            switch chunk {
            case .audio(let bytes): audio.append(bytes)
            case .metadata(let value): stationTitle = value.title; stationArtist = value.artist
            }
        }

        #expect(audio == Data("ABCDEFGH".utf8))
        #expect(stationTitle == "Song")
        #expect(stationArtist == "Artist")
    }

    @Test func pcmRingBufferReadsStereoFramesWithoutCrossingChannels() {
        let ring = RadioPCMRingBuffer(capacityFrames: 4)
        let input: [Float] = [1, 10, 2, 20, 3, 30]
        let written = input.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 3) }
        var left = [Float](repeating: 0, count: 3)
        var right = [Float](repeating: 0, count: 3)
        let read = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                ring.read(left: leftBuffer.baseAddress!, right: rightBuffer.baseAddress!, frameCount: 3)
            }
        }

        #expect(written == 3)
        #expect(read == 3)
        #expect(left == [1, 2, 3])
        #expect(right == [10, 20, 30])
        #expect(ring.availableFrames == 0)
    }

    @Test func decodesMP3PacketsToPCMAtTheSharedEngineRate() async throws {
        let fixture = try #require(Bundle(for: RadioTestBundleToken.self).url(forResource: "radio-test", withExtension: "mp3"))
        let encoded = try Data(contentsOf: fixture)
        let ring = RadioPCMRingBuffer()
        let queue = DispatchQueue(label: "radio-decoder-test")
        let generation = RadioStreamGeneration()
        let (events, continuation) = AsyncStream<RadioDecodeTestEvent>.makeStream()
        let context = RadioStreamDecodeContext(
            queue: queue,
            ring: ring,
            generation: generation,
            expectedGeneration: 0,
            onReady: { continuation.yield(.ready($0)) },
            onMetadata: { _ in },
            onUnsupported: { continuation.yield(.unsupported($0)) }
        )
        queue.async { context.initialize(formatHint: kAudioFileMP3Type) }
        context.receive(encoded)

        let event = await withTaskGroup(of: RadioDecodeTestEvent?.self) { group in
            group.addTask {
                for await event in events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        context.shutdown()

        guard case .ready(let sampleRate)? = event else {
            Issue.record("The MP3 stream did not decode before the timeout or returned an error: \(String(describing: event))")
            return
        }
        #expect(sampleRate == 48_000)
        #expect(ring.availableFrames >= 12_000)
    }

    @Test func controlledHTTPDisconnectReconnectsAndDeliversICYMetadata() async throws {
        let fixture = try #require(Bundle(for: RadioTestBundleToken.self).url(forResource: "radio-test", withExtension: "mp3"))
        let encoded = try Data(contentsOf: fixture)
        RadioTestURLProtocol.script.configure(audioData: Self.streamWithICYMetadata(encoded, interval: 256))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RadioTestURLProtocol.self]
        let decoder = RadioStreamDecoder(ring: RadioPCMRingBuffer(), sessionConfiguration: configuration)
        decoder.onReady = { RadioTestURLProtocol.script.record(.ready($0)) }
        decoder.onMetadata = { RadioTestURLProtocol.script.record(.metadata($0.title, $0.artist)) }
        decoder.onUnsupported = { RadioTestURLProtocol.script.record(.unsupported($0)) }
        decoder.onFailure = { message in
            RadioTestURLProtocol.script.record(.unsupported(message))
            if RadioTestURLProtocol.script.requests == 1 {
                decoder.start(url: URL(string: "http://radio.test/live.mp3")!)
            }
        }
        decoder.start(url: URL(string: "http://radio.test/live.mp3")!)
        try await Task.sleep(for: .milliseconds(500))
        decoder.stop()

        let events = RadioTestURLProtocol.script.events
        #expect(events.filter { if case .ready = $0 { true } else { false } }.count == 2)
        #expect(events.contains(.metadata("Song", "Artist")))
        #expect(RadioTestURLProtocol.script.requests == 2)
    }

    private static func streamWithICYMetadata(_ audio: Data, interval: Int) -> Data {
        var metadata = Array("StreamTitle='Artist - Song';".utf8)
        while metadata.count % 16 != 0 { metadata.append(0) }
        var result = Data()
        var offset = 0
        while offset < audio.count {
            let end = min(offset + interval, audio.count)
            result.append(audio[offset..<end])
            offset = end
            if offset < audio.count {
                result.append(UInt8(metadata.count / 16))
                result.append(contentsOf: metadata)
            }
        }
        return result
    }
}
