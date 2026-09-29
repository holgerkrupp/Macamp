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

        encoded = json.dumps(scanner.asdict(first), indent=2, sort_keys=True)
        self.assertIn('"schema_version": 1', encoded)
        self.assertIn('classic.equalizer.resource-gate', encoded)
        self.assertIn('classic.playlist.resource-gate', encoded)
        self.assertIn('modern.xui.independent-instance-input', encoded)
        self.assertIn('modern.xui.sendparams-and-scope-markers', encoded)

    def test_validation_cli_emits_machine_readable_report(self):
        # Exercise the same entry point used by local CI/developer checks.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            exit_code = scanner.main(["--validation-report", "--json"])
        self.assertEqual(exit_code, 0)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual({check["status"] for check in payload["checks"]}, {"pass"})


if __name__ == "__main__":
    unittest.main()
