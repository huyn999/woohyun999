#!/usr/bin/env python3
"""gen_workloads.py — CRIU 호환성 탐침(fail-probe) 워크로드 생성기.

webOS TV 앱에서 실제로 나타나는 자원 사용 패턴(fd/소켓/스레드/락/공유메모리/타이머 등)을
"feature"로 정의하고, 단일 feature 탐침 + 현실적 조합(composite) 시나리오로 총 N개(기본 100)의
워크로드 디렉터리(workload.c + workload.yaml)를 testbed/workloads/ 아래에 생성한다.

계약 v2 준수 사항 (testbed/workloads/README.md):
  A1 named flags (--bytes/--port, common/flags.h)
  A2 PHASE 발행 + fflush — feature 하나 획득할 때마다 f_<feature> phase 발행
  A6 핑퐁 서버 (common/probe_server.h) → served_first 자동
계약 A4(dump 시점 fd = stdio+listen뿐)는 **의도적으로 위반**한다 — 그것이 탐침의 목적.

Usage:
  python3 gen_workloads.py --workloads-dir <repo>/testbed/workloads --count 100 [--prefix fp_]
  생성 후: testbed/workloads/build.sh   (자동 발견·빌드)
"""
import argparse
import re
import csv
import os
import sys
import textwrap

# ---------------------------------------------------------------------------
# Feature registry
# 각 feature: C setup 코드(획득 직후 PHASE f_<id> 발행은 생성기가 붙임), 선택적 loop tick,
# 예상 RSS 증가량(MiB, manifest resident 선언용), webOS 대응 설명, 예상 CRIU 리스크 메모.
# setup 코드 규약: 실패는 원칙적으로 die("...")로 즉사(환경 문제를 조용히 통과시키지 않는다).
# 단, 환경 의존적으로 없을 수 있는 자원(tty 등)은 ok=%d 를 PHASE에 실어 정직하게 기록.
# ---------------------------------------------------------------------------
F = {}


def feat(fid, desc, risk, rss_mib, setup, tick="", atomic=False):
    F[fid] = dict(desc=desc, risk=risk, rss=rss_mib, setup=textwrap.dedent(setup),
                  tick=textwrap.dedent(tick), atomic=atomic)


def instrument_lines(setup_code, feat_id):
    """line 모드: snippet 최상위(depth==1) 문장 각각 뒤에 PHASE 삽입.
    반환: (계측된 코드, 삽입된 phase 이름 리스트). 중괄호 깊이 추적으로
    for/if 내부 블록(자식 프로세스 루프 등)은 건드리지 않는다."""
    lines = setup_code.strip("\n").split("\n")
    out, names = [], []
    depth = 0
    k = 0
    for i, l in enumerate(lines):
        out.append(l)
        depth += l.count("{") - l.count("}")
        s = l.strip()
        is_last = (i == len(lines) - 1)
        if depth == 1 and s.endswith(";") and not is_last:
            k += 1
            nm = f"f_{feat_id}_l{k:02d}"
            names.append(nm)
            ind = l[:len(l) - len(l.lstrip())]
            out.append(f'{ind}PHASE("{nm}"); phase_gap(gap_ms);')
    return "\n".join(out), names


feat("plain", "아무 자원도 없는 최소 앱 (대조군)", "none", 0, "")

feat("large_heap", "대형 힙 (브라우저/게임의 리소스 로딩)", "none — dump 이미지만 커짐", 300, """
    { size_t n = 300ull << 20; char *p = malloc(n); if (!p) die("large_heap malloc");
      for (size_t i = 0; i < n; i += 4096) p[i] = 1;
      KEEP(p); }
""")

feat("dirty_churn", "메모리를 계속 더럽히는 상태 갱신 (EPG/캐시 갱신)", "none — dump 시점 dirty 양 변동", 0, "", """
    if (g_base && g_base_n) { static size_t off; size_t span = 1 << 20;
      for (size_t i = 0; i < span && g_base_n; i += 4096) g_base[(off + i) % g_base_n]++;
      off = (off + span) % (g_base_n ? g_base_n : 1); }
""")

feat("logfile", "append 로그 파일 fd (모든 서비스 데몬)", "low — regular file fd", 0, """
    { snprintf(g_path_logfile, sizeof(g_path_logfile), "/tmp/criuprobe_log_p%d", g_port);
      int fd = open(g_path_logfile, O_CREAT | O_WRONLY | O_APPEND, 0644);
      if (fd < 0) die("logfile open"); dprintf(fd, "start\\n"); KEEPFD(fd); g_logfd = fd; }
""", """
    if (g_logfd >= 0) dprintf(g_logfd, "t\\n");
""")

feat("tmpunlink", "열어둔 채 unlink한 임시파일 (캐시/다운로드 중간파일)", "medium — ghost file 복원 경로", 0, """
    { char tmpl[] = "/tmp/criuprobe_ghost_XXXXXX"; int fd = mkstemp(tmpl);
      if (fd < 0) die("mkstemp"); char b[4096]; memset(b, 7, sizeof(b));
      if (write(fd, b, sizeof(b)) != sizeof(b)) die("ghost write");
      if (unlink(tmpl) < 0) die("ghost unlink"); KEEPFD(fd); }
""")

feat("fifo", "named pipe (레거시 IPC)", "low", 0, """
    { snprintf(g_path_fifo, sizeof(g_path_fifo), "/tmp/criuprobe_fifo_p%d", g_port);
      unlink(g_path_fifo);
      if (mkfifo(g_path_fifo, 0600) < 0) die("mkfifo");
      int fd = open(g_path_fifo, O_RDWR); if (fd < 0) die("fifo open"); KEEPFD(fd); }
""")

feat("pipe", "익명 파이프 + 미소비 데이터 (자식 헬퍼 통신)", "low — 파이프 버퍼 내용 dump", 0, """
    { int p[2]; if (pipe2(p, 0) < 0) die("pipe2");
      if (write(p[1], "pending-data\\n", 13) != 13) die("pipe write");
      KEEPFD(p[0]); KEEPFD(p[1]); }
""")

feat("socketpair", "AF_UNIX socketpair (프로세스 내부 채널)", "low", 0, """
    { int sv[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) die("socketpair");
      if (write(sv[0], "x", 1) != 1) die("sp write"); KEEPFD(sv[0]); KEEPFD(sv[1]); }
""")

feat("unix_listen", "UNIX 도메인 listen 소켓 (luna-service 류 데몬)", "medium — bind 경로 재생성", 0, """
    { snprintf(g_path_us, sizeof(g_path_us), "/tmp/criuprobe_us_p%d", g_port);
      unlink(g_path_us);
      int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) die("us socket");
      struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
      snprintf(a.sun_path, sizeof(a.sun_path), "%s", g_path_us);
      if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) die("us bind");
      if (listen(fd, 4) < 0) die("us listen"); KEEPFD(fd); g_usfd = fd; }
""")

feat("unix_conn", "연결 성립된 UNIX 소켓 쌍 (버스 클라이언트)", "medium — established unix", 0, """
    { if (g_usfd < 0) { /* 자체 리스너가 없으면 하나 만든다 */
        snprintf(g_path_us, sizeof(g_path_us), "/tmp/criuprobe_usc_p%d", g_port);
        unlink(g_path_us);
        g_usfd = socket(AF_UNIX, SOCK_STREAM, 0); if (g_usfd < 0) die("usc socket");
        struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof(a.sun_path), "%s", g_path_us);
        if (bind(g_usfd, (struct sockaddr *)&a, sizeof(a)) < 0) die("usc bind");
        if (listen(g_usfd, 4) < 0) die("usc listen"); KEEPFD(g_usfd); }
      int cl = socket(AF_UNIX, SOCK_STREAM, 0); if (cl < 0) die("uconn socket");
      struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
      snprintf(a.sun_path, sizeof(a.sun_path), "%s", g_path_us);
      if (connect(cl, (struct sockaddr *)&a, sizeof(a)) < 0) die("uconn connect");
      int sv = accept(g_usfd, NULL, NULL); if (sv < 0) die("uconn accept");
      KEEPFD(cl); KEEPFD(sv); }
""")

feat("tcp_listen2", "보조 TCP listen 소켓 (관리 포트)", "low", 0, """
    { int extra_port = 0; int fd = probe_listen(0, &extra_port); KEEPFD(fd); (void)extra_port; }
""")

feat("tcp_established", "연결 성립된 loopback TCP 쌍 (스트리밍/앱스토어 연결)", "HIGH — 기본 옵션 dump 거부 예상 (--tcp-established 필요)", 0, """
    { int lp = 0; int l = probe_listen(0, &lp);
      int cl = socket(AF_INET, SOCK_STREAM, 0); if (cl < 0) die("tcp cl socket");
      struct sockaddr_in a; memset(&a, 0, sizeof(a)); a.sin_family = AF_INET;
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons((uint16_t)lp);
      if (connect(cl, (struct sockaddr *)&a, sizeof(a)) < 0) die("tcp connect");
      int sv = accept(l, NULL, NULL); if (sv < 0) die("tcp accept");
      if (write(cl, "hello", 5) != 5) die("tcp write");
      KEEPFD(l); KEEPFD(cl); KEEPFD(sv); }
""")

feat("udp", "바인드된 UDP 소켓 (텔레메트리/디스커버리)", "low", 0, """
    { int fd = socket(AF_INET, SOCK_DGRAM, 0); if (fd < 0) die("udp socket");
      struct sockaddr_in a; memset(&a, 0, sizeof(a)); a.sin_family = AF_INET;
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = 0;
      if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) die("udp bind"); KEEPFD(fd); }
""")

feat("timerfd", "주기 timerfd (프레임/폴링 타이머)", "low", 0, """
    { int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
      if (fd < 0) die("timerfd_create");
      struct itimerspec its = { .it_interval = { 0, 100000000L }, .it_value = { 0, 100000000L } };
      if (timerfd_settime(fd, 0, &its, NULL) < 0) die("timerfd_settime");
      KEEPFD(fd); g_tfd = fd; }
""", """
    if (g_tfd >= 0) { uint64_t exp; while (read(g_tfd, &exp, sizeof(exp)) > 0) {} }
""")

feat("eventfd", "eventfd (이벤트 루프 wakeup)", "low", 0, """
    { int fd = eventfd(1, EFD_NONBLOCK); if (fd < 0) die("eventfd"); KEEPFD(fd); }
""")

feat("signalfd", "signalfd (시그널 기반 제어)", "low", 0, """
    { sigset_t m; sigemptyset(&m); sigaddset(&m, SIGUSR1);
      if (sigprocmask(SIG_BLOCK, &m, NULL) < 0) die("sigprocmask");
      int fd = signalfd(-1, &m, SFD_NONBLOCK); if (fd < 0) die("signalfd"); KEEPFD(fd); }
""")

feat("epoll", "epoll 인스턴스 + 등록 fd (이벤트 루프)", "low", 0, """
    { int ep = epoll_create1(0); if (ep < 0) die("epoll_create1");
      int ev = eventfd(0, EFD_NONBLOCK); if (ev < 0) die("epoll eventfd");
      struct epoll_event e = { .events = EPOLLIN, .data = { .fd = ev } };
      if (epoll_ctl(ep, EPOLL_CTL_ADD, ev, &e) < 0) die("epoll_ctl");
      KEEPFD(ep); KEEPFD(ev); }
""")

feat("inotify", "inotify 감시 (설정/미디어 디렉터리 워처)", "medium — watch 경로 복원", 0, """
    { snprintf(g_path_watch, sizeof(g_path_watch), "/tmp/criuprobe_watch_p%d", g_port);
      mkdir(g_path_watch, 0755);
      int fd = inotify_init1(IN_NONBLOCK); if (fd < 0) die("inotify_init1");
      if (inotify_add_watch(fd, g_path_watch, IN_CREATE | IN_MODIFY) < 0) die("inotify_add_watch");
      KEEPFD(fd); }
""")

feat("memfd", "memfd + mmap (GPU/렌더 버퍼 전달)", "low (CRIU 4.x 지원)", 16, """
    { int fd = memfd_create("criuprobe", 0); if (fd < 0) die("memfd_create");
      size_t n = 16ull << 20; if (ftruncate(fd, n) < 0) die("memfd ftruncate");
      char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      if (p == MAP_FAILED) die("memfd mmap");
      for (size_t i = 0; i < n; i += 4096) p[i] = 2;
      KEEP(p); KEEPFD(fd); }
""")

feat("shm_posix", "POSIX 공유메모리 (컴포지터/서비스 간 버퍼)", "medium", 16, """
    { snprintf(g_path_shm, sizeof(g_path_shm), "/criuprobe_shm_p%d", g_port);
      shm_unlink(g_path_shm);
      int fd = shm_open(g_path_shm, O_CREAT | O_RDWR, 0600); if (fd < 0) die("shm_open");
      size_t n = 16ull << 20; if (ftruncate(fd, n) < 0) die("shm ftruncate");
      char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      if (p == MAP_FAILED) die("shm mmap");
      for (size_t i = 0; i < n; i += 4096) p[i] = 3;
      KEEP(p); KEEPFD(fd); }
""")

feat("shm_sysv", "SysV 공유메모리, attach 후 IPC_RMID (오디오/AV 파이프라인 레거시)", "HIGH — RMID된 세그먼트 복원", 16, """
    { int id = shmget(IPC_PRIVATE, 16ull << 20, IPC_CREAT | 0600);
      if (id < 0) die("shmget");
      char *p = shmat(id, NULL, 0); if (p == (void *)-1) die("shmat");
      shmctl(id, IPC_RMID, NULL);   /* attach 유지 중 RMID — 마지막 detach 때 소멸 */
      for (size_t i = 0; i < (16ull << 20); i += 4096) p[i] = 4;
      KEEP(p); }
""")

feat("mq", "POSIX 메시지 큐 + 미소비 메시지 (서비스 명령 큐)", "medium", 0, """
    { snprintf(g_path_mq, sizeof(g_path_mq), "/criuprobe_mq_p%d", g_port);
      mq_unlink(g_path_mq);
      struct mq_attr at = { .mq_flags = 0, .mq_maxmsg = 4, .mq_msgsize = 64 };
      mqd_t q = mq_open(g_path_mq, O_CREAT | O_RDWR | O_NONBLOCK, 0600, &at);
      if (q == (mqd_t)-1) die("mq_open");
      if (mq_send(q, "cmd", 4, 0) < 0) die("mq_send"); KEEPFD((int)q); }
""")

feat("sem_sysv", "SysV 세마포어 (레거시 락)", "medium", 0, """
    { int id = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600); if (id < 0) die("semget");
      union semun { int val; } arg; arg.val = 1;
      if (semctl(id, 0, SETVAL, arg) < 0) die("semctl SETVAL"); g_semid = id; }
""")

feat("thread1", "워커 스레드 1개 (I/O 헬퍼)", "low", 0, """
    { pthread_t t; if (pthread_create(&t, NULL, wk_sleeper, NULL) != 0) die("pthread_create"); }
""")

feat("thread4", "워커 스레드 4개 (디코더/렌더 풀)", "low", 0, """
    { for (int i = 0; i < 4; i++) { pthread_t t;
        if (pthread_create(&t, NULL, wk_sleeper, NULL) != 0) die("pthread_create x4"); } }
""")

feat("futex_wait", "futex(조건변수)에 영구 블록된 스레드 (유휴 워커풀)", "medium — 블록 상태 복원", 0, """
    { pthread_t t; if (pthread_create(&t, NULL, wk_futex_wait, NULL) != 0) die("pthread futex"); }
""")

feat("child", "자식 프로세스 1 (헬퍼/플러그인 프로세스)", "low — 프로세스 트리 dump", 0, """
    { pid_t c = fork(); if (c < 0) die("fork");
      if (c == 0) { for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); } } }
""", """
    { int st; while (waitpid(-1, &st, WNOHANG) > 0) {} }
""", atomic=True)

feat("grandchild", "자식의 자식 (2단 트리 — 앱이 띄운 헬퍼의 헬퍼)", "medium — 깊은 트리", 0, """
    { pid_t c = fork(); if (c < 0) die("fork gc");
      if (c == 0) { pid_t g = fork();
        if (g == 0) { for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); } }
        for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); } } }
""", """
    { int st; while (waitpid(-1, &st, WNOHANG) > 0) {} }
""", atomic=True)

feat("session", "setsid로 세션 분리 (데몬화 관례)", "medium — 세션 리더 복원", 0, """
    { if (setsid() < 0) printf("PHASE_NOTE setsid_failed errno=%d\\n", errno); fflush(stdout); }
""")

feat("mmap_priv", "파일 MAP_PRIVATE 매핑 (리소스/폰트 로딩)", "low", 8, """
    { snprintf(g_path_map, sizeof(g_path_map), "/tmp/criuprobe_map_p%d", g_port);
      int fd = open(g_path_map, O_CREAT | O_RDWR, 0644); if (fd < 0) die("map open");
      size_t n = 8ull << 20; if (ftruncate(fd, n) < 0) die("map ftruncate");
      char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
      if (p == MAP_FAILED) die("map mmap");
      for (size_t i = 0; i < n; i += 4096) p[i] = 5;
      KEEP(p); close(fd); }
""")

feat("mmap_shared", "파일 MAP_SHARED rw 매핑 (설정 캐시 파일)", "medium — 파일 동기화 의미", 8, """
    { snprintf(g_path_maps, sizeof(g_path_maps), "/tmp/criuprobe_maps_p%d", g_port);
      int fd = open(g_path_maps, O_CREAT | O_RDWR, 0644); if (fd < 0) die("maps open");
      size_t n = 8ull << 20; if (ftruncate(fd, n) < 0) die("maps ftruncate");
      char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      if (p == MAP_FAILED) die("maps mmap");
      for (size_t i = 0; i < n; i += 4096) p[i] = 6;
      KEEP(p); KEEPFD(fd); }
""")

feat("mlock", "mlock된 영역 (오디오 언더런 방지 버퍼)", "medium — 권한/한도", 1, """
    { size_t n = 1 << 20;
      char *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      if (p == MAP_FAILED) die("mlock mmap");
      if (mlock(p, n) < 0) printf("PHASE_NOTE mlock_failed errno=%d\\n", errno);
      fflush(stdout); memset(p, 8, n); KEEP(p); }
""")

feat("rlimit", "낮춘 RLIMIT_NOFILE (샌드박스 관례)", "low", 0, """
    { struct rlimit rl; if (getrlimit(RLIMIT_NOFILE, &rl) < 0) die("getrlimit");
      rl.rlim_cur = 256; if (setrlimit(RLIMIT_NOFILE, &rl) < 0) die("setrlimit"); }
""")

feat("itimer", "setitimer 주기 SIGALRM (레거시 워치독)", "medium — 진행 중 타이머+핸들러", 0, """
    { struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = wk_sig_noop;
      if (sigaction(SIGALRM, &sa, NULL) < 0) die("sigaction ALRM");
      struct itimerval iv = { { 0, 200000 }, { 0, 200000 } };
      if (setitimer(ITIMER_REAL, &iv, NULL) < 0) die("setitimer"); }
""")

feat("posix_timer", "timer_create RT 시그널 타이머", "medium", 0, """
    { struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = wk_sig_noop;
      if (sigaction(SIGRTMIN, &sa, NULL) < 0) die("sigaction RT");
      timer_t tid; struct sigevent se; memset(&se, 0, sizeof(se));
      se.sigev_notify = SIGEV_SIGNAL; se.sigev_signo = SIGRTMIN;
      if (timer_create(CLOCK_MONOTONIC, &se, &tid) < 0) die("timer_create");
      struct itimerspec its = { { 0, 200000000L }, { 0, 200000000L } };
      if (timer_settime(tid, 0, &its, NULL) < 0) die("timer_settime"); }
""")

feat("sigaltstack", "대체 시그널 스택 (크래시 핸들러 관례)", "low", 0, """
    { stack_t ss; ss.ss_sp = malloc(SIGSTKSZ); ss.ss_size = SIGSTKSZ; ss.ss_flags = 0;
      if (!ss.ss_sp) die("sigaltstack malloc");
      if (sigaltstack(&ss, NULL) < 0) die("sigaltstack"); KEEP(ss.ss_sp); }
""")

feat("cwd_tmp", "작업 디렉터리 이동 (앱 데이터 디렉터리)", "low — cwd 경로 존재 필요", 0, """
    { snprintf(g_path_cwd, sizeof(g_path_cwd), "/tmp/criuprobe_cwd_p%d", g_port);
      mkdir(g_path_cwd, 0755);
      if (chdir(g_path_cwd) < 0) die("chdir"); }
""")

feat("devnull", "/dev/null 추가 fd 3개", "low", 0, """
    { for (int i = 0; i < 3; i++) { int fd = open("/dev/null", O_RDWR);
        if (fd < 0) die("devnull open"); KEEPFD(fd); } }
""")

feat("devurandom", "/dev/urandom fd (난수 소스 상시 오픈)", "medium — 캐릭터 디바이스", 0, """
    { int fd = open("/dev/urandom", O_RDONLY); if (fd < 0) die("urandom open");
      char b[16]; if (read(fd, b, sizeof(b)) < 0) die("urandom read"); KEEPFD(fd); }
""")

feat("tty", "/dev/tty 오픈 시도 (디버그 콘솔)", "HIGH — 터미널 fd; ctty 없으면 open 자체가 skip", 0, """
    { int fd = open("/dev/tty", O_RDWR);
      if (fd >= 0) KEEPFD(fd);
      printf("PHASE_NOTE tty_open ok=%d errno=%d\\n", fd >= 0, fd >= 0 ? 0 : errno);
      fflush(stdout); }
""")

feat("netlink", "NETLINK_ROUTE 소켓 (네트워크 상태 감시)", "HIGH — netlink 복원 제한", 0, """
    { int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
      if (fd < 0) die("netlink socket");
      struct sockaddr_nl a; memset(&a, 0, sizeof(a)); a.nl_family = AF_NETLINK;
      a.nl_groups = RTMGRP_LINK;
      if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) die("netlink bind");
      KEEPFD(fd); }
""")

feat("abstract_unix", "abstract namespace UNIX listen (경로 없는 버스)", "medium", 0, """
    { int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) die("aus socket");
      struct sockaddr_un a; memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
      int n = snprintf(a.sun_path + 1, sizeof(a.sun_path) - 1, "criuprobe_abs_p%d", g_port);
      if (bind(fd, (struct sockaddr *)&a, sizeof(sa_family_t) + 1 + n) < 0) die("aus bind");
      if (listen(fd, 4) < 0) die("aus listen"); KEEPFD(fd); }
""")

feat("lock_flock", "flock 배타 락 보유 (단일 인스턴스 락파일)", "HIGH — 기본 옵션 dump 거부 예상 (--file-locks 필요)", 0, """
    { snprintf(g_path_flock, sizeof(g_path_flock), "/tmp/criuprobe_flock_p%d", g_port);
      int fd = open(g_path_flock, O_CREAT | O_RDWR, 0644); if (fd < 0) die("flock open");
      if (flock(fd, LOCK_EX) < 0) die("flock"); KEEPFD(fd); }
""")

feat("lock_posix", "fcntl POSIX 레코드 락 보유 (DB 파일 락)", "HIGH — --file-locks 필요", 0, """
    { snprintf(g_path_plock, sizeof(g_path_plock), "/tmp/criuprobe_plock_p%d", g_port);
      int fd = open(g_path_plock, O_CREAT | O_RDWR, 0644); if (fd < 0) die("plock open");
      struct flock fl; memset(&fl, 0, sizeof(fl)); fl.l_type = F_WRLCK; fl.l_whence = SEEK_SET;
      if (fcntl(fd, F_SETLK, &fl) < 0) die("fcntl F_SETLK"); KEEPFD(fd); }
""")

# ---------------------------------------------------------------------------
# 현실적 composite 시나리오 (webOS 앱/서비스 유형 → feature 조합)
# ---------------------------------------------------------------------------
COMPOSITES = [
    ("c_media_hls",      ["tcp_established", "thread4", "timerfd", "memfd"], "HLS 스트리밍 플레이어: 서버 연결 + 디코더 스레드풀 + 프레임 타이머 + 렌더 버퍼"),
    ("c_media_local",    ["mmap_priv", "timerfd", "thread1"], "로컬 미디어 재생: 파일 매핑 + 타이머 + I/O 스레드"),
    ("c_dvr",            ["logfile", "lock_flock", "timerfd"], "DVR 녹화 서비스: 녹화 로그 + 파일 락 + 스케줄 타이머"),
    ("c_epg",            ["shm_posix", "inotify", "mmap_shared"], "EPG 캐시 서비스: 공유메모리 + 데이터 갱신 감시 + 캐시 파일 매핑"),
    ("c_luna_client",    ["unix_conn", "epoll", "eventfd"], "luna-service 버스 클라이언트: 버스 연결 + 이벤트 루프"),
    ("c_luna_daemon",    ["unix_listen", "epoll", "child"], "버스 데몬: UNIX listen + 이벤트 루프 + 워커 프로세스"),
    ("c_launcher",       ["child", "grandchild", "session"], "앱 런처: 2단 자식 트리 + 세션 분리"),
    ("c_browser",        ["thread4", "large_heap", "memfd", "socketpair"], "웹앱/브라우저 탭: 스레드풀 + 대형 힙 + 렌더 버퍼 + 내부 채널"),
    ("c_ads",            ["udp", "itimer", "logfile"], "광고/비콘 모듈: UDP + 주기 타이머 + 로그"),
    ("c_voice",          ["signalfd", "thread1", "pipe"], "음성 에이전트: 시그널 제어 + 오디오 스레드 + 파이프"),
    ("c_photos",         ["mmap_priv", "large_heap"], "사진 뷰어: 이미지 매핑 + 디코딩 힙"),
    ("c_game",           ["large_heap", "thread4", "futex_wait"], "네이티브 게임: 대형 힙 + 스레드풀 + 유휴 워커(futex)"),
    ("c_settings",       ["mq", "sem_sysv", "logfile"], "설정 서비스: 메시지 큐 + 레거시 세마포어 + 로그"),
    ("c_updater",        ["inotify", "tmpunlink", "lock_posix"], "업데이트 데몬: 디렉터리 감시 + 임시파일 + DB 락"),
    ("c_screensaver",    ["timerfd", "mmap_priv"], "스크린세이버: 타이머 + 리소스 매핑"),
    ("c_telemetry",      ["udp", "logfile", "posix_timer"], "텔레메트리: UDP 송신 + 로그 + RT 타이머"),
    ("c_broker",         ["socketpair", "unix_listen", "epoll"], "IPC 브로커: 내부 채널 + UNIX listen + 이벤트 루프"),
    ("c_db",             ["lock_posix", "mmap_shared", "logfile"], "임베디드 DB 서비스: 레코드 락 + 파일 매핑 + WAL 로그"),
    ("c_thumbnailer",    ["child", "pipe", "tmpunlink"], "썸네일 생성기: 자식 워커 + 파이프 + 임시파일"),
    ("c_notify",         ["eventfd", "timerfd", "unix_conn"], "알림 서비스: 이벤트 fd + 타이머 + 버스 연결"),
    ("c_input",          ["epoll", "timerfd", "unix_listen"], "입력 서비스: 이벤트 루프 + 리핏 타이머 + UNIX listen"),
    ("c_wifi",           ["netlink", "epoll"], "Wi-Fi 매니저: netlink 감시 + 이벤트 루프"),
    ("c_bt",             ["netlink", "thread1", "eventfd"], "블루투스 매니저: netlink + 워커 + 이벤트 fd"),
    ("c_appstore",       ["tcp_established", "tmpunlink", "logfile"], "앱스토어 다운로더: 서버 연결 + 다운로드 임시파일 + 로그"),
    ("c_backup",         ["lock_flock", "mmap_shared", "child"], "백업 서비스: 락 + 파일 매핑 + 워커 프로세스"),
    ("c_debug_console",  ["tty", "pipe"], "디버그 콘솔 브리지: tty + 파이프"),
    ("c_watchdog",       ["itimer", "signalfd", "logfile"], "워치독: 주기 SIGALRM + signalfd + 로그"),
    ("c_cache_mgr",      ["tmpunlink", "inotify", "shm_posix"], "캐시 매니저: ghost 파일 + 감시 + 공유메모리"),
    ("c_audio",          ["shm_sysv", "timerfd", "thread1"], "오디오 서버: SysV shm 버퍼 + 주기 타이머 + 스레드"),
    ("c_render",         ["memfd", "shm_posix", "thread4"], "렌더 서비스: memfd + 공유메모리 + 스레드풀"),
]

# 100개 채우기용 자동 pair 조합: 위험 feature × 흔한 feature (결정적 순서)
PAIR_RISKY = ["tcp_established", "lock_flock", "lock_posix", "netlink", "shm_sysv",
              "futex_wait", "grandchild", "session", "tmpunlink", "unix_conn",
              "mmap_shared", "inotify", "itimer"]
PAIR_COMMON = ["timerfd", "epoll", "thread1", "large_heap", "logfile", "eventfd"]

C_TEMPLATE = r'''/* AUTO-GENERATED by failprobe/gen_workloads.py — 수정하지 말 것 (재생성됨)
 * workload: {name}
 * scenario: {desc}
 * features: {feats}
 * 계약 v2: A1(named flags)/A2(PHASE+fflush)/A6(핑퐁) 준수. A4는 탐침 목적상 의도적 위반.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <mqueue.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "flags.h"
#include "probe_server.h"

static void die(const char *m) {{ perror(m); exit(1); }}

static void *g_keep[128]; static int g_keepn;
static int g_keepfd[128]; static int g_keepfdn;
#define KEEP(p)   do {{ if (g_keepn < 128) g_keep[g_keepn++] = (void *)(p); }} while (0)
#define KEEPFD(f) do {{ if (g_keepfdn < 128) g_keepfd[g_keepfdn++] = (f); }} while (0)
#define PHASE(nm) do {{ printf("PHASE %s\n", nm); fflush(stdout); }} while (0)

#define WL_UNUSED __attribute__((unused))
static char *g_base; static size_t g_base_n;
static int g_port WL_UNUSED;
static int g_logfd WL_UNUSED = -1, g_tfd WL_UNUSED = -1, g_usfd WL_UNUSED = -1, g_semid WL_UNUSED = -1;
static char g_path_logfile[128] WL_UNUSED, g_path_fifo[128] WL_UNUSED, g_path_us[96] WL_UNUSED, g_path_watch[128] WL_UNUSED;
static char g_path_shm[128] WL_UNUSED, g_path_mq[128] WL_UNUSED, g_path_map[128] WL_UNUSED, g_path_maps[128] WL_UNUSED;
static char g_path_cwd[128] WL_UNUSED, g_path_flock[128] WL_UNUSED, g_path_plock[128] WL_UNUSED;

static void WL_UNUSED wk_sig_noop(int s) {{ (void)s; }}
static void * WL_UNUSED wk_sleeper(void *a) {{ (void)a;
    for (;;) {{ struct timespec ts = {{ 0, 50000000L }}; nanosleep(&ts, NULL); }}
    return NULL; }}
static pthread_mutex_t g_fx_mu WL_UNUSED = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_fx_cv WL_UNUSED = PTHREAD_COND_INITIALIZER;
static void * WL_UNUSED wk_futex_wait(void *a) {{ (void)a;
    pthread_mutex_lock(&g_fx_mu);
    for (;;) pthread_cond_wait(&g_fx_cv, &g_fx_mu);
    return NULL; }}
static long WL_UNUSED now_ms(void) {{ struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L; }}

/* -Wall 침묵용: feature 미포함 빌드에서도 공통 심볼을 '사용됨'으로 만든다 */
static __attribute__((used)) void wl_ref_all_(void)
{{
    (void)g_keep; (void)g_keepn; (void)g_keepfd; (void)g_keepfdn;
    (void)g_base; (void)g_base_n; (void)g_port;
    (void)g_logfd; (void)g_tfd; (void)g_usfd; (void)g_semid;
    (void)g_path_logfile; (void)g_path_fifo; (void)g_path_us; (void)g_path_watch;
    (void)g_path_shm; (void)g_path_mq; (void)g_path_map; (void)g_path_maps;
    (void)g_path_cwd; (void)g_path_flock; (void)g_path_plock;
    (void)wk_sig_noop; (void)wk_sleeper; (void)wk_futex_wait;
    (void)g_fx_mu; (void)g_fx_cv; (void)now_ms; (void)die;
}}

/* phase 관측→freeze 사이 at-or-after 스큐 제거: 각 phase 직후 gap 동안 머물러
 * dump가 "정확히 그 라인 직후 상태"를 얼리게 한다 (호환성 판정 전용 — 시간 측정에는
 * 이 gap이 들어가면 안 되므로 crossover류 측정에 쓸 땐 --phase_gap_ms 0). */
static void phase_gap(long ms)
{{
    if (ms <= 0) return;
    struct timespec ts = {{ ms / 1000, (ms % 1000) * 1000000L }};
    nanosleep(&ts, NULL);
}}

int main(int argc, char **argv)
{{
    long bytes = wl_flag_long(argc, argv, "--bytes", 52428800);
    long port  = wl_flag_long(argc, argv, "--port", 18080);
    long gap_ms = wl_flag_long(argc, argv, "--phase_gap_ms", 400);
    g_port = (int)port;
    PHASE("init"); phase_gap(gap_ms);

    /* base 상주 메모리 (--bytes) */
    if (bytes > 0) {{
        g_base = malloc((size_t)bytes); if (!g_base) die("base malloc");
        g_base_n = (size_t)bytes;
        for (size_t i = 0; i < g_base_n; i += 4096) g_base[i] = 1;
    }}
    PHASE("base_mem"); phase_gap(gap_ms);

{setup_blocks}
    int actual_port = 0;
    int lfd = probe_listen((int)port, &actual_port);
    printf("PHASE ready port=%d\n", actual_port); fflush(stdout);

    long t0 = now_ms(); int steady = 0;
    for (;;) {{
        probe_serve_pending(lfd, 100);
{tick_blocks}        if (!steady && now_ms() - t0 > 400) {{ PHASE("steady"); steady = 1; }}
    }}
    return 0;
}}
'''

MANIFEST_TEMPLATE = """name: {name}
# AUTO-GENERATED failprobe workload — {desc}
# features: {feats}
# expected risks: {risks}
params:
  bytes: {{default: 52428800}}
  port:  {{default: 18080}}
  phase_gap_ms: {{default: 400}}   # phase별 정지 창(호환성 스윕용); 시간 측정 시 0
phases: [{phases}]
metrics: []
resident:
  from_param: bytes
  bytes_per_unit: 1
  overhead_mib: {overhead}
"""


def split_guarded(line):
    """`if (...) die("x"); REST;` 를 줄 분리해 -Wmisleading-indentation 회피."""
    m = re.match(r'^(\s*)(if\s*\(.*?\)\s*(?:die|printf)\([^;]*\);)\s+(\S.*)$', line)
    if m:
        return [m.group(1) + m.group(2), m.group(1) + m.group(3)]
    return [line]


def indent(code, n=4):
    pad = " " * n
    out = []
    for l in code.strip("\n").split("\n"):
        for part in split_guarded(l):
            out.append(pad + part if part.strip() else part)
    return "\n".join(out)


def gen_one(name, feats, desc, outdir, granularity="feature"):
    setup_blocks, tick_blocks, risks = [], [], []
    line_phases = []
    overhead = 8  # 코드/libc/스레드 스택 기본 여유
    for f in feats:
        spec = F[f]
        code = spec["setup"]
        f_line_names = []
        if granularity == "line" and code.strip() and not spec.get("atomic"):
            code, f_line_names = instrument_lines(code, f)
        if code.strip():
            setup_blocks.append(indent(code) + f'\n    PHASE("f_{f}"); phase_gap(gap_ms);\n')
        else:
            setup_blocks.append(f'    PHASE("f_{f}"); phase_gap(gap_ms);\n')
        line_phases.extend(f_line_names + [f"f_{f}"])
        if spec["tick"].strip():
            tick_blocks.append(indent(spec["tick"], 8) + "\n")
        risks.append(f"{f}:{spec['risk']}")
        overhead += spec["rss"]
    if "thread4" in feats:
        overhead += 8
    phases = ["init", "base_mem"] + line_phases + ["ready", "served_first", "steady"]
    c_src = C_TEMPLATE.format(name=name, desc=desc, feats=",".join(feats),
                              setup_blocks="".join(setup_blocks),
                              tick_blocks="".join(tick_blocks))
    manifest = MANIFEST_TEMPLATE.format(name=name, desc=desc, feats=",".join(feats),
                                        risks="; ".join(risks),
                                        phases=", ".join(phases), overhead=overhead)
    d = os.path.join(outdir, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "workload.c"), "w") as fh:
        fh.write(c_src)
    with open(os.path.join(d, "workload.yaml"), "w") as fh:
        fh.write(manifest)
    return phases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads-dir", required=True, help="testbed/workloads 경로")
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--prefix", default="fp_")
    ap.add_argument("--granularity", choices=["feature", "line"], default="feature",
                    help="line: setup 구간의 모든 최상위 문장 뒤에 덤프 지점 삽입")
    args = ap.parse_args()

    outdir = args.workloads_dir
    if not os.path.isfile(os.path.join(outdir, "common", "probe_server.h")):
        sys.exit(f"ERROR: {outdir} 가 testbed/workloads 가 아님 (common/probe_server.h 없음)")

    plan = []  # (name, feats, desc)
    for fid in F:  # 단일 feature 탐침
        plan.append((f"{args.prefix}s_{fid}", [fid], f"single-feature probe: {F[fid]['desc']}"))
    for cname, feats, desc in COMPOSITES:
        plan.append((f"{args.prefix}{cname}", feats, desc))
    # 100 채우기: 결정적 pair 조합
    pi = 0
    for r in PAIR_RISKY:
        for c in PAIR_COMMON:
            if len(plan) >= args.count:
                break
            name = f"{args.prefix}p{pi:02d}_{r}__{c}"
            plan.append((name, [r, c], f"pair probe: {F[r]['desc']} + {F[c]['desc']}"))
            pi += 1
        if len(plan) >= args.count:
            break
    plan = plan[:args.count]

    rows = []
    for name, feats, desc in plan:
        phases = gen_one(name, feats, desc, outdir, granularity=args.granularity)
        rows.append(dict(name=name, features=",".join(feats), n_phases=len(phases),
                         phases=" ".join(phases), desc=desc,
                         risks="; ".join(f"{f}:{F[f]['risk']}" for f in feats)))

    # phase → 소스 라인 역추적표
    map_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "phase_map.csv")
    with open(map_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["workload", "phase", "c_line_no", "statement"])
        for name, feats, desc in plan:
            cpath = os.path.join(outdir, name, "workload.c")
            prev_stmt, prev_no = "", 0
            for no, l in enumerate(open(cpath), 1):
                s = l.strip()
                m = re.search(r'PHASE\("([a-z0-9_]+)"\)', s)
                if m and not s.startswith("#define"):
                    w.writerow([name, m.group(1), prev_no, prev_stmt[:160]])
                elif s and "PHASE" not in s:
                    prev_stmt, prev_no = s, no
    print(f"phase→line map: {map_path}")

    csv_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios.csv")
    with open(csv_path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["name", "features", "n_phases", "phases", "desc", "risks"])
        w.writeheader()
        w.writerows(rows)
    print(f"generated {len(plan)} workloads under {outdir}")
    print(f"scenario table: {csv_path}")
    print("next: testbed/workloads/build.sh 로 빌드 (자동 발견)")


if __name__ == "__main__":
    main()
