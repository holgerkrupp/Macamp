#!/usr/bin/env python3
"""Deterministic tests for the developer-only corpus scanner."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import winamp_skin_corpus as scanner  # noqa: E402


class CorpusScannerTests(unittest.TestCase):
    def test_smoke_is_deterministic_and_reports_gaps(self):
        first = scanner.render_text(scanner.smoke_result())
        second = scanner.render_text(scanner.smoke_result())
        self.assertEqual(first, second)
        self.assertIn("Classic Equalizer window", first)
        self.assertIn("Modern XUI custom widgets", first)
        self.assertIn("[unimplemented]", first)

    def test_zip_detection_matches_loader_extension_precedence(self):
        modern = scanner.scan_entries("modern.zip", ".zip", {"skin.xml": b"<root/>", "MAIN.BMP": b""})
        classic = scanner.scan_entries("classic.zip", ".zip", {"MAIN.BMP": b"", "readme.txt": b""})
        forced_classic = scanner.scan_entries("forced.wsz", ".wsz", {"skin.xml": b"<root/>", "MAIN.BMP": b""})
        self.assertEqual(modern.archive_type, "Modern")
        self.assertEqual(classic.archive_type, "Classic")
        self.assertEqual(forced_classic.archive_type, "Classic")

    def test_archive_is_read_without_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "fixture.wal"
            payload = io.BytesIO()
            with zipfile.ZipFile(payload, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("skin.xml", "<root><layout id='normal'/></root>")
                archive.writestr("images/bg.png", b"png")
            archive_path.write_bytes(payload.getvalue())
            result = scanner.scan_archive(archive_path)
            self.assertTrue(result.valid)
            self.assertEqual(result.archive_type, "Modern")
            self.assertEqual(result.entries, ["images/bg.png", "skin.xml"])
            self.assertFalse((Path(directory) / "images").exists())

    def test_json_output_shape_is_serializable(self):
        encoded = json.dumps([scanner.asdict(result) for result in scanner.smoke_result()], sort_keys=True)
        self.assertIn('"archive_type": "Classic"', encoded)
        self.assertIn('"findings"', encoded)

    def test_project_owned_validation_report_is_deterministic_and_passes(self):
        first = scanner.validation_report()
        second = scanner.validation_report()
        self.assertTrue(first.passed)
        self.assertEqual(first, second)
        self.assertEqual(first.schema_version, 2)

        encoded = json.dumps(scanner.asdict(first), indent=2, sort_keys=True)
        self.assertIn('"schema_version": 2', encoded)
        self.assertIn('classic.equalizer.render-window-gate', encoded)
        self.assertIn('classic.playlist.render-window-gate', encoded)
        self.assertIn('classic.cursor.ani-cur-gate', encoded)
        self.assertIn('classic.eqf.preset-gate', encoded)
        self.assertIn('modern.render.scene-window-gate', encoded)
        self.assertIn('modern.xui.independent-instance-input', encoded)
        self.assertIn('modern.xui.sendparams-and-scope-markers', encoded)

    def test_findings_match_current_classic_and_modern_capabilities(self):
        fixtures = scanner.validation_fixture_entries()
        classic_extension, classic_entries = fixtures["classic-reference.wsz"]
        modern_extension, modern_entries = fixtures["modern-reference.wal"]
        classic = scanner.scan_entries("classic-reference.wsz", classic_extension, classic_entries)
        modern = scanner.scan_entries("modern-reference.wal", modern_extension, modern_entries)

        classic_findings = {finding.name: finding for finding in classic.findings}
        self.assertEqual(classic_findings["Classic Equalizer window"].status, "supported")
        self.assertEqual(classic_findings["Classic Playlist Editor composition"].status, "supported")
        self.assertEqual(classic_findings["Classic ANI/CUR cursors"].status, "supported")
        self.assertEqual(classic_findings["Classic EQF preset interchange"].status, "supported")
        self.assertEqual(classic_findings["Classic Q1 preset interchange"].status, "unimplemented")

        modern_findings = {finding.name: finding for finding in modern.findings}
        self.assertEqual(modern_findings["Modern layout/group hierarchy"].status, "supported")
        self.assertEqual(modern_findings["Modern XUI custom widgets"].status, "supported")
        self.assertEqual(modern_findings["Modern sendparams"].status, "supported")
        self.assertEqual(modern_findings["Modern scoped hideobject"].status, "supported")
        self.assertEqual(modern_findings["Modern AnimatedLayer playback"].status, "partial")
        self.assertEqual(modern_findings["Modern bitmap fonts/TrueType declarations"].status, "partial")

    def test_validation_cli_emits_machine_readable_report(self):
        # Exercise the same entry point used by local CI/developer checks.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            exit_code = scanner.main(["--validation-report", "--json"])
        self.assertEqual(exit_code, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["schema_version"], 2)
        self.assertEqual({check["status"] for check in payload["checks"]}, {"pass"})


if __name__ == "__main__":
    unittest.main()
