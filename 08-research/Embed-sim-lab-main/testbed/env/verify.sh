#!/usr/bin/env bash
# env/verify.sh — 환경 설정값과 cgroup membership 검증 dispatcher
#
# settings:
#   config.env를 읽어 기대값을 모듈에 인자로 전달하고, 각 모듈의 `verify` action을 호출.
#   각 모듈은 자체 PASS/FAIL 라인을 출력하고 실패 개수를 exit code로 반환.
#
# Scope:
#   - L1 structural/readback verify: cgroup 존재, memory.max/memory.swap.max/cpu.max/cpuset.cpus 값 일치
#   - L2 membership verify: canary preflight 또는 runner가 넘긴 실제 PID의 cgroup membership 확인
#   - L3 behavioral verify: 필요 시 본 실험과 분리된 별도 self-test로 수행
#
# 모듈 추가 시 아래 dispatch 블록에 한 줄만 추가하면 됨.
#
# Usage:
#   sudo env/verify.sh <run_dir>                         # settings 검증(default)
#   sudo env/verify.sh <run_dir> settings                # settings 검증
#   sudo env/verify.sh <run_dir> preflight               # canary membership 사전 검증
#   sudo env/verify.sh <run_dir> membership <label> <pid>
#   sudo env/verify.sh <run_dir> process-tree-count <pid>
#   sudo env/verify.sh <run_dir> generic-recovery <label> <pid> <alive_ms> <min_tree_count>
#
# 인터페이스: run_dir 하나 + 설정은 <run_dir>/config.env에서 CFG_* 변수로 source (스펙 §5-6).

set -uo pipefail

if [[ $# -lt 1 ]]; then
	echo "usage: $0 <run_dir> [settings|preflight|membership <label> <pid>]" >&2
	exit 2
fi
RUN_DIR="$1"
ACTION="${2:-settings}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$RUN_DIR/config.env"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"
RUN_ID="${CFG_RUN_ID:?config.env missing CFG_RUN_ID}"
MEMORY_MAX="${CFG_MEMORY_MAX:?config.env missing CFG_MEMORY_MAX}"
MEMORY_SWAP_MAX="${CFG_MEMORY_SWAP_MAX:-0}"
CPU_BANDWIDTH_CORES="${CFG_CPU_BANDWIDTH_CORES:-}"
CPUSET_CPUS="${CFG_CPUSET_CPUS:-}"
CPU_FREQ_KHZ="${CFG_CPU_FREQ_KHZ:-}"
STORAGE_IMAGE_ENABLED="${CFG_STORAGE_IMAGE_ENABLED:-false}"
STORAGE_IMAGE_CAPACITY="${CFG_STORAGE_IMAGE_CAPACITY:-256M}"
STORAGE_IMAGE_RBPS="${CFG_STORAGE_IMAGE_RBPS:-max}"
STORAGE_IMAGE_WBPS="${CFG_STORAGE_IMAGE_WBPS:-max}"
STORAGE_IMAGE_DELAY_ENABLED="${CFG_STORAGE_IMAGE_DELAY_ENABLED:-false}"
STORAGE_IMAGE_DELAY_READ_MS="${CFG_STORAGE_IMAGE_DELAY_READ_MS:-0}"
STORAGE_IMAGE_DELAY_WRITE_MS="${CFG_STORAGE_IMAGE_DELAY_WRITE_MS:-0}"
CG_PATH="/sys/fs/cgroup/criu_test_$RUN_ID"

pid_in_cgroup() {
	local pid="$1"
	local member

	[[ -r "$CG_PATH/cgroup.procs" ]] || return 1
	while read -r member; do
		[[ "$member" == "$pid" ]] && return 0
	done < "$CG_PATH/cgroup.procs"
	return 1
}

require_pid_in_cgroup() {
	local label="$1"
	local pid="$2"

	if pid_in_cgroup "$pid"; then
		echo "[membership] OK: $label pid=$pid is in $CG_PATH"
		return 0
	fi

	echo "[membership] FAIL: $label pid=$pid is not in $CG_PATH" >&2
	echo "[membership] cgroup.procs: $(tr '\n' ' ' < "$CG_PATH/cgroup.procs" 2>/dev/null)" >&2
	echo "[membership] /proc/$pid/cgroup:" >&2
	cat "/proc/$pid/cgroup" >&2 2>/dev/null || true
	return 1
}

wait_pid_in_cgroup() {
	local label="$1"
	local pid="$2"

	for _ in $(seq 1 30); do
		pid_in_cgroup "$pid" && {
			echo "[membership] OK: $label pid=$pid is in $CG_PATH"
			return 0
		}
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done

	require_pid_in_cgroup "$label" "$pid"
}

collect_descendants() {
	local root="$1"
	local child

	for child in $(pgrep -P "$root" 2>/dev/null || true); do
		echo "$child"
		collect_descendants "$child"
	done
}

process_tree_count() {
	local root="$1"
	local count=1
	local descendants

	kill -0 "$root" 2>/dev/null || {
		echo 0
		return 0
	}

	descendants="$(collect_descendants "$root")"
	if [[ -n "$descendants" ]]; then
		count=$((count + $(printf '%s\n' "$descendants" | sed '/^$/d' | wc -l)))
	fi
	echo "$count"
}

join_current_process_to_cgroup() {
	echo "$BASHPID" > "$CG_PATH/cgroup.procs"
}

do_settings() {
	local fail=0

	echo "[env/verify] run_id=$RUN_ID"
	echo

	# --- hardware ---
	echo "[hardware/cgroup]"
	"$SCRIPT_DIR/hardware/cgroup.sh" verify "$RUN_ID"
	fail=$((fail + $?))

	echo "[hardware/memory]"
	"$SCRIPT_DIR/hardware/memory.sh" verify "$RUN_ID" "$MEMORY_MAX" "$MEMORY_SWAP_MAX"
	fail=$((fail + $?))

	# cpu는 선택적 layer — setup에서 bandwidth/cpuset 중 하나라도 줬을 때만 검증
	if [[ -n "$CPU_BANDWIDTH_CORES" || -n "$CPUSET_CPUS" ]]; then
		echo "[hardware/cpu]"
		"$SCRIPT_DIR/hardware/cpu.sh" verify "$RUN_ID" "${CPU_BANDWIDTH_CORES:-max}" "$CPUSET_CPUS"
		fail=$((fail + $?))
	fi

	# cpu 주파수 고정도 선택적 layer — frequency_khz를 줬을 때만 검증
	if [[ -n "${CPU_FREQ_KHZ:-}" && "$CPU_FREQ_KHZ" != "none" && "$CPU_FREQ_KHZ" != "max" ]]; then
		echo "[hardware/cpufreq]"
		"$SCRIPT_DIR/hardware/cpufreq.sh" verify "$RUN_ID" "$CPU_FREQ_KHZ" "$CPUSET_CPUS"
		fail=$((fail + $?))
	fi

	# --- storage ---
	echo "[storage]"
	"$SCRIPT_DIR/hardware/storage.sh" verify "$RUN_ID" "$STORAGE_IMAGE_ENABLED" "$STORAGE_IMAGE_CAPACITY" \
		"$STORAGE_IMAGE_RBPS" "$STORAGE_IMAGE_WBPS" "$STORAGE_IMAGE_DELAY_ENABLED" \
		"$STORAGE_IMAGE_DELAY_READ_MS" "$STORAGE_IMAGE_DELAY_WRITE_MS"
	fail=$((fail + $?))

	# --- policy (TODO) ---
	# echo "[policy/sysctl]"
	# "$SCRIPT_DIR/policy/sysctl.sh" verify "$RUN_ID" "$SWAPPINESS"
	# fail=$((fail + $?))
	#
	# echo "[policy/swap]"
	# "$SCRIPT_DIR/policy/swap.sh"   verify "$RUN_ID" "$SWAP_BACKEND"
	# fail=$((fail + $?))

	echo
	if (( fail == 0 )); then
		echo "[env/verify] ALL CHECKS PASSED"
		return 0
	else
		echo "[env/verify] $fail CHECK(S) FAILED"
		return 1
	fi
}

do_preflight() {
	local canary_pid

	(
		join_current_process_to_cgroup
		exec sleep 60
	) &
	canary_pid=$!

	if ! wait_pid_in_cgroup "canary" "$canary_pid"; then
		kill -KILL "$canary_pid" 2>/dev/null || true
		wait "$canary_pid" 2>/dev/null || true
		return 1
	fi

	kill -TERM "$canary_pid" 2>/dev/null || true
	wait "$canary_pid" 2>/dev/null || true
}

do_generic_recovery() {
	local label="$1"
	local pid="$2"
	local alive_ms="$3"
	local min_tree_count="$4"
	local fail=0
	local sleep_s
	local state
	local tree_count
	local thread_count
	local fd_count

	require_pid_in_cgroup "$label" "$pid" || fail=$((fail + 1))

	kill -0 "$pid" 2>/dev/null || {
		echo "[generic] FAIL: $label pid=$pid is not alive" >&2
		return 1
	}
	echo "[generic] OK: $label pid=$pid is alive"

	sleep_s="$(awk "BEGIN{printf \"%.3f\", $alive_ms / 1000}")"
	sleep "$sleep_s"
	kill -0 "$pid" 2>/dev/null || {
		echo "[generic] FAIL: $label pid=$pid died within ${alive_ms}ms" >&2
		return 1
	}
	echo "[generic] OK: $label pid=$pid survived ${alive_ms}ms"

	state="$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo missing)"
	case "$state" in
		R|S|D|I)
			echo "[generic] OK: $label state=$state"
			;;
		*)
			echo "[generic] FAIL: $label unexpected state=$state" >&2
			fail=$((fail + 1))
			;;
	esac

	tree_count="$(process_tree_count "$pid")"
	if (( tree_count >= min_tree_count )); then
		echo "[generic] OK: $label process_tree_count=$tree_count (min=$min_tree_count)"
	else
		echo "[generic] FAIL: $label process_tree_count=$tree_count (min=$min_tree_count)" >&2
		fail=$((fail + 1))
	fi

	thread_count="$(find "/proc/$pid/task" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
	if (( thread_count > 0 )); then
		echo "[generic] OK: $label threads=$thread_count"
	else
		echo "[generic] FAIL: $label thread count is zero/unreadable" >&2
		fail=$((fail + 1))
	fi

	fd_count="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
	if [[ -d "/proc/$pid/fd" ]]; then
		echo "[generic] OK: $label fd_count=$fd_count"
	else
		echo "[generic] FAIL: $label fd directory is unreadable" >&2
		fail=$((fail + 1))
	fi

	return $fail
}

case "$ACTION" in
	settings)
		do_settings
		;;
	preflight)
		do_preflight
		;;
	membership)
		if [[ $# -ne 4 ]]; then
			echo "usage: $0 <run_dir> membership <label> <pid>" >&2
			exit 2
		fi
		require_pid_in_cgroup "$3" "$4"
		;;
	process-tree-count)
		if [[ $# -ne 3 ]]; then
			echo "usage: $0 <run_dir> process-tree-count <pid>" >&2
			exit 2
		fi
		process_tree_count "$3"
		;;
	generic-recovery)
		if [[ $# -ne 6 ]]; then
			echo "usage: $0 <run_dir> generic-recovery <label> <pid> <alive_ms> <min_tree_count>" >&2
			exit 2
		fi
		do_generic_recovery "$3" "$4" "$5" "$6"
		;;
	*)
		echo "ERROR: unknown verify action: $ACTION" >&2
		exit 2
		;;
esac
