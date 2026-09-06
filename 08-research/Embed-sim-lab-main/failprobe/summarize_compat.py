#!/usr/bin/env python3
"""summarize_compat.py — compat_sweep 결과 CSV 요약.

출력:
  1. 전체 통계 (셀 수, dump 실패, restore 실패, verify 실패)
  2. 실패 워크로드 × phase 목록
  3. 에러 클러스터: CRIU 소스 위치(criu/xxx.c)별 빈도 — "어느 서브시스템이 원인인가"
  4. feature별 실패율 (scenarios.csv가 옆에 있으면)

Usage: python3 summarize_compat.py failprobe/results/compat_strict.csv [-o summary.md]
"""
import argparse
import collections
import csv
import os
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("-o", "--out", default=None, help="markdown 요약 저장 경로")
    args = ap.parse_args()

    rows = list(csv.DictReader(open(args.csv_path)))
    if not rows:
        sys.exit("empty csv")

    lines = []
    def em(s=""):
        lines.append(s)
        print(s)

    n = len(rows)
    launch_fail = [r for r in rows if r["launch_ok"] != "1"]
    dump_fail = [r for r in rows if r["launch_ok"] == "1" and r["dump_rc"] not in ("0", "na") ]
    restore_fail = [r for r in rows if r["dump_rc"] == "0" and r["restore_rc"] not in ("0", "na")]
    verify_fail = [r for r in rows if r["restore_rc"] == "0" and r["verify"] in ("pong_fail", "resume_stalled")]
    full_ok = [r for r in rows if r["dump_rc"] == "0" and r["restore_rc"] == "0"
               and r["verify"] in ("pong_ok", "resumed_to_ready")]

    em(f"# CRIU compat sweep 요약 — {os.path.basename(args.csv_path)}")
    em()
    em(f"- 셀(워크로드×phase): {n}")
    em(f"- 완전 성공 (dump+restore+verify): {len(full_ok)} ({100*len(full_ok)/n:.1f}%)")
    em(f"- launch/phase 미도달: {len(launch_fail)}")
    em(f"- dump 실패: {len(dump_fail)}")
    em(f"- restore 실패 (dump는 성공): {len(restore_fail)}")
    em(f"- verify 실패 (restore는 성공, 서비스 미복귀): {len(verify_fail)}")
    em()

    def err_src(e):
        m = re.search(r"Error \((criu/[^:)+]+)", e or "")
        return m.group(1) if m else ("(no-error-line)" if not e else "(unparsed)")

    for title, group, key in [("dump 실패 에러 클러스터", dump_fail, "dump_err"),
                              ("restore 실패 에러 클러스터", restore_fail, "restore_err")]:
        em(f"## {title}")
        if not group:
            em("(없음)")
            em()
            continue
        clus = collections.Counter(err_src(r[key]) for r in group)
        for src, c in clus.most_common():
            em(f"- **{src}** × {c}")
            sample = next(r for r in group if err_src(r[key]) == src)
            em(f"  - 예: `{sample['workload']}@{sample['phase']}` — {sample[key][:160]}")
        em()

    em("## 실패 셀 상세 (workload × phase)")
    bad = launch_fail + dump_fail + restore_fail + verify_fail
    if not bad:
        em("(전부 성공)")
    for r in sorted(bad, key=lambda r: (r["workload"], r["phase"])):
        stage = ("launch" if r in launch_fail else "dump" if r in dump_fail
                 else "restore" if r in restore_fail else "verify")
        err = r["dump_err"] if stage == "dump" else r["restore_err"] if stage == "restore" else ""
        em(f"- `{r['workload']}` @ `{r['phase']}` → **{stage} 실패** {('— ' + err[:140]) if err else ''}")
    em()

    # feature별 실패율 (scenarios.csv 있으면)
    scen_path = os.path.join(os.path.dirname(os.path.abspath(args.csv_path)), "..", "scenarios.csv")
    scen_path = os.path.normpath(scen_path)
    if os.path.isfile(scen_path):
        feats_of = {r["name"]: r["features"].split(",") for r in csv.DictReader(open(scen_path))}
        tot = collections.Counter()
        bad_c = collections.Counter()
        badset = {(r["workload"], r["phase"]) for r in bad}
        for r in rows:
            for f in feats_of.get(r["workload"], []):
                tot[f] += 1
                if (r["workload"], r["phase"]) in badset:
                    bad_c[f] += 1
        em("## feature별 실패율 (해당 feature 포함 셀 기준)")
        ranked = sorted(tot, key=lambda f: (-(bad_c[f] / tot[f]), -tot[f]))
        for f in ranked:
            if bad_c[f] == 0:
                continue
            em(f"- **{f}**: {bad_c[f]}/{tot[f]} ({100*bad_c[f]/tot[f]:.0f}%)")
        clean = [f for f in ranked if bad_c[f] == 0]
        if clean:
            em(f"- 실패 0: {', '.join(clean)}")

    if args.out:
        with open(args.out, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        print(f"\nsaved: {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
