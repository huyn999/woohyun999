#!/usr/bin/env python3
"""runner/collect.py — runs/*/result.env를 모아 분석용 CSV로 출력.

각 run은 자기 디렉토리에 result.env(flat key=value)를 남긴다(PASS/FAIL 모두).
이 스크립트는 그것들을 스캔해 union-of-keys CSV를 만든다. run_cold_start(cold)와
run_once(restore)가 섞여 있어도 OK — 한쪽에만 있는 컬럼은 다른 쪽 row에선 NA가 된다.
새 워크로드가 심는 wl_*나 dump_phase 같은 신규 키도 PREFERRED에 없어도 union으로
자동 수집돼 알파벳순으로 뒤에 붙는다 — 이 스크립트를 고치지 않고도 새 컬럼이 열린다
(설계 스펙 §4 "플러그인" 목표: 워크로드/필드 추가가 collect.py 변경을 요구하지 않아야 함).

이식: testbed_old/runner/collect.py (동일 union-of-keys 로직, 무변경).

확장(Task 16): base_dir 하나만 스캔하던 old CLI에, run_id manifest(선택 인자)를 추가했다.
run_campaign.sh의 RUNS_ROOT는 캠페인 간 공유 디렉터리(Task 15에서 실측 확인 — 같은
run_id를 다른 캠페인이 재사용하면 이전 result.env를 덮어쓴다)라, base_dir 전체를 그냥
넘기면 이 캠페인 것이 아닌 run까지 CSV에 섞인다. manifest를 주면 그 run_id들만(즉
"이 캠페인이 실제로 발주한 run들"만) 골라 담는다 — base_dir 하나만 주는 old 사용법은
그대로 동작한다(하위 호환, 인자 추가는 CLI를 깨지 않는다).

마구잡이로 돌린 뒤:
  runner/collect.py > runs/results.csv                    # 모든 run을 CSV로
  runner/collect.py runs > out.csv                         # runs 경로 지정
  runner/collect.py runs run_ids.txt > out.csv             # run_ids.txt에 열거된 run만
그다음 pandas/엑셀로 바로 분석.
"""

import csv
import sys
from pathlib import Path


def parse_env(path: Path) -> dict:
    out = {}
    skipped = 0
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            skipped += 1
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    if skipped:
        print(f"WARN: {path}: skipped {skipped} line(s) without '='", file=sys.stderr)
    return out


# 사람이 보기 좋은 컬럼 순서. 여기 없는 키는 뒤에 알파벳순으로 붙는다.
PREFERRED = [
    "exp_id", "repeat_id", "run_id", "runner", "timestamp", "result", "fail_reason",
    "memory_max", "memory_swap_max", "cpu_bandwidth", "cpuset_cpus",
    "storage_enabled", "storage_rbps", "storage_wbps",
    "storage_delay_enabled", "storage_delay_read_ms", "storage_delay_write_ms",
    "stress_enabled", "stress_vm_workers", "stress_vm_bytes", "stress_cpu_saturate",
    "workload", "target_bytes", "dynamic_mode", "dynamic_dirty_bytes",
    "dynamic_interval_ms", "dynamic_init_work_ms", "compute_iters", "compute_ms",
    "workload_port", "kdat_cache", "checkpoint_after_s", "restore_gap_s",
    # main metrics (command -> first response); compare cold_response_s vs restore_response_s
    "cold_response_s", "restore_response_s",
    # secondary internal-ready metrics and decomposition
    "cold_ready_s", "restore_time_s", "dump_time_s",
    "kdat_probing_s", "restore_work_s", "launch_overhead_s", "kdat_ratio",
    "cold_launch_s", "task_visible_s",
    "image_size_bytes",
    "memory_current_before", "memory_current_after_stress", "memory_peak_bytes",
    "oom", "oom_kill", "generic_recovery",
    "storage_capacity", "kernel_version",
    "criu_dump_log", "criu_restore_log", "target_log",
    # appended columns (schema extension; 기존 컬럼 순서는 위에서 그대로 유지된다)
    # cache control + probe instrumentation
    "cache_policy", "drop_caches_rc", "drop_caches_ts",
    "probe_interval_ms", "probe_timeout_s", "probe_attempts", "first_success_attempt",
    "restore_peak_current",
    # NOTE: dump_phase, wl_* (워크로드별 지표), 시점별 memstat_<label>_* / meminfo_<label>_*
    #   키는 여기 나열하지 않아도 union-of-keys로 자동 수집되어 알파벳순으로 뒤에 붙는다
    #   (append-only 유지 — 새 워크로드/필드 추가가 이 파일 수정을 요구하지 않는다).
]


def collect_envs(base: Path, manifest: Path | None) -> list[Path]:
    """이 base 아래에서 읽을 result.env 경로 목록을 정한다.

    manifest가 없으면(old 그대로) base/*/result.env 전부. manifest가 있으면 그 안에 열거된
    run_id들의 base/<run_id>/result.env만(캠페인 스코프 필터 — 위 모듈 docstring 참조).
    """
    if manifest is None:
        return sorted(base.glob("*/result.env"))
    run_ids = [ln.strip() for ln in manifest.read_text().splitlines() if ln.strip()]
    return [base / rid / "result.env" for rid in run_ids]


def main() -> None:
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "runs"
    manifest = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    rows = []
    for env in collect_envs(base, manifest):
        if not env.exists():
            print(f"WARN: skip {env}: no result.env (run may have failed before it was written)", file=sys.stderr)
            continue
        try:
            rows.append(parse_env(env))
        except OSError as exc:
            print(f"WARN: skip {env}: {exc}", file=sys.stderr)
    if not rows:
        print(f"no result.env found under {base}" + (f" (manifest={manifest})" if manifest else ""), file=sys.stderr)
        sys.exit(1)

    allkeys = set()
    for row in rows:
        allkeys.update(row)
    cols = [c for c in PREFERRED if c in allkeys] + sorted(allkeys - set(PREFERRED))

    # 미측정/해당없음 값은 빈칸 대신 NA로 통일한다(runner가 쓰는 'na'도 'NA'로 정규화).
    # 한쪽 runner에만 있는 컬럼(cold의 restore_*, restore의 cold_*)도 반대편 row에선 NA가 된다.
    def cell(v: str) -> str:
        return "NA" if v in ("", "na") else v

    writer = csv.DictWriter(sys.stdout, fieldnames=cols, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow({c: cell(row.get(c, "")) for c in cols})
    print(f"collected {len(rows)} run(s) from {base}", file=sys.stderr)


if __name__ == "__main__":
    main()
