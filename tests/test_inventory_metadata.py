"""Tests for manifest size and selected platform metadata."""
import pathlib
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import inventory


class ManifestMetadataTest(unittest.TestCase):
    def test_size_for_selected_platform(self):
        index = {"manifests": [{"digest": "sha256:child", "platform": {"os": "linux", "architecture": "amd64"}}]}
        manifest = {"config": {"digest": "sha256:config", "size": 10}, "layers": [{"size": 100}, {"size": 200}]}
        with mock.patch.object(inventory, "request", side_effect=[(index, {"Docker-Content-Digest": "sha256:index"}), (manifest, {}), ({"created": "date"}, {})]):
            result = inventory.tag_metadata("repo", "latest")
        self.assertEqual((result["digest"], result["size_bytes"], result["platform"], result["built_at"]), ("sha256:index", 310, "linux/amd64", "date"))

    def test_incomplete_sizes_are_unavailable(self):
        manifest = {"config": {"size": 10}, "layers": [{"size": 100}, {}]}
        with mock.patch.object(inventory, "request", return_value=(manifest, {})):
            self.assertIsNone(inventory.tag_metadata("repo", "tag")["size_bytes"])

    def test_empty_image_and_failed_metadata(self):
        manifest = {"config": {"size": 10}, "layers": []}
        with mock.patch.object(inventory, "request", return_value=(manifest, {})):
            self.assertEqual(inventory.tag_metadata("repo", "tag")["size_bytes"], 10)
        with mock.patch.object(inventory, "request", side_effect=ValueError), mock.patch.object(inventory, "tag_updated", return_value=None):
            self.assertIsNone(inventory.tag_entry("repo", "tag")["size_bytes"])
