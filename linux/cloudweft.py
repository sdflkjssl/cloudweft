#!/usr/bin/env python3
"""Linux CloudWeft: one AList storage instance per Rclone FUSE/VFS mount.

AList remains the authority for credentials and cloud drivers.  Rclone owns
on-demand reads, write-back and disk caching; CloudWeft only reconciles mounts.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

LOG = logging.getLogger("cloudweft")
HOME = Path.home()
DATA = Path(os.environ.get("CLOUDWEFT_DATA_DIR", HOME / ".local/share/cloudweft")).expanduser()
CONFIG = Path(os.environ.get("CLOUDWEFT_CONFIG_DIR", HOME / ".config/cloudweft")).expanduser()
CACHE = Path(os.environ.get("CLOUDWEFT_CACHE_DIR", HOME / ".cache/cloudweft")).expanduser()
MOUNT_ROOT = Path(os.environ.get("CLOUDWEFT_MOUNT_ROOT", HOME / "CloudWeft")).expanduser()
ALIST = os.environ.get("CLOUDWEFT_ALIST_URL", "http://127.0.0.1:5244").rstrip("/")
REFRESH = int(os.environ.get("CLOUDWEFT_REFRESH_SECONDS", "30"))
STOP = False


def http(method: str, uri: str, *, headers=None, payload=None, timeout=12) -> bytes:
    req = Request(uri, data=payload, method=method, headers=headers or {})
    with urlopen(req, timeout=timeout) as response:
        return response.read()


def alist_password() -> str:
    if os.environ.get("CLOUDWEFT_ALIST_PASSWORD"):
        return os.environ["CLOUDWEFT_ALIST_PASSWORD"]
    password_path = DATA / "alist-admin-pass.txt"
    if not password_path.is_file():
        raise RuntimeError("AList credential file missing: " + str(password_path))
    return password_path.read_text(encoding="utf-8").strip()


def alist_api() -> list[dict]:
    data = json.dumps({"username": "admin", "password": alist_password()}).encode()
    payload = json.loads(http("POST", ALIST + "/api/auth/login",
                              headers={"Content-Type": "application/json"}, payload=data))
    if payload.get("code") != 200:
        raise RuntimeError("AList admin login rejected: " + str(payload.get("message", "")))
    token = payload["data"]["token"]
    listed = json.loads(http("GET", ALIST + "/api/admin/storage/list",
                             headers={"Authorization": token}))
    if listed.get("code") != 200:
        raise RuntimeError("AList storage discovery failed: " + str(listed.get("message", "")))
    return listed.get("data", {}).get("content") or []


@dataclass(frozen=True)
class Storage:
    sid: str
    display: str
    mount: str
    status: str

    @staticmethod
    def from_alist(item: dict) -> "Storage":
        storage_id = int(item["id"])
        raw_mount = str(item.get("mount_path") or "/")
        mount = "/" + "/".join(p for p in raw_mount.split("/") if p)
        # Name is a presentation field; the storage ID is the identity.
        display = str(item.get("remark") or "").strip()
        if not display:
            display = mount.rstrip("/").split("/")[-1] or "Storage"
        display = unicodedata.normalize("NFC", display).replace("/", "_").replace("\\", "_")
        display = "".join(c if c.isprintable() else "_" for c in display)
        display = display.strip(" .") or ("storage-" + str(storage_id))
        return Storage("s" + str(storage_id), display, mount,
                       str(item.get("status") or ""))


def storage_available(item: dict, password: str) -> bool:
    if item.get("disabled"):
        return False
    if (item.get("status") or "") in ("", "work"):
        return True
    # AList may retain a stale failed status even after WebDAV recovers.
    import base64
    mount = Storage.from_alist(item).mount
    path = "/".join(quote(segment, safe="") for segment in mount.strip("/").split("/"))
    uri = ALIST + "/dav/" + path + "/"
    auth = base64.b64encode(("admin:" + password).encode()).decode()
    try:
        http("PROPFIND", uri, headers={"Authorization": "Basic " + auth,
                                     "Depth": "0"}, timeout=5)
        return True
    except (HTTPError, URLError, TimeoutError):
        return False


def mountpoints() -> set[str]:
    """Get mounted targets from the kernel (safe even with unresponsive FUSE)."""
    result = set()
    try:
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            fields = line.split()
            result.add(fields[4].replace("\\040", " "))
    except OSError:
        pass
    return result


def save_atomic(path: Path, content: str, mode: int = 0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".cloudweft-")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            file.write(content)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load_roots() -> dict[str, str]:
    path = CONFIG / "roots.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def choose_root(store: Storage, roots: dict[str, str]) -> Path:
    if store.sid in roots:
        path = Path(roots[store.sid])
        if path.resolve().parent != MOUNT_ROOT.resolve():
            raise RuntimeError("Existing mount path escapes CloudWeft directory: " + str(path))
        return path
    candidate = MOUNT_ROOT / store.display
    reserved = set(roots.values())
    if str(candidate) in reserved or candidate.exists():
        candidate = MOUNT_ROOT / (store.display + " (" + store.sid + ")")
    if str(candidate) in reserved or candidate.exists():
        raise RuntimeError("Both mount names occupied for " + store.sid)
    roots[store.sid] = str(candidate)
    save_atomic(CONFIG / "roots.json", json.dumps(roots, ensure_ascii=False, indent=2))
    return candidate


def remote_url(store: Storage) -> str:
    path = "/".join(quote(part, safe="") for part in store.mount.strip("/").split("/") if part)
    return ALIST + "/dav/" + path


def build_rclone_config(storages: list[Storage], password: str) -> Path:
    result = configparser.ConfigParser(interpolation=None)
    result.optionxform = str
    obscure = subprocess.run(["rclone", "obscure", password],
                             capture_output=True, text=True, check=True).stdout.strip()
    for storage in storages:
        result["cloudweft_" + storage.sid] = {
            "type": "webdav",
            "url": remote_url(storage),
            "vendor": "other",
            "user": "admin",
            "pass": obscure,
        }
    import io
    stream = io.StringIO()
    result.write(stream)
    dest = CONFIG / "rclone.conf"
    save_atomic(dest, stream.getvalue())
    return dest


def terminate_mount(proc: subprocess.Popen, path: Path):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    if str(path) in mountpoints():
        result = subprocess.run(["fusermount3", "-u", str(path)], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode and str(path) in mountpoints():
            subprocess.run(["fusermount3", "-uz", str(path)], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Supervisor:
    def __init__(self):
        self.children: dict[str, tuple[subprocess.Popen, Path, object]] = {}
        self.roots = load_roots()
        self.storage_ids: set[str] = set()
        self.mount_config: dict[str, str] = {}

    def start(self, store: Storage, config: Path):
        root = choose_root(store, self.roots)
        root.mkdir(parents=True, exist_ok=True)
        if str(root) in mountpoints():
            LOG.warning("Mount already active at %s; skipping duplicate", root)
            return
        log_path = DATA / "logs" / (store.sid + ".log")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log = open(log_path, "a", encoding="utf-8")
        args = [
            "rclone", "mount", "cloudweft_" + store.sid + ":", str(root),
            "--config", str(config), "--vfs-cache-mode", "full",
            "--cache-dir", str(CACHE / "rclone"),
            "--vfs-write-back", "5s",
            "--vfs-cache-max-size", os.environ.get("CLOUDWEFT_VFS_CACHE_SIZE", "30G"),
            "--vfs-cache-max-age", os.environ.get("CLOUDWEFT_VFS_CACHE_AGE", "720h"),
            "--vfs-read-chunk-size", "16M", "--vfs-read-chunk-size-limit", "256M",
            # WebDAV/AList has no remote change feed. Keep the namespace cache
            # short so external deletion (especially empty folders) becomes
            # visible on re-enumeration without restarting the mount.
            "--buffer-size", "16M", "--dir-cache-time",
            os.environ.get("CLOUDWEFT_DIR_CACHE_TIME", "15s"),
            "--poll-interval", "0",
            "--transfers", "8", "--umask", "027",
            "--log-level", "INFO"
        ]
        try:
            proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
        except Exception:
            log.close()
            raise
        self.children[store.sid] = (proc, root, log)
        self.mount_config[store.sid] = self.desired_config(store, alist_password())
        LOG.info("Mounted %s (%s) at %s [pid=%d]", store.display, store.sid, root, proc.pid)

    @staticmethod
    def desired_config(store: Storage, password: str) -> str:
        return hashlib.sha256((remote_url(store) + "\\0" + password).encode()).hexdigest()

    def reconcile(self):
        records = alist_api()
        password = alist_password()
        enabled = [item for item in records if not item.get("disabled")]
        configured_ids = {Storage.from_alist(item).sid for item in enabled}
        available = [Storage.from_alist(item) for item in enabled
                     if storage_available(item, password)]
        config = build_rclone_config(available, password)
        by_id = {store.sid: store for store in available}
        for sid, (proc, path, log) in list(self.children.items()):
            store = by_id.get(sid)
            changed = store is not None and self.mount_config.get(sid) != self.desired_config(store, password)
            # A temporary cloud-driver failure must not discard the VFS cache
            # or pending local writes. Only an explicit removal/disable stops
            # a healthy mount.
            if sid not in configured_ids or proc.poll() is not None or changed:
                LOG.warning("Removing mount worker %s (exit=%s)", sid, proc.poll())
                terminate_mount(proc, path)
                log.close()
                del self.children[sid]
                self.mount_config.pop(sid, None)
        for store in available:
            if store.sid not in self.children:
                self.start(store, config)
        self.storage_ids = configured_ids

    def close(self):
        for sid, (proc, path, log) in list(self.children.items()):
            terminate_mount(proc, path)
            log.close()
            del self.children[sid]
            self.mount_config.pop(sid, None)


def stop_signal(_sig, _frame):
    global STOP
    STOP = True


def run():
    MOUNT_ROOT.mkdir(parents=True, exist_ok=True)
    DATA.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, stop_signal)
    signal.signal(signal.SIGINT, stop_signal)
    manager = Supervisor()
    try:
        while not STOP:
            try:
                manager.reconcile()
            except Exception as exc:
                LOG.warning("Discovery or mount failed (retrying): %s", exc)
            for _ in range(max(1, REFRESH)):
                if STOP:
                    break
                time.sleep(1)
    finally:
        manager.close()


def status():
    roots = load_roots()
    mounted = mountpoints()
    if not roots:
        print("No storage instances have been mounted yet.")
    for sid, target in sorted(roots.items()):
        print(sid + "\t" + ("mounted" if target in mounted else "unmounted") + "\t" + target)
    try:
        for item in alist_api():
            store = Storage.from_alist(item)
            print("AList\t" + store.sid + "\t" + store.display + "\t" + store.status)
    except Exception as exc:
        print("AList unavailable: " + str(exc), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="CloudWeft Linux FUSE frontend")
    parser.add_argument("command", choices=["run", "status", "check"])
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s",
                        stream=sys.stdout)
    if args.command == "run":
        run()
    elif args.command == "status":
        status()
    elif args.command == "check":
        print(json.dumps([storage.__dict__ for storage in
                          (Storage.from_alist(i) for i in alist_api())],
                         ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
