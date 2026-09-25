import MusicKit

struct AppleMusicAuthorizationService: Sendable {
    var currentState: ProviderAuthenticationState {
        MusicKitModelMapper.authorization(MusicAuthorization.currentStatus)
    }

    func request() async throws -> ProviderAuthenticationState {
        let state = MusicKitModelMapper.authorization(await MusicAuthorization.request())
        guard state == .authorized else {
            let message = state == .restricted
                ? "Apple Music access is restricted by system policy."
                : "Apple Music access was not granted. You can change this in System Settings > Privacy & Security > Media & Apple Music."
            throw ProviderError(code: .authorizationDenied, message: message)
        }
        // Authorization controls access to the user's music data. Catalogue playback
        // eligibility is a separate MusicSubscription capability and must not prevent
        // library requests (for example, for an iCloud Music Library account).
        return state
    }
}
