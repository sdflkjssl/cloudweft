#!/usr/bin/env python3
"""Fast, read-only Nautilus state projection of Rclone's existing VFS metadata.

All queries are local filesystem reads; never call AList or Rclone over the
network from a Nautilus InfoProvider callback.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("CLOUDWEFT_CONFIG_DIR", HOME / ".config/cloudweft"))
CACHE = Path(os.environ.get("CLOUDWEFT_CACHE_DIR", HOME / ".cache/cloudweft"))


def _file_complete(metadata: dict, data_path: Path) -> bool:
    size = metadata.get("Size")
    if not isinstance(size, int) or size < 0 or not data_path.is_file():
        return False
    try:
        if data_path.stat().st_size != size:
            return False
    except OSError:
        return False
    if size == 0:
        return True
    intervals = metadata.get("Rs")
    if not isinstance(intervals, list) or not all(isinstance(item, dict) for item in intervals):
        return False
    covered = 0
    for item in sorted(intervals, key=lambda x: x.get("Pos", -1)):
        if not isinstance(item, dict):
            return False
        start, count = item.get("Pos"), item.get("Size")
        if not isinstance(start, int) or not isinstance(count, int):
            return False
        if start > covered or start < 0 or count < 0:
            return False
        covered = max(covered, start + count)
        if covered >= size:
            return True
    return False


def locate(path: str, *, roots_path: Path | None = None) -> tuple[str, Path] | None:
    """Map a Nautilus path to one *registered* storage and its relative path."""
    roots_path = roots_path or CONFIG / "roots.json"
    try:
        roots = json.loads(roots_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(roots, dict):
        return None
    normalized = os.path.abspath(path)
    for sid, root in roots.items():
        if not isinstance(sid, str) or not isinstance(root, str):
            continue
        registered = os.path.abspath(root)
        try:
            inside = os.path.commonpath((normalized, registered)) == registered
        except ValueError:
            continue
        if inside:
            return sid, Path(os.path.relpath(normalized, registered))
    return None


def state(path: str, *, is_directory=False, roots_path: Path | None = None,
          cache_dir: Path | None = None) -> str | None:
    match = locate(path, roots_path=roots_path)
    if match is None:
        return None
    sid, relative = match
    if is_directory:
        return "online-only"
    cachedir = cache_dir or CACHE
    suffix = Path("cloudweft_" + sid) / relative
    metadata_path = cachedir / "rclone" / "vfsMeta" / suffix
    data_path = cachedir / "rclone" / "vfs" / suffix
    try:
        if metadata_path.stat().st_size > 128 * 1024:
            return "online-only"
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "online-only"
    if metadata.get("Dirty") is True:
        return "modified"
    return "cached" if _file_complete(metadata, data_path) else "online-only"
