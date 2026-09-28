# Provider integration guide

Implement `PlaybackProvider` on the main actor and publish neutral `ProviderSnapshot` values. Capabilities are contractual: advertise an operation only when it is reliable, and throw `ProviderError.unsupported` for any unavailable direct call. UI code must branch on capabilities, never provider names.

A provider owns authentication, concrete SDK models/player, stable ID reconstruction, queue mapping, error mapping, and state observation. If it also supports catalogue/library discovery, implement `MusicDiscoveryProvider`. Do not persist SDK objects; persist neutral IDs and resolve them through the adapter. UI consumes `ProviderDescriptor` values from `ProviderRegistry`; unavailable descriptors remain visible in Music Services but never appear in the normal connection menu.

Apple Music uses the process-wide `ApplicationMusicPlayer` behind `AppleMusicPlaybackProvider`. MusicKit objects do not cross the adapter. Its protected audio provides no PCM/frequency/waveform capability and its application-volume/equalizer controls remain disabled.

MusicKit configuration is an App Service attached to the explicit App ID in Apple’s developer portal. It has no `com.apple.developer.musickit` code-signing entitlement. The app does require `NSAppleMusicUsageDescription` before requesting authorization.

| Provider | Availability | Integration | Authentication | Capability boundary |
| --- | --- | --- | --- | --- |
| Apple Music | Available | MusicKit native provider | MusicKit | No PCM, spectrum, waveform, native EQ, or app volume |
| Local Files | Available | Local AVFoundation playback | None | Local decoded audio and EQ only |
| Demo Library | Available | In-memory test provider | None | Deterministic demo capabilities |
| Spotify | Requires configuration | Official Web API / Connect control | OAuth PKCE | Remote-device control; never decode Spotify audio in Macamp |
| TIDAL | Requires configuration | Official TIDAL SDK 0.12.x (`Auth`, `Player`, `EventProducer`, `TidalAPI`) | TIDAL OAuth | Official player callbacks and transport; no PCM/equalizer boundary |
| SoundCloud | Requires configuration | Official API stream responses | OAuth PKCE | No protected-audio caching; required uploader attribution |
| YouTube | Requires external player | Visible official IFrame player | OAuth/API key as permitted | No audio-only, hidden/background playback, extraction, or media URL caching |
| Deezer | Temporarily unavailable | None | Pending official access | Blocked pending official developer/playback support; no scraping or private APIs |

Spotify, SoundCloud, and YouTube are enabled only when their environment configuration is present. OAuth tokens are stored in Keychain; client secrets and API keys are read from the process environment and are never embedded in the app. Spotify uses Web API/Connect control and never decodes Spotify audio locally. SoundCloud resolves the documented stream redirect and sends protected audio directly to `AVPlayer` without caching it. YouTube uses Data API metadata plus a visible 640×360 official IFrame player; it pauses when the surface is removed and never performs extraction or background/audio-only playback. Deezer is intentionally not implemented: current access constraints do not justify shipping an adapter until Deezer documents an approved public path for Macamp.

Configure providers with `MACAMP_SPOTIFY_CLIENT_ID` / `MACAMP_SPOTIFY_REDIRECT_URI`, `MACAMP_TIDAL_CLIENT_ID` / `MACAMP_TIDAL_CLIENT_SECRET`, `MACAMP_SOUNDCLOUD_CLIENT_ID` / `MACAMP_SOUNDCLOUD_REDIRECT_URI` (and optionally `MACAMP_SOUNDCLOUD_CLIENT_SECRET`), or `MACAMP_YOUTUBE_API_KEY` plus optional Google OAuth client and redirect variables. Redirect URLs must match the provider application registrations exactly.

Local playback uses security-scoped bookmarks and `AVPlayer`. It supports MP3 files, folders, ordinary M3U/M3U8 track lists, and HLS manifests while exposing no PCM capability. A future AVAudioEngine path may add analysis; its real-time callbacks must allocate no memory, acquire no contested lock, or touch UI, and PCM must move through a bounded transfer that drops visualization frames instead of blocking audio.
