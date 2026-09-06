#!/usr/bin/env python3
"""runner/summarize.py — all_runs.csv를 (exp_id, condition, dump_phase)별로 집계한다.

condition은 run_id에서 `_rep<NN>` 접미사를 떼서 만든다(이식원의 `_rep<NN>_cold|restore`
정규식은 old run_id 스킴 전용 — 아래 "old 대비 변경" 참조). 같은 condition·dump_phase의
반복(rep)들이 한 행으로 모여 median/percentile/bootstrap CI가 계산된다.

Usage:
  summarize.py [all_runs.csv]   # 기본: ../runs/all_runs.csv → summary CSV를 stdout으로

old 대비 변경 (Task 16, testbed_old/runner/summarize.py 이식):
  1. condition_of(): old 정규식 `_rep\\d+_(cold|restore)$`는 run_id가 `..._repNN_cold`/
     `..._repNN_restore`처럼 러너 종류까지 접미사로 달던 old 스킴 전용이었다. 새
     expand_campaign.py(Task 14)의 run_name()은 `rep{rep:02d}`를 항상 "마지막 토큰"으로만
     붙인다(cold: `dirty_rep01`, restore: `dirty_koff_rep01`) — old 정규식은 이 새 run_id에
     매치되지 않아(끝이 `_cold`/`_restore`가 아니므로) _repNN이 전혀 안 떨어져 나가고 rep마다
     별개 condition이 돼 버린다. 그래서 `_rep\\d+$`(끝의 _repNN만 제거)로 교체했다 — 브리프가
     명시한 "run_id에서 _repNN 제거"와 일치.
  2. restore_n 판정: old는 `runner == "once"`였다(old run_once.sh가 result.env에
     `runner=once`를 남겼다). 새 tree의 run_once.sh(Task 12)는 `result_set runner restore`로
     `runner=restore`를 남긴다(testbed/runner/run_once.sh:297) — 실측(`testbed/runs/dirty_koff_rep01
     /result.env`: `runner=restore`)으로 확인. old 문자열을 그대로 두면 restore_n이 항상 0으로
     나오는 조용한 회귀였을 것이라 `runner == "restore"`로 고쳤다.
  3. 그룹 키에 dump_phase 추가: (exp_id, condition, dump_phase) 3-tuple로 그룹핑한다.
     dump_at이 여러 값이면 이미 run_id 토큰(`d{phase}`)으로 condition이 갈리지만, 단일값이면
     토큰이 안 붙어(§4-C-2-4 "값이 변하는 축만 토큰화") run_id만으로는 구분되지 않는다 —
     result.env 자체의 dump_phase 필드(cold는 "na", restore는 CFG_DUMP_AT)로 명시적으로
     그룹을 나눠, run_id 토큰화 규칙에 조건 분리를 암묵적으로 의존하지 않게 한다. bootstrap
     median CI 로직(§6-17)은 완전히 무변경 이식.
"""

import csv
import random
import re
import sys
from pathlib import Path

# bootstrap median CI 설정. 재현성을 위해 고정 seed를 쓴다(같은 입력 → 같은 CI).
BOOTSTRAP_RESAMPLES = 2000
BOOTSTRAP_SEED = 12345


def to_num(v):
    if v is None:
        return None
    v = v.strip()
    if v in ("", "NA", "na"):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "NA"
    n = len(xs)
    mid = n // 2
    m = xs[mid] if n % 2 else (xs[mid - 1] + xs[mid]) / 2
    return f"{m:.6g}"


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "NA"
    if len(xs) == 1:
        return f"{xs[0]:.6g}"
    # linear interpolation between closest ranks
    rank = (p / 100.0) * (len(xs) - 1)
    lo = int(rank)
    frac = rank - lo
    hi = min(lo + 1, len(xs) - 1)
    return f"{xs[lo] + (xs[hi] - xs[lo]) * frac:.6g}"


def _median_num(xs):
    # 숫자 리스트(None 없음)의 median을 float로 반환 — bootstrap 내부용.
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2


def median_ci(values, resamples=BOOTSTRAP_RESAMPLES, seed=BOOTSTRAP_SEED):
    """percentile bootstrap으로 median의 95% CI (lo, hi)를 문자열로 반환.

    값을 복원추출(resample)해 매번 median을 구하고, 그 분포의 2.5/97.5 percentile을 취한다.
    표본이 2개 미만이면 CI를 정의할 수 없어 ('NA','NA'). seed 고정이라 재현 가능."""
    xs = [x for x in values if x is not None]
    if len(xs) < 2:
        return ("NA", "NA")
    rng = random.Random(seed)
    n = len(xs)
    meds = [_median_num([xs[rng.randrange(n)] for _ in range(n)]) for _ in range(resamples)]
    return (pct(meds, 2.5), pct(meds, 97.5))


def condition_of(run_id):
    # Task 16: old는 `_rep\d+_(cold|restore)$`(old run_id 스킴 전용). 새 run_id는
    # rep{NN}가 항상 마지막 토큰이라 끝의 _repNN만 떼면 된다 — 모듈 docstring "old 대비 변경" 1 참조.
    return re.sub(r"_rep\d+$", "", run_id)


# 렌즈3(실증): 서로 다른 설정의 런들이 같은 run_id(따라서 같은 exp_id/condition/dump_phase)로
# 뭉치는 경우가 있다 — 캠페인 YAML을 복사해 한 축에 값 하나씩만 넣고 따로 도는 "캠페인 분리
# 비교" 운영 실수다. run_id는 "값이 변하는 축만 토큰화"하므로(expand_campaign.py run_name()),
# 그 축을 캠페인 밖(별도 파일의 단일값)으로 바꾸면 run_id 문자열 자체는 그대로라 여기 그룹핑이
# 서로 다른 조건을 조용히 한 행(median)으로 섞는다. 이 컬럼 집합이 "조건을 정의"한다 — run_id
# 토큰화와 무관하게 실제로 같은 조건인지 독립적으로 재확인하는 안전망.
CONDITION_COLS = [
    "workload", "memory_max", "memory_swap_max", "cpu_bandwidth", "cpuset_cpus", "cpu_freq_khz",
    "storage_enabled", "storage_capacity", "storage_rbps", "storage_wbps",
    "storage_delay_enabled", "storage_delay_read_ms", "storage_delay_write_ms",
    "stress_enabled", "stress_vm_workers", "stress_vm_bytes", "stress_cpu_saturate",
    "kdat_cache", "cache_policy", "warmup_pings", "checkpoint_after_s",
]


def _norm_cond_val(v):
    # to_num()과 달리 문자열 그대로 비교한다(조건 컬럼은 workload명처럼 숫자가 아닌 값도 있다) —
    # NA 표기만 하나로 합쳐 "값이 실제로 없음"을 단일 값으로 취급한다.
    if v is None:
        return "NA"
    v = v.strip()
    return "NA" if v in ("", "NA", "na") else v


def wl_param_cond_cols(fieldnames):
    """입력 CSV에 존재하는 wl_param_* 컬럼(단 wl_param_port 제외)을 정렬해 반환한다
    (hardening v2 §4). port는 캠페인이 런마다 배정하는 값이라 조건이 아니다 — 조건 균일성
    검사에서 뺀다. 구 CSV(wl_param_* 열 자체가 없음)에선 빈 리스트 → 추가 검사 없이 기존 통과 유지."""
    return sorted(
        c for c in (fieldnames or [])
        if c.startswith("wl_param_") and c != "wl_param_port"
    )


def check_condition_uniform(groups, cond_cols=CONDITION_COLS):
    """(exp_id, condition, dump_phase) 그룹마다 cond_cols가 균일한지 검사한다.

    cond_cols는 기본 CONDITION_COLS이며, 입력 CSV에 wl_param_* 열이 있으면 main()이
    그것(wl_param_port 제외)을 덧붙여 넘긴다(hardening v2 §4) — 같은 조건인데 workload
    파라미터가 갈린 런이 한 median으로 섞이는 걸 추가로 막는 2차 방어선.
    그룹 안 전 행에서 같은 컬럼의 값이 갈리면(NA만 있는 경우는 값이 하나뿐이라 애초에 안 걸림 —
    "NA만 있는 컬럼은 검사 통과") 서로 다른 조건의 런이 뭉친 것 — stderr에 어떤 컬럼이 어떤
    값들로 갈렸는지 밝히고 exit 1. cold/restore 혼재는 dump_phase(cold="na")가 이미 그룹 키에
    들어 있어 애초에 다른 그룹이므로 영향 없음."""
    mismatches = []
    for key in sorted(groups):
        g = groups[key]
        if len(g) < 2:
            continue
        for col in cond_cols:
            values = {}
            for r in g:
                values.setdefault(_norm_cond_val(r.get(col)), []).append(r.get("run_id", "?"))
            if len(values) > 1:
                mismatches.append((key, col, values))
    if not mismatches:
        return
    for (exp, cond, dump_phase), col, values in mismatches:
        detail = ", ".join(f"{v!r}<-{sorted(rids)}" for v, rids in sorted(values.items()))
        print(
            f"ERROR: condition mismatch in group (exp_id={exp!r}, condition={cond!r}, "
            f"dump_phase={dump_phase!r}): column '{col}' has multiple values: {detail}",
            file=sys.stderr,
        )
    print(
        "FATAL: 같은 (exp_id, condition, dump_phase) 그룹 안에 서로 다른 조건의 런이 섞여 있어 "
        "median이 오염됩니다.\n"
        "축 비교는 반드시 한 캠페인 안에서 다중값 리스트로 선언하라"
        "(캠페인 복사+단일값 방식은 run_id가 겹친다).",
        file=sys.stderr,
    )
    sys.exit(1)


SUMMARY_COLS = [
    "exp_id", "condition", "dump_phase", "n", "cold_n", "restore_n", "pass_count", "fail_count", "fail_rate",
    "median_cold_response_s", "p95_cold_response_s",
    "median_restore_response_s", "p95_restore_response_s",
    "median_cold_ready_s", "median_restore_time_s", "median_dump_time_s",
    "median_image_size_bytes", "median_memory_peak_bytes",
    "median_kdat_probing_s", "median_restore_work_s", "median_kdat_ratio",
    "oom_count", "oom_kill_count",
    # appended columns: bootstrap median 95% CI (lo/hi) for the key metrics
    "cold_response_s_ci_lo", "cold_response_s_ci_hi",
    "restore_response_s_ci_lo", "restore_response_s_ci_hi",
    "restore_time_s_ci_lo", "restore_time_s_ci_hi",
    "image_size_bytes_ci_lo", "image_size_bytes_ci_hi",
]


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "runs" / "all_runs.csv"
    reader = csv.DictReader(open(src))
    rows = list(reader)
    if not rows:
        print(f"no rows in {src}", file=sys.stderr)
        sys.exit(1)

    groups = {}
    for r in rows:
        key = (r.get("exp_id", "NA"), condition_of(r.get("run_id", "")), r.get("dump_phase", "NA"))
        groups.setdefault(key, []).append(r)

    # hardening v2 §4: CSV에 존재하는 wl_param_*(port 제외) 열을 조건 균일성 가드에 동적 추가.
    # 구 CSV(그 열이 없음)에선 빈 리스트라 CONDITION_COLS만 검사 — 기존 통과가 그대로 유지된다.
    cond_cols = CONDITION_COLS + wl_param_cond_cols(reader.fieldnames)
    check_condition_uniform(groups, cond_cols)   # 렌즈3: 조건 병합 가드 — 통과 전엔 아무 것도 stdout에 안 씀

    def col(g, name):
        return [to_num(r.get(name)) for r in g]

    def count_pos(g, name):
        return sum(1 for r in g if (to_num(r.get(name)) or 0) > 0)

    w = csv.DictWriter(sys.stdout, fieldnames=SUMMARY_COLS)
    w.writeheader()
    for (exp, cond, dump_phase) in sorted(groups):
        g = groups[(exp, cond, dump_phase)]
        n = len(g)
        cold_n = sum(1 for r in g if r.get("runner") == "cold")
        restore_n = sum(1 for r in g if r.get("runner") == "restore")
        passes = sum(1 for r in g if r.get("result") == "PASS")
        fails = sum(1 for r in g if r.get("result") == "FAIL")
        cold_resp_ci = median_ci(col(g, "cold_response_s"))
        restore_resp_ci = median_ci(col(g, "restore_response_s"))
        restore_time_ci = median_ci(col(g, "restore_time_s"))
        image_size_ci = median_ci(col(g, "image_size_bytes"))
        w.writerow({
            "exp_id": exp, "condition": cond, "dump_phase": dump_phase, "n": n,
            "cold_n": cold_n, "restore_n": restore_n,
            "pass_count": passes, "fail_count": fails,
            "fail_rate": f"{fails / n:.3f}" if n else "NA",
            "median_cold_response_s": median(col(g, "cold_response_s")),
            "p95_cold_response_s": pct(col(g, "cold_response_s"), 95),
            "median_restore_response_s": median(col(g, "restore_response_s")),
            "p95_restore_response_s": pct(col(g, "restore_response_s"), 95),
            "median_cold_ready_s": median(col(g, "cold_ready_s")),
            "median_restore_time_s": median(col(g, "restore_time_s")),
            "median_dump_time_s": median(col(g, "dump_time_s")),
            "median_image_size_bytes": median(col(g, "image_size_bytes")),
            "median_memory_peak_bytes": median(col(g, "memory_peak_bytes")),
            "median_kdat_probing_s": median(col(g, "kdat_probing_s")),
            "median_restore_work_s": median(col(g, "restore_work_s")),
            "median_kdat_ratio": median(col(g, "kdat_ratio")),
            "oom_count": count_pos(g, "oom"),
            "oom_kill_count": count_pos(g, "oom_kill"),
            "cold_response_s_ci_lo": cold_resp_ci[0], "cold_response_s_ci_hi": cold_resp_ci[1],
            "restore_response_s_ci_lo": restore_resp_ci[0], "restore_response_s_ci_hi": restore_resp_ci[1],
            "restore_time_s_ci_lo": restore_time_ci[0], "restore_time_s_ci_hi": restore_time_ci[1],
            "image_size_bytes_ci_lo": image_size_ci[0], "image_size_bytes_ci_hi": image_size_ci[1],
        })
    print(f"summarized {len(groups)} condition(s) from {len(rows)} run(s) in {src}", file=sys.stderr)


if __name__ == "__main__":
    main()
