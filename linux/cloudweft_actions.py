#!/usr/bin/env python3
"""Desktop actions for CloudWeft; use the mounted VFS and never launch a shell."""
from __future__ import annotations

import argparse
import concurrent.futures
import logging
import os
import shutil
import subprocess
from pathlib import Path

import cache_status

LOG = logging.getLogger("cloudweft-actions")


def files_under(paths: list[str]):
    for target in paths:
        absolute = os.path.abspath(target)
        if cache_status.locate(absolute) is None:
            raise ValueError("Path is outside a registered CloudWeft storage")
        if os.path.islink(absolute):
            raise ValueError("Symbolic-link downloads are not supported")
        if os.path.isdir(absolute):
            for current, directories, files in os.walk(absolute, followlinks=False):
                directories[:] = [item for item in directories
                                 if not os.path.islink(os.path.join(current, item))]
                for name in files:
                    pathname = os.path.join(current, name)
                    if not os.path.islink(pathname):
                        yield pathname
        elif os.path.isfile(absolute):
            yield absolute
        else:
            raise FileNotFoundError(absolute)


def hydrate(file_path: str) -> int:
    total = 0
    with open(file_path, "rb", buffering=0) as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            total += len(block)
    LOG.info("Cached %d bytes: %s", total, file_path)
    return total


def download(paths: list[str], max_workers: int = 6) -> tuple[int, int]:
    downloaded = 0
    failures = 0
    tasks: set[concurrent.futures.Future] = set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        try:
            for path in files_under(paths):
                tasks.add(executor.submit(hydrate, path))
                if len(tasks) >= max_workers * 3:
                    done, tasks = concurrent.futures.wait(tasks,
                        return_when=concurrent.futures.FIRST_COMPLETED)
                    for future in done:
                        try:
                            downloaded += future.result()
                        except Exception:
                            failures += 1
                            LOG.exception("File download failed")
        except Exception:
            failures += 1
            LOG.exception("Directory enumeration failed")
        for future in concurrent.futures.as_completed(tasks):
            try:
                downloaded += future.result()
            except Exception:
                failures += 1
                LOG.exception("File download failed")
    return downloaded, failures


def main():
    parser = argparse.ArgumentParser(description="CloudWeft desktop file actions")
    parser.add_argument("command", choices=["download", "status"])
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if args.command == "status":
        for path in args.paths:
            print((cache_status.state(path, is_directory=Path(path).is_dir())
                   or "outside") + "\t" + path)
        return
    bytes_downloaded, errors = download(args.paths)
    if shutil.which("notify-send") and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        title = "CloudWeft"
        message = (f"{errors} file(s) could not be downloaded" if errors
                   else f"Downloaded {bytes_downloaded:,} bytes to local cache")
        try:
            subprocess.run(["notify-send", "--app-name=CloudWeft", title, message],
                           timeout=3, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
    if errors:
        raise SystemExit(f"{errors} files failed; see CloudWeft action log")
    print(f"Cached {bytes_downloaded} bytes")


if __name__ == "__main__":
    main()
