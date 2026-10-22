import AppKit
import Foundation
import Testing
@testable import Macamp

@Suite("Finder file drop payloads")
struct FileURLDropViewTests {
    @Test func preservesInputOrderAndDuplicateURLs() throws {
        let second = URL(fileURLWithPath: "/Music/second.mp3")
        let first = URL(fileURLWithPath: "/Music/first.mp3")

        let urls = try FileURLDropPayloadParser.parse([second, first, second]).get()

        #expect(urls == [second.standardizedFileURL, first.standardizedFileURL, second.standardizedFileURL])
    }

    @Test func acceptsFoldersAndM3UPlaylistsForDownstreamHandling() throws {
        let folder = URL(fileURLWithPath: "/Music/Folder", isDirectory: true)
        let m3u = URL(fileURLWithPath: "/Music/queue.m3u")
        let m3u8 = URL(fileURLWithPath: "/Music/radio.m3u8")

        let urls = try FileURLDropPayloadParser.parse([folder, m3u, m3u8]).get()

        #expect(urls == [folder.standardizedFileURL, m3u.standardizedFileURL, m3u8.standardizedFileURL])
    }

    @Test func rejectsEmptyPayload() {
        #expect(FileURLDropPayloadParser.parse([]) == .failure(.emptyPayload))
    }

    @Test @MainActor func readsFinderFileURLPasteboardEntries() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FileURLDropViewTests"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([NSURL(fileURLWithPath: "/Music/song.mp3")]))

        let urls = try FileURLDropPayloadParser.read(from: pasteboard).get()

        #expect(urls == [URL(fileURLWithPath: "/Music/song.mp3")])
    }

    @Test @MainActor func keepsValidFilesInMixedFinderDrop() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FileURLDropViewMixedTests"))
        pasteboard.clearContents()
        let song = NSURL(fileURLWithPath: "/Music/song.mp3")
        let skinArchive = NSURL(fileURLWithPath: "/Downloads/skin.wsz")
        #expect(pasteboard.writeObjects([song, skinArchive]))

        let urls = try FileURLDropPayloadParser.read(from: pasteboard).get()

        #expect(urls == [song as URL, skinArchive as URL])
    }

    @Test(arguments: ["zip", "rar", "7z", "tar", "gz", "wsz"])
    func rejectsUnsupportedArchives(extension fileExtension: String) {
        let archive = URL(fileURLWithPath: "/Downloads/unsupported.\(fileExtension)")

        #expect(FileURLDropPayloadParser.parse([archive]) == .failure(.unsupportedArchive(archive)))
    }

    @Test func rejectsNonFileURLs() {
        let remote = URL(string: "https://example.com/track.mp3")!

        #expect(FileURLDropPayloadParser.parse([remote]) == .failure(.nonFileURL))
    }
}
