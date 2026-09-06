#!/usr/bin/env python3
"""webos_probe/summarize_webos.py — 비교 도출 리포트

입력: compat_sweep이 만든 CSV (fp_w_* 행 사용; v1 CSV를 함께 주면 대조표에 반영)
출력: "webOS 실재 상황 통과 지도 + 실패요인 등급 대조" 텍스트 리포트

  python3 summarize_webos.py results/compat_permissive_tv.csv [v1.csv]
"""
import csv, sys, collections

KIND = {}
DESC = {}
def load_catalog():
    import importlib.util, os
    spec = importlib.util.spec_from_file_location(
        "genw", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen_workloads_w.py"))
    m = importlib.util.module_from_spec(spec)
    # gen_workloads import 부작용 없이 카탈로그만 얻기 위해 W 정의부를 텍스트 파싱하지 않고
    # 모듈 실행이 필요하므로, failprobe 경로가 있어야 한다. 실패 시 카탈로그 없이 진행.
    try:
        spec.loader.exec_module(m)
        for name, feats, kind, desc in m.W:
            KIND[name] = kind; DESC[name] = desc
    except SystemExit:
        pass
    except Exception:
        pass

SIG = [
 ("C1_tcp_inflight",  "In-flight connection",            "재현 예상(①): 원격 연결 수립 창 — 재시도/--skip-in-flight로 흡수"),
 ("C2_session",       "Can't fork for",                  "재현 예상(②): 트리 후 setsid — 순서 교정으로 소거"),
 ("C3_ctty",          "ctty inheritance",                "재현 예상(③): 개발자모드 한정 — setsid 기동으로 소거"),
 ("C4_mq_mount",      "Can't lookup mount",              "비-webOS(④·C급): mq 미사용 판단 — check_webos_usage.sh로 검증"),
 ("L_sysv",           "doesn't live in IPC ns",          "비-webOS(레거시): SysV 미사용 판단 — 동일 검증"),
 ("UNIX_inflight?",   "",                                 ""),
]

def classify(err_d, err_r):
    blob = (err_d or "") + (err_r or "")
    for tag, pat, _ in SIG:
        if pat and pat in blob: return tag
    return "NEW" if blob.strip() else "?"

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rows = list(csv.DictReader(open(sys.argv[1])))
    w = [r for r in rows if r["workload"].startswith("fp_w_")]
    if not w:
        sys.exit("CSV에 fp_w_* 행이 없음 — webOS 스윕을 먼저 실행하세요")
    load_catalog()

    per = collections.OrderedDict()
    for r in w:
        wl = r["workload"]; per.setdefault(wl, {"cells":0,"fail":[],"pass":0})
        per[wl]["cells"] += 1
        launch_ok = r.get("launch_ok","1")
        dfail = r.get("dump_rc") == "1"; rfail = r.get("restore_rc") == "1"
        vfail = r.get("verify") in ("pong_fail","resume_stalled")
        if launch_ok == "0" or dfail or rfail or vfail:
            per[wl]["fail"].append((r["phase"],
                classify(r.get("dump_err",""), r.get("restore_err",""))))
        else:
            per[wl]["pass"] += 1

    print("=" * 72)
    print(" webOS 충실 스윕 — 비교 도출 리포트")
    print("=" * 72)
    order = {"P":0, "R":1, "U":2}
    for wl in sorted(per, key=lambda x: (order.get(KIND.get(x,"P"), 3), x)):
        d = per[wl]; k = KIND.get(wl, "?")
        head = f"[{k}] {wl}: {d['pass']}/{d['cells']} 통과"
        if not d["fail"]:
            print(f"  {head}  — 전 지점 통과")
        else:
            tags = collections.Counter(t for _, t in d["fail"])
            first = d["fail"][0][0]
            print(f"  {head}  — 실패 {len(d['fail'])}셀 (최초 {first}) → {dict(tags)}")
        if wl in DESC: print(f"        └ {DESC[wl]}")

    # 부류별 요약과 서사 문장
    agg = collections.defaultdict(lambda: [0,0])
    tagset = collections.Counter()
    for wl, d in per.items():
        k = KIND.get(wl, "?"); agg[k][0] += d["pass"]; agg[k][1] += d["cells"]
        for _, t in d["fail"]: tagset[t] += 1
    print("\n" + "-" * 72)
    print(" 부류별: " + "  ".join(f"[{k}] {a}/{b}" for k,(a,b) in sorted(agg.items())))
    print(" 실패 태그 분포:", dict(tagset) or "없음")
    new = tagset.get("NEW", 0)
    print("-" * 72)
    print(" 서사 도출:")
    p_pass, p_tot = agg.get("P",[0,0])
    print(f"  1) webOS 실재 상황(P군): {p_pass}/{p_tot} 셀 통과"
          + (" — 실재 상황은 얼려진다" if p_pass == p_tot else " — P군 실패는 개별 검토 필요(아래 태그)"))
    print( "  2) 실패 재현(R군): 기측정 클러스터의 webOS 맥락 재발현 여부 확인")
    print( "  3) 미지수(U군: registration): UNIX in-flight " +
          ("→ NEW 태그 발생 시 신규 발견" if new else "→ 통과 시 'luna 등록은 TCP와 달리 안전' 대비 발견"))
    print( "  4) 비-webOS 실패요인(mq/SysV)은 이 스윕에 없음 — v1 커버리지 결과 인용 +")
    print( "     check_webos_usage.sh 결과로 '미사용→무해' 판정을 근거화")
    for tag, _, note in SIG:
        if tag in tagset and note: print(f"     · {tag}: {note}")

if __name__ == "__main__":
    main()
