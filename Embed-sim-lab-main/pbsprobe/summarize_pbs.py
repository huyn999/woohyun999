#!/usr/bin/env python3
"""summarize_pbs.py — pbs_matrix.csv → 판정 매트릭스 + 에러 클러스터 + 가설 대조 (markdown)

usage: python3 summarize_pbs.py [results/pbs_matrix.csv] > report.md
"""
import csv
import os
import re
import sys
from collections import Counter, defaultdict

FAM_TITLE = {
    "A": "A. lifecycle — 기동 생애주기 라인 스윕",
    "B": "B. hub — Luna hub 축 (경계 밖 연결과 처방)",
    "C": "C. tcp — TCP feed 축 (lock 생존 조건)",
    "D": "D. memory — 메모리 축 (fail-fast vs 침묵형)",
    "E": "E. ops — 운영 상황·처방 총합",
    "F": "F. surface — 추가 자원 전수 검사 (잠금·스레드·DGRAM·shm·렌더·cwd)",
    "G": "G. world — 상시 배경 세계(webOS 근사) 상호작용",
    "H": "H. issues — CRIU 실사용 이슈(GitHub) 도출 함정",
    "I": "I. reality — 운영 현실·환경 변동 (트리·시그널·선점·OTA·SIGBUS·감시무효)",
    "J": "J. fullmap — 전 라인 완전 지도 (만물 구성 × 양극 옵션 + 자원별 단독 라인)",
    "K": "K. gridmap — 상황×라인 일관 격자 (조작을 전제 성립 라인마다)",
    "L": "L. exhaustive — 완전 격자: 구성×라인×옵션 5종 전수",
    "M": "M. sampling — 라인 사이 시간 샘플링 (동치류 검산)",
    "N": "N. substeps — 긴 줄의 실행 도중 라인 (부분 읽기/파싱/touch)",
    "O": "O. srclines — 소스 문장 단위 (자동 계측, 코드 줄=dump 지점)",
    "S": "S. matrix — 상황×라인 통합 매트릭스",
}

# hypothesis 문자열 → 기대 판정 키워드 (pre-registration 대조)
HYP_MAP = [
    (r"^silent_dead", {"silent_dead", "conn_dead"}),
    (r"^dump_fail", {"dump_fail"}),
    (r"^restore_fail", {"restore_fail"}),
    (r"^ok", {"ok", "orig_intact"}),
    (r"^부분|^경계", None),   # 경계 사례: 사전 판정 유보 — 일치율 계산에서 제외
]


def expected_of(hyp):
    for pat, exp in HYP_MAP:
        if re.match(pat, hyp):
            return exp
    return None


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "pbs_matrix.csv")
    rows = list(csv.DictReader(open(path, newline="")))
    if not rows:
        print("빈 CSV:", path)
        return 1

    # 가설 조인 (scenarios.csv)
    scen_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios.csv")
    hyp = {}
    if os.path.exists(scen_path):
        for r in csv.DictReader(open(scen_path, newline="")):
            hyp[r["scenario"]] = r["hypothesis"]

    print("# pbsprobe 판정 매트릭스\n")
    print(f"셀 {len(rows)}개 — `{os.path.basename(path)}`\n")

    vc = Counter(r["verdict"] for r in rows)
    print("## 전체 판정 분포\n")
    print("| verdict | n |")
    print("|---|---|")
    for v, n in vc.most_common():
        print(f"| {v} | {n} |")
    print()

    for fam in "ABCDEFGHIJKLMNOS":
        frows = [r for r in rows if r["family"] == fam]
        if not frows:
            continue
        print(f"## {FAM_TITLE.get(fam, fam)}\n")
        print("| scenario | phase | opts | pre | post | mem | verdict | pong | stat | hub | tcp | live5 | resume | rereg_ms |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in frows:
            print("| {scenario} | {phase} | {criu_opts} | {pre_dump} | {post_dump} | "
                  "{restore_mem_mib} | **{verdict}** | {v_pong} | {v_stat} | {v_hub} | "
                  "{v_tcp} | {v_live5} | {v_resume} | {rereg_ms} |".format(**r))
        print()

    # 가설 대조 (pre-registration)
    if hyp:
        match = miss = held = 0
        misses = []
        for r in rows:
            h = hyp.get(r["scenario"], "")
            exp = expected_of(h)
            if exp is None:
                held += 1
                continue
            if r["verdict"] in exp:
                match += 1
            else:
                miss += 1
                misses.append((r["scenario"], h.split("—")[0].strip(), r["verdict"]))
        total = match + miss
        print("## 사전 가설 대조 (pre-registration)\n")
        if total:
            print(f"- 일치 {match}/{total} ({100.0 * match / total:.1f}%), 유보(경계 사례) {held}\n")
        if misses:
            print("| scenario | 가설 | 실측 |")
            print("|---|---|---|")
            for s, h, v in misses:
                print(f"| {s} | {h} | {v} |")
            print()
            print("불일치는 실패가 아니라 결과다 — 셀 로그(`results/runs/<scenario>/`)로 원인 확정.\n")

    # 에러 클러스터
    errs = Counter()
    for r in rows:
        for k in ("dump_err", "restore_err"):
            e = r.get(k, "").strip().strip('"')
            if e:
                m = re.search(r"\(criu/([a-z0-9_\-]+\.c):(\d+)\)", e)
                errs[m.group(1) + ":" + m.group(2) if m else e[:60]] += 1
    if errs:
        print("## CRIU 에러 클러스터 (파일:줄)\n")
        print("| 위치 | n |")
        print("|---|---|")
        for e, n in errs.most_common(15):
            print(f"| `{e}` | {n} |")
        print()

    # 처방 비용
    ms = [int(r["rereg_ms"]) for r in rows if r.get("rereg_ms", "na") not in ("na", "")]
    if ms:
        ms.sort()
        print("## disconnect & re-register 처방 비용\n")
        print(f"- 재등록 소요: median {ms[len(ms)//2]} ms, min {ms[0]} / max {ms[-1]} (n={len(ms)})\n")
    pivot_S(rows)

    return 0


def pivot_S(rows):
    S=[r for r in rows if r["family"]=="S"]
    if not S: return
    sits=sorted({r["scenario"].split("__")[0] for r in S})
    # 라인 순서: 첫 등장 순 보존
    seen=[]; 
    for r in S:
        ph=r["scenario"].split("__",1)[1]
        if ph not in seen: seen.append(ph)
    code={"ok":"O","dump_fail":"D","restore_fail":"R","silent_dead":"S!","conn_dead":"C!",
          "no_service":"N","resume_stalled":"Z","orig_intact":"I","launch_fail":"L!","dry":"·"}
    idx={(r["scenario"].split("__")[0], r["scenario"].split("__",1)[1]):r["verdict"] for r in S}
    print("\n## 상황 × 라인 매트릭스 (O=ok D=dump실패 R=restore실패 S!=침묵사 C!=연결사)\n")
    print("| 라인 \\ 상황 | " + " | ".join(x[3:] or x for x in sits) + " |")
    print("|---" * (len(sits)+1) + "|")
    for ph in seen:
        cells=[code.get(idx.get((s0,ph),""), " ") if (s0,ph) in idx else " " for s0 in sits]
        print(f"| {ph} | " + " | ".join(cells) + " |")

if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:   # | head 등으로 파이프가 먼저 닫혀도 정상 종료
        sys.exit(0)
