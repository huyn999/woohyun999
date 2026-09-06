#!/usr/bin/env bash
# criu_x5.sh — "얼지 않은 바깥 세계" 실측
#
# 지금까지 우리는 dump 직후 ~1초 만에 restore했다. 그러나 실제 용도는
# "앱을 얼려 메모리를 회수하고, 사용자가 돌아오면 되살린다" — 몇 분 뒤다.
# 얼어 있는 동안 바깥 세계는 얼지 않는다.
#
# 질문: CRIU가 TCP 연결을 완벽히 복원해도, 그 사이 상대가 끊었다면?
#       → CRIU는 성공했는데 앱은 죽은 연결을 들고 있게 된다.
#
# 방법: 정지 시간을 0s / 15s / 45s / 90s로 늘려가며,
#       (a) 서버가 계속 데이터를 보내는 경우 (재전송 폭풍 → RST)
#       (b) 복원 후 실제로 데이터를 주고받을 수 있는지
#       를 확인한다.
#
#   sudo ./criu_x5.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음"; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$ROOT/failprobe/results"; mkdir -p "$OUT/runs"
CSV="$OUT/freeze_duration.csv"
echo "freeze_s,server_sends,dump_rc,restore_rc,verdict,detail" > "$CSV"

cat > /tmp/cl.c <<'SRC'
/* 서버와 연결을 맺고, 복원 후 데이터를 주고받을 수 있는지 확인하는 클라이언트 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	int port = atoi(argv[1]);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("connect"); return 1; }
	if (write(fd, "hello\n", 6) != 6) { perror("write"); return 1; }
	printf("READY\n"); fflush(stdout);

	/* 여기서 얼린다. 복원되면 아래가 이어서 실행된다. */
	for (;;) {
		struct timespec ts = { 0, 200000000L };
		nanosleep(&ts, NULL);
		if (access("/tmp/cl_go", F_OK) == 0) break;   /* 복원 후 신호 */
	}
	/* 연결이 아직 살아 있는가? — 실제로 써 보고 읽어 본다 */
	if (write(fd, "ping\n", 5) != 5) {
		printf("DEAD_WRITE errno=%d (%s)\n", errno, strerror(errno)); fflush(stdout); return 0;
	}
	char buf[64];
	struct timeval tv = { 5, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	int n = read(fd, buf, sizeof(buf) - 1);
	if (n > 0) { buf[n] = 0; printf("ALIVE got=%s", buf); }
	else if (n == 0) printf("DEAD_EOF (상대가 닫았다)\n");
	else printf("DEAD_READ errno=%d (%s)\n", errno, strerror(errno));
	fflush(stdout);
	return 0;
}
SRC
gcc -O2 -o /tmp/cl /tmp/cl.c || exit 1

run_case() {
	local FREEZE=$1 SENDS=$2 PORT=$3
	rm -f /tmp/cl_go /tmp/cl.log /tmp/srv.log
	local CELL="$OUT/runs/freeze_${FREEZE}_${SENDS}"; rm -rf "$CELL"; mkdir -p "$CELL/img"

	# 서버 (얼지 않는다 — 바깥 세계)
	SENDS=$SENDS PORT=$PORT python3 - <<'PY' > /tmp/srv.log 2>&1 &
import socket, os, time
port=int(os.environ["PORT"]); sends=os.environ["SENDS"]=="1"
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",port)); s.listen(4); print("SRV ready",flush=True)
c,_=s.accept(); c.recv(64); print("SRV accepted",flush=True)
try:
    while True:
        if sends:                      # 얼어 있는 클라이언트에게 계속 보낸다
            c.sendall(b"x"*1400)       # → ACK 없음 → 재전송 폭풍 → 결국 RST
        d=c.recv(64)                   # 클라이언트의 ping을 받으면 pong
        if d and b"ping" in d: c.sendall(b"pong\n"); print("SRV pong",flush=True)
        if not d: print("SRV peer closed",flush=True); break
        time.sleep(0.2)
except Exception as e:
    print("SRV err",e,flush=True)
PY
	local SRV=$!
	sleep 1
	/tmp/cl "$PORT" > /tmp/cl.log 2>&1 & local CL=$!
	for _ in $(seq 1 50); do grep -q READY /tmp/cl.log && break; sleep 0.1; done

	"$CRIU" dump -t "$CL" -D "$CELL/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	local DRC=$?
	if [[ $DRC -ne 0 ]]; then
		printf '%s,%s,%s,na,dump_fail,"%s"\n' "$FREEZE" "$SENDS" "$DRC" "$(grep -m1 'Error (' "$CELL/img/dump.log" | cut -c1-90)" >> "$CSV"
		echo "  [정지 ${FREEZE}s, 서버송신=$SENDS] dump 실패($DRC)"; kill -9 "$SRV" 2>/dev/null; return
	fi

	echo "     ... ${FREEZE}초 동안 얼어 있는다 (바깥 세계는 계속 돌아간다)"
	sleep "$FREEZE"

	"$CRIU" restore -d -D "$CELL/img" -v4 -o restore.log --pidfile "$CELL/pid" "${OPTS[@]}" >/dev/null 2>&1
	local RRC=$?
	local V="restore_fail" D=""
	if [[ $RRC -eq 0 ]]; then
		touch /tmp/cl_go            # 복원된 클라이언트에게 "연결을 써 보라"고 신호
		for _ in $(seq 1 80); do grep -qE "^(ALIVE|DEAD)" /tmp/cl.log && break; sleep 0.2; done
		D="$(grep -E '^(ALIVE|DEAD)' /tmp/cl.log | head -1)"
		[[ -z "$D" ]] && D="무응답(hang)"
		case "$D" in
			ALIVE*) V="연결 살아있음" ;;
			DEAD*)  V="연결 죽음" ;;
			*)      V="무응답" ;;
		esac
	else
		D="$(grep -m1 'Error (' "$CELL/img/restore.log" | cut -c1-90)"
	fi
	printf '%s,%s,0,%s,%s,"%s"\n' "$FREEZE" "$SENDS" "$RRC" "$V" "$D" >> "$CSV"
	printf "  [정지 %3ss, 서버송신=%s] restore_rc=%s → %s   %s\n" "$FREEZE" "$SENDS" "$RRC" "$V" "$D"
	pkill -9 -f "/tmp/cl $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
	[[ -f "$CELL/pid" ]] && kill -9 "$(cat "$CELL/pid")" 2>/dev/null
	sleep 0.3
}

echo "== A. 서버가 조용히 기다리는 경우 (idle 연결) =="
P=31000
for f in 0 15 45 90; do run_case "$f" 0 $((P++)); done
echo
echo "== B. 서버가 계속 데이터를 보내는 경우 (실제 스트리밍) =="
for f in 0 15 45 90; do run_case "$f" 1 $((P++)); done

echo
echo "── 읽는 법 ──"
echo "  '연결 살아있음' → CRIU 복원 후에도 실제로 데이터가 오간다 (진짜 성공)"
echo "  '연결 죽음'     → CRIU는 rc=0인데 소켓은 시체다 — 얼어 있는 동안 상대가 끊었다 ★"
echo "  B가 A보다 빨리 죽으면 → 스트리밍처럼 데이터가 흐르는 연결일수록 정지에 취약하다"
echo "CSV → $CSV"
