#!/usr/bin/env bash
# env/hardware/memory.sh — cgroup memory controller로 RAM/swap 한도 적용
#
# 모사 대상: 디바이스가 물리적으로 줄 수 있는 RAM 한도 + swap escape guard
#   - memory.max      = hard RAM ceiling
#   - memory.swap.max = 이 cgroup이 swap으로 밀어낼 수 있는 anonymous memory 한도
#   - memory.high     = reclaim pressure 유도 soft-ish limit  ← TODO
#
# 전제: cgroup 디렉토리는 cgroup.sh create가 이미 만들어 둠.
#        이 스크립트는 그 위에 memory 제약을 "얹기"만 한다 (디렉토리 lifecycle 관여 X).
#        그래서 destroy action 없음 — cgroup.sh destroy가 디렉토리째 지우면 memory.max도 사라짐.
#
# Action: apply | verify
#
# Usage:
#   sudo memory.sh apply  <run_id> <memory_max> [swap_max]
#   sudo memory.sh verify <run_id> <memory_max> [swap_max]
#
# 예:
#   memory_max=512M, swap_max=0    → 순수 RAM ceiling baseline
#   memory_max=512M, swap_max=64M  → 작은 embedded swap 허용
#   memory_max=512M, swap_max=max  → cgroup swap 한도 없음

set -euo pipefail

CG_ROOT="/sys/fs/cgroup"

# -------------------------------------------------------- args & dispatch
ACTION="${1:-}"
RUN_ID="${2:-}"

if [[ -z "$ACTION" || -z "$RUN_ID" ]]; then
	echo "usage: $0 {apply <run_id> <memory_max> [swap_max] | verify <run_id> <memory_max> [swap_max]}" >&2
	exit 2
fi

CG_PATH="$CG_ROOT/criu_test_$RUN_ID"

# --------------------------------------------------------- common helpers
require_root() {
	[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
}

# IEC 표기(256M, 1G)를 bytes로 변환. "max"는 cgroup의 무제한 표기 그대로 둔다.
limit_to_cgroup_value() {
	local value="$1"
	local label="$2"

	if [[ "$value" == "max" ]]; then
		echo "max"
		return 0
	fi

	numfmt --from=iec "$value" 2>/dev/null \
		|| { echo "ERROR: invalid $label (got: '$value')" >&2; exit 2; }
}

format_limit() {
	local value="$1"

	if [[ "$value" == "max" ]]; then
		echo "max"
	else
		numfmt --to=iec --suffix=B "$value"
	fi
}

# ============================================================== APPLY
do_apply() {
	local memory_max="$1"
	local swap_max="${2:-0}"
	[[ -n "$memory_max" ]] || { echo "ERROR: memory_max required" >&2; exit 2; }
	require_root

	[[ -d "$CG_PATH" ]] \
		|| { echo "ERROR: cgroup not found: $CG_PATH (run cgroup.sh create first)" >&2; exit 1; }

	# parent에 memory controller delegate (이미 켜져있으면 무시)
	echo "+memory" > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null || true

	# memory controller가 child에 delegate 됐는지 확인
	if [[ ! -f "$CG_PATH/memory.max" ]]; then
		echo "ERROR: memory controller not delegated to $CG_PATH" >&2
		exit 1
	fi
	if [[ ! -f "$CG_PATH/memory.swap.max" ]]; then
		echo "ERROR: memory.swap.max not available in $CG_PATH" >&2
		echo "       cannot enforce swap escape guard for this run" >&2
		exit 1
	fi

	local memory_value swap_value
	memory_value="$(limit_to_cgroup_value "$memory_max" "memory_max")"
	swap_value="$(limit_to_cgroup_value "$swap_max" "swap_max")"
	echo "$memory_value" > "$CG_PATH/memory.max"
	echo "$swap_value" > "$CG_PATH/memory.swap.max"

	echo "[hardware/memory] applied: memory.max = $(format_limit "$memory_value")  ($memory_value)"
	echo "[hardware/memory] applied: memory.swap.max = $(format_limit "$swap_value")  ($swap_value)"
}

# ============================================================= VERIFY
do_verify() {
	local memory_max="$1"
	local swap_max="${2:-0}"
	[[ -n "$memory_max" ]] || { echo "ERROR: memory_max required" >&2; exit 2; }

	local fail=0
	check() {
		if eval "$2"; then printf "  [PASS] %s\n" "$1"
		else printf "  [FAIL] %s\n" "$1"; fail=$((fail+1)); fi
	}

	# 주의: memory.max는 page 크기로 반올림될 수 있음. IEC 값(1M 배수)은 항상 page-aligned이라
	# 보통 정확히 일치하지만, 어긋나면 그걸 잡는 게 verify의 목적.
	local expected actual expected_swap actual_swap
	expected="$(limit_to_cgroup_value "$memory_max" "memory_max")"
	actual=$(cat "$CG_PATH/memory.max" 2>/dev/null || echo -1)
	check "memory.max == $expected (actual: $actual)" \
		"[ '$actual' = '$expected' ]"

	expected_swap="$(limit_to_cgroup_value "$swap_max" "swap_max")"
	actual_swap=$(cat "$CG_PATH/memory.swap.max" 2>/dev/null || echo "missing")
	check "memory.swap.max == $expected_swap (actual: $actual_swap)" \
		"[ '$actual_swap' = '$expected_swap' ]"

	return $fail
}

# -------------------------------------------------------------- dispatch
case "$ACTION" in
	apply)
		do_apply "${3:-}" "${4:-0}"
		;;
	verify)
		do_verify "${3:-}" "${4:-0}"
		;;
	*)
		echo "ERROR: unknown action: $ACTION" >&2
		exit 2
		;;
esac
