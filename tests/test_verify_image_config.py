"""Tests for the read-only arm64 Image configuration gate."""

import gzip
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "verify_image_config", Path(__file__).resolve().parents[1] / "scripts/verify_image_config.py"
)
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)

IMAGE_HEADER = bytes(56) + b"ARM\x64" + bytes(4)
CONFIG = b"CONFIG_IP_SET=y\n# CONFIG_IP6_NF_NAT is not set\n"


def record(config=CONFIG):
    return verifier.START + gzip.compress(config, compresslevel=0, mtime=0) + verifier.END


class ImageConfigTests(unittest.TestCase):
    def test_matching_config_does_not_modify_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "Image"
            config = Path(tmp) / ".config"
            image_data = IMAGE_HEADER + record()
            image.write_bytes(image_data)
            config.write_bytes(CONFIG)
            verifier.verify(image, config)
            self.assertEqual(image_data, image.read_bytes())
            self.assertEqual(CONFIG, config.read_bytes())

    def test_different_config_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "Image"
            config = Path(tmp) / ".config"
            image.write_bytes(IMAGE_HEADER + record())
            config.write_bytes(b"CONFIG_IP_SET=n\n")
            with self.assertRaisesRegex(ValueError, "differs from"):
                verifier.verify(image, config)

    def test_end_marker_inside_gzip_is_not_a_trailer(self):
        config = CONFIG + b"# IKCFG_ED\n"
        blob = record(config)
        self.assertEqual(2, blob.count(verifier.END))
        self.assertEqual(config, verifier.embedded_config(IMAGE_HEADER + blob + b"padding"))

    def test_corrupt_or_missing_record_is_rejected(self):
        valid = record()
        corrupt = bytearray(valid)
        corrupt[-len(verifier.END) - 8] ^= 1  # gzip CRC
        for body in (b"", valid[:-1], corrupt):
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "no valid embedded IKCONFIG"):
                verifier.embedded_config(IMAGE_HEADER + body)

    def test_multiple_records_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "multiple embedded IKCONFIG"):
            verifier.embedded_config(IMAGE_HEADER + record() + record())

    def test_wrong_image_format_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "expected an uncompressed arm64 Image"):
            verifier.embedded_config(bytes(64) + record())

    def test_oversized_config_is_rejected(self):
        with patch.object(verifier, "MAX_CONFIG_BYTES", len(CONFIG) - 1):
            with self.assertRaisesRegex(ValueError, "no valid embedded IKCONFIG"):
                verifier.embedded_config(IMAGE_HEADER + record())
