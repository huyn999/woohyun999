#!/usr/bin/env python3
# pbsprobe/gen_matrix.py — 상황 × 라인 통합 매트릭스 (단일 일관 구조)
#
#   행 = 라인(생애주기 dump 지점: phase + 긴 줄의 25/50/75% + 소스 문장 Lsrc)
#   열 = 상황(가정): 앱 구성 + CRIU 옵션 + 조작 + 환경을 하나로 묶은 이름
#   셀 = "그 상황에서 그 라인에 dump→restore하면 문제가 되는가"
#
# 셀 이름: S<번호><상황>__<라인>   (요약기가 이 규약으로 라인×상황 표를 피벗)
# 전제조건 게이트만 적용: 그 상황의 구성에 존재하지 않는 라인,
# 조작의 대상이 아직 없는 라인(예: lock 제거는 tcp_conn 이후)은 제외.
import csv, os, sys

D = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(D, "scenarios.csv")

BASE_APP = ("--db_mib 8 --index_mib 12 --parse_iters 120000 --refresh_ms 500 "
            "--refresh_kib 256 --timer 1 --timer_s 60 --watch 1 --substeps 1 ")
NOHUB = BASE_APP + "--hub_conns 0"
HUB   = BASE_APP + "--hub_conns 4 --hub_pending 8"
HTCP  = HUB + " --tcp reqresp"
EVERY = (HTCP + " --threads 4 --selfpipe 1 --eventfd 1 --db_lock flock --shm_mib 4 "
         "--log_dgram 1 --render 1 --workdir 1 --child 1 --zombie 1 --sigpend 1 "
         "--urandom 1 --tmpunlink 1 --epoll 1 --udp 1 --netlink 1 --unix_listen 1 --mmap_db 1")
HEAVY = ("--db_mib 8 --index_mib 300 --parse_iters 60000 --hub_conns 0 "
         "--refresh_ms 500 --refresh_kib 256 --timer 0 --watch 0 --substeps 1")

SUB = lambda core: [p for c in core for p in ((c, c+"_p25", c+"_p50", c+"_p75")
                    if c in ("db_read", "db_parse", "epg_index") else (c,))]
NOHUB_PH = SUB(["init", "db_open", "db_read", "db_parse", "epg_index", "epg_text",
                "epg_reserve", "timer_armed", "db_watch"]) + ["ready", "steady"]
HUB_PH   = SUB(["init", "db_open", "db_read", "db_parse", "epg_index", "epg_text",
                "epg_reserve"]) + ["hub_conn1", "hub_conn2", "hub_conn3", "hub_conn4",
                "hub_subscribed", "timer_armed", "db_watch", "ready", "steady"]
HTCP_PH  = HUB_PH[:-4] + ["tcp_conn", "timer_armed", "db_watch", "ready", "steady"]
EVERY_PH = (["init", "sig_pending", "dev_urandom", "log_open", "db_open", "db_lock"]
            + SUB(["db_read", "db_parse", "epg_index"])[1:]  # db_read..epg_index(+p)
            + ["epg_text", "epg_reserve", "thread1", "thread2", "thread3", "thread4",
               "helper_forked", "zombie_made", "selfpipe", "eventfd_open", "shm_map",
               "workdir", "tmp_journal", "hub_conn1", "hub_conn2", "hub_conn3",
               "hub_conn4", "hub_subscribed", "render_conn", "tcp_conn", "epoll_open",
               "svc_listen", "udp_open", "netlink_open", "timer_armed", "db_watch",
               "db_mmap", "ready", "steady"])
HEAVY_PH = SUB(["init", "db_open", "db_read", "db_parse", "epg_index"]) + \
           ["epg_text", "epg_reserve", "ready", "steady"]

def after(phases, start):                       # start 라인부터 끝까지
    return phases[phases.index(start):]

# ── 상황 정의: 프로그램 생성 (구성×옵션 + 조작 + 메모리 + 허브세계) ──────────
SITS = []
_n = [0]
def sit(name, desc, params, opts, pre, post, mem, hubm, phases):
    _n[0] += 1
    SITS.append((f"{_n[0]:03d}", name, desc, params, opts, pre, post, mem, hubm, phases))

OPTS5 = ("strict", "ext_unix", "tcp_est", "filelocks", "permissive")
HUBn = lambda n: BASE_APP + f"--hub_conns {n} --hub_pending 8"
CORE = [  # (이름, params, hub_mode, 라인들)
    ("pure",  NOHUB, "none", NOHUB_PH),
    ("hub1",  HUBn(1), "normal", [p for p in HUB_PH if p not in ("hub_conn2","hub_conn3","hub_conn4")]),
    ("hub2",  HUBn(2), "normal", [p for p in HUB_PH if p not in ("hub_conn3","hub_conn4")]),
    ("hub4",  HUB, "normal", HUB_PH),
    ("hub8",  HUBn(8), "normal", HUB_PH),
    ("tcprr", HTCP, "normal", HTCP_PH),
    ("tcpst", HUB + " --tcp stream", "normal", HTCP_PH),
    ("heavy", HEAVY, "none", HEAVY_PH),
    ("light", "--db_mib 2 --index_mib 24 --parse_iters 20000 --hub_conns 0 --refresh_ms 300 --refresh_kib 512 --timer 0 --watch 0 --substeps 1", "none", HEAVY_PH),
    ("all",   EVERY, "normal", EVERY_PH),
]
for cname, cpar, chub, cph in CORE:          # 구성 10 × 옵션 5 = 상황 50
    for o in OPTS5:
        sit(f"{cname}.{o[:4]}", f"{cname} 구성·{o}", cpar, o, "none", "none", 0, chub, cph)

SINGLES = [  # 자원 1개 상황 18 × 옵션 5 = 90 (라인 = 그 자원 지점+완료 2)
    ("sigpend"," --sigpend 1","none","sig_pending"), ("urandom"," --urandom 1","none","dev_urandom"),
    ("log"," --log_dgram 1","normal","log_open"), ("lockf"," --db_lock flock","none","db_lock"),
    ("lockp"," --db_lock posix","none","db_lock"), ("thread"," --threads 4","none","thread4"),
    ("child"," --child 1","none","helper_forked"), ("zombie"," --zombie 1","none","zombie_made"),
    ("selfpipe"," --selfpipe 1","none","selfpipe"), ("eventfd"," --eventfd 1","none","eventfd_open"),
    ("shm"," --shm_mib 4","none","shm_map"), ("wd"," --workdir 1","none","workdir"),
    ("journal"," --tmpunlink 1","none","tmp_journal"), ("render"," --render 1","normal","render_conn"),
    ("epoll"," --epoll 1 --eventfd 1","none","epoll_open"), ("listen"," --unix_listen 1","none","svc_listen"),
    ("udp"," --udp 1","none","udp_open"), ("netlink"," --netlink 1","none","netlink_open"),
]
for rname, rflag, rhub, rph in SINGLES:
    for o in OPTS5:
        sit(f"one_{rname}.{o[:4]}", f"단독자원 {rname}·{o}", NOHUB + rflag, o,
            "none", "none", 0, rhub, ["init", "db_open", rph, "epg_index", "ready", "steady"])

MANIP = [  # 조작 상황 (적정 구성·옵션 고정) — 전제 성립 라인들
    ("rescue","처방(연결해제)", EVERY,"permissive","bye","none",0,"normal", after(EVERY_PH,"hub_conn1")),
    ("rescue_tcp","처방+TCP만", HTCP,"tcp_est","bye","none",0,"normal", after(HTCP_PH,"hub_conn1")),
    ("droplock","CRIU lock 제거", HTCP,"tcp_est","none","droplock_sleep2",0,"normal", after(HTCP_PH,"tcp_conn")),
    ("frz15","15초 정지", NOHUB,"strict","none","sleep15",0,"none", NOHUB_PH),
    ("frz45","45초 정지", NOHUB,"strict","none","sleep45",0,"none", NOHUB_PH),
    ("frz45_rx","45초 정지+처방", EVERY,"permissive","bye","sleep45",0,"normal", after(EVERY_PH,"hub_conn1")),
    ("dbgone","DB 소실", NOHUB,"strict","none","rmdb",0,"none", after(NOHUB_PH,"db_open")),
    ("dbswap","DB inode 교체", NOHUB+" --watch 1","strict","none","rmdb_recreate",0,"none", after(NOHUB_PH,"db_watch")),
    ("dbtouch","DB 갱신", NOHUB,"strict","none","touchdb",0,"none", after(NOHUB_PH,"db_watch")),
    ("shmgone","shm 소실", NOHUB+" --shm_mib 4","strict","none","rmshm",0,"none", ["shm_map","ready","steady"]),
    ("wdgone","cwd 소실", NOHUB+" --workdir 1","strict","none","rmwd",0,"none", ["workdir","ready","steady"]),
    ("trunc","mmap 절단", NOHUB+" --mmap_db 1","strict","none","truncdb",0,"none", ["db_mmap","ready","steady"]),
    ("ota","바이너리 교체", NOHUB,"strict","none","mvbin",0,"none", NOHUB_PH),
    ("ota_back","교체 후 복귀", NOHUB,"strict","none","mvbin_back",0,"none", ["epg_index","ready","steady"]),
    ("squat","이름 선점", NOHUB+" --unix_listen 1","strict","none","squat",0,"none", ["svc_listen","ready","steady"]),
    ("hubup","허브 교체+처방", HUB,"strict","bye","hub_restart",0,"normal", ["hub_subscribed","ready","steady"]),
    ("cycle2","처방 2사이클", HUB,"strict","bye","cycle2",0,"normal", ["hub_subscribed","ready","steady"]),
    ("re2","순차 재복원", NOHUB,"strict","none","restore2",0,"none", ["epg_index","ready","steady"]),
    ("dup","동시 복원", NOHUB,"strict","none","restore_dup",0,"none", ["ready","steady"]),
]
for m in MANIP: sit(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])

# GitHub 이슈 계열 상황 (gh#505 half-closed, PR#2030 SCM/송신자 사망, timerfd 만기, backlog flood)
HC = HUB + " --tcp stream --tcp_halfclose 1"
HC_PH = HUB_PH[:9] + ["hub_conn1","hub_conn2","hub_conn3","hub_conn4","hub_subscribed",
                      "tcp_conn","tcp_halfclosed","ready","steady"]
for o in OPTS5:
    sit(f"halfclose.{o[:4]}", f"half-closed TCP(gh#505)·{o}", HC, o, "none","none",0,"normal",
        ["tcp_conn","tcp_halfclosed","ready","steady"])
for o in ("strict","ext_unix","permissive"):
    sit(f"scm.{o[:4]}", f"fd 실린 미수신 SCM(PR#2030)·{o}", HUBn(1)+" --pass_fd", o,
        "none","none",0,"normal", ["hub_conn1","hub_subscribed","ready","steady"])
sit("scm_gone","SCM 송신자 사망(PR#2030)", HUBn(1)+" --pass_fd","strict","hubkill","none",0,"normal",
    ["hub_subscribed","ready","steady"])
sit("timer_exp","타이머 만기 경과 정지", NOHUB.replace("--timer_s 60","--timer_s 5"),"strict",
    "none","sleep15",0,"none", ["timer_armed","ready","steady"])
sit("flood","재등록 backlog 폭주(WORLD 전용 의미)", HUB+" --flood_name 1","strict","bye","none",0,"normal",
    ["hub_subscribed","ready","steady"])
sit("flood45","45s 부재 후 폭주(WORLD)", HUB+" --flood_name 1","strict","bye","sleep45",0,"normal",
    ["ready","steady"])
# 주요 조작 × 옵션 확장 (strict 외 permissive 판정도)
for nm,desc,par,pre,post,mem,hub,ph in [
    ("droplock2","lock 제거·옵션총동원", HTCP,"none","droplock_sleep2",0,"normal", after(HTCP_PH,"tcp_conn")),
    ("dbgone2","DB 소실·옵션총동원", NOHUB,"none","rmdb",0,"none", after(NOHUB_PH,"db_open")),
    ("ota2","OTA·옵션총동원", NOHUB,"none","mvbin",0,"none", ["epg_index","ready","steady"]),
    ("trunc2","mmap 절단·옵션총동원", NOHUB+" --mmap_db 1","none","truncdb",0,"none", ["db_mmap","ready","steady"]),
    ("squat2","이름 선점·옵션총동원", NOHUB+" --unix_listen 1","none","squat",0,"none", ["svc_listen","ready","steady"]),
    ("shmgone2","shm 소실·옵션총동원", NOHUB+" --shm_mib 4","none","rmshm",0,"none", ["shm_map","ready","steady"]),
    ("dbswap2","inode 교체·옵션총동원", NOHUB+" --watch 1","none","rmdb_recreate",0,"none", after(NOHUB_PH,"db_watch")),
]:
    sit(nm,desc,par,"permissive",pre,post,mem,hub,ph)

for lim in (300, 330, 500, 700, 1024):       # 메모리 상황 heavy×5 + light×2
    sit(f"mem{lim}", f"heavy를 {lim}MiB 한도 복원", HEAVY,"strict","none","none",lim,"none", HEAVY_PH)
for lim in (330, 500):
    sit(f"lmem{lim}", f"light-dirty를 {lim}MiB 한도 복원",
        "--db_mib 2 --index_mib 24 --parse_iters 20000 --hub_conns 0 --refresh_ms 300 --refresh_kib 512 --timer 0 --watch 0 --substeps 1",
        "strict","none","none",lim,"none", HEAVY_PH)

sit("noaccept","허브가 accept 안 함(backlog)", HUBn(1),"strict","none","none",0,"noaccept", ["hub_conn1"])
sit("hubdead","재접속 대상 부재", HUB,"strict","bye","none",0,"down_after", ["hub_subscribed","ready","steady"])
sit("selfhub","경계 안 허브(대조)", BASE_APP+"--hub_conns 2 --hub_pending 8 --selfhub 1","strict","none","none",0,"self", HUB_PH[:9]+["hub_conn1","hub_conn2","hub_subscribed","ready","steady"])

sit("srcline","소스 문장·옵션 없음", EVERY+" --lbl 1","strict","none","none",0,"normal", None)
sit("srcline_opt","소스 문장·옵션 총동원", EVERY+" --lbl 1","permissive","none","none",0,"normal", None)

def hyp(sname, ph, opts, pre):
    if pre == "bye":
        return "ok — 처방이 외부연결을 해제했으므로 이 라인도 통과 (전 라인 생존이 처방의 증명)"
    lock = ph == "db_lock" or (sname in ("all", "all_opt") and "db_lock" in EVERY_PH
                               and EVERY_PH.index(ph) >= EVERY_PH.index("db_lock"))
    hub = "hub_conn" in ph or (sname.startswith(("hub", "all", "tcp")) and ph in
          ("hub_subscribed", "render_conn", "tcp_conn", "epoll_open", "svc_listen",
           "udp_open", "netlink_open", "timer_armed", "db_watch", "db_mmap", "ready", "steady")
          and sname not in ("tcp",))
    if sname.startswith(("frz", "pure")):
        return "ok — 자원 무해 구간 전체 통과"
    if sname in ("dbgone", "shmgone", "wdgone"):
        return "restore_fail — 열린 DB의 원본 소실 (라인 무관)"
    if sname in ("ota", "squat"):
        return "restore_fail — 실행파일 소실 (라인 무관)"
    if sname.startswith(("mem", "lmem")):
        return "경계 — 이미지가 한도를 넘는 라인부터 실패 (진행률 지점이 경계 정밀화)"
    if sname == "droplock":
        return "conn_dead — 복원은 성공하나 TCP만 침묵사 (rc로 안 보임)"
    if sname == "tcp":
        return "ok — tcp-established가 TCP를 구제 (hub 없음… 단 hub 라인 이후는 fail)" \
            if "hub" not in ph else "dump_fail — hub established"
    if lock and opts == "strict":
        return "dump_fail — 잠금 보유 시점부터 (경계선 1)"
    if hub:
        return "dump_fail — hub established는 옵션 불가 (경계선 2, 처방만이 답)"
    return "ok — 이 라인의 자원은 해당 옵션에서 무해"

rows = []
def emit(num, sname, desc, params, opts, pre, post, mem, hubm, ph):
    rows.append({"scenario": f"S{num}{sname}__{ph}", "family": "S", "phase": ph,
                 "criu_opts": opts, "pre_dump": pre, "post_dump": post,
                 "restore_mem_mib": mem, "hub_mode": hubm,
                 "verify": "pong,stat" if ph in ("ready", "steady") else "resume",
                 "params": params, "hypothesis": f"[{desc}] " + hyp(sname, ph, opts, pre)})

for num, sname, desc, params, opts, pre, post, mem, hubm, phases in SITS:
    if phases is None:                          # 소스 문장 상황: Lsrc 목록에서
        lblf = os.path.join(D, "lbl_phases.txt")
        if not os.path.exists(lblf):
            print("[gen] WARN: lbl_phases.txt 없음 — srcline 상황 생략 (gen_lbl.py 먼저)")
            continue
        for line in open(lblf):
            n, ln, stmt = line.rstrip("\n").split("\t")
            emit(num, sname, desc, params, opts, pre, post, mem, hubm, n)
        continue
    for ph in phases:
        emit(num, sname, desc, params, opts, pre, post, mem, hubm, ph)

with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["scenario", "family", "phase", "criu_opts",
                                      "pre_dump", "post_dump", "restore_mem_mib",
                                      "hub_mode", "verify", "params", "hypothesis"])
    w.writeheader()
    w.writerows(rows)
per = {}
for r in rows:
    k = r["scenario"].split("__")[0]
    per[k] = per.get(k, 0) + 1
print(f"[gen] 상황 {len(per)}개 × 라인 = {len(rows)}셀 → {OUT}")
for k in sorted(per):
    print(f"      {k:14s} {per[k]:3d}라인")
