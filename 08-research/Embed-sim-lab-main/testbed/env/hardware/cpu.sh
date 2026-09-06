#!/usr/bin/env bash
# env/hardware/cpu.sh — cgroup CPU 제약 적용
#
# 모사 대상: 디바이스의 CPU 처리량 상한 (저전력/소수 코어 SoC)
#   - cpu.max      = CFS bandwidth (quota/period)
#   - cpuset.cpus  = 실행 가능한 CPU core 집합
#   - cpu.weight   = 경합 시 상대 점유율          ← TODO
#
# 전제: cgroup 디렉토리는 cgroup.sh create가 이미 만들어 둠.
#        이 스크립트는 그 위에 cpu 제약을 "얹기"만 한다 (디렉토리 lifecycle 관여 X).
#        그래서 destroy action 없음 — cgroup.sh destroy가 디렉토리째 지우면 cpu.max도 사라짐.
#
# Action: apply | verify
#
# Usage:
#   sudo cpu.sh apply  <run_id> <bandwidth_cores|max> [cpuset_cpus]
#   sudo cpu.sh verify <run_id> <bandwidth_cores|max> [cpuset_cpus]
#
# 예:
#   bandwidth_cores=1.5 → cpu.max = 150000 100000  (100ms 중 150ms 분량)
#   bandwidth_cores=max → cpu.max = max 100000     (CPU bandwidth 제한 없음)
#   cpuset_cpus=0-1     → CPU 0~1번에서만 실행 가능

set -euo pipefail

CG_ROOT="/sys/fs/cgroup"
PERIOD=100000   # CFS period 100ms (microseconds). quota = bandwidth_cores * PERIOD.

# -------------------------------------------------------- args & dispatch
ACTION="${1:-}"
RUN_ID="${2:-}"

if [[ -z "$ACTION" || -z "$RUN_ID" ]]; then
	echo "usage: $0 {apply <run_id> <bandwidth_cores|max> [cpuset_cpus] | verify <run_id> <bandwidth_cores|max> [cpuset_cpus]}" >&2
	exit 2
fi

CG_PATH="$CG_ROOT/criu_test_$RUN_ID"

# --------------------------------------------------------- common helpers
require_root() {
	[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
}

# bandwidth_cores(예: 1.5, 0.5)를 CFS quota(microseconds)로 변환.
# "max"는 bandwidth 제한 없이 cpuset만 걸고 싶을 때 사용한다.
# 커널 최소 quota는 1000us(1ms)라 그 아래는 바닥 처리.
bandwidth_to_quota() {
	local bandwidth_cores="$1"
	if [[ "$bandwidth_cores" == "max" ]]; then
		echo "max"
		return 0
	fi

	[[ "$bandwidth_cores" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
		|| { echo "ERROR: bandwidth_cores must be a positive number or 'max' (got: '$bandwidth_cores')" >&2; exit 2; }
	awk "BEGIN { q = $bandwidth_cores * $PERIOD; if (q < 1000) q = 1000; printf \"%d\", q }"
}

# cpulist(예: 0, 0-1, 0,2-3)를 정렬된 comma list로 정규화해서 비교에 사용한다.
normalize_cpulist() {
	local cpulist="$1"
	awk -v list="$cpulist" '
		BEGIN {
			if (list !~ /^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$/) exit 2
			n = split(list, parts, ",")
			for (i = 1; i <= n; i++) {
				split(parts[i], r, "-")
				start = r[1] + 0
				end = (r[2] == "" ? start : r[2] + 0)
				if (end < start) exit 2
				for (c = start; c <= end; c++) seen[c] = 1
			}
			first = 1
			for (c = 0; c < 4096; c++) {
				if (c in seen) {
					if (!first) printf ","
					printf "%d", c
					first = 0
				}
			}
			printf "\n"
		}
	' || { echo "ERROR: invalid cpuset_cpus (got: '$cpulist')" >&2; exit 2; }
}

apply_cpuset() {
	local cpuset_cpus="$1"
	[[ -n "$cpuset_cpus" ]] || return 0

	normalize_cpulist "$cpuset_cpus" >/dev/null

	# parent에 cpuset controller delegate (이미 켜져있으면 무시)
	echo "+cpuset" > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null || true

	if [[ ! -f "$CG_PATH/cpuset.cpus" ]]; then
		echo "ERROR: cpuset controller not delegated to $CG_PATH" >&2
		exit 1
	fi

	# 일부 커널/환경에서는 명시적인 cpuset.cpus 설정 전에 mems도 유효해야 한다.
	if [[ -f "$CG_PATH/cpuset.mems" && -r "$CG_ROOT/cpuset.mems.effective" ]]; then
		local mems
		mems="$(cat "$CG_ROOT/cpuset.mems.effective")"
		[[ -n "$mems" ]] && echo "$mems" > "$CG_PATH/cpuset.mems"
	fi

	echo "$cpuset_cpus" > "$CG_PATH/cpuset.cpus"
	echo "[hardware/cpu] applied: cpuset.cpus = $cpuset_cpus  (effective: $(cat "$CG_PATH/cpuset.cpus.effective"))"
}

# ============================================================== APPLY
do_apply() {
	local bandwidth_cores="$1"
	local cpuset_cpus="$2"
	[[ -n "$bandwidth_cores" ]] || { echo "ERROR: bandwidth_cores required" >&2; exit 2; }
	require_root

	[[ -d "$CG_PATH" ]] \
		|| { echo "ERROR: cgroup not found: $CG_PATH (run cgroup.sh create first)" >&2; exit 1; }

	# parent에 cpu controller delegate (이미 켜져있으면 무시)
	echo "+cpu" > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null || true

	# cpu controller가 child에 delegate 됐는지 확인
	if [[ ! -f "$CG_PATH/cpu.max" ]]; then
		echo "ERROR: cpu controller not delegated to $CG_PATH" >&2
		echo "       (컨테이너에 cpu cgroup이 위임됐는지 확인: --privileged 또는 cgroup delegation)" >&2
		exit 1
	fi

	local quota
	quota="$(bandwidth_to_quota "$bandwidth_cores")"
	echo "$quota $PERIOD" > "$CG_PATH/cpu.max"

	echo "[hardware/cpu] applied: cpu.max = $quota $PERIOD  (${bandwidth_cores} core bandwidth)"
	apply_cpuset "$cpuset_cpus"
}

# ============================================================= VERIFY
do_verify() {
	local bandwidth_cores="$1"
	local cpuset_cpus="$2"
	[[ -n "$bandwidth_cores" ]] || { echo "ERROR: bandwidth_cores required" >&2; exit 2; }

	local fail=0
	check() {
		if eval "$2"; then printf "  [PASS] %s\n" "$1"
		else printf "  [FAIL] %s\n" "$1"; fail=$((fail+1)); fi
	}

	# cpu.max는 memory.max와 달리 커널이 값을 보정하지 않음 — 쓴 값 그대로 읽힘.
	local quota expected actual
	quota="$(bandwidth_to_quota "$bandwidth_cores")"
	expected="$quota $PERIOD"
	actual=$(cat "$CG_PATH/cpu.max" 2>/dev/null || echo "missing")
	check "cpu.max == '$expected' (actual: '$actual')" \
		"[ '$actual' = '$expected' ]"

	if [[ -n "$cpuset_cpus" ]]; then
		local expected_cpus actual_cpus actual_effective
		expected_cpus="$(normalize_cpulist "$cpuset_cpus")"
		actual_cpus="$(normalize_cpulist "$(cat "$CG_PATH/cpuset.cpus" 2>/dev/null || echo "")")"
		actual_effective="$(cat "$CG_PATH/cpuset.cpus.effective" 2>/dev/null || echo "missing")"
		check "cpuset.cpus == '$cpuset_cpus' (actual: '$(cat "$CG_PATH/cpuset.cpus" 2>/dev/null || echo "missing")', effective: '$actual_effective')" \
			"[ '$actual_cpus' = '$expected_cpus' ]"
	fi

	return $fail
}

# -------------------------------------------------------------- dispatch
case "$ACTION" in
	apply)
		do_apply "${3:-}" "${4:-}"
		;;
	verify)
		do_verify "${3:-}" "${4:-}"
		;;
	*)
		echo "ERROR: unknown action: $ACTION" >&2
		exit 2
		;;
esac
