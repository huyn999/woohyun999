#!/usr/bin/env python3
"""runner/compare_cold_restore.py — main all_runs.csv에서 cold/restore를 짝지어 delta를 낸다
(fairness hardening v2 §5).

cold 런과 restore 런을 "같은 환경·같은 반복(repeat)"으로 묶어 first-response 시간의 차이
(delta = restore_response − cold_response)를 조건별로 요약한다. delta<0이면 restore가 더 빠르고
(=restore 우세), delta>0이면 cold가 더 빠르다(=cold 우세).

Usage:
  compare_cold_restore.py <all_runs.csv> <out_dir>

  <all_runs.csv> : run_campaign.sh finalize()가 만든 main CSV(calibration 미포함). collect.py의
                   union-of-keys 스키마(runner/collect.py) — runner/cold_response_s/restore_response_s/
                   repeat_id/kdat_cache/dump_phase 및 조건 컬럼들.
  <out_dir>      : paired_runs.csv + comparison_by_condition.csv 를 쓴다.

페어링 키(§5): [workload, 환경 조건 컬럼(summarize.CONDITION_COLS와 동일 집합, kdat_cache 제외),
wl_param_*(port 제외), repeat_id]. kdat_cache/dump_phase/port는 키에서 빼고 라벨로만 보존한다
(같은 cold 하나가 kdat on/off 두 restore와 각각 짝지어진다). repeat_id는 페어링의 앵커라 양쪽
모두 값이 있고 같아야 한다 — repeat_id가 없는 cold(예: calibration 런)는 페어링 대상에서 제외한다.
그 밖의 조건 컬럼은 한쪽이 NA면(예: cold엔 warmup_pings/checkpoint_after_s가 구조적으로 없다)
그 컬럼으론 배제하지 않는다(NA=와일드카드, §5 "결측 처리"). wl_param_* 열이 없는 구 CSV는
그 부분이 빠진 채 기존 메타데이터만으로 페어링된다(fallback).

median/bootstrap-CI는 runner/summarize.py의 median_ci(고정 seed·resamples)를 그대로 import해
재사용한다 — 같은 계산은 한 곳(동일 함수)에서만(expand_campaign.py가 config_to_env.py를,
compare_parity.py가 summarize.py를 재사용하는 것과 같은 원칙).
"""
import argparse
import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summarize as sm  # noqa: E402  (경로 삽입 후 import) — median_ci/CONDITION_COLS/condition_of 재사용

NA_TOKENS = ("", "NA", "na")


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def norm(v):
    """조건/키 값 정규화: None/공백/NA 표기를 단일 None으로 — 나머진 strip한 문자열."""
    if v is None:
        return None
    v = v.strip()
    return None if v in NA_TOKENS else v


def key_columns(fieldnames):
    """페어링 키에 쓸 (환경 컬럼, wl_param 컬럼) 목록을 정한다(§5).

    환경 컬럼: summarize.CONDITION_COLS에서 kdat_cache만 뺀 것(workload 포함, 그 외 라벨성
    컬럼 dump_phase/port는 애초에 CONDITION_COLS에 없다). wl_param 컬럼: CSV에 실재하는
    wl_param_*(단 wl_param_port 제외) — 없으면(구 CSV) 빈 리스트로 자연 fallback."""
    env = [c for c in sm.CONDITION_COLS if c != "kdat_cache"]
    wl = sorted(
        c for c in (fieldnames or [])
        if c.startswith("wl_param_") and c != "wl_param_port"
    )
    return env, wl


def compatible(cold, restore, env_cols, wl_cols):
    """cold와 restore가 같은 조건·같은 반복인가. repeat_id는 앵커(양쪽 값 존재+동일 필수),
    그 밖의 키 컬럼은 한쪽이 NA면 와일드카드(§5 결측 처리)."""
    cr, rr = norm(cold.get("repeat_id")), norm(restore.get("repeat_id"))
    if cr is None or rr is None or cr != rr:
        return False
    for c in env_cols + wl_cols:
        a, b = norm(cold.get(c)), norm(restore.get(c))
        if a is not None and b is not None and a != b:
            return False
    return True


def exact_key(row, env_cols, wl_cols):
    """중복 cold 탐지용 정규화 키(repeat_id 포함) — 두 cold가 이게 같으면 '같은 키 2개'(§5 die)."""
    return tuple(norm(row.get(c)) for c in env_cols + wl_cols + ["repeat_id"])


PAIRED_COLS = [
    "cold_run_id", "restore_run_id", "cold_response_s", "restore_response_s",
    "delta_s", "kdat_cache", "dump_phase", "repeat_id", "condition_key",
]
COMPARISON_COLS = [
    "cold_condition", "condition_key", "kdat_cache", "dump_phase", "n_pairs", "n_delta",
    "n_missing_delta", "median_delta_s", "delta_ci_lo", "delta_ci_hi", "winner",
]


def build_pairs(rows, env_cols, wl_cols):
    """restore 각각에 대응하는 cold를 찾아 (cold_row, restore_row) 목록을 만든다.

    반환: (pairs, missing_run_ids). cold 중복(같은 exact_key 2개)은 die. restore가 매칭하는
    cold가 0개면 missing(스킵+집계), 2개 이상이면 die(모호)."""
    colds = [r for r in rows if r.get("runner") == "cold"]
    restores = [r for r in rows if r.get("runner") == "restore"]

    # repeat_id 없는 cold(예: calibration)는 앵커가 없어 페어링 대상이 아니다 — 제외한다.
    eligible = [c for c in colds if norm(c.get("repeat_id")) is not None]

    # 중복 cold 탐지(§5): eligible cold를 exact_key로 묶어 2개 이상이면 die.
    by_key = {}
    for c in eligible:
        by_key.setdefault(exact_key(c, env_cols, wl_cols), []).append(c)
    dupes = {k: v for k, v in by_key.items() if len(v) > 1}
    if dupes:
        detail = "; ".join(
            f"{[c['run_id'] for c in v]}" for v in dupes.values()
        )
        die(f"duplicate cold(같은 페어링 키 2개 이상): {detail} — 같은 조건·같은 repeat의 cold가 "
            "둘 이상이라 어느 것과 짝지을지 모호하다(캠페인 중복 발주/수동 재실행 의심)")

    pairs = []
    missing = []
    for r in restores:
        matched = [c for c in eligible if compatible(c, r, env_cols, wl_cols)]
        if not matched:
            missing.append(r["run_id"])
            continue
        if len(matched) > 1:
            die(f"restore '{r['run_id']}'가 cold {len(matched)}개와 매칭(모호): "
                f"{[c['run_id'] for c in matched]}")
        pairs.append((matched[0], r))

    # 결정성: (cold_run_id, kdat_cache, dump_phase)로 정렬.
    pairs.sort(key=lambda cr: (cr[0].get("run_id", ""),
                               norm(cr[1].get("kdat_cache")) or "",
                               norm(cr[1].get("dump_phase")) or ""))
    return pairs, missing


def fmt(x):
    return "NA" if x is None else f"{x:.6g}"


def pair_condition_signature(cold, restore, env_cols, wl_cols):
    """comparison grouping용 실제 조건 signature.

    페어링 compatible()와 같은 컬럼 집합을 쓰되 repeat_id는 빼고, 한쪽이 NA이면 반대쪽 값을
    채운다. 이렇게 해야 구 CSV(cold에 warmup_pings/checkpoint_after_s가 NA)도 restore의 조건값으로
    올바르게 그룹이 갈리고, run_id 토큰에 의존하지 않는다."""
    sig = []
    for c in env_cols + wl_cols:
        v = norm(cold.get(c))
        if v is None:
            v = norm(restore.get(c))
        sig.append((c, v or "NA"))
    return tuple(sig)


def condition_key(sig):
    return "|".join(f"{k}={v}" for k, v in sig)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("all_runs_csv", type=Path)
    ap.add_argument("out_dir", type=Path)
    args = ap.parse_args()

    if not args.all_runs_csv.is_file():
        die(f"all_runs.csv not found: {args.all_runs_csv}")
    reader = csv.DictReader(open(args.all_runs_csv))
    rows = list(reader)
    if not rows:
        die(f"no rows in {args.all_runs_csv}")

    env_cols, wl_cols = key_columns(reader.fieldnames)
    pairs, missing = build_pairs(rows, env_cols, wl_cols)

    if missing:
        print(f"WARN: {len(missing)} restore run(s) had no matching cold (skipped): "
              f"{', '.join(sorted(missing))}", file=sys.stderr)
    if not pairs:
        die("no cold/restore pairs produced — comparison would be empty "
            "(all restore rows missing cold, or CSV has no comparable cold/restore rows)")

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- paired_runs.csv ---
    paired_path = out_dir / "paired_runs.csv"
    # 조건별 delta 모으기(comparison용):
    # (실제 조건 signature, cold_condition label, kdat_cache, dump_phase) -> [delta_or_None, ...]
    groups = {}
    with open(paired_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=PAIRED_COLS)
        w.writeheader()
        for cold, restore in pairs:
            cresp = sm.to_num(cold.get("cold_response_s"))
            rresp = sm.to_num(restore.get("restore_response_s"))
            delta = (rresp - cresp) if (cresp is not None and rresp is not None) else None
            kdat = norm(restore.get("kdat_cache")) or "NA"
            dphase = norm(restore.get("dump_phase")) or "NA"
            rep = norm(restore.get("repeat_id")) or "NA"
            sig = pair_condition_signature(cold, restore, env_cols, wl_cols)
            sig_key = condition_key(sig)
            w.writerow({
                "cold_run_id": cold.get("run_id"),
                "restore_run_id": restore.get("run_id"),
                "cold_response_s": fmt(cresp),
                "restore_response_s": fmt(rresp),
                "delta_s": fmt(delta),
                "kdat_cache": kdat,
                "dump_phase": dphase,
                "repeat_id": rep,
                "condition_key": sig_key,
            })
            cond = sm.condition_of(cold.get("run_id", ""))
            groups.setdefault((sig, cond, kdat, dphase), []).append(delta)

    # --- comparison_by_condition.csv ---
    comparison_path = out_dir / "comparison_by_condition.csv"
    with open(comparison_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COMPARISON_COLS)
        w.writeheader()
        for (sig, cond, kdat, dphase) in sorted(groups, key=lambda x: (x[1], condition_key(x[0]), x[2], x[3])):
            deltas = groups[(sig, cond, kdat, dphase)]
            nums = [d for d in deltas if d is not None]
            n_pairs = len(deltas)
            n_delta = len(nums)
            n_missing = n_pairs - n_delta
            if nums:
                med = sm._median_num(nums)
                median_delta = f"{med:.6g}"
                winner = "restore" if med < 0 else ("cold" if med > 0 else "tie")
            else:
                median_delta = "NA"
                winner = "NA"
            ci_lo, ci_hi = sm.median_ci(deltas)  # median_ci가 None을 걸러낸다
            w.writerow({
                "cold_condition": cond, "condition_key": condition_key(sig),
                "kdat_cache": kdat, "dump_phase": dphase,
                "n_pairs": n_pairs, "n_delta": n_delta, "n_missing_delta": n_missing,
                "median_delta_s": median_delta, "delta_ci_lo": ci_lo, "delta_ci_hi": ci_hi,
                "winner": winner,
            })

    print(f"WROTE: {paired_path} ({len(pairs)} pairs), {comparison_path} "
          f"({len(groups)} condition group(s)); missing_cold={len(missing)}", file=sys.stderr)


if __name__ == "__main__":
    main()
