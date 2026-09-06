/* pbsprobe/pbs_hub.c — pbs_mock의 "바깥 세계": Luna hub(UNIX bus) + TCP feed 서버
 *
 * xpeer.c(connprobe)의 후속: 덤프 집합 밖에 사는 상대 프로세스. criu dump -t <pbs_mock>
 * 트리에 절대 들어가지 않는다 — 그게 "hub는 얼릴 수 없다"(발표 7장)의 재현 조건.
 *
 *   --port N        hub: 추상 UNIX "pbsprobe_hub_p<N>" listen
 *   --feed M        feed: 127.0.0.1:N+3000 TCP listen. M = none|reqresp|stream
 *   --pending K     hub 연결마다 등록 ack 후 notify K건 push (클라이언트가 안 읽으면
 *                   receive queue에 미수신 메시지로 남는다 — 발표 5장의 그 queue)
 *   --no-accept     hub listen만 하고 accept 안 함 → 연결이 백로그에 걸린 채 방치
 *                   (발표 6장 Batch B의 "connect는 됐지만 accept 전" 케이스)
 *
 * stdout 프로토콜 (pbs_sweep.sh가 grep으로 소비):
 *   HUB ready port=<N> feed=<M>
 *   HUB register svc=<name> total=<등록 누계>     ← restore 후 재등록 검증의 근거
 *   FEED conn n=<...> / FEED push ...
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static void die(const char *m) { perror(m); exit(1); }

#define MAXC 64
static int hub_c[MAXC], hub_cn;      /* hub 쪽 accepted 연결 */
static int feed_c[MAXC], feed_cn;    /* feed 쪽 accepted 연결 */
static int reg_total;

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
}

int main(int argc, char **argv)
{
	int port = 18080, pending = 2, no_accept = 0, pass_fd = 0;
	long flood = 300;   /* 재등록 flood 기본량 — 'flood' 이름 서비스에만 발동 */
	const char *feed = "none";
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--feed") && i + 1 < argc) feed = argv[++i];
		else if (!strcmp(argv[i], "--pending") && i + 1 < argc) pending = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--no-accept")) no_accept = 1;
		else if (!strcmp(argv[i], "--flood_on_rereg") && i + 1 < argc) flood = atol(argv[++i]);
		else if (!strcmp(argv[i], "--pass_fd")) pass_fd = 1;
	}
	signal(SIGPIPE, SIG_IGN);

	/* 재등록 flood용: 이미 본 서비스 이름 기억 (세계에서 "밀린 notify"의 근사) */
	char seen[128][64];
	int seen_n = 0;
	/* SCM_RIGHTS용 전달 fd: pipe 읽기끝 (luna가 fd를 넘기는 패턴의 최소형) */
	int passpipe[2] = { -1, -1 };
	if (pass_fd && pipe(passpipe) == 0) {
		ssize_t w = write(passpipe[1], "X", 1);
		(void)w;
	}

	/* hub: 추상 UNIX listen */
	int hl = socket(AF_UNIX, SOCK_STREAM, 0);
	if (hl < 0)
		die("hub socket");
	struct sockaddr_un ua;
	memset(&ua, 0, sizeof(ua));
	ua.sun_family = AF_UNIX;
	snprintf(ua.sun_path + 1, sizeof(ua.sun_path) - 2, "pbsprobe_hub_p%d", port);
	socklen_t ual = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ua.sun_path + 1));
	if (bind(hl, (struct sockaddr *)&ua, ual) < 0)
		die("hub bind");
	if (listen(hl, 16) < 0)
		die("hub listen");

	/* feed: TCP listen (모드가 none이어도 listen은 해 둔다 — 연결 시도 자체를 관찰) */
	int fl = socket(AF_INET, SOCK_STREAM, 0);
	if (fl < 0)
		die("feed socket");
	int one = 1;
	setsockopt(fl, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in ta;
	memset(&ta, 0, sizeof(ta));
	ta.sin_family = AF_INET;
	ta.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	ta.sin_port = htons((uint16_t)(port + 3000));
	if (bind(fl, (struct sockaddr *)&ta, sizeof(ta)) < 0)
		die("feed bind");
	if (listen(fl, 16) < 0)
		die("feed listen");

	say("HUB ready port=%d feed=%s pending=%d accept=%d", port, feed, pending, !no_accept);

	/* 확장 수신자: PmLog 모형 DGRAM 싱크 + 렌더 채널 listener (F 가족 상대역) */
	int lg = socket(AF_UNIX, SOCK_DGRAM, 0);
	if (lg >= 0) {
		struct sockaddr_un la;
		memset(&la, 0, sizeof(la));
		la.sun_family = AF_UNIX;
		snprintf(la.sun_path + 1, sizeof(la.sun_path) - 2, "pbsprobe_log_p%d", port);
		socklen_t ll = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(la.sun_path + 1));
		if (bind(lg, (struct sockaddr *)&la, ll) < 0) {
			close(lg);
			lg = -1;
		}
	}
	int rl = socket(AF_UNIX, SOCK_STREAM, 0);
	if (rl >= 0) {
		struct sockaddr_un ra;
		memset(&ra, 0, sizeof(ra));
		ra.sun_family = AF_UNIX;
		snprintf(ra.sun_path + 1, sizeof(ra.sun_path) - 2, "pbsprobe_render_p%d", port);
		socklen_t rll = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ra.sun_path + 1));
		if (bind(rl, (struct sockaddr *)&ra, rll) < 0 || listen(rl, 8) < 0) {
			close(rl);
			rl = -1;
		}
	}
	int render_c[MAXC]; int render_cn = 0; long log_rx = 0;

	long last_push = 0;
	char payload[512];
	for (size_t i = 0; i < sizeof(payload) - 1; i++)
		payload[i] = 'a' + (i % 26);
	payload[sizeof(payload) - 1] = '\n';

	for (;;) {
		/* poll 스냅샷: 이 pass의 순회는 반드시 스냅샷 개수(hub_snap/feed_snap)
		 * 기준으로 한다 — accept로 배열이 자라도 ps[]와 어긋나지 않게. 제거는
		 * 순회 중 swap하지 않고 표시 후 일괄 압축 (revents 오귀속 방지). */
		struct pollfd ps[4 + MAXC * 3];
		int pn = 0;
		ps[pn].fd = no_accept ? -1 : hl;
		ps[pn++].events = POLLIN;
		ps[pn].fd = fl;
		ps[pn++].events = POLLIN;
		ps[pn].fd = lg;                       /* [2] log DGRAM 싱크 */
		ps[pn++].events = POLLIN;
		ps[pn].fd = rl;                       /* [3] render listener */
		ps[pn++].events = POLLIN;
		int hub_base = pn, hub_snap = hub_cn;
		for (int i = 0; i < hub_snap; i++) {
			ps[pn].fd = hub_c[i];
			ps[pn++].events = POLLIN;
		}
		int feed_base = pn, feed_snap = feed_cn;
		for (int i = 0; i < feed_snap; i++) {
			ps[pn].fd = feed_c[i];
			ps[pn++].events = POLLIN;
		}
		int rend_base = pn, rend_snap = render_cn;
		for (int i = 0; i < rend_snap; i++) {
			ps[pn].fd = render_c[i];
			ps[pn++].events = POLLIN;
		}
		poll(ps, pn, 20);

		/* log DGRAM 수신 — 첫 건과 50건마다 로그 (재개 검증 근거) */
		if (lg >= 0 && (ps[2].revents & POLLIN)) {
			char lb[256];
			while (recv(lg, lb, sizeof(lb), MSG_DONTWAIT) > 0) {
				log_rx++;
				if (log_rx == 1 || log_rx % 50 == 0)
					say("LOG rx n=%ld", log_rx);
			}
		}
		/* render accept + HUP 정리 */
		if (rl >= 0 && (ps[3].revents & POLLIN) && render_cn < MAXC) {
			int c = accept(rl, NULL, NULL);
			if (c >= 0) {
				render_c[render_cn++] = c;
				say("RENDER conn n=%d", render_cn);
			}
		}
		for (int i = 0; i < rend_snap; i++) {
			short re = ps[rend_base + i].revents;
			if (re & (POLLHUP | POLLERR)) {
				close(render_c[i]);
				render_c[i] = -1;
				continue;
			}
			if (re & POLLIN) {
				char b[64];
				ssize_t r = recv(render_c[i], b, sizeof(b), MSG_DONTWAIT);
				if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
					close(render_c[i]);
					render_c[i] = -1;
				}
			}
		}
		for (int i = 0; i < render_cn; i++)
			if (render_c[i] < 0) {
				render_c[i] = render_c[--render_cn];
				i--;
			}

		/* hub accept + register 처리 */
		if (!no_accept && (ps[0].revents & POLLIN) && hub_cn < MAXC) {
			int c = accept(hl, NULL, NULL);
			if (c >= 0) {
				struct timeval tv = { 0, 300000 };
				setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
				char line[128] = { 0 };
				ssize_t r = read(c, line, sizeof(line) - 1);
				if (r > 0 && !strncmp(line, "REG ", 4)) {
					char *nl = strchr(line, '\n');
					if (nl)
						*nl = 0;
					reg_total++;
					say("HUB register svc=%s total=%d", line + 4, reg_total);
					char ack[32];
					int L = snprintf(ack, sizeof(ack), "ACK %d\n", reg_total);
					if (write(c, ack, L) != L) { /* best effort */ }
					for (int m = 0; m < pending; m++) {
						char msg[64];
						int ml = snprintf(msg, sizeof(msg),
								  "{\"notify\":\"chg\",\"seq\":%d}\n", m);
						if (send(c, msg, ml, MSG_DONTWAIT) != ml)
							break;   /* 버퍼 한도 — 허브는 절대 멈추지 않는다 */
					}
					/* SCM_RIGHTS: fd 하나를 보조 데이터로 전달 (클라이언트가
					 * 안 읽으면 'fd가 실린 미수신 메시지'가 queue에 남는다 —
					 * PR#2030의 그 계급) */
					if (pass_fd && passpipe[0] >= 0) {
						struct msghdr mh;
						struct iovec iov = { .iov_base = "FD\n", .iov_len = 3 };
						char cbuf[CMSG_SPACE(sizeof(int))];
						memset(&mh, 0, sizeof(mh));
						memset(cbuf, 0, sizeof(cbuf));
						mh.msg_iov = &iov;
						mh.msg_iovlen = 1;
						mh.msg_control = cbuf;
						mh.msg_controllen = sizeof(cbuf);
						struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
						cm->cmsg_level = SOL_SOCKET;
						cm->cmsg_type = SCM_RIGHTS;
						cm->cmsg_len = CMSG_LEN(sizeof(int));
						memcpy(CMSG_DATA(cm), &passpipe[0], sizeof(int));
						if (sendmsg(c, &mh, 0) > 0)
							say("HUB passfd svc=%s", line + 4);
					}
					/* 재등록 감지 → 밀린 notify 폭주 방출 (세계의 backlog 근사) */
					int again = 0;
					for (int s = 0; s < seen_n; s++)
						if (!strncmp(seen[s], line + 4, sizeof(seen[0]) - 1)) {
							again = 1;
							break;
						}
					if (!again && seen_n < 128) {
						snprintf(seen[seen_n], sizeof(seen[0]), "%.62s", line + 4);
						seen_n++;
					}
					if (again && flood > 0 && strstr(line + 4, "flood")) {
						/* 논블로킹 방출: 실제 허브처럼 수신자 버퍼 한도까지만
						 * 밀고(초과분은 drop으로 간주), 허브는 멈추지 않는다 */
						long sent = 0, dropped = 0;
						for (long m = 0; m < flood; m++) {
							char msg[96];
							int ml = snprintf(msg, sizeof(msg),
									  "{\"backlog\":\"chg\",\"seq\":%ld}\n", m);
							if (send(c, msg, ml, MSG_DONTWAIT) != ml) {
								dropped = flood - m;
								break;
							}
							sent++;
						}
						say("HUB flood svc=%s sent=%ld dropped=%ld", line + 4, sent, dropped);
					}
				}
				hub_c[hub_cn++] = c;
			}
		}
		/* hub 연결 정리 (클라이언트 close → HUP) + SUB 라인 소비 */
		for (int i = 0; i < hub_snap; i++) {
			short re = ps[hub_base + i].revents;
			if (re & (POLLHUP | POLLERR)) {
				close(hub_c[i]);
				hub_c[i] = -1;
				continue;
			}
			if (re & POLLIN) {
				char b[128];
				ssize_t r = recv(hub_c[i], b, sizeof(b), MSG_DONTWAIT);
				if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
					close(hub_c[i]);
					hub_c[i] = -1;
				}
			}
		}
		for (int i = 0; i < hub_cn; i++)   /* 일괄 압축 */
			if (hub_c[i] < 0) {
				hub_c[i] = hub_c[--hub_cn];
				i--;
			}

		/* feed accept */
		if ((ps[1].revents & POLLIN) && feed_cn < MAXC) {
			int c = accept(fl, NULL, NULL);
			if (c >= 0) {
				say("FEED conn n=%d", feed_cn + 1);
				int fl2 = fcntl(c, F_GETFL, 0);
				fcntl(c, F_SETFL, fl2 | O_NONBLOCK);
				feed_c[feed_cn++] = c;
			}
		}
		/* feed 서비스 */
		for (int i = 0; i < feed_snap; i++) {
			short re = ps[feed_base + i].revents;
			if (re & (POLLHUP | POLLERR)) {
				close(feed_c[i]);
				feed_c[i] = -1;
				continue;
			}
			if (re & POLLIN) {
				char b[256];
				ssize_t r = recv(feed_c[i], b, sizeof(b) - 1, MSG_DONTWAIT);
				if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
					close(feed_c[i]);
					feed_c[i] = -1;
					continue;
				}
				if (r > 0 && !strcmp(feed, "reqresp") && !strncmp(b, "REQ ", 4)) {
					char resp[128];
					int L = snprintf(resp, sizeof(resp),
							 "EPG slot-data ts=%ld ok\n", (long)time(NULL));
					if (write(feed_c[i], resp, L) != L) { /* HUP은 다음 poll에서 */ }
				}
				/* SUBSCRIBE는 상태 전환 없이 수신만 — stream push는 아래에서 전 연결 대상 */
			}
		}
		for (int i = 0; i < feed_cn; i++)   /* 일괄 압축 */
			if (feed_c[i] < 0) {
				feed_c[i] = feed_c[--feed_cn];
				i--;
			}
		/* stream: 25ms마다 전 feed 연결에 512B push (HLS 조각 모사) */
		if (!strcmp(feed, "stream")) {
			struct timespec ts;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			long now = ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
			if (now - last_push >= 25) {
				last_push = now;
				for (int i = 0; i < feed_cn; i++) {
					if (write(feed_c[i], payload, sizeof(payload)) < 0
					    && errno != EAGAIN && errno != EWOULDBLOCK) {
						close(feed_c[i]);
						feed_c[i] = feed_c[--feed_cn];
						i--;
					}
				}
			}
		}
	}
	return 0;
}
