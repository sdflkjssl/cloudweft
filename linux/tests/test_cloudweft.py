import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloudweft


class LinuxCloudWeftTest(unittest.TestCase):
    def test_storage_identity_and_display(self):
        one = cloudweft.Storage.from_alist(
            {"id": 3, "mount_path": "/baidu", "remark": "百度网盘", "status": "work"})
        self.assertEqual(one.sid, "s3")
        self.assertEqual(one.display, "百度网盘")
        self.assertEqual(one.mount, "/baidu")

    def test_same_name_separate_storage_ids(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "CloudWeft"
            root.mkdir()
            config = Path(temp) / "config"
            a = cloudweft.Storage("s2", "quark", "/quark", "work")
            b = cloudweft.Storage("s9", "quark", "/other", "work")
            with patch.object(cloudweft, "MOUNT_ROOT", root), patch.object(cloudweft, "CONFIG", config):
                mappings = {}
                path_a = cloudweft.choose_root(a, mappings)
                path_b = cloudweft.choose_root(b, mappings)
                self.assertEqual(path_a.name, "quark")
                self.assertEqual(path_b.name, "quark (s9)")
                self.assertEqual(cloudweft.choose_root(a, cloudweft.load_roots()), path_a)

    def test_unowned_existing_folder_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "baidu").mkdir()
            (root / "baidu" / "local.txt").write_text("keep")
            with patch.object(cloudweft, "MOUNT_ROOT", root), patch.object(cloudweft, "CONFIG", root / "config"):
                chosen = cloudweft.choose_root(
                    cloudweft.Storage("s4", "baidu", "/baidu", "work"), {})
                self.assertEqual(chosen.name, "baidu (s4)")
                self.assertEqual((root / "baidu" / "local.txt").read_text(), "keep")

    def test_temporary_driver_error_keeps_running_mount(self):
        class Running:
            def poll(self):
                return None

        with tempfile.TemporaryDirectory() as temp:
            with patch.object(cloudweft, "CONFIG", Path(temp)):
                manager = cloudweft.Supervisor()
                mock_log = object()
                manager.children["s2"] = (Running(), Path(temp) / "quark", mock_log)
                manager.mount_config["s2"] = "cached"
                with (
                    patch.object(cloudweft, "alist_api", return_value=[
                        {"id": 2, "mount_path": "/quark", "driver": "Quark",
                         "status": "temporary error", "disabled": False}]),
                    patch.object(cloudweft, "alist_password", return_value="test"),
                    patch.object(cloudweft, "storage_available", return_value=False),
                    patch.object(cloudweft, "build_rclone_config", return_value=Path(temp)),
                    patch.object(cloudweft, "terminate_mount") as terminate,
                ):
                    manager.reconcile()
                    self.assertIn("s2", manager.children)
                    terminate.assert_not_called()

    def test_invalid_relative_name_sanitized(self):
        name = cloudweft.Storage.from_alist(
            {"id": 11, "mount_path": "/path", "remark": "../x/y\n", "status": "work"}).display
        self.assertNotIn("/", name)
        self.assertNotIn("\n", name)

    def test_rclone_password_is_obscured_and_file_is_private(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(cloudweft, "CONFIG", Path(temp)):
                config = cloudweft.build_rclone_config(
                    [cloudweft.Storage("s7", "Test", "/test", "work")], "secret-example")
                data = config.read_text()
                self.assertIn("cloudweft_s7", data)
                self.assertNotIn("secret-example", data)
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
