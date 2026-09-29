# Local Winamp skin corpus scanner

`winamp_skin_corpus.py` is a developer-only triage tool for personally obtained
`.wsz`, `.wal`, and ZIP-compatible skin archives. It reads archives in place and
never extracts, copies, embeds, or redistributes skin files. The repository's
`.gitignore` keeps the conventional local `Skins/` corpus out of source control.

The format detection and XML vocabulary intentionally mirror the current
`SkinArchiveLoader` and `ModernSkinParser` contracts. The scanner does not
replace those Swift parsers or decode MAKI bytecode; it reports those areas as
partial or unimplemented rather than claiming runtime support. Feature statuses
are a small, explicit #45 baseline and should be updated as compatibility gates
land.

```sh
# Show deterministic help.
python3 Scripts/winamp_skin_corpus.py --help

# Scan a local corpus directory (defaults to ./Skins when no path is supplied).
python3 Scripts/winamp_skin_corpus.py Skins

# Produce machine-readable, sorted output.
python3 Scripts/winamp_skin_corpus.py --json Skins

# Run without any third-party skin files.
python3 Scripts/winamp_skin_corpus.py --smoke
python3 Scripts/test_winamp_skin_corpus.py
```

Exit status is `0` for valid scans, `1` when no archives are found, and `2` if
one or more archives could not be read or classified.
