# Winamp interaction compatibility

This guide describes how imports, service discovery, and playlist controls behave in the current Macamp build. It is a behavior contract for the app's import entry points and skin controls; visual checks listed at the end still require manual acceptance.

## Shared mixed-source playlist

Macamp has one app-owned playlist shared by Classic skins, Modern skins, the Library queue, and the playlist editor. It stores provider-neutral display metadata and stable provider item references, including duplicate occurrences as separate rows. The playlist and current row persist across launches. Adding tracks from a service, importing local files, or inserting tracks next does not start playback or interrupt the active provider. Choosing a row routes playback to its source and stops the previous source before starting the new one. Shuffle and repeat are applied to the shared playlist.

Use **Add from Streaming Service…** in the File menu, menu bar, or Classic playlist ADD menu. The picker remains available when the Library window is hidden. Choose a service, connect when requested, search its catalogue, or load its library. Individual search results can be appended directly. Supported service albums and playlists expose an **Add Tracks** action. Adding a collection appends the returned tracks without autoplay. Modern skin controls labeled **Add from service** or **Add streaming** map to the same picker, and its playlist action opens the shared native editor. The editor supports play, append local media or streaming items, insert next, reorder, remove, and clear.

Rows show the source and readiness. **Queued** means the item is waiting in the app playlist; **Requires connection/device** means provider authorization, a compatible playback device, or a visible official player is needed; **Requires file access** means macOS file permission must be renewed; **Unsupported by provider policy** means the provider cannot be used through the supported integration. Status refreshes as providers connect or playback surfaces appear. A failed handoff leaves playback stopped and reports the provider error instead of claiming success.

Service support follows provider rules. Spotify playback is controlled through Spotify Connect and requires a playable device; Macamp does not decode its audio. TIDAL uses its official player. Apple Music songs and searchable albums can be added through MusicKit, but playlist-item expansion is not supported in this build. SoundCloud results retain attribution and use official API stream responses. YouTube results can be queued, but playback requires the visible official IFrame player and does not continue in the background. Deezer remains unavailable pending an approved public integration. The picker keeps unavailable services visible with their configuration or policy status.

## Import intent contract

Every import entry point sends one explicit intent to the shared media importer:

| Intent | Result |
| --- | --- |
| **Append to queue** | Add imported tracks after the current row in the shared playlist. Do not start playback or interrupt the active provider. |
| **Insert next** | Put imported tracks at the next shared-playlist position. Do not interrupt the current track. |
| **Replace and play** | Replace the shared playlist with the imported tracks and start the first track. |
| **Add to library** | Remember imported files and playlists in Local Files without changing the shared playlist or starting playback. |

Local media import accepts MP3 files, folders, M3U/M3U8 playlists, and HLS M3U8 manifests. Folder imports scan for MP3 and playlist files. Ordinary playlist entries are resolved relative to their playlist; unsupported entries are skipped with warnings. HLS manifests are queued as stream items. Imported file access is persisted with security-scoped bookmarks. Files opened from Finder and **Open & Play** use **Replace and play**. The Classic player's file, folder, playlist, and drop actions use **Append to queue**, except where the menu explicitly says **Insert files next** or **Add files to library**.

An import does not require the Library window to be open. Use the Classic player's right-click menu, the **File** menu, or the menu bar item's **Add Music** menu to add items directly. **Open & Play…** starts the selected media.

## Classic playlist toolbar

The Classic playlist window exposes five toolbar menus. These are Macamp queue operations; the imported skin supplies the toolbar artwork and layout.

| Toolbar | Actions |
| --- | --- |
| **ADD** | Add files, folder, or playlist (append); add from a streaming service; insert files next; add files to the Local Files library. |
| **REM** | Remove selected queue rows; remove all rows (clear queue). |
| **SEL** | Select all, select none, or invert selection. |
| **MISC** | Play the first selected row; move selected rows up or down; remove duplicate tracks. |
| **LIST** | Load an M3U playlist (append); save the current app playlist as M3U; clear the shared playlist. |

Playlist rows support single selection, Command-click toggling, Shift-click ranges, and keyboard selection. Enter/Return plays the selected row. Delete or Backspace removes selected rows. Command-A selects all rows. Drops on the playlist's track area append media; drops on its toolbar are not accepted.

## Modern skin actions

Modern WAL controls are first classified by semantic action, Wasabi action/parameter, and label. Standard transport controls (play, pause, stop, previous, next, seek, volume, balance, shuffle, repeat, and visualization) map to Macamp playback actions when recognized. Import phrases such as **Add Files**, **Add Folder**, **Add Playlist**, and **Add from streaming service** open the corresponding Macamp picker and append the results. An explicit playlist visibility action, such as a `guid:pl` target or a show/hide/toggle playlist action, opens or closes Macamp's shared playlist editor. An **Add Playlist** import is kept distinct from a playlist-window toggle.

MAKI click handlers run through the bounded interpreter. When a script handles the click, it remains authoritative; otherwise the recognized declarative action is used. Unsupported MAKI host calls are diagnosed and safely ignored. The shared playlist editor has native row selection, reorder, removal, and M3U save controls regardless of which skin is active.

## Drag and drop surfaces

| Drop surface | Behavior |
| --- | --- |
| Classic or Modern main player canvas | Append dropped files, folders, and playlists to the shared playlist. |
| Classic playlist track area | Append dropped files, folders, and playlists to the shared playlist. The toolbar and shaded list do not accept drops. |
| **Local Files** library view | Import into the Local Files library without changing the current queue. |

Drops use Finder file URLs. MP3, M3U/M3U8, and folders are passed to the media importer. A skin/archive-only drop is rejected; in a mixed drop, media items still reach the importer and unsupported entries produce import warnings.

## Startup and Library access

At startup Macamp restores saved skin and local-media access, restores the playback session, and restores Apple Music authorization state without prompting. The Library window is suppressed on launch by default. Open it from **Show Library** or **Option-Command-L**. The Classic player can be shown with **Option-Command-1** and may also appear on launch when that setting is enabled. The menu bar item can expose import and playback commands when enabled.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command-O | Open & Play… |
| Shift-Command-O | Add Files… |
| Option-Command-O | Add Folder… |
| Shift-Command-P | Add Playlist… |
| Option-Command-L | Show Library |
| Option-Command-1 | Show Player |
| Shift-Command-V | Show Visualization |
| Space | Play or pause |
| Command-Left / Command-Right | Previous / next |
| Command-Period | Stop |
| Up / Down in Classic playlist | Move the selected row |
| Shift-Up / Shift-Down in Classic playlist | Extend row selection |
| Enter / Return in Classic playlist | Play selected row |
| Delete / Backspace in Classic playlist | Remove selected rows |
| Command-A in Classic playlist | Select all rows |

## Compatibility matrix

| Behavior | Classic skin | Modern WAL skin |
| --- | --- | --- |
| Main player transport and recognized standard controls | Supported | Supported when semantic controls are recognized; MAKI handlers may own the action |
| Add files, folder, or playlist | Supported through picker; append intent | Supported for recognized semantic import actions; append intent |
| Playlist-window visibility | Toggles the shared playlist window | Recognized explicit visibility actions toggle the shared playlist window |
| Playlist row selection, reorder, and removal | Supported in the shared native editor and Classic playlist | Supported in the shared native editor |
| Load and save M3U from playlist window | Supported in the shared playlist | Supported in the shared playlist |
| Main-player and playlist-area drag/drop | Supported on the surfaces listed above | Main-player canvas supported; playlist-area drop remains the Classic window path |
| MAKI runtime | Not applicable | Bounded interpreter; unsupported host methods remain compatibility gaps |

## Manual visual QA still required

The following combinations are manual acceptance checks. No visual/manual result is implied by this document. For each row, verify correct skin scale and hit targets, transparent-region behavior, playlist/player dragging and docking, import intent, and that shaded windows restore to the same position and scale.

| Scale | Main player state | Main/player group state | Status |
| --- | --- | --- | --- |
| 1× | Normal | Docked | Manual QA required |
| 1× | Normal | Detached | Manual QA required |
| 1× | Shaded | Docked | Manual QA required |
| 1× | Shaded | Detached | Manual QA required |
| 2× | Normal | Docked | Manual QA required |
| 2× | Normal | Detached | Manual QA required |
| 2× | Shaded | Docked | Manual QA required |
| 2× | Shaded | Detached | Manual QA required |
| 3× | Normal | Docked | Manual QA required |
| 3× | Normal | Detached | Manual QA required |
| 3× | Shaded | Docked | Manual QA required |
| 3× | Shaded | Detached | Manual QA required |
| 4× | Normal | Docked | Manual QA required |
| 4× | Normal | Detached | Manual QA required |
| 4× | Shaded | Docked | Manual QA required |
| 4× | Shaded | Detached | Manual QA required |
