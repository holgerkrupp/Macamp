import AppKit
import Foundation
import UniformTypeIdentifiers

enum ApplicationOpenRoute: Equatable {
    case fileImport
    case oauthCallback
    case unsupported
}

@MainActor
final class ApplicationOpenRouter {
    private let dependencies: DependencyContainer
    private let oauthRedirectURIs: [URL]
    private var isReady = false
    private var pendingFileImports: [([URL], MediaImportAction)] = []
    private var pendingOAuthCallbacks: [URL] = []

    init(dependencies: DependencyContainer) {
        self.dependencies = dependencies
        let configuration = ExternalProviderConfiguration.environment
        oauthRedirectURIs = [
            URL(string: "macamp://oauth/tidal"),
            configuration.spotifyRedirectURI,
            configuration.soundCloudRedirectURI,
            configuration.youtubeRedirectURI
        ].compactMap { $0 }
    }

    static func route(for url: URL, oauthRedirectURIs: [URL] = defaultOAuthRedirectURIs) -> ApplicationOpenRoute {
        if url.isFileURL { return .fileImport }
        return oauthRedirectURIs.contains(where: { sameRedirectTarget(url, $0) }) ? .oauthCallback : .unsupported
    }

    /// SwiftUI URL delivery is reserved for OAuth callbacks. File opens arrive
    /// through NSApplicationDelegate.openFiles and are handled exactly once.
    func handleURL(_ url: URL) {
        guard Self.route(for: url, oauthRedirectURIs: oauthRedirectURIs) == .oauthCallback else { return }
        guard isReady else {
            pendingOAuthCallbacks.append(url)
            return
        }
        dispatchOAuthCallback(url)
    }

    func handleFileURLs(_ urls: [URL], action: MediaImportAction) {
        let supported = urls.filter(Self.isSupportedMediaURL)
        guard !supported.isEmpty else { return }
        guard isReady else {
            pendingFileImports.append((supported, action))
            return
        }
        dispatchFileImport(supported, action: action)
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        let fileImports = pendingFileImports
        let callbacks = pendingOAuthCallbacks
        pendingFileImports.removeAll()
        pendingOAuthCallbacks.removeAll()
        fileImports.forEach { dispatchFileImport($0.0, action: $0.1) }
        callbacks.forEach(dispatchOAuthCallback)
    }

    private func dispatchFileImport(_ urls: [URL], action: MediaImportAction) {
        Task { await dependencies.importMediaURLs(urls, action: action) }
    }

    private func dispatchOAuthCallback(_ url: URL) {
        Task { await dependencies.playback.handleOAuthCallback(url) }
    }

    private static func isSupportedMediaURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        let supportedExtensions: Set<String> = ["mp3", "m3u", "m3u8"]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static var defaultOAuthRedirectURIs: [URL] {
        let configuration = ExternalProviderConfiguration.environment
        return [
            URL(string: "macamp://oauth/tidal"),
            configuration.spotifyRedirectURI,
            configuration.soundCloudRedirectURI,
            configuration.youtubeRedirectURI
        ].compactMap { $0 }
    }

    private static func sameRedirectTarget(_ url: URL, _ redirect: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == redirect.scheme?.lowercased() else { return false }
        return url.host?.lowercased() == redirect.host?.lowercased()
            && normalizedPath(url.path) == normalizedPath(redirect.path)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.lowercased()
    }
}

@MainActor
enum ApplicationMediaImportPanel {
    private static let audioAndPlaylistTypes: [UTType] = ["mp3", "m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }

    private static let playlistTypes: [UTType] = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }

    static func chooseFiles() -> [URL] {
        choose(title: "Add Files or Playlists", types: audioAndPlaylistTypes, canChooseFiles: true, canChooseDirectories: false)
    }

    static func choosePlaylists() -> [URL] {
        choose(title: "Add Playlist Files", types: playlistTypes, canChooseFiles: true, canChooseDirectories: false)
    }

    static func chooseFolder() -> [URL] {
        choose(title: "Add a Music Folder", types: [], canChooseFiles: false, canChooseDirectories: true, allowsMultipleSelection: false)
    }

    static func chooseFilesAndFolders() -> [URL] {
        choose(title: "Open Music and Playlists", types: audioAndPlaylistTypes, canChooseFiles: true, canChooseDirectories: true)
    }

    private static func choose(
        title: String,
        types: [UTType],
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        allowsMultipleSelection: Bool = true
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        return panel.runModal() == .OK ? panel.urls : []
    }
}
