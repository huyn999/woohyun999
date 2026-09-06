#!/usr/bin/env bash
# webosprobe/probe_sweep.sh — TCP 연결-생존 실험 통합 러너
#
# 흩어져 있던 criu_x3/x4/x5/x7/x8 다섯 스크립트를 하나로 합쳤다. 모두 같은 통합
# 워크로드(connprobe --mode ...)를 dump/restore 하고, 상대 서버는 늘 별도 프로세스
# (덤프 밖)다. 서브커맨드로 실험을 고른다:
#
#   sudo ./probe_sweep.sh syn_sent    # (구 x3) SYN_SENT 소켓을 dump 할 수 있나
#   sudo ./probe_sweep.sh syn_alive   # (구 x4) 복원+방화벽해제 후 SYN 재전송으로 연결 성사되나
#   sudo ./probe_sweep.sh freeze      # (구 x5) 정지 시간 0/15/45/90s × idle/streaming → CSV
#   sudo ./probe_sweep.sh stream      # (구 x7) 스트리밍 리더, iptables 유/무 비교
#   sudo ./probe_sweep.sh roundtrip   # (구 x8) 스트리밍 + PING→PONG 왕복 검증, iptables 유/무
#   sudo ./probe_sweep.sh all         # 다섯 개 순서대로
#
# 환경변수: FREEZE(정지 초, stream/roundtrip 기본 45), CRIU_BIN(다른 CRIU 경로)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }

CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음 (testbed/criu 빌드 먼저)" >&2; exit 1; }
WP="$HERE/bin/connprobe"
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$HERE/results"; mkdir -p "$OUT/runs"
FREEZE="${FREEZE:-45}"

# connprobe 가 없으면 자동 빌드
[[ -x "$WP" ]] || { echo "[build] connprobe 미빌드 → build.sh"; "$HERE/build.sh" >/dev/null || exit 1; }

# ── 공용 헬퍼 ────────────────────────────────────────────────────────────────
wait_line() { # $1=log $2=regex $3=timeout_s $4=pid(옵션)
	local log="$1" re="$2" deadline=$(( $(date +%s) + $3 )) pid="${4:-}"
	while (( $(date +%s) < deadline )); do
		grep -qE "$re" "$log" 2>/dev/null && return 0
		[[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 1
		sleep 0.05
	done
	return 1
}
tcp_state() { # $1=remote_port → /proc/net/tcp 에서 상태 문자열
	python3 - "$1" <<'PY'
import sys
want = int(sys.argv[1])
names = {'01':'ESTABLISHED','02':'SYN_SENT','06':'TIME_WAIT','07':'CLOSE','0A':'LISTEN'}
for ln in open('/proc/net/tcp').readlines()[1:]:
    f = ln.split(); rp = int(f[2].split(':')[1], 16)
    if rp == want:
        print("   remote_port=%d state=%s inode=%s" % (rp, names.get(f[3], f[3]), f[9]))
PY
}

# ══════════════════════════════════════════════════════════════════════════════
# syn_sent (구 criu_x3) — 논블로킹 connect 로 SYN_SENT 를 붙잡아 두고 dump 가능한가
# ══════════════════════════════════════════════════════════════════════════════
run_syn_sent() {
	echo "════ syn_sent: SYN_SENT 소켓을 dump 할 수 있나 (구 x3) ════"
	local PORT=29999 CELL="$OUT/runs/syn_sent"; rm -rf "$CELL"; mkdir -p "$CELL/img"

	echo "[1/4] SYN 을 DROP (응답이 영원히 안 오게)"
	iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP 2>/dev/null \
		|| { echo "ERROR: iptables 실패 (WSL 등에서 미지원)"; return 1; }
	local restore_fw="iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP 2>/dev/null"
	trap "$restore_fw" RETURN

	echo "[2/4] 논블로킹 connect → SYN_SENT 고정"
	"$WP" --mode syn_sent --port $PORT > "$CELL/wl.log" 2>&1 &
	local WLPID=$!
	wait_line "$CELL/wl.log" "^PHASE syn_sent" 5 "$WLPID" || { echo "  기동 실패"; kill -9 "$WLPID" 2>/dev/null; return 1; }
	sed 's/^/   /' "$CELL/wl.log"

	echo "[3/4] 커널 상태 확인 (02 = SYN_SENT)"
	tcp_state $PORT

	echo "[4/4] 이 상태에서 dump 시도"
	"$CRIU" dump -t "$WLPID" -D "$CELL/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	local DRC=$?
	echo "   dump_rc=$DRC"
	grep -m3 -E "Error|Warn.*(sock|tcp|inet)" "$CELL/img/dump.log" 2>/dev/null | sed 's/^/   /'
	kill -9 "$WLPID" 2>/dev/null

	echo; echo "── 판정 ──"
	if [[ $DRC -ne 0 ]]; then
		echo "  ❌ SYN_SENT 는 dump 불가 → \"클라이언트는 안전\" 주장에 예외가 있다."
	else
		echo "  ✅ SYN_SENT 도 dump 통과 → 클라이언트 측엔 위험한 창이 없다(생존은 syn_alive 로 확인)."
	fi
	echo "  로그: $CELL/img/dump.log"
	eval "$restore_fw"; trap - RETURN
}

# ══════════════════════════════════════════════════════════════════════════════
# syn_alive (구 criu_x4) — SYN_SENT 소켓이 복원 후 정말 살아 연결이 성사되는가
# ══════════════════════════════════════════════════════════════════════════════
run_syn_alive() {
	echo "════ syn_alive: 복원 후 SYN 재전송으로 연결이 성사되나 (구 x4) ════"
	local PORT=29998 CELL="$OUT/runs/syn_alive"; rm -rf "$CELL"; mkdir -p "$CELL/img"
	local RESUME=/tmp/connprobe_syn_alive; rm -f "$RESUME"

	# 진짜 리스너(연결이 성사될 수 있는 상대) — 덤프 밖
	PORT=$PORT python3 - <<'PY' > "$CELL/lis.log" 2>&1 &
import socket, os
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(os.environ["PORT"]))); s.listen(8)
print("LISTENER ready", flush=True)
while True:
    c, _ = s.accept(); print("ACCEPTED", flush=True)
PY
	local LIS=$!; sleep 1

	echo "[1] SYN DROP — 핸드셰이크를 멈춘다"
	iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP
	cleanup(){ iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP 2>/dev/null
	           kill -9 "$LIS" 2>/dev/null; pkill -9 -f "connprobe --mode syn_sent_epoll" 2>/dev/null; }
	trap cleanup RETURN

	echo "[2] 논블로킹 connect + epoll → SYN_SENT 고정"
	"$WP" --mode syn_sent_epoll --port $PORT > "$CELL/wl.log" 2>&1 &
	local WL=$!; sleep 1.5
	tcp_state $PORT

	echo "[3] dump"
	"$CRIU" dump -t "$WL" -D "$CELL/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	echo "    dump_rc=$?"
	grep -iE "warn.*(sock|inet|tcp)|Error" "$CELL/img/dump.log" 2>/dev/null | head -3 | sed 's/^/    /'

	echo "[4] restore"
	"$CRIU" restore -d -D "$CELL/img" -v4 -o restore.log --pidfile "$CELL/pid" "${OPTS[@]}" >/dev/null 2>&1
	echo "    restore_rc=$?"; sleep 1
	echo "    복원된 소켓 상태:"; tcp_state $PORT | sed 's/^ */      /'

	echo "[5] 방화벽 해제 — 살아 있다면 SYN 재전송이 통과해 연결이 성사된다 (백오프 1s,2s,4s…)"
	iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP
	for _ in $(seq 1 24); do grep -qE "^(CONNECTED|FAILED)" "$CELL/wl.log" && break; sleep 0.5; done

	echo; echo "── 워크로드 출력 ──"; sed 's/^/    /' "$CELL/wl.log"
	echo "── 판정 ──"
	if grep -q "^CONNECTED" "$CELL/wl.log"; then
		echo "  ✅ 소켓 생존 — 복원 후 SYN 재전송이 통과, 연결 성사. SYN_SENT 는 진짜 안전."
	elif grep -q "^FAILED" "$CELL/wl.log"; then
		echo "  ⚠️  소켓이 에러로 깨어남 — 앱은 최소한 실패를 '알 수'는 있다(재시도 가능)."
	else
		echo "  ❌ 침묵형 실패 — rc=0/rc=0 인데 연결은 증발. 앱은 영원히 epoll 에서 대기."
	fi
	cleanup; trap - RETURN
}

# ══════════════════════════════════════════════════════════════════════════════
# freeze (구 criu_x5) — 정지 시간 × (idle/streaming) 매트릭스 → CSV
# ══════════════════════════════════════════════════════════════════════════════
_freeze_case() { # $1=freeze_s $2=server_sends(0/1) $3=port
	local FR=$1 SENDS=$2 PORT=$3 CSV="$4"
	local RESUME=/tmp/connprobe_freeze; rm -f "$RESUME"
	local CELL="$OUT/runs/freeze_${FR}_${SENDS}"; rm -rf "$CELL"; mkdir -p "$CELL/img"

	SENDS=$SENDS PORT=$PORT python3 - <<'PY' > "$CELL/srv.log" 2>&1 &
import socket, os, time
port=int(os.environ["PORT"]); sends=os.environ["SENDS"]=="1"
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",port)); s.listen(4); print("SRV ready",flush=True)
c,_=s.accept(); c.recv(64); print("SRV accepted",flush=True)
try:
    while True:
        if sends: c.sendall(b"x"*1400)   # 얼어 있는 클라에게 계속 보냄 → 재전송 폭풍 → RST
        d=c.recv(64)
        if d and b"ping" in d: c.sendall(b"pong\n"); print("SRV pong",flush=True)
        if not d: print("SRV peer closed",flush=True); break
        time.sleep(0.2)
except Exception as e:
    print("SRV err", e, flush=True)
PY
	local SRV=$!; sleep 1
	"$WP" --mode idle_client --port "$PORT" --resume-file "$RESUME" > "$CELL/wl.log" 2>&1 &
	local CL=$!
	wait_line "$CELL/wl.log" "^READY" 6 "$CL" || { echo "  [정지 ${FR}s] 기동 실패"; kill -9 "$SRV" "$CL" 2>/dev/null; return; }

	"$CRIU" dump -t "$CL" -D "$CELL/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	local DRC=$?
	if [[ $DRC -ne 0 ]]; then
		printf '%s,%s,%s,na,dump_fail,"%s"\n' "$FR" "$SENDS" "$DRC" \
			"$(grep -m1 'Error (' "$CELL/img/dump.log" | cut -c1-90)" >> "$CSV"
		echo "  [정지 ${FR}s, 서버송신=$SENDS] dump 실패($DRC)"; kill -9 "$SRV" 2>/dev/null; return
	fi

	echo "     ... ${FR}초 동안 얼어 있는다 (바깥 세계는 계속 돈다)"
	sleep "$FR"
	"$CRIU" restore -d -D "$CELL/img" -v4 -o restore.log --pidfile "$CELL/pid" "${OPTS[@]}" >/dev/null 2>&1
	local RRC=$? V="restore_fail" D=""
	if [[ $RRC -eq 0 ]]; then
		touch "$RESUME"
		for _ in $(seq 1 80); do grep -qE "^(ALIVE|DEAD)" "$CELL/wl.log" && break; sleep 0.2; done
		D="$(grep -E '^(ALIVE|DEAD)' "$CELL/wl.log" | head -1)"; [[ -z "$D" ]] && D="무응답(hang)"
		case "$D" in ALIVE*) V="연결 살아있음" ;; DEAD*) V="연결 죽음" ;; *) V="무응답" ;; esac
	else
		D="$(grep -m1 'Error (' "$CELL/img/restore.log" | cut -c1-90)"
	fi
	printf '%s,%s,0,%s,%s,"%s"\n' "$FR" "$SENDS" "$RRC" "$V" "$D" >> "$CSV"
	printf "  [정지 %3ss, 서버송신=%s] restore_rc=%s → %s   %s\n" "$FR" "$SENDS" "$RRC" "$V" "$D"
	pkill -9 -f "connprobe --mode idle_client --port $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
	[[ -f "$CELL/pid" ]] && kill -9 "$(cat "$CELL/pid")" 2>/dev/null
	sleep 0.3
}
run_freeze() {
	echo "════ freeze: 얼어 있는 동안 상대가 끊으면? (구 x5) ════"
	local CSV="$OUT/freeze_duration.csv"
	echo "freeze_s,server_sends,dump_rc,restore_rc,verdict,detail" > "$CSV"
	echo "== A. 서버가 조용히 기다리는 경우 (idle) =="
	local P=31000; for f in 0 15 45 90; do _freeze_case "$f" 0 $((P++)) "$CSV"; done
	echo "== B. 서버가 계속 데이터를 보내는 경우 (streaming) =="
	for f in 0 15 45 90; do _freeze_case "$f" 1 $((P++)) "$CSV"; done
	echo; echo "  '연결 죽음' = CRIU rc=0 인데 소켓은 시체(얼어 있는 동안 상대가 끊음)"
	echo "  CSV → $CSV"
}

# ══════════════════════════════════════════════════════════════════════════════
# stream (구 criu_x7) / roundtrip (구 criu_x8) — iptables 패킷 차단이 필요한가
# ══════════════════════════════════════════════════════════════════════════════
# 두 실험은 서버(스트리밍 vs 스트리밍+pong)와 워크로드 모드(stream_reader vs pingpong),
# 판정선(생존 heuristic vs 왕복 증거)만 다르다. 공통 골격을 _ab_case 로 묶었다.
_stream_server() { # $1=port  (계속 밀어넣기만)
	PORT=$1 python3 - <<'PY'
import socket, os, time
port=int(os.environ["PORT"])
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",port)); s.listen(4); print("SRV ready",flush=True)
c,_=s.accept(); c.recv(64); print("SRV accepted",flush=True); c.setblocking(True)
sent=0
try:
    while True:
        c.sendall(b"x"*1400); sent+=1400
        if sent % 140000 == 0: print(f"SRV sent {sent}B",flush=True)
        time.sleep(0.01)
except Exception as e:
    print(f"SRV STOPPED after {sent}B: {type(e).__name__}: {e}",flush=True)
PY
}
_pong_server() { # $1=port  (스트리밍 + PING→PONG)
	PORT=$1 python3 - <<'PY'
import socket, os, select, time
port=int(os.environ["PORT"])
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",port)); s.listen(4); print("SRV ready",flush=True)
c,_=s.accept(); c.recv(64); print("SRV accepted",flush=True); c.setblocking(False)
sent=0
try:
    while True:
        rd,wr,_=select.select([c],[c],[],0.05)
        if rd:
            d=c.recv(4096)
            if not d: print(f"SRV EOF after {sent}B",flush=True); break
            if b"PING" in d: c.sendall(b"PONG\n"); print("SRV got PING -> PONG",flush=True)
        if wr:
            try:
                n=c.send(b"x"*1400); sent+=n
                if sent//140000 != (sent-n)//140000: print(f"SRV sent {sent}B",flush=True)
            except BlockingIOError: pass
        time.sleep(0.005)
except Exception as e:
    print(f"SRV STOPPED after {sent}B: {type(e).__name__}: {e}",flush=True)
PY
}
_ab_case() { # $1=mode(stream_reader|pingpong) $2=server_fn $3=use_ipt(no/yes) $4=port $5=label $6=resume
	local MODE=$1 SRVFN=$2 IPT=$3 PORT=$4 LABEL=$5 RESUME=$6
	rm -f "$RESUME"
	local C="$OUT/runs/${MODE}_$IPT"; rm -rf "$C"; mkdir -p "$C/img"
	echo; printf '═%.0s' {1..74}; echo; echo "  $LABEL"; printf '═%.0s' {1..74}; echo

	"$SRVFN" "$PORT" > "$C/srv.log" 2>&1 & local SRV=$!; sleep 1
	"$WP" --mode "$MODE" --port "$PORT" --resume-file "$RESUME" > "$C/wl.log" 2>&1 & local CL=$!
	wait_line "$C/wl.log" "^READY" 8 "$CL" || { echo "  기동 실패"; kill -9 "$SRV" "$CL" 2>/dev/null; return; }
	sleep 1.5

	echo "[1] 덤프 직전 — 커널이 본 연결"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /'
	local ST; ST="$(ss -tn 2>/dev/null | grep -c ":$PORT.*ESTAB")"
	if [[ "$ST" -lt 1 ]]; then
		echo "    ⚠ ESTABLISHED 가 아니다 — 전제 깨짐. 중단."
		pkill -9 -f "connprobe --mode $MODE --port $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null; return
	fi

	if [[ "$IPT" == yes ]]; then
		echo "[2] iptables — 얼려 있는 동안 서버→클라 패킷을 막는다"
		iptables -I INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP
	else
		echo "[2] iptables 없음 — 패킷이 그대로 도착한다"
	fi

	echo "[3] criu dump"
	"$CRIU" dump -t "$CL" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	echo "    rc=$?"
	echo "[4] ${FREEZE}초 정지 — 서버는 계속 보낸다"; sleep "$FREEZE"
	echo "    서버 로그: $(tail -1 "$C/srv.log")"
	echo "[5] criu restore"
	"$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1
	echo "    rc=$?"
	[[ "$IPT" == yes ]] && iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null

	echo "[6] 복원된 앱이 그 연결을 실제로 쓸 수 있는가"
	touch "$RESUME"
	for _ in $(seq 1 80); do grep -qE "^(ALIVE_READ|DEAD_EOF|READ_FAIL|VERDICT)" "$C/wl.log" && break; sleep 0.2; done
	grep -E '^(RESUMED|SO_ERROR|DRAINED|ALIVE_READ|DEAD_EOF|READ_FAIL|WRITE_OK|WRITE_FAIL|VERDICT)' "$C/wl.log" \
		| head -6 | sed 's/^/    /'
	echo "    서버 최종: $(tail -1 "$C/srv.log")"
	echo
	if grep -q "VERDICT=ALIVE" "$C/wl.log"; then
		echo "  ▶ 연결 생존 ✅  (PING→PONG 왕복 확인)"
	elif grep -q "^ALIVE_READ" "$C/wl.log" && grep -q "^WRITE_OK" "$C/wl.log"; then
		echo "  ▶ 연결 생존(heuristic) — 왕복은 roundtrip 서브커맨드로 확정하라"
	elif grep -qE "ECONNRESET|Connection reset|VERDICT=DEAD" "$C/wl.log"; then
		echo "  ▶ 연결 죽음 ☠  — RST 를 받았다 (iptables 가 필요했다는 증거)"
	else
		echo "  ▶ 애매 — 위 SO_ERROR/READ_FAIL 값을 봐야 한다"
	fi
	pkill -9 -f "connprobe --mode $MODE --port $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
	[[ -f "$C/pid" ]] && kill -9 "$(cat "$C/pid")" 2>/dev/null
	iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null
	sleep 0.5
}
run_stream() {
	echo "════ stream: iptables 패킷 차단이 필요한가 — 스트리밍 리더 (구 x7) ════"
	trap 'for p in 32100 32101; do iptables -D INPUT -p tcp -s 127.0.0.1 --sport $p -j DROP 2>/dev/null; done' RETURN
	_ab_case stream_reader _stream_server no  32100 "A. iptables 없음 — 얼려 있는 동안 패킷 도착" /tmp/connprobe_stream
	_ab_case stream_reader _stream_server yes 32101 "B. iptables 있음 — 얼려 있는 동안 패킷 차단" /tmp/connprobe_stream
	echo; echo "  A가 죽고 B가 살면 → iptables 패킷 차단은 필수다."
	trap - RETURN
}
run_roundtrip() {
	echo "════ roundtrip: 왕복(PING→PONG)까지 검증 — write 성공은 증거가 아니다 (구 x8) ════"
	trap 'for p in 32200 32201; do iptables -D INPUT -p tcp -s 127.0.0.1 --sport $p -j DROP 2>/dev/null; done' RETURN
	_ab_case pingpong _pong_server no  32200 "A. iptables 없음" /tmp/connprobe_rt
	_ab_case pingpong _pong_server yes 32201 "B. iptables 있음" /tmp/connprobe_rt
	echo; echo "  판정 기준: PING→PONG 왕복이 성공해야 '연결 생존'이다."
	trap - RETURN
}

case "${1:-}" in
	syn_sent)  run_syn_sent ;;
	syn_alive) run_syn_alive ;;
	freeze)    run_freeze ;;
	stream)    run_stream ;;
	roundtrip) run_roundtrip ;;
	all)       run_syn_sent; echo; run_syn_alive; echo; run_freeze; echo; run_stream; echo; run_roundtrip ;;
	*) echo "usage: sudo $0 [syn_sent|syn_alive|freeze|stream|roundtrip|all]"; exit 1 ;;
esac
echo; echo "[done]"
