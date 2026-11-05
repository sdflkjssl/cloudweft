#!/usr/bin/env python3
"""Import AList storage definitions over a trusted SSH pipe.

Only storage definitions are copied; local AList admin credentials remain local.
The input may contain cloud refresh tokens, so do not print or persist stdin.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cloudweft


def api(token, method, path, payload=None):
    result = json.loads(cloudweft.http(
        method, cloudweft.ALIST + path,
        headers={"Authorization": token, "Content-Type": "application/json"},
        payload=json.dumps(payload).encode() if payload is not None else None,
    ))
    if result.get("code") != 200:
        raise RuntimeError("AList request rejected at " + path.split("?")[0])
    return result["data"]


def main():
    source = sys.stdin.buffer.read(2_000_001)
    if len(source) > 2_000_000:
        raise SystemExit("Storage definitions exceed the 2 MB import limit")
    records = json.loads(source)
    if not isinstance(records, list):
        raise SystemExit("Expected a list of AList storage definitions")
    login = json.loads(cloudweft.http(
        "POST", cloudweft.ALIST + "/api/auth/login",
        headers={"Content-Type": "application/json"},
        payload=json.dumps({"username": "admin", "password": cloudweft.alist_password()}).encode(),
    ))
    if login.get("code") != 200:
        raise SystemExit("Local AList authentication failed")
    token = login["data"]["token"]
    current = {item["mount_path"]: item for item in cloudweft.alist_api()}
    for record in records:
        if not isinstance(record, dict):
            raise SystemExit("Invalid storage record")
        mount = record.get("mount_path")
        driver = record.get("driver")
        addition = record.get("addition")
        if not isinstance(mount, str) or not mount.startswith("/") or not isinstance(driver, str) or not isinstance(addition, str):
            raise SystemExit("Invalid AList storage fields")
        if mount in current:
            if current[mount].get("driver") != driver:
                raise SystemExit("Mount path conflict: " + mount)
            print("Existing mount preserved:", mount)
            continue
        # Preserve the AList driver schema and auth parameters; assign a new
        # local storage ID, which remains stable in this Linux instance.
        allowed = ("mount_path", "order", "driver", "cache_expiration",
                   "addition", "remark", "disabled", "disable_index",
                   "enable_sign", "order_by", "order_direction",
                   "extract_folder", "web_proxy", "webdav_policy",
                   "proxy_range", "down_proxy_url", "down_proxy_sign")
        payload = {key: record[key] for key in allowed if key in record}
        api(token, "POST", "/api/admin/storage/create", payload)
        print("Imported storage:", mount, "(" + driver + ")")
    print("AList storage import complete")


if __name__ == "__main__":
    main()
