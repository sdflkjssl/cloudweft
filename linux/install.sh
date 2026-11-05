#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${CLOUDWEFT_DATA_DIR:-$HOME/.local/share/cloudweft}"
ALIST_DATA="$DATA/alist-data"
BIN="$HOME/.local/bin/cloudweft-alist"
SERVICES="$HOME/.config/systemd/user"
VERSION="${CLOUDWEFT_ALIST_VERSION:-v3.66.0}"

# Migrate the earlier experimental Linux-only Plinth service without losing
# its AList configuration or exposing the old cloud root as a new product.
LEGACY_DATA="$HOME/.local/share/plinth"
LEGACY_CONFIG="$HOME/.config/plinth"
if [[ -d "$LEGACY_DATA" && ! -d "$DATA" ]]; then
    if findmnt -rn -o TARGET | grep -Fxq "$HOME/Plinth"; then
        echo "Legacy root still mounted; refuse migration while it is in use." >&2
        exit 1
    fi
    if findmnt -rn -o TARGET | grep -Fqx -- "$HOME/Plinth/quark"; then
        echo "Legacy cloud mount active; refuse migration." >&2
        exit 1
    fi
    if [[ -f "$LEGACY_CONFIG/roots.json" ]]; then
        # Do not convert a configured account automatically; encrypted write-back
        # cache must be drained and explicitly reconciled first.
        if python3 - "$LEGACY_CONFIG/roots.json" <<'PY'
import json,sys
sys.exit(0 if not json.load(open(sys.argv[1])) else 1)
PY
        then :; else
            echo "Legacy configured mounts found; preserve old service and request explicit migration." >&2
            exit 1
        fi
    fi
    systemctl --user stop plinth-linux.service plinth-alist.service 2>/dev/null || true
    systemctl --user disable plinth-linux.service plinth-alist.service 2>/dev/null || true
    mkdir -p "$(dirname "$DATA")"
    mv "$LEGACY_DATA" "$DATA"
    if [[ -x "$HOME/.local/bin/plinth-alist" && ! -x "$HOME/.local/bin/cloudweft-alist" ]]; then
        cp -p "$HOME/.local/bin/plinth-alist" "$HOME/.local/bin/cloudweft-alist"
    fi
    echo "Migrated experimental local AList data into CloudWeft."
fi

if command -v apt-get >/dev/null; then
    DEPENDENCIES=()
    command -v python3 >/dev/null || DEPENDENCIES+=(python3)
    command -v curl >/dev/null || DEPENDENCIES+=(curl)
    command -v tar >/dev/null || DEPENDENCIES+=(tar)
    command -v rclone >/dev/null || DEPENDENCIES+=(rclone)
    command -v fusermount3 >/dev/null || DEPENDENCIES+=(fuse3)
    if (("${#DEPENDENCIES[@]}" > 0)); then
        sudo apt-get update -qq
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq "${DEPENDENCIES[@]}"
    fi
fi
for command in python3 curl tar rclone fusermount3 systemctl; do
    command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }
done
mkdir -p "$DATA" "$ALIST_DATA" "$HOME/.local/bin" "$SERVICES" "$HOME/CloudWeft"
chmod 700 "$DATA" "$ALIST_DATA"

if command -v nautilus >/dev/null; then
    if ! python3 -c 'import gi; gi.require_version("Nautilus", "4.1"); from gi.repository import Nautilus' >/dev/null 2>&1; then
        if command -v apt-get >/dev/null; then
            sudo apt-get update -qq
            DEBIAN_FRONTEND=noninteractive sudo apt-get install -y -qq python3-nautilus gir1.2-nautilus-4.1
        else
            echo "Nautilus Python extension packages unavailable; FUSE mount still works." >&2
        fi
    fi
fi

if [[ ! -x "$BIN" ]]; then
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        *) echo "Unsupported CPU architecture" >&2; exit 1 ;;
    esac
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fL --retry 3 --connect-timeout 15 \
        "https://github.com/AlistGo/alist/releases/download/$VERSION/alist-linux-$ARCH.tar.gz" \
        -o "$TMP/alist.tar.gz"
    tar -tzf "$TMP/alist.tar.gz" | grep -qx 'alist' || {
        echo "Unexpected AList release archive" >&2; exit 1;
    }
    tar -xOzf "$TMP/alist.tar.gz" alist > "$TMP/alist"
    chmod 700 "$TMP/alist"
    install -m 700 "$TMP/alist" "$BIN"
fi

PASSWORD_FILE="$DATA/alist-admin-pass.txt"
if [[ ! -s "$PASSWORD_FILE" ]]; then
    python3 "$ROOT/linux/alist_init.py" "$BIN" "$ALIST_DATA" "$PASSWORD_FILE"
fi

# Bound the admin API to loopback; cloud content is exposed only in user mounts.
python3 - "$ALIST_DATA/config.json" "$ALIST_DATA/data.db" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
database = pathlib.Path(sys.argv[2])
if not path.exists():
    raise SystemExit("Missing AList config: " + str(path))
obj = json.loads(path.read_text())
obj.setdefault("scheme", {})["address"] = "127.0.0.1"
current = obj.setdefault("database", {}).get("db_file", "")
# AList stores absolute SQLite paths. Move only the old generated default.
if "/plinth/" in current or current in ("", "data/data.db"):
    obj["database"]["db_file"] = str(database)
path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n")
PY

cat > "$SERVICES/cloudweft-alist.service" <<'UNIT'
[Unit]
Description=CloudWeft AList cloud driver backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/cloudweft-alist server --data %h/.local/share/cloudweft/alist-data
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=default.target
UNIT

cat > "$SERVICES/cloudweft-linux.service" <<UNIT
[Unit]
Description=CloudWeft Linux cloud files (AList and Rclone FUSE)
After=network-online.target cloudweft-alist.service
Wants=cloudweft-alist.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 "$ROOT/linux/cloudweft.py" run
Restart=on-failure
RestartSec=8
UMask=0077

[Install]
WantedBy=default.target
UNIT

# Nautilus can open the root directly; preserve all existing user bookmarks.
python3 - "$HOME/CloudWeft" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
bookmark = Path.home() / ".config/gtk-3.0/bookmarks"
bookmark.parent.mkdir(parents=True, exist_ok=True)
existing = bookmark.read_text(encoding="utf-8") if bookmark.exists() else ""
if root.as_uri() not in [line.split(" ", 1)[0] for line in existing.splitlines()]:
    bookmark.write_text(existing.rstrip("\n") + "\n" + root.as_uri() + " CloudWeft\n",
                        encoding="utf-8")
PY
DESKTOP="$HOME/.local/share/applications/cloudweft.desktop"
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<UNIT
[Desktop Entry]
Type=Application
Name=CloudWeft
Comment=Cloud files powered by AList and Rclone
Exec=nautilus "$HOME/CloudWeft"
Icon=folder-remote
Terminal=false
Categories=Utility;FileTools;
UNIT
chmod 644 "$DESKTOP"

# Integrate file status and cache download into GNOME Files via the official
# python3-nautilus bridge. Existing icon assets are upstream Apache-2.0 Wusel
# graphics with the license included in the source distribution.
if command -v nautilus >/dev/null && python3 -c 'import gi;gi.require_version("Nautilus","4.1");from gi.repository import Nautilus' >/dev/null 2>&1; then
    mkdir -p "$DATA/runtime" "$HOME/.local/share/nautilus-python/extensions"
    install -m 644 "$ROOT/linux/cache_status.py" "$DATA/runtime/cache_status.py"
    install -m 644 "$ROOT/linux/cloudweft_actions.py" "$DATA/runtime/cloudweft_actions.py"
    install -m 644 "$ROOT/linux/nautilus/cloudweft_nautilus.py" "$HOME/.local/share/nautilus-python/extensions/cloudweft_nautilus.py"
    ICON_DEST="$HOME/.local/share/icons/hicolor/scalable/emblems"
    mkdir -p "$ICON_DEST"
    for icon in "$ROOT"/linux/nautilus/emblems/*.svg; do
        install -m 644 "$icon" "$ICON_DEST/$(basename "$icon")"
    done
    # Nautilus loads extensions at startup. A new window after this point
    # sees native emblems; no command-line window is launched by menus.
    nautilus -q >/dev/null 2>&1 || true
fi

systemctl --user daemon-reload
systemctl --user enable --now cloudweft-alist.service
for _ in {1..40}; do
    if curl -fsS --max-time 2 http://127.0.0.1:5244/ping | grep -qx pong; then
        break
    fi
    sleep 0.5
done
curl -fsS --max-time 5 http://127.0.0.1:5244/ping | grep -qx pong || {
    echo "AList did not start; inspect: journalctl --user -u cloudweft-alist" >&2
    exit 1
}
systemctl --user enable --now cloudweft-linux.service
# Retire only the launcher and bookmark created by the old experimental
# installer. Leave any unrelated Plinth application and user files intact.
LEGACY_DESKTOP="$HOME/.local/share/applications/plinth.desktop"
if [[ -f "$LEGACY_DESKTOP" ]] &&
   grep -Fqx 'Comment=Cloud files powered by AList and Rclone' "$LEGACY_DESKTOP" &&
   grep -Fq "$HOME/Plinth" "$LEGACY_DESKTOP"; then
    rm -- "$LEGACY_DESKTOP"
    python3 - "$HOME/Plinth" <<'PY'
from pathlib import Path
import sys
bookmark = Path.home() / ".config/gtk-3.0/bookmarks"
if bookmark.exists():
    obsolete = Path(sys.argv[1]).resolve().as_uri() + " Plinth"
    keep = [line for line in bookmark.read_text(encoding="utf-8").splitlines()
            if line != obsolete]
    bookmark.write_text("\n".join(keep) + "\n", encoding="utf-8")
PY
fi
echo "Installed CloudWeft Linux: ~/CloudWeft"
echo "AList management: http://127.0.0.1:5244 (admin)"
echo "Current mount status: python3 $ROOT/linux/cloudweft.py status"
