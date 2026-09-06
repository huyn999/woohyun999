#!/usr/bin/env bash
# env/hardware/cpufreq.sh — 테스트 코어를 고정 CPU 주파수로 clamp (느린 임베디드 CPU 클럭 모사)
#
# 모사 대상: 디바이스의 절대 CPU 클럭(예: LG webOS TV ≈ 1.235GHz).
#   cgroup cpu.max/cpuset은 "CPU 시간 점유율"과 "코어 수"만 제한할 뿐 코어 클럭을 못 낮춘다.
#   → 짧은 버스트(예: CRIU kerndat probing)는 quota 안에서 호스트 풀스피드로 돌아 디바이스를
#     못 흉내낸다(host powersave governor에선 0.8~5.5GHz로 출렁이기까지 한다).
#   여기서는 DVFS(cpufreq)의 scaling_min/max_freq를 목표 주파수 한 점으로 모아 박아, 그 코어를
#   해당 클럭에 고정한다. 그러면 절대 클럭이 모사되고 주파수 변동(probing 노이즈)도 사라진다.
#
# ⚠️ 다른 hardware 모듈과 결정적 차이 — 이건 cgroup이 아니라 *호스트 전역* 상태다:
#   - cgroup destroy로 자동 정리되지 않는다. 그래서 apply가 원래값을 RUN_DIR/cpufreq.orig에 저장하고
#     teardown이 restore로 반드시 되돌린다(실패·크래시에도 run_once의 cleanup trap이 보장).
#   - 공유 호스트에선 cpuset 코어에 다른 테넌트 작업이 스케줄되면 그 작업도 같이 느려진다.
#     전용 기기에서 쓰는 게 정석이며, 그래서 기본은 비활성(주파수 미지정 시 no-op)이고
#     cpuset_cpus 없이는 거부한다(전역 clamp 금지).
#
# Action: apply | restore | verify
#
# Usage:
#   sudo cpufreq.sh apply   <run_id> <freq_khz> <cpuset_cpus>
#   sudo cpufreq.sh restore <run_id>
#   sudo cpufreq.sh verify  <run_id> <freq_khz> <cpuset_cpus>
#
# 예: freq_khz=1235000 → 1.235GHz, cpuset_cpus=0-3 → cpu0~3을 1.235GHz에 고정.

set -uo pipefail

CPU_BASE="/sys/devices/system/cpu"

ACTION="${1:-}"
RUN_ID="${2:-}"
if [[ -z "$ACTION" || -z "$RUN_ID" ]]; then
	echo "usage: $0 {apply <run_id> <freq_khz> <cpuset_cpus> | restore <run_id> | verify <run_id> <freq_khz> <cpuset_cpus>}" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$PROJECT_ROOT/runs/$RUN_ID"
ORIG_FILE="$RUN_DIR/cpufreq.orig"

require_root() { [[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }; }

# cpulist(0-3, 0,2-3)를 코어 번호 공백 리스트로 펼친다.
# (cpu.sh의 normalize_cpulist와 같은 idiom — caller가 이 모듈뿐이라 공유 util로 빼지 않고 inline.)
expand_cpulist() {
	awk -v list="$1" 'BEGIN {
		if (list !~ /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) exit 2
		n = split(list, parts, ",")
		for (i = 1; i <= n; i++) {
			split(parts[i], r, "-"); s = r[1] + 0; e = (r[2] == "" ? s : r[2] + 0)
			if (e < s) exit 2
			for (c = s; c <= e; c++) seen[c] = 1
		}
		first = 1
		for (c = 0; c < 4096; c++) if (c in seen) { if (!first) printf " "; printf "%d", c; first = 0 }
		printf "\n"
	}' || { echo "ERROR: invalid cpuset_cpus (got: '$1')" >&2; exit 2; }
}

cpufreq_dir() { echo "$CPU_BASE/cpu$1/cpufreq"; }

# ============================================================== APPLY
do_apply() {
	local freq_khz="$1" cpuset="$2"
	require_root

	# 주파수 미지정/none/max면 clamp 안 함 (이 축 비활성).
	if [[ -z "$freq_khz" || "$freq_khz" == "none" || "$freq_khz" == "max" ]]; then
		echo "[hardware/cpufreq] disabled (no fixed frequency)"
		return 0
	fi
	[[ "$freq_khz" =~ ^[0-9]+$ ]] || { echo "ERROR: freq_khz must be an integer in kHz (got: '$freq_khz')" >&2; exit 2; }
	# 호스트 전역 clamp 방지 — 반드시 cpuset로 코어를 한정한다.
	[[ -n "$cpuset" ]] || { echo "ERROR: cpu.frequency_khz는 cpuset_cpus가 있어야 한다(호스트 전역 clamp 금지)" >&2; exit 2; }

	local hw_min hw_max
	hw_min="$(cat "$(cpufreq_dir 0)/cpuinfo_min_freq" 2>/dev/null || echo 0)"
	hw_max="$(cat "$(cpufreq_dir 0)/cpuinfo_max_freq" 2>/dev/null || echo 0)"
	[[ "$hw_min" != "0" ]] || { echo "ERROR: cpufreq sysfs 없음 — 이 호스트는 DVFS 제어 불가" >&2; exit 1; }
	if (( freq_khz < hw_min || freq_khz > hw_max )); then
		echo "ERROR: freq_khz=$freq_khz 가 hardware 범위 [$hw_min, $hw_max] kHz 밖이다" >&2; exit 2
	fi

	local cores; cores="$(expand_cpulist "$cpuset")"
	mkdir -p "$RUN_DIR"
	: > "$ORIG_FILE"

	local c d cur_min cur_max gov
	for c in $cores; do
		d="$(cpufreq_dir "$c")"
		[[ -w "$d/scaling_max_freq" && -w "$d/scaling_min_freq" ]] \
			|| { echo "ERROR: $d/scaling_{min,max}_freq 쓰기 불가 (privileged 호스트 접근 필요)" >&2; exit 1; }
		cur_min="$(cat "$d/scaling_min_freq")"; cur_max="$(cat "$d/scaling_max_freq")"
		gov="$(cat "$d/scaling_governor" 2>/dev/null || echo unknown)"
		# 원래값을 set 전에 먼저 기록 — 이후 어디서 실패해도 teardown restore가 되돌릴 수 있게.
		echo "$c $gov $cur_min $cur_max" >> "$ORIG_FILE"
		# min>max 과도 상태를 피하며 한 점으로 모은다.
		if (( freq_khz <= cur_max )); then
			echo "$freq_khz" > "$d/scaling_min_freq"; echo "$freq_khz" > "$d/scaling_max_freq"
		else
			echo "$freq_khz" > "$d/scaling_max_freq"; echo "$freq_khz" > "$d/scaling_min_freq"
		fi
	done
	echo "[hardware/cpufreq] applied: cores [$cpuset] → ${freq_khz}kHz 고정 (orig saved → $ORIG_FILE)"

	# 즉시 readback 검증 — clamp이 안 먹었으면 크게 실패시킨다(teardown이 orig로 원복).
	if ! do_verify "$freq_khz" "$cpuset"; then
		echo "ERROR: cpufreq clamp readback 불일치 — 적용 실패" >&2
		exit 1
	fi
}

# ============================================================= RESTORE
do_restore() {
	[[ -f "$ORIG_FILE" ]] || { echo "[hardware/cpufreq] 복원할 것 없음 (no $ORIG_FILE)"; return 0; }
	local c gov omin omax d
	while read -r c gov omin omax; do
		[[ -n "$c" ]] || continue
		d="$(cpufreq_dir "$c")"
		[[ -d "$d" ]] || continue
		# 천장(max) 먼저 넓히고 → 바닥(min) 내리고 → governor 복원. best-effort(teardown은 절대 실패 X).
		[[ -w "$d/scaling_max_freq" ]] && echo "$omax" > "$d/scaling_max_freq" 2>/dev/null || true
		[[ -w "$d/scaling_min_freq" ]] && echo "$omin" > "$d/scaling_min_freq" 2>/dev/null || true
		if [[ "$gov" != "unknown" && -w "$d/scaling_governor" ]]; then
			echo "$gov" > "$d/scaling_governor" 2>/dev/null || true
		fi
	done < "$ORIG_FILE"
	echo "[hardware/cpufreq] restored cores from $ORIG_FILE"
}

# ============================================================= VERIFY
do_verify() {
	local freq_khz="$1" cpuset="$2"
	if [[ -z "$freq_khz" || "$freq_khz" == "none" || "$freq_khz" == "max" ]]; then
		echo "  [PASS] cpufreq disabled"
		return 0
	fi
	[[ -n "$cpuset" ]] || { echo "  [FAIL] cpufreq set이지만 cpuset 없음"; return 1; }

	local cores fail=0 c d mn mx
	cores="$(expand_cpulist "$cpuset")"
	for c in $cores; do
		d="$(cpufreq_dir "$c")"
		mn="$(cat "$d/scaling_min_freq" 2>/dev/null || echo na)"
		mx="$(cat "$d/scaling_max_freq" 2>/dev/null || echo na)"
		if [[ "$mn" == "$freq_khz" && "$mx" == "$freq_khz" ]]; then
			printf "  [PASS] cpu%s scaling_min/max == %s kHz\n" "$c" "$freq_khz"
		else
			printf "  [FAIL] cpu%s scaling_min/max = %s/%s (expected %s)\n" "$c" "$mn" "$mx" "$freq_khz"
			fail=$((fail + 1))
		fi
	done
	return $fail
}

# -------------------------------------------------------------- dispatch
case "$ACTION" in
	apply)   do_apply "${3:-}" "${4:-}" ;;
	restore) do_restore ;;
	verify)  do_verify "${3:-}" "${4:-}" ;;
	*) echo "ERROR: unknown action: $ACTION" >&2; exit 2 ;;
esac
