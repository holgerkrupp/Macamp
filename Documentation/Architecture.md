# Architecture

Macamp is a new standalone macOS project. The initial repository contained only a cross-platform “Hello, world” target; it had no player architecture, docs, tests, or entitlements. The application is now macOS-only, targets macOS 15+, uses Swift 6 with main-actor UI isolation, automatic signing, the app sandbox, MusicKit, user-selected read-only files, and outgoing networking.

## Dependency direction

`DependencyContainer` owns provider instances, settings, skin storage, local PCM analysis, and window controllers. `PlaybackCoordinator` is the single UI-facing playback model. SwiftUI and AppKit consume only `PlaybackItem`, `PlaybackQueue`, `PlaybackState`, and `PlaybackCapabilities`; they never receive `Song`, `Album`, `Playlist`, or `ApplicationMusicPlayer`.

```text
SwiftUI library ─┐
AppKit skin UI ──┼── PlaybackCoordinator ── PlaybackProvider
Commands ────────┘                         ├── AppleMusicPlaybackProvider ── MusicKit
                                          ├── LocalFilePlaybackProvider ── AVFoundation
                                          └── MockPlaybackProvider

LocalFilePlaybackProvider ── post-EQ PCM tap ── LocalPCMAudioAnalysisSource
                                              └── VisualizationFrameStore
                                                   ├── VisualizationWindow
                                                   └── Classic / Modern inline regions
```

All playback providers are main-actor isolated. Provider snapshots arrive through `AsyncStream`; transport calls also apply an immediate snapshot, preventing UI latency. Each active engine owns one elapsed-time task that runs only during playback. UI updates never originate from an arbitrary background queue.

`LocalFilePlaybackProvider` owns an `AVAudioEngine`/`AVAudioPlayerNode` path for local files, an `AVPlayer` fallback for remote playlist URLs, a neutral item-to-URL registry, security-scoped resources, and the local queue. Its importer supports AVFoundation-decodable local audio, relative M3U/PLS/XSPF/CUE references, CUE source-time segments, and HLS M3U8 manifests; XML playlist parsing disables external entity resolution. The local-file engine includes a real ten-band `AVAudioUnitEQ`; protected Apple Music and remote-stream audio still do not advertise decoded PCM, spectrum, waveform, or application EQ access.

Music-library authorization is persisted and revoked by macOS; Macamp refreshes `MusicAuthorization.currentStatus` at launch instead of storing a duplicate permission token. Imported skin archives live in the app's Application Support container. `SkinLibraryStore` rebuilds its validated catalog from those copies at launch and persists only the selected skin identifier (or the explicit fallback selection) in app preferences.

Skin archive decoding runs in an actor. AppKit image creation, window state, hit testing, rendering, settings, and playback state remain main-actor isolated. The classic renderer converts mouse coordinates into the 275 × 116 logical canvas and dispatches semantic actions to `PlaybackCoordinator`.

## Source layout

- `Application`: app lifecycle, dependency container, commands
- `PlaybackCore`: neutral IDs/models, capabilities, provider protocol, coordinator, mock, effects and future boundaries
- `AppleMusicProvider`: authorization, catalogue/library services, MusicKit mapping and player adapter
- `LocalMediaProvider`: AVFoundation-supported MP3/AAC/M4A/ALAC/FLAC/WAV/AIFF import, playlist parsing, security-scoped bookmarks, metadata, decoded local playback and remote stream fallback
- `WinampSkinKit`: archive loader, assets, validation, region parsing, renderer, window and docking policy
- `VisualizationKit`: data/preset contracts, deterministic analysis source and built-in renderer
- `Persistence`: settings and classic-window restoration
- `Features`: modern SwiftUI navigation, playback, skin, visualization, settings and diagnostics views

## Roadmap

1. Continue closing Classic sprite/font/config compatibility gaps.
2. Extend supported decoded local formats and improve their metadata workflows.
3. Add Now Playing and remote command integration where it complements MusicKit.
4. Evaluate future service adapters only through documented provider APIs and permitted playback surfaces.
