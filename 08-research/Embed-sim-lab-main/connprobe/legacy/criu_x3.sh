#!/usr/bin/env bash
# criu_x3.sh — SYN_SENT 실측 (자기 압축 해제형, 파일 하나)
#
# 왜 필요한가:
#   ext_tcp_pend는 블로킹 connect()를 썼다. connect()가 리턴한 뒤에 덤프했으므로
#   소켓은 이미 ESTABLISHED였다. 즉 "핸드셰이크 진행 중(SYN_SENT)"은 한 번도
#   측정하지 않았다.
#
#   그런데 실제 스트리밍 앱·브라우저는 논블로킹 connect() + epoll을 쓴다.
#   인터넷 RTT 동안 소켓은 SYN_SENT에 머문다 — 로컬 루프백의 마이크로초가
#   아니라 수십~수백 ms짜리 창이다.
#
#   CRIU의 TCP 덤프는 ESTABLISHED / CLOSE / LISTEN만 다룬다.
#   SYN_SENT가 어떻게 되는지가 이 스크립트의 유일한 질문이다.
#
# 방법: iptables로 SYN을 DROP해 응답이 영원히 오지 않게 만든 뒤,
#       논블로킹 connect로 소켓을 SYN_SENT에 붙잡아 두고 덤프한다.
#
#   sudo ./criu_x3.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음" >&2; exit 1; }
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
OUT="$ROOT/failprobe/results"; mkdir -p "$OUT/runs"
BLACKHOLE_PORT=29999

cat > /tmp/synsent.c <<'SRC'
/* 논블로킹 connect로 SYN_SENT 상태를 붙잡아 두는 최소 워크로드 */
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
	int port = (argc > 1) ? atoi(argv[1]) : 29999;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) { perror("socket"); return 1; }
	fcntl(fd, F_SETFL, O_NONBLOCK);              /* 논블로킹 — 실제 앱과 동일 */
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	int r = connect(fd, (struct sockaddr *)&a, sizeof(a));
	if (r < 0 && errno != EINPROGRESS) { perror("connect"); return 1; }
	printf("PHASE syn_sent fd=%d errno=%d(EINPROGRESS=%d)\n", fd, errno, EINPROGRESS);
	fflush(stdout);
	for (;;) { struct timespec ts = { 1, 0 }; nanosleep(&ts, NULL); }  /* 창을 붙잡아 둔다 */
}
SRC
gcc -O2 -o /tmp/synsent /tmp/synsent.c || { echo "빌드 실패"; exit 1; }

echo "[1/4] SYN을 DROP하도록 방화벽 설정 (응답이 영원히 안 오게)"
iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport $BLACKHOLE_PORT -j DROP 2>/dev/null \
  || { echo "ERROR: iptables 실패 — WSL에서 iptables가 없으면 아래 대안을 쓰세요"; exit 1; }
cleanup(){ iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport $BLACKHOLE_PORT -j DROP 2>/dev/null; }
trap cleanup EXIT

echo "[2/4] 논블로킹 connect → SYN_SENT에 붙잡기"
/tmp/synsent $BLACKHOLE_PORT > /tmp/synsent.log 2>&1 &
WLPID=$!
sleep 1
cat /tmp/synsent.log

echo "[3/4] 커널이 정말 SYN_SENT인지 확인 (상태 02 = SYN_SENT)"
python3 - <<PYEOF
for ln in open('/proc/net/tcp').readlines()[1:]:
    f = ln.split()
    rp = int(f[2].split(':')[1], 16)
    if rp == $BLACKHOLE_PORT:
        st = {'01':'ESTABLISHED','02':'SYN_SENT','0A':'LISTEN'}.get(f[3], f[3])
        print(f"   remote_port={rp}  state={st}  inode={f[9]}")
PYEOF

echo "[4/4] 이 상태에서 dump 시도"
CELL="$OUT/runs/synsent"; rm -rf "$CELL"; mkdir -p "$CELL/img"
"$CRIU" dump -t "$WLPID" -D "$CELL/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
DRC=$?
echo "   dump_rc=$DRC"
grep -m3 -E "Error|Warn.*(sock|tcp|inet)" "$CELL/img/dump.log" | sed 's/^/   /'
kill -9 "$WLPID" 2>/dev/null

echo
echo "── 판정 ──"
if [[ $DRC -ne 0 ]]; then
  echo "  ❌ SYN_SENT는 dump 불가 → \"클라이언트는 안전\"이라는 주장에 예외가 있다."
  echo "     실제 앱(논블로킹 connect + epoll)은 인터넷 RTT 동안 이 상태에 머문다."
else
  echo "  ✅ SYN_SENT도 dump 통과 → 클라이언트 측에는 정말 위험한 창이 없다."
  RRC_IMG="$CELL/img"
  "$CRIU" restore -d -D "$RRC_IMG" -v4 -o restore.log "${OPTS[@]}" >/dev/null 2>&1
  echo "     restore_rc=$?  (복원 후 연결이 어떻게 되는지도 확인 필요)"
  pkill -9 -f /tmp/synsent 2>/dev/null
fi
echo "  로그: $CELL/img/dump.log"
