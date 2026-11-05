#!/usr/bin/env python3
"""Live, isolated AList -> Rclone -> FUSE read/write regression.

Creates a temporary AList Local storage, then deletes only that test storage.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import cloudweft
import cache_status


def auth():
    request = json.dumps({"username": "admin", "password": cloudweft.alist_password()}).encode()
    response = json.loads(cloudweft.http("POST", cloudweft.ALIST + "/api/auth/login",
                                     headers={"Content-Type": "application/json"}, payload=request))
    assert response["code"] == 200, response.get("message")
    return {"Authorization": response["data"]["token"],
            "Content-Type": "application/json"}


def api(path, *, method="GET", data=None, headers=None):
    return json.loads(cloudweft.http(method, cloudweft.ALIST + path,
                      headers=headers or auth(),
                      payload=json.dumps(data).encode() if data is not None else None))


def poll(fn, seconds=45):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if fn():
                return
        except (FileNotFoundError, OSError):
            pass
        time.sleep(.5)
    raise AssertionError("Timed out: " + repr(fn))


def main():
    with tempfile.TemporaryDirectory(prefix="cloudweft-linux-it-") as temp:
        source = pathlib.Path(temp)
        (source / "hello.txt").write_text("hello through AList\n", encoding="utf-8")
        (source / "folder").mkdir()
        (source / "folder" / "a.txt").write_text("nested\n", encoding="utf-8")
        label = "_cloudweft_linux_test_" + str(os.getpid())
        record = {
            "mount_path": "/" + label,
            "driver": "Local",
            "remark": label,
            "webdav_policy": "native_proxy",
            "cache_expiration": 0,
            "addition": json.dumps({"root_folder_path": str(source), "show_hidden": True}),
        }
        imported = subprocess.run(
            [sys.executable, str(pathlib.Path(__file__).resolve().parents[1] /
                                 "import_storages.py")],
            input=json.dumps([record]), text=True,
            capture_output=True, check=False,
        )
        assert imported.returncode == 0, imported.stderr
        storage_id = next(int(item["id"]) for item in cloudweft.alist_api()
                          if item["mount_path"] == record["mount_path"])
        sid = "s" + str(storage_id)
        root = cloudweft.MOUNT_ROOT / label
        print("Created temporary storage", sid, flush=True)
        try:
            poll(lambda: any(int(x["id"]) == storage_id and x.get("status") == "work"
                             for x in cloudweft.alist_api()), 25)
            subprocess.run(["systemctl", "--user", "restart", "cloudweft-linux.service"], check=True)
            poll(lambda: str(root) in cloudweft.mountpoints(), 30)
            assert cache_status.state(str(root / "hello.txt")) == "online-only"
            assert (root / "hello.txt").read_text() == "hello through AList\n"
            assert (root / "folder" / "a.txt").read_text() == "nested\n"
            poll(lambda: cache_status.state(str(root / "hello.txt")) == "cached", 10)
            print("PASS Rclone cache-backed status transitions", flush=True)
            subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve().parents[1] /
                         "cloudweft_actions.py"), "download", str(root / "folder")],
                           check=True, capture_output=True, text=True)
            assert cache_status.state(str(root / "folder" / "a.txt")) == "cached"
            print("PASS Nautilus background download action", flush=True)
            print("PASS mount, nested listing, on-demand read", flush=True)

            (root / "uploaded.txt").write_text("upload through FUSE\n", encoding="utf-8")
            poll(lambda: (source / "uploaded.txt").exists(), 30)
            assert (source / "uploaded.txt").read_text() == "upload through FUSE\n"
            print("PASS write-back upload", flush=True)

            (root / "hello.txt").rename(root / "renamed.txt")
            poll(lambda: (source / "renamed.txt").exists(), 30)
            assert not (source / "hello.txt").exists()
            print("PASS rename", flush=True)

            (root / "uploaded.txt").unlink()
            poll(lambda: not (source / "uploaded.txt").exists(), 30)
            (root / "newfolder").mkdir()
            (root / "newfolder" / "child.txt").write_text("child\n")
            poll(lambda: (source / "newfolder" / "child.txt").exists(), 30)
            print("PASS deletion, directory and nested write-back", flush=True)

            # A deletion made outside the mount must disappear from the VFS
            # namespace, including an empty folder created by this client.
            (root / "external-delete-empty").mkdir()
            poll(lambda: (source / "external-delete-empty").is_dir(), 30)
            assert (root / "external-delete-empty").is_dir()
            (source / "external-delete-empty").rmdir()
            poll(lambda: "external-delete-empty" not in {p.name for p in root.iterdir()}, 45)
            print("PASS externally deleted empty directory disappears", flush=True)

            (source / "external-delete-full").mkdir()
            (source / "external-delete-full" / "entry.txt").write_text("content")
            poll(lambda: (root / "external-delete-full" / "entry.txt").is_file(), 45)
            (source / "external-delete-full" / "entry.txt").unlink()
            (source / "external-delete-full").rmdir()
            poll(lambda: "external-delete-full" not in {p.name for p in root.iterdir()}, 45)
            print("PASS externally deleted nonempty directory disappears", flush=True)
        finally:
            result = api("/api/admin/storage/delete?" + urlencode({"id": storage_id}),
                         method="POST")
            if result.get("code") != 200:
                print("WARNING: cleanup storage failed:", result.get("message"), file=sys.stderr)
            subprocess.run(["systemctl", "--user", "restart", "cloudweft-linux.service"],
                           check=False)
            poll(lambda: str(root) not in cloudweft.mountpoints(), 20)
            if root.exists() and not any(root.iterdir()):
                root.rmdir()
            roots = cloudweft.load_roots()
            if roots.get(sid) == str(root):
                del roots[sid]
                cloudweft.save_atomic(cloudweft.CONFIG / "roots.json", json.dumps(roots, indent=2))
            print("Temporary test storage cleaned up", flush=True)


if __name__ == "__main__":
    main()
