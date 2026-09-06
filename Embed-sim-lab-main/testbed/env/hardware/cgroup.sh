#!/usr/bin/env bash
# env/hardware/cgroup.sh — cgroup 디렉토리 lifecycle (골격)
#
# 이 스크립트는 "빈 cgroup을 만들고/지우는" 골격만 담당한다.
# 자원 한도(memory.max, cpu.max, io.max ...)는 각 자원 모듈이 이 골격 위에 얹는다:
#   - memory.sh : RAM ceiling
#   - cpu.sh    : CPU bandwidth
#   - storage.sh: CRIU image storage capacity + I/O bandwidth
#
# Action: create | destroy | verify
#
# Usage:
#   sudo cgroup.sh create  <run_id>
#   sudo cgroup.sh destroy <run_id>
#   sudo cgroup.sh verify  <run_id>

set -euo pipefail

CG_ROOT="/sys/fs/cgroup"

# -------------------------------------------------------- args & dispatch
ACTION="${1:-}"
RUN_ID="${2:-}"

if [[ -z "$ACTION" || -z "$RUN_ID" ]]; then
	echo "usage: $0 {create <run_id> | destroy <run_id> | verify <run_id>}" >&2
	exit 2
fi

CG_PATH="$CG_ROOT/criu_test_$RUN_ID"

# --------------------------------------------------------- common checks
require_root() {
	[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
}

require_cgv2() {
	[[ "$(stat -fc %T "$CG_ROOT" 2>/dev/null)" == "cgroup2fs" ]] || {
		echo "ERROR: cgroup v2 not mounted at $CG_ROOT" >&2
		exit 1
	}
}

# ============================================================== CREATE
do_create() {
	require_root
	require_cgv2

	# stale cgroup 제거
	if [[ -d "$CG_PATH" ]]; then
		echo "[hardware/cgroup] stale cgroup exists, removing: $CG_PATH" >&2
		rmdir "$CG_PATH" || { echo "ERROR: cannot remove stale cgroup" >&2; exit 1; }
	fi
	mkdir "$CG_PATH"

	echo "[hardware/cgroup] created: $CG_PATH"
}

# ============================================================ DESTROY
do_destroy() {
	require_root

	if [[ ! -d "$CG_PATH" ]]; then
		echo "[hardware/cgroup] cgroup does not exist, nothing to destroy: $CG_PATH"
		return 0
	fi

	# residual procs SIGKILL
	# NOTE: sysfs files always report st_size=0, so [[ -s ... ]] is a LIE here.
	# Iterate unconditionally — no-op if procs file is empty.
	killed=0
	while read -r pid; do
		if [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null; then
			killed=$((killed+1))
		fi
	done < "$CG_PATH/cgroup.procs"
	if (( killed > 0 )); then
		echo "[hardware/cgroup] killed $killed residual proc(s)" >&2
		sleep 0.3
	fi

	# rmdir — once procs are gone the dir should be removable.
	# If not, retry once after a slightly longer wait (race against fork/reparent).
	if ! rmdir "$CG_PATH" 2>/dev/null; then
		sleep 0.5
		while read -r pid; do
			[[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
		done < "$CG_PATH/cgroup.procs"
		sleep 0.3
		if ! rmdir "$CG_PATH" 2>/dev/null; then
			echo "[hardware/cgroup] WARN: rmdir failed (procs still in?)" >&2
			echo "[hardware/cgroup]   remaining: $(tr '\n' ' ' < "$CG_PATH/cgroup.procs" 2>/dev/null)" >&2
			exit 1
		fi
	fi

	echo "[hardware/cgroup] destroyed: $CG_PATH"
}

# =============================================================== VERIFY
# 골격 검증 — 디렉토리가 존재하는지만. 자원 값 검증은 각 자원 모듈이 담당.
do_verify() {
	local fail=0
	check() {
		if eval "$2"; then printf "  [PASS] %s\n" "$1"
		else printf "  [FAIL] %s\n" "$1"; fail=$((fail+1)); fi
	}

	check "cgroup exists ($CG_PATH)" "[ -d '$CG_PATH' ]"

	return $fail
}

# -------------------------------------------------------------- dispatch
case "$ACTION" in
	create)
		do_create
		;;
	destroy)
		do_destroy
		;;
	verify)
		do_verify
		;;
	*)
		echo "ERROR: unknown action: $ACTION" >&2
		exit 2
		;;
esac
