import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cache_status


class CacheStatusTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mount = self.root / "CloudWeft" / "quark"
        self.mount.mkdir(parents=True)
        self.config = self.root / "roots.json"
        self.config.write_text(json.dumps({"s2": str(self.mount)}))
        self.cache = self.root / "cache"
        self.data = self.cache / "rclone/vfs/cloudweft_s2/hello.txt"
        self.meta = self.cache / "rclone/vfsMeta/cloudweft_s2/hello.txt"
        self.meta.parent.mkdir(parents=True)
        self.data.parent.mkdir(parents=True)

    def write_cache(self, parts, size=10, dirty=False):
        self.data.write_bytes(b"abcdefghij"[:size])
        self.meta.write_text(json.dumps(
            {"Size": size, "Rs": [{"Pos": p, "Size": n} for p, n in parts],
             "Dirty": dirty, "Fingerprint": str(size)}))

    def state(self, name="hello.txt"):
        return cache_status.state(str(self.mount / name),
                                  roots_path=self.config, cache_dir=self.cache)

    def test_online_only_without_cache(self):
        self.assertEqual(self.state(), "online-only")

    def test_complete_cache(self):
        self.write_cache([(0, 5), (5, 5)])
        self.assertEqual(self.state(), "cached")

    def test_partial_cache_never_marked_complete(self):
        self.write_cache([(0, 5), (8, 2)])
        self.assertEqual(self.state(), "online-only")

    def test_modified_has_priority(self):
        self.write_cache([(0, 10)], dirty=True)
        self.assertEqual(self.state(), "modified")

    def test_escape_and_other_user_files_not_annotated(self):
        self.assertIsNone(cache_status.locate(str(self.mount / "../private.txt"),
                                              roots_path=self.config))
        self.assertIsNone(self.state("../private.txt"))

    def test_file_size_mismatch(self):
        self.write_cache([(0, 10)], size=10)
        self.data.write_bytes(b"tiny")
        self.assertEqual(self.state(), "online-only")

    def test_corrupt_cache_data(self):
        self.meta.write_text("{invalid")
        self.assertEqual(self.state(), "online-only")


if __name__ == "__main__":
    unittest.main()
