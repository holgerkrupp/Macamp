import Foundation

enum PlaylistFileParser {
    static func parse(data: Data, playlistURL: URL) throws -> [M3UPlaylistEntry] {
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw ProviderError(code: .invalidResponse, message: "The playlist is larger than 8 MiB.")
        }
        return try switch playlistURL.pathExtension.lowercased() {
        case "pls": try parsePLS(data: data, playlistURL: playlistURL)
        case "xspf": try parseXSPF(data: data, playlistURL: playlistURL)
        case "cue": try parseCUE(data: data, playlistURL: playlistURL)
        default: throw ProviderError(code: .unsupported, message: "That playlist format is not supported.")
        }
    }

    private static func parsePLS(data: Data, playlistURL: URL) throws -> [M3UPlaylistEntry] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ProviderError(code: .invalidResponse, message: "The PLS playlist is not valid text.")
        }
        var values: [Int: [String: String]] = [:]
        for line in text.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = key.drop { !$0.isNumber }
            guard let index = Int(digits), index > 0 else { continue }
            let field = String(key.prefix { !$0.isNumber }).lowercased()
            values[index, default: [:]][field] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values.keys.sorted().compactMap { index in
            guard let fields = values[index], let file = fields["file"],
                  let url = M3UPlaylistParser.resolvedURL(file, relativeTo: playlistURL) else { return nil }
            let duration = fields["length"].flatMap(Double.init).flatMap { $0 >= 0 ? Duration.seconds($0) : nil }
            return M3UPlaylistEntry(url: url, title: fields["title"], duration: duration)
        }
    }

    private static func parseXSPF(data: Data, playlistURL: URL) throws -> [M3UPlaylistEntry] {
        let delegate = XSPFPlaylistDelegate(playlistURL: playlistURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw ProviderError(code: .invalidResponse, message: "The XSPF playlist is invalid XML.")
        }
        return delegate.entries
    }

    private static func parseCUE(data: Data, playlistURL: URL) throws -> [M3UPlaylistEntry] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ProviderError(code: .invalidResponse, message: "The CUE sheet is not valid text.")
        }
        struct CueTrack {
            var number: String
            var file: String
            var title: String?
            var artist: String?
            var start: Double?
        }
        var defaultArtist: String?
        var currentFile: String?
        var tracks: [CueTrack] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(where: \.isWhitespace) else { continue }
            let command = line[..<separator].uppercased()
            let arguments = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch command {
            case "FILE":
                currentFile = cueFirstValue(arguments)
            case "TRACK":
                let parts = arguments.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[1].uppercased().hasPrefix("AUDIO"),
                      let currentFile else { continue }
                tracks.append(CueTrack(number: String(parts[0]), file: currentFile, title: nil, artist: defaultArtist, start: nil))
            case "PERFORMER":
                let value = cueFirstValue(arguments)
                if tracks.isEmpty { defaultArtist = value }
                else { tracks[tracks.count - 1].artist = value }
            case "TITLE":
                guard !tracks.isEmpty else { continue }
                tracks[tracks.count - 1].title = cueFirstValue(arguments)
            case "INDEX":
                let parts = arguments.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[0] == "01", !tracks.isEmpty,
                      let seconds = cueTime(String(parts[1])) else { continue }
                tracks[tracks.count - 1].start = seconds
            default:
                continue
            }
        }
        let resolved = tracks.enumerated().compactMap { index, track -> M3UPlaylistEntry? in
            guard let start = track.start,
                  let url = M3UPlaylistParser.resolvedURL(track.file, relativeTo: playlistURL) else { return nil }
            let nextStart = tracks.dropFirst(index + 1).first { $0.file == track.file }?.start
            let end: Double? = nextStart.flatMap { next -> Double? in
                guard next > start else { return nil }
                return next
            }
            let duration = end.flatMap { end in track.start.map { Duration.seconds(end - $0) } }
            return M3UPlaylistEntry(
                url: url,
                title: track.title ?? url.deletingPathExtension().lastPathComponent,
                artist: track.artist,
                duration: duration,
                sourceStartSeconds: start,
                sourceEndSeconds: end,
                occurrenceID: "cue:\(track.number):\(index)"
            )
        }
        guard !resolved.isEmpty else {
            throw ProviderError(code: .invalidResponse, message: "The CUE sheet contains no audio tracks with file references.")
        }
        return resolved
    }

    private static func cueFirstValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "\"", let end = trimmed.dropFirst().firstIndex(of: "\"") else {
            return String(trimmed.split(whereSeparator: \.isWhitespace).first ?? "")
        }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
    }

    private static func cueTime(_ value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3, parts[0] >= 0, parts[1] >= 0, parts[1] < 60, parts[2] >= 0, parts[2] < 75 else { return nil }
        return parts[0] * 60 + parts[1] + parts[2] / 75
    }
}

private final class XSPFPlaylistDelegate: NSObject, XMLParserDelegate {
    private let playlistURL: URL
    private var elementName = ""
    private var value = ""
    private var track: (location: String?, title: String?, artist: String?, duration: Double?)?
    private(set) var entries: [M3UPlaylistEntry] = []

    init(playlistURL: URL) { self.playlistURL = playlistURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        self.elementName = elementName.lowercased()
        value = ""
        if self.elementName == "track" { track = (nil, nil, nil, nil) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let content = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard track != nil else { return }
        switch name {
        case "location": track?.location = content
        case "title": track?.title = content
        case "creator": track?.artist = content
        case "duration": track?.duration = Double(content).map { $0 / 1_000 }
        case "track":
            if let current = track, let location = current.location,
               let url = M3UPlaylistParser.resolvedURL(location, relativeTo: playlistURL) {
                entries.append(M3UPlaylistEntry(url: url, title: current.title, artist: current.artist, duration: current.duration.map(Duration.seconds)))
            }
            track = nil
        default: break
        }
        value = ""
    }
}
