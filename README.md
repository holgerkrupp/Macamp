# Macamp

Macamp is a native macOS music player that pairs a modern SwiftUI library with a detachable, transparent AppKit player inspired by classic Winamp. It plays Apple Music through MusicKit and local MP3 files through AVFoundation. A built-in demo provider keeps the interface and tests usable without an Apple Music account.

## Current milestone

- User-triggered Apple Music authorization and subscription/playability check
- Cancellable, debounced catalogue search for songs, albums, artists, and playlists
- MusicKit library browsing for songs, albums, artists, and playlists
- Song playback, pause, explicit stop, seek, previous/next, shuffle, repeat, queue, artwork, and synchronized metadata
- Local MP3, folder, M3U/M3U8 track-list, and HLS-manifest import with persistent security-scoped access
- Provider-neutral playback state and capability-driven controls
- Borderless transparent classic player at 1×–4× integer scales
- Defensive `.wsz`, `.wal`, and `.zip` import with content detection, bounded extraction, case-insensitive nested assets, validation, and application-managed storage
- Eight built-in visualizations driven by deterministic simulated data for the current playback providers
- Diagnostics, settings, keyboard/menu commands, persistence, and a mock development library
- Swift 6 test coverage using synthetic skin archives and no real Apple Music account

An Apple Music subscription may be required for catalogue playback. MusicKit does not provide this app with raw decoded PCM from protected Apple Music audio, so Apple Music visualizations are explicitly simulated. Local playback currently uses AVPlayer and also keeps visualization data simulated; a later AVAudioEngine path can add bounded PCM-based spectrum and waveform analysis.

Classic Winamp 2.x skins receive native bitmap rendering, region/alpha hit testing, and semantic controls. Winamp Modern `.wal` skins combine a declarative Wasabi XML renderer with a sandboxed Swift MAKI bytecode interpreter. Versions `0x15`–`0x17`, event dispatch, bounded VM operations, standard object lookup/visibility/XML calls, playback events, and target-position drawer animations are supported. MAKI never receives filesystem, network, process, native-code, or plug-in access. External XML entities and unsupported Wasabi components remain disabled. Macamp never loads Windows Winamp DLL plug-ins, captures system audio, or requests microphone/screen-recording permission.

Spotify and YouTube are future adapters. They depend on official APIs, official playback surfaces, account eligibility, quotas, and provider terms; Macamp does not use unofficial endpoints or embed credentials.

## Requirements and setup

1. Open `Macamp.xcodeproj` in Xcode 26 or newer.
2. Select the Macamp target, choose your development team, and replace `dev.holgerkrupp.Macamp` if that identifier is unavailable.
3. Register an explicit App ID matching the bundle identifier in Certificates, Identifiers & Profiles. Open its **App Services** tab and enable **MusicKit**. MusicKit is associated with the bundle ID at runtime and must not be added to the code-signing entitlements file.
4. Run on macOS 15 or newer. Click **Connect Apple Music** in the app; Macamp never prompts on launch.
5. Use **Demo Library** from the sidebar provider menu when signing, App Service, subscription, or account configuration is unavailable.
6. Choose **Playback → Open Local Media…** or **Local Files** in the sidebar to add MP3/M3U/M3U8 files. Choose a folder when a playlist refers to sibling files so the sandbox can retain access to all of them.

The app sandbox allows outgoing network requests and read-only access to files explicitly chosen by the user. Imported skins are copied into the app’s Application Support directory.

Build and test without signing:

```sh
xcodebuild -project Macamp.xcodeproj -scheme Macamp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Macamp.xcodeproj -scheme Macamp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Known limitations

- Apple Music authorization and playback require a correctly provisioned App ID and cannot be validated by account-independent unit tests.
- Search currently loads the first page (up to 25 items per type); library views load up to 100 items per type.
- The classic renderer supports `main.bmp`, standard semantic transport controls, region/alpha transparency, and a generated fallback skin. Full sprite/font/configuration fidelity, fully skinned classic playlist/equalizer windows, group docking, and windowshade rendering remain roadmap work. Local-file playback has a functional ten-band application EQ; Apple Music remains visual-only because MusicKit does not expose protected decoded audio.
- Modern `.wal` support is not yet a complete Wasabi runtime. Validated MAKI programs run inside the bounded interpreter, and HeadAMP-style cross-script drawer controls work. Unsupported host methods, dynamic Wasabi object creation, third-party components, bitmap-font engines, and some animation APIs remain compatibility gaps; scripts that encounter one are isolated while declarative behavior remains available.
- Application volume and DSP are disabled for Apple Music because MusicKit does not expose those operations.
- Queue editing is disabled for Apple Music; only supported transport is advertised.
- Local playback is MP3-focused. Other local codecs, playlist editing/export, Now Playing/remote-command integration, gapless playback, ReplayGain, and real PCM visualization are not in this delivery.

See [Architecture](Documentation/Architecture.md), [provider integration](Documentation/ProviderIntegration.md), [skin compatibility](Documentation/SkinCompatibility.md), [visualization compatibility](Documentation/VisualizationCompatibility.md), and [security notes](Documentation/SecurityAndPrivacy.md).
