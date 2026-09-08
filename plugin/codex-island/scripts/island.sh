#!/bin/bash
set -euo pipefail
island_action="${1:-show}"
case "$island_action" in
  show|hide|chat|settings|status) ;;
  *) echo '用法: island.sh show|hide|chat|settings|status' >&2; exit 2 ;;
esac
island_app=""
for island_candidate in "$HOME/Applications/Codex Island.app" '/Applications/Codex Island.app'; do
  if [[ -x "$island_candidate/Contents/MacOS/CodexIsland" ]]; then island_app="$island_candidate"; break; fi
done
if [[ -z "$island_app" ]]; then
  echo '未找到 Codex Island.app。请先把原生应用放入“应用程序”目录。' >&2
  exit 1
fi
if [[ "$island_action" == status ]]; then
  exec "$island_app/Contents/MacOS/CodexIsland" --diagnose
fi
island_route="$island_action"
[[ "$island_action" == show ]] && island_route=expand
[[ "$island_action" == hide ]] && island_route=collapse
/usr/bin/open -a "$island_app" "codex-island://$island_route"
