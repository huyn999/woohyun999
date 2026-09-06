#!/usr/bin/env python3
"""gen_workloads_v2.py — failprobe 확장축 생성기 (기존 100종 불변, fp_x_* 추가)

"모든 가능성" 지도에서 v1이 비워둔 커널 객체 축을 채우는 단일 탐침 16종.
gen_workloads.py의 계약·계측·스켈레톤을 그대로 재사용한다.

    python3 gen_workloads_v2.py --workloads-dir testbed/workloads
    testbed/workloads/build.sh
    sudo CONSTRAINED=1 PERMISSIVE=1 PHASE_GAP_MS=150 PHASE_TIMEOUT_S=40 \
         failprobe/compat_sweep.sh 'fp_x_*'      # 확장분만 스윕

privilege/커널버전 의존 자원은 원본 tty와 같은 skip 규약을 따른다:
획득 실패 시 PHASE_NOTE를 남기고 자원 없이 통과 — '못 얻은 상태'가
'얻고 못 얼린 상태'로 오염되지 않는다.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_workloads as g

X = {}
def xfeat(fid, desc, risk, rss, setup, atomic=False):
    g.feat(fid, desc, risk, rss, setup, atomic=atomic)
    X[fid] = desc

# ── IPC/소켓 확장 ────────────────────────────────────────────────────────────
xfeat("scm_inflight", "UNIX 소켓 버퍼에 '배달 중' fd (SCM_RIGHTS 미수신)", "HIGH — fd-passing in-flight", 1, """
{ int sp[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) < 0) die("scm socketpair");
  int payload = open("/dev/null", O_RDONLY); if (payload < 0) die("scm payload");
  struct msghdr mh; memset(&mh, 0, sizeof(mh));
  char dat = 'F'; struct iovec iov = { &dat, 1 }; mh.msg_iov = &iov; mh.msg_iovlen = 1;
  char cbuf[CMSG_SPACE(sizeof(int))]; memset(cbuf, 0, sizeof(cbuf));
  mh.msg_control = cbuf; mh.msg_controllen = sizeof(cbuf);
  struct cmsghdr *cm = CMSG_FIRSTHDR(&mh); cm->cmsg_level = SOL_SOCKET;
  cm->cmsg_type = SCM_RIGHTS; cm->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(cm), &payload, sizeof(int));
  if (sendmsg(sp[0], &mh, 0) < 0) die("scm sendmsg");
  KEEPFD(sp[0]); KEEPFD(sp[1]); KEEPFD(payload); }
""")

xfeat("unix_dgram", "UNIX 데이터그램 쌍 + 미수신 패킷", "medium", 1, """
{ int sp[2]; if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sp) < 0) die("dgram socketpair");
  if (send(sp[0], "evt", 3, 0) != 3) die("dgram send");
  KEEPFD(sp[0]); KEEPFD(sp[1]); }
""")

xfeat("raw_icmp", "raw ICMP 소켓 (네트워크 진단 데몬)", "HIGH — raw sk 복원", 1, """
{ int r = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
  if (r >= 0) KEEPFD(r);
  printf("PHASE_NOTE raw_icmp ok=%d errno=%d\\n", r >= 0, r >= 0 ? 0 : errno);
  fflush(stdout); }
""")

# ── 신형 fd 계열 ─────────────────────────────────────────────────────────────
xfeat("io_uring", "io_uring 링 fd (현대 비동기 I/O)", "HIGH — CRIU 미지원 예상", 2, """
{ struct { unsigned a[40]; } params; memset(&params, 0, sizeof(params));
  long u = syscall(425 /* io_uring_setup */, 8, &params);
  if (u >= 0) KEEPFD((int)u);
  printf("PHASE_NOTE io_uring ok=%d errno=%d\\n", u >= 0, u >= 0 ? 0 : (int)-u);
  fflush(stdout); }
""", atomic=True)

xfeat("pidfd", "pidfd (프로세스 핸들 — 신형 감시/워치독)", "medium", 1, """
{ long p = syscall(434 /* pidfd_open */, (long)getpid(), 0L);
  if (p >= 0) KEEPFD((int)p);
  printf("PHASE_NOTE pidfd ok=%d\\n", p >= 0); fflush(stdout); }
""", atomic=True)

xfeat("uffd", "userfaultfd + 등록 페이지 (사용자 공간 페이징)", "HIGH", 2, """
{ long u = syscall(323 /* userfaultfd */, (long)O_CLOEXEC);
  if (u >= 0) {
      struct { uint64_t api, features, ioctls; } a = { 0xAA, 0, 0 };
      if (syscall(16 /* ioctl */, u, 0xc018aa3fL /* UFFDIO_API */, &a) == 0) {
          void *pg = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
          struct { struct { uint64_t start, len; } range; uint64_t mode, ioctls; } r
              = { { (uint64_t)pg, 4096 }, 1 /* MISSING */, 0 };
          syscall(16, u, 0xc020aa00L /* UFFDIO_REGISTER */, (long)&r);
          KEEP(pg);
      }
      KEEPFD((int)u);
  }
  printf("PHASE_NOTE uffd ok=%d errno=%d\\n", u >= 0, u >= 0 ? 0 : (int)-u);
  fflush(stdout); }
""", atomic=True)

# ── 파일 계열 확장 ───────────────────────────────────────────────────────────
xfeat("o_tmpfile", "O_TMPFILE 무명 파일 (이름이 애초에 없는 임시파일)", "medium — ghost의 극단형", 2, """
{ int t = open("/tmp", O_TMPFILE | O_RDWR, 0600);
  if (t >= 0) { if (write(t, "tmpdata", 7) != 7) die("o_tmpfile write"); KEEPFD(t); }
  printf("PHASE_NOTE o_tmpfile ok=%d errno=%d\\n", t >= 0, t >= 0 ? 0 : errno);
  fflush(stdout); }
""")

xfeat("lease_rd", "파일 read lease (F_SETLEASE — 캐시 무결성 프로토콜)", "HIGH — lease 복원", 1, """
{ snprintf(g_path_map, sizeof(g_path_map), "/tmp/criuprobe_lease_p%d", g_port);
  int lf = open(g_path_map, O_CREAT | O_RDONLY, 0600); if (lf < 0) die("lease open");
  int lr = fcntl(lf, F_SETLEASE, F_RDLCK);
  KEEPFD(lf);
  printf("PHASE_NOTE lease ok=%d errno=%d\\n", lr == 0, lr == 0 ? 0 : errno);
  fflush(stdout); }
""")

# ── 메모리 계열 확장 ─────────────────────────────────────────────────────────
xfeat("memfd_seal", "봉인된 memfd (F_SEAL_WRITE — 불변 공유버퍼 프로토콜)", "medium", 4, """
{ int m = syscall(319 /* memfd_create */, "criuprobe_sealed", 2U /* ALLOW_SEALING */);
  if (m < 0) die("memfd_seal create");
  if (ftruncate(m, 1 << 20) < 0) die("memfd_seal trunc");
  if (fcntl(m, 1033 /* F_ADD_SEALS */, 1|2|8 /* SEAL|SHRINK|GROW|WRITE */) < 0) die("memfd_seal seal");
  void *mp = mmap(NULL, 1 << 20, PROT_READ, MAP_SHARED, m, 0);
  if (mp == MAP_FAILED) die("memfd_seal mmap");
  KEEPFD(m); KEEP(mp); }
""")

xfeat("mmap_exec_jit", "실행가능 익명 페이지 + 실제 점프 (JIT 최소형 — V8/JS엔진)", "HIGH — exec 페이지 복원", 2, """
{ unsigned char *jit = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  if (jit == MAP_FAILED) die("jit mmap");
  jit[0] = 0xB8; jit[1] = 0x2A; jit[2] = 0; jit[3] = 0; jit[4] = 0; jit[5] = 0xC3; /* mov eax,42; ret */
  if (mprotect(jit, 4096, PROT_READ|PROT_EXEC) < 0) die("jit mprotect");
  int (*fn)(void) = (int (*)(void))jit;
  if (fn() != 42) die("jit exec");
  KEEP(jit); }
""", atomic=True)

xfeat("hugetlb", "hugepage 매핑 (MAP_HUGETLB — 미디어/DB 대형버퍼)", "HIGH", 4, """
{ void *h = mmap(NULL, 2 << 20, PROT_READ|PROT_WRITE,
                 MAP_PRIVATE|MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
  if (h != MAP_FAILED) { memset(h, 7, 4096); KEEP(h); }
  printf("PHASE_NOTE hugetlb ok=%d errno=%d\\n", h != MAP_FAILED, h != MAP_FAILED ? 0 : errno);
  fflush(stdout); }
""", atomic=True)

# ── 시그널/보안/프로세스 계열 확장 ───────────────────────────────────────────
xfeat("sig_pending", "블록된 RT 시그널 3개 pending (미처리 이벤트 큐)", "medium — 시그널 큐 복원", 1, """
{ sigset_t bs; sigemptyset(&bs); sigaddset(&bs, SIGRTMIN);
  if (sigprocmask(SIG_BLOCK, &bs, NULL) < 0) die("sig block");
  union sigval v; v.sival_int = 7;
  if (sigqueue(getpid(), SIGRTMIN, v) < 0) die("sigqueue1");
  if (sigqueue(getpid(), SIGRTMIN, v) < 0) die("sigqueue2");
  if (sigqueue(getpid(), SIGRTMIN, v) < 0) die("sigqueue3"); }
""")

xfeat("seccomp_allow", "seccomp BPF 필터 설치 (샌드박스 최소형)", "HIGH — 필터 복원", 1, """
{ struct wk_sf { unsigned short code; unsigned char jt, jf; unsigned int k; };
  struct wk_sf allow = { 0x06, 0, 0, 0x7fff0000U /* RET_ALLOW */ };
  struct wk_fp { unsigned short len; struct wk_sf *filter; } prog = { 1, &allow };
  if (syscall(157 /* prctl */, 38L /* NO_NEW_PRIVS */, 1L, 0L, 0L, 0L) < 0) die("nnp");
  long sr = syscall(157, 22L /* SET_SECCOMP */, 2L /* FILTER */, (long)&prog, 0L, 0L);
  printf("PHASE_NOTE seccomp ok=%d errno=%d\\n", sr == 0, sr == 0 ? 0 : errno);
  fflush(stdout); }
""", atomic=True)

xfeat("epoll_excl", "EPOLLEXCLUSIVE 등록 (thundering-herd 회피 관용구)", "medium", 1, """
{ int ep = epoll_create1(0); if (ep < 0) die("epx create");
  int ev = eventfd(0, 0); if (ev < 0) die("epx eventfd");
  struct epoll_event e; memset(&e, 0, sizeof(e));
  e.events = EPOLLIN | (1U << 28) /* EPOLLEXCLUSIVE */; e.data.fd = ev;
  if (epoll_ctl(ep, EPOLL_CTL_ADD, ev, &e) < 0) die("epx ctl");
  KEEPFD(ep); KEEPFD(ev); }
""")

xfeat("many_fds", "fd 256개 (대규모 fd 테이블 — 스케일 축)", "low — 규모만", 2, """
{ int i; for (i = 0; i < 256; i++) { int d = open("/dev/null", O_RDONLY);
      if (d < 0) die("many_fds open"); KEEPFD(d); } }
""", atomic=True)

xfeat("deep_tree", "6단 프로세스 체인 (깊은 트리 — 위상 축)", "medium — 깊이 스케일", 1, """
{ int depth; pid_t c;
  for (depth = 0; depth < 6; depth++) {
      c = fork(); if (c < 0) die("deep fork");
      if (c > 0) break;
  }
  if (depth == 6 || c == 0) { /* leaf 또는 중간: 대기 루프 */ }
  if (c == 0) { for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); } } }
""", atomic=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads-dir", required=True)
    ap.add_argument("--prefix", default="fp_x_")
    a = ap.parse_args()
    if not os.path.isfile(os.path.join(a.workloads_dir, "common", "probe_server.h")):
        sys.exit("ERROR: workloads-dir가 testbed/workloads가 아님")
    made = []
    for fid, desc in X.items():
        name = f"{a.prefix}s_{fid}"
        phases = g.gen_one(name, [fid], f"v2 extension probe: {desc}", a.workloads_dir,
                           granularity="line")
        made.append((name, len(phases)))
    total = sum(n - 1 for _, n in made)  # served_first 제외
    print(f"generated {len(made)} extension workloads (셀 {total}개 예상)")
    for n, p in made: print(f"  {n}: {p} phases")
    print("next: workloads/build.sh → compat_sweep.sh 'fp_x_*'")

if __name__ == "__main__":
    main()
