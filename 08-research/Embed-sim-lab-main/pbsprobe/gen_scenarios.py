#!/usr/bin/env python3
"""gen_scenarios.py — pbs dump/restore 상황 매트릭스 생성기 (결정적)

pbs(EPG 배너 서비스)에서 실제로 일어날 법한 dump/restore 상황 ~100개를
scenarios.csv로 생성한다. 각 행 = pbs_sweep.sh의 셀 1개 = 판정 1개.

failprobe/scenarios.csv와 같은 pre-registration 원칙: hypothesis 열은 측정 전
사전 가설이고, 실측과의 일치/불일치 자체가 결과다.

가족(family) 구성 — 발표(07/22)의 3대 발견 + 생애주기 + 운영 상황:
  A lifecycle  기동 생애주기 라인 스윕: 어느 라인까지는 얼 수 있는가
  B hub        Luna hub 축: 경계 밖 연결의 실패 양상과 disconnect&re-register 처방
  C tcp        TCP 축: iptables lock 생존 조건, 정지 시간, 반증
  D memory     메모리 축: fail-fast vs 침묵형 OOM, 이미지 크기, dirty 갱신 중 dump
  E ops        운영 상황: 타이머/감시/mmap/반복 사이클/처방 총합

열:
  scenario   셀 이름 (고유)
  family     A|B|C|D|E
  phase      dump_at (pbs_mock manifest phases 중)
  criu_opts  strict|ext_unix|tcp_est|permissive  (pbs_sweep가 CRIU 옵션으로 번역)
  pre_dump   none|bye          (bye = SIGUSR1 → hub_disconnected 대기 후 dump)
  post_dump  none|droplock|sleep15|sleep45|droplock_sleep2 (dump~restore 사이 조작)
  restore_mem_mib  0=제약 없음, N=memory.max N MiB cgroup 안에서 restore
  hub_mode   normal|noaccept|none|self|down_after (down_after = restore 전 hub kill)
  verify     쉼표목록: pong,stat,hub,tcp,live5,resume
  params     pbs_mock named flags (공백 구분, port/resume_file 제외 — sweep가 주입)
  hypothesis 사전 가설 (자유 서술 + 기대 판정 ok|dump_fail|restore_fail|silent_dead)
"""
import csv
import io
import os
import sys

ROWS = []

# 기본 파라미터: "화면 하단 EPG 배너" 규모 — DB 8MiB, 인덱스 12MiB, 허브 4연결
BASE = "--db_mib 8 --index_mib 12 --parse_iters 120000 --hub_conns 4 --hub_pending 2 " \
       "--refresh_ms 500 --refresh_kib 256 --timer 1 --timer_s 60 --watch 1"
NOHUB = "--db_mib 8 --index_mib 12 --parse_iters 120000 --hub_conns 0 --refresh_ms 500 " \
        "--refresh_kib 256 --timer 1 --timer_s 60 --watch 1"


def row(scenario, family, phase, criu, pre, post, mem, hub, verify, params, hyp):
    ROWS.append(dict(scenario=scenario, family=family, phase=phase, criu_opts=criu,
                     pre_dump=pre, post_dump=post, restore_mem_mib=mem, hub_mode=hub,
                     verify=verify, params=params, hypothesis=hyp))


# ═══ A. lifecycle — 기동 생애주기 라인 스윕 (strict) ═══════════════════════
# "socket()까지는 OK, connect() 라인부터 NG"의 pbs판. hub_conn1이 경계다.
LIFE = [
    ("init",           "ok — 자원 없음"),
    ("db_open",        "ok — regular file fd"),
    ("db_read",        "ok — 파일 읽기 완료 상태"),
    ("db_parse",       "ok — 순수 연산 직후"),
    ("epg_index",      "ok — anon 메모리만 (이미지 커짐)"),
    ("epg_text",       "ok — 배너 렌더 완료"),
    ("epg_reserve",    "ok — untouched 예약은 이미지에 안 실림"),
    ("hub_conn1",      "dump_fail — 외부 UNIX established (sk-unix 'half of stream')"),
    ("hub_conn2",      "dump_fail — 동일, 연결 2개"),
    ("hub_conn4",      "dump_fail — 동일, 연결 4개 (기본 구성)"),
    ("hub_subscribed", "dump_fail — 미처리 SUB까지 얹힘"),
    ("timer_armed",    "dump_fail — hub가 이미 있어 hub에서 거부 (timerfd 자체는 ok)"),
    ("db_watch",       "dump_fail — 동일 (inotify 자체는 ok)"),
    ("ready",          "dump_fail — hub 물고 ready"),
    ("steady",         "dump_fail — 상시 상태도 동일"),
]
for ph, hyp in LIFE:
    v = "resume" if ph not in ("ready", "steady") else "pong,stat"
    row(f"A_life_{ph}", "A", ph, "strict", "none", "none", 0, "normal", v, BASE, hyp)
# hub 없는 대조 생애주기: 순수 EPG 파서는 전 구간 통과해야 함 (전 라인)
for ph in ("init", "db_open", "db_read", "db_parse", "epg_index", "epg_text",
           "epg_reserve", "timer_armed", "db_watch", "ready", "steady"):
    v = "resume" if ph not in ("ready", "steady") else "pong,stat"
    row(f"A_nohub_{ph}", "A", ph, "strict", "none", "none", 0, "none", v, NOHUB,
        "ok — hub 없으면 전 구간 통과 (침묵 실패 없음)")

# ═══ B. hub — Luna hub 축 ═════════════════════════════════════════════════
# B1 연결 수 스케일: 1개든 8개든 하나라도 있으면 죽는가
for n in (1, 2, 8):
    p = BASE.replace("--hub_conns 4", f"--hub_conns {n}")
    row(f"B_conns{n}_steady", "B", "steady", "strict", "none", "none", 0, "normal",
        "pong,stat", p, "dump_fail — 연결 1개부터 즉사, 개수 무관")
# B2 미수신 queue 크기: queue가 클수록 다른 실패인가 (아니어야 정상)
for q in (0, 8, 32):
    p = BASE.replace("--hub_pending 2", f"--hub_pending {q}")
    row(f"B_pending{q}_steady", "B", "steady", "strict", "none", "none", 0, "normal",
        "pong,stat", p, "dump_fail — queue 크기 무관, established 자체가 원인")
# B3 Batch A 대조군: 연결 양쪽이 프로세스 안 (socketpair) → 전부 통과 + queue 보존
for ph in ("ready", "steady"):
    p = BASE + " --selfhub 1"
    row(f"B_selfhub_{ph}", "B", ph, "strict", "none", "none", 0, "self",
        "pong,stat", p, "ok — 경계 안 연결은 queue까지 완전 복원 (발표 6장 Batch A)")
# B4 half-open: connect만 되고 accept 전 (백로그) — dump는 통과, restore에서 실패
row("B_halfopen_hubconn1", "B", "hub_conn1", "strict", "none", "none", 0, "noaccept",
    "resume", BASE.replace("--hub_conns 4", "--hub_conns 1"),
    "restore_fail — dump rc=0 이미지 생성, restore 'Peer unresolved' (발표 6장)")
row("B_halfopen_steady", "B", "steady", "strict", "none", "none", 0, "noaccept",
    "pong,stat", BASE, "restore_fail — 대기열 연결 4개, dump 통과 후 restore 실패")
# B5 --ext-unix-sk 옵션 구제 시도: dump는 넘어가나, restore가 성립하는가
for ph in ("steady",):
    row(f"B_extunix_{ph}", "B", ph, "ext_unix", "none", "none", 0, "normal",
        "pong,stat", BASE,
        "부분 — dump는 통과 가능하나 restore에서 상대 소켓 부재로 실패 예상 (옵션 처방의 한계)")
row("B_extunix_conn1", "B", "hub_conn1", "ext_unix", "none", "none", 0, "normal",
    "resume", BASE.replace("--hub_conns 4", "--hub_conns 1"),
    "부분 — 연결 1개도 동일: 옵션은 dump 단계만 구제")
# B6 처방: disconnect & re-register (발표 7장 대안의 실측)
for n in (1, 4, 8):
    p = BASE.replace("--hub_conns 4", f"--hub_conns {n}")
    row(f"B_bye_conns{n}", "B", "steady", "strict", "bye", "none", 0, "normal",
        "pong,stat,hub,live5", p,
        "ok — 해제 후 dump 전 구간 통과, restore 후 재등록 성공. 재등록 ms가 처방 비용")
# B7 처방 + 미수신 queue: 끊는 순간 queue 내용은 유실 — 유실을 명시 관측
row("B_bye_pending32", "B", "steady", "strict", "bye", "none", 0, "normal",
    "pong,stat,hub", BASE.replace("--hub_pending 2", "--hub_pending 32"),
    "ok(연결) — 단 미수신 notify 32건은 유실. 처방의 대가를 기록")
# B8 처방 후 hub가 내려간 세계: restore 시점에 hub 부재 → 앱은 살되 재등록 재시도
row("B_bye_hubdown", "B", "steady", "strict", "bye", "none", 0, "down_after",
    "pong,stat,live5", BASE,
    "ok(앱 생존) — hub 재등록은 실패 상태로 재시도 지속 (hub_dead), PONG은 정상")
# B9 처방 반복성: 같은 앱을 2회 연속 freeze/restore (사이클 내구성)
row("B_bye_cycle2", "B", "steady", "strict", "bye", "cycle2", 0, "normal",
    "pong,stat,hub", BASE,
    "ok — 2회 연속 사이클에도 crc 유지 + 재등록 누계 증가")
# B10 pre-ready에서 처방: 기동 도중(hub만 붙은 직후) 끊고 얼리기
row("B_bye_at_subscribed", "B", "hub_subscribed", "strict", "bye", "none", 0, "normal",
    "resume", BASE,
    "ok — 기동 중간 처방도 성립, 복원 후 잔여 기동 이어가 ready 도달")
# B11 처방 + 정지 시간: 재등록 방식이면 정지 15/45s가 무해한가 (TCP와 달리 상대 상태 없음)
for s in (15, 45):
    row(f"B_bye_freeze{s}", "B", "steady", "strict", "bye", f"sleep{s}", 0, "normal",
        "pong,stat,hub", BASE,
        f"ok — {s}s 정지 후에도 재등록 성립. hub 쪽에 지킬 상태가 없어 정지 시간 무관")
# B12 permissive 총합(--ext-unix-sk 포함 전 옵션): 옵션만으로 hub가 구제되는가
row("B_permissive_steady", "B", "steady", "permissive", "none", "none", 0, "normal",
    "pong,stat", BASE,
    "부분 — 전 옵션으로도 restore 성립 불가 예상: 옵션 처방의 한계선 확정")
# B13 Batch A + 대형 queue: 경계 안이면 미수신 32건까지 그대로 복원되는가
row("B_selfhub_pending32", "B", "steady", "strict", "none", "none", 0, "self",
    "pong,stat", BASE.replace("--hub_pending 2", "--hub_pending 32") + " --selfhub 1",
    "ok — 경계 안 queue는 크기 무관 완전 복원 (crc + STAT으로 확인)")
# B14 dump 실패의 비파괴성: strict dump가 거부돼도 원본 앱은 무사한가
row("B_dumpfail_harmless", "B", "steady", "strict", "none", "verify_orig", 0, "normal",
    "pong,stat", BASE,
    "ok(원본) — dump rc=1이어도 원본 프로세스·hub 연결은 그대로: 실패는 비파괴적")

# ═══ C. tcp — TCP feed 축 ════════════════════════════════════════════════
RR = NOHUB + " --tcp reqresp"
ST = NOHUB + " --tcp stream"
# C1 established TCP는 strict에서 거부되는가 (옵션 없이는 dump 불가가 공식 동작)
row("C_rr_strict", "C", "steady", "strict", "none", "none", 0, "normal",
    "pong", RR, "dump_fail — established TCP는 --tcp-established 없이는 거부")
row("C_st_strict", "C", "steady", "strict", "none", "none", 0, "normal",
    "pong", ST, "dump_fail — 동일")
# C2 --tcp-established: 왕복까지 생존 (발표 8장 A/B)
row("C_rr_tcpest", "C", "steady", "tcp_est", "none", "none", 0, "normal",
    "pong,stat,tcp", RR, "ok — 요청-응답형: 복원 후 다음 요청 정상 (8장 A)")
row("C_st_tcpest", "C", "steady", "tcp_est", "none", "none", 0, "normal",
    "pong,stat,tcp", ST, "ok — streaming: 복원 후 수신 재개, loss 0B (8장 B)")
# C3 정지 시간 축: freeze 15s/45s에도 커널 수준 생존 (retransmission 복구)
for s in (15, 45):
    row(f"C_st_freeze{s}", "C", "steady", "tcp_est", "none", f"sleep{s}", 0, "normal",
        "pong,tcp", ST, f"ok — {s}s 정지에도 lock이 RST를 막아 생존 (재전송 복구)")
row("C_rr_freeze45", "C", "steady", "tcp_est", "none", "sleep45", 0, "normal",
    "pong,tcp", RR, "ok — 조용한 연결은 정지 시간에 더 둔감")
# C4 반증: lock 제거 → rc=0인데 연결만 침묵사 (발표 8장 C)
row("C_st_droplock", "C", "steady", "tcp_est", "none", "droplock_sleep2", 0, "normal",
    "pong,tcp", ST,
    "silent_dead(연결) — restore rc=0 + PONG ok, 그러나 TCPQ 실패. rc로 못 잡는 사례")
row("C_rr_droplock", "C", "steady", "tcp_est", "none", "droplock_sleep2", 0, "normal",
    "pong,tcp", RR,
    "부분 — 조용한 reqresp는 상대 재전송이 없어 생존 가능성 있음 (경계 사례, 실측 필요)")
# C5 hub+tcp 복합: 실제 pbs 완전체 — 무엇이 먼저 막는가
row("C_full_strict", "C", "steady", "strict", "none", "none", 0, "normal",
    "pong", BASE + " --tcp reqresp",
    "dump_fail — hub(sk-unix)가 먼저 거부 (에러 순서 기록)")
row("C_full_tcpest_only", "C", "steady", "tcp_est", "none", "none", 0, "normal",
    "pong", BASE + " --tcp reqresp",
    "dump_fail — TCP만 허용해도 hub가 남아 거부")
# C6 대조: tcp 없음 (feed 미접속 상태로 steady)
row("C_none_ctrl", "C", "steady", "strict", "none", "none", 0, "normal",
    "pong,stat", NOHUB, "ok — TCP 없으면 통과 (대조군)")
# C7 warm 전(ready) 시점의 streaming dump: 수신 개시 직후 얼리기
row("C_st_at_ready", "C", "ready", "tcp_est", "none", "none", 0, "normal",
    "pong,tcp", ST, "ok — 수신 초입에도 lock 메커니즘 동일 작동")
# C8 dump 실패의 비파괴성 (TCP판): strict 거부 후 원본의 연결이 살아있는가
row("C_dumpfail_harmless", "C", "steady", "strict", "none", "verify_orig", 0, "normal",
    "pong,tcp", ST,
    "ok(원본) — dump rc=1이어도 원본의 streaming 수신은 계속: 실패는 비파괴적")

# ═══ D. memory — 메모리 축 (발표 10~11장) ═════════════════════════════════
HV = "--db_mib 8 --index_mib 300 --parse_iters 60000 --hub_conns 0 --refresh_ms 500 " \
     "--refresh_kib 256 --timer 0 --watch 0"                     # heavy: touched 300MiB
LT = "--db_mib 8 --index_mib 8 --parse_iters 60000 --hub_conns 0 --reserve_mib 300 " \
     "--refresh_ms 200 --refresh_kib 4096 --timer 0 --watch 0"   # light: 예약 300MiB, 틱마다 4MiB 점진 touch
# D1 heavy 이미지: 여유 있으면 통과, 빠듯하면 restore 단계에서 fail-fast
row("D_heavy_roomy", "D", "steady", "strict", "none", "none", 700, "none",
    "pong,stat,live5", HV, "ok — 700MiB 한도면 309MiB 이미지 복원 성공")
row("D_heavy_tight", "D", "steady", "strict", "none", "none", 300, "none",
    "pong", HV, "restore_fail — page 쓰기 중 한도 초과, rc=1 fail-fast (11장 상단)")
row("D_heavy_exact", "D", "steady", "strict", "none", "none", 330, "none",
    "pong,live5", HV, "경계 — 이미지+오버헤드가 한도 언저리: fail-fast 또는 직후 OOM")
# D2 light 이미지 + 지연 touch: restore rc=0 후 뒤늦게 OOM — 침묵형 실패 재현
row("D_light_silent", "D", "steady", "strict", "none", "none", 100, "none",
    "pong,live5", LT,
    "silent_dead — restore rc=0·에러 0줄, refresh가 reserve를 채우다 수 초 뒤 OOM kill (11장 하단)")
row("D_light_roomy", "D", "steady", "strict", "none", "none", 700, "none",
    "pong,stat,live5", LT, "ok — 여유 있으면 지연 touch도 무사 (대조군)")
# D3 dump 시점별 이미지 크기: 예약 전/후·touch 전/후 (10장 dump point 1/2의 pbs판)
row("D_img_at_dbread", "D", "db_read", "strict", "none", "none", 0, "none",
    "resume", HV, "ok — 인덱스 구축 전: 이미지 소형 (img_bytes 기록·비교)")
row("D_img_at_index", "D", "epg_index", "strict", "none", "none", 0, "none",
    "resume", HV, "ok — touched 300MiB 직후: 이미지 대형 (~300MiB)")
row("D_img_reserve", "D", "epg_reserve", "strict", "none", "none", 0, "none",
    "resume", LT, "ok — untouched 예약 300MiB는 이미지에 안 실림 (소형 유지)")
# D4 dirty 갱신 도중 dump: refresh가 도는 상시 상태에서 반복 3회 — 이미지 재현성
for i in (1, 2, 3):
    row(f"D_dirty_rep{i}", "D", "steady", "strict", "none", "none", 0, "none",
        "pong,stat", NOHUB.replace("--refresh_ms 500", "--refresh_ms 100"),
        "ok — 매회 통과하되 crc는 dump 시점마다 다름 (dirty 진행의 스냅샷)")
# D5 같은 이미지에서 2회 restore: 이미지 재사용 가능성
row("D_restore_twice", "D", "steady", "strict", "none", "restore2", 0, "none",
    "pong,stat", NOHUB, "ok — 동일 이미지 재복원 성공 (단, 첫 복원 프로세스 종료 후)")
# D6 TV 총량 제약: 실측 기기 스펙(1708MiB)에서의 복원
row("D_tv_budget", "D", "steady", "strict", "none", "none", 1708, "none",
    "pong,stat,live5", HV, "ok — TV 총량이면 여유. anchor region 조건 기록")
# D7 침묵사 원인의 반증 대조: 같은 light 이미지, refresh만 끄면 안 죽는다
row("D_light_norefresh", "D", "steady", "strict", "none", "none", 100, "none",
    "pong,stat,live5", LT.replace("--refresh_ms 200", "--refresh_ms 0"),
    "ok — 지연 touch가 없으면 100MiB 한도에서도 생존: 침묵사의 원인이 touch임을 반증으로 확정")
# D8 중간 한도: heavy 이미지 + 500MiB (여유~빠듯 사이 보간점)
row("D_heavy_mid500", "D", "steady", "strict", "none", "none", 500, "none",
    "pong,stat,live5", HV, "ok — 이미지 309MiB + 오버헤드 < 500MiB 예상 (경계 보간)")
# D9 ready 시점 이미지: warm 전 dump 크기 (dump 시점 축의 실무 기본값 후보)
row("D_img_at_ready", "D", "ready", "strict", "none", "none", 0, "none",
    "pong,stat", HV, "ok — ready 시점 이미지 크기 기록 (steady와 대비)")
# D10 같은 이미지 '동시' 2회 복원: PID 충돌로 두 번째는 실패해야 정상
row("D_restore_concurrent", "D", "steady", "strict", "none", "restore_dup", 0, "none",
    "pong", NOHUB, "restore_fail(2번째) — 동일 PID 요구로 동시 복원 불가 (운영 제약 확정)")

# ═══ E. ops — 운영 상황·자원 단독·처방 총합 ═══════════════════════════════
row("E_timer_only", "E", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB.replace("--timer 1", "--timer 1").replace("--watch 1", "--watch 0"),
    "ok — armed timerfd는 dump/restore 지원 (실측 확인)")
row("E_watch_only", "E", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB.replace("--timer 1", "--timer 0"),
    "ok — inotify watch 복원 지원 (경로 존재 전제)")
row("E_watch_gone", "E", "steady", "strict", "none", "rmdb", 0, "none",
    "pong", NOHUB.replace("--timer 1", "--timer 0"),
    "restore_fail 또는 경고 — 감시 대상 DB 파일이 사라진 채 restore (경로 의존성)")
row("E_mmap_db", "E", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --mmap_db 1",
    "ok — 파일 mmap은 같은 경로 존재 시 복원 (발표 fp_c_epg 계열)")
row("E_mmap_gone", "E", "steady", "strict", "none", "rmdb", 0, "none",
    "pong", NOHUB + " --mmap_db 1",
    "restore_fail — 매핑 파일 부재로 복원 불가 (ghost 아님: 링크가 남아있던 파일)")
row("E_tick_1s", "E", "steady", "strict", "none", "sleep15", 0, "none",
    "pong,stat", NOHUB.replace("--timer_s 60", "--timer_s 1"),
    "ok — 1s 타이머로 15s 정지: 복원 직후 틱 폭주 없이 재개되는지 clock_tick 로그로 관측")
# 처방 총합: 완전체 pbs를 처방 세트(bye + tcp_est)로 살리기 — 헤드라인 양성 케이스
row("E_full_rx", "E", "steady", "tcp_est", "bye", "none", 0, "normal",
    "pong,stat,hub,tcp,live5", BASE + " --tcp reqresp",
    "ok — 처방 세트(연결해제+재등록, tcp-established)로 완전체 pbs가 산다. 헤드라인")
row("E_full_rx_stream", "E", "steady", "tcp_est", "bye", "none", 0, "normal",
    "pong,stat,hub,tcp,live5", BASE + " --tcp stream",
    "ok — streaming 포함 완전체도 처방 세트로 생존")
row("E_full_rx_mem", "E", "steady", "tcp_est", "bye", "none", 700, "normal",
    "pong,stat,hub,tcp,live5", BASE + " --tcp reqresp",
    "ok — 처방 세트 + 메모리 제약(700MiB) 동시 성립")
for i in (1, 2, 3):
    row(f"E_full_cycle{i}", "E", "steady", "tcp_est", "bye", "none", 0, "normal",
        "pong,stat,hub", BASE + " --tcp reqresp",
        "ok — 처방 세트 반복 내구성 (run별 독립 사이클)")
row("E_pre_ready_mem", "E", "epg_index", "strict", "none", "none", 700, "none",
    "resume", NOHUB, "ok — 기동 중간 dump 후 제약 하 복원, 잔여 기동 완주")
row("E_gap0_steady", "E", "steady", "strict", "bye", "none", 0, "normal",
    "pong,stat,hub", BASE + " --phase_gap_ms 0",
    "ok — gap 0(시간 측정 조건)에서도 처방 성립 (측정 캠페인 이행 가능성 확인)")
row("E_full_rx_at_ready", "E", "ready", "tcp_est", "bye", "none", 0, "normal",
    "pong,hub", BASE + " --tcp reqresp",
    "ok — warm 전(ready) 시점 처방도 성립: dump 시점 선택의 자유도 확인")
row("E_watch_alive", "E", "steady", "strict", "none", "touchdb", 0, "none",
    "pong,stat", NOHUB.replace("--timer 1", "--timer 0"),
    "ok — restore 후 DB 파일을 갱신하면 inotify가 실제 동작 (감시 기능의 회생 확인)")

# ═══ F. surface — 실기 pbs가 가질 법한 추가 자원의 전수 검사 ══════════════
# 근거: LS2 구조(허브 데몬+등록/구독), PmLog(DGRAM), sqlite(DB 잠금/WAL),
#       GLib mainloop(eventfd/self-pipe), 렌더 연결, 워커 스레드, 전용 cwd.
#       각 자원을 (1) 단독으로 격리해 판정하고 (2) 전부 켠 RICH 구성으로
#       line-by-line 재스윕해 "실패 경계선이 어디로 이동하는가"를 본다.
RICH = BASE + " --tcp reqresp --threads 4 --selfpipe 1 --eventfd 1 --db_lock flock " \
              "--shm_mib 4 --log_dgram 1 --render 1 --workdir 1"

# F1 자원별 격리 (NOHUB 기반 — 그 자원만의 판정)
row("F_thread4_steady", "F", "steady", "strict", "none", "none", 0, "none",
    "pong,stat,live5", NOHUB + " --threads 4",
    "ok — 멀티스레드 dump/restore 지원, thr 카운터 재개로 스레드 회생 확인")
row("F_thread_line", "F", "thread2", "strict", "none", "none", 0, "none",
    "resume", NOHUB + " --threads 4",
    "ok — 스레드 2개 시점 dump 후 잔여 스레드 생성 이어감")
row("F_selfpipe_steady", "F", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --selfpipe 1", "ok — pipe 복원 지원")
row("F_eventfd_steady", "F", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --eventfd 1",
    "ok — eventfd 복원 지원, STAT ev=1로 왕복 확인")
row("F_flock_strict", "F", "steady", "strict", "none", "none", 0, "none",
    "pong", NOHUB + " --db_lock flock",
    "dump_fail — 파일 잠금은 --file-locks 없이는 dump 거부")
row("F_flock_filelocks", "F", "steady", "filelocks", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --db_lock flock",
    "ok — --file-locks로 잠금 포함 복원")
row("F_posix_strict", "F", "steady", "strict", "none", "none", 0, "none",
    "pong", NOHUB + " --db_lock posix",
    "dump_fail — POSIX 락도 동일 정책")
row("F_posix_filelocks", "F", "steady", "filelocks", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --db_lock posix", "ok — 동일 구제")
row("F_shm_steady", "F", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --shm_mib 4",
    "ok — /dev/shm 파일 존재 시 MAP_SHARED 복원, STAT shm=1")
row("F_shm_gone", "F", "steady", "strict", "none", "rmshm", 0, "none",
    "pong", NOHUB + " --shm_mib 4",
    "restore_fail — 매핑 원본 shm 파일 소실 시 복원 불가 (경로 의존성)")
row("F_log_strict", "F", "steady", "strict", "none", "none", 0, "normal",
    "pong,stat", NOHUB + " --log_dgram 1",
    "경계 — connected DGRAM(외부 수신자): STREAM과 정책이 다른지 실측 (PmLog 전략 결정 근거)")
row("F_log_extunix", "F", "steady", "ext_unix", "none", "none", 0, "normal",
    "pong,stat", NOHUB + " --log_dgram 1",
    "경계 — --ext-unix-sk가 DGRAM에 듣는지: 수신자 주소가 남아 있으므로 재연결 성립 가능")
row("F_render_strict", "F", "steady", "strict", "none", "none", 0, "normal",
    "pong", NOHUB + " --render 1",
    "dump_fail — hub와 동일 계급(외부 established STREAM): 동일 에러 라인인지 확인")
row("F_render_bye", "F", "steady", "strict", "bye", "none", 0, "normal",
    "pong,stat,hub,live5", NOHUB + " --render 1",
    "ok — 처방이 render 채널까지 끊고 재접속함을 검증 (hub_reregistered render=1)")
row("F_wd_gone", "F", "steady", "strict", "none", "rmwd", 0, "none",
    "pong", NOHUB + " --workdir 1",
    "restore_fail — cwd 디렉터리 소실 시 복원 불가 (배포 시 cwd 보존 요구사항 도출)")
row("F_wd_ok", "F", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --workdir 1", "ok — cwd 존재하면 정상 (대조군)")

# F2 RICH 완전체 line-by-line (strict): 잠금이 hub보다 앞이므로 실패 경계선이
#    hub_conn1이 아니라 db_lock으로 당겨진다는 가설을 라인 단위로 검증
for ph in ("log_open", "db_lock", "db_parse", "epg_reserve", "thread4", "selfpipe",
           "eventfd_open", "shm_map", "workdir", "hub_conn1", "hub_subscribed",
           "render_conn", "tcp_conn", "ready", "steady"):
    if ph in ("ready", "steady"):
        v = "pong"
    else:
        v = "resume"
    if ph == "log_open":
        hyp = "경계 — connected DGRAM만 있는 시점: DGRAM 정책 단독 관측"
    elif ph in ("db_lock", "db_parse", "epg_reserve", "thread4", "selfpipe",
                "eventfd_open", "shm_map", "workdir"):
        hyp = "dump_fail — flock 보유 시점부터 strict 거부: 실패 경계선이 hub 앞으로 이동"
    else:
        hyp = "dump_fail — 잠금+외부 연결 중첩: 첫 에러가 무엇인지 순서 기록"
    row(f"F_all_life_{ph}", "F", ph, "strict", "none", "none", 0, "normal", v, RICH, hyp)

# F3 RICH 완전체 permissive line-by-line (요점 phase): 옵션 총합의 도달선
for ph in ("db_lock", "shm_map", "hub_conn1", "steady"):
    v = "resume" if ph not in ("ready", "steady") else "pong"
    row(f"F_all_perm_{ph}", "F", ph, "permissive", "none", "none", 0, "normal", v, RICH,
        "부분 — --file-locks가 잠금은 구제, hub established는 여전히 미구제 예상")

# F4 처방 총합 (최종 헤드라인): 모든 자원 + bye + permissive
row("F_all_rx", "F", "steady", "permissive", "bye", "none", 0, "normal",
    "pong,stat,hub,tcp,live5", RICH,
    "ok — 전 자원 구성이 처방 세트(연결해제·재등록 + file-locks + tcp-established)로 생존. 최종 헤드라인")
row("F_all_rx_cycle2", "F", "steady", "permissive", "bye", "cycle2", 0, "normal",
    "pong,stat,hub", RICH, "ok — 전 자원 + 처방 반복 사이클 내구성")
row("F_all_rx_mem", "F", "steady", "permissive", "bye", "none", 700, "normal",
    "pong,stat,hub,tcp,live5", RICH, "ok — 전 자원 + 처방 + 메모리 제약 동시 성립")
row("F_all_dumpfail_harmless", "F", "steady", "strict", "none", "verify_orig", 0, "normal",
    "pong,stat,tcp", RICH,
    "ok(원본) — 전 자원 구성 strict dump 실패의 비파괴성: 원본 서비스·잠금·연결 전부 무사")

# ═══ G. world — 상시 배경 세계(webOS 근사) 안에서의 실험 ═══════════════════
# 전제: pbsprobe/world_up.sh 로 세계 기동 후 WORLD=1 pbs_sweep.sh
# (world hub + 상주 서비스 + 버스 소음 + [옵션] TV cgroup/stress/memd).
# WORLD 모드가 아니면 이 가족은 자동 skip. A~F도 WORLD=1로 돌리면 같은 세계
# 안에서 재실행된다 — G는 세계에서만 성립하는 상호작용 셀만 담는다.
# 세계 공변량(up_s/regs/mem/memd_kills)이 CSV world 열에 셀마다 기록된다.
# G 생애주기: 소음 낀 세계에서도 실패 경계선이 단독 실험과 같은가 (line-by-line)
for ph in ("init", "db_read", "epg_index", "hub_conn1", "hub_subscribed",
           "tcp_conn", "ready", "steady"):
    v = "resume" if ph not in ("ready", "steady") else "pong,stat"
    hyp = ("ok — 소음 무관 통과" if ph in ("init", "db_read", "epg_index")
           else "dump_fail — 세계에서도 동일 경계선 (hub established)")
    row(f"G_life_{ph}", "G", ph, "strict", "none", "none", 0, "normal", v, BASE + " --tcp reqresp", hyp)
row("G_rx", "G", "steady", "tcp_est", "bye", "none", 0, "normal",
    "pong,stat,hub,tcp,live5", BASE + " --tcp reqresp",
    "ok — 상주 서비스·소음 낀 세계에서도 처방 성립. rereg_ms를 단독값과 비교(공유 hub 경합 비용)")
row("G_rx_cycle2", "G", "steady", "tcp_est", "bye", "cycle2", 0, "normal",
    "pong,stat,hub", BASE + " --tcp reqresp", "ok — 세계 안 반복 사이클 내구성")
row("G_flood_rereg", "G", "steady", "tcp_est", "bye", "none", 0, "normal",
    "pong,stat,hub,live5", BASE + " --tcp reqresp --flood_name 1",
    "ok(생존) — 재등록 순간 밀린 notify 폭주(버퍼 한도까지, 초과분 drop)에도 서비스 유지 — 유입/유실량이 처방의 숨은 비용")
row("G_freeze45_flood", "G", "steady", "tcp_est", "bye", "sleep45", 0, "normal",
    "pong,stat,hub,live5", BASE + " --tcp reqresp --flood_name 1",
    "ok(생존) — 45s 부재 후 복귀+폭주: '오래 얼었다 돌아온 앱'의 실전 시나리오")
row("G_soak_dirty", "G", "steady", "tcp_est", "bye", "sleep15", 0, "normal",
    "pong,stat,hub", BASE.replace("--refresh_ms 500", "--refresh_ms 100") + " --tcp reqresp",
    "ok — 세계 부하 속 dirty churn 앱의 노화-소형판 (world up_s 공변량과 함께 해석)")
row("G_mem_heavy", "G", "steady", "strict", "none", "none", 0, "none",
    "pong,stat,live5",
    "--db_mib 8 --index_mib 200 --parse_iters 60000 --hub_conns 0 --refresh_ms 500 --refresh_kib 256 --timer 0 --watch 0",
    "경계 — 세계 물리(WORLD_CONSTRAINED) 안 200MiB 복원: memd가 개입하는가(memd_kills 공변량). 물리 없으면 ok")
row("G_dumpfail_world", "G", "steady", "strict", "none", "verify_orig", 0, "normal",
    "pong,stat", BASE, "ok(원본) — 세계에서도 dump 실패는 비파괴적 (상주 서비스 무영향은 공변량으로)")

# ═══ H. issues — CRIU 실사용 이슈(GitHub)에서 도출한 함정 셀 ═══════════════
# 근거: gh#505(half-closed TCP는 TCP_REPAIR 불가, ARMv8 실사례), PR#2030(SCM_RIGHTS
# 미수신 + 송신자 사망 → 'Can't find sender'), gh#772(--ext-unix-sk: dump는 되나
# restore 실패), gh#1696(glibc≥2.35 rseq — CRIU≥3.17 필요, 라즈베리파이 직결),
# timerfd it_value=0 복원 버그(PR#2030 병기), criu.org(복원은 동일 경로 요구, GPU 불가).
row("H_epoll_steady", "H", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --epoll 1 --eventfd 1 --selfpipe 1",
    "ok — epoll 인스턴스+등록집합 복원 지원 (GLib mainloop 실형태)")
row("H_epoll_line", "H", "epoll_open", "strict", "none", "none", 0, "none",
    "resume", NOHUB + " --epoll 1 --eventfd 1", "ok — epoll 직후 라인 dump")
row("H_urandom_steady", "H", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --urandom 1", "ok — /dev/urandom fd 재개방 복원")
row("H_tmpunlink_strict", "H", "steady", "strict", "none", "none", 0, "none",
    "pong", NOHUB + " --tmpunlink 1",
    "경계 — unlink된 저널(sqlite -journal 모형): ghost 처리 없이는 dump 거부 예상")
row("H_tmpunlink_perm", "H", "steady", "permissive", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --tmpunlink 1",
    "ok — --link-remap/--ghost-limit로 구제 (sqlite 임시파일 전략의 근거)")
row("H_tmpunlink_line", "H", "tmp_journal", "permissive", "none", "none", 0, "none",
    "resume", NOHUB + " --tmpunlink 1", "ok — 저널 라인 시점 dump")
row("H_scm_pending", "H", "steady", "strict", "none", "none", 0, "normal",
    "pong", NOHUB.replace("--hub_conns 0", "--hub_conns 1") + " --pass_fd",
    "dump_fail — fd 실린 미수신 메시지(SCM_RIGHTS)가 queue에: established+scm 중첩 (hub --pass_fd)")
row("H_scm_selfhub", "H", "steady", "strict", "none", "none", 0, "self",
    "pong,stat", BASE.replace("--hub_conns 4", "--hub_conns 2") + " --selfhub 1",
    "ok — 경계 안이면 scm 없는 queue 복원과 동급 (대조군)")
row("H_halfclose_tcpest", "H", "steady", "tcp_est", "none", "none", 0, "normal",
    "pong", NOHUB + " --tcp stream --tcp_halfclose 1",
    "dump_fail — half-closed TCP는 TCP_REPAIR 불가 (gh#505, ARMv8 실사례). 에러 라인 채증")
row("H_halfclose_line", "H", "tcp_halfclosed", "tcp_est", "none", "none", 0, "normal",
    "resume", NOHUB + " --tcp stream --tcp_halfclose 1",
    "dump_fail — halfclose 라인 직후에도 동일")
row("H_timer_expire_freeze", "H", "steady", "strict", "none", "sleep15", 0, "none",
    "pong,stat,live5", NOHUB.replace("--timer_s 60", "--timer_s 5"),
    "ok(경계) — 5s 타이머를 15s 얼림: 복원 후 만기 지난 타이머의 틱 거동 (timerfd 복원 버그 계보 확인)")
row("H_rseq_baseline", "H", "steady", "strict", "none", "none", 0, "none",
    "pong,stat,live5", NOHUB,
    "ok — glibc≥2.35는 rseq 자동등록: 이 평범한 셀 자체가 rseq C/R 검증 (CRIU<3.17이면 복원 후 크래시 — Pi에서 버전 확인 셀)")
row("H_hub_upgraded", "H", "steady", "strict", "bye", "hub_restart", 0, "normal",
    "pong,stat,hub,live5", BASE,
    "ok — dump~restore 사이 hub 재시작(같은 주소, 새 인스턴스): 처방이면 '허브 업그레이드' 시나리오도 생존")

# ═══ I. reality — 운영 현실·환경 변동: 3대 발견 밖의 문제 표면 ═══════════════
# 프로세스 트리(자식/좀비), 보류 시그널, 앱 자신의 listen과 이름 선점(재시작
# 경합), OTA 바이너리 교체, mmap 파일 절단(SIGBUS 침묵사), 감시 무효화(inode
# 교체), 블로킹 syscall 안에서의 dump, UDP/netlink 소켓 계급.
row("I_child_steady", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat,live5", NOHUB + " --child 1",
    "ok — 프로세스 트리(부모+헬퍼) 통째 dump/restore. STAT chld=S 유지")
row("I_child_line", "I", "helper_forked", "strict", "none", "none", 0, "none",
    "resume", NOHUB + " --child 1", "ok — 자식 생성 직후 라인 dump 후 잔여 기동")
row("I_zombie_steady", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --zombie 1",
    "ok(경계) — 미수거 좀비 포함 트리: CRIU zombie 복원 경로. STAT zomb=Z 유지가 판정")
row("I_sigpend_steady", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --sigpend 1",
    "ok — 블록+보류 시그널(USR2) 보존: 복원 후 STAT sigp=1 유지 (전달·유실 모두 실패)")
row("I_unix_listen", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --unix_listen 1",
    "ok — 자기 luna 메서드 listen(추상)의 복원 (대조군)")
row("I_name_squat", "I", "steady", "strict", "none", "squat", 0, "none",
    "pong", NOHUB + " --unix_listen 1",
    "restore_fail — 복원 사이 다른 프로세스가 추상 이름 선점(재시작 경합): EADDRINUSE 계급")
row("I_udp_steady", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --udp 1", "ok — bound+connected UDP 복원 (소켓 분류 완결)")
row("I_netlink_steady", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat", NOHUB + " --netlink 1",
    "ok(경계) — NETLINK_ROUTE bound: CRIU netlink 지원 범위 실측 (connman류 전제)")
row("I_binary_gone", "I", "steady", "strict", "none", "mvbin", 0, "none",
    "pong", NOHUB,
    "restore_fail — dump~restore 사이 실행 바이너리 소실/이동(OTA 교체): 매핑 경로 복원 불가")
row("I_binary_back", "I", "steady", "strict", "none", "mvbin_back", 0, "none",
    "pong,stat", NOHUB,
    "ok — 바이너리가 잠깐 사라졌다 같은 경로로 복귀하면 무해 (OTA 롤백 대조군)")
row("I_mmap_trunc", "I", "steady", "strict", "none", "truncdb", 0, "none",
    "pong,live5", NOHUB + " --mmap_db 1",
    "silent_dead(경계) — mmap된 DB가 절단됨: restore rc는 성공, 다음 접근에서 SIGBUS — 침묵사 3호 후보")
row("I_watch_recreate", "I", "steady", "strict", "none", "rmdb_recreate", 0, "none",
    "pong,stat,watch", NOHUB.replace("--watch 0", "--watch 1") if "--watch 0" in NOHUB else NOHUB,
    "경계 — 감시 대상이 삭제 후 재생성(새 inode): 복원은 성공하나 watch가 침묵(무효 wd) 예상 — watch_dead")
row("I_watch_alive_ctrl", "I", "steady", "strict", "none", "none", 0, "none",
    "pong,stat,watch", NOHUB.replace("--watch 0", "--watch 1") if "--watch 0" in NOHUB else NOHUB,
    "ok+watch_ok — 대조군: inode 보존 시 복원 후 감시 실동작")
row("I_flock_blocked", "I", "db_open", "filelocks", "settle", "none", 0, "none",
    "resume", NOHUB + " --db_lock flock_wait",
    "ok — 블로킹 flock() syscall 안에서 잠든 채 dump→restore: 홀더 해제 후 잠금 획득하고 기동 완주")
row("I_all_rx", "I", "steady", "permissive", "bye", "none", 0, "normal",
    "pong,stat,hub,live5", BASE + " --child 1 --sigpend 1 --unix_listen 1 --udp 1 --urandom 1",
    "ok — 현실 자원 총합 + 처방: 트리·시그널·listen·UDP까지 얹은 구성의 생존 (헤드라인 v3)")

# ═══ J. fullmap — 전 라인 완전 지도 ═══════════════════════════════════════
# "모든 줄에서 얼려본다"의 전수판. 세 축:
#  J2) EVERYTHING(모든 자원 ON) 구성의 생애주기 전 38라인 × {strict, permissive}
#      — 실패 경계선의 완전 지도: strict는 db_lock(첫 잠금)부터,
#        permissive는 잠금·저널을 구제해 hub_conn1부터 막힌다는 2중 경계 가설
#  J1) 자원별 단독 구성 × 그 자원의 라인 — 경계선 이동의 자원 귀속
#      (0개=A, 1개=J1, 전부=J2 의 3점 보간)
#  J3) 기본 구성(A와 동일)의 hub 라인 × permissive — gh#772 축(dump만 구제) 보완
EVERYTHING = BASE + " --tcp reqresp --threads 4 --selfpipe 1 --eventfd 1 --db_lock flock " \
    "--shm_mib 4 --log_dgram 1 --render 1 --workdir 1 --child 1 --zombie 1 --sigpend 1 " \
    "--urandom 1 --tmpunlink 1 --epoll 1 --udp 1 --netlink 1 --unix_listen 1 --mmap_db 1"
J2_PHASES = ("init", "sig_pending", "dev_urandom", "log_open", "db_open", "db_lock",
             "db_read", "db_parse", "epg_index", "epg_text", "epg_reserve",
             "thread1", "thread2", "thread3", "thread4", "helper_forked", "zombie_made",
             "selfpipe", "eventfd_open", "shm_map", "workdir", "tmp_journal",
             "hub_conn1", "hub_conn2", "hub_conn3", "hub_conn4", "hub_subscribed",
             "render_conn", "tcp_conn", "epoll_open", "svc_listen", "udp_open",
             "netlink_open", "timer_armed", "db_watch", "db_mmap", "ready", "steady")
PRE_LOCK = J2_PHASES[:J2_PHASES.index("db_lock")]
PRE_HUB = J2_PHASES[:J2_PHASES.index("hub_conn1")]
for opts in ("strict", "permissive"):
    for ph in J2_PHASES:
        v = "pong,stat" if ph in ("ready", "steady") else "resume"
        if opts == "strict":
            hyp = ("ok — 잠금 이전 라인: 자원 무해 구간" if ph in PRE_LOCK
                   else "dump_fail — flock 보유(db_lock)부터 strict 거부: 경계선 1")
        else:
            hyp = ("ok — 잠금·unlink 저널은 --file-locks/--link-remap이 구제" if ph in PRE_HUB
                   else "dump_fail — hub established는 옵션이 없다: 경계선 2 (처방만이 답)")
        row(f"J_all_{opts[:4]}_{ph}", "J", ph, opts, "none", "none", 0, "normal", v,
            EVERYTHING, hyp)

# J1 자원별 단독 라인 (그 자원만 켠 구성에서 그 자원의 라인 직후 dump)
J1 = [
    ("sigpend",  "sig_pending",  " --sigpend 1",               "strict",    "none",   "ok"),
    ("urandom",  "dev_urandom",  " --urandom 1",               "strict",    "none",   "ok"),
    ("log",      "log_open",     " --log_dgram 1",             "strict",    "normal", "경계 — connected DGRAM 단독 시점"),
    ("thread",   "thread2",      " --threads 4",               "strict",    "none",   "ok"),
    ("child",    "helper_forked"," --child 1",                 "strict",    "none",   "ok"),
    ("zombie",   "zombie_made",  " --zombie 1",                "strict",    "none",   "ok(경계) — 좀비 낀 트리"),
    ("selfpipe", "selfpipe",     " --selfpipe 1",              "strict",    "none",   "ok"),
    ("eventfd",  "eventfd_open", " --eventfd 1",               "strict",    "none",   "ok"),
    ("shm",      "shm_map",      " --shm_mib 4",               "strict",    "none",   "ok"),
    ("wd",       "workdir",      " --workdir 1",               "strict",    "none",   "ok"),
    ("journal",  "tmp_journal",  " --tmpunlink 1",             "permissive","none",   "ok — ghost 구제 하 재개"),
    ("render",   "render_conn",  " --render 1",                "strict",    "normal", "dump_fail — 외부 STREAM 단독으로도 거부"),
    ("epoll",    "epoll_open",   " --epoll 1 --eventfd 1",     "strict",    "none",   "ok"),
    ("listen",   "svc_listen",   " --unix_listen 1",           "strict",    "none",   "ok"),
    ("udp",      "udp_open",     " --udp 1",                   "strict",    "none",   "ok"),
    ("netlink",  "netlink_open", " --netlink 1",               "strict",    "none",   "ok(경계) — netlink 지원 범위"),
    ("lockf",    "db_lock",      " --db_lock flock",           "filelocks", "none",   "ok — --file-locks 하 잠금 라인 재개"),
    ("lockp",    "db_lock",      " --db_lock posix",           "filelocks", "none",   "ok — 동일"),
]
for name, ph, flag, opts, hm, hyp in J1:
    row(f"J_one_{name}", "J", ph, opts, "none", "none", 0, hm, "resume", NOHUB + flag,
        hyp + " — 단독 구성 라인 재개 (자원 귀속 3점 보간의 중간점)")

# J3 기본 구성 hub 라인 × permissive (gh#772: --ext-unix-sk는 dump만 구제)
for ph in ("hub_conn1", "hub_subscribed", "ready", "steady"):
    v = "pong,stat" if ph in ("ready", "steady") else "resume"
    row(f"J_base_perm_{ph}", "J", ph, "permissive", "none", "none", 0, "normal", v, BASE,
        "경계 — ext-unix-sk로 dump는 통과 가능하나 restore 'Peer unresolved' 예상 (gh#772 재현 축)")

# ═══ K. gridmap — 상황×라인 일관 격자 ═══════════════════════════════════════
# "모든 상황도 라인 축 위에서" — 각 조작을 그 전제조건이 성립하는 라인마다 적용.
# (전제 미성립 조합만 제외: 예. rmshm은 shm_map 이전 라인에선 무의미)
GRID = [
    # (이름, 조작, 라인들, opts, pre, mem, hub, params, 가설)
    ("bye",     "none",     ("hub_conn1","hub_conn2","hub_conn4","hub_subscribed","tcp_conn","ready"),
     "tcp_est", "bye", 0, "normal", BASE + " --tcp reqresp",
     "ok — 처방을 그 라인에서 걸면 그 라인까지의 앱이 얼려지고 재개+재등록"),
    ("droplock","droplock_sleep2", ("tcp_conn","ready"),
     "tcp_est", "none", 0, "normal", NOHUB + " --tcp reqresp",
     "conn_dead — lock 제거 침묵 연결사가 라인 무관하게 재현되는가"),
    ("frz45",   "sleep45",  ("db_read","epg_index","ready"),
     "strict", "none", 0, "none", NOHUB,
     "ok — 기동 중간 라인에서 45s 얼려도 잔여 기동 재개 (타이머/시계 무관 구간)"),
    ("rmdb",    "rmdb",     ("db_open","db_read","db_parse","epg_index","ready"),
     "strict", "none", 0, "none", NOHUB,
     "restore_fail — 열린 DB fd의 원본 소실: 어느 라인이든 경로 의존 동일"),
    ("rmshm",   "rmshm",    ("shm_map","ready","steady"),
     "strict", "none", 0, "none", NOHUB + " --shm_mib 4",
     "restore_fail — shm 원본 소실, 라인 무관"),
    ("rmwd",    "rmwd",     ("workdir","ready"),
     "strict", "none", 0, "none", NOHUB + " --workdir 1",
     "restore_fail — cwd 소실, 라인 무관"),
    ("trunc",   "truncdb",  ("db_mmap","ready"),
     "strict", "none", 0, "none", NOHUB + " --mmap_db 1",
     "restore_fail(경계) — mmap 대상 절단: 복원 시점 검증에 걸리는가"),
    ("mvbin",   "mvbin",    ("init","epg_index","ready"),
     "strict", "none", 0, "none", NOHUB,
     "restore_fail — 실행파일 소실은 라인 무관 (매핑 경로 복원)"),
    ("squat",   "squat",    ("svc_listen","ready"),
     "strict", "none", 0, "none", NOHUB + " --unix_listen 1",
     "restore_fail — 이름 선점, listen 성립 이후 라인 공통"),
    ("hubup",   "hub_restart", ("hub_subscribed","ready"),
     "strict", "bye", 0, "normal", BASE,
     "ok — 그 라인에서 처방+dump 후 hub가 교체돼도 재접속 성립"),
    ("mem700",  "none",     ("db_read","epg_index","epg_reserve","ready"),
     "strict", "none", 700, "none",
     "--db_mib 8 --index_mib 300 --parse_iters 60000 --hub_conns 0 --refresh_ms 500 --refresh_kib 256 --timer 0 --watch 0",
     "경계 — heavy 이미지를 라인별로 700MiB 한도에 복원: 어느 라인부터 한도를 넘나 (D_img의 실복원판)"),
    ("lockp",   "none",     ("db_lock","ready"),
     "filelocks", "none", 0, "none", NOHUB + " --db_lock posix",
     "ok — POSIX 락 라인 재개 (--file-locks)"),
]
for name, post, phases, opts, pre, mem, hm, params, hyp in GRID:
    for ph in phases:
        v = "pong,stat" if ph == "steady" else ("pong,stat" if ph == "ready" else "resume")
        if name == "bye":
            v = v + ",hub"
        if name == "droplock":
            v = "pong,tcp"
        row(f"K_{name}_{ph}", "K", ph, opts, pre, post, mem, hm, v, params, hyp)

# ═══ L. exhaustive — 완전 격자: 구성 × 라인 × 옵션 5종 전부 ═══════════════════
# "전부 다 돌려본다"의 문자 그대로 판. 전제조건 게이트(그 구성에 존재하는
# phase만)만 빼고 모든 조합. 기존 A/F/J와 겹치는 점은 재현성 검증을 겸한다.
ALL_OPTS = ("strict", "ext_unix", "tcp_est", "filelocks", "permissive")
NOHUB_PH = ("init", "db_open", "db_read", "db_parse", "epg_index", "epg_text",
            "epg_reserve", "timer_armed", "db_watch", "ready", "steady")
BASE_PH  = NOHUB_PH[:9] + ("hub_conn1", "hub_conn2", "hub_conn3", "hub_conn4",
                           "hub_subscribed") + ("ready", "steady")
BTCP_PH  = BASE_PH[:14] + ("tcp_conn",) + ("ready", "steady")
L_CONFIGS = [
    ("nohub", NOHUB, NOHUB_PH, "none"),
    ("base",  BASE, BASE_PH, "normal"),
    ("btcp",  BASE + " --tcp reqresp", BTCP_PH, "normal"),
    ("ev",    EVERYTHING, J2_PHASES, "normal"),
]
# 자원별 단독 구성: 그 자원 라인 + ready + steady
L_SINGLES = [
    ("sigpend",  "sig_pending",  " --sigpend 1",           "none"),
    ("urandom",  "dev_urandom",  " --urandom 1",           "none"),
    ("log",      "log_open",     " --log_dgram 1",         "normal"),
    ("lockf",    "db_lock",      " --db_lock flock",       "none"),
    ("lockp",    "db_lock",      " --db_lock posix",       "none"),
    ("thread",   "thread4",      " --threads 4",           "none"),
    ("child",    "helper_forked"," --child 1",             "none"),
    ("zombie",   "zombie_made",  " --zombie 1",            "none"),
    ("selfpipe", "selfpipe",     " --selfpipe 1",          "none"),
    ("eventfd",  "eventfd_open", " --eventfd 1",           "none"),
    ("shm",      "shm_map",      " --shm_mib 4",           "none"),
    ("wd",       "workdir",      " --workdir 1",           "none"),
    ("journal",  "tmp_journal",  " --tmpunlink 1",         "none"),
    ("render",   "render_conn",  " --render 1",            "normal"),
    ("epoll",    "epoll_open",   " --epoll 1 --eventfd 1", "none"),
    ("listen",   "svc_listen",   " --unix_listen 1",       "none"),
    ("udp",      "udp_open",     " --udp 1",               "none"),
    ("netlink",  "netlink_open", " --netlink 1",           "none"),
    ("mmap",     "db_mmap",      " --mmap_db 1",           "none"),
]
def l_hyp(cfg, ph, opts, phases):
    i = phases.index(ph) if ph in phases else 0
    has_lock = "db_lock" in phases and i >= phases.index("db_lock")
    has_hub = any(p.startswith("hub_conn") for p in phases) and \
              i >= phases.index("hub_conn1") if "hub_conn1" in phases else False
    has_tcp = "tcp_conn" in phases and i >= phases.index("tcp_conn")
    need = []
    if has_lock: need.append("locks")
    if has_hub: need.append("hub")
    if has_tcp: need.append("tcp")
    if not need:
        return "ok — 이 시점 자원은 어떤 옵션에서도 무해"
    give = {"strict": set(), "ext_unix": {"dgram"}, "tcp_est": {"tcp"},
            "filelocks": {"locks"}, "permissive": {"locks", "tcp", "dgram"}}[opts]
    if "hub" in need:
        return "dump_fail — hub established는 어느 옵션으로도 불가 (처방만이 답)"
    lack = [n for n in need if n not in give]
    return ("ok — 필요한 구제가 전부 옵션에 포함" if not lack
            else f"dump_fail — {'/'.join(lack)} 구제 옵션 부재")
for cname, cparams, cphases, chub in L_CONFIGS:
    for opts in ALL_OPTS:
        for ph in cphases:
            v = "pong,stat" if ph in ("ready", "steady") else "resume"
            row(f"L_{cname}_{opts[:4]}_{ph}", "L", ph, opts, "none", "none", 0, chub,
                v, cparams, l_hyp(cname, ph, opts, cphases))
for sname, sph, sflag, shub in L_SINGLES:
    for opts in ALL_OPTS:
        for ph in (sph, "ready", "steady"):
            v = "pong,stat" if ph in ("ready", "steady") else "resume"
            row(f"L_one_{sname}_{opts[:4]}_{ph}", "L", ph, opts, "none", "none", 0,
                shub, v, NOHUB + sflag,
                "격자점 — 단독 자원 × 옵션 5종 전수 (귀속·구제 조건의 완전표)")

# ═══ M. sampling — 라인 '사이' 검산: 시간 샘플링 dump ═══════════════════════
# 38개 phase가 CRIU-구별가능 상태의 전부라는 동치류 가설의 검산.
# gap 30ms 기동을 임의 시각에 저격 — 판정이 그 시각의 phase 지도 예측과
# 일치해야 하며, 벗어나는 표본이 나오면 '숨은 상태' 발견.
# ═══ N. substeps — 긴 줄의 '실행 도중' 라인바이라인 ═══════════════════════
# read/parse/index-touch 루프의 25/50/75% 지점 = "절반 읽은/절반 파싱한/절반
# 채운" 프로세스를 그 자리에서 dump→restore→잔여 진행 재개.
SUB_PH = ("db_read_p25", "db_read_p50", "db_read_p75",
          "db_parse_p25", "db_parse_p50", "db_parse_p75",
          "epg_index_p25", "epg_index_p50", "epg_index_p75")
for ph in SUB_PH:
    row(f"N_{ph}", "N", ph, "strict", "none", "none", 0, "none", "resume",
        NOHUB + " --substeps 1",
        "ok — 작업 도중 상태(부분 읽기/부분 파싱/부분 touch)도 얼리고 이어감. 이미지 크기가 진행률에 비례")
for ph in ("db_read_p50", "db_parse_p50", "epg_index_p50"):
    row(f"N_lock_{ph}", "N", ph, "strict", "none", "none", 0, "none", "resume",
        NOHUB + " --substeps 1 --db_lock flock",
        "dump_fail — 잠금 보유 중엔 작업 도중 시점도 전부 거부 (경계선이 진행 중간까지 관통)")
    row(f"N_lockrx_{ph}", "N", ph, "filelocks", "none", "none", 0, "none", "resume",
        NOHUB + " --substeps 1 --db_lock flock",
        "ok — --file-locks면 작업 도중 시점도 재개")

# ═══ O. srclines — 소스 문장 단위 라인바이라인 (자동 계측판) ═══════════════
# gen_lbl.py가 main() 생애주기의 순차 실행 문장 전부에 심은 Lsrc phase 각각에서
# dump→restore→재개. "코드 줄 하나 = dump 지점 하나"의 문자 그대로 판.
import os as _os
_lblf = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "lbl_phases.txt")
if _os.path.exists(_lblf):
    for _line in open(_lblf):
        _n, _ln, _stmt = _line.rstrip("\n").split("\t")
        for opts in ("strict", "permissive"):
            row(f"O_{_n}_{opts[:4]}", "O", _n, opts, "none", "none", 0, "normal",
                "resume", EVERYTHING + " --lbl 1",
                f"지도 일치 — 원본 {_ln}행 [{_stmt[:40]}] 직후: 그 시점 보유 자원의 phase 지도 예측과 동일해야")
else:
    print("[gen] WARN: lbl_phases.txt 없음 — O 가족 생략 (pbsprobe/gen_lbl.py 먼저)")

for opts in ("strict", "permissive"):
    for ms in (150, 300, 450, 600, 750, 900, 1100, 1300, 1600, 2000, 2500, 3000):
        row(f"M_t{ms}_{opts[:4]}", "M", "init", opts, f"settle{ms}", "none", 0,
            "normal", "resume", EVERYTHING + " --phase_gap_ms 30",
            "지도 일치 — 이 시각이 속한 phase 구간의 예측 판정과 동일해야 함 (불일치=숨은 상태)")


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios.csv")
    names = set()
    for r in ROWS:
        assert r["scenario"] not in names, f"중복 셀 이름: {r['scenario']}"
        names.add(r["scenario"])
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(ROWS[0].keys()))
    w.writeheader()
    for r in ROWS:
        w.writerow(r)
    with open(out, "w") as f:
        f.write(buf.getvalue())
    fam = {}
    for r in ROWS:
        fam[r["family"]] = fam.get(r["family"], 0) + 1
    print(f"[gen] {len(ROWS)} cells → {out}")
    print("      " + "  ".join(f"{k}:{v}" for k, v in sorted(fam.items())))


if __name__ == "__main__":
    sys.exit(main())
