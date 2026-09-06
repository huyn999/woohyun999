#!/usr/bin/env bash
# runner/lib/cleanup.sh — 등록 역순 실행 EXIT trap (두 러너 공용)
CLEANUP_FNS=()
cleanup_register() { CLEANUP_FNS+=("$1"); }
cleanup_run_all() {
	local i
	for ((i = ${#CLEANUP_FNS[@]} - 1; i >= 0; i--)); do
		"${CLEANUP_FNS[$i]}" || true
	done
}
cleanup_install_trap() { trap cleanup_run_all EXIT; }
