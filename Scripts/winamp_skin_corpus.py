#!/usr/bin/env python3
"""Scan a local Winamp skin corpus without extracting or redistributing it.

The scanner deliberately stays outside the Macamp application target.  It mirrors
the archive/manifest vocabulary used by SkinArchiveLoader and ModernSkinParser,
but does not attempt to replace the app's authoritative Swift parsers.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, Mapping


ARCHIVE_EXTENSIONS = {".wsz", ".wal", ".zip"}
MAX_ENTRIES = 512
MAX_TOTAL_SIZE = 64 * 1024 * 1024

CLASSIC_RESOURCES = {
    "main.bmp",
    "cbuttons.bmp",
    "titlebar.bmp",
    "shufrep.bmp",
    "volume.bmp",
    "balance.bmp",
    "posbar.bmp",
    "numbers.bmp",
    "nums_ex.bmp",
    "playpaus.bmp",
    "monoster.bmp",
    "text.bmp",
    "region.txt",
    "viscolor.txt",
    "eqmain.bmp",
    "eq_ex.bmp",
    "pledit.bmp",
    "pledit.txt",
}

MODERN_IMAGE_EXTENSIONS = {".bmp", ".png", ".jpg", ".jpeg", ".gif", ".tif", ".tiff"}
MODERN_TAGS = {
    "winampabstractionlayer",
    "skininfo",
    "name",
    "author",
    "screenshot",
    "elements",
    "bitmap",
    "container",
    "layout",
    "groupdef",
    "group",
    "layer",
    "animatedlayer",
    "button",
    "togglebutton",
    "nstatesbutton",
    "slider",
    "text",
    "songticker",
    "vis",
    "albumart",
    "component",
    "script",
    # Known compatibility gaps are included so they are reported as features,
    # not accidentally hidden in the generic unknown-tag list.
    "include",
    "sendparams",
    "elementalias",
    "embed_xui",
}


@dataclass(frozen=True)
class Finding:
    name: str
    status: str
    evidence: str


@dataclass
class ScanResult:
    path: str
    extension: str
    archive_type: str
    entries: list[str] = field(default_factory=list)
    total_uncompressed_bytes: int = 0
    resources: list[str] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def valid(self) -> bool:
        return not self.errors


def _basename(path: str) -> str:
    return path.rsplit("/", 1)[-1].lower()


def _normalize_entry(name: str) -> str:
    return name.replace("\\", "/").lstrip("./").lower()


def _unsafe_entry(name: str) -> bool:
    if name.startswith("/") or ":" in name:
        return True
    return any(part == ".." for part in name.split("/"))


def _find_entries(entries: Mapping[str, bytes], basename: str) -> list[str]:
    return sorted(path for path in entries if _basename(path) == basename)


def _finding(name: str, status: str, evidence: str) -> Finding:
    return Finding(name=name, status=status, evidence=evidence)


def _classic_findings(entries: Mapping[str, bytes]) -> list[Finding]:
    names = {_basename(path) for path in entries}
    findings: list[Finding] = []

    main = _find_entries(entries, "main.bmp")
    if main:
        findings.append(_finding("Classic Main canvas", "supported", ", ".join(main)))
    else:
        findings.append(_finding("Classic Main canvas", "unimplemented", "main.bmp is missing"))

    sprite_assets = sorted(names & CLASSIC_RESOURCES)
    if sprite_assets:
        findings.append(_finding("Classic sprite resource inventory", "supported", ", ".join(sprite_assets)))

    if names & {"cbuttons.bmp", "shufrep.bmp", "posbar.bmp", "volume.bmp", "balance.bmp"}:
        findings.append(
            _finding(
                "Classic Main sprite catalog",
                "supported",
                "canonical transport/toggle atlas names are present",
            )
        )
    if names & {"posbar.bmp", "volume.bmp", "balance.bmp"}:
        findings.append(
            _finding(
                "Classic seek/volume/balance composition",
                "partial",
                "track/thumb resources are present; full window-path rendering is still a compatibility gate",
            )
        )

    gaps = [
        ("Classic Equalizer window", "unimplemented", "EQMAIN.BMP/EQ_EX.BMP still require the dedicated borderless window path", {"eqmain.bmp", "eq_ex.bmp"}),
        ("Classic Playlist Editor composition", "unimplemented", "PLEDIT.BMP/PLEDIT.TXT still require tiled frame and row composition", {"pledit.bmp", "pledit.txt"}),
        ("Classic bitmap text", "unimplemented", "NUMBERS.BMP/TEXT.BMP are inventory-only in this scanner baseline", {"numbers.bmp", "text.bmp", "nums_ex.bmp"}),
        ("Classic VISCOLOR configuration", "unknown", "VISCOLOR.TXT is detected but its rendering contract is not classified", {"viscolor.txt"}),
        ("Classic ANI/CUR cursors", "unimplemented", "cursor interchange is not part of the current Classic resource path", {"*.ani", "*.cur"}),
        ("Classic EQF/Q1 preset interchange", "unimplemented", "preset interchange is outside the current resource path", {"*.eqf", "*.q1"}),
    ]
    for name, status, evidence, triggers in gaps:
        matching = sorted(resource for resource in names if resource in triggers)
        if name.endswith("cursors"):
            matching = sorted(path for path in entries if Path(path).suffix.lower() in {".ani", ".cur"})
        elif name.endswith("interchange"):
            matching = sorted(path for path in entries if Path(path).suffix.lower() in {".eqf", ".q1"})
        if matching:
            evidence = f"{evidence}; observed: {', '.join(matching)}"
        findings.append(_finding(name, status, evidence))

    unknown = sorted(names - CLASSIC_RESOURCES)
    if unknown:
        findings.append(_finding("Unknown Classic resources", "unknown", ", ".join(unknown)))
    return findings


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def _modern_findings(entries: Mapping[str, bytes], xml_data: bytes | None) -> tuple[list[Finding], list[str]]:
    findings: list[Finding] = []
    warnings: list[str] = []
    tags: Counter[str] = Counter()
    attributes: Counter[str] = Counter()

    xml_paths = _find_entries(entries, "skin.xml")
    if not xml_paths:
        return [_finding("Modern skin.xml manifest", "unimplemented", "skin.xml is missing")], warnings

    manifest = xml_paths[0]
    if xml_data is None:
        xml_data = entries[manifest]
    if b"<!doctype" in xml_data.lower():
        warnings.append(f"Ignored external document type declaration in {manifest}")
    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError as error:
        return [_finding("Modern skin.xml manifest", "unknown", f"XML parse failed: {error}")], warnings

    for element in root.iter():
        tag = _local_name(element.tag)
        tags[tag] += 1
        for attribute in element.attrib:
            attributes[attribute.lower()] += 1

    findings.append(_finding("Modern skin.xml manifest", "supported", manifest))

    bitmap_count = tags["bitmap"]
    image_files = sorted(path for path in entries if Path(path).suffix.lower() in MODERN_IMAGE_EXTENSIONS)
    if bitmap_count:
        findings.append(_finding("Modern bitmap declarations", "supported", f"{bitmap_count} bitmap element(s)"))
    elif image_files:
        findings.append(_finding("Modern bitmap declarations", "partial", f"{len(image_files)} image resource(s), no <bitmap> declarations"))

    layout_count = tags["layout"]
    groupdef_count = tags["groupdef"]
    if layout_count or groupdef_count:
        findings.append(
            _finding(
                "Modern layout/group hierarchy",
                "supported" if not groupdef_count else "partial",
                f"{layout_count} layout(s), {groupdef_count} groupdef(s); static scene expansion is recognized",
            )
        )
    else:
        findings.append(_finding("Modern layout/group hierarchy", "unimplemented", "no <layout> or <groupdef> found"))

    standard_controls = sum(tags[tag] for tag in ("button", "togglebutton", "nstatesbutton", "slider"))
    if standard_controls:
        findings.append(_finding("Modern standard controls", "supported", f"{standard_controls} button/slider element(s)"))
    if tags["animatedlayer"]:
        findings.append(_finding("Modern AnimatedLayer playback", "partial", f"{tags['animatedlayer']} animatedlayer element(s); first-frame support is the current baseline"))
    if tags["script"] or any(Path(path).suffix.lower() == ".maki" for path in entries):
        maki_count = sum(Path(path).suffix.lower() == ".maki" for path in entries)
        findings.append(_finding("Modern MAKI bindings", "partial", f"{tags['script']} XML binding(s), {maki_count} .maki file(s); app loader validates bytecode"))
        findings.append(_finding("MAKI dynamic object creation", "unimplemented", "standalone scanner does not claim dynamic opcode compatibility"))
    if attributes["desktopalpha"] or attributes["sysregion"]:
        findings.append(_finding("Modern desktopalpha/sysregion", "partial", f"desktopalpha={attributes['desktopalpha']}, sysregion={attributes['sysregion']} attribute occurrence(s)"))

    gap_tags = {
        "xuitag": ("Modern XUI custom widgets", "unimplemented"),
        "include": ("Modern include expansion", "unimplemented"),
        "sendparams": ("Modern sendparams", "unimplemented"),
        "elementalias": ("Modern elementalias", "unimplemented"),
        "embed_xui": ("Modern embed_xui", "unimplemented"),
        "inherit_group": ("Modern inherit_group scoping", "partial"),
    }
    for attribute, (name, status) in gap_tags.items():
        if attributes[attribute]:
            findings.append(_finding(name, status, f"{attributes[attribute]} {attribute} attribute occurrence(s)"))
    for tag in ("include", "sendparams", "elementalias", "embed_xui"):
        name, status = gap_tags[tag]
        if tags[tag]:
            findings.append(_finding(name, status, f"{tags[tag]} <{tag}> element(s)"))

    unknown_tags = sorted(tag for tag in tags if tag not in MODERN_TAGS)
    if unknown_tags:
        details = ", ".join(f"{tag}({tags[tag]})" for tag in unknown_tags)
        findings.append(_finding("Unknown Modern XML elements", "unknown", details))

    # These are explicit engine-baseline gaps, reported even when a particular
    # archive does not exercise them, so corpus results remain actionable.
    baseline = [
        ("Modern bitmap fonts/TrueType declarations", "unimplemented", "not classified by the current standalone feature vocabulary"),
        ("Modern ANI/CUR cursors", "unimplemented", "not part of the current Modern resource path"),
        ("Modern custom plug-in components", "unknown", "component parameters are inventoried but plug-in behavior is not inferred"),
    ]
    findings.extend(_finding(*item) for item in baseline)
    return findings, warnings


def scan_entries(path: str, extension: str, entries: Mapping[str, bytes], sizes: Mapping[str, int] | None = None) -> ScanResult:
    normalized = {_normalize_entry(name): data for name, data in entries.items()}
    normalized_sizes = {_normalize_entry(name): value for name, value in (sizes or {}).items()}
    has_classic = bool(_find_entries(normalized, "main.bmp"))
    has_modern = bool(_find_entries(normalized, "skin.xml"))
    suffix = extension.lower()
    if suffix == ".wsz":
        archive_type = "Classic"
    elif suffix == ".wal":
        archive_type = "Modern"
    elif has_modern:
        archive_type = "Modern"
    elif has_classic:
        archive_type = "Classic"
    else:
        archive_type = "Unknown"

    result = ScanResult(path=path, extension=suffix, archive_type=archive_type)
    result.entries = sorted(normalized)
    result.total_uncompressed_bytes = sum(normalized_sizes.get(name, len(data)) for name, data in normalized.items())
    result.resources = sorted(_basename(name) for name in normalized)
    if archive_type == "Classic":
        result.findings = _classic_findings(normalized)
    elif archive_type == "Modern":
        manifest = _find_entries(normalized, "skin.xml")
        result.findings, result.warnings = _modern_findings(normalized, normalized[manifest[0]] if manifest else None)
    else:
        result.errors.append("Could not classify archive: expected main.bmp or skin.xml")
    if len(result.entries) > MAX_ENTRIES:
        result.warnings.append(f"Entry count exceeds app loader limit ({MAX_ENTRIES})")
    if result.total_uncompressed_bytes > MAX_TOTAL_SIZE:
        result.warnings.append(f"Uncompressed size exceeds app loader limit ({MAX_TOTAL_SIZE} bytes)")
    return result


def scan_archive(path: Path) -> ScanResult:
    extension = path.suffix.lower()
    result_path = os.fspath(path)
    if extension not in ARCHIVE_EXTENSIONS:
        return ScanResult(path=result_path, extension=extension, archive_type="Unknown", errors=["Unsupported extension; use .wsz, .wal, or .zip"])
    try:
        with zipfile.ZipFile(path) as archive:
            entries: dict[str, bytes] = {}
            sizes: dict[str, int] = {}
            for info in archive.infolist():
                raw_name = info.filename.replace("\\", "/")
                if raw_name.endswith("/"):
                    continue
                if _unsafe_entry(raw_name):
                    return ScanResult(path=result_path, extension=extension, archive_type="Unknown", errors=[f"Unsafe archive path: {raw_name}"])
                name = _normalize_entry(raw_name)
                if name in entries:
                    return ScanResult(path=result_path, extension=extension, archive_type="Unknown", errors=[f"Duplicate case-insensitive path: {raw_name}"])
                entries[name] = archive.read(info)
                sizes[name] = info.file_size
    except (OSError, zipfile.BadZipFile, RuntimeError, ValueError) as error:
        return ScanResult(path=result_path, extension=extension, archive_type="Unknown", errors=[f"Unable to read ZIP archive: {error}"])
    return scan_entries(result_path, extension, entries, sizes)


def discover(paths: Iterable[Path]) -> list[Path]:
    discovered: set[Path] = set()
    for path in paths:
        if path.is_file() and path.suffix.lower() in ARCHIVE_EXTENSIONS:
            discovered.add(path)
        elif path.is_dir():
            discovered.update(candidate for candidate in path.rglob("*") if candidate.is_file() and candidate.suffix.lower() in ARCHIVE_EXTENSIONS)
    return sorted(discovered, key=lambda item: os.fspath(item))


def _format_findings(findings: Iterable[Finding]) -> list[str]:
    order = {"supported": 0, "partial": 1, "unimplemented": 2, "unknown": 3}
    return [f"    [{finding.status}] {finding.name}: {finding.evidence}" for finding in sorted(findings, key=lambda item: (order.get(item.status, 9), item.name, item.evidence))]


def render_text(results: Iterable[ScanResult]) -> str:
    lines: list[str] = []
    for result in results:
        lines.extend([
            result.path,
            f"  archive: {result.archive_type} (extension {result.extension or '<none>'})",
            f"  entries: {len(result.entries)} files, {result.total_uncompressed_bytes} uncompressed bytes",
            f"  resources: {', '.join(result.resources) if result.resources else '<none>'}",
        ])
        if result.findings:
            lines.append("  features:")
            lines.extend(_format_findings(result.findings))
        for warning in sorted(result.warnings):
            lines.append(f"  warning: {warning}")
        for error in sorted(result.errors):
            lines.append(f"  error: {error}")
        lines.append("")
    return "\n".join(lines).rstrip()


def smoke_result() -> list[ScanResult]:
    modern_xml = b"""<WinampAbstractionLayer><elements><bitmap id='bg' file='bg.png'/></elements><container id='main'><layout id='normal' w='275' h='116'><groupdef id='drawer' xuitag='Wasabi:Drawer'><button id='play' image='bg'/><sendparams/></groupdef></layout></container></WinampAbstractionLayer>"""
    return [
        scan_entries("<smoke>/classic.wsz", ".wsz", {"main.bmp": b"", "cbuttons.bmp": b"", "eqmain.bmp": b"", "custom.dat": b""}),
        scan_entries("<smoke>/modern.wal", ".wal", {"skin.xml": modern_xml, "bg.png": b"", "scripts/player.maki": b""}),
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Scan local WSZ/WAL/ZIP skins without extracting or embedding them.")
    parser.add_argument("paths", nargs="*", type=Path, help="archive files or directories to scan")
    parser.add_argument("--json", action="store_true", dest="as_json", help="emit deterministic JSON")
    parser.add_argument("--smoke", action="store_true", help="scan deterministic in-memory fixtures and exit")
    args = parser.parse_args(argv)

    if args.smoke:
        results = smoke_result()
    else:
        paths = args.paths or [Path("Skins")]
        archives = discover(paths)
        if not archives:
            print("No .wsz, .wal, or .zip skins found in the requested paths.", file=sys.stderr)
            return 1
        results = [scan_archive(path) for path in archives]

    if args.as_json:
        print(json.dumps([asdict(result) for result in results], indent=2, sort_keys=True))
    else:
        print(render_text(results))
    return 0 if all(result.valid for result in results) else 2


if __name__ == "__main__":
    raise SystemExit(main())
