# Macamp

Macamp is a native macOS music player that pairs a modern SwiftUI library with a detachable, transparent AppKit player inspired by classic Winamp. It plays Apple Music through MusicKit and local MP3 files through AVFoundation. A built-in demo provider keeps the interface and tests usable without an Apple Music account.

## Current milestone

- User-triggered Apple Music authorization and subscription/playability check
- Cancellable, debounced catalogue search for songs, albums, artists, and playlists
- MusicKit library browsing for songs, albums, artists, and playlists
- Song playback, pause, explicit stop, seek, previous/next, shuffle, repeat, queue, artwork, and synchronized metadata
- One persistent mixed-source playlist shared by the Classic and Modern skin editors, Library queue, and streaming-service picker; local MP3, folder, M3U/M3U8 playlist, and HLS-manifest import with persistent security-scoped access
- Provider-neutral playback state and capability-driven controls
- Borderless transparent classic player at 1×–4× integer scales
- Defensive `.wsz`, `.wal`, and `.zip` import with content detection, bounded extraction, case-insensitive nested assets, validation, and application-managed storage
- Eight built-in visualizations, with post-EQ PCM analysis for local audio-engine playback
- Diagnostics, settings, keyboard/menu commands, persistence, and a mock development library
- Swift 6 test coverage using synthetic skin archives and no real Apple Music account

An Apple Music subscription may be required for catalogue playback. MusicKit does not provide this app with raw decoded PCM from protected Apple Music audio. Local file playback uses an AVAudioEngine path and exposes post-EQ PCM visualization through a bounded, non-blocking audio tap; hosted providers and AVPlayer URL playback report visualization as unavailable. Macamp does not capture microphone or system audio.

Classic Winamp 2.x skins receive native bitmap rendering, region/alpha hit testing, and semantic controls. Winamp Modern `.wal` skins combine a declarative Wasabi XML renderer with a sandboxed Swift MAKI bytecode interpreter. Versions `0x15`–`0x17`, event dispatch, bounded VM operations, standard object lookup/visibility/XML calls, playback events, and target-position drawer animations are supported. MAKI never receives filesystem, network, process, native-code, or plug-in access. External XML entities and unsupported Wasabi components remain disabled. Macamp never loads Windows Winamp DLL plug-ins, captures system audio, or requests microphone/screen-recording permission.

Streaming services appear in **Add from Streaming Service…** when their provider adapter is available. Spotify playback uses Spotify Connect; TIDAL uses its official player; Apple Music uses MusicKit; SoundCloud preserves required attribution; YouTube requires its visible official player. Deezer remains unavailable pending an approved public integration. Provider account eligibility, quotas, official playback surfaces, and service terms apply; Macamp does not use unofficial endpoints or embed credentials. See [Provider Integration](Documentation/ProviderIntegration.md) for the current boundaries and [Winamp Interaction Compatibility](Documentation/WinampInteractionCompatibility.md) for playlist behavior.

## Requirements and setup

1. Open `Macamp.xcodeproj` in Xcode 26 or newer.
2. Select the Macamp target, choose your development team, and replace `dev.holgerkrupp.Macamp` if that identifier is unavailable.
3. Register an explicit App ID matching the bundle identifier in Certificates, Identifiers & Profiles. Open its **App Services** tab and enable **MusicKit**. MusicKit is associated with the bundle ID at runtime and must not be added to the code-signing entitlements file.
4. Run on macOS 15 or newer. Click **Connect Apple Music** in the app; Macamp never prompts on launch.
5. Use **Demo Library** from the sidebar provider menu when signing, App Service, subscription, or account configuration is unavailable.
6. Choose **File → Open & Play…**, **Add Files…**, **Add Folder…**, **Add Playlist…**, or **Add from Streaming Service…** to import without opening the Library. The Classic playlist ADD menu also offers the service picker. Items append to the shared mixed-source playlist without autoplay; selecting a row routes playback to that source. Use **Local Files** in the sidebar or **Show Library** (Option-Command-L) to manage the remembered local library. MP3, ordinary M3U/M3U8 playlists with supported entries, and HLS M3U8 manifests are supported. Choose a folder when a playlist refers to sibling files so the sandbox can retain access to them.

The app sandbox allows outgoing network requests and read-only access to files explicitly chosen by the user. Imported skins are copied into the app’s Application Support directory.

Build and test without signing:

```sh
xcodebuild -project Macamp.xcodeproj -scheme Macamp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Macamp.xcodeproj -scheme Macamp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## Known limitations

- Apple Music authorization and playback require a correctly provisioned App ID and cannot be validated by account-independent unit tests.
- Search currently loads the first page (up to 25 items per type); library views load up to 100 items per type.
- The Classic renderer supports `main.bmp`, standard semantic transport controls, region/alpha transparency, and a generated fallback skin. Some sprite/font/configuration fidelity remains incomplete. The shared playlist editor supports row selection, reorder, removal, clear, duplicate removal, M3U load/save, local file add/insert, and streaming service discovery. Local-file playback has a functional ten-band application EQ; Apple Music remains visual-only because MusicKit does not expose protected decoded audio.
- Modern `.wal` support is not yet a complete Wasabi runtime. Validated MAKI programs run inside the bounded interpreter, and HeadAMP-style cross-script drawer controls work. Unsupported host methods, dynamic Wasabi object creation, third-party components, bitmap-font engines, and some animation APIs remain compatibility gaps; scripts that encounter one are isolated while declarative behavior remains available.
- Application volume and DSP are disabled for Apple Music because MusicKit does not expose those operations.
- Apple Music songs and searchable albums can be appended, but playlist-item expansion is not supported in this build. YouTube playback requires the visible official player, and Spotify playback requires a compatible Spotify Connect device. A queued entry remains visible when its provider needs connection, file access, or a supported playback surface.
- Local audio files are MP3-focused. Ordinary M3U/M3U8 playlists can reference supported local MP3 entries, and HLS M3U8 manifests can be imported as streams. Other local audio codecs, general library playlist editing/export, Now Playing/remote-command integration, gapless playback, and ReplayGain are not in this delivery.

See [Architecture](Documentation/Architecture.md), [provider integration](Documentation/ProviderIntegration.md), [skin compatibility](Documentation/SkinCompatibility.md), [Winamp interaction compatibility](Documentation/WinampInteractionCompatibility.md), [visualization compatibility](Documentation/VisualizationCompatibility.md), and [security notes](Documentation/SecurityAndPrivacy.md).
