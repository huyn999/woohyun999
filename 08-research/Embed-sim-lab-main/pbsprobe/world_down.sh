#!/usr/bin/env bash
# pbsprobe/world_down.sh — 상시 세계 정리 (멱등)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$DIR/results/world"
if [[ -f "$WD/state.env" ]]; then
	# shellcheck disable=SC1091
	source "$WD/state.env"
	pkill -9 -f "pbs_hub --port ${WORLD_PORT} " 2>/dev/null
	pkill -9 -f "hub_port ${WORLD_PORT}" 2>/dev/null          # 상주 서비스들
	[[ -n "${MEMD_PID:-}" ]] && kill -9 "$MEMD_PID" 2>/dev/null
	if [[ -n "${WORLD_CG:-}" && -d "${WORLD_CG:-/nonexistent}" ]]; then
		pkill -9 -f "stress-ng" 2>/dev/null
		sleep 0.3
		for p in $(cat "$WORLD_CG/run/cgroup.procs" 2>/dev/null) $(cat "$WORLD_CG/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
		sleep 0.2
		find "$WORLD_CG" -depth -type d -exec rmdir {} \; 2>/dev/null
	fi
	for i in $(seq 1 "${WORLD_SVCS:-3}"); do
		rm -f "/tmp/pbsprobe_db_p$(( WORLD_PORT + 10 + i )).bin"
	done
	rm -f "$WD/state.env"
	echo "[world] DOWN (로그는 $WD/ 에 보존)"
else
	echo "[world] 이미 내려가 있음"
fi
