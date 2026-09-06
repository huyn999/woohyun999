/*
 * webos_probe.c — CRIU TCP 연결-생존 단일 워크로드 (통합판)
 *
 * 흩어져 있던 5개 실험 스크립트(criu_x3/x4/x5/x7/x8)가 각자 /tmp에 풀어놓던
 * 워크로드 C(synsent.c / ss2.c / cl.c / rd.c / c8.c)를 하나로 합쳤다.
 * 모두 "TCP 클라이언트 소켓이 freeze(dump) → 정지 → restore를 넘어 정말 살아
 * 있는가"를 점층적으로 검증하는 같은 계열이라, --mode 하나로 고른다.
 *
 * 이 프로세스가 곧 criu dump -t <pid> 의 대상(덤프 트리)이다. 상대편 서버/피어는
 * 항상 별도 프로세스(덤프 밖) — probe_sweep.sh 의 파이썬 서버 또는 xpeer.
 *
 * ── 모드 (괄호 = 이식원) ─────────────────────────────────────────────────────
 *   syn_sent        (criu_x3/synsent.c)  논블로킹 connect로 SYN_SENT에 붙잡아 둔다.
 *                                          핸드셰이크가 진행 중인 소켓을 dump할 수 있나?
 *   syn_sent_epoll  (criu_x4/ss2.c)       위 + epoll로 연결 완료를 기다린다. 복원·방화벽
 *                                          해제 후 SYN 재전송이 통과해 CONNECTED 되는가?
 *   idle_client     (criu_x5/cl.c)        성립된 연결. 정지 후 write("ping")+read로
 *                                          연결이 살았는지 본다(ALIVE/DEAD).
 *   stream_reader   (criu_x7/rd.c)        계속 recv하는 스트리밍 앱. 복원 후 SO_ERROR·
 *                                          read·write 각각을 확인.
 *   pingpong        (criu_x8/c8.c)        스트리밍 + 복원 후 PING→PONG 왕복(round-trip)
 *                                          까지 확인 — write 성공만으론 생존 증거가 아니다.
 *
 * ── 생애주기 계약 (testbed/workloads 계약과 동일 정신) ───────────────────────
 *   · 상태 전이마다 stdout에 한 줄 + 즉시 fflush (러너가 grep 폴링으로 관측).
 *   · 안정 지점에서 `PHASE <name> ...` 를 찍는다 — dump는 이 지점 도달 직후 일어난다.
 *   · 정지가 끝났음을 알리는 신호는 --resume-file 의 "존재"다(러너가 touch).
 *     복원된 프로세스는 그 파일이 생길 때까지 정지 지점에서 스핀한다.
 *
 * ── 사용법 ───────────────────────────────────────────────────────────────────
 *   webos_probe --mode <M> --port <N> [--resume-file <PATH>]
 *     --port         상대(서버/피어)가 듣고 있는 loopback TCP 포트. (필수)
 *     --resume-file  "정지 해제" 신호 파일. 기본 /tmp/webos_probe_go.
 *     --resume-file 은 idle_client/stream_reader/pingpong 에서만 의미가 있다.
 *
 * 빌드: gcc -O2 -Wall -o webos_probe webos_probe.c   (build.sh 가 자동으로 함)
 */
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

static const char *DEFAULT_RESUME_FILE = "/tmp/webos_probe_go";

static void die(const char *m)
{
	perror(m);
	exit(1);
}

static void sleep_ms(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* loopback TCP 소켓을 만들고 127.0.0.1:<port> 로 connect 를 건다.
 * nonblock=1 이면 O_NONBLOCK 을 먼저 걸어 connect 가 EINPROGRESS 로 즉시 리턴한다
 * (= SYN_SENT 창을 관측 가능하게 벌린다). *out_errno 에 connect 직후 errno 를 남긴다. */
static int connect_loopback(int port, int nonblock, int *out_errno)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		die("socket");
	if (nonblock)
		fcntl(fd, F_SETFL, O_NONBLOCK);

	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);

	int r = connect(fd, (struct sockaddr *)&a, sizeof(a));
	if (out_errno)
		*out_errno = errno;
	if (r < 0 && !(nonblock && errno == EINPROGRESS))
		die("connect");
	return fd;
}

/* 정지 지점 — resume_file 이 나타날 때까지 스핀한다. 복원된 프로세스는 dump 당시
 * 바로 이 루프 안에 있었고, 러너가 restore 후 파일을 touch 하면 빠져나온다. */
static void wait_resume(const char *resume_file)
{
	while (access(resume_file, F_OK) != 0)
		sleep_ms(100);
}

/* fd 를 확실히 블로킹으로 되돌리고 send/recv 타임아웃을 건다(복원 후 검증용). */
static void make_blocking_with_timeout(int fd, int seconds)
{
	int fl = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);
	struct timeval tv = { seconds, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static void report_so_error(int fd)
{
	int soerr = 0;
	socklen_t sl = sizeof(soerr);
	getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
	printf("SO_ERROR=%d (%s)\n", soerr, soerr ? strerror(soerr) : "no error");
	fflush(stdout);
}

/* ── 모드 1: syn_sent (criu_x3/synsent.c) ────────────────────────────────────
 * 논블로킹 connect 로 소켓을 SYN_SENT 에 붙잡아 둔 채 정지. 상대 포트로 가는 SYN 은
 * 러너가 iptables 로 DROP 하므로 응답이 영원히 오지 않는다 = 창이 무한히 열린다. */
static int mode_syn_sent(int port)
{
	int e = 0;
	int fd = connect_loopback(port, 1, &e);
	printf("PHASE syn_sent fd=%d errno=%d(EINPROGRESS=%d) port=%d\n", fd, e, EINPROGRESS, port);
	fflush(stdout);
	for (;;)
		sleep_ms(1000); /* 창을 붙잡아 둔다 (dump 대상) */
	return 0;
}

/* ── 모드 2: syn_sent_epoll (criu_x4/ss2.c) ──────────────────────────────────
 * 논블로킹 connect + epoll(EPOLLOUT) — 실제 스트리밍 앱/브라우저 방식. 복원 후 러너가
 * 방화벽을 풀면 커널이 SYN 을 재전송(1s,2s,4s…)한다. 소켓이 살아 있으면 연결이 성사돼
 * CONNECTED, 커널이 버렸으면 아무 일도 없거나 FAILED. */
static int mode_syn_sent_epoll(int port)
{
	int fd = connect_loopback(port, 1, NULL);
	printf("PHASE syn_sent port=%d\n", port);
	fflush(stdout);

	int ep = epoll_create1(0);
	struct epoll_event ev = { .events = EPOLLOUT, .data.fd = fd };
	epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
	for (;;) { /* 실제 앱처럼 연결 완료를 기다린다 (dump 는 이 대기 중에 일어난다) */
		struct epoll_event out[1];
		int n = epoll_wait(ep, out, 1, 1000);
		if (n > 0) {
			int err = 0;
			socklen_t el = sizeof(err);
			getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
			if (err == 0)
				printf("CONNECTED — 연결 성사\n");
			else
				printf("FAILED — errno=%d (%s)\n", err, strerror(err));
			fflush(stdout);
			break;
		}
	}
	for (;;)
		sleep_ms(1000);
	return 0;
}

/* ── 모드 3: idle_client (criu_x5/cl.c) ──────────────────────────────────────
 * 성립된 연결에 "hello" 를 보내고 조용히 정지. recv 를 안 하므로 수신 윈도우가 0 →
 * 흐름 제어가 서버 송신을 멈춘다. 복원 후 write("ping")+read 로 연결 생존을 본다. */
static int mode_idle_client(int port, const char *resume_file)
{
	int fd = connect_loopback(port, 0, NULL);
	if (write(fd, "hello\n", 6) != 6)
		die("write");
	printf("PHASE ready port=%d\n", port); /* = 이전 스크립트의 READY */
	printf("READY\n");
	fflush(stdout);

	wait_resume(resume_file); /* 여기서 얼린다. 복원되면 아래가 이어진다. */

	if (write(fd, "ping\n", 5) != 5) {
		printf("DEAD_WRITE errno=%d (%s)\n", errno, strerror(errno));
		fflush(stdout);
		return 0;
	}
	char buf[64];
	struct timeval tv = { 5, 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	int n = read(fd, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = 0;
		printf("ALIVE got=%s", buf);
	} else if (n == 0) {
		printf("DEAD_EOF (상대가 닫았다)\n");
	} else {
		printf("DEAD_READ errno=%d (%s)\n", errno, strerror(errno));
	}
	fflush(stdout);
	return 0;
}

/* ── 모드 4: stream_reader (criu_x7/rd.c) ────────────────────────────────────
 * 계속 recv 하는 스트리밍 앱. 수신 윈도우가 열려 있어 얼려 있는 동안에도 서버 패킷이
 * 도착한다 → iptables 로 막지 않으면 커널이 RST 를 보낼 수 있다. 복원 후 SO_ERROR /
 * read / write 를 각각 확인한다(왕복까지는 안 봄 — 그건 pingpong 의 몫). */
static int mode_stream_reader(int port, const char *resume_file)
{
	int fd = connect_loopback(port, 0, NULL);
	if (write(fd, "start\n", 6) != 6)
		die("write");
	printf("PHASE ready port=%d\n", port);
	printf("READY\n");
	fflush(stdout);

	char buf[4096];
	long total = 0;
	fcntl(fd, F_SETFL, O_NONBLOCK);
	while (access(resume_file, F_OK) != 0) {
		int n = recv(fd, buf, sizeof(buf), 0);
		if (n > 0)
			total += n;
		else if (n == 0) {
			printf("EOF_WHILE_READING total=%ld\n", total);
			fflush(stdout);
		} else if (errno != EAGAIN && errno != EWOULDBLOCK) {
			printf("READ_ERR errno=%d (%s) total=%ld\n", errno, strerror(errno), total);
			fflush(stdout);
		}
		sleep_ms(20);
	}
	printf("RESUMED total_before=%ld\n", total);
	fflush(stdout);

	make_blocking_with_timeout(fd, 8);
	report_so_error(fd);

	int n = recv(fd, buf, sizeof(buf) - 1, 0);
	if (n > 0)
		printf("ALIVE_READ  (%d bytes 수신 — 서버가 여전히 보내고 있다)\n", n);
	else if (n == 0)
		printf("DEAD_EOF  (상대가 닫았다)\n");
	else
		printf("READ_FAIL errno=%d (%s)\n", errno, strerror(errno));
	fflush(stdout);

	if (write(fd, "ping\n", 5) != 5)
		printf("WRITE_FAIL errno=%d (%s)\n", errno, strerror(errno));
	else
		printf("WRITE_OK\n");
	fflush(stdout);
	return 0;
}

/* ── 모드 5: pingpong (criu_x8/c8.c) ─────────────────────────────────────────
 * stream_reader 의 엄밀판. 복원 후 밀린 데이터를 비우고(DRAINED), PING 을 보내
 * PONG 이 실제로 돌아오는지(왕복) 확인한다. write() 성공은 커널 버퍼에 넣기만 해도
 * 나므로 생존 증거가 못 된다 — 왕복만이 증거다. */
static int mode_pingpong(int port, const char *resume_file)
{
	int fd = connect_loopback(port, 0, NULL);
	if (write(fd, "start\n", 6) != 6)
		die("write");
	printf("PHASE ready port=%d\n", port);
	printf("READY\n");
	fflush(stdout);

	char buf[8192];
	long total = 0;
	fcntl(fd, F_SETFL, O_NONBLOCK);
	while (access(resume_file, F_OK) != 0) {
		int n = recv(fd, buf, sizeof(buf), 0);
		if (n > 0)
			total += n;
		sleep_ms(10);
	}
	printf("RESUMED  read_before_freeze=%ld\n", total);
	fflush(stdout);

	make_blocking_with_timeout(fd, 8);
	report_so_error(fd);

	/* (1) 얼려 있는 동안 서버가 보낸 게 쌓여 있어야 한다 */
	long drained = 0;
	for (int i = 0; i < 20; i++) {
		int n = recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
		if (n > 0)
			drained += n;
		else
			break;
	}
	printf("DRAINED  after_restore=%ld bytes\n", drained);
	fflush(stdout);

	/* (2) 진짜 검증 — PING 을 보내고 PONG 이 돌아오는가 */
	if (write(fd, "PING\n", 5) != 5) {
		printf("VERDICT=DEAD  write errno=%d (%s)\n", errno, strerror(errno));
		fflush(stdout);
		return 0;
	}
	time_t t0 = time(NULL);
	int found = 0;
	while (time(NULL) - t0 < 8) {
		int n = recv(fd, buf, sizeof(buf) - 1, 0);
		if (n <= 0)
			break;
		buf[n] = 0;
		if (strstr(buf, "PONG")) {
			found = 1;
			break;
		}
	}
	if (found)
		printf("VERDICT=ALIVE  (PING -> PONG 왕복 성공)\n");
	else if (errno == ECONNRESET)
		printf("VERDICT=DEAD  (ECONNRESET — RST를 받았다)\n");
	else
		printf("VERDICT=DEAD  (PONG 미수신, errno=%d %s)\n", errno, strerror(errno));
	fflush(stdout);
	return 0;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
	        "usage: %s --mode <M> --port <N> [--resume-file <PATH>]\n"
	        "  modes: syn_sent | syn_sent_epoll | idle_client | stream_reader | pingpong\n",
	        argv0);
}

int main(int argc, char **argv)
{
	const char *mode = NULL;
	const char *resume_file = DEFAULT_RESUME_FILE;
	int port = -1;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--mode") && i + 1 < argc)
			mode = argv[++i];
		else if (!strcmp(argv[i], "--port") && i + 1 < argc)
			port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--resume-file") && i + 1 < argc)
			resume_file = argv[++i];
		else {
			fprintf(stderr, "unknown arg: %s\n", argv[i]);
			usage(argv[0]);
			return 2;
		}
	}
	if (!mode || port < 0) {
		usage(argv[0]);
		return 2;
	}

	if (!strcmp(mode, "syn_sent"))
		return mode_syn_sent(port);
	if (!strcmp(mode, "syn_sent_epoll"))
		return mode_syn_sent_epoll(port);
	if (!strcmp(mode, "idle_client"))
		return mode_idle_client(port, resume_file);
	if (!strcmp(mode, "stream_reader"))
		return mode_stream_reader(port, resume_file);
	if (!strcmp(mode, "pingpong"))
		return mode_pingpong(port, resume_file);

	fprintf(stderr, "invalid mode: %s\n", mode);
	usage(argv[0]);
	return 2;
}
