#!/usr/bin/env bash
# criu_x8.sh — iptables 패킷 차단이 정말 필요한가? (제대로 된 검증)
#
# 이전 실험(x7)의 결함:
#   · 서버가 보내기만 하고 읽지 않아서 왕복(round-trip) 확인이 불가능했다
#   · write()가 성공했다고 연결이 살아있다는 뜻이 아니다 (커널 버퍼에 넣기만 해도 성공)
#   · SO_ERROR=0은 "아직 RST를 안 받았다"일 뿐이다
#
# 이번엔 제대로:
#   1. 서버가 스트리밍하면서 동시에 ping을 받으면 pong으로 답한다
#   2. 클라이언트가 복원 후 ping을 보내고 pong이 실제로 돌아오는지 확인 (왕복)
#   3. 서버 쪽에서도 ss로 그 소켓이 아직 ESTABLISHED인지 직접 본다
#   4. dump 후 / 정지 중 / restore 후 각 시점의 커널 소켓 상태를 찍는다
#
#   sudo ./criu_x8.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음"; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$ROOT/failprobe/results"; mkdir -p "$OUT/runs"
FREEZE="${FREEZE:-45}"

# ── 클라이언트: 계속 읽다가, 복원 후 ping→pong 왕복을 확인 ──────────────
cat > /tmp/c8.c <<'SRC'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
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
	if (write(fd, "start\n", 6) != 6) { perror("write"); return 1; }
	printf("READY\n"); fflush(stdout);

	char buf[8192];
	long total = 0;
	fcntl(fd, F_SETFL, O_NONBLOCK);
	while (access("/tmp/c8_go", F_OK) != 0) {   /* 계속 읽는다 = 스트리밍 앱 */
		int n = recv(fd, buf, sizeof(buf), 0);
		if (n > 0) total += n;
		struct timespec ts = { 0, 10000000L };
		nanosleep(&ts, NULL);
	}
	printf("RESUMED  read_before_freeze=%ld\n", total); fflush(stdout);

	/* ── 복원 후 검증 ── */
	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);      /* 블로킹으로 */
	struct timeval tv = { 8, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	int soerr = 0; socklen_t sl = sizeof(soerr);
	getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
	printf("SO_ERROR=%d (%s)\n", soerr, soerr ? strerror(soerr) : "no error");
	fflush(stdout);

	/* (1) 얼려 있는 동안 서버가 보낸 게 쌓여 있어야 한다 — 8초 안에 뭐라도 오나? */
	long drained = 0;
	for (int i = 0; i < 20; i++) {
		int n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
		if (n > 0) drained += n;
		else break;
	}
	printf("DRAINED  after_restore=%ld bytes\n", drained); fflush(stdout);

	/* (2) 진짜 검증 — ping 보내고 pong이 돌아오는가 (왕복) */
	if (write(fd, "PING\n", 5) != 5) {
		printf("VERDICT=DEAD  write errno=%d (%s)\n", errno, strerror(errno));
		fflush(stdout); return 0;
	}
	/* 서버는 스트리밍 중이므로 x가 섞여 온다. PONG 문자열을 찾을 때까지 읽는다. */
	time_t t0 = time(NULL);
	int found = 0;
	while (time(NULL) - t0 < 8) {
		int n = recv(fd, buf, sizeof(buf) - 1, 0);
		if (n <= 0) break;
		buf[n] = 0;
		if (strstr(buf, "PONG")) { found = 1; break; }
	}
	if (found) printf("VERDICT=ALIVE  (PING → PONG 왕복 성공)\n");
	else if (errno == ECONNRESET) printf("VERDICT=DEAD  (ECONNRESET — RST를 받았다)\n");
	else printf("VERDICT=DEAD  (PONG 미수신, errno=%d %s)\n", errno, strerror(errno));
	fflush(stdout);
	return 0;
}
SRC
gcc -O2 -o /tmp/c8 /tmp/c8.c || exit 1

run_case() {
	local IPT=$1 PORT=$2 LABEL=$3
	rm -f /tmp/c8_go /tmp/c8.log /tmp/s8.log
	local C="$OUT/runs/x8_$IPT"; rm -rf "$C"; mkdir -p "$C/img"
	echo; printf '═%.0s' {1..76}; echo
	echo "  $LABEL"
	printf '═%.0s' {1..76}; echo

	# 서버: 스트리밍 + ping에 pong 응답 (select로 동시에)
	PORT=$PORT python3 - <<'PY' > /tmp/s8.log 2>&1 &
import socket, os, select, time
port = int(os.environ["PORT"])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(4); print("SRV ready", flush=True)
c, _ = s.accept(); c.recv(64); print("SRV accepted", flush=True)
c.setblocking(False)
sent = 0
try:
    while True:
        rd, wr, _ = select.select([c], [c], [], 0.05)
        if rd:
            d = c.recv(4096)
            if not d:
                print(f"SRV EOF (peer closed) after {sent}B", flush=True); break
            if b"PING" in d:
                c.sendall(b"PONG\n"); print("SRV got PING → sent PONG", flush=True)
        if wr:
            try:
                n = c.send(b"x" * 1400)       # 스트리밍
                sent += n
                if sent // 140000 != (sent - n) // 140000:
                    print(f"SRV sent {sent}B", flush=True)
            except BlockingIOError:
                pass
        time.sleep(0.005)
except Exception as e:
    print(f"SRV STOPPED after {sent}B: {type(e).__name__}: {e}", flush=True)
PY
	local SRV=$!
	sleep 1
	/tmp/c8 "$PORT" > /tmp/c8.log 2>&1 & local CL=$!
	for _ in $(seq 1 60); do grep -q READY /tmp/c8.log && break; sleep 0.1; done
	sleep 1.5

	echo "[1] 덤프 직전 — 커널이 본 연결"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /'
	local ST; ST="$(ss -tn 2>/dev/null | grep -c ':'"$PORT"'.*ESTAB' || echo 0)"
	if [[ "$ST" -lt 2 ]]; then
		echo "    ⚠ ESTABLISHED 쌍이 아니다 — 전제 깨짐. 중단."
		pkill -9 -f "/tmp/c8 $PORT"; kill -9 "$SRV" 2>/dev/null; return
	fi
	echo "    서버 송신량: $(grep -o 'SRV sent [0-9]*B' /tmp/s8.log | tail -1)"

	if [[ "$IPT" == yes ]]; then
		echo; echo "[2] iptables — 얼려 있는 동안 서버→클라이언트 패킷을 막는다"
		iptables -I INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP
		echo "    \$ iptables -I INPUT -p tcp --sport $PORT -j DROP"
	else
		echo; echo "[2] iptables 없음 — 패킷이 그대로 도착한다"
	fi

	echo; echo "[3] criu dump  (--tcp-established)"
	"$CRIU" dump -t "$CL" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	echo "    rc = $?"
	echo "    dump 직후 커널의 그 연결:"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /' || echo "        (없음 — 소켓이 사라졌다)"

	echo; echo "[4] ${FREEZE}초 정지 — 서버는 계속 보낸다"
	sleep "$FREEZE"
	echo "    서버 로그: $(tail -1 /tmp/s8.log)"
	echo "    정지 중 커널의 그 연결:"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /' || echo "        (없음)"

	echo; echo "[5] criu restore"
	"$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1
	echo "    rc = $?"
	[[ "$IPT" == yes ]] && iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null
	sleep 1
	echo "    복원 후 커널의 그 연결:"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /' || echo "        (없음)"

	echo; echo "[6] 왕복 검증 — PING을 보내고 PONG이 돌아오는가"
	touch /tmp/c8_go
	for _ in $(seq 1 80); do grep -q "^VERDICT" /tmp/c8.log && break; sleep 0.25; done
	grep -E '^(RESUMED|SO_ERROR|DRAINED|VERDICT)' /tmp/c8.log | sed 's/^/    /'
	echo "    서버 최종: $(tail -1 /tmp/s8.log)"
	echo
	if grep -q "VERDICT=ALIVE" /tmp/c8.log; then
		echo "  ▶ 연결 생존 ✅  (왕복 확인)"
	else
		echo "  ▶ 연결 죽음 ☠"
	fi

	pkill -9 -f "/tmp/c8 $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
	[[ -f "$C/pid" ]] && kill -9 "$(cat "$C/pid")" 2>/dev/null
	iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null
	sleep 0.5
}

trap 'for p in 32200 32201; do iptables -D INPUT -p tcp -s 127.0.0.1 --sport $p -j DROP 2>/dev/null; done' EXIT

run_case no  32200 "A. iptables 없음"
run_case yes 32201 "B. iptables 있음"

echo; printf '═%.0s' {1..76}; echo
echo "  판정 기준: PING → PONG 왕복이 성공해야 '연결 생존'이다."
echo "  write()만 성공한 건 증거가 아니다 (커널 버퍼에 넣기만 해도 성공하므로)."
printf '═%.0s' {1..76}; echo
