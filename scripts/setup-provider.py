#!/usr/bin/env python3
from __future__ import annotations

import getpass
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

HOME = Path.home()
PROJECT = Path(__file__).resolve().parents[1]
ALIST = HOME / ".local/bin/alist"
ALIST_DATA = HOME / "Library/Application Support/alist/data"
PASS_FILE = HOME / ".cloud-drive-fp-data/alist-admin-pass.txt"
ALIST_URL = "http://127.0.0.1:5244"
BRIDGE_URL = "http://127.0.0.1:8081"

BAIDU_REDIRECT_URI = "https://alistgo.com/tool/baidu/callback"


def request_json(path: str, *, method: str = "GET", token: str | None = None, body=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(ALIST_URL + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


def admin_username() -> str:
    db = ALIST_DATA / "data.db"
    try:
        con = sqlite3.connect(db)
        row = con.execute("select username from x_users where id=2 limit 1").fetchone()
        if row and row[0]:
            return str(row[0])
    except Exception:
        pass
    return "admin"


def stored_password_works(username: str) -> bool:
    if not PASS_FILE.is_file():
        return False
    password = PASS_FILE.read_text().strip()
    if not password:
        return False
    try:
        payload = request_json(
            "/api/auth/login",
            method="POST",
            body={"username": username, "password": password},
        )
        return payload.get("code") == 200 and bool((payload.get("data") or {}).get("token"))
    except Exception:
        return False


def reset_admin_password() -> None:
    if not ALIST.is_file():
        raise RuntimeError("AList is not installed; run scripts/install-services.sh first")
    raw = subprocess.check_output(
        [str(ALIST), "admin", "random", "--data", str(ALIST_DATA)],
        stderr=subprocess.STDOUT,
        text=True,
    )
    clean = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", raw)
    matches = re.findall(r"password:\s*(\S+)", clean, flags=re.I)
    if not matches:
        raise RuntimeError("AList did not return a generated admin password")
    PASS_FILE.parent.mkdir(parents=True, exist_ok=True)
    PASS_FILE.write_text(matches[-1])
    os.chmod(PASS_FILE, 0o600)
    domain = f"gui/{os.getuid()}"
    for label in ("com.local.alist", "com.local.cloud-drive-fp-bridge"):
        subprocess.run(["launchctl", "kickstart", "-k", f"{domain}/{label}"], check=False)
    for _ in range(30):
        try:
            urllib.request.urlopen(ALIST_URL + "/ping", timeout=1).read()
            break
        except Exception:
            time.sleep(0.25)


def ensure_admin_password() -> str:
    username = admin_username()
    if not stored_password_works(username):
        reset_admin_password()
    if not stored_password_works(username):
        raise RuntimeError("Unable to reconcile the Cloud Drive FP AList admin credential")
    return username


def admin_token(username: str) -> str:
    password = PASS_FILE.read_text().strip()
    payload = request_json(
        "/api/auth/login",
        method="POST",
        body={"username": username, "password": password},
    )
    token = (payload.get("data") or {}).get("token")
    if payload.get("code") != 200 or not token:
        raise RuntimeError(payload.get("message") or "AList admin login failed")
    return str(token)


def open_alist() -> None:
    username = ensure_admin_password()
    password = PASS_FILE.read_text().strip()
    try:
        subprocess.run(["pbcopy"], input=password, text=True, check=True)
        copied = True
    except Exception:
        copied = False
    print(f"AList username: {username}")
    print("AList password: copied to clipboard" if copied else f"AList password: {password}")
    webbrowser.open(ALIST_URL + "/@manage/storages")


def field_default(field: dict):
    value = field.get("default", "")
    kind = str(field.get("type") or "").lower()
    if kind in {"bool", "boolean"}:
        return str(value).lower() == "true"
    if kind in {"number", "integer"}:
        if value in {"", None}:
            return 0
        try:
            number = float(value)
            return int(number) if number.is_integer() else number
        except (TypeError, ValueError):
            return 0
    return "" if value is None else value


def defaults(fields) -> dict:
    return {
        field["name"]: field_default(field)
        for field in (fields or [])
        if isinstance(field, dict) and field.get("name")
    }


def driver_info(token: str, driver: str) -> dict:
    payload = request_json(
        "/api/admin/driver/info?driver=" + urllib.parse.quote(driver),
        token=token,
    )
    if payload.get("code") != 200:
        raise RuntimeError(payload.get("message") or f"Unable to read {driver} driver schema")
    data = payload.get("data") or {}
    if not isinstance(data, dict):
        raise RuntimeError(f"AList returned an invalid {driver} driver schema")
    return data


def baidu_oauth_url(driver: dict) -> str:
    additional = defaults(driver.get("additional") or driver.get("addition") or [])
    client_id = str(additional.get("client_id") or "").strip()
    if not client_id:
        raise RuntimeError("AList BaiduNetdisk driver has no default client_id")
    return "https://openapi.baidu.com/oauth/2.0/authorize?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "qrcode": "1",
            "redirect_uri": BAIDU_REDIRECT_URI,
            "response_type": "code",
            "scope": "basic,netdisk",
        }
    )


def baidu_addition(driver: dict, refresh_token: str) -> str:
    fields = driver.get("additional") or driver.get("addition") or []
    addition = defaults(fields)
    normalized = {
        str(key).lower().replace("-", "_").replace(" ", "_"): key
        for key in addition
    }
    refresh_key = normalized.get("refresh_token")
    if not refresh_key:
        raise RuntimeError("AList BaiduNetdisk schema has no refresh_token field")
    addition[refresh_key] = refresh_token

    root_key = normalized.get("root_folder_path") or normalized.get("root_folder_id")
    if root_key and not addition.get(root_key):
        addition[root_key] = "/"

    return json.dumps(addition, ensure_ascii=False, separators=(",", ":"))


def setup_baidu() -> None:
    username = ensure_admin_password()
    token = admin_token(username)
    driver = driver_info(token, "BaiduNetdisk")
    print("Opening Baidu authorization for the AList BaiduNetdisk driver…")
    webbrowser.open(baidu_oauth_url(driver))
    refresh = getpass.getpass("Paste the returned refresh token here (input hidden): ").strip()
    if not refresh:
        raise RuntimeError("No refresh token supplied")

    listing = request_json("/api/admin/storage/list?page=1&per_page=100", token=token)
    if listing.get("code") != 200:
        raise RuntimeError(listing.get("message") or "Unable to list AList storages")
    existing = next(
        (x for x in ((listing.get("data") or {}).get("content") or []) if x.get("mount_path") == "/baidu"),
        None,
    )

    body = defaults(driver.get("common") or [])
    body.update(
        {
            "mount_path": "/baidu",
            "driver": "BaiduNetdisk",
            "remark": "百度网盘",
            "webdav_policy": "native_proxy",
            "addition": baidu_addition(driver, refresh),
        }
    )
    endpoint = "/api/admin/storage/create"
    if existing:
        body["id"] = existing.get("id")
        body["status"] = existing.get("status") or "work"
        endpoint = "/api/admin/storage/update"

    result = request_json(endpoint, method="POST", token=token, body=body)
    if result.get("code") != 200:
        raise RuntimeError(result.get("message") or "AList rejected the Baidu storage configuration")

    for _ in range(20):
        time.sleep(0.5)
        listing = request_json("/api/admin/storage/list?page=1&per_page=100", token=token)
        item = next(
            (x for x in ((listing.get("data") or {}).get("content") or []) if x.get("mount_path") == "/baidu"),
            None,
        )
        if item and not item.get("disabled") and (not item.get("status") or item.get("status") == "work"):
            print("BaiduNetdisk is configured at /baidu and reports healthy.")
            if sys.platform == "darwin":
                for app in (Path("/Applications/Plinth.app"), HOME / "Applications/Plinth.app"):
                    if app.exists():
                        subprocess.run(["open", str(app)], check=False)
                        break
            return
    status = item.get("status") if item else "missing"
    raise RuntimeError(f"BaiduNetdisk was saved but is not healthy yet: {status}")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in {"-h", "--help"}:
        print("Usage:")
        print("  scripts/setup-provider.py alist")
        print("  scripts/setup-provider.py baidu")
        return 0
    command = sys.argv[1].lower()
    if command == "alist":
        open_alist()
        return 0
    if command == "baidu":
        setup_baidu()
        return 0
    raise RuntimeError(f"Unsupported provider setup: {command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
