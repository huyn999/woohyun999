/* pbsprobe/pbs_probe.c — 검증 클라이언트 (runner/cprobe.c의 확장판)
 *
 * usage: pbs_probe <host> <port> <timeout_ms> [CMD]
 *   CMD 기본 PING. PING|STAT|TCPQ (5바이트 프레이밍, 개행 자동).
 *   응답 첫 줄을 stdout에 출력. 응답 수신 시 exit 0, 실패 시 exit 1.
 *
 * cprobe와 마찬가지로 static 빌드 대상 — 측정 창 안 스폰 비용 최소화 원칙을
 * 따르되, pbsprobe는 판정 전용(시간 측정 아님)이라 창 불변식 대상은 아니다.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s <host> <port> <timeout_ms> [PING|STAT|TCPQ]\n", argv[0]);
		return 2;
	}
	const char *host = argv[1];
	int port = atoi(argv[2]);
	int tmo = atoi(argv[3]);
	const char *cmd = argc > 4 ? argv[4] : "PING";

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return 1;
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, host, &a.sin_addr) != 1)
		return 2;

	struct timeval tv = { tmo / 1000, (tmo % 1000) * 1000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0)
		return 1;

	char req[8];
	int L = snprintf(req, sizeof(req), "%s\n", cmd);
	if (L != 5 || write(fd, req, 5) != 5)   /* 5바이트 프레이밍 강제 */
		return 1;

	char buf[256];
	size_t got = 0;
	while (got < sizeof(buf) - 1) {
		ssize_t r = read(fd, buf + got, sizeof(buf) - 1 - got);
		if (r <= 0)
			break;
		got += (size_t)r;
		if (memchr(buf, '\n', got))
			break;
	}
	close(fd);
	if (got == 0)
		return 1;
	buf[got] = 0;
	char *nl = strchr(buf, '\n');
	if (nl)
		*nl = 0;
	printf("%s\n", buf);
	return 0;
}
