import sys
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import gi
    gi.require_version("Nautilus", "4.1")
    from gi.repository import Nautilus
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "nautilus"))
    import cloudweft_nautilus as plugin
except (ImportError, ValueError):
    Nautilus = None


@unittest.skipIf(Nautilus is None, "Nautilus GI bindings unavailable")
class NautilusExtensionTest(unittest.TestCase):
    class FakeFile:
        def __init__(self):
            self.emblems = []
        def get_uri(self):
            return "file:///home/test/CloudWeft/quark/hello.txt"
        def is_directory(self):
            return False
        def add_emblem(self, name):
            self.emblems.append(name)

    def test_emblem_and_native_menu(self):
        file = self.FakeFile()
        with (
            patch.object(plugin.cache_status, "locate", return_value=("s2", Path("hello.txt"))),
            patch.object(plugin.cache_status, "state", return_value="cached"),
        ):
            extension = plugin.CloudWeftExtension()
            self.assertEqual(extension.update_file_info(file), Nautilus.OperationResult.COMPLETE)
            self.assertEqual(file.emblems, ["wusel-emblem-cached"])
            self.assertEqual(len(extension.get_file_items([file])), 1)

    def test_files_outside_mount_have_no_menu(self):
        file = self.FakeFile()
        with patch.object(plugin.cache_status, "locate", return_value=None):
            self.assertEqual(plugin.CloudWeftExtension().get_file_items([file]), [])


if __name__ == "__main__":
    unittest.main()
