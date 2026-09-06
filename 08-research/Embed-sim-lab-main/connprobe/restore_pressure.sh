#!/usr/bin/env bash
# criu_p2.sh — 복원 압박 실험 (수정판)
#
# 이전 판의 버그 3개를 고쳤다:
#   1) 이미지 하나를 여러 예산에 재사용 → 첫 복원이 wl.log를 키워서 이후 전부
#      files-reg.c:2175(bad size)로 실패. → 예산마다 새로 기동·새로 dump.
#   2) phase_gap 3000ms → 복원 후 ready 도달에 45초+ 소요, 2초만 기다려 pong_fail 오판.
#      → gap 300ms, ready 최대 60초 대기.
#   3) cgroup 디렉터리를 rm -rf로 지우려 함 → rmdir.
#
# 질문: 메모리가 모자라 복원이 안 될 때 CRIU는 정직하게 실패를 알리는가?
#       아니면 restore_rc=0을 주고 프로세스는 조용히 죽는가?
#
#   sudo ./criu_p2.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
CPROBE="$ROOT/testbed/runner/cprobe"
BIN="$ROOT/testbed/workloads/bin"
RESULTS="$ROOT/failprobe/results"; RUNS="$RESULTS/runs"
CG=/sys/fs/cgroup/criu_rp
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
WL=fp_w_qml_app
mkdir -p "$RUNS"
[[ -x "$CRIU" && -x "$BIN/$WL" ]] || { echo "criu 또는 $WL 없음" >&2; exit 1; }

CSV="$RESULTS/restore_pressure.csv"
echo "phase,image_rss_mb,budget_mb,dump_rc,restore_rc,alive_5s,verify,criu_said" > "$CSV"
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

wait_line() { local log="$1" re="$2" dl=$(( $(date +%s) + $3 )) pid="${4:-}"
	while (( $(date +%s) < dl )); do
		grep -qE "$re" "$log" 2>/dev/null && return 0
		[[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 1
		sleep 0.05
	done; return 1; }
first_err() { [[ -f "$1" ]] || { echo ""; return; }
	grep -m1 -E "Error \(" "$1" | tr ',' ';' | tr -d '"' | cut -c1-200; }
cg_reset() { rmdir "$CG" 2>/dev/null; mkdir -p "$CG" 2>/dev/null
	echo "$1" > "$CG/memory.max" 2>/dev/null; echo 0 > "$CG/memory.swap.max" 2>/dev/null; }

port=27100
for ph in f_large_heap_l01 f_large_heap; do
  for budget in 1024 512 400 340 300 260 200; do
	cell="$RUNS/rp__${ph}__b${budget}"; rm -rf "$cell"; mkdir -p "$cell/img"
	wlog="$cell/wl.log"

	# ── 1) 무제약 기동 + dump (예산마다 새로: 로그 오염 방지) ──
	( exec "$BIN/$WL" --port "$port" --bytes 8388608 --phase_gap_ms 300 ) > "$wlog" 2>&1 &
	WLPID=$!
	if ! wait_line "$wlog" "^PHASE ${ph}( |$)" 60 "$WLPID"; then
		echo "  [$ph/$budget] 기동 실패"; kill -9 "$WLPID" 2>/dev/null; continue; fi
	# phase 창 안에서 dump하려면 여기서 멈춰 있어야 한다 → SIGSTOP으로 확실히 고정
	kill -STOP "$WLPID" 2>/dev/null
	rss=$(( $(awk '/VmRSS/{print $2}' /proc/$WLPID/status 2>/dev/null || echo 0) / 1024 ))
	kill -CONT "$WLPID" 2>/dev/null
	"$CRIU" dump -t "$WLPID" -D "$cell/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	drc=$?
	pkill -9 -f "bin/${WL} --port ${port}" 2>/dev/null
	if [[ $drc -ne 0 ]]; then
		printf '%s,%s,%s,%s,na,na,na,"%s"\n' "$ph" "$rss" "$budget" "$drc" "$(first_err "$cell/img/dump.log")" >> "$CSV"
		echo "  [$ph/$budget] dump 실패($drc)"; continue; fi

	# ── 2) 예산이 걸린 cgroup 안에서 restore ──
	cg_reset $((budget * 1048576))
	( echo $BASHPID > "$CG/cgroup.procs" 2>/dev/null
	  exec "$CRIU" restore -d -D "$cell/img" -v4 -o restore.log --pidfile "$cell/pid" "${OPTS[@]}" ) >/dev/null 2>&1
	rrc=$?
	said="$(first_err "$cell/img/restore.log")"; [[ -z "$said" ]] && said="(에러 없음)"

	# ── 3) 핵심: rc=0이어도 살아 있는가? 그리고 정상 동작하는가? ──
	alive=na; verify=na
	if [[ $rrc -eq 0 && -f "$cell/pid" ]]; then
		rpid="$(cat "$cell/pid")"
		sleep 5
		if kill -0 "$rpid" 2>/dev/null; then
			alive=yes
			if wait_line "$wlog" "^PHASE ready" 60 "$rpid"; then
				verify=pong_fail
				for _ in $(seq 1 60); do
					"$CPROBE" 127.0.0.1 "$port" 200 >/dev/null 2>&1 && { verify=pong_ok; break; }
					sleep 0.1
				done
			else
				verify=$(kill -0 "$rpid" 2>/dev/null && echo resume_stalled || echo died_while_resuming)
			fi
		else
			alive=NO; verify=died_after_restore
		fi
		kill -9 "$rpid" 2>/dev/null
	fi
	printf '%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$ph" "$rss" "$budget" "$drc" "$rrc" "$alive" "$verify" "$said" >> "$CSV"
	printf "  [RSS %3dMB] 예산 %4dMB → restore_rc=%-2s alive=%-3s %-20s %s\n" \
		"$rss" "$budget" "$rrc" "$alive" "$verify" "$(echo "$said" | cut -c1-50)"
	pkill -9 -f "bin/${WL} --port ${port}" 2>/dev/null
	rmdir "$CG" 2>/dev/null
	port=$((port + 1))
  done
done
rmdir "$CG" 2>/dev/null
echo
echo "── 읽는 법 ──"
echo "  restore_rc≠0 + OOM 관련 에러 → CRIU가 정직하게 알림 (좋음)"
echo "  restore_rc≠0 + 엉뚱한 에러   → 실패는 알리되 원인을 오보 (주의)"
echo "  restore_rc=0 + alive=NO      → ★ 침묵형: 복원했다고 믿는데 죽어 있음 (최악)"
echo "  restore_rc=0 + pong_ok       → 정상"
echo "CSV → $CSV"
