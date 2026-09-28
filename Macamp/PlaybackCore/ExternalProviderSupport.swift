import AppKit
import Foundation

@MainActor
protocol OAuthCallbackHandling: AnyObject {
    func handleOAuthCallback(_ url: URL) async
}

@MainActor
protocol ProviderHTTPTransport: AnyObject {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

@MainActor
final class URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ProviderError(code: .invalidResponse, message: "The provider returned a non-HTTP response.")
            }
            return (data, response)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError(code: .network, message: error.localizedDescription)
        }
    }
}

@MainActor
final class OAuthSession {
    let providerID: PlaybackProviderID
    let client: OAuthPKCEClient
    let store: OAuthKeychainStore
    private(set) var token: OAuthToken?
    private var pendingState: String?
    private var pendingVerifier: String?

    init(providerID: PlaybackProviderID, configuration: OAuthPKCEConfiguration, store: OAuthKeychainStore = OAuthKeychainStore()) {
        self.providerID = providerID
        client = OAuthPKCEClient(configuration: configuration)
        self.store = store
        token = store.load(providerID: providerID)
    }

    var isAuthorized: Bool { token != nil }

    func beginAuthorization() throws -> URL {
        let state = OAuthPKCE.verifier()
        let verifier = OAuthPKCE.verifier()
        guard let url = client.authorizationURL(state: state, verifier: verifier) else {
            throw ProviderError(code: .invalidResponse, message: "The provider authorization URL could not be created.")
        }
        pendingState = state
        pendingVerifier = verifier
        return url
    }

    func finishAuthorization(_ callback: URL) async throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let query = components.queryItems,
              let state = query.first(where: { $0.name == "state" })?.value,
              state == pendingState,
              let verifier = pendingVerifier else {
            throw ProviderError(code: .authorizationDenied, message: "The provider OAuth callback state was invalid.")
        }
        if let error = query.first(where: { $0.name == "error" })?.value {
            throw ProviderError(code: .authorizationDenied, message: "Provider authorization failed: \(error).")
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            throw ProviderError(code: .authorizationDenied, message: "The provider did not return an authorization code.")
        }
        let newToken = try await client.exchange(code: code, verifier: verifier)
        try store.save(newToken, providerID: providerID)
        token = newToken
        pendingState = nil
        pendingVerifier = nil
    }

    func accessToken() async throws -> String {
        guard var token else {
            throw ProviderError(code: .reauthorizationRequired, message: "Authorize this provider before using it.")
        }
        if token.isExpired {
            guard let refreshToken = token.refreshToken else {
                throw ProviderError(code: .reauthorizationRequired, message: "The provider authorization expired; authorize again.")
            }
            token = try await client.refresh(token)
            if token.refreshToken == nil { token.refreshToken = refreshToken }
            try store.save(token, providerID: providerID)
            self.token = token
        }
        return token.accessToken
    }

    func clear() {
        store.delete(providerID: providerID)
        token = nil
        pendingState = nil
        pendingVerifier = nil
    }
}

@MainActor
class ExternalPlaybackProviderBase {
    let id: PlaybackProviderID
    let displayName: String
    let capabilities: PlaybackCapabilities
    var authenticationState: ProviderAuthenticationState = .notDetermined
    var state: PlaybackState
    var queue = PlaybackQueue()
    var snapshotContinuations: [UUID: AsyncStream<ProviderSnapshot>.Continuation] = [:]

    init(id: PlaybackProviderID, displayName: String, capabilities: PlaybackCapabilities) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        state = PlaybackState(status: .stopped, providerID: id)
    }

    func snapshots() -> AsyncStream<ProviderSnapshot> {
        let id = UUID()
        let pair = AsyncStream<ProviderSnapshot>.makeStream()
        snapshotContinuations[id] = pair.continuation
        pair.continuation.yield(snapshot)
        return pair.stream
    }

    func publish() {
        let value = snapshot
        snapshotContinuations.values.forEach { $0.yield(value) }
    }

    var snapshot: ProviderSnapshot { ProviderSnapshot(authenticationState: authenticationState, state: state, queue: queue) }

    func openAuthorizationURL(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
        authenticationState = .authorizing
        publish()
    }

    func mappedProviderError(status: Int, retryAfter: String? = nil) -> ProviderError {
        switch status {
        case 401: return ProviderError(code: .reauthorizationRequired, message: "Provider authorization expired; authorize again.")
        case 403: return ProviderError(code: .subscriptionRequired, message: "The provider denied this operation for the current account or device.")
        case 404: return ProviderError(code: .itemUnavailable, message: "The provider could not find that item or device.")
        case 429:
            let suffix = retryAfter.map { " Retry after \($0) seconds." } ?? ""
            return ProviderError(code: .rateLimited, message: "The provider rate limit was reached.\(suffix)")
        default: return ProviderError(code: .providerUnavailable, message: "The provider returned HTTP \(status).")
        }
    }
}

extension URLRequest {
    mutating func setOAuthBearer(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    mutating func setOAuthHeader(_ token: String) {
        setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
    }
}

struct ExternalProviderConfiguration: Sendable {
    var spotifyClientID: String?
    var spotifyRedirectURI: URL?
    var tidalClientID: String?
    var tidalClientSecret: String?
    var soundCloudClientID: String?
    var soundCloudClientSecret: String?
    var soundCloudRedirectURI: URL?
    var youtubeAPIKey: String?
    var youtubeClientID: String?
    var youtubeRedirectURI: URL?

    static var environment: Self {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func url(_ key: String) -> URL? { value(key).flatMap(URL.init(string:)) }
        return Self(
            spotifyClientID: value("MACAMP_SPOTIFY_CLIENT_ID"), spotifyRedirectURI: url("MACAMP_SPOTIFY_REDIRECT_URI"),
            tidalClientID: value("MACAMP_TIDAL_CLIENT_ID"), tidalClientSecret: value("MACAMP_TIDAL_CLIENT_SECRET"),
            soundCloudClientID: value("MACAMP_SOUNDCLOUD_CLIENT_ID"), soundCloudClientSecret: value("MACAMP_SOUNDCLOUD_CLIENT_SECRET"), soundCloudRedirectURI: url("MACAMP_SOUNDCLOUD_REDIRECT_URI"),
            youtubeAPIKey: value("MACAMP_YOUTUBE_API_KEY"), youtubeClientID: value("MACAMP_YOUTUBE_CLIENT_ID"), youtubeRedirectURI: url("MACAMP_YOUTUBE_REDIRECT_URI")
        )
    }
}
