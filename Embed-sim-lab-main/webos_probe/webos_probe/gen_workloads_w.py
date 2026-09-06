#!/usr/bin/env python3
"""webos_probe/gen_workloads_w.py — webOS 충실 워크로드 생성기 (fp_w_*, 23종)

webOS OSE 아키텍처 문서(Managers & Services / Base Components 층)의 컴포넌트를
커널 객체 언어로 번역한 워크로드 집합. 세 부류를 의도적으로 섞는다:

  [P] 통과 예상군    — webOS 실재 상황의 정상 성분 조합 → "실재 상황은 얼려진다" 입증용
  [R] 실패 재현군    — 기측정 실패요인의 webOS 맥락 재현(대조쌍 포함) → 등급 판정 입증용
  [U] 미지수         — 미측정 성분 (UNIX in-flight = luna 등록 창) → 신규 발견 후보

의존: ../failprobe/gen_workloads.py (+_v2: jit 등 확장 feat)
"""
import argparse, os, sys
_here = os.path.dirname(os.path.abspath(__file__))
for cand in (_here, os.path.join(_here, "..", "failprobe")):
    if os.path.isfile(os.path.join(cand, "gen_workloads.py")):
        sys.path.insert(0, cand); break
else:
    sys.exit("ERROR: gen_workloads.py를 찾을 수 없음 (webos_probe 옆에 failprobe/ 필요)")
import gen_workloads as g
import gen_workloads_v2  # noqa: F401 — mmap_exec_jit 등 확장 feat 등록

# ── webOS 전용 신규 feat ──────────────────────────────────────────────────────
g.feat("unix_inflight", "UNIX 소켓 connect~accept 창 (luna 버스 등록 순간)",
       "HIGH — tcp in-flight의 유닉스 대응 여부", 1, """
{ int ul = socket(AF_UNIX, SOCK_STREAM, 0); if (ul < 0) die("uif lsock");
  struct sockaddr_un ua; memset(&ua, 0, sizeof(ua)); ua.sun_family = AF_UNIX;
  snprintf(ua.sun_path + 1, sizeof(ua.sun_path) - 2, "criuprobe_uif_p%d", g_port);
  socklen_t ual = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ua.sun_path + 1));
  if (bind(ul, (struct sockaddr *)&ua, ual) < 0) die("uif bind");
  if (listen(ul, 8) < 0) die("uif listen");
  int uc = socket(AF_UNIX, SOCK_STREAM, 0); if (uc < 0) die("uif csock");
  if (connect(uc, (struct sockaddr *)&ua, ual) < 0) die("uif connect");
  int us = accept(ul, NULL, NULL); if (us < 0) die("uif accept");
  if (write(uc, "{\\"register\\":1}", 14) != 14) die("uif write");
  KEEPFD(ul); KEEPFD(uc); KEEPFD(us); }
""")

g.feat("unix_fanin", "허브 fan-in: UNIX listen + 성립 연결 8쌍 + 미소비 JSON",
       "medium — 다연결·큐잉 스케일", 2, """
{ int hl = socket(AF_UNIX, SOCK_STREAM, 0); if (hl < 0) die("fan lsock");
  struct sockaddr_un ha; memset(&ha, 0, sizeof(ha)); ha.sun_family = AF_UNIX;
  snprintf(ha.sun_path + 1, sizeof(ha.sun_path) - 2, "criuprobe_hub_p%d", g_port);
  socklen_t hal = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(ha.sun_path + 1));
  if (bind(hl, (struct sockaddr *)&ha, hal) < 0) die("fan bind");
  if (listen(hl, 16) < 0) die("fan listen");
  KEEPFD(hl);
  int i; for (i = 0; i < 8; i++) {
      int c = socket(AF_UNIX, SOCK_STREAM, 0); if (c < 0) die("fan csock");
      if (connect(c, (struct sockaddr *)&ha, hal) < 0) die("fan connect");
      int a = accept(hl, NULL, NULL); if (a < 0) die("fan accept");
      if (write(c, "{\\"method\\":\\"call\\"}", 18) != 18) die("fan write");
      KEEPFD(c); KEEPFD(a);
  } }
""", atomic=True)

# ── 워크로드 카탈로그: (이름, 성분, 부류, 대응 컴포넌트/근거) ─────────────────
W = [
 # ------- Base Components -------
 ("fp_w_hub",            ["unix_fanin","epoll","logfile"],                          "P",
  "ls-hubd — 중앙 교환소: listen + 성립 연결 8쌍(미소비 JSON) + epoll + pmlog"),
 ("fp_w_registration",   ["unix_inflight"],                                          "U",
  "버스 등록 순간 — luna 전송(UNIX)의 connect~accept 창: 유일한 미측정 성분"),
 ("fp_w_client_sub",     ["unix_conn","epoll","timerfd"],                            "P",
  "구독 클라이언트 — 장수 버스 연결 + 하트비트"),
 ("fp_w_dynamic_svc",    ["child","unix_conn","epoll"],                              "P",
  "동적 서비스 — 요청 시 spawn + 버스 연결"),
 # ------- Managers & Services -------
 ("fp_w_sam",            ["child","grandchild","unix_listen","epoll"],               "P",
  "SAM — 앱 생명주기 매니저: 앱 트리 + 수신 버스 (올바른 데몬화 순서)"),
 ("fp_w_sam_bad_order",  ["child","grandchild","session","unix_listen"],             "R",
  "SAM 순서 실수 재현 — 트리 생성 후 setsid (fp_w_sam과 한 성분 대조쌍, 클러스터 ② 재현)"),
 ("fp_w_wam_renderer",   ["mmap_exec_jit","large_heap","thread4","unix_conn","memfd"],"P",
  "WAM 웹앱 렌더러 — Chromium 멀티프로세스 1개: V8 JIT + 300MB 힙 + 스레드풀 + 버스"),
 ("fp_w_enact_browser",  ["mmap_exec_jit","large_heap","memfd","tcp_established","unix_conn"],"R",
  "Enact 브라우저 — JIT + 힙 + 원격 연결: tcp l05 창의 webOS 재현(클러스터 ①) 포함"),
 ("fp_w_qml_app",        ["large_heap","thread4","mmap_priv","unix_conn"],           "P",
  "QML 시스템 UI 앱 — 씬 리소스 매핑 + 렌더 스레드 + 버스"),
 ("fp_w_js_service",     ["mmap_exec_jit","unix_conn","timerfd"],                    "P",
  "Node 기반 JS 서비스 — JIT + 버스 + 주기 타이머"),
 ("fp_w_appinstalld",    ["child","tmpunlink","inotify","logfile"],                  "P",
  "appinstalld — 설치 파이프라인: 워커 + 임시파일 + 감시 + 로그"),
 ("fp_w_settings_svc",   ["unix_listen","epoll","lock_posix","logfile"],             "P",
  "settingsservice — 수신 버스 + 설정 파일 레코드락 + 로그 (mq 없는 실제 설계)"),
 ("fp_w_memorymanager",  ["unix_listen","timerfd","eventfd","logfile"],              "P",
  "memorymanager — 주기 샘플링 + 이벤트 통지 + 수신 버스"),
 ("fp_w_notificationd",  ["unix_listen","eventfd","timerfd"],                        "P",
  "notification — 이벤트 큐 + 만료 타이머 + 수신 버스"),
 ("fp_w_connman_wifi",   ["netlink","unix_listen","epoll"],                          "P",
  "네트워크 매니저(connman/wpa 대응) — NETLINK_ROUTE 구독 + 버스"),
 ("fp_w_bluetooth_mgr",  ["netlink","thread1","eventfd","unix_conn"],                "P",
  "블루투스 매니저 — netlink + 워커 + 이벤트"),
 ("fp_w_audiod",         ["shm_posix","timerfd","thread1","unix_listen"],            "P",
  "오디오 데몬 — POSIX shm 버퍼(현대 스택 방식: SysV 아님) + 주기 믹서 + 버스"),
 ("fp_w_db8",            ["lock_flock","mmap_shared","logfile"],                     "P",
  "DB8/LevelDB — 파일락 + mmap 테이블 + 컴팩션 로그"),
 ("fp_w_tempdb",         ["memfd","unix_listen","epoll"],                            "P",
  "tempdb — 인메모리 저장(memfd) + 수신 버스"),
 ("fp_w_epg_cache",      ["dirty_churn","mmap_shared","inotify"],                    "P",
  "EPG 캐시 — 지속 dirty 갱신 + 공유 매핑 + 파일 감시"),
 ("fp_w_umedia",         ["thread4","timerfd","memfd","unix_conn"],                  "P",
  "uMediaServer 워커 — 디코더 스레드 + 프레임클록 + 버퍼 + 버스"),
 ("fp_w_media_hls",      ["tcp_established","thread4","timerfd","memfd"],            "R",
  "HLS 스트리밍 — 원격 연결 수립 포함: tcp l05 창 재현(클러스터 ①)"),
 ("fp_w_devmode_console",["tty","pipe","unix_conn"],                                 "R",
  "개발자 모드 진단 도구 — 셸 상속 ctty (클러스터 ③의 B급 맥락 재현)"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads-dir", required=True)
    a = ap.parse_args()
    if not os.path.isfile(os.path.join(a.workloads_dir, "common", "probe_server.h")):
        sys.exit("ERROR: workloads-dir가 testbed/workloads가 아님")
    total = 0; byk = {"P":0,"R":0,"U":0}
    for name, feats, kind, desc in W:
        phases = g.gen_one(name, feats, f"[{kind}] webOS-faithful: {desc}", a.workloads_dir,
                           granularity="line")
        total += len(phases) - 1; byk[kind] += 1
        print(f"  [{kind}] {name}: {len(phases)} phases")
    print(f"generated {len(W)} workloads — 통과예상 {byk['P']} · 실패재현 {byk['R']} · 미지수 {byk['U']} (셀 {total}개 예상)")

if __name__ == "__main__":
    main()
