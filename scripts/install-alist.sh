#!/usr/bin/env bash
set -euo pipefail

VERSION="${ALIST_VERSION:-v3.64.0}"
DATA_DIR="${FP_DATA_DIR:-$HOME/.cloud-drive-fp-data}"
PASS_FILE="$DATA_DIR/alist-admin-pass.txt"
BIN_DIR="$HOME/.local/bin"
ALIST_BIN="$BIN_DIR/alist"

case "$(uname -s)" in
  Darwin)
    OS="darwin"
    WORK_DIR="$HOME/Library/Application Support/alist"
    ;;
  Linux)
    OS="linux"
    WORK_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/plinth/alist"
    ;;
  *)
    echo "Unsupported OS for scripts/install-alist.sh: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64) ARCH="amd64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ASSET="alist-$OS-$ARCH.tar.gz"
URL="https://github.com/AlistGo/alist/releases/download/$VERSION/$ASSET"
ALIST_DATA="$WORK_DIR/data"

mkdir -p "$BIN_DIR" "$ALIST_DATA" "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [[ ! -x "$ALIST_BIN" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "[AList] downloading $VERSION ($OS/$ARCH)"
  curl -fL "$URL" -o "$TMP/alist.tar.gz"
  tar -xzf "$TMP/alist.tar.gz" -C "$TMP" alist
  install -m 755 "$TMP/alist" "$ALIST_BIN"
fi

# Cloud Drive FP Setup owns this AList data directory. If its admin credential
# is missing, reset/generate one and keep it only in the backend private state dir.
if [[ ! -s "$PASS_FILE" ]]; then
  RAW="$("$ALIST_BIN" admin random --data "$ALIST_DATA" 2>&1 || true)"
  CLEAN="$(printf '%s\n' "$RAW" | sed -E $'s/\\x1B\\[[0-9;?]*[ -\\/]*[@-~]//g')"
  PASSWORD="$(printf '%s\n' "$CLEAN" | sed -n 's/.*password:[[:space:]]*//p' | tail -1 | tr -d '\r')"
  if [[ -z "$PASSWORD" ]]; then
    echo "$RAW" >&2
    echo "Failed to capture generated AList admin password." >&2
    exit 1
  fi
  printf '%s' "$PASSWORD" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi

CONFIG_FILE="$ALIST_DATA/config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "AList config was not created: $CONFIG_FILE" >&2
  exit 1
fi
TMP_CONFIG="$CONFIG_FILE.tmp.$$"
awk '
  BEGIN { changed=0 }
  {
    if (!changed && $0 ~ /"address"[[:space:]]*:[[:space:]]*"0\.0\.0\.0"/) {
      sub(/"0\.0\.0\.0"/, "\"127.0.0.1\"")
      changed=1
    }
    print
  }
' "$CONFIG_FILE" > "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG_FILE"

printf 'AList binary: %s\n' "$ALIST_BIN"
printf 'AList data:   %s\n' "$ALIST_DATA"
printf 'AList admin credential: %s\n' "$PASS_FILE"
printf 'AList listen: 127.0.0.1:5244\n'
