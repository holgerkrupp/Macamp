import Foundation
import Security
import CryptoKit

enum ExternalPlaybackIntegrationKind: String, Codable, Sendable {
    case remoteDeviceControl
    case officialEmbeddedPlayer
    case nativeDecodedAudio
}

struct FutureProviderDescriptor: Identifiable, Sendable {
    var id: PlaybackProviderID
    var displayName: String
    var permittedIntegrationKinds: Set<ExternalPlaybackIntegrationKind>
    var notes: String

    static let spotify = Self(
        id: "spotify", displayName: "Spotify",
        permittedIntegrationKinds: [.remoteDeviceControl, .officialEmbeddedPlayer],
        notes: "Requires OAuth and official Spotify APIs/SDKs. No native audio decoding is assumed."
    )
    static let youtube = Self(
        id: "youtube", displayName: "YouTube",
        permittedIntegrationKinds: [.officialEmbeddedPlayer],
        notes: "Metadata and playback remain separate; playback requires an official embedded player where permitted."
    )
}

enum ProviderAvailability: String, Codable, Sendable {
    case available
    case requiresConfiguration
    case requiresExternalAppOrDevice
    case unsupportedOnPlatform
    case temporarilyUnavailable

    var isSelectable: Bool { self == .available }
}

enum ProviderAuthenticationKind: String, Codable, Sendable {
    case none
    case musicKit
    case oauthPKCE
}

struct ProviderDescriptor: Identifiable, Hashable, Sendable {
    var id: PlaybackProviderID
    var displayName: String
    var iconName: String
    var authentication: ProviderAuthenticationKind
    var integration: ExternalPlaybackIntegrationKind?
    var availability: ProviderAvailability
    var accountRequirements: String
    var supportedPlatforms: [String]
    var notes: String

    var isSelectable: Bool { availability.isSelectable }

    static let appleMusic = Self(
        id: .appleMusic, displayName: "Apple Music", iconName: "apple.logo", authentication: .musicKit,
        integration: .nativeDecodedAudio, availability: .available,
        accountRequirements: "Apple Music authorization; catalogue playback may require an eligible subscription.",
        supportedPlatforms: ["macOS"], notes: "Uses MusicKit's supported catalogue, library and player APIs."
    )
    static let localMedia = Self(
        id: .localMedia, displayName: "Local Files", iconName: "internaldrive", authentication: .none,
        integration: .nativeDecodedAudio, availability: .available,
        accountRequirements: "Selected files or folders.", supportedPlatforms: ["macOS"],
        notes: "Playback stays local and uses security-scoped file access."
    )
    static let preview = Self(
        id: .preview, displayName: "Demo Library", iconName: "sparkles", authentication: .none,
        integration: .nativeDecodedAudio, availability: .available,
        accountRequirements: "None.", supportedPlatforms: ["macOS"], notes: "Deterministic in-memory demo content."
    )
    static let spotify = Self(
        id: .spotify, displayName: "Spotify", iconName: "waveform", authentication: .oauthPKCE,
        integration: .remoteDeviceControl, availability: .requiresConfiguration,
        accountRequirements: "An approved Spotify developer application and Premium account for Connect control.",
        supportedPlatforms: ["macOS"], notes: "Official Web API/Connect control only; Macamp never decodes Spotify audio."
    )
    static let tidal = Self(
        id: "tidal", displayName: "TIDAL", iconName: "waveform", authentication: .oauthPKCE,
        integration: .nativeDecodedAudio, availability: .requiresConfiguration,
        accountRequirements: "An approved TIDAL application and supported official SDK configuration.",
        supportedPlatforms: ["macOS"], notes: "The official Swift SDK must be verified against Macamp's deployment target before enabling playback."
    )
    static let soundCloud = Self(
        id: "soundcloud", displayName: "SoundCloud", iconName: "cloud", authentication: .oauthPKCE,
        integration: .nativeDecodedAudio, availability: .requiresConfiguration,
        accountRequirements: "A registered SoundCloud application using OAuth 2.1 with PKCE.",
        supportedPlatforms: ["macOS"], notes: "Only documented API stream responses and required uploader attribution are permitted."
    )
    static let youtube = Self(
        id: .youtube, displayName: "YouTube", iconName: "play.rectangle", authentication: .oauthPKCE,
        integration: .officialEmbeddedPlayer, availability: .requiresExternalAppOrDevice,
        accountRequirements: "YouTube Data API configuration; playback requires a visible official embedded player.",
        supportedPlatforms: ["macOS"], notes: "No YouTube Music scraping, media URL extraction, background playback or audio-only playback."
    )
    static let deezer = Self(
        id: "deezer", displayName: "Deezer", iconName: "music.note", authentication: .oauthPKCE,
        integration: nil, availability: .temporarilyUnavailable,
        accountRequirements: "Official Deezer developer access approved for Macamp.",
        supportedPlatforms: ["macOS"], notes: "Blocked pending an official supported developer/playback path; no scraping, private APIs or obsolete SDKs."
    )
}

@MainActor
final class ProviderRegistry {
    private(set) var descriptors: [ProviderDescriptor] = []
    private var registeredIDs: Set<PlaybackProviderID> = []

    var availableDescriptors: [ProviderDescriptor] { descriptors.filter { $0.isSelectable && registeredIDs.contains($0.id) } }
    var allDescriptors: [ProviderDescriptor] { descriptors }

    func register(_ provider: any PlaybackProvider, descriptor: ProviderDescriptor) {
        registeredIDs.insert(provider.id)
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    func registerUnavailable(_ descriptor: ProviderDescriptor) {
        descriptors.removeAll { $0.id == descriptor.id }
        descriptors.append(descriptor)
    }

    func descriptor(for id: PlaybackProviderID?) -> ProviderDescriptor? {
        guard let id else { return nil }
        return descriptors.first { $0.id == id }
    }

    func isAvailable(_ id: PlaybackProviderID) -> Bool {
        availableDescriptors.contains { $0.id == id }
    }
}

struct OAuthPKCEConfiguration: Sendable {
    var clientID: String
    var clientSecret: String? = nil
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var redirectURI: URL
    var scopes: [String]
}

struct OAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiration: Date?
    var scope: String?

    var isExpired: Bool { expiration.map { $0 <= Date().addingTimeInterval(30) } ?? false }
}

final class OAuthKeychainStore: @unchecked Sendable {
    private let service: String
    init(service: String = "dev.holgerkrupp.Macamp.oauth") { self.service = service }

    func load(providerID: PlaybackProviderID) -> OAuthToken? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: providerID.rawValue, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func save(_ token: OAuthToken, providerID: PlaybackProviderID) throws {
        let data = try JSONEncoder().encode(token)
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: providerID.rawValue]
        SecItemDelete(base as CFDictionary)
        var item = base; item[kSecValueData] = data
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ProviderError(code: .unknown, message: "The provider token could not be stored securely.")
        }
    }

    func delete(providerID: PlaybackProviderID) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: providerID.rawValue]
        SecItemDelete(query as CFDictionary)
    }
}

enum OAuthPKCE {
    static func verifier() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<64).compactMap { _ in alphabet.randomElement() })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct OAuthPKCEClient: Sendable {
    let configuration: OAuthPKCEConfiguration

    func authorizationURL(state: String, verifier: String) -> URL? {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    func exchange(code: String, verifier: String) async throws -> OAuthToken {
        var values = [
            "grant_type": "authorization_code", "client_id": configuration.clientID,
            "code": code, "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": verifier
        ]
        if let clientSecret = configuration.clientSecret { values["client_secret"] = clientSecret }
        return try await request(values)
    }

    func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw ProviderError(code: .authorizationDenied, message: "The provider did not issue a refresh token.") }
        var values = [
            "grant_type": "refresh_token", "client_id": configuration.clientID,
            "refresh_token": refreshToken
        ]
        if let clientSecret = configuration.clientSecret { values["client_secret"] = clientSecret }
        let refreshed = try await request(values)
        return OAuthToken(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? refreshToken, expiration: refreshed.expiration, scope: refreshed.scope)
    }

    private func request(_ values: [String: String]) async throws -> OAuthToken {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = values.map { pair in
            let (key, value) = pair
            return "\(Self.escape(key))=\(Self.escape(value))"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError(code: .authorizationDenied, message: "The provider rejected the OAuth token request.")
        }
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        return OAuthToken(accessToken: payload.accessToken, refreshToken: payload.refreshToken, expiration: payload.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }, scope: payload.scope)
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }

    private struct TokenPayload: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
        }
    }
}
