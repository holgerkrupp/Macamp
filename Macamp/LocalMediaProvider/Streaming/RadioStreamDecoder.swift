import AudioToolbox
import Foundation
import Synchronization

/// Progressive HTTP MP3/AAC decoder. HLS and unsupported server formats should
/// remain on AVPlayer; this path only emits PCM after AudioFileStream identifies
/// MP3 or AAC and AudioConverter has decoded enough audio to start safely.
@MainActor
final class RadioStreamDecoder {
    private let ring: RadioPCMRingBuffer
    private let decodeQueue = DispatchQueue(label: "dev.holgerkrupp.Macamp.radio-decode", qos: .userInitiated)
    private let generation = RadioStreamGeneration()
    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var delegate: RadioStreamSessionDelegate?
    private var context: RadioStreamDecodeContext?
    private var readyGeneration: UInt64?

    var onReady: (@MainActor (Double) -> Void)?
    var onMetadata: (@MainActor (ICYFramer.ICYMetadata) -> Void)?
    var onUnsupported: (@MainActor (String) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    init(ring: RadioPCMRingBuffer, sessionConfiguration: URLSessionConfiguration = .default) {
        self.ring = ring
        self.sessionConfiguration = sessionConfiguration
    }

    func start(url: URL) {
        stop()
        let current = generation.value.load(ordering: .acquiring) &+ 1
        generation.value.store(current, ordering: .releasing)
        readyGeneration = nil

        let context = RadioStreamDecodeContext(
            queue: decodeQueue,
            ring: ring,
            generation: generation,
            expectedGeneration: current,
            onReady: { [weak self] sampleRate in
                Task { @MainActor [weak self] in
                    guard let self, self.generation.value.load(ordering: .acquiring) == current,
                          self.readyGeneration != current else { return }
                    self.readyGeneration = current
                    self.onReady?(sampleRate)
                }
            },
            onMetadata: { [weak self] metadata in
                Task { @MainActor [weak self] in
                    guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                    self.onMetadata?(metadata)
                }
            },
            onUnsupported: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                    self.onUnsupported?(message)
                }
            }
        )
        self.context = context
        let ring = self.ring
        let generationToken = generation
        let decodeQueue = self.decodeQueue
        decodeQueue.async {
            ring.reset()
            context.initialize(formatHint: Self.formatHint(for: url))
        }

        let proxy = RadioStreamSessionDelegate(
            onResponse: { [weak self, weak context] response in
                guard generationToken.value.load(ordering: .acquiring) == current else { return }
                guard let http = response as? HTTPURLResponse else {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                        self.onUnsupported?("The station did not return an HTTP audio stream.")
                    }
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let message = "The station returned HTTP \(http.statusCode)."
                    Task { @MainActor [weak self] in
                        guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                        self.onFailure?(message)
                    }
                    return
                }
                let mime = (http.mimeType ?? "").lowercased()
                if mime.contains("mpegurl") || mime.contains("x-mpegurl") {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                        self.onUnsupported?("HLS stations continue to use AVPlayer.")
                    }
                    return
                }
                if let context { context.configure(metaInterval: Self.metadataInterval(http.allHeaderFields)) }
            },
            onData: { [weak context] data in
                guard generationToken.value.load(ordering: .acquiring) == current else { return }
                context?.receive(data)
            },
            onComplete: { [weak self] error in
                decodeQueue.async { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation.value.load(ordering: .acquiring) == current else { return }
                        self.onFailure?(error?.localizedDescription ?? "The station closed its stream.")
                    }
                }
            }
        )
        delegate = proxy
        let configuration = sessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: proxy, delegateQueue: delegateQueue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("audio/mpeg,audio/aac,audio/aacp,audio/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func stop() {
        generation.value.store(generation.value.load(ordering: .acquiring) &+ 1, ordering: .releasing)
        readyGeneration = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        let oldContext = context
        context = nil
        if let oldContext { oldContext.shutdown() }
    }

    nonisolated private static func formatHint(for url: URL) -> AudioFileTypeID {
        switch url.pathExtension.lowercased() {
        case "mp3": kAudioFileMP3Type
        case "aac", "aacp": kAudioFileAAC_ADTSType
        default: 0
        }
    }

    nonisolated private static func metadataInterval(_ headers: [AnyHashable: Any]) -> Int {
        for (key, value) in headers {
            guard String(describing: key).lowercased() == "icy-metaint",
                  let count = Int(String(describing: value)), count > 0 else { continue }
            return count
        }
        return 0
    }
}

nonisolated final class RadioStreamDecodeContext: @unchecked Sendable {
    private let queue: DispatchQueue
    private let ring: RadioPCMRingBuffer
    private let generation: RadioStreamGeneration
    private let expectedGeneration: UInt64
    private let onReady: @Sendable (Double) -> Void
    private let onMetadata: @Sendable (ICYFramer.ICYMetadata) -> Void
    private let onUnsupported: @Sendable (String) -> Void
    private var framer = ICYFramer()
    private var parser: AudioFileStreamParser?
    private var decoder: AudioConverterDecoder?
    private var magicCookie: Data?
    private var isReady = false
    private var isShutdown = false
    private var didReportFailure = false

    init(
        queue: DispatchQueue,
        ring: RadioPCMRingBuffer,
        generation: RadioStreamGeneration,
        expectedGeneration: UInt64,
        onReady: @escaping @Sendable (Double) -> Void,
        onMetadata: @escaping @Sendable (ICYFramer.ICYMetadata) -> Void,
        onUnsupported: @escaping @Sendable (String) -> Void
    ) {
        self.queue = queue
        self.ring = ring
        self.generation = generation
        self.expectedGeneration = expectedGeneration
        self.onReady = onReady
        self.onMetadata = onMetadata
        self.onUnsupported = onUnsupported
    }

    func initialize(formatHint: AudioFileTypeID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isShutdown, isCurrent else { return }
        let parser = AudioFileStreamParser(formatHint: formatHint)
        parser.confinementQueue = queue
        parser.onFormatAvailable = { [weak self] format in self?.handleFormat(format) }
        parser.onMagicCookie = { [weak self] cookie in self?.magicCookie = cookie }
        parser.onPackets = { [weak self] data, descriptions in self?.decode(data, descriptions: descriptions) }
        parser.onError = { [weak self] message in self?.reportUnsupported(message) }
        self.parser = parser
        if let message = parser.initError { reportUnsupported(message) }
    }

    func configure(metaInterval: Int) {
        queue.async { [self] in
            guard !isShutdown, isCurrent else { return }
            framer.configure(metaInterval: metaInterval)
        }
    }

    func receive(_ data: Data) {
        queue.async { [self] in
            guard !isShutdown, isCurrent, !didReportFailure else { return }
            for chunk in framer.consume(data) {
                switch chunk {
                case .audio(let bytes): parser?.parse(bytes)
                case .metadata(let metadata): onMetadata(metadata)
                }
            }
        }
    }

    func shutdown() {
        queue.async { [self] in
            guard !isShutdown else { return }
            isShutdown = true
            decoder?.dispose()
            decoder = nil
            parser?.close()
            parser = nil
        }
    }

    private func handleFormat(_ format: AudioStreamBasicDescription) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard format.mFormatID == kAudioFormatMPEGLayer3 || format.mFormatID == kAudioFormatMPEG4AAC else {
            reportUnsupported("This station's audio format is not supported for decoded playback.")
            return
        }
        guard decoder == nil else { return }
        let decoder = AudioConverterDecoder(inputFormat: format, magicCookie: magicCookie)
        guard decoder.converter != nil else {
            reportUnsupported("Macamp could not create a decoder for this station.")
            return
        }
        decoder.confinementQueue = queue
        self.decoder = decoder
    }

    private func decode(_ data: Data, descriptions: [AudioStreamPacketDescription]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isShutdown, isCurrent, !didReportFailure, let decoder else { return }
        if descriptions.isEmpty {
            decoder.enqueue(data: data, descriptions: [])
        } else {
            for description in descriptions {
                let start = Int(description.mStartOffset)
                let size = Int(description.mDataByteSize)
                guard start >= 0, size > 0, start + size <= data.count else { continue }
                let single = AudioStreamPacketDescription(
                    mStartOffset: 0,
                    mVariableFramesInPacket: description.mVariableFramesInPacket,
                    mDataByteSize: description.mDataByteSize
                )
                decoder.enqueue(data: Data(data[start..<(start + size)]), descriptions: [single])
            }
        }
        while decoder.hasQueuedPackets {
            guard isCurrent else { return }
            guard let (pcm, frameCount) = decoder.decode() else {
                if let status = decoder.lastDecodeError {
                    reportUnsupported("The station stream could not be decoded (AudioConverter status \(status)).")
                }
                return
            }
            _ = ring.write(from: pcm, frameCount: frameCount)
            if !isReady, ring.availableFrames >= 12_000 {
                isReady = true
                onReady(decoder.sampleRate)
            }
        }
    }

    private func reportUnsupported(_ message: String) {
        guard isCurrent, !didReportFailure else { return }
        didReportFailure = true
        onUnsupported(message)
    }

    private var isCurrent: Bool {
        generation.value.load(ordering: .acquiring) == expectedGeneration
    }
}

nonisolated final class RadioStreamGeneration: @unchecked Sendable {
    let value = Atomic<UInt64>(0)
}

private nonisolated final class RadioStreamSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onResponse: @Sendable (URLResponse) -> Void
    private let onData: @Sendable (Data) -> Void
    private let onComplete: @Sendable (Error?) -> Void

    init(
        onResponse: @escaping @Sendable (URLResponse) -> Void,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        onResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { onData(data) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error)
    }
}
