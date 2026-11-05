#!/usr/bin/env bash
set -u

uid="$(id -u)"
domain="gui/$uid"

printf 'AList process:  '
if launchctl print "$domain/com.local.alist" >/dev/null 2>&1; then
  printf 'loaded'
else
  printf 'NOT LOADED'
fi
if curl -fsS --max-time 2 http://127.0.0.1:5244/ >/dev/null 2>&1; then
  printf ', healthy :5244\n'
else
  printf ', DOWN :5244\n'
fi

printf 'Bridge process: '
if launchctl print "$domain/com.local.cloud-drive-fp-bridge" >/dev/null 2>&1; then
  printf 'loaded'
else
  printf 'NOT LOADED'
fi
if nc -z 127.0.0.1 8081 >/dev/null 2>&1; then
  printf ', healthy :8081\n'
else
  printf ', DOWN :8081\n'
fi

printf 'Finder domains:\n'
found=0
for path in "$HOME/Library/CloudStorage/"Plinth-*; do
  [[ -e "$path" ]] || continue
  [[ "$(basename "$path")" == "Plinth-Internal" ]] && continue
  printf '%s\n' "$path"
  found=1
done
[[ "$found" -eq 1 ]] || printf '  none\n'
