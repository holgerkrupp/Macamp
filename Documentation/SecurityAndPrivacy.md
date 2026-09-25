# Security and privacy

Macamp collects no analytics and embeds no service credentials. It does not log tokens or library contents. Unified playback logging contains only user-presentable non-sensitive error text.

The app is sandboxed with outgoing network access and user-selected read-only file access. Music authorization is requested only after a button click. OAuth adapters must store tokens in Keychain. Local media persists security-scoped bookmarks for files and folders the user explicitly selects rather than requesting broad filesystem access. **Forget Local Library** removes those bookmarks and releases active scopes.

Skin and preset files are treated as untrusted data. Archive paths, encryption state, duplicates, counts, and sizes are validated; native executable entries are ignored; and only safe metadata/file copies are persisted. Modern WAL parsing rejects external entities and document type declarations. Compiled MAKI is validated as data and interpreted by a pure-Swift VM with file/table/code limits, per-event instruction and stack budgets, bounded call/event depth, and a restricted Wasabi host API. Scripts cannot access the filesystem, network, processes, native symbols, Windows APIs, or plug-ins. An invalid program is rejected, and a runtime fault disables only that script instance. No copyrighted third-party Winamp skin ships with the app.

Macamp does not bypass DRM, extract protected audio, scrape private APIs, download protected media, impersonate an official client, capture system audio, or request microphone/screen-recording/input-monitoring permissions for visualization.
