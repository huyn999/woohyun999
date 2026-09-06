#!/usr/bin/env bash
# criu_x.sh — 자기 압축 해제형 실험 꾸러미 (파일 하나만 옮기면 됨)
#
# 이 스크립트 하나가 필요한 소스를 스스로 풀어놓고, 빌드하고, 실험을 돌린다.
# repo 루트(Embed-sim-lab-main)에서 실행할 것.
#
#   sudo ./criu_x.sh xmatrix     — 봉쇄 조건 행렬 (50셀, ~3분)
#                                   피어가 같은 프로세스냐 / 다른 프로세스냐 / 덤프 밖이냐
#   sudo ./criu_x.sh pressure    — 복원 압박 실험 (12셀, ~2분)
#                                   넉넉한 데서 dump → 빡빡한 cgroup에서 restore
#                                   질문: CRIU는 정직하게 에러를 내는가, 조용히 죽는가?
#   sudo ./criu_x.sh all         — 둘 다
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$ROOT/testbed/workloads" && -d "$ROOT/failprobe" ]] || {
	echo "ERROR: repo 루트(Embed-sim-lab-main)에서 실행하세요" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: sudo 필요" >&2; exit 1; }

WP="$ROOT/webos_probe"; BIN="$ROOT/testbed/workloads/bin"
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
CPROBE="$ROOT/testbed/runner/cprobe"
RESULTS="$ROOT/failprobe/results"; RUNS="$RESULTS/runs"
mkdir -p "$WP" "$RUNS"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음" >&2; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)

# ══════════════════════════════════════════════════════════════════════════════
# 1) 소스 풀어놓기
# ══════════════════════════════════════════════════════════════════════════════
cat > "$WP/xpeer.c" <<'XPEER_SRC_EOF'
/* webos_probe/xpeer.c — 외부 피어 (덤프 집합 밖에 사는 프로세스)
 * 스윕이 셀마다 워크로드보다 먼저 띄우고, criu dump -t <워크로드> 의 트리에 들어가지 않는다.
 *   --port N      UNIX 추상 "criuprobe_xpeer_p<N>", TCP 포트 N+3000
 *   --no-accept   listen만 하고 accept 하지 않음 → 연결이 백로그에 걸린 채 방치 (= 등록 창)
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
static void die(const char *m) { perror(m); exit(1); }
int main(int argc, char **argv)
{
	int port = 18080, no_accept = 0;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--no-accept")) no_accept = 1;
	}
	int ul = socket(AF_UNIX, SOCK_STREAM, 0);
	if (ul < 0) die("xpeer unix socket");
	struct sockaddr_un ua;
	memset(&ua, 0, sizeof(ua));
	ua.sun_family = AF_UNIX;
	snprintf(ua.sun_path + 1, sizeof(ua.sun_path) - 2, "criuprobe_xpeer_p%d", port);
	socklen_t ual = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ua.sun_path + 1));
	if (bind(ul, (struct sockaddr *)&ua, ual) < 0) die("xpeer unix bind");
	if (listen(ul, 16) < 0) die("xpeer unix listen");
	int tl = socket(AF_INET, SOCK_STREAM, 0);
	if (tl < 0) die("xpeer tcp socket");
	int one = 1;
	setsockopt(tl, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in ta;
	memset(&ta, 0, sizeof(ta));
	ta.sin_family = AF_INET;
	ta.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	ta.sin_port = htons((uint16_t)(port + 3000));
	if (bind(tl, (struct sockaddr *)&ta, sizeof(ta)) < 0) die("xpeer tcp bind");
	if (listen(tl, 16) < 0) die("xpeer tcp listen");
	printf("XPEER ready port=%d tcp=%d accept=%d\n", port, port + 3000, !no_accept);
	fflush(stdout);
	if (no_accept)
		for (;;) { struct timespec ts = { 1, 0 }; nanosleep(&ts, NULL); }
	for (;;) {
		fd_set rd;
		FD_ZERO(&rd); FD_SET(ul, &rd); FD_SET(tl, &rd);
		struct timeval tv = { 0, 50000 };
		int mx = (ul > tl ? ul : tl) + 1;
		if (select(mx, &rd, NULL, NULL, &tv) > 0) {
			if (FD_ISSET(ul, &rd)) accept(ul, NULL, NULL);
			if (FD_ISSET(tl, &rd)) accept(tl, NULL, NULL);
		}
	}
	return 0;
}
XPEER_SRC_EOF

cat > "$WP/gen_workloads_x.py" <<'GENX_SRC_EOF'
#!/usr/bin/env python3
"""webos_probe/gen_workloads_x.py — 봉쇄 조건 행렬 (fp_x_*, 6종)

기존 registration/tcp_established는 리스너와 커넥터가 같은 프로세스 안에 있었다
(self-loopback). 이 6종이 세 교란 요인을 분리한다 — 두 전송(UNIX/TCP) × 세 봉쇄 조건:

  backlog_*   리스너=워크로드, 커넥터=자식 프로세스. 둘 다 덤프 안, 그러나 별개 프로세스.
              accept 안 함 → 연결이 백로그에 걸림.  (self-loopback이 원인이었나?)
  ext_*_pend  커넥터=워크로드, 리스너=외부 xpeer(덤프 밖), accept 안 함.
              워크로드는 클라이언트 소켓만 쥠.  (= 진짜 luna 등록 창 / 진짜 HLS 수립 창)
  ext_*_est   위와 같되 외부 피어가 accept 완료.  (대조군)
"""
import argparse, os, sys
_here = os.path.dirname(os.path.abspath(__file__))
for cand in (_here, os.path.join(_here, "..", "failprobe")):
    if os.path.isfile(os.path.join(cand, "gen_workloads.py")):
        sys.path.insert(0, cand); break
else:
    sys.exit("ERROR: gen_workloads.py를 찾을 수 없음")
import gen_workloads as g
import gen_workloads_v2  # noqa: F401

_UADDR = r"""
      struct sockaddr_un xa; memset(&xa, 0, sizeof(xa)); xa.sun_family = AF_UNIX;
      snprintf(xa.sun_path + 1, sizeof(xa.sun_path) - 2, "criuprobe_xpeer_p%d", g_port);
      socklen_t xal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(xa.sun_path + 1));
"""

g.feat("backlog_unix", "UNIX 리스너 + 자식이 connect + 미accept (별개 프로세스, 둘 다 덤프 안)",
       "HIGH — self-loopback이 아닌 조건에서 UNIX 백로그가 살아남는가", 1, """
{ int bl = socket(AF_UNIX, SOCK_STREAM, 0); if (bl < 0) die("bl sock");
  struct sockaddr_un ba; memset(&ba, 0, sizeof(ba)); ba.sun_family = AF_UNIX;
  snprintf(ba.sun_path + 1, sizeof(ba.sun_path) - 2, "criuprobe_bl_p%d", g_port);
  socklen_t bal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ba.sun_path + 1));
  if (bind(bl, (struct sockaddr *)&ba, bal) < 0) die("bl bind");
  if (listen(bl, 8) < 0) die("bl listen");
  int sy[2]; if (pipe(sy) < 0) die("bl pipe");
  pid_t bc = fork(); if (bc < 0) die("bl fork");
  if (bc == 0) {
      close(sy[0]);
      int c = socket(AF_UNIX, SOCK_STREAM, 0); if (c < 0) _exit(1);
      if (connect(c, (struct sockaddr *)&ba, bal) < 0) _exit(1);
      if (write(sy[1], "x", 1) != 1) _exit(1);
      for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); }
  }
  close(sy[1]); char sb; if (read(sy[0], &sb, 1) != 1) die("bl sync");
  KEEPFD(bl); KEEPFD(sy[0]); }
""", atomic=True)

g.feat("backlog_tcp", "TCP 리스너 + 자식이 connect + 미accept (별개 프로세스, 둘 다 덤프 안)",
       "HIGH — self-loopback이 아니어도 sk-inet.c:185가 나는가", 1, """
{ int bp = 0; int bl = probe_listen(0, &bp);
  int sy[2]; if (pipe(sy) < 0) die("bt pipe");
  pid_t bc = fork(); if (bc < 0) die("bt fork");
  if (bc == 0) {
      close(sy[0]);
      int c = socket(AF_INET, SOCK_STREAM, 0); if (c < 0) _exit(1);
      struct sockaddr_in a; memset(&a, 0, sizeof(a)); a.sin_family = AF_INET;
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons((uint16_t)bp);
      if (connect(c, (struct sockaddr *)&a, sizeof(a)) < 0) _exit(1);
      if (write(sy[1], "x", 1) != 1) _exit(1);
      for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); }
  }
  close(sy[1]); char sb; if (read(sy[0], &sb, 1) != 1) die("bt sync");
  KEEPFD(bl); KEEPFD(sy[0]); }
""", atomic=True)

g.feat("ext_unix_pend", "외부 허브(덤프 밖)에 connect, 상대는 아직 accept 안 함",
       "HIGH — 실제 luna 등록 창", 1, """
{ int xc = socket(AF_UNIX, SOCK_STREAM, 0); if (xc < 0) die("xup sock");
""" + _UADDR + """
      if (connect(xc, (struct sockaddr *)&xa, xal) < 0) die("xup connect");
      KEEPFD(xc); }
""")

g.feat("ext_tcp_pend", "외부 서버(덤프 밖)에 connect, 상대는 아직 accept 안 함",
       "HIGH — 실제 HLS 수립 창", 1, """
{ int xc = socket(AF_INET, SOCK_STREAM, 0); if (xc < 0) die("xtp sock");
  struct sockaddr_in xt; memset(&xt, 0, sizeof(xt)); xt.sin_family = AF_INET;
  xt.sin_addr.s_addr = htonl(INADDR_LOOPBACK); xt.sin_port = htons((uint16_t)(g_port + 3000));
  if (connect(xc, (struct sockaddr *)&xt, sizeof(xt)) < 0) die("xtp connect");
  KEEPFD(xc); }
""")

g.feat("ext_unix_est", "외부 허브(덤프 밖)와 성립된 UNIX 연결 + 전송 완료",
       "medium — 외부 소켓 dump/restore", 1, """
{ int xc = socket(AF_UNIX, SOCK_STREAM, 0); if (xc < 0) die("xue sock");
""" + _UADDR + """
      if (connect(xc, (struct sockaddr *)&xa, xal) < 0) die("xue connect");
      if (write(xc, "{\\"register\\":1}", 14) != 14) die("xue write");
      KEEPFD(xc); }
""")

g.feat("ext_tcp_est", "외부 서버(덤프 밖)와 성립된 TCP 연결 + 전송 완료",
       "medium — 외부 TCP dump/restore", 1, """
{ int xc = socket(AF_INET, SOCK_STREAM, 0); if (xc < 0) die("xte sock");
  struct sockaddr_in xt; memset(&xt, 0, sizeof(xt)); xt.sin_family = AF_INET;
  xt.sin_addr.s_addr = htonl(INADDR_LOOPBACK); xt.sin_port = htons((uint16_t)(g_port + 3000));
  if (connect(xc, (struct sockaddr *)&xt, sizeof(xt)) < 0) die("xte connect");
  if (write(xc, "hello", 5) != 5) die("xte write");
  KEEPFD(xc); }
""")

W = [
 ("fp_x_backlog_unix",  ["backlog_unix"],  "봉쇄A: 리스너=나, 커넥터=자식(덤프 안), 미accept"),
 ("fp_x_backlog_tcp",   ["backlog_tcp"],   "봉쇄A: 동일 조건의 TCP — self-loopback 교란 제거"),
 ("fp_x_ext_unix_pend", ["ext_unix_pend"], "봉쇄B: 리스너=외부 허브(덤프 밖), 미accept"),
 ("fp_x_ext_tcp_pend",  ["ext_tcp_pend"],  "봉쇄B: 리스너=외부 서버(덤프 밖), 미accept"),
 ("fp_x_ext_unix_est",  ["ext_unix_est"],  "봉쇄C: 외부 허브와 성립 완료 — 대조군"),
 ("fp_x_ext_tcp_est",   ["ext_tcp_est"],   "봉쇄C: 외부 서버와 성립 완료 — 대조군"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads-dir", required=True)
    a = ap.parse_args()
    total = 0
    for name, feats, desc in W:
        ph = g.gen_one(name, feats, f"[X] 봉쇄 행렬: {desc}", a.workloads_dir, granularity="line")
        total += len(ph) - 1
        print(f"  {name}: {len(ph)} phases")
    print(f"generated {len(W)} workloads (셀 {total}개)")

if __name__ == "__main__":
    main()
GENX_SRC_EOF

echo "[setup] 소스 배치 완료: $WP/xpeer.c, $WP/gen_workloads_x.py"

# ══════════════════════════════════════════════════════════════════════════════
# 2) 공용 함수
# ══════════════════════════════════════════════════════════════════════════════
wait_line() { # $1=log $2=regex $3=timeout_s $4=pid(옵션)
	local log="$1" re="$2" deadline=$(( $(date +%s) + $3 )) pid="${4:-}"
	while (( $(date +%s) < deadline )); do
		grep -qE "$re" "$log" 2>/dev/null && return 0
		[[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 1
		sleep 0.02
	done
	return 1
}
first_err() {
	[[ -f "$1" ]] || { echo ""; return; }
	grep -m1 -E "Error \(" "$1" | tr ',' ';' | tr -d '"' | cut -c1-300
}
phases_of() {
	python3 - "$ROOT/testbed/workloads/$1/workload.yaml" <<-'PYEOF'
	import sys, yaml
	m = yaml.safe_load(open(sys.argv[1]))
	print(" ".join(p for p in m.get("phases", []) if p != "served_first"))
	PYEOF
}

# ══════════════════════════════════════════════════════════════════════════════
# 3) 실험 A — 봉쇄 조건 행렬
# ══════════════════════════════════════════════════════════════════════════════
run_xmatrix() {
	echo; echo "════ 실험 A: 봉쇄 조건 행렬 ════"
	python3 "$WP/gen_workloads_x.py" --workloads-dir "$ROOT/testbed/workloads" || return 1
	gcc -O2 -Wall -o "$BIN/xpeer" "$WP/xpeer.c" || return 1
	"$ROOT/testbed/workloads/build.sh" >/dev/null 2>&1 || \
		{ echo "ERROR: build.sh 실패 — 직접 돌려서 확인하세요"; return 1; }

	local CSV="$RESULTS/compat_xmatrix.csv"
	echo "workload,phase,mode,launch_ok,dump_rc,restore_rc,verify,dump_err,restore_err" > "$CSV"
	local port_ctr=0
	for wl in fp_x_backlog_unix fp_x_backlog_tcp fp_x_ext_unix_pend fp_x_ext_tcp_pend \
	          fp_x_ext_unix_est fp_x_ext_tcp_est; do
		[[ -x "$BIN/$wl" ]] || { echo "[skip] $wl 미빌드"; continue; }
		for ph in $(phases_of "$wl"); do
			local port=$((26000 + port_ctr)); port_ctr=$((port_ctr + 1))
			local cell="$RUNS/${wl}__${ph}__xmatrix"; rm -rf "$cell"; mkdir -p "$cell/img"
			local wlog="$cell/wl.log" plog="$cell/xpeer.log" XP=""
			if [[ "$wl" != fp_x_backlog_* ]]; then
				local popt=(); [[ "$wl" == *_pend ]] && popt=(--no-accept)
				( exec "$BIN/xpeer" --port "$port" "${popt[@]}" ) > "$plog" 2>&1 &
				XP=$!
				wait_line "$plog" "^XPEER ready" 5 "$XP" || { echo "[$wl@$ph] xpeer 실패"; kill -9 "$XP" 2>/dev/null; continue; }
			fi
			( exec "$BIN/$wl" --port "$port" --bytes 8388608 --phase_gap_ms 400 ) > "$wlog" 2>&1 &
			local WLPID=$! launch_ok=1 dump_rc=na restore_rc=na verify=na derr="" rerr=""
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
	echo; echo "── 봉쇄 행렬 판정 (창 지점만) ──"
	awk -F, 'NR>1 && ($2 ~ /_pend$|_unix$|_tcp$/ || $2 ~ /l0[0-9]$/) && ($5!="0"||$6!="0"||$7 ~ /fail|stall/) \
		{printf "  ✗ %-20s %-24s dump=%s restore=%s %s\n", $1, $2, $5, $6, $8 $9}' "$CSV"
	awk -F, 'NR>1{n[$1]++; if($5=="0"&&$6=="0"&&$7 !~ /fail|stall/) p[$1]++} END{
		printf "\n  %-22s %s\n", "워크로드", "통과/전체";
		for (w in n) printf "  %-22s %d/%d%s\n", w, p[w]+0, n[w], (p[w]==n[w] ? "  ← 전 지점 통과" : "  ← 실패 있음")}' "$CSV"
	echo "  CSV → $CSV"
}

# ══════════════════════════════════════════════════════════════════════════════
# 4) 실험 B — 복원 압박: 넉넉한 데서 dump → 빡빡한 cgroup에서 restore
# ══════════════════════════════════════════════════════════════════════════════
#   질문: 메모리가 모자라 복원이 안 될 때 CRIU는 정직하게 에러를 내는가,
#         아니면 restore_rc=0을 주고 프로세스는 조용히 OOM으로 죽는가?
#   축1 = 이미지가 짊어진 RSS (phase를 다이얼로 사용)
#           f_large_heap_l01 → malloc만, RSS ≈ 8MB
#           f_large_heap     → 300MB 상주
#   축2 = 복원 cgroup의 memory.max (넉넉 → 빡빡)
run_pressure() {
	echo; echo "════ 실험 B: 복원 압박 (dump는 무제약, restore만 cgroup 안) ════"
	local WL=fp_w_qml_app
	[[ -x "$BIN/$WL" ]] || { echo "ERROR: $BIN/$WL 없음 — webOS 워크로드 먼저 빌드"; return 1; }
	local CG=/sys/fs/cgroup/criu_restore_pressure
	local CSV="$RESULTS/restore_pressure.csv"
	echo "phase,image_rss_mb,restore_budget_mb,restore_rc,alive_after_5s,verify,criu_said" > "$CSV"
	echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

	local port=27000
	for ph in f_large_heap_l01 f_large_heap; do
		# ── 1단계: 무제약 환경에서 dump (넉넉하므로 반드시 성공) ──
		local cell="$RUNS/pressure__${ph}"; rm -rf "$cell"; mkdir -p "$cell/img"
		( exec "$BIN/$WL" --port "$port" --bytes 8388608 --phase_gap_ms 3000 ) > "$cell/wl.log" 2>&1 &
		local WLPID=$!
		if ! wait_line "$cell/wl.log" "^PHASE ${ph}( |\$)" 30 "$WLPID"; then
			echo "  [$ph] 기동 실패 — 건너뜀"; kill -9 "$WLPID" 2>/dev/null; continue
		fi
		local rss_mb=$(( $(awk '/VmRSS/{print $2}' /proc/$WLPID/status 2>/dev/null || echo 0) / 1024 ))
		"$CRIU" dump -t "$WLPID" -D "$cell/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
		local drc=$?
		pkill -9 -f "bin/${WL} --port ${port}" 2>/dev/null
		if [[ $drc -ne 0 ]]; then echo "  [$ph] dump 실패($drc) — 건너뜀"; continue; fi
		echo "  [$ph] dump OK — 이미지가 짊어진 RSS = ${rss_mb}MB"

		# ── 2단계: 예산을 줄여 가며 restore. 이미지는 매번 새 복사본 ──
		for budget in 1024 512 384 320 280 200; do
			local img="$cell/img_b${budget}"; rm -rf "$img"; cp -r "$cell/img" "$img"
			rm -rf "$CG"; mkdir -p "$CG" 2>/dev/null
			echo $((budget * 1048576)) > "$CG/memory.max" 2>/dev/null
			echo 0 > "$CG/memory.swap.max" 2>/dev/null

			# criu 자신을 cgroup 안에 넣고 restore → 복원된 프로세스도 그 안에서 태어난다
			( echo $BASHPID > "$CG/cgroup.procs" 2>/dev/null
			  exec "$CRIU" restore -d -D "$img" -v4 -o restore.log \
			       --pidfile "$img/pid" "${OPTS[@]}" ) >/dev/null 2>&1
			local rrc=$?
			local said="$(first_err "$img/restore.log")"
			[[ -z "$said" ]] && said="(에러 없음)"

			# ── 핵심 관측: restore_rc가 0이어도 프로세스가 살아 있는가? ──
			local alive=na verify=na
			if [[ $rrc -eq 0 && -f "$img/pid" ]]; then
				local rpid; rpid="$(cat "$img/pid")"
				sleep 5
				if kill -0 "$rpid" 2>/dev/null; then
					alive=yes
					verify=pong_fail
					for _ in $(seq 1 40); do
						"$CPROBE" 127.0.0.1 "$port" 200 >/dev/null 2>&1 && { verify=pong_ok; break; }
						sleep 0.05
					done
				else
					alive=NO
					verify=died_after_restore
				fi
				kill -9 "$rpid" 2>/dev/null
			fi
			printf '%s,%s,%s,%s,%s,%s,"%s"\n' "$ph" "$rss_mb" "$budget" "$rrc" "$alive" "$verify" "$said" >> "$CSV"
			printf "    예산 %4dMB → restore_rc=%-2s alive=%-3s %-20s %s\n" \
				"$budget" "$rrc" "$alive" "$verify" "$(echo "$said" | cut -c1-45)"
			pkill -9 -f "bin/${WL} --port ${port}" 2>/dev/null
			rm -rf "$img"
		done
		rm -rf "$CG" 2>/dev/null
		port=$((port + 1))
	done
	echo
	echo "── 읽는 법 ──"
	echo "  restore_rc≠0            → CRIU가 정직하게 실패를 알림 (좋음: 운영자가 안다)"
	echo "  restore_rc=0 & alive=NO → 침묵형 실패 (나쁨: 복원했다고 믿는데 죽어 있음) ★"
	echo "  restore_rc=0 & pong_ok  → 정상 복원"
	echo "  CSV → $CSV"
}

case "${1:-all}" in
	xmatrix)  run_xmatrix ;;
	pressure) run_pressure ;;
	all)      run_xmatrix; run_pressure ;;
	*) echo "usage: sudo $0 [xmatrix|pressure|all]"; exit 1 ;;
esac
echo; echo "[done]"
