#!/usr/bin/env bash
# criu_x4.sh — SYN_SENT 소켓이 복원 후 "정말 살아 있는가"
#
# criu_x3에서 dump_rc=0, restore_rc=0이 나왔다. 그러나 rc=0은 성공을 뜻하지 않는다
# (자원 ④에서 이미 배웠다). CRIU의 TCP repair는 ESTABLISHED만 다룬다. SYN_SENT를
# 어떻게 처리했는지 — 상태를 보존했는지, 연결을 버리고 빈 소켓만 복원했는지 — 는
# rc로 알 수 없다.
#
# 결정적 검사:
#   1. 진짜 리스너를 띄운다 (연결이 성사될 수 있는 상대)
#   2. 방화벽으로 SYN을 DROP → 핸드셰이크가 멈춰 SYN_SENT에 고정
#   3. 그 상태에서 dump → restore
#   4. 방화벽을 푼다  → 소켓이 살아 있으면 커널이 SYN을 재전송(1s,2s,4s…)하고
#                        연결이 성사된다. 죽어 있으면 아무 일도 없다.
#   5. 워크로드가 연결 성사를 감지하면 "CONNECTED"를 찍는다 (실제 앱과 동일한 epoll 대기)
#
#   sudo ./criu_x4.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음"; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$ROOT/failprobe/results/runs/synsent2"; rm -rf "$OUT"; mkdir -p "$OUT/img"
PORT=29998

cat > /tmp/ss2.c <<'SRC'
/* 논블로킹 connect + epoll — 실제 스트리밍 앱/브라우저와 같은 방식 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	int port = (argc > 1) ? atoi(argv[1]) : 29998;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	fcntl(fd, F_SETFL, O_NONBLOCK);
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0 && errno != EINPROGRESS) {
		perror("connect"); return 1;
	}
	printf("PHASE syn_sent\n"); fflush(stdout);

	int ep = epoll_create1(0);
	struct epoll_event ev = { .events = EPOLLOUT, .data.fd = fd };
	epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
	for (;;) {                       /* 실제 앱처럼 연결 완료를 기다린다 */
		struct epoll_event out[1];
		int n = epoll_wait(ep, out, 1, 1000);
		if (n > 0) {
			int err = 0; socklen_t el = sizeof(err);
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
			if (err == 0) { printf("CONNECTED — 연결 성사\n"); fflush(stdout); }
			else { printf("FAILED — errno=%d (%s)\n", err, strerror(err)); fflush(stdout); }
			break;
		}
	}
	for (;;) { struct timespec ts = { 1, 0 }; nanosleep(&ts, NULL); }
}
SRC
gcc -O2 -o /tmp/ss2 /tmp/ss2.c || exit 1

# 진짜 리스너 (연결이 성사될 수 있는 상대) — 덤프 집합 밖
python3 - <<PYEOF > /tmp/lis.log 2>&1 &
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $PORT)); s.listen(8)
print("LISTENER ready", flush=True)
while True:
    c, _ = s.accept(); print("ACCEPTED", flush=True)
PYEOF
LIS=$!; sleep 1

echo "[1] SYN DROP — 핸드셰이크를 멈춘다"
iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP
cleanup(){ iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP 2>/dev/null
           kill -9 $LIS 2>/dev/null; pkill -9 -f /tmp/ss2 2>/dev/null; }
trap cleanup EXIT

echo "[2] 논블로킹 connect → SYN_SENT 고정"
/tmp/ss2 $PORT > /tmp/ss2.log 2>&1 & WL=$!
sleep 1.5
python3 -c "
for ln in open('/proc/net/tcp').readlines()[1:]:
    f=ln.split(); rp=int(f[2].split(':')[1],16)
    if rp==$PORT and f[3]=='02': print('    커널 상태: SYN_SENT  inode=%s' % f[9])"

echo "[3] dump"
"$CRIU" dump -t "$WL" -D "$OUT/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
echo "    dump_rc=$?"
grep -iE "warn.*(sock|inet|tcp)|Error" "$OUT/img/dump.log" | head -3 | sed 's/^/    /'

echo "[4] restore"
"$CRIU" restore -d -D "$OUT/img" -v4 -o restore.log --pidfile "$OUT/pid" "${OPTS[@]}" >/dev/null 2>&1
echo "    restore_rc=$?"
RP=$(cat "$OUT/pid" 2>/dev/null)
sleep 1
echo "    복원된 프로세스의 소켓 상태:"
python3 -c "
found=False
for ln in open('/proc/net/tcp').readlines()[1:]:
    f=ln.split(); rp=int(f[2].split(':')[1],16)
    if rp==$PORT:
        st={'01':'ESTABLISHED','02':'SYN_SENT','06':'TIME_WAIT','07':'CLOSE','0A':'LISTEN'}.get(f[3],f[3])
        print('      %-12s inode=%s' % (st, f[9])); found=True
if not found: print('      ⚠️  소켓이 사라졌다 — 연결이 증발했다')"

echo "[5] 방화벽 해제 — 살아 있다면 SYN 재전송이 통과해 연결이 성사되어야 한다"
iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DROP
echo "    12초 대기 (SYN 재전송 백오프: 1s, 2s, 4s, 8s…)"
for i in $(seq 1 24); do
  grep -qE "^(CONNECTED|FAILED)" /tmp/ss2.log && break
  sleep 0.5
done
echo
echo "── 워크로드 출력 ──"; sed 's/^/    /' /tmp/ss2.log
echo "── 리스너 출력 ──";   sed 's/^/    /' /tmp/lis.log

echo
echo "── 판정 ──"
if grep -q "^CONNECTED" /tmp/ss2.log; then
  echo "  ✅ 소켓이 살아남았다 — 복원 후 SYN 재전송이 통과하고 연결이 성사됐다."
  echo "     → SYN_SENT는 진짜로 안전하다. \"클라이언트에는 위험한 창이 없다\"가 확정."
elif grep -q "^FAILED" /tmp/ss2.log; then
  echo "  ⚠️  소켓이 에러로 깨어났다 — 앱은 최소한 실패를 '알 수는' 있다 (재시도 가능)."
else
  echo "  ❌ 침묵형 실패 — rc=0/rc=0인데 연결은 증발했다."
  echo "     앱은 영원히 오지 않는 응답을 epoll에서 기다린다. 프로세스는 살아 있으므로"
  echo "     헬스체크(PING/PONG)조차 통과한다. 끊긴 것은 연결 하나뿐이다."
fi
