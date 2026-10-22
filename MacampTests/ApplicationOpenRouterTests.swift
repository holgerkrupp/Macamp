import Foundation
import Testing
@testable import Macamp

@Suite("Application open URL routing")
struct ApplicationOpenRouterTests {
    @Test func sendsFileURLsToMediaImportPath() throws {
        let file = URL(fileURLWithPath: "/Music/song.mp3")
        #expect(ApplicationOpenRouter.route(for: file) == .fileImport)
    }

    @Test(arguments: [
        URL(string: "macamp://oauth/tidal?code=abc")!
    ])
    func sendsCustomSchemesToOAuthPath(_ url: URL) {
        #expect(ApplicationOpenRouter.route(for: url) == .oauthCallback)
    }

    @Test func ignoresUnknownCustomSchemes() {
        let url = URL(string: "music-provider://callback?code=abc")!
        #expect(ApplicationOpenRouter.route(for: url) == .unsupported)
    }

    @Test(arguments: [
        URL(string: "https://example.com/music.mp3")!,
        URL(string: "http://example.com/callback")!
    ])
    func ignoresWebURLs(_ url: URL) {
        #expect(ApplicationOpenRouter.route(for: url) == .unsupported)
    }
}
