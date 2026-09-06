#!/usr/bin/env bash
# stress/stop.sh — background stress-ng 인스턴스들 정리
#
# Usage:
#   sudo stress/stop.sh <run_dir>

set -uo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <run_dir>" >&2
	exit 2
fi

RUN_DIR="$1"
PIDS_FILE="$RUN_DIR/stress.pids"

[[ -f "$PIDS_FILE" ]] || {
	echo "[stress] nothing to stop"
	exit 0
}

mapfile -t PIDS < "$PIDS_FILE"

for p in "${PIDS[@]}"; do
	[[ -n "$p" ]] || continue
	kill -TERM "$p" 2>/dev/null || true
done

for _ in $(seq 1 30); do
	alive=0
	for p in "${PIDS[@]}"; do
		[[ -n "$p" ]] || continue
		kill -0 "$p" 2>/dev/null && { alive=1; break; }
	done
	(( alive )) || break
	sleep 0.1
done

killed=0
for p in "${PIDS[@]}"; do
	[[ -n "$p" ]] || continue
	if kill -0 "$p" 2>/dev/null; then
		kill -KILL "$p" 2>/dev/null || true
		killed=$((killed + 1))
	fi
done
(( killed > 0 )) && echo "[stress] WARN: force-killed $killed instance(s)" >&2

echo "[stress] stopped: ${#PIDS[@]} instance(s)"
