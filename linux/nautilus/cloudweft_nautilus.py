"""CloudWeft status emblems and desktop actions for GNOME Files.

Uses python3-nautilus (the official Nautilus Python extension bridge), Rclone's
existing local VFS metadata, and Apache-2.0 emblem SVGs from Wusel.
"""
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

import gi
gi.require_version("Nautilus", "4.1")
from gi.repository import GLib, GObject, Nautilus

RUNTIME = Path.home() / ".local/share/cloudweft/runtime"
if str(RUNTIME) not in sys.path:
    sys.path.insert(0, str(RUNTIME))

import cache_status

EMBLEMS = {
    "online-only": "wusel-emblem-cloud",
    "cached": "wusel-emblem-cached",
    "modified": "wusel-emblem-modified",
}


def path_from_file(file_info):
    uri = file_info.get_uri()
    parsed = urlparse(uri)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        return None
    return unquote(parsed.path)


class CloudWeftExtension(GObject.GObject, Nautilus.InfoProvider, Nautilus.MenuProvider):
    def update_file_info(self, file_info):
        try:
            path = path_from_file(file_info)
            if path:
                state = cache_status.state(path, is_directory=file_info.is_directory())
                emblem = EMBLEMS.get(state)
                if emblem:
                    file_info.add_emblem(emblem)
        except Exception:
            # Nautilus must always remain usable, even if CloudWeft is down.
            pass
        return Nautilus.OperationResult.COMPLETE

    def get_file_items(self, files):
        paths = []
        for file_info in files:
            path = path_from_file(file_info)
            if not path or cache_status.locate(path) is None:
                return []
            paths.append(path)
        if not paths:
            return []

        label = "CloudWeft · 下载到本地缓存" if os.environ.get("LANG", "").startswith("zh") \
                else "CloudWeft · Download to local cache"
        item = Nautilus.MenuItem(
            name="CloudWeft::DownloadToCache",
            label=label,
            tip="Download content through the existing Rclone VFS cache",
            icon="folder-download",
        )
        item.connect("activate", self._on_download, tuple(paths), tuple(files))
        return [item]

    def _on_download(self, _item, paths, files):
        runtime = Path.home() / ".local/share/cloudweft"
        log_path = runtime / "logs" / "desktop-actions.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        action = runtime / "runtime" / "cloudweft_actions.py"
        try:
            with log_path.open("ab") as log:
                subprocess.Popen(
                    ["/usr/bin/python3", str(action), "download", *paths],
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    close_fds=True,
                )
        except OSError:
            return
        for delay in (3, 10, 30):
            GLib.timeout_add_seconds(delay, self._refresh_files, files)

    @staticmethod
    def _refresh_files(files):
        for file_info in files:
            try:
                file_info.invalidate_extension_info()
            except Exception:
                pass
        return GLib.SOURCE_REMOVE
