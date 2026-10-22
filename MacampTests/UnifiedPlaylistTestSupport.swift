import Foundation
@testable import Macamp

@MainActor
func makeIsolatedUnifiedPlaylistStore() -> UnifiedPlaylistStore {
    let suiteName = "MacampTests.UnifiedPlaylist.\(UUID().uuidString)"
    return UnifiedPlaylistStore(defaults: UserDefaults(suiteName: suiteName)!, storageKey: "playlist")
}
