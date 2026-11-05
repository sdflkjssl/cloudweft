#!/usr/bin/env python3
"""Initialize a local AList admin password without parsing or logging secrets."""
import os
import pathlib
import secrets
import subprocess
import sys

binary, data_dir, password_file = map(pathlib.Path, sys.argv[1:4])
previous = data_dir / "data.db"
if password_file.exists() and password_file.stat().st_size:
    raise SystemExit(0)
if previous.exists() and os.environ.get("CLOUDWEFT_RECOVER_NEW") != "1":
    raise SystemExit("Existing AList database has no registered CloudWeft password; preserving administrator credentials.")
pwd = secrets.token_urlsafe(32)
result = subprocess.run([str(binary), "admin", "set", pwd, "--data", str(data_dir)],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, check=False)
if result.returncode or "admin user has been updated" not in result.stdout.lower():
    raise SystemExit("AList admin password setup failed. Check the local database.")
password_file.write_text(pwd + "\n", encoding="utf-8")
password_file.chmod(0o600)
print("Local AList admin credential initialized.")
