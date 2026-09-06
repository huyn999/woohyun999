#!/usr/bin/env bash
# failprobe/timing_sweep.sh — cold vs restore 시간 비교 (RQ2)
#
# compat 스윕(strict)에서 ready 셀을 통과한 워크로드만 골라, 기존 러너
# (run_cold_start.sh / run_once.sh — cgroup/stress/storage 제약 전부 적용)로
# cold_response_s vs restore_response_s 를 반복 측정한다.
#
# compat_sweep과의 분업: compat = "얼릴 수 있는가"(제약 없이 빠르게),
# timing = "얼리는 게 빠른가"(전체 제약 아래 정식 측정).
#
# Usage:
#   sudo failprobe/timing_sweep.sh                 # compat 통과 fp_* 전부 × REPS(기본 3)
#   sudo failprobe/timing_sweep.sh 'fp_c_*'        # glob 제한
#   REPS=5 sudo failprobe/timing_sweep.sh
#   SKIP_FILTER=1 sudo ...                         # compat CSV 필터 생략(전부 시도)
#   RESUME=1 sudo ...                              # timing.csv 기존 행 skip
#
# 필수 전제:
#   - bootstrap 완료 (doctor PASS 상태의 scenario.yaml — cpufreq 등 이 머신에 맞게 조정된 것)
#   - 워크로드 빌드 완료
#   - 측정 정합성: phase_gap_ms는 여기서 0으로 강제 오버라이드된다 (gap은 compat 전용)
#
# 산출물: failprobe/results/timing.csv, timing_summary.csv
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
TESTBED="$ROOT/testbed"
[[ $EUID -eq 0 ]] || { echo "ERROR: root 필요" >&2; exit 1; }
[[ -x "$TESTBED/runner/run_once.sh" ]] || { echo "ERROR: runner 없음" >&2; exit 1; }

GLOB="${1:-fp_*}"
REPS="${REPS:-3}"
COMPAT_CSV="${COMPAT_CSV:-$DIR/results/compat_strict.csv}"
CFG_DIR="$DIR/timing/configs"
RESULTS="$DIR/results"
CSV="$RESULTS/timing.csv"
RUN_TIMEOUT="${RUN_TIMEOUT:-300}"
mkdir -p "$CFG_DIR" "$RESULTS"

if [[ "${RESUME:-0}" != "1" || ! -f "$CSV" ]]; then
	echo "workload,rep,path,result,response_s,dump_time_s,image_size_bytes,run_id" > "$CSV"
fi

# 대상 선정: glob ∩ (compat ready 셀 dump=0·restore=0 통과)
WLS=()
for d in "$TESTBED/workloads/"$GLOB/; do
	wl="$(basename "$d")"
	[[ -f "$d/workload.c" ]] || continue
	if [[ "${SKIP_FILTER:-0}" != "1" ]]; then
		if [[ ! -f "$COMPAT_CSV" ]]; then
			echo "ERROR: $COMPAT_CSV 없음 — compat 스윕 먼저 (또는 SKIP_FILTER=1)" >&2; exit 1
		fi
		grep -q "^${wl},ready,strict,1,0,0," "$COMPAT_CSV" || { echo "[skip] $wl: compat ready 미통과"; continue; }
	fi
	WLS+=("$wl")
done
echo "[timing] workloads=${#WLS[@]} reps=$REPS → cold+restore = $(( ${#WLS[@]} * REPS * 2 )) runs"

gen_cfg() { # $1=wl → config yaml 경로 출력
	local wl="$1" out="$CFG_DIR/$1.yaml"
	python3 - "$TESTBED/scenario.yaml" "$wl" "$out" <<-'EOF'
	import sys, yaml
	base, wl, out = sys.argv[1:4]
	cfg = yaml.safe_load(open(base))
	cfg["workload"] = {"name": wl,
	                   "params": {"port": 18080, "phase_gap_ms": 0}}  # gap 0 = 시간 오염 방지
	cfg["dump_at"] = "served_first"   # warm dump (old 의미론) — 모든 fp manifest에 존재
	yaml.safe_dump(cfg, open(out, "w"), allow_unicode=True, sort_keys=False)
	EOF
	echo "$out"
}

get_kv() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2; }

n=0
for wl in "${WLS[@]}"; do
	cfg="$(gen_cfg "$wl")"
	for rep in $(seq 1 "$REPS"); do
		for path in cold restore; do
			n=$((n+1))
			rid="t_${wl}_${path:0:1}${rep}"
			if [[ "${RESUME:-0}" == "1" ]] && grep -q ",${rid}$" "$CSV"; then continue; fi
			if [[ "$path" == "cold" ]]; then
				timeout "$RUN_TIMEOUT" "$TESTBED/runner/run_cold_start.sh" --run-id "$rid" --config "$cfg" >/dev/null 2>&1
			else
				timeout "$RUN_TIMEOUT" "$TESTBED/runner/run_once.sh" --run-id "$rid" --config "$cfg" >/dev/null 2>&1
			fi
			env_f="$TESTBED/runs/$rid/result.env"
			res="$(get_kv "$env_f" result)"; res="${res:-TIMEOUT_OR_CRASH}"
			if [[ "$path" == "cold" ]]; then resp="$(get_kv "$env_f" cold_response_s)"
			else resp="$(get_kv "$env_f" restore_response_s)"; fi
			dt="$(get_kv "$env_f" dump_time_s)"; sz="$(get_kv "$env_f" image_size_bytes)"
			echo "$wl,$rep,$path,$res,${resp:-na},${dt:-na},${sz:-na},$rid" >> "$CSV"
			echo "[$n] $wl $path rep$rep → $res ${resp:-na}s"
		done
	done
done

# 요약: 워크로드별 median cold vs restore, 승자, 배율
python3 - "$CSV" "$RESULTS/timing_summary.csv" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
by = {}
for r in rows:
    if r["result"] != "PASS" or r["response_s"] in ("na", ""):
        continue
    by.setdefault(r["workload"], {"cold": [], "restore": []})[r["path"]].append(float(r["response_s"]))
out = csv.writer(open(sys.argv[2], "w"))
out.writerow(["workload", "n_cold", "n_restore", "cold_med_s", "restore_med_s", "winner", "ratio_restore_over_cold"])
print(f"\n{'workload':38} {'cold_med':>9} {'rest_med':>9}  winner")
for wl in sorted(by):
    c, rs = by[wl]["cold"], by[wl]["restore"]
    if not c or not rs:
        out.writerow([wl, len(c), len(rs), "", "", "insufficient", ""]); continue
    cm, rm = statistics.median(c), statistics.median(rs)
    win = "restore" if rm < cm else "cold"
    out.writerow([wl, len(c), len(rs), f"{cm:.4f}", f"{rm:.4f}", win, f"{rm/cm:.2f}"])
    print(f"{wl:38} {cm:9.4f} {rm:9.4f}  {win} (x{rm/cm:.2f})")
print(f"\nsaved: {sys.argv[2]}")
EOF
echo "[timing] DONE → $CSV"
