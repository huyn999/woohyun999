/* webosprobe/xpeer.c — 외부 피어 (덤프 집합 밖에 사는 프로세스)
 *
 * criu_x.sh 의 heredoc 에서 추출. xmatrix/capture 실험이 셀마다 워크로드보다 먼저
 * 띄우며, criu dump -t <워크로드> 의 트리에 들어가지 않는다("경계 밖 상대").
 *
 *   --port N      UNIX 추상 "criuprobe_xpeer_p<N>", TCP 포트 N+3000 을 listen.
 *   --no-accept   listen 만 하고 accept 하지 않음 → 연결이 백로그에 걸린 채 방치
 *                 (= 등록/수립 진행 창; 상대가 아직 accept 안 한 상태를 재현).
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
