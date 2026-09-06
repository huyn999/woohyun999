#!/usr/bin/env bash
# pbsprobe/world_status.sh — 세계 공변량 스냅샷 한 줄 (스윕이 셀마다 CSV에 기록)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$DIR/results/world"
[[ -f "$WD/state.env" ]] || { echo "world=down"; exit 0; }
# shellcheck disable=SC1091
source "$WD/state.env"
up=$(( $(date +%s) - WORLD_T0 ))
regs=$(grep -c "HUB register" "$WD/hub.log" 2>/dev/null || echo 0)
logs=$(grep -oE "LOG rx n=[0-9]+" "$WD/hub.log" 2>/dev/null | tail -1 | grep -oE "[0-9]+" || echo 0)
alive=$(pgrep -cf "hub_port $WORLD_PORT" 2>/dev/null || echo 0)
mem="na"
[[ -n "${WORLD_CG:-}" && -r "$WORLD_CG/memory.current" ]] && mem=$(( $(cat "$WORLD_CG/memory.current") / 1048576 ))
memd=$(grep -c "MEMD kill" "$WD/memd.log" 2>/dev/null || echo 0)
echo "up_s=$up regs=$regs log_rx=$logs svcs=$alive mem_mib=$mem memd_kills=$memd"
