import AVFoundation
import AppKit
import CryptoKit
import Foundation
import Observation

struct AudioCDTrack: Identifiable, Sendable, Equatable {
    let discID: String
    let number: Int
    let url: URL
    let duration: TimeInterval
    var id: String { "\(discID):\(number)" }
    var title: String { "Track \(number)" }
}

enum AudioCDRipFormat: String, CaseIterable, Identifiable {
    case aiff
    case m4a

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

enum AudioCDError: LocalizedError {
    case unsupportedDisc
    case noAudioTracks
    case missingTrack(Int)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDisc: "This disc is unreadable or does not expose mounted audio tracks. Mixed-mode discs may not be supported by this drive."
        case .noAudioTracks: "No audio tracks were found on this disc."
        case let .missingTrack(number): "Audio CD track \(number) is not readable."
        case let .exportFailed(message): message
        }
    }
}

@MainActor
@Observable
final class AudioCDManager {
    private(set) var tracks: [AudioCDTrack] = []
    private(set) var volumeURL: URL?
    private(set) var statusMessage = "Insert an audio CD or choose a mounted disc."
    private(set) var isRipping = false
    private(set) var ripProgress = 0.0
    private(set) var ripDescription = ""

    @ObservationIgnored private var scopedVolumeURL: URL?
    @ObservationIgnored private var wasPresent = false
    @ObservationIgnored private var activeExport: AVAssetExportSession?

    func refresh() {
        guard let volumeURL else {
            let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            for volume in mounted {
                if let foundTracks = try? Self.readTracks(from: volume), !foundTracks.isEmpty {
                    self.volumeURL = volume
                    tracks = foundTracks
                    statusMessage = "Audio CD ready."
                    wasPresent = true
                    return
                }
            }
            return
        }

        guard FileManager.default.fileExists(atPath: volumeURL.path) else {
            tracks = []
            self.volumeURL = nil
            scopedVolumeURL?.stopAccessingSecurityScopedResource()
            scopedVolumeURL = nil
            statusMessage = wasPresent ? "The audio CD was ejected." : "Insert an audio CD or choose a mounted disc."
            wasPresent = false
            return
        }
        do {
            tracks = try Self.readTracks(from: volumeURL)
            statusMessage = tracks.isEmpty ? "No audio tracks were found on this disc." : "Audio CD ready."
            wasPresent = true
        } catch {
            tracks = []
            statusMessage = error.localizedDescription
        }
    }

    func chooseDisc() {
        let panel = NSOpenPanel()
        panel.title = "Choose Mounted Audio CD"
        panel.message = "Choose the mounted audio CD volume. Macamp reads its TOC and audio tracks."
        panel.prompt = "Use Disc"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        scopedVolumeURL?.stopAccessingSecurityScopedResource()
        let accessed = url.startAccessingSecurityScopedResource()
        scopedVolumeURL = accessed ? url : nil
        volumeURL = url
        do {
            let foundTracks = try Self.readTracks(from: url)
            tracks = foundTracks
            statusMessage = "Audio CD ready."
            wasPresent = true
        } catch {
            tracks = []
            statusMessage = error.localizedDescription
        }
    }

    func chooseDestinationFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Rip Destination"
        panel.message = "Choose a folder for the extracted audio tracks."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func rip(_ selected: [AudioCDTrack], to folder: URL, format: AudioCDRipFormat) async -> [URL] {
        guard !selected.isEmpty, !isRipping else { return [] }
        isRipping = true
        ripProgress = 0
        ripDescription = "Preparing tracks…"
        defer {
            activeExport = nil
            isRipping = false
        }

        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed { folder.stopAccessingSecurityScopedResource() }
        }

        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, track) in selected.enumerated() {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: track.url.path) else { throw AudioCDError.missingTrack(track.number) }
                let destination = Self.uniqueDestination(folder: folder, name: track.title, fileExtension: format.fileExtension)
                ripDescription = "Extracting \(track.title) (\(index + 1) of \(selected.count))"
                ripProgress = Double(index) / Double(selected.count)
                if format == .aiff {
                    try FileManager.default.copyItem(at: track.url, to: destination)
                } else {
                    try await exportM4A(from: track.url, to: destination)
                }
                written.append(destination)
                ripProgress = Double(index + 1) / Double(selected.count)
            }
            ripDescription = "Extracted \(written.count) track\(written.count == 1 ? "" : "s")."
        } catch is CancellationError {
            statusMessage = "Audio CD extraction was cancelled. Completed tracks were kept."
            ripDescription = statusMessage
        } catch {
            statusMessage = "Could not extract the selected tracks: \(error.localizedDescription)"
            ripDescription = statusMessage
        }
        return written
    }

    func cancelRip() {
        activeExport?.cancelExport()
    }

    static func readTracks(from volume: URL) throws -> [AudioCDTrack] {
        let tocURL = volume.appendingPathComponent(".TOC.plist")
        guard let data = try? Data(contentsOf: tocURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let sessions = plist["Sessions"] as? [[String: Any]],
              let session = sessions.first(where: { ($0["Session Number"] as? Int ?? 1) == 1 }) ?? sessions.first,
              let leadout = session["Leadout Block"] as? Int,
              let entries = session["Track Array"] as? [[String: Any]] else {
            throw AudioCDError.unsupportedDisc
        }
        let discID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let audioEntries = entries
            .filter { !($0["Data"] as? Bool ?? false) }
            .compactMap { entry -> (number: Int, start: Int)? in
                guard let number = entry["Point"] as? Int,
                      let start = entry["Start Block"] as? Int,
                      (1...99).contains(number) else { return nil }
                return (number, start)
            }
            .sorted { $0.number < $1.number }
        guard !audioEntries.isEmpty else { throw AudioCDError.noAudioTracks }

        let files = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        var filesByNumber: [Int: URL] = [:]
        for file in files where file.pathExtension.lowercased() == "aiff" || file.pathExtension.lowercased() == "aif" {
            guard let number = Int(file.lastPathComponent.prefix(while: \.isNumber)) else { continue }
            filesByNumber[number] = file
        }

        var result: [AudioCDTrack] = []
        for index in audioEntries.indices {
            let entry = audioEntries[index]
            guard let file = filesByNumber[entry.number] else { continue }
            let end = index + 1 < audioEntries.count ? audioEntries[index + 1].start : leadout
            guard end > entry.start else { continue }
            result.append(AudioCDTrack(discID: discID, number: entry.number, url: file, duration: Double(end - entry.start) / 75))
        }
        guard !result.isEmpty else { throw AudioCDError.noAudioTracks }
        return result
    }

    private func exportM4A(from source: URL, to destination: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCDError.exportFailed("macOS could not create an M4A audio export session.")
        }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        activeExport = exporter
        do {
            try await exporter.export(to: destination, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func uniqueDestination(folder: URL, name: String, fileExtension: String) -> URL {
        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let base = safeName.isEmpty ? "Audio Track" : safeName
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(suffix))").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
