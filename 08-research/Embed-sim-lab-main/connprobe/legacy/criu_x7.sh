#!/usr/bin/env bash
# criu_x7.sh — iptables 패킷 차단이 정말 필요한가?
#
# 지금까지 우리 워크로드는 recv()를 안 했다. 그래서 수신 윈도우가 0이 되고,
# 흐름 제어가 서버 송신을 멈춰서 — 얼려 있는 동안 도착하는 패킷이 없었다.
# 그 덕에 iptables 없이도 연결이 살아남았다.
#
# 그런데 실제 스트리밍 앱은 계속 읽는다. window가 열려 있으니 서버가 계속 보내고,
# 얼려 있는 동안 패킷이 도착한다. 주인 없는 패킷 → 커널이 RST → 서버가 연결을 끊는다.
# (CRIU 공식 가이드가 dump~restore 구간의 패킷 차단을 요구하는 이유)
#
# 이 스크립트는 그것을 실측한다. 워크로드가 "계속 읽는" 버전이고, 두 조건을 비교한다:
#
#   A. iptables 없음  → 예상: 얼려 있는 동안 RST → 복원 후 ECONNRESET
#   B. iptables 있음  → 예상: 패킷이 막혀 RST 없음 → 복원 후 연결 생존
#
#   sudo ./criu_x7.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음"; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$ROOT/failprobe/results"; mkdir -p "$OUT/runs"
FREEZE="${FREEZE:-45}"

# ── 계속 읽는 클라이언트 (= 실제 스트리밍 앱) ───────────────────────────
cat > /tmp/rd.c <<'SRC'
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

	/* 실제 스트리밍 앱처럼 계속 읽는다 → 수신 윈도우가 열려 있다
	   → 서버가 계속 보낼 수 있다 → 얼려 있는 동안 패킷이 도착한다 */
	char buf[4096];
	long total = 0;
	fcntl(fd, F_SETFL, O_NONBLOCK);
	while (access("/tmp/rd_go", F_OK) != 0) {
		int n = recv(fd, buf, sizeof(buf), 0);
		if (n > 0) total += n;
		else if (n == 0) { printf("EOF_WHILE_READING total=%ld\n", total); fflush(stdout); }
		else if (errno != EAGAIN && errno != EWOULDBLOCK) {
			printf("READ_ERR errno=%d (%s) total=%ld\n", errno, strerror(errno), total);
			fflush(stdout);
		}
		struct timespec ts = { 0, 20000000L };
		nanosleep(&ts, NULL);
	}
	printf("RESUMED total_before=%ld\n", total); fflush(stdout);

	/* 복원 후 — 연결이 살아 있는가? */
	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);        /* 확실히 블로킹으로 */
	struct timeval tv = { 8, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	/* (1) 소켓 에러 상태부터 확인 */
	int soerr = 0; socklen_t sl = sizeof(soerr);
	getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
	printf("SO_ERROR = %d (%s)\n", soerr, soerr ? strerror(soerr) : "no error");
	fflush(stdout);

	/* (2) 서버가 계속 보내고 있으니, 그냥 읽어보면 데이터가 와야 한다 */
	int n = recv(fd, buf, sizeof(buf) - 1, 0);
	if (n > 0) {
		printf("ALIVE_READ  (%d bytes 수신 — 서버가 여전히 보내고 있다)\n", n);
	} else if (n == 0) {
		printf("DEAD_EOF  (상대가 닫았다)\n");
	} else {
		printf("READ_FAIL errno=%d (%s)\n", errno, strerror(errno));
	}
	fflush(stdout);

	/* (3) 써 보기 */
	if (write(fd, "ping\n", 5) != 5)
		printf("WRITE_FAIL errno=%d (%s)\n", errno, strerror(errno));
	else
		printf("WRITE_OK\n");
	fflush(stdout);
	return 0;
}
SRC
gcc -O2 -o /tmp/rd /tmp/rd.c || exit 1

run_case() {
	local USE_IPT=$1 PORT=$2 LABEL=$3
	rm -f /tmp/rd_go /tmp/rd.log /tmp/srv2.log
	local C="$OUT/runs/x7_$USE_IPT"; rm -rf "$C"; mkdir -p "$C/img"

	echo
	printf '═%.0s' {1..74}; echo
	echo "  $LABEL"
	printf '═%.0s' {1..74}; echo

	# 서버: 쉬지 않고 데이터를 밀어넣는다 (스트리밍)
	PORT=$PORT python3 - <<'PY' > /tmp/srv2.log 2>&1 &
import socket, os, time
port = int(os.environ["PORT"])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(4); print("SRV ready", flush=True)
c, _ = s.accept(); c.recv(64); print("SRV accepted", flush=True)
c.setblocking(True)                     # 블로킹. 읽지 않는다. 오직 보내기만.
sent = 0
try:
    while True:
        c.sendall(b"x" * 1400)          # 계속 스트리밍 (클라이언트가 읽으니 계속 나간다)
        sent += 1400
        if sent % 140000 == 0:
            print(f"SRV sent {sent}B", flush=True)
        time.sleep(0.01)
except Exception as e:
    print(f"SRV STOPPED after {sent}B: {type(e).__name__}: {e}", flush=True)
PY
	local SRV=$!
	sleep 1
	/tmp/rd "$PORT" > /tmp/rd.log 2>&1 & local CL=$!
	for _ in $(seq 1 60); do grep -q READY /tmp/rd.log && break; sleep 0.1; done
	sleep 1

	echo "[1] 덤프 직전 — 상태 확인"
	echo "    \$ ss -tn | grep :$PORT"
	ss -tn 2>/dev/null | grep ":$PORT" | sed 's/^/        /'
	local ST
	ST="$(ss -tn 2>/dev/null | grep ":$PORT" | awk '{print $1}' | sort -u | tr '\n' ' ')"
	echo "    상태: ${ST:-(없음)}"
	if ! echo "$ST" | grep -q ESTAB; then
		echo "    ⚠ ESTABLISHED가 아니다 — 실험 전제가 깨졌다. 중단."
		pkill -9 -f "/tmp/rd $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
		return
	fi
	echo "    서버가 지금까지 보낸 양: $(grep -c 'SRV sent' /tmp/srv2.log 2>/dev/null || echo 0) × 140KB"
	echo "    클라이언트가 지금까지 읽은 양: (계속 읽는 중 — recv 루프)"

	if [[ "$USE_IPT" == "yes" ]]; then
		echo
		echo "[2] iptables — 얼려 있는 동안 이 연결로 들어오는 패킷을 막는다"
		echo "    \$ iptables -I INPUT -p tcp --sport $PORT -j DROP"
		iptables -I INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP
	else
		echo
		echo "[2] iptables 없음 — 얼려 있는 동안 패킷이 그대로 도착한다"
	fi

	echo
	echo "[3] criu dump"
	"$CRIU" dump -t "$CL" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
	local DRC=$?
	echo "    rc = $DRC"
	[[ $DRC -ne 0 ]] && { grep -m1 "Error (" "$C/img/dump.log" | sed 's/^/    /'; }

	echo
	echo "[4] ${FREEZE}초 동안 얼려둔다 — 서버는 계속 돌아간다"
	sleep "$FREEZE"
	echo "    서버 로그: $(tail -1 /tmp/srv2.log)"
	echo "    (SRV STOPPED 가 찍혔다면 → 서버가 RST를 받고 연결이 끊긴 것)"

	echo
	echo "[5] criu restore"
	"$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1
	local RRC=$?
	echo "    rc = $RRC"

	if [[ "$USE_IPT" == "yes" ]]; then
		echo "    \$ iptables -D INPUT ...   (방화벽 해제)"
		iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null
	fi

	echo
	echo "[6] 복원된 앱이 그 연결을 실제로 쓸 수 있는가?"
	touch /tmp/rd_go
	for _ in $(seq 1 60); do grep -qE "^(ALIVE|DEAD)" /tmp/rd.log && break; sleep 0.2; done
	grep -E '^(RESUMED|SO_ERROR|ALIVE_READ|DEAD_EOF|READ_FAIL|WRITE_OK|WRITE_FAIL)' /tmp/rd.log \
		| head -6 | sed 's/^/    /'

	echo
	echo "    서버 최종 로그: $(tail -1 /tmp/srv2.log)"
	echo
	if grep -q "^ALIVE_READ" /tmp/rd.log && grep -q "^WRITE_OK" /tmp/rd.log; then
		echo "  ▶ 판정: 연결 생존 ✅  — 복원 후에도 서버와 실제로 데이터가 오간다"
	elif grep -qE "ECONNRESET|Connection reset" /tmp/rd.log; then
		echo "  ▶ 판정: 연결 죽음 ☠  — RST를 받았다 (iptables가 필요했다는 증거)"
	else
		echo "  ▶ 판정: 애매 — 위 SO_ERROR / READ_FAIL 값을 봐야 한다"
	fi

	pkill -9 -f "/tmp/rd $PORT" 2>/dev/null; kill -9 "$SRV" 2>/dev/null
	[[ -f "$C/pid" ]] && kill -9 "$(cat "$C/pid")" 2>/dev/null
	iptables -D INPUT -p tcp -s 127.0.0.1 --sport "$PORT" -j DROP 2>/dev/null
	sleep 0.5
}

trap 'iptables -D INPUT -p tcp -s 127.0.0.1 --sport 32100 -j DROP 2>/dev/null;
      iptables -D INPUT -p tcp -s 127.0.0.1 --sport 32101 -j DROP 2>/dev/null' EXIT

run_case no  32100 "A. iptables 없음 — 얼려 있는 동안 패킷이 계속 도착한다"
run_case yes 32101 "B. iptables 있음 — 얼려 있는 동안 패킷을 막는다"

echo
printf '═%.0s' {1..74}; echo
echo "  A가 죽고 B가 살면 → iptables 패킷 차단은 '있으면 좋은 것'이 아니라 필수다."
echo "  둘 다 살면    → 흐름 제어가 여전히 보호하고 있다는 뜻 (서버 송신 패턴 재확인 필요)."
printf '═%.0s' {1..74}; echo
