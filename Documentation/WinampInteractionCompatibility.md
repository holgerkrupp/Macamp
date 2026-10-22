# Winamp interaction compatibility

This guide describes how file imports and playlist controls behave in the current Macamp build. It is a behavior contract for the app's import entry points and skin controls; visual checks listed at the end still require manual acceptance.

## Import intent contract

Every import entry point sends one explicit intent to the shared media importer:

| Intent | Result |
| --- | --- |
| **Append to queue** | Add imported tracks after the current Local Files queue. Do not start playback. If another provider is active, leave it playing and add the tracks to the Local Files queue. |
| **Insert next** | Put imported tracks at the next queue position. Do not interrupt the current track. |
| **Replace and play** | Activate Local Files, replace its queue with the imported tracks, and start the first track. |
| **Add to library** | Remember imported files and playlists in Local Files without changing the playback queue or starting playback. |

Local media import accepts MP3 files, folders, M3U/M3U8 playlists, and HLS M3U8 manifests. Folder imports scan for MP3 and playlist files. Ordinary playlist entries are resolved relative to their playlist; unsupported entries are skipped with warnings. HLS manifests are queued as stream items. Imported file access is persisted with security-scoped bookmarks. Files opened from Finder and **Open & Play** use **Replace and play**. The Classic player's file, folder, playlist, and drop actions use **Append to queue**, except where the menu explicitly says **Insert files next** or **Add files to library**.

An import does not require the Library window to be open. Use the Classic player's right-click menu, the **File** menu, or the menu bar item's **Add Music** menu to add items directly. **Open & Play…** starts the selected media.

## Classic playlist toolbar

The Classic playlist window exposes five toolbar menus. These are Macamp queue operations; the imported skin supplies the toolbar artwork and layout.

| Toolbar | Actions |
| --- | --- |
| **ADD** | Add files, folder, or playlist (append); insert files next; add files to the Local Files library. |
| **REM** | Remove selected queue rows; remove all rows (clear queue). |
| **SEL** | Select all, select none, or invert selection. |
| **MISC** | Play the first selected row; remove duplicate tracks. |
| **LIST** | Load an M3U playlist (append); save the current queue as M3U; clear the queue. |

Playlist rows support single selection, Command-click toggling, Shift-click ranges, and keyboard selection. Enter/Return plays the selected row. Delete or Backspace removes selected rows. Command-A selects all rows. Drops on the playlist's track area append media; drops on its toolbar are not accepted.

## Modern skin actions

Modern WAL controls are first classified by semantic action, Wasabi action/parameter, and label. Standard transport controls (play, pause, stop, previous, next, seek, volume, balance, shuffle, repeat, and visualization) map to Macamp playback actions when recognized. Import phrases such as **Add Files**, **Add Folder**, and **Add Playlist** open the corresponding Macamp picker and append the results. An explicit playlist visibility action, such as a `guid:pl` target or a show/hide/toggle playlist action, opens or closes Macamp's playlist window. An **Add Playlist** import is kept distinct from a playlist-window toggle.

MAKI click handlers run through the bounded interpreter. When a script handles the click, it remains authoritative; otherwise the recognized declarative action is used. Unsupported MAKI host calls are diagnosed and safely ignored. A Modern skin can show playlist-related artwork or scripted components, but it does not currently expose the Classic playlist's native row selection, queue removal, duplicate removal, or M3U save controls. Use the Classic playlist window for those operations.

## Drag and drop surfaces

| Drop surface | Behavior |
| --- | --- |
| Classic or Modern main player canvas | Append dropped files, folders, and playlists to the Local Files queue. |
| Classic playlist track area | Append dropped files, folders, and playlists to the Local Files queue. The toolbar and shaded list do not accept drops. |
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
| Playlist row selection and queue removal | Supported in the Classic playlist window | No native Modern playlist selection/removal controls |
| Load and save M3U from playlist window | Supported | Use the Classic playlist window |
| Main-player and playlist-area drag/drop | Supported on the surfaces listed above | Main-player canvas supported; playlist-area editing remains the Classic window path |
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
