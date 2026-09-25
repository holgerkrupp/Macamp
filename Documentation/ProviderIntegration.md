# Provider integration guide

Implement `PlaybackProvider` on the main actor and publish neutral `ProviderSnapshot` values. Capabilities are contractual: advertise an operation only when it is reliable, and throw `ProviderError.unsupported` for any unavailable direct call. UI code must branch on capabilities, never provider names.

A provider owns authentication, concrete SDK models/player, stable ID reconstruction, queue mapping, error mapping, and state observation. If it also supports catalogue/library discovery, implement `MusicDiscoveryProvider`. Do not persist SDK objects; persist neutral IDs and resolve them through the adapter.

Apple Music uses the process-wide `ApplicationMusicPlayer` behind `AppleMusicPlaybackProvider`. MusicKit objects do not cross the adapter. Its protected audio provides no PCM/frequency/waveform capability and its application-volume/equalizer controls remain disabled.

MusicKit configuration is an App Service attached to the explicit App ID in Apple’s developer portal. It has no `com.apple.developer.musickit` code-signing entitlement. The app does require `NSAppleMusicUsageDescription` before requesting authorization.

Spotify may later use OAuth stored in Keychain plus official Web API/Connect control or an official embedded playback SDK. It must not decode Spotify audio natively or embed secrets. YouTube metadata access does not imply playback access; a future adapter may use supported data APIs and an official embedded player, never unofficial YouTube Music endpoints or media URL extraction.

Local playback uses security-scoped bookmarks and `AVPlayer`. It supports MP3 files, folders, ordinary M3U/M3U8 track lists, and HLS manifests while exposing no PCM capability. A future AVAudioEngine path may add analysis; its real-time callbacks must allocate no memory, acquire no contested lock, or touch UI, and PCM must move through a bounded transfer that drops visualization frames instead of blocking audio.
