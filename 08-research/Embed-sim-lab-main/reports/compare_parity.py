#!/usr/bin/env python3
"""새 parity 캠페인(4셀×{cold,koff,kon}=12조건) median이 old wsk_redesign bootstrap 95% CI
안에 드는지 판정한다 (스펙 §8-3, testbed-rewrite Task 20 Step 3).

Usage:
  compare_parity.py <old_summary_csv> <new_summary_csv>
  compare_parity.py --selftest <old_summary_csv>     # new_summary_csv 없이 로직만 자가 검증

  old_summary_csv : testbed/experiments/wsk_redesign/summary_by_condition.csv (동결 대상 — 진실)
  new_summary_csv : testbed/experiments/parity/summary_by_condition.csv (캠페인 finalize()가 생성)

두 CSV 모두 testbed/runner/summarize.py 출력 스키마를 공유한다(condition, median_{m}_s,
{m}_s_ci_lo/hi 등) — reports/make_wsk_figures.py의 med()/ci() 헬퍼와 동일한 열 이름 관례를
그대로 따른다. all_runs.csv를 직접 파싱해 median을 재계산하지 않는 이유: summarize.py가
이미 (exp_id, condition, dump_phase)별 median/bootstrap-CI를 계산해 두므로, 여기서 같은 로직을
복제하면 두 곳이 갈라질 위험만 커진다(동일 계산은 동일 함수 1곳 — expand_campaign.py가
config_to_env.py를 재사용하는 것과 같은 원칙).

MAP 키(새 condition)는 expand_campaign.py:run_name()이 실제로 만드는 이름이다. campaign_parity.yaml은
axes.cpu=[busy,idle]·axes.kdat=[on,off] 둘 다 값이 여럿(varies)이라 항상 토큰화되지만, 각
workload의 sweep(dirty.bytes=[50] 1개, initburst.calibrate_from_ms=[150] 1개)은 값이 하나뿐이라
sweep 토큰이 안 붙는다(run_name(): `if sweep_varies: tokens.append(...)`, sweep_varies =
len(display_vals) > 1). 그래서 새 condition은 "dirty_cpubusy"이지 old 관례의 "dirty_50M_cpubusy"가
아니다 — 브리프가 경고한 부분. testbed/configs/campaign_parity.yaml을
`expand_campaign.py --resolve initburst.iters=<calib값> --yes`로 실제 전개해 plan.tsv의
run_id(rep 접미사 제거)로 실측 확인함(dry-run, Task 20 준비 단계).
"""
import argparse
import csv
import sys

# 새 condition(summarize.py:condition_of() 규칙대로 run_id에서 "_rep<NN>"를 뗀 값) →
#   (old condition, [비교할 지표 접두사 목록])
# 지표 접두사 m은 median_{m}_s / {m}_s_ci_lo / {m}_s_ci_hi 세 열에 대응한다(§8-3 비교 대상).
# 4셀(dirty×{cpubusy,cpuidle}, initburst×{cpubusy,cpuidle}) × 3(cold/kon/koff) = 12조건.
MAP = {
    "dirty_cpubusy":          ("dirty_50M_cpubusy",        ["cold_response"]),
    "dirty_cpuidle":          ("dirty_50M_cpuidle",        ["cold_response"]),
    "dirty_cpubusy_kon":      ("dirty_50M_cpubusy_kon",    ["restore_response", "restore_time"]),
    "dirty_cpubusy_koff":     ("dirty_50M_cpubusy_koff",   ["restore_response", "restore_time"]),
    "dirty_cpuidle_kon":      ("dirty_50M_cpuidle_kon",    ["restore_response", "restore_time"]),
    "dirty_cpuidle_koff":     ("dirty_50M_cpuidle_koff",   ["restore_response", "restore_time"]),
    "initburst_cpubusy":      ("ib_150ms_cpubusy",         ["cold_response"]),
    "initburst_cpuidle":      ("ib_150ms_cpuidle",         ["cold_response"]),
    "initburst_cpubusy_kon":  ("ib_150ms_cpubusy_kon",     ["restore_response", "restore_time"]),
    "initburst_cpubusy_koff": ("ib_150ms_cpubusy_koff",    ["restore_response", "restore_time"]),
    "initburst_cpuidle_kon":  ("ib_150ms_cpuidle_kon",     ["restore_response", "restore_time"]),
    "initburst_cpuidle_koff": ("ib_150ms_cpuidle_koff",    ["restore_response", "restore_time"]),
}


def load_by_condition(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    by_cond = {}
    for r in rows:
        cond = r["condition"]
        if cond in by_cond:
            sys.exit(
                f"ERROR: duplicate condition '{cond}' in {path} — summary CSV should have one "
                "row per condition (campaign에 dump_at 값이 여럿이면 이 스크립트 확장 필요)"
            )
        by_cond[cond] = r
    return by_cond


def detect_condition_prefix(conds, map_keys):
    """새 summary의 condition이 `<prefix>_<mapkey>` 형태(hardening v2 §1 캠페인 접두)면 그 prefix를
    돌려준다(무접두 기존 summary면 ""). 캠페인 이름에 '_'가 들어갈 수 있으므로(예: parity_smoke)
    각 condition의 모든 '_' 경계 누적 접두를 후보로 삼아, 벗겼을 때 MAP 키와 가장 많이 겹치는
    후보를 고른다(동률이면 긴 접두 우선 — Codex 교차검토 low-2). 무접두 summary에선 어떤 후보로
    벗겨도 MAP 키와 안 겹쳐 "" — 기존 동작 보존. 자동 감지가 애매하면 --condition-prefix로 명시."""
    mk = set(map_keys)
    candidates = set()
    for c in conds:
        parts = c.split("_")
        for i in range(1, len(parts)):
            candidates.add("_".join(parts[:i]))
    best, best_hits = "", 0
    for p in sorted(candidates, key=len):
        stripped = {c[len(p) + 1:] for c in conds if c.startswith(p + "_")}
        hits = len(stripped & mk)
        if hits > best_hits or (hits == best_hits and hits > 0 and len(p) > len(best)):
            best, best_hits = p, hits
    return best if best_hits else ""


def reprefix_new(new_by_cond, prefix):
    """새 condition에서 `<prefix>_` 접두를 떼어 MAP 키(무접두)와 맞춘다. prefix가 ""면 그대로."""
    if not prefix:
        return new_by_cond
    out = {}
    for cond, row in new_by_cond.items():
        stripped = cond[len(prefix) + 1:] if cond.startswith(prefix + "_") else cond
        if stripped in out:
            sys.exit(f"ERROR: condition prefix '{prefix}' 제거 후 '{stripped}' 충돌 — "
                     "접두를 잘못 잡았거나 summary에 접두/무접두가 섞여 있다")
        out[stripped] = row
    return out


def to_float(row, key, path, cond):
    raw = row.get(key)
    if raw is None or raw in ("", "NA", "na"):
        sys.exit(f"ERROR: {path} condition '{cond}': column '{key}' missing/NA")
    try:
        return float(raw)
    except ValueError:
        sys.exit(f"ERROR: {path} condition '{cond}': column '{key}'={raw!r} not numeric")


def compare(old_by_cond, new_by_cond, old_path, new_path):
    """MAP의 12조건을 순회하며 PASS/FAIL/MISSING 판정. (fails, missing) 리스트 반환."""
    fails = []
    missing = []
    for new_cond, (old_cond, metrics) in MAP.items():
        if new_cond not in new_by_cond:
            missing.append(new_cond)
            print(f"MISSING new condition '{new_cond}' (not found in {new_path})")
            continue
        if old_cond not in old_by_cond:
            sys.exit(f"ERROR: old condition '{old_cond}' not found in {old_path} (MAP 오타?)")
        new_row = new_by_cond[new_cond]
        old_row = old_by_cond[old_cond]
        n = new_row.get("n", "?")
        for m in metrics:
            med = to_float(new_row, f"median_{m}_s", new_path, new_cond)
            lo = to_float(old_row, f"{m}_s_ci_lo", old_path, old_cond)
            hi = to_float(old_row, f"{m}_s_ci_hi", old_path, old_cond)
            ok = lo <= med <= hi
            print(
                f"{'PASS' if ok else 'FAIL'} {new_cond}/{m}: new_med={med:.4f} "
                f"old_CI=[{lo:.4f},{hi:.4f}] (old_cond={old_cond} n={n})"
            )
            if not ok:
                fails.append((new_cond, m))
    return fails, missing


def build_selftest_new(old_by_cond, old_path):
    """--selftest: new_summary_csv 없이 파싱/MAP/비교 로직만 검증한다. old CSV의 실측 median을
    그대로 '새 condition' 이름으로 복제한 가짜 new_by_cond를 만든다 — new_med == old의 자기 median
    이므로 old 자신의 CI 안에 들어야 정상(로직/MAP이 맞다면 12/12 PASS가 나와야 하는 회귀 감지용
    자가 테스트). 실제 새 캠페인 결과 검증이 아니라 스크립트 로직 자체의 자가 테스트임에 유의."""
    fake = {}
    for new_cond, (old_cond, metrics) in MAP.items():
        old_row = old_by_cond.get(old_cond)
        if old_row is None:
            sys.exit(f"ERROR: selftest: old condition '{old_cond}' not found in {old_path}")
        row = {"condition": new_cond, "n": old_row.get("n", "?")}
        for m in metrics:
            row[f"median_{m}_s"] = old_row[f"median_{m}_s"]
        fake[new_cond] = row
    return fake


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("old_summary_csv", help="testbed/experiments/wsk_redesign/summary_by_condition.csv")
    ap.add_argument(
        "new_summary_csv", nargs="?",
        help="testbed/experiments/parity/summary_by_condition.csv (--selftest 시 생략 가능)",
    )
    ap.add_argument(
        "--selftest", action="store_true",
        help="new_summary_csv 없이 old 데이터를 복제해 MAP/파싱/비교 로직만 검증(캠페인 실행 전 자가 테스트)",
    )
    ap.add_argument(
        "--condition-prefix", default=None,
        help="새 summary condition의 캠페인 접두(hardening v2 §1). 생략하면 자동 감지 — 무접두 "
             "기존 summary는 접두 없이 그대로 동작한다.",
    )
    args = ap.parse_args()

    old_by_cond = load_by_condition(args.old_summary_csv)

    if args.selftest:
        new_by_cond = build_selftest_new(old_by_cond, args.old_summary_csv)
        new_path = f"<selftest copy of {args.old_summary_csv}>"
    else:
        if not args.new_summary_csv:
            sys.exit("ERROR: new_summary_csv required unless --selftest")
        new_by_cond = load_by_condition(args.new_summary_csv)
        new_path = args.new_summary_csv
        # 캠페인 접두 처리(hardening v2 §6): 새 run_id는 `<campaign>_...`이라 summary condition도
        # 접두를 단다(예: parity_dirty_cpubusy). MAP 키는 무접두(dirty_cpubusy)이므로 접두를 떼어
        # 맞춘다 — 명시 --condition-prefix가 우선, 없으면 자동 감지. 무접두 기존 summary는 "".
        prefix = args.condition_prefix
        if prefix is None:
            prefix = detect_condition_prefix(list(new_by_cond), MAP.keys())
            if prefix:
                print(f"(auto-detected condition prefix '{prefix}_' in {new_path} — stripping to match MAP)")
        new_by_cond = reprefix_new(new_by_cond, prefix)

    fails, missing = compare(old_by_cond, new_by_cond, args.old_summary_csv, new_path)

    n_checks = sum(len(metrics) for _cond, metrics in MAP.values())
    n_missing_checks = sum(len(MAP[c][1]) for c in missing)
    print(
        f"\n{'SELFTEST' if args.selftest else 'RESULT'}: "
        f"{n_checks - len(fails) - n_missing_checks}/{n_checks} PASS, "
        f"{len(fails)} FAIL, {n_missing_checks} MISSING (of {len(MAP)} conditions, {len(missing)} missing)"
    )
    if fails:
        print("FAIL 목록 (§8-3: 원인 규명 전 old 동결 금지):")
        for cond, m in fails:
            print(f"  - {cond}/{m}")
    sys.exit(1 if (fails or missing) else 0)


if __name__ == "__main__":
    main()
