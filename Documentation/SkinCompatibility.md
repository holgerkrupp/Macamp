# Skin compatibility

Macamp accepts `.wsz`, `.wal`, and `.zip` archives. Plain ZIP files are detected by their contents: a `main.bmp` identifies a classic skin and `skin.xml` identifies a Modern skin. Archive directory structure and case-insensitive paths are preserved.

## Classic skins

Classic Winamp 2.x skins render `main.bmp`, recognize common optional bitmap/configuration names case-insensitively, and apply the legacy `#FF00FF` color key only to Classic assets. `REGION.TXT` is parsed from the active `[Normal]` section, including multiple polygons; malformed regions are ignored and the window falls back to bitmap alpha and then a rectangle. Rendering uses the native 275 × 116 logical canvas, nearest-neighbor interpolation, and integer scale factors. The region mask stays in logical skin coordinates at every display scale.

## Modern WAL skins

WAL files are ZIP-compatible Wasabi skin packages. Macamp safely parses skin metadata, screenshots, bitmap declarations, layouts and group definitions, inherited/nested group offsets, initial visibility/alpha, first frames of animated layers, and recognized standard controls such as play, pause, stop, previous, next, seek, volume, balance, ten-band EQ, shuffle, repeat, minimize, and close. The parser now retains a live hierarchical `WasabiScene` projection with local child frames, stable handles, duplicate-ID scopes, effective visibility/alpha, active-layout selection, and hierarchy-aware hit testing; the existing flattened renderer/runtime projection is being migrated onto that scene incrementally.

Compiled `.maki` versions `0x15`, `0x16`, and `0x17` are decoded and structurally validated before managed storage. A bounded interpreter implements the Winamp VM stack, variables, calls, branches, arithmetic, event tables, and a restricted host-object layer for common `System`, `Group`, `GuiObject`, playback, XML-parameter, visibility, click, mouse, slider, timer, config, layout, redock, volume, EQ, and generic target-animation calls. MAKI input events now preserve typed receiver handles and payloads through the VM, use canonical `onEnterArea`/`onLeaveArea` names, and model Button capture/pressed state, release filtering, declarative action, and `onLeftClick` ordering. Dynamic object opcodes and the complete standard class surface remain explicit compatibility gaps. `SkinAssetCatalog.compatibilitySmokeReport()` summarizes object types, bindings, events, animations, and diagnostics for local skin triage.

Modern skins preserve native PNG alpha and do not use the Classic magenta color key. A supported `sysregion` subset is composed separately from drawer occlusion: positive values add a layer frame, negative values subtract a cut-out, and `desktopalpha` records that bitmap alpha participates in the window silhouette. This is not a claim of 100% Wasabi compatibility. Dynamic object opcodes, custom classes/components, third-party plug-ins, bitmap fonts, and a number of skin-specific host methods remain explicitly out of scope. Unsupported calls are diagnostic no-ops; unsafe dynamic behavior disables only the affected script instance and keeps the declarative fallback usable. A screenshot remains the fallback when no renderable layout exists.

Classic skins expose a canonical Main-window sprite catalog cross-checked against Webamp and the MIT `wsz` tables: transport, eject, shuffle/repeat, EQ/Playlist source and destination rectangles, and the 275x116 seek/volume geometry are data-driven. Main seek and volume now crop the POSBAR/VOLUME atlas frames and place the exact canonical thumbs in logical Winamp pixels; no synthetic green slider fills are used. Bitmap text, balance composition, borderless EQ/Playlist windows, and tiled Playlist rendering are still pending; the existing SwiftUI utility panels remain the explicit fallback for incomplete asset sets. Both paths read the same playback, queue, and effect state.

## Compatibility validation gates

The skin test suite contains project-owned synthetic Modern and Classic diagnostic fixtures. Their generated atlases use deliberately distinct colors for each sprite state, so source-rectangle mistakes produce observable pixel-hash or state differences without redistributing third-party skins. Tests also record a deterministic scene behavior trace covering nested group movement, hit testing, and active-layout changes. Local archives in the ignored `Skins/` directory remain optional manual corpus fixtures; this repository does not currently include a separate corpus-scanning CLI.

## Archive safety

Imports reject absolute/traversal paths, filenames with drive-style colons, encrypted archives, duplicate case-insensitive paths, more than 512 entries, more than 64 MAKI programs, individual assets over 16 MiB, totals over 64 MiB, truncated archives, and unsupported compression. Native executable content is ignored. MAKI remains interpreted data and has no general-purpose OS capability. Invalid skins remain listed with validation errors but do not replace the active skin.

Windows executable/DLL plug-ins remain out of scope. The bundled fallback is generated by Macamp and contains no redistributed Winamp artwork.

## Local compatibility fixtures

Developers may place personally obtained test archives in the repository-local `Skins/` directory for manual compatibility checks. That directory is Git-ignored and is never copied into the application bundle. Import skins through the in-app skin manager to exercise the same sandboxed validation and application-managed storage path used by end users.
