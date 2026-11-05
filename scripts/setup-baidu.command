#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/setup-provider.py baidu
printf '\n百度网盘配置完成。Plinth 会自动启动，并自动挂载到访达。\n'
printf '按回车关闭此窗口… '
read -r _
