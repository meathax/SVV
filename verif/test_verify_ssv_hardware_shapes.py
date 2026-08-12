#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from verify_ssv_hardware_shapes import MULTIDIM_UNPACKED_RE, audit  # noqa: E402


class HardwareShapeAuditTests(unittest.TestCase):
    def test_current_repository_passes(self):
        result = audit(ROOT)
        self.assertEqual(result["status"], "pass", result["errors"])
        self.assertFalse(result["quartus_rbf"])
        self.assertFalse(result["inference_proven"])

    def test_multidimensional_memory_pattern_is_rejected(self):
        self.assertRegex("logic [15:0] cache [0:1][0:31];", MULTIDIM_UNPACKED_RE)

    def test_missing_manifest_fails_closed(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as directory:
            result = audit(Path(directory))
        self.assertEqual(result["status"], "fail")


if __name__ == "__main__":
    unittest.main()
