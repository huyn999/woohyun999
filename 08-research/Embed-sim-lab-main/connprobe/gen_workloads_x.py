#!/usr/bin/env python3
"""webosprobe/gen_workloads_x.py — 봉쇄 조건 행렬 생성기 (fp_x_*, 6종)

criu_x.sh 의 heredoc 에서 추출. failprobe 의 gen_workloads 계약·계측·스켈레톤을 재사용해,
"리스너/커넥터가 같은 프로세스인가 / 다른 프로세스인가 / 덤프 밖인가" 세 교란 요인을
두 전송(UNIX/TCP)에 대해 분리한 6개 워크로드를 testbed/workloads 아래에 만든다.

  backlog_*   리스너=워크로드, 커넥터=자식 프로세스. 둘 다 덤프 안, 그러나 별개 프로세스.
              accept 안 함 → 연결이 백로그에 걸림.  (self-loopback 이 원인이었나?)
  ext_*_pend  커넥터=워크로드, 리스너=외부 xpeer(덤프 밖), accept 안 함.
              워크로드는 클라이언트 소켓만 쥠.  (= 진짜 luna 등록 창 / HLS 수립 창)
  ext_*_est   위와 같되 외부 피어가 accept 완료.  (대조군)

사용:
  python3 gen_workloads_x.py --workloads-dir ../testbed/workloads
그 다음 xpeer(webosprobe/bin/xpeer)를 셀마다 상대로 띄우고 compat_sweep 로 스윕한다
(xmatrix.sh 가 자동으로 함).
"""
import argparse, os, sys

# failprobe/gen_workloads.py 를 찾는다: webosprobe/ 와 ../failprobe/ 둘 다 시도.
_here = os.path.dirname(os.path.abspath(__file__))
for cand in (_here, os.path.join(_here, "..", "failprobe")):
    if os.path.isfile(os.path.join(cand, "gen_workloads.py")):
        sys.path.insert(0, cand)
        break
else:
    sys.exit("ERROR: gen_workloads.py 를 찾을 수 없음 (failprobe/ 가 있어야 함)")
import gen_workloads as g
import gen_workloads_v2  # noqa: F401  (v2 기능 등록 side-effect)

_UADDR = r"""
      struct sockaddr_un xa; memset(&xa, 0, sizeof(xa)); xa.sun_family = AF_UNIX;
      snprintf(xa.sun_path + 1, sizeof(xa.sun_path) - 2, "criuprobe_xpeer_p%d", g_port);
      socklen_t xal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(xa.sun_path + 1));
"""

g.feat("backlog_unix", "UNIX 리스너 + 자식이 connect + 미accept (별개 프로세스, 둘 다 덤프 안)",
       "HIGH — self-loopback 이 아닌 조건에서 UNIX 백로그가 살아남는가", 1, """
{ int bl = socket(AF_UNIX, SOCK_STREAM, 0); if (bl < 0) die("bl sock");
  struct sockaddr_un ba; memset(&ba, 0, sizeof(ba)); ba.sun_family = AF_UNIX;
  snprintf(ba.sun_path + 1, sizeof(ba.sun_path) - 2, "criuprobe_bl_p%d", g_port);
  socklen_t bal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ba.sun_path + 1));
  if (bind(bl, (struct sockaddr *)&ba, bal) < 0) die("bl bind");
  if (listen(bl, 8) < 0) die("bl listen");
  int sy[2]; if (pipe(sy) < 0) die("bl pipe");
  pid_t bc = fork(); if (bc < 0) die("bl fork");
  if (bc == 0) {
      close(sy[0]);
      int c = socket(AF_UNIX, SOCK_STREAM, 0); if (c < 0) _exit(1);
      if (connect(c, (struct sockaddr *)&ba, bal) < 0) _exit(1);
      if (write(sy[1], "x", 1) != 1) _exit(1);
      for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); }
  }
  close(sy[1]); char sb; if (read(sy[0], &sb, 1) != 1) die("bl sync");
  KEEPFD(bl); KEEPFD(sy[0]); }
""", atomic=True)

g.feat("backlog_tcp", "TCP 리스너 + 자식이 connect + 미accept (별개 프로세스, 둘 다 덤프 안)",
       "HIGH — self-loopback 이 아니어도 sk-inet.c:185 가 나는가", 1, """
{ int bp = 0; int bl = probe_listen(0, &bp);
  int sy[2]; if (pipe(sy) < 0) die("bt pipe");
  pid_t bc = fork(); if (bc < 0) die("bt fork");
  if (bc == 0) {
      close(sy[0]);
      int c = socket(AF_INET, SOCK_STREAM, 0); if (c < 0) _exit(1);
      struct sockaddr_in a; memset(&a, 0, sizeof(a)); a.sin_family = AF_INET;
      a.sin_addr.s_addr = htonl(INADDR_LOOPBACK); a.sin_port = htons((uint16_t)bp);
      if (connect(c, (struct sockaddr *)&a, sizeof(a)) < 0) _exit(1);
      if (write(sy[1], "x", 1) != 1) _exit(1);
      for (;;) { struct timespec ts = { 0, 50000000L }; nanosleep(&ts, NULL); }
  }
  close(sy[1]); char sb; if (read(sy[0], &sb, 1) != 1) die("bt sync");
  KEEPFD(bl); KEEPFD(sy[0]); }
""", atomic=True)

g.feat("ext_unix_pend", "외부 허브(덤프 밖)에 connect, 상대는 아직 accept 안 함",
       "HIGH — 실제 luna 등록 창", 1, """
{ int xc = socket(AF_UNIX, SOCK_STREAM, 0); if (xc < 0) die("xup sock");
""" + _UADDR + """
      if (connect(xc, (struct sockaddr *)&xa, xal) < 0) die("xup connect");
      KEEPFD(xc); }
""")

g.feat("ext_tcp_pend", "외부 서버(덤프 밖)에 connect, 상대는 아직 accept 안 함",
       "HIGH — 실제 HLS 수립 창", 1, """
{ int xc = socket(AF_INET, SOCK_STREAM, 0); if (xc < 0) die("xtp sock");
  struct sockaddr_in xt; memset(&xt, 0, sizeof(xt)); xt.sin_family = AF_INET;
  xt.sin_addr.s_addr = htonl(INADDR_LOOPBACK); xt.sin_port = htons((uint16_t)(g_port + 3000));
  if (connect(xc, (struct sockaddr *)&xt, sizeof(xt)) < 0) die("xtp connect");
  KEEPFD(xc); }
""")

g.feat("ext_unix_est", "외부 허브(덤프 밖)와 성립된 UNIX 연결 + 전송 완료",
       "medium — 외부 소켓 dump/restore", 1, """
{ int xc = socket(AF_UNIX, SOCK_STREAM, 0); if (xc < 0) die("xue sock");
""" + _UADDR + """
      if (connect(xc, (struct sockaddr *)&xa, xal) < 0) die("xue connect");
      if (write(xc, "{\\"register\\":1}", 14) != 14) die("xue write");
      KEEPFD(xc); }
""")

g.feat("ext_tcp_est", "외부 서버(덤프 밖)와 성립된 TCP 연결 + 전송 완료",
       "medium — 외부 TCP dump/restore", 1, """
{ int xc = socket(AF_INET, SOCK_STREAM, 0); if (xc < 0) die("xte sock");
  struct sockaddr_in xt; memset(&xt, 0, sizeof(xt)); xt.sin_family = AF_INET;
  xt.sin_addr.s_addr = htonl(INADDR_LOOPBACK); xt.sin_port = htons((uint16_t)(g_port + 3000));
  if (connect(xc, (struct sockaddr *)&xt, sizeof(xt)) < 0) die("xte connect");
  if (write(xc, "hello", 5) != 5) die("xte write");
  KEEPFD(xc); }
""")

W = [
 ("fp_x_backlog_unix",  ["backlog_unix"],  "봉쇄A: 리스너=나, 커넥터=자식(덤프 안), 미accept"),
 ("fp_x_backlog_tcp",   ["backlog_tcp"],   "봉쇄A: 동일 조건의 TCP — self-loopback 교란 제거"),
 ("fp_x_ext_unix_pend", ["ext_unix_pend"], "봉쇄B: 리스너=외부 허브(덤프 밖), 미accept"),
 ("fp_x_ext_tcp_pend",  ["ext_tcp_pend"],  "봉쇄B: 리스너=외부 서버(덤프 밖), 미accept"),
 ("fp_x_ext_unix_est",  ["ext_unix_est"],  "봉쇄C: 외부 허브와 성립 완료 — 대조군"),
 ("fp_x_ext_tcp_est",   ["ext_tcp_est"],   "봉쇄C: 외부 서버와 성립 완료 — 대조군"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads-dir", required=True)
    a = ap.parse_args()
    total = 0
    for name, feats, desc in W:
        ph = g.gen_one(name, feats, f"[X] 봉쇄 행렬: {desc}", a.workloads_dir, granularity="line")
        total += len(ph) - 1
        print(f"  {name}: {len(ph)} phases")
    print(f"generated {len(W)} workloads (셀 {total}개)")


if __name__ == "__main__":
    main()
