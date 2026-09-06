#!/usr/bin/env bash
# connprobe/xmatrix.sh — 봉쇄 조건 행렬 (구 criu_x.sh xmatrix)
#
# "연결이 dump/restore 를 넘는가"를 리스너/커넥터 위상별로 가른다. gen_workloads_x.py 가
# fp_x_* 6종(backlog/ext_pend/ext_est × UNIX/TCP)을 testbed/workloads 아래에 만들고,
# 셀마다 xpeer(덤프 밖 상대)를 띄운 뒤 dump/restore/verify 를 돌려 CSV 로 남긴다.
#
# 자기 압축 해제형이던 원본과 달리, 소스(xpeer.c, gen_workloads_x.py)는 이제 이 패키지에
# 파일로 있다. build.sh 가 xpeer 를 미리 빌드한다.
#
#   sudo ./xmatrix.sh
#
# 환경변수: CRIU_BIN(다른 CRIU 경로)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[[ -d "$ROOT/testbed/workloads" && -d "$ROOT/failprobe" ]] || {
	echo "ERROR: repo 루트(Embed-sim-lab-main) 아래 connprobe/ 에서 실행하세요" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: sudo 필요" >&2; exit 1; }

CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
CPROBE="$ROOT/testbed/runner/cprobe"
XPEER="$HERE/bin/xpeer"
RESULTS="$HERE/results"; RUNS="$RESULTS/runs"; mkdir -p "$RUNS"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음" >&2; exit 1; }
[[ -x "$XPEER" ]] || { echo "[build] xpeer 미빌드 → build.sh"; "$HERE/build.sh" >/dev/null || exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)

wait_line() { local log="$1" re="$2" deadline=$(( $(date +%s) + $3 )) pid="${4:-}"
	while (( $(date +%s) < deadline )); do
		grep -qE "$re" "$log" 2>/dev/null && return 0
		[[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 1
		sleep 0.02
	done; return 1; }
first_err() { [[ -f "$1" ]] || { echo ""; return; }
	grep -m1 -E "Error \(" "$1" | tr ',' ';' | tr -d '"' | cut -c1-300; }
phases_of() {
	python3 - "$ROOT/testbed/workloads/$1/workload.yaml" <<-'PYEOF'
	import sys, yaml
	m = yaml.safe_load(open(sys.argv[1]))
	print(" ".join(p for p in m.get("phases", []) if p != "served_first"))
	PYEOF
}

echo "════ 봉쇄 조건 행렬 (구 criu_x.sh xmatrix) ════"
python3 "$HERE/gen_workloads_x.py" --workloads-dir "$ROOT/testbed/workloads" || exit 1
"$ROOT/testbed/workloads/build.sh" >/dev/null 2>&1 || { echo "ERROR: workloads/build.sh 실패"; exit 1; }

CSV="$RESULTS/compat_xmatrix.csv"
echo "workload,phase,mode,launch_ok,dump_rc,restore_rc,verify,dump_err,restore_err" > "$CSV"
port_ctr=0
for wl in fp_x_backlog_unix fp_x_backlog_tcp fp_x_ext_unix_pend fp_x_ext_tcp_pend \
          fp_x_ext_unix_est fp_x_ext_tcp_est; do
	[[ -x "$ROOT/testbed/workloads/bin/$wl" ]] || { echo "[skip] $wl 미빌드"; continue; }
	for ph in $(phases_of "$wl"); do
		port=$((26000 + port_ctr)); port_ctr=$((port_ctr + 1))
		cell="$RUNS/${wl}__${ph}__xmatrix"; rm -rf "$cell"; mkdir -p "$cell/img"
		wlog="$cell/wl.log" plog="$cell/xpeer.log" XP=""
		if [[ "$wl" != fp_x_backlog_* ]]; then
			popt=(); [[ "$wl" == *_pend ]] && popt=(--no-accept)
			( exec "$XPEER" --port "$port" "${popt[@]}" ) > "$plog" 2>&1 & XP=$!
			wait_line "$plog" "^XPEER ready" 5 "$XP" || { echo "[$wl@$ph] xpeer 실패"; kill -9 "$XP" 2>/dev/null; continue; }
		fi
		( exec "$ROOT/testbed/workloads/bin/$wl" --port "$port" --bytes 8388608 --phase_gap_ms 400 ) > "$wlog" 2>&1 &
		WLPID=$! launch_ok=1 dump_rc=na restore_rc=na verify=na derr="" rerr=""
		if ! wait_line "$wlog" "^PHASE ${ph}( |\$)" 20 "$WLPID"; then
			launch_ok=0
		else
			"$CRIU" dump -t "$WLPID" -D "$cell/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
			dump_rc=$?; derr="$(first_err "$cell/img/dump.log")"
			if [[ $dump_rc -eq 0 ]]; then
				sleep 0.2
				"$CRIU" restore -d -D "$cell/img" -v4 -o restore.log --pidfile "$cell/pid" "${OPTS[@]}" >/dev/null 2>&1
				restore_rc=$?; rerr="$(first_err "$cell/img/restore.log")"
				if [[ $restore_rc -eq 0 ]]; then
					case "$ph" in
					ready|steady)
						verify=pong_fail
						for _ in $(seq 1 100); do
							"$CPROBE" 127.0.0.1 "$port" 200 >/dev/null 2>&1 && { verify=pong_ok; break; }
							sleep 0.05
						done ;;
					*)
						if wait_line "$wlog" "^PHASE ready" 15; then verify=resumed_to_ready
						else verify=resume_stalled; fi ;;
					esac
				fi
			fi
		fi
		printf '%s,%s,xmatrix,%s,%s,%s,%s,"%s","%s"\n' \
			"$wl" "$ph" "$launch_ok" "$dump_rc" "$restore_rc" "$verify" "$derr" "$rerr" >> "$CSV"
		echo "  [$wl@$ph] dump=$dump_rc restore=$restore_rc verify=$verify"
		pkill -9 -f "bin/${wl} --port ${port}" 2>/dev/null
		[[ -n "$XP" ]] && kill -9 "$XP" 2>/dev/null
		[[ -f "$cell/pid" ]] && kill -9 "$(cat "$cell/pid")" 2>/dev/null
		sleep 0.05
	done
done
echo; echo "── 워크로드별 통과/전체 ──"
awk -F, 'NR>1{n[$1]++; if($5=="0"&&$6=="0"&&$7 !~ /fail|stall/) p[$1]++} END{
	for (w in n) printf "  %-22s %d/%d%s\n", w, p[w]+0, n[w], (p[w]==n[w] ? "  ← 전 지점 통과" : "  ← 실패 있음")}' "$CSV"
echo "  CSV → $CSV"
