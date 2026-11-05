#!/usr/bin/env bash
set -euo pipefail

LABEL_ALIST="com.local.alist"
LABEL_BRIDGE="com.local.cloud-drive-fp-bridge"
UID_NOW="$(id -u)"
DOMAIN="gui/$UID_NOW"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_DIR="$HOME"
DATA_DIR="$HOME_DIR/.cloud-drive-fp-data"
LEGACY_DIR="$HOME_DIR/Projects/quark-sync"
ALIST_BIN="$HOME_DIR/.local/bin/alist"
ALIST_WORK_DIR="$HOME_DIR/Library/Application Support/alist"
NODE_BIN="$(command -v node || true)"
LAUNCH_AGENTS="$HOME_DIR/Library/LaunchAgents"
ALIST_DST="$LAUNCH_AGENTS/$LABEL_ALIST.plist"
BRIDGE_DST="$LAUNCH_AGENTS/$LABEL_BRIDGE.plist"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "node executable not found"
[[ -f "$PROJECT_ROOT/macos/server/alist-bridge.js" ]] || fail "bridge missing under $PROJECT_ROOT"

mkdir -p "$DATA_DIR/logs" "$LAUNCH_AGENTS"

# One-time migration from the original quark-sync state directory. Existing
# canonical files always win, so rerunning this installer is safe.
for name in alist-admin-pass.txt fp-idmap.json fp-idmap-baidu.json; do
  if [[ ! -e "$DATA_DIR/$name" && -f "$LEGACY_DIR/$name" ]]; then
    cp -p "$LEGACY_DIR/$name" "$DATA_DIR/$name"
    printf 'migrated %s\n' "$name"
  fi
done
chmod 700 "$DATA_DIR"
chmod 600 "$DATA_DIR"/alist-admin-pass.txt 2>/dev/null || true

# AList is managed by the Cloud Drive FP backend setup layer. Migrate an
# existing local admin credential first, then bootstrap AList only if needed.
bash "$PROJECT_ROOT/scripts/install-alist.sh"
[[ -x "$ALIST_BIN" ]] || fail "AList bootstrap failed: $ALIST_BIN"
[[ -d "$ALIST_WORK_DIR" ]] || fail "AList working directory missing: $ALIST_WORK_DIR"

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render() {
  local src="$1" dst="$2"
  sed \
    -e "s|__ALIST_BIN__|$(escape_sed "$ALIST_BIN")|g" \
    -e "s|__ALIST_WORK_DIR__|$(escape_sed "$ALIST_WORK_DIR")|g" \
    -e "s|__NODE_BIN__|$(escape_sed "$NODE_BIN")|g" \
    -e "s|__PROJECT_ROOT__|$(escape_sed "$PROJECT_ROOT")|g" \
    -e "s|__DATA_DIR__|$(escape_sed "$DATA_DIR")|g" \
    "$src" > "$dst"
  chmod 644 "$dst"
  plutil -lint "$dst" >/dev/null
}

render "$PROJECT_ROOT/scripts/launchd/$LABEL_ALIST.plist" "$ALIST_DST"
render "$PROJECT_ROOT/macos/launchd/$LABEL_BRIDGE.plist" "$BRIDGE_DST"

# Replace any old in-memory copy with the just-installed definitions.
# launchd removal is asynchronous on some macOS releases; bootstrapping the
# same label immediately can return EIO. Wait for the old label to disappear,
# then retry bootstrap deterministically.
restart_agent() {
  local label="$1" plist="$2"
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done

  local ok=0
  for _ in $(seq 1 10); do
    if launchctl bootstrap "$DOMAIN" "$plist" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 0.5
  done
  [[ "$ok" -eq 1 ]] || fail "launchctl could not load $label from $plist"
  launchctl kickstart -k "$DOMAIN/$label"
}

restart_agent "$LABEL_ALIST" "$ALIST_DST"
restart_agent "$LABEL_BRIDGE" "$BRIDGE_DST"

# Give both local services a short deterministic startup window.
for _ in $(seq 1 20); do
  if curl -fsS --max-time 1 http://127.0.0.1:5244/ >/dev/null 2>&1; then break; fi
  sleep 0.5
done
for _ in $(seq 1 20); do
  if nc -z 127.0.0.1 8081 >/dev/null 2>&1; then break; fi
  sleep 0.5
done

printf '\nPlinth services installed as persistent LaunchAgents.\n'
printf 'AList:  '
if curl -fsS --max-time 2 http://127.0.0.1:5244/ >/dev/null 2>&1; then
  printf 'OK (127.0.0.1:5244)\n'
else
  printf 'FAILED; see %s/logs/alist-launchd.err\n' "$DATA_DIR"
fi
printf 'Bridge: '
if nc -z 127.0.0.1 8081 >/dev/null 2>&1; then
  printf 'OK (127.0.0.1:8081)\n'
else
  printf 'FAILED; see %s/logs/fp-bridge.err\n' "$DATA_DIR"
fi
printf 'node:    %s\n' "$NODE_BIN"
printf 'state:   %s\n' "$DATA_DIR"
