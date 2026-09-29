# Skin compatibility

Macamp accepts `.wsz`, `.wal`, and `.zip` archives. Plain ZIP files are detected by their contents: a `main.bmp` identifies a classic skin and `skin.xml` identifies a Modern skin. Archive directory structure and case-insensitive paths are preserved.

## Classic skins

Classic Winamp 2.x skins render `main.bmp`, recognize common optional bitmap/configuration names case-insensitively, and apply the legacy `#FF00FF` color key only to Classic assets. `REGION.TXT` is parsed from the active `[Normal]` section, including multiple polygons; malformed regions are ignored and the window falls back to bitmap alpha and then a rectangle. Rendering uses the native 275 × 116 logical canvas, nearest-neighbor interpolation, and integer scale factors. The region mask stays in logical skin coordinates at every display scale.

## Modern WAL skins

WAL files are ZIP-compatible Wasabi skin packages. Macamp safely parses skin metadata, screenshots, bitmap declarations, layouts and group definitions, inherited/nested group offsets, initial visibility/alpha, first frames of animated layers, and recognized standard controls such as play, pause, stop, previous, next, seek, volume, balance, ten-band EQ, shuffle, repeat, minimize, and close. The parser retains a live hierarchical `WasabiScene` with local child frames, stable handles, duplicate-ID scopes, effective visibility/alpha, active-layout selection, and hierarchy-aware hit testing. Modern painting, input, target animation, and layout selection now read that scene; the compatibility tree remains only as an adapter for older diagnostic callers.

Compiled `.maki` versions `0x15`, `0x16`, and `0x17` are decoded and structurally validated before managed storage. A bounded interpreter implements the Winamp VM stack, variables, calls, branches, arithmetic, event tables, dynamic `new`/`delete` object handles, and typed `System`, `Group`, `Container`, `Layout`, `GuiObject`, `Button`, `Slider`, `Timer`, and `ConfigAttribute` state for high-value methods. MAKI input events preserve typed receiver handles and payloads through the VM, use canonical `onEnterArea`/`onLeaveArea` names, and model Button capture/pressed state, release filtering, declarative action, and `onLeftClick` ordering. The full standard class surface and several host callbacks remain explicit compatibility gaps. `SkinAssetCatalog.compatibilitySmokeReport()` summarizes object types, bindings, events, animations, and diagnostics for local skin triage.

Modern skins preserve native PNG alpha and do not use the Classic magenta color key. A supported `sysregion` subset is composed separately from drawer occlusion: positive values add a layer frame, negative values subtract a cut-out, and `desktopalpha` records that bitmap alpha participates in the window silhouette. Generic MAKI target geometry mutates scene-node local frames (including Groups), so descendants move for painting and hit testing. `Container.switchToLayout` selects a retained live Layout and resizes the logical skin host; `beforeRedock`/`redock` update the shared host docking state. This is not a claim of 100% Wasabi compatibility. Dynamic object opcodes, custom classes/components, third-party plug-ins, bitmap fonts, and a number of standard host methods remain explicitly out of scope. Unsupported calls are diagnostic no-ops; unsafe dynamic behavior disables only the affected script instance and keeps the declarative fallback usable. A screenshot remains the fallback when no renderable layout exists.

Classic skins expose a canonical Main-window sprite catalog cross-checked against Webamp and the MIT `wsz` tables: transport, eject, shuffle/repeat, EQ/Playlist source and destination rectangles, and the 275x116 seek/volume geometry are data-driven. Main seek and volume now crop the POSBAR/VOLUME atlas frames and place the exact canonical thumbs in logical Winamp pixels; no synthetic green slider fills are used. Bitmap text, balance composition, borderless EQ/Playlist windows, and tiled Playlist rendering are still pending; the existing SwiftUI utility panels remain the explicit fallback for incomplete asset sets. Both paths read the same playback, queue, and effect state.

## Compatibility validation gates

The skin test suite contains project-owned synthetic Modern and Classic diagnostic fixtures. Their generated atlases use deliberately distinct colors for each sprite state, so source-rectangle mistakes produce observable pixel-hash or state differences without redistributing third-party skins. Tests also record a deterministic scene behavior trace covering nested group movement, hit testing, and active-layout changes. Local archives in the ignored `Skins/` directory remain optional manual corpus fixtures. `Scripts/winamp_skin_corpus.py` scans local WSZ/WAL/ZIP archives without extracting or bundling third-party skins and reports resources plus supported, partial, and unimplemented compatibility areas.

## Archive safety

Imports reject absolute/traversal paths, filenames with drive-style colons, encrypted archives, duplicate case-insensitive paths, more than 512 entries, more than 64 MAKI programs, individual assets over 16 MiB, totals over 64 MiB, truncated archives, and unsupported compression. Native executable content is ignored. MAKI remains interpreted data and has no general-purpose OS capability. Invalid skins remain listed with validation errors but do not replace the active skin.

Windows executable/DLL plug-ins remain out of scope. The bundled fallback is generated by Macamp and contains no redistributed Winamp artwork.

## Local compatibility fixtures

Developers may place personally obtained test archives in the repository-local `Skins/` directory for manual compatibility checks. That directory is Git-ignored and is never copied into the application bundle. Import skins through the in-app skin manager to exercise the same sandboxed validation and application-managed storage path used by end users.
