/* runner/cprobe.c — 경량 first-response 프로브 (request_probe.py의 C 대체).
 *
 * loopback TCP로 "PING\n"을 보내고 "PONG..." 응답을 확인한다. 한 번만 시도:
 *   성공(PONG) → 응답 라인을 stdout에 찍고 exit 0
 *   실패(연결거부/타임아웃/형식불일치) → exit 1 (러너 폴링 루프가 재시도)
 *
 * python 대체 이유: 인터프리터 스폰(cold-cache 20~200ms, memcg 압박 하 수백 ms)을 없애
 *   측정 창이 "진짜 첫 응답(connect+RTT)"만 담게 한다. static 빌드로 동적 링커 fault도 제거.
 *
 * 사용: cprobe <host> <port> [timeout_ms]
 * 빌드: gcc -O2 -static -o cprobe cprobe.c   (testbed/bootstrap.sh가 빌드 — 산출물은 gitignore)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc != 3 && argc != 4) {
		fprintf(stderr, "usage: %s <host> <port> [timeout_ms>0]\n", argv[0]);
		return 2;
	}
	const char *host = argv[1];
	int port = atoi(argv[2]);
	int timeout_ms = (argc == 4) ? atoi(argv[3]) : 300;
	if (port <= 0) { fprintf(stderr, "cprobe: bad port\n"); return 2; }
	if (timeout_ms <= 0) { fprintf(stderr, "cprobe: timeout_ms must be > 0 (0 means infinite SO_RCVTIMEO wait, not \"no timeout\")\n"); return 2; }

	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) { perror("socket"); return 1; }

	struct timeval tv;
	tv.tv_sec = timeout_ms / 1000;
	tv.tv_usec = (timeout_ms % 1000) * 1000;
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)port);
	if (inet_pton(AF_INET, host, &a.sin_addr) != 1) { fprintf(stderr, "cprobe: bad host\n"); close(s); return 2; }

	if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return 1; }  /* refused/timeout → 재시도 */
	if (send(s, "PING\n", 5, 0) != 5) { close(s); return 1; }

	char buf[256];
	ssize_t n = recv(s, buf, sizeof buf - 1, 0);
	close(s);
	if (n <= 0) return 1;
	buf[n] = '\0';
	if (n < 5 || memcmp(buf, "PONG\n", 5) != 0) { fprintf(stderr, "cprobe: unexpected: %s\n", buf); return 1; }

	/* 개행 정리 후 한 줄 출력 (request_probe.py와 동일 포맷) */
	char *nl = strchr(buf, '\n');
	if (nl) *nl = '\0';
	printf("%s\n", buf);
	return 0;
}
