/* workloads/common/probe_server.h — 계약 §4-A6 핑퐁 서버 (전 워크로드 공용)
 * PONG은 고정 비용("PONG\n" 5바이트) — 가변 작업 싣기 금지 (스펙 §6-6).
 * 첫 요청 처리 직후 PHASE served_first를 자동 발행한다 (warm dump 의미론, §4-A6). */
#ifndef PROBE_SERVER_H
#define PROBE_SERVER_H
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int probe_served_first_ = 0;

/* 127.0.0.1:<port>에 listen. port==0이면 커널 배정, *out_port에 실제 포트. 실패 시 exit(1). */
static int probe_listen(int port, int *out_port)
{
	signal(SIGPIPE, SIG_IGN);   /* write(PONG) 재시도/부분전송 추가 대비 예방적 방어 */
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) { perror("probe_listen: socket"); exit(1); }
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("probe_listen: bind"); exit(1); }
	if (listen(fd, 8) < 0) { perror("probe_listen: listen"); exit(1); }
	socklen_t len = sizeof(a);
	if (getsockname(fd, (struct sockaddr *)&a, &len) < 0) { perror("probe_listen: getsockname"); exit(1); }
	if (out_port)
		*out_port = ntohs(a.sin_port);
	return fd;
}

/* 최대 1개 대기 연결을 서비스: "PING"이면 "PONG\n" 응답 후 close.
 * timeout_ms 동안 연결 없으면 0 반환. 서비스했으면 1.
 * dump 시점에 established 연결이 남지 않도록 요청당 즉시 close (계약 §4-A4).
 * served_first는 "PONG\n" 5바이트 write가 성공(반환값 5)한 요청에서만 발행한다 —
 * 빈 연결/garbage/분할되다 만 PING으로는 발행되지 않음. */
static int probe_serve_pending(int lfd, int timeout_ms)
{
	struct pollfd p = { .fd = lfd, .events = POLLIN };
	int r = poll(&p, 1, timeout_ms);
	if (r <= 0)
		return 0;
	int c = accept(lfd, NULL, NULL);
	if (c < 0) {
		struct timespec ts = { .tv_sec = 0, .tv_nsec = 10L * 1000 * 1000 };
		nanosleep(&ts, NULL);   /* EMFILE/ENFILE 등 즉시-재실패 busy-spin 방지 */
		return 0;
	}
	/* 누적 read가 블로킹이므로, "PI"만 보내고 연결을 유지하는 클라이언트가 serve 루프를
	 * wedge하지 못하게 accept 소켓에 짧은 recv 타임아웃(200ms)을 건다 — 타임아웃 시 n<0 →
	 * break → 미완성으로 close, served_first 미발행 (기존 의미 유지). 연결당 상수 비용(µs)
	 * 1회라 PONG 고정비용(§6-6)에 영향 없음. */
	struct timeval rtv = { 0, 200000 };
	setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
	/* "PING\n" 5바이트(계약 §4-A6 프레이밍 — cprobe/warm-up이 보내는 요청 전체)를 분할 패킷
	 * 허용하며 누적 수신. 4바이트("PING")만 읽고 close하면 미수신 1바이트('\n') 탓에 커널이
	 * FIN 대신 RST로 닫아(close-with-unread-data), PONG 전달이 "RST 전에 큐에 쌓인 데이터는
	 * 먼저 읽힌다"는 리눅스 구현 세부에 기대게 된다 — 요청을 끝까지 소비해 정상 FIN으로 닫는다. */
	char buf[5];
	size_t got = 0;
	while (got < sizeof(buf)) {
		ssize_t n = read(c, buf + got, sizeof(buf) - got);
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	if (got == sizeof(buf) && strncmp(buf, "PING\n", 5) == 0) {
		if (write(c, "PONG\n", 5) == 5 && !probe_served_first_) {   /* 불변식 §6-6: 재시도 루프 금지, 1회 write */
			probe_served_first_ = 1;
			printf("PHASE served_first\n");
			fflush(stdout);   /* 계약 §4-A2 fflush 의무 */
		}
	}
	close(c);
	return 1;
}
#endif
