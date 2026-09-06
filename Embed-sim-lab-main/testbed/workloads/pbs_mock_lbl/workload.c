/* testbed/workloads/pbs_mock/workload.c — webOS pbs(EPG 배너 서비스) 상세 모사
 *
 * 실제 pbs: 화면 하단 배너에서 채널 DB를 파싱해 "이 시간대 이 채널은 이 방송"을
 * 텍스트로 보여주는 서비스. 이 워크로드는 그 생애주기를 자원 단위로 재현한다:
 *
 *   [기동]  DB 파일 open → 스트리밍 read(io) → 파싱·해시(compute) → 편성 인덱스
 *           구축 + EPG 텍스트 캐시(anon mem, touched) → (선택) 지연 캐시 예약
 *           (malloc-untouched — 침묵형 OOM 탐침) → Luna hub 접속 N개(UNIX,
 *           register/ack + 미수신 notify queue) → subscribe → (선택) TCP feed
 *           접속(reqresp|stream) → timerfd(분 단위 배너 시계) → inotify(DB 갱신
 *           감시) → ready
 *   [상시]  핑퐁 서비스 + 주기 refresh(배너 재렌더: dirty page + 소량 compute,
 *           reserve 영역 점진 touch) + hub 생존 감시/재접속 + feed 수신
 *
 * 계약 v2 (testbed/workloads/README.md) 준수:
 *   A1 named flags (common/flags.h)
 *   A2 PHASE + fflush — setup의 문장 경계마다 발행 (failprobe line 계측과 동형)
 *   A3 일은 작업 단위(parse_iters)로 정의, 시간(parse_ms)은 측정해 보고
 *   A5 SIGTERM 기본 종료
 *   A6 핑퐁: PING\n → PONG\n 5바이트 고정, 첫 성공 시 PHASE served_first.
 *      (probe_server.h를 쓰지 않고 동일 프레이밍으로 직접 구현 — STAT/TCPQ
 *       검증 채널이 추가로 필요해서. 계약은 행동 규약이므로 허용, README B절.)
 *   A4는 탐침 목적상 의도적 위반 (hub/tcp/timerfd/inotify fd — 그것이 실험 대상).
 *
 * 검증 채널 (측정 창 밖 전용 — PONG 고정비용 불변식 §6-6과 분리):
 *   "STAT\n" → "STAT crc=<8hex> slot=<n> hub=<alive>/<total> rereg=<n>
 *               res=<touched_kib> up_ms=<n>\n"
 *     crc  : 편성 인덱스 메모리 FNV-1a — restore 전후 비교로 상태 무결성 판정
 *     slot : 현재 시간대 슬롯 번호 — "지금 뭐 하는지"를 답할 수 있는가(기능 판정)
 *   "TCPQ\n" → "TCPR mode=<m> ok=<0|1> rx=<bytes>\n"
 *     reqresp: 즉석 왕복 1회 결과 / stream: 누적 수신 바이트(두 번 찍어 증가 확인)
 *
 * disconnect & re-register 처방 (발표 슬라이드 7의 대안 실측용):
 *   SIGUSR1        → hub fd 전부 close, PHASE hub_disconnected closed=N, 재접속 보류
 *   --resume_file  → 파일이 생기면 보류 해제, 재접속+재등록,
 *                    PHASE hub_reregistered ms=<소요> conns=<n> (connprobe 규약 재사용)
 *   --hub_reconnect 1 이면 hub가 죽었을 때(HUP)도 자동 재접속 (실서비스 동작)
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include "flags.h"

#define PHASE(...) do { printf("PHASE " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define MAX_HUB 8

static void die(const char *m) { perror(m); exit(1); }

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static void phase_gap(long ms)
{
	if (ms <= 0)
		return;
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* ── 전역 상태 ─────────────────────────────────────────────────────────── */
static int g_port;
static int g_hub_port;                              /* 외부 세계 주소의 기준 포트.
                                                       기본 = 자기 port. world 모드에선
                                                       공유 world hub의 포트를 가리킴 */
static long g_channels, g_slots;
static char *g_index; static size_t g_index_n;      /* 편성 인덱스 + EPG 텍스트 (touched) */
static char *g_reserve; static size_t g_reserve_n;  /* 지연 캐시 (untouched — 침묵형 OOM 탐침) */
static size_t g_reserve_touched;                    /* refresh가 점진 touch한 양 */
static int g_hubfd[MAX_HUB]; static int g_hub_total, g_hub_alive;
static int g_selfhub_peer[MAX_HUB];                 /* selfhub(Batch A) 모드의 반대편 소켓 */
static int g_selfhub;
static long g_hub_pending;
static int g_rereg_count;                           /* restore 후 재등록 성공 횟수 */
static int g_tcpfd = -1; static const char *g_tcp_mode; static long g_tcp_rx;
static volatile sig_atomic_t g_bye;                 /* SIGUSR1: 처방 — hub 연결 해제 */
static int g_hub_hold;                              /* 해제 후 재접속 보류 (resume_file 대기) */
static const char *g_resume_file;
static int g_served_first;
static char g_dbpath[128];

/* ── 확장 자원 (실기 pbs가 가질 법한 후보들 — F 가족 실험 대상) ─────────── */
static long g_thr_ticks;                            /* 워커 스레드 진행 카운터 (STAT thr=) */
static int g_efd = -1;                              /* eventfd (GLib mainloop wakeup 모형) */
static int g_pipe[2] = { -1, -1 };                  /* self-pipe (전통적 wakeup 모형) */
static char *g_shm; static size_t g_shm_n;          /* POSIX shm 배너 버퍼 (surface 모형) */
static char g_shm_name[64];
static int g_logfd = -1;                            /* PmLog 모형: 외부 DGRAM UNIX 소켓 */
static int g_renderfd = -1;                         /* 렌더 채널 모형: 별도 외부 STREAM */
static long g_use_log, g_use_render, g_flood_name;
static pid_t g_child = -1, g_zombie = -1;           /* 헬퍼 자식 / 미수거 좀비 */
static long g_sigpend;                              /* USR2 블록+보류 유지 */
static long g_db_events;                            /* inotify 수신 누계 */

static char child_state(pid_t p)                    /* /proc/<p>/stat 3열: R/S/Z.. */
{
	if (p <= 0)
		return '-';
	char path[64], buf[256];
	snprintf(path, sizeof(path), "/proc/%d/stat", p);
	int f = open(path, O_RDONLY);
	if (f < 0)
		return 'X';
	ssize_t r = read(f, buf, sizeof(buf) - 1);
	close(f);
	if (r <= 0)
		return 'X';
	buf[r] = 0;
	char *rp = strrchr(buf, ')');
	return (rp && rp[1] == ' ') ? rp[2] : 'X';
}

static void *worker_thread(void *arg)
{
	(void)arg;                                      /* 파싱 보조 워커: 주기적 경량 연산 */
	for (;;) {
		struct timespec ts = { 0, 50L * 1000 * 1000 };
		nanosleep(&ts, NULL);
		__atomic_add_fetch(&g_thr_ticks, 1, __ATOMIC_RELAXED);
	}
	return NULL;
}

static int log_connect(void)                        /* PmLog 모형: connected DGRAM */
{
	int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (fd < 0)
		return -1;
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	snprintf(a.sun_path + 1, sizeof(a.sun_path) - 2, "pbsprobe_log_p%d", g_hub_port);
	socklen_t al = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(a.sun_path + 1));
	if (connect(fd, (struct sockaddr *)&a, al) < 0) {
		close(fd);
		return -1;
	}
	ssize_t w = send(fd, "LOG start\n", 10, MSG_DONTWAIT);
	(void)w;
	return fd;
}

static int render_connect(void)                     /* 렌더/서피스 모형: hub와 별개 STREAM */
{
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	snprintf(a.sun_path + 1, sizeof(a.sun_path) - 2, "pbsprobe_render_p%d", g_hub_port);
	socklen_t al = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(a.sun_path + 1));
	if (connect(fd, (struct sockaddr *)&a, al) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

/* ── FNV-1a: 편성 인덱스 무결성 crc ─────────────────────────────────────── */
static uint32_t fnv1a(const char *p, size_t n)
{
	uint32_t h = 2166136261u;
	for (size_t i = 0; i < n; i++) {
		h ^= (uint8_t)p[i];
		h *= 16777619u;
	}
	return h;
}

static uint32_t sched_crc(void)
{
	if (!g_index)
		return 0;
	size_t n = g_index_n < (1u << 20) ? g_index_n : (1u << 20);
	return fnv1a(g_index, n);
}

/* 현재 슬롯: 가상 방송 시계 — 실제 시각을 슬롯 폭으로 나눈 값 (배너의 "지금") */
static int cur_slot(void)
{
	time_t t = time(NULL);
	long slot_s = 86400 / (g_slots > 0 ? g_slots : 48);
	return (int)((t % 86400) / (slot_s > 0 ? slot_s : 1800));
}

/* ── Luna hub 연결: connect → REG → ACK 대기 (외부 hub = pbsprobe/pbs_hub) ── */
static int hub_connect_one(int k)
{
	if (g_selfhub) {
		/* Batch A 대조군: 연결의 양쪽을 같은 프로세스가 소유 (발표 5장) */
		int sp[2];
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) < 0)
			return -1;
		/* 미수신 notify 재현: 반대편이 보내고 이쪽이 안 읽음 */
		for (long m = 0; m < g_hub_pending; m++) {
			char msg[64];
			int L = snprintf(msg, sizeof(msg), "{\"notify\":\"chg\",\"seq\":%ld}\n", m);
			if (write(sp[1], msg, L) != L)
				break;
		}
		g_selfhub_peer[k] = sp[1];
		return sp[0];
	}
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	struct sockaddr_un a;
	memset(&a, 0, sizeof(a));
	a.sun_family = AF_UNIX;
	snprintf(a.sun_path + 1, sizeof(a.sun_path) - 2, "pbsprobe_hub_p%d", g_hub_port);
	socklen_t al = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(a.sun_path + 1));
	if (connect(fd, (struct sockaddr *)&a, al) < 0) {
		close(fd);
		return -1;
	}
	char reg[64];
	int L = snprintf(reg, sizeof(reg), "REG com.webos.pbs%s.%d\n",
			 g_flood_name ? ".flood" : "", k);
	if (write(fd, reg, L) != L) {
		close(fd);
		return -1;
	}
	/* ACK 대기 (hub가 no-accept 모드면 안 옴 → 짧게 포기하고 '대기열 연결'로 유지
	 * — 발표 6장의 "connect는 됐지만 accept 전" 케이스가 정확히 이 상태) */
	struct pollfd p = { .fd = fd, .events = POLLIN };
	if (poll(&p, 1, 300) > 0 && (p.revents & POLLIN)) {
		char ack[32];
		ssize_t r = read(fd, ack, sizeof(ack));
		(void)r;   /* ack 내용은 신뢰 판단에만 사용, 미수신도 연결은 유지 */
	}
	return fd;
}

static void hub_close_all(void)
{
	int n = 0, xr = 0, xl = 0;
	for (int k = 0; k < g_hub_total; k++) {
		if (g_hubfd[k] >= 0) {
			close(g_hubfd[k]);
			g_hubfd[k] = -1;
			n++;
		}
		if (g_selfhub && g_selfhub_peer[k] >= 0) {
			close(g_selfhub_peer[k]);
			g_selfhub_peer[k] = -1;
		}
	}
	if (g_renderfd >= 0) { close(g_renderfd); g_renderfd = -1; xr = 1; }
	if (g_logfd >= 0)    { close(g_logfd);    g_logfd = -1;    xl = 1; }
	g_hub_alive = 0;
	PHASE("hub_disconnected closed=%d render=%d log=%d", n, xr, xl);
}

static void hub_reconnect_all(void)
{
	long t0 = now_ms();
	int ok = 0;
	for (int k = 0; k < g_hub_total; k++) {
		if (g_hubfd[k] >= 0)
			continue;
		g_hubfd[k] = hub_connect_one(k);
		if (g_hubfd[k] >= 0)
			ok++;
	}
	if (g_use_render && g_renderfd < 0) g_renderfd = render_connect();
	if (g_use_log && g_logfd < 0)       g_logfd = log_connect();
	g_hub_alive = 0;
	for (int k = 0; k < g_hub_total; k++)
		if (g_hubfd[k] >= 0)
			g_hub_alive++;
	if (ok > 0 || (g_use_render && g_renderfd >= 0) || (g_use_log && g_logfd >= 0)) {
		g_rereg_count += ok;
		PHASE("hub_reregistered ms=%ld conns=%d alive=%d render=%d log=%d",
		      now_ms() - t0, ok, g_hub_alive, g_renderfd >= 0, g_logfd >= 0);
	}
}

/* ── TCP feed (127.0.0.1:port+3000, pbsprobe/pbs_hub --feed) ───────────── */
static int tcp_connect_feed(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)(g_hub_port + 3000));
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
		close(fd);
		return -1;
	}
	if (strcmp(g_tcp_mode, "stream") == 0) {
		/* 구독 개시를 알리고 이후 서버가 미는 조각을 논블로킹 수신 */
		if (write(fd, "SUBSCRIBE epg\n", 14) != 14) { close(fd); return -1; }
		int fl = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, fl | O_NONBLOCK);
	}
	return fd;
}

static int tcp_roundtrip(char *out, size_t outn)   /* TCPQ 응답 본문 생성 */
{
	if (g_tcpfd < 0)
		return snprintf(out, outn, "TCPR mode=%s ok=0 rx=%ld\n", g_tcp_mode, g_tcp_rx);
	if (strcmp(g_tcp_mode, "reqresp") == 0) {
		int ok = 0;
		if (write(g_tcpfd, "REQ now\n", 8) == 8) {
			struct pollfd p = { .fd = g_tcpfd, .events = POLLIN };
			if (poll(&p, 1, 1500) > 0 && (p.revents & POLLIN)) {
				char buf[256];
				ssize_t r = read(g_tcpfd, buf, sizeof(buf));
				if (r > 0) { ok = 1; g_tcp_rx += r; }
			}
		}
		if (!ok) { close(g_tcpfd); g_tcpfd = -1; }   /* 시체 fd는 정직하게 폐기 */
		return snprintf(out, outn, "TCPR mode=reqresp ok=%d rx=%ld\n", ok, g_tcp_rx);
	}
	/* stream: 수신 진행량 보고 — 호출 측이 두 번 찍어 증가를 확인 */
	return snprintf(out, outn, "TCPR mode=stream ok=%d rx=%ld\n", g_tcpfd >= 0, g_tcp_rx);
}

/* ── 서비스: PING/STAT/TCPQ (요청당 accept→응답→close, A4 정신 유지) ────── */
static int serve_listen(int port, int *out_port)
{
	signal(SIGPIPE, SIG_IGN);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		die("serve socket");
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0)
		die("serve bind");
	if (listen(fd, 8) < 0)
		die("serve listen");
	socklen_t len = sizeof(a);
	getsockname(fd, (struct sockaddr *)&a, &len);
	if (out_port)
		*out_port = ntohs(a.sin_port);
	return fd;
}

static long g_t0;
static int serve_pending(int lfd, int timeout_ms)
{
	struct pollfd p = { .fd = lfd, .events = POLLIN };
	if (poll(&p, 1, timeout_ms) <= 0)
		return 0;
	int c = accept(lfd, NULL, NULL);
	if (c < 0) {
		struct timespec ts = { 0, 10L * 1000 * 1000 };
		nanosleep(&ts, NULL);
		return 0;
	}
	struct timeval rtv = { 0, 200000 };
	setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
	char buf[6] = { 0 };
	size_t got = 0;
	while (got < 5) {   /* 5바이트 프레이밍 — probe_server.h와 동일 근거 (FIN close) */
		ssize_t n = read(c, buf + got, 5 - got);
		if (n <= 0)
			break;
		got += (size_t)n;
	}
	if (got == 5 && strncmp(buf, "PING\n", 5) == 0) {
		if (write(c, "PONG\n", 5) == 5 && !g_served_first) {
			g_served_first = 1;
			PHASE("served_first");
		}
	} else if (got == 5 && strncmp(buf, "BANR\n", 5) == 0) {
		/* 배너 질의: "지금/다음 방송"을 편성 인덱스 메모리에서 실제로 읽는다.
		 * ID = 해당 슬롯 창(4KiB 보폭 128B)의 FNV — 재계산이 아니라 복원된
		 * 메모리의 바이트에서 파생되므로, 정지 전 'next'가 부활 후 'now'로
		 * 나오면 "미래 편성까지 담긴 인덱스가 통째로 살아왔다"의 증명이 된다 */
		int slot = cur_slot();
		unsigned idn = 0, idx = 0;
		if (g_index && g_index_n > 8192) {
			/* 인덱스 앞부분의 실제 편성 엔트리 영역(슬롯×채널, 16B/엔트리)에서
			 * 해당 슬롯의 채널 행 전체를 해시 — 슬롯 번호가 엔트리 텍스트에
			 * 박혀 있으므로 슬롯마다 고유 ID가 나온다 */
			size_t row = (size_t)g_channels * 16;
			size_t ents_bytes = (size_t)g_channels * (size_t)g_slots * 16;
			if (ents_bytes > g_index_n)
				ents_bytes = g_index_n;
			size_t span = row > 256 ? 256 : row;
			if (ents_bytes > span + row) {
				size_t o1 = ((size_t)slot * row) % (ents_bytes - span);
				size_t o2 = ((size_t)(slot + 1) * row) % (ents_bytes - span);
				idn = fnv1a(g_index + o1, span);
				idx = fnv1a(g_index + o2, span);
			}
		}
		char out[128];
		int L = snprintf(out, sizeof(out), "BANR slot=%d now=PGM-%08x next=PGM-%08x\n",
				 slot, idn, idx);
		if (write(c, out, L) != L) { /* best effort */ }
	} else if (got == 5 && strncmp(buf, "STAT\n", 5) == 0) {
		/* ev: eventfd write→read 왕복 / log: connected DGRAM send 성공 여부
		 * (수신자 죽었으면 ECONNREFUSED) / shm: 매핑 쓰기 후 재확인 */
		int ev = -1, lg = -1, sh = -1;
		if (g_efd >= 0) {
			uint64_t one = 1, back = 0;
			ev = (write(g_efd, &one, 8) == 8 && read(g_efd, &back, 8) == 8 && back >= 1);
		}
		if (g_use_log)
			lg = (g_logfd >= 0 && send(g_logfd, "LOG stat\n", 9, MSG_DONTWAIT) == 9);
		if (g_shm) {
			g_shm[0] = (char)(g_shm[0] + 1);
			sh = 1;
		}
		int sigp = 0;
		if (g_sigpend) {
			sigset_t ps;
			sigemptyset(&ps);
			if (sigpending(&ps) == 0 && sigismember(&ps, SIGUSR2))
				sigp = 1;
		}
		char out[320];
		int L = snprintf(out, sizeof(out),
				 "STAT crc=%08x slot=%d hub=%d/%d rereg=%d res=%zu thr=%ld ev=%d shm=%d log=%d chld=%c zomb=%c sigp=%d watch=%ld up_ms=%ld\n",
				 sched_crc(), cur_slot(), g_hub_alive, g_hub_total,
				 g_rereg_count, g_reserve_touched >> 10,
				 __atomic_load_n(&g_thr_ticks, __ATOMIC_RELAXED), ev, sh, lg,
				 child_state(g_child), child_state(g_zombie), sigp, g_db_events,
				 now_ms() - g_t0);
		if (write(c, out, L) != L) { /* best effort */ }
	} else if (got == 5 && strncmp(buf, "TCPQ\n", 5) == 0) {
		char out[128];
		int L = tcp_roundtrip(out, sizeof(out));
		if (write(c, out, L) != L) { /* best effort */ }
	}
	close(c);
	return 1;
}

static void on_usr1(int s) { (void)s; g_bye = 1; }

int main(int argc, char **argv)
{
	long port        = wl_flag_long(argc, argv, "--port", 18080);
	long gap_ms      = wl_flag_long(argc, argv, "--phase_gap_ms", 400);
	long lbl_trace   = wl_flag_long(argc, argv, "--lbl", 0);          /* 줄 단위 계측 (자동 생성판) */
	long db_mib      = wl_flag_long(argc, argv, "--db_mib", 8);
	if (lbl_trace) { PHASE("Lsrc_001 ln=474"); phase_gap(gap_ms); }
	g_channels       = wl_flag_long(argc, argv, "--channels", 60);
	if (lbl_trace) { PHASE("Lsrc_002 ln=475"); phase_gap(gap_ms); }
	g_slots          = wl_flag_long(argc, argv, "--slots", 48);
	if (lbl_trace) { PHASE("Lsrc_003 ln=476"); phase_gap(gap_ms); }
	long parse_iters = wl_flag_long(argc, argv, "--parse_iters", 120000);
	if (lbl_trace) { PHASE("Lsrc_004 ln=477"); phase_gap(gap_ms); }
	long index_mib   = wl_flag_long(argc, argv, "--index_mib", 12);
	if (lbl_trace) { PHASE("Lsrc_005 ln=478"); phase_gap(gap_ms); }
	long reserve_mib = wl_flag_long(argc, argv, "--reserve_mib", 0);
	if (lbl_trace) { PHASE("Lsrc_006 ln=479"); phase_gap(gap_ms); }
	long hub_conns   = wl_flag_long(argc, argv, "--hub_conns", 4);
	if (lbl_trace) { PHASE("Lsrc_007 ln=480"); phase_gap(gap_ms); }
	g_hub_pending    = wl_flag_long(argc, argv, "--hub_pending", 2);
	if (lbl_trace) { PHASE("Lsrc_008 ln=481"); phase_gap(gap_ms); }
	long hub_recon   = wl_flag_long(argc, argv, "--hub_reconnect", 1);
	if (lbl_trace) { PHASE("Lsrc_009 ln=482"); phase_gap(gap_ms); }
	g_selfhub        = (int)wl_flag_long(argc, argv, "--selfhub", 0);
	if (lbl_trace) { PHASE("Lsrc_010 ln=483"); phase_gap(gap_ms); }
	g_tcp_mode       = wl_flag_str(argc, argv, "--tcp", "none");
	if (lbl_trace) { PHASE("Lsrc_011 ln=484"); phase_gap(gap_ms); }
	long refresh_ms  = wl_flag_long(argc, argv, "--refresh_ms", 1000);
	if (lbl_trace) { PHASE("Lsrc_012 ln=485"); phase_gap(gap_ms); }
	long refresh_kib = wl_flag_long(argc, argv, "--refresh_kib", 256);
	if (lbl_trace) { PHASE("Lsrc_013 ln=486"); phase_gap(gap_ms); }
	long use_timer   = wl_flag_long(argc, argv, "--timer", 1);
	if (lbl_trace) { PHASE("Lsrc_014 ln=487"); phase_gap(gap_ms); }
	long timer_s     = wl_flag_long(argc, argv, "--timer_s", 60);
	if (lbl_trace) { PHASE("Lsrc_015 ln=488"); phase_gap(gap_ms); }
	long use_watch   = wl_flag_long(argc, argv, "--watch", 1);
	if (lbl_trace) { PHASE("Lsrc_016 ln=489"); phase_gap(gap_ms); }
	long use_mmap    = wl_flag_long(argc, argv, "--mmap_db", 0);
	if (lbl_trace) { PHASE("Lsrc_017 ln=490"); phase_gap(gap_ms); }
	g_resume_file    = wl_flag_str(argc, argv, "--resume_file", "");
	if (lbl_trace) { PHASE("Lsrc_018 ln=491"); phase_gap(gap_ms); }
	long threads     = wl_flag_long(argc, argv, "--threads", 0);       /* 워커 스레드 (≤4) */
	long use_pipe    = wl_flag_long(argc, argv, "--selfpipe", 0);      /* self-pipe wakeup */
	long use_efd     = wl_flag_long(argc, argv, "--eventfd", 0);       /* eventfd wakeup */
	const char *lockm = wl_flag_str(argc, argv, "--db_lock", "none");  /* none|flock|posix */
	long shm_mib     = wl_flag_long(argc, argv, "--shm_mib", 0);       /* POSIX shm 배너 버퍼 */
	g_use_log        = wl_flag_long(argc, argv, "--log_dgram", 0);     /* PmLog형 DGRAM */
	g_use_render     = wl_flag_long(argc, argv, "--render", 0);        /* 렌더 채널 STREAM */
	long use_wd      = wl_flag_long(argc, argv, "--workdir", 0);       /* 전용 cwd로 chdir */
	long hub_port    = wl_flag_long(argc, argv, "--hub_port", 0);      /* 0=자기 port (world 공유용) */
	long use_epoll   = wl_flag_long(argc, argv, "--epoll", 0);         /* GLib mainloop의 epoll fd */
	long use_tmpunl  = wl_flag_long(argc, argv, "--tmpunlink", 0);     /* unlink된 저널 파일 (sqlite) */
	long use_urand   = wl_flag_long(argc, argv, "--urandom", 0);       /* /dev/urandom fd 상시 보유 */
	long tcp_halfcl  = wl_flag_long(argc, argv, "--tcp_halfclose", 0); /* feed에 shutdown(WR) */
	g_flood_name     = wl_flag_long(argc, argv, "--flood_name", 0);   /* 재등록 flood 대상 이름 */
	long use_child   = wl_flag_long(argc, argv, "--child", 0);         /* 헬퍼 자식 (트리 dump) */
	long use_zombie  = wl_flag_long(argc, argv, "--zombie", 0);        /* 미수거 좀비 자식 */
	g_sigpend        = wl_flag_long(argc, argv, "--sigpend", 0);       /* 보류 시그널 유지 */
	long use_ulisten = wl_flag_long(argc, argv, "--unix_listen", 0);   /* 자기 luna 메서드 listen */
	long use_udp     = wl_flag_long(argc, argv, "--udp", 0);           /* UDP (SSDP류) */
	long use_nl      = wl_flag_long(argc, argv, "--netlink", 0);       /* NETLINK_ROUTE (connman류) */
	long substeps    = wl_flag_long(argc, argv, "--substeps", 0);      /* 긴 줄의 25/50/75% 중간 phase */

	g_port = (int)port;
	if (lbl_trace) { PHASE("Lsrc_019 ln=514"); phase_gap(gap_ms); }
	g_hub_port = hub_port > 0 ? (int)hub_port : (int)port;
	if (lbl_trace) { PHASE("Lsrc_020 ln=515"); phase_gap(gap_ms); }
	if (hub_conns > MAX_HUB)
		hub_conns = MAX_HUB;
	for (int k = 0; k < MAX_HUB; k++) {
		g_hubfd[k] = -1;
		g_selfhub_peer[k] = -1;
	}
	signal(SIGUSR1, on_usr1);
	if (lbl_trace) { PHASE("Lsrc_021 ln=522"); phase_gap(gap_ms); }
	g_t0 = now_ms();
	if (lbl_trace) { PHASE("Lsrc_022 ln=523"); phase_gap(gap_ms); }
	PHASE("init pid=%d", getpid());
	phase_gap(gap_ms);

	/* ── 0-. 보류 시그널: USR2를 블록하고 스스로 큐잉 — dump 시점에 '전달 안 된
	 *      시그널'이 있는 프로세스. 복원 후에도 보류가 유지되는지 STAT sigp로 ── */
	if (g_sigpend) {
		sigset_t bs;
		sigemptyset(&bs);
		sigaddset(&bs, SIGUSR2);
		sigprocmask(SIG_BLOCK, &bs, NULL);
		kill(getpid(), SIGUSR2);
		PHASE("sig_pending set=1");
		phase_gap(gap_ms);
	}

	/* ── 0a. /dev/urandom fd 상시 보유 (glib/openssl 초기화 잔류 fd 모형) ── */
	if (use_urand) {
		int uf = open("/dev/urandom", O_RDONLY);
		PHASE("dev_urandom ok=%d", uf >= 0);
		phase_gap(gap_ms);
	}

	/* ── 0. PmLog 모형: 외부 로그 수신자에 connected DGRAM (실기처럼 최우선) ── */
	if (g_use_log) {
		g_logfd = log_connect();
		PHASE("log_open ok=%d", g_logfd >= 0);
		phase_gap(gap_ms);
	}

	/* ── 1. 채널 DB open ── 없으면 결정적 내용으로 자체 생성 (탐침 자급 규약,
	 *      failprobe와 동일). cold 공정성: 측정용으로 쓸 땐 러너가 미리 만들어
	 *      두면 생성 비용이 빠진다. */
	snprintf(g_dbpath, sizeof(g_dbpath), "/tmp/pbsprobe_db_p%d.bin", g_port);
	if (lbl_trace) { PHASE("Lsrc_023 ln=556"); phase_gap(gap_ms); }
	size_t db_n = (size_t)db_mib << 20;
	if (lbl_trace) { PHASE("Lsrc_024 ln=557"); phase_gap(gap_ms); }
	{
		struct stat st;
		if (stat(g_dbpath, &st) != 0 || (size_t)st.st_size != db_n) {
			int wf = open(g_dbpath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
			if (wf < 0)
				die("db create");
			char blk[1 << 16];
			for (size_t i = 0; i < sizeof(blk); i++)
				blk[i] = (char)(i * 131 + 7);   /* 결정적 — crc 재현성 */
			for (size_t off = 0; off < db_n; off += sizeof(blk)) {
				size_t w = db_n - off < sizeof(blk) ? db_n - off : sizeof(blk);
				if (write(wf, blk, w) != (ssize_t)w)
					die("db fill");
			}
			close(wf);
		}
	}
	int dbfd = open(g_dbpath, O_RDONLY);
	if (lbl_trace) { PHASE("Lsrc_025 ln=575"); phase_gap(gap_ms); }
	if (dbfd < 0)
		die("db open");
	PHASE("db_open bytes=%zu", db_n);
	phase_gap(gap_ms);

	/* ── 1b. DB 잠금 (sqlite 모형): flock 또는 POSIX 읽기락 — CRIU는 파일 잠금을
	 *      --file-locks 없이는 거부한다. 잠금 라인이 hub보다 먼저 오므로, 잠금이
	 *      있으면 실패 경계선이 앞으로 당겨지는지가 F 가족의 질문 ── */
	if (strcmp(lockm, "flock_wait") == 0) {
		/* 블로킹 획득: 다른 보유자가 있으면 syscall 안에서 잠든 채 dump된다 */
		int lr = flock(dbfd, LOCK_EX);
		PHASE("db_lock mode=flock_wait ok=%d", lr == 0);
		phase_gap(gap_ms);
	} else if (strcmp(lockm, "flock") == 0) {
		int lr = flock(dbfd, LOCK_EX | LOCK_NB);
		PHASE("db_lock mode=flock ok=%d", lr == 0);
		phase_gap(gap_ms);
	} else if (strcmp(lockm, "posix") == 0) {
		struct flock fl = { .l_type = F_RDLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1 };
		int lr = fcntl(dbfd, F_SETLK, &fl);
		PHASE("db_lock mode=posix ok=%d", lr == 0);
		phase_gap(gap_ms);
	}

	/* ── 2. DB 스트리밍 read (io 축) — 청크 read로 페이지 캐시 경유, 합산 xor로
	 *      최적화 제거 방지. 루프 내부는 계약대로 쪼개지 않는다. ── */
	uint32_t db_x = 0;
	if (lbl_trace) { PHASE("Lsrc_026 ln=602"); phase_gap(gap_ms); }
	{
		static char chunk[1 << 20];
		ssize_t r;
		size_t rdone = 0;
		int rmark = 0;
		while ((r = read(dbfd, chunk, sizeof(chunk))) > 0) {
			for (ssize_t i = 0; i < r; i += 512)
				db_x ^= (uint8_t)chunk[i];
			rdone += (size_t)r;
			if (substeps)
				while (rmark < 3 && rdone * 4 >= db_n * (size_t)(rmark + 1)) {
					rmark++;
					PHASE("db_read_p%d done=%zu", rmark * 25, rdone);
					phase_gap(gap_ms);
				}
		}
	}
	PHASE("db_read xor=%u", db_x);
	phase_gap(gap_ms);

	/* ── 3. 파싱 (compute 축, A3: 작업 단위 = parse_iters) — 시간은 측정해 보고 ── */
	long parse_t0 = now_ms();
	if (lbl_trace) { PHASE("Lsrc_027 ln=624"); phase_gap(gap_ms); }
	uint32_t h = 2166136261u ^ db_x;
	if (lbl_trace) { PHASE("Lsrc_028 ln=625"); phase_gap(gap_ms); }
	{
		int mark = 0;
		for (long i = 0; i < parse_iters; i++) {
			h ^= (uint32_t)i;
			h *= 16777619u;
			h ^= h >> 15;
			if (substeps && mark < 3 && (i + 1) * 4 >= parse_iters * (mark + 1)) {
				mark++;
				PHASE("db_parse_p%d i=%ld", mark * 25, i + 1);
				phase_gap(gap_ms);
			}
		}
	}
	long parse_ms = now_ms() - parse_t0;
	if (lbl_trace) { PHASE("Lsrc_029 ln=639"); phase_gap(gap_ms); }
	PHASE("db_parse parse_ms=%ld h=%u", parse_ms, h);
	phase_gap(gap_ms);

	/* ── 4. 편성 인덱스 + EPG 텍스트 캐시 (mem 축, touched) ── */
	g_index_n = (size_t)index_mib << 20;
	if (lbl_trace) { PHASE("Lsrc_030 ln=644"); phase_gap(gap_ms); }
	if (g_index_n > 0) {
		g_index = malloc(g_index_n);
		if (!g_index)
			die("index malloc");
		/* 채널×슬롯 편성표를 앞부분에 결정적으로 기록, 나머지는 페이지 touch */
		size_t ents = (size_t)g_channels * (size_t)g_slots;
		for (size_t e = 0; e < ents && e * 16 + 16 <= g_index_n; e++)
			snprintf(g_index + e * 16, 16, "c%03us%03u:%04x",
				 (unsigned)(e % (size_t)g_channels) % 1000u,
				 (unsigned)(e / (size_t)g_channels) % 1000u,
				 (unsigned)((h + e * 2654435761u) & 0xffff));
		{
			int mark = 0;
			for (size_t i = ents * 16; i < g_index_n; i += 4096) {
				g_index[i] = (char)(h + i);
				if (substeps && mark < 3 && i * 4 >= g_index_n * (size_t)(mark + 1)) {
					mark++;
					PHASE("epg_index_p%d touched=%zu", mark * 25, i);
					phase_gap(gap_ms);
				}
			}
		}
	}
	PHASE("epg_index bytes=%zu crc=%08x", g_index_n, sched_crc());
	phase_gap(gap_ms);

	/* ── 5. 현재 슬롯 배너 텍스트 렌더 (배너의 "지금 이 채널은 이 방송") ── */
	{
		char banner[256];
		int slot = cur_slot();
		snprintf(banner, sizeof(banner), "[NOW slot=%d] CH001 News | CH002 Drama | crc=%08x",
			 slot, sched_crc());
		if (g_index && g_index_n > 4096)
			memcpy(g_index + g_index_n - 4096, banner, strlen(banner) + 1);
	}
	PHASE("epg_text slot=%d", cur_slot());
	phase_gap(gap_ms);

	/* ── 6. 지연 캐시 예약 (발표 10장 dump point 1과 동형: 주소만, 물리 page 없음)
	 *      refresh가 매 틱 refresh_kib씩 점진 touch → 복원 후 뒤늦게 한도 초과하는
	 *      침묵형 OOM(11장)을 앱 동작 그대로 재현 ── */
	g_reserve_n = (size_t)reserve_mib << 20;
	if (lbl_trace) { PHASE("Lsrc_031 ln=686"); phase_gap(gap_ms); }
	if (g_reserve_n > 0) {
		g_reserve = malloc(g_reserve_n);
		if (!g_reserve)
			die("reserve malloc");
	}
	PHASE("epg_reserve bytes=%zu", g_reserve_n);
	phase_gap(gap_ms);

	/* ── 6b. 워커 스레드 (파싱 보조 — 멀티스레드 dump 검증). 스레드마다 phase ── */
	if (threads > 4)
		threads = 4;
	for (long t = 0; t < threads; t++) {
		pthread_t th;
		int pr = pthread_create(&th, NULL, worker_thread, NULL);
		PHASE("thread%ld ok=%d", t + 1, pr == 0);
		phase_gap(gap_ms);
	}

	/* ── 6b2. 헬퍼 자식 (프로세스 트리 dump): 실기 서비스가 띄우는 보조 프로세스 ── */
	if (use_child) {
		g_child = fork();
		if (g_child == 0) {
			for (;;) {
				struct timespec ts = { 0, 100L * 1000 * 1000 };
				nanosleep(&ts, NULL);
			}
			_exit(0);
		}
		PHASE("helper_forked pid=%d ok=%d", g_child, g_child > 0);
		phase_gap(gap_ms);
	}

	/* ── 6b3. 미수거 좀비: 자식이 죽었는데 부모가 아직 wait 안 한 순간의 트리 ── */
	if (use_zombie) {
		g_zombie = fork();
		if (g_zombie == 0)
			_exit(0);
		usleep(30000);   /* 좀비 확정 대기 */
		PHASE("zombie_made pid=%d state=%c", g_zombie, child_state(g_zombie));
		phase_gap(gap_ms);
	}

	/* ── 6c. 이벤트 루프 wakeup 기구: self-pipe / eventfd (GLib mainloop 내부 모형) ── */
	if (use_pipe) {
		int pr = pipe2(g_pipe, O_NONBLOCK);
		PHASE("selfpipe ok=%d", pr == 0);
		phase_gap(gap_ms);
	}
	if (use_efd) {
		g_efd = eventfd(0, EFD_NONBLOCK);
		PHASE("eventfd_open ok=%d", g_efd >= 0);
		phase_gap(gap_ms);
	}

	/* ── 6d. POSIX shm 배너 버퍼 (surface/그래픽 버퍼 최소 모형: MAP_SHARED 파일) ── */
	if (shm_mib > 0) {
		snprintf(g_shm_name, sizeof(g_shm_name), "/pbsprobe_shm_p%d", g_port);
		int sfd = shm_open(g_shm_name, O_CREAT | O_RDWR, 0644);
		if (sfd >= 0 && ftruncate(sfd, (off_t)shm_mib << 20) == 0) {
			g_shm_n = (size_t)shm_mib << 20;
			g_shm = mmap(NULL, g_shm_n, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
			if (g_shm == MAP_FAILED) {
				g_shm = NULL;
				g_shm_n = 0;
			} else {
				for (size_t i = 0; i < g_shm_n; i += 4096)
					g_shm[i] = (char)i;   /* 버퍼 실제 점유 */
			}
		}
		if (sfd >= 0)
			close(sfd);
		PHASE("shm_map ok=%d bytes=%zu", g_shm != NULL, g_shm_n);
		phase_gap(gap_ms);
	}

	/* ── 6e. 전용 작업 디렉터리 chdir (경로 의존 복원 검증: cwd가 사라지면?) ── */
	if (use_wd) {
		char wd[96];
		snprintf(wd, sizeof(wd), "/tmp/pbsprobe_wd_p%d", g_port);
		mkdir(wd, 0755);
		int cr = chdir(wd);
		PHASE("workdir ok=%d", cr == 0);
		phase_gap(gap_ms);
	}

	/* ── 6f. unlink된 저널 파일 (sqlite -journal/-wal 모형): 열린 채 이름 삭제.
	 *      CRIU는 ghost file 처리(--link-remap/ghost-limit)가 필요한 계급 ── */
	if (use_tmpunl) {
		char jp[96];
		snprintf(jp, sizeof(jp), "/tmp/pbsprobe_journal_p%d", g_port);
		int jf = open(jp, O_CREAT | O_RDWR | O_TRUNC, 0644);
		int jok = 0;
		if (jf >= 0) {
			if (write(jf, "journal", 7) == 7 && unlink(jp) == 0)
				jok = 1;   /* fd는 유지 — 디스크 상 이름 없음 */
		}
		PHASE("tmp_journal ok=%d", jok);
		phase_gap(gap_ms);
	}

	/* ── 6g. epoll은 hub/tcp 연결 뒤에서 연다 (등록할 fd가 있어야 하므로) ── */

	/* ── 7. Luna hub 접속 — 연결 1개마다 phase (line-by-line의 핵심 구간:
	 *      "hub_conn1부터 dump가 거부되는가") ── */
	g_hub_total = (int)hub_conns;
	if (lbl_trace) { PHASE("Lsrc_032 ln=791"); phase_gap(gap_ms); }
	for (int k = 0; k < g_hub_total; k++) {
		g_hubfd[k] = hub_connect_one(k);
		if (g_hubfd[k] < 0) {
			PHASE("hub_conn%d ok=0 errno=%d", k + 1, errno);
		} else {
			g_hub_alive++;
			PHASE("hub_conn%d ok=1 alive=%d", k + 1, g_hub_alive);
		}
		phase_gap(gap_ms);
	}
	if (g_hub_total > 0 && g_hubfd[0] >= 0) {
		ssize_t w = write(g_hubfd[0], "SUB channelchange\n", 18);
		(void)w;
	}
	PHASE("hub_subscribed alive=%d total=%d", g_hub_alive, g_hub_total);
	phase_gap(gap_ms);

	/* ── 7b. 렌더 채널 (hub와 별개의 외부 STREAM — 배너를 '그리는' 연결의 최소 모형.
	 *      CRIU 관점에서 hub와 같은 계급인지(동일 에러 라인) 확인이 목적) ── */
	if (g_use_render) {
		g_renderfd = render_connect();
		PHASE("render_conn ok=%d", g_renderfd >= 0);
		phase_gap(gap_ms);
	}

	/* ── 8. TCP feed (선택) ── */
	if (strcmp(g_tcp_mode, "none") != 0) {
		g_tcpfd = tcp_connect_feed();
		PHASE("tcp_conn mode=%s ok=%d", g_tcp_mode, g_tcpfd >= 0);
		phase_gap(gap_ms);
		/* half-closed 상태 (송신만 닫음 — TCP_REPAIR가 거부하는 계급, gh#505) */
		if (tcp_halfcl && g_tcpfd >= 0) {
			int hr = shutdown(g_tcpfd, SHUT_WR);
			PHASE("tcp_halfclosed ok=%d", hr == 0);
			phase_gap(gap_ms);
		}
	}

	/* ── 8b. epoll 인스턴스 (GLib mainloop의 실제 대기 기구): 주요 fd 등록.
	 *      로직은 기존 poll 유지 — CRIU가 덤프해야 하는 것은 epoll fd와 등록
	 *      집합 그 자체 ── */
	if (use_epoll) {
		int ep = epoll_create1(0);
		int nreg = 0;
		if (ep >= 0) {
			struct epoll_event ev = { .events = EPOLLIN };
			int cand[MAX_HUB + 4];
			int nc = 0;
			for (int k = 0; k < g_hub_total; k++)
				if (g_hubfd[k] >= 0)
					cand[nc++] = g_hubfd[k];
			if (g_efd >= 0) cand[nc++] = g_efd;
			if (g_pipe[0] >= 0) cand[nc++] = g_pipe[0];
			if (g_tcpfd >= 0) cand[nc++] = g_tcpfd;
			if (g_renderfd >= 0) cand[nc++] = g_renderfd;
			for (int i = 0; i < nc; i++) {
				ev.data.fd = cand[i];
				if (epoll_ctl(ep, EPOLL_CTL_ADD, cand[i], &ev) == 0)
					nreg++;
			}
		}
		PHASE("epoll_open ok=%d nreg=%d", ep >= 0, nreg);
		phase_gap(gap_ms);
	}

	/* ── 8c. 자기 서비스 listen (실기 luna 서비스는 메서드 제공자 = listener) ──
	 *      복원 시 이 추상 이름을 다른 프로세스가 선점하면? → I_name_squat */
	if (use_ulisten) {
		int sl = socket(AF_UNIX, SOCK_STREAM, 0);
		int slok = 0;
		if (sl >= 0) {
			struct sockaddr_un sa;
			memset(&sa, 0, sizeof(sa));
			sa.sun_family = AF_UNIX;
			snprintf(sa.sun_path + 1, sizeof(sa.sun_path) - 2, "pbsprobe_svc_p%d", g_port);
			socklen_t sal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(sa.sun_path + 1));
			slok = (bind(sl, (struct sockaddr *)&sa, sal) == 0 && listen(sl, 4) == 0);
		}
		PHASE("svc_listen ok=%d", slok);
		phase_gap(gap_ms);
	}

	/* ── 8d. UDP (SSDP/디스커버리류): bound + connected 한 쌍 ── */
	if (use_udp) {
		int ub = socket(AF_INET, SOCK_DGRAM, 0);
		int uc = socket(AF_INET, SOCK_DGRAM, 0);
		int uok = 0;
		if (ub >= 0 && uc >= 0) {
			struct sockaddr_in ua;
			memset(&ua, 0, sizeof(ua));
			ua.sin_family = AF_INET;
			ua.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
			ua.sin_port = htons((uint16_t)(g_port + 4000));
			uok = (bind(ub, (struct sockaddr *)&ua, sizeof(ua)) == 0);
			ua.sin_port = htons((uint16_t)(g_port + 4001));
			uok = uok && (connect(uc, (struct sockaddr *)&ua, sizeof(ua)) == 0);
		}
		PHASE("udp_open ok=%d", uok);
		phase_gap(gap_ms);
	}

	/* ── 8e. netlink route (connman/네트워크 감시류) ── */
	if (use_nl) {
		int nfd = socket(AF_NETLINK, SOCK_RAW, 0 /* NETLINK_ROUTE */);
		int nok = 0;
		if (nfd >= 0) {
			struct sockaddr_nl na;
			memset(&na, 0, sizeof(na));
			na.nl_family = AF_NETLINK;
			nok = (bind(nfd, (struct sockaddr *)&na, sizeof(na)) == 0);
		}
		PHASE("netlink_open ok=%d", nok);
		phase_gap(gap_ms);
	}

	/* ── 9. 배너 시계 timerfd (armed 상태로 dump되는 타이머) ── */
	int tfd = -1;
	if (lbl_trace) { PHASE("Lsrc_033 ln=908"); phase_gap(gap_ms); }
	if (use_timer) {
		tfd = timerfd_create(CLOCK_MONOTONIC, 0);
		if (tfd >= 0) {
			struct itimerspec its = { { timer_s, 0 }, { timer_s, 0 } };
			timerfd_settime(tfd, 0, &its, NULL);
		}
		PHASE("timer_armed ok=%d period_s=%ld", tfd >= 0, timer_s);
		phase_gap(gap_ms);
	}

	/* ── 10. DB 갱신 감시 inotify ── */
	int ifd = -1;
	if (lbl_trace) { PHASE("Lsrc_034 ln=920"); phase_gap(gap_ms); }
	if (use_watch) {
		ifd = inotify_init1(IN_NONBLOCK);
		if (ifd >= 0 && inotify_add_watch(ifd, g_dbpath, IN_MODIFY | IN_CLOSE_WRITE) < 0) {
			close(ifd);
			ifd = -1;
		}
		PHASE("db_watch ok=%d", ifd >= 0);
		phase_gap(gap_ms);
	}

	/* ── 11. (선택) DB 파일 mmap — EPG 캐시 파일 매핑 변형 (fp_c_epg 계열) ── */
	void *dbmap = NULL;
	if (lbl_trace) { PHASE("Lsrc_035 ln=932"); phase_gap(gap_ms); }
	if (use_mmap) {
		dbmap = mmap(NULL, db_n, PROT_READ, MAP_SHARED, dbfd, 0);
		PHASE("db_mmap ok=%d", dbmap != MAP_FAILED);
		phase_gap(gap_ms);
	}

	/* ── ready + 서비스 루프 ── */
	int actual_port = 0;
	if (lbl_trace) { PHASE("Lsrc_036 ln=940"); phase_gap(gap_ms); }
	int lfd = serve_listen((int)port, &actual_port);
	if (lbl_trace) { PHASE("Lsrc_037 ln=941"); phase_gap(gap_ms); }
	printf("PHASE ready port=%d parse_ms=%ld sched_crc=%08x hub_ok=%d\n",
	       actual_port, parse_ms, sched_crc(), g_hub_alive);
	fflush(stdout);

	long t_ready = now_ms(), t_refresh = t_ready;
	int steady = 0;
	uint64_t tick_buf;
	for (;;) {
		serve_pending(lfd, 50);

		/* SIGUSR1 처방: hub 연결 해제 후 보류 (resume_file 생길 때까지) */
		if (g_bye) {
			g_bye = 0;
			hub_close_all();
			g_hub_hold = 1;
		}
		if (g_hub_hold && g_resume_file[0] && access(g_resume_file, F_OK) == 0) {
			g_hub_hold = 0;
			hub_reconnect_all();
		}

		/* hub 생존 감시: HUP/ERR → 사망 처리, (보류 아니면) 자동 재접속 */
		if (!g_selfhub && g_hub_total > 0 && !g_hub_hold) {
			int dead = 0;
			for (int k = 0; k < g_hub_total; k++) {
				if (g_hubfd[k] < 0) {
					dead++;
					continue;
				}
				struct pollfd p = { .fd = g_hubfd[k], .events = 0 };
				if (poll(&p, 1, 0) > 0 && (p.revents & (POLLHUP | POLLERR))) {
					printf("PHASE_NOTE hub_conn_dead k=%d revents=0x%x\n",
					       k + 1, p.revents);
					fflush(stdout);
					close(g_hubfd[k]);
					g_hubfd[k] = -1;
					g_hub_alive--;
					dead++;
				}
			}
			if (dead == g_hub_total && g_hub_alive == 0 && dead > 0) {
				static long last_try;
				if (hub_recon && now_ms() - last_try > 500) {
					last_try = now_ms();
					hub_reconnect_all();
					if (g_hub_alive == 0) {
						static int said;
						if (!said) {
							said = 1;
							PHASE("hub_dead retrying=1");
						}
					}
				}
			}
		}

		/* stream feed 수신 (논블로킹) */
		if (g_tcpfd >= 0 && strcmp(g_tcp_mode, "stream") == 0) {
			char b[4096];
			ssize_t r;
			while ((r = read(g_tcpfd, b, sizeof(b))) > 0)
				g_tcp_rx += r;
			if (r == 0) {   /* 서버가 닫음(RST/FIN) → 시체 정직 처리 */
				close(g_tcpfd);
				g_tcpfd = -1;
			}
		}

		/* timerfd 소비 (배너 시계 틱) */
		if (tfd >= 0) {
			struct pollfd p = { .fd = tfd, .events = POLLIN };
			if (poll(&p, 1, 0) > 0 && read(tfd, &tick_buf, 8) == 8)
				PHASE("clock_tick slot=%d", cur_slot());
		}

		/* inotify 소비 (DB 갱신 → 배너 텍스트 재렌더 트리거) */
		if (ifd >= 0) {
			char ev[512];
			while (read(ifd, ev, sizeof(ev)) > 0) {
				g_db_events++;
				printf("PHASE_NOTE db_changed n=%ld\n", g_db_events);
				fflush(stdout);
			}
		}

		/* 주기 refresh: 배너 재렌더 = dirty page + 소량 compute
		 * + reserve 점진 touch (지연 캐시 채움 → 침묵형 OOM 경로)
		 * + shm 배너 버퍼 dirty + PmLog 틱 송신 */
		if (refresh_ms > 0 && now_ms() - t_refresh >= refresh_ms) {
			t_refresh = now_ms();
			if (g_index && g_index_n > 0) {
				size_t span = (size_t)refresh_kib << 10;
				if (span > g_index_n)
					span = g_index_n;
				static size_t roff;
				for (size_t i = 0; i < span; i += 4096)
					g_index[(roff + i) % g_index_n]++;
				roff = (roff + span) % g_index_n;
			}
			if (g_reserve && g_reserve_touched < g_reserve_n) {
				size_t span = (size_t)refresh_kib << 10;
				if (g_reserve_touched + span > g_reserve_n)
					span = g_reserve_n - g_reserve_touched;
				memset(g_reserve + g_reserve_touched, 0x5a, span);
				g_reserve_touched += span;
			}
			if (g_shm && g_shm_n > 4096)
				g_shm[(size_t)(now_ms() / refresh_ms * 4096) % g_shm_n] ^= 1;
			if (g_logfd >= 0) {
				ssize_t w = send(g_logfd, "LOG tick\n", 9, MSG_DONTWAIT);
				(void)w;
			}
		}

		if (!steady && now_ms() - t_ready > 400) {
			steady = 1;
			PHASE("steady");
		}
	}
	return 0;
}
