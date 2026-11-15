import AppKit
import Testing
@testable import Macamp

struct ClassicPlaylistTests {
    @Test func toolbarHitZonesMapToTheFiveCanonicalButtons() {
        let y: CGFloat = 200
        for button in ClassicPlaylistToolbarButton.allCases {
            let frame = ClassicPlaylistToolbarGeometry.frame(for: button, bottomY: y, width: 275)
            #expect(frame.size == CGSize(width: 22, height: 18))
            #expect(ClassicPlaylistToolbarGeometry.button(at: CGPoint(x: frame.midX, y: frame.midY), bottomY: y, width: 275) == button)
        }
    }

    @Test func toolbarUsesSpriteCoordinatesAndAnchorsListButtonToRightEdge() {
        let y: CGFloat = 194
        #expect(ClassicPlaylistToolbarGeometry.frame(for: .add, bottomY: y, width: 275) == CGRect(x: 14, y: 202, width: 22, height: 18))
        #expect(ClassicPlaylistToolbarGeometry.frame(for: .remove, bottomY: y, width: 275).origin.x == 43)
        #expect(ClassicPlaylistToolbarGeometry.frame(for: .select, bottomY: y, width: 275).origin.x == 72)
        #expect(ClassicPlaylistToolbarGeometry.frame(for: .misc, bottomY: y, width: 275).origin.x == 101)
        #expect(ClassicPlaylistToolbarGeometry.frame(for: .list, bottomY: y, width: 375).origin.x == 331)
    }

    @Test func toolbarHitTestingExcludesFrameAndMenuOutsideTheFiveButtons() {
        #expect(ClassicPlaylistToolbarGeometry.button(at: CGPoint(x: 4, y: 201), bottomY: 194, width: 275) == nil)
        #expect(ClassicPlaylistToolbarGeometry.button(at: CGPoint(x: 126, y: 210), bottomY: 194, width: 275) == nil)
        #expect(ClassicPlaylistToolbarGeometry.button(at: CGPoint(x: 240, y: 201), bottomY: 194, width: 275) == nil)
    }

    @Test func playlistDropKeepsSupportedEntriesBesideUnsupportedArchives() {
        let supported = URL(fileURLWithPath: "/Music/Track.mp3")
        let folder = URL(fileURLWithPath: "/Music/Album", isDirectory: true)
        let playlist = URL(fileURLWithPath: "/Music/Mix.m3u8")
        let archive = URL(fileURLWithPath: "/Music/Skin.wsz")
        let remote = URL(string: "https://example.com/track.mp3")!

        #expect(ClassicPlaylistDropPayload.acceptedURLs(from: [supported, archive, folder, remote, playlist]) == [
            supported.standardizedFileURL,
            folder.standardizedFileURL,
            playlist.standardizedFileURL
        ])
    }

    @Test @MainActor func reorderSelectionTracksOneDuplicateOccurrenceByPlaylistIdentity() {
        let store = makeIsolatedUnifiedPlaylistStore()
        let track = PlaybackItem(
            id: "local-track",
            providerID: .localMedia,
            providerItemID: "file:///Music/track.mp3",
            title: "Track",
            mediaKind: .localFile,
            isExplicit: false
        )
        store.append([track, track, track])
        let before = store.queue.items

        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let after = store.queue.items
        let selected = ClassicPlaylistSurface.selectionAfterReorder(
            IndexSet(integer: 0),
            previousItems: before,
            currentItems: after
        )

        #expect(after.map(\.providerItemID) == Array(repeating: track.providerItemID, count: 3))
        #expect(after.map(\.id).count == Set(after.map(\.id)).count)
        #expect(selected == IndexSet(integer: 2))
    }
}
