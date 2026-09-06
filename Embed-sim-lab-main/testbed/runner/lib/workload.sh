#!/usr/bin/env bash
# runner/lib/workload.sh — 워크로드-무지 기동·PHASE 관측 (YAML은 안 읽음 — env만)
# uses: WL_BIN WL_FLAGS RUN_DIR CG_PATH / sets: WL_PID WL_LOG WL_PHASE_LINE

wl_launch() {
	WL_LOG="$RUN_DIR/workload.log"
	: > "$WL_LOG"
	# cgroup join 후 exec — 첫 할당부터 memcg 계정 (old target 기동 방식 계승)
	# shellcheck disable=SC2086
	( echo "$BASHPID" > "$CG_PATH/cgroup.procs" && exec "$WL_BIN" $WL_FLAGS ) \
		> "$WL_LOG" 2>&1 &
	WL_PID=$!
}

# 측정 창 밖 전용 (grep 스폰 있음). dump_at 대기·ready 대기용.
wl_wait_phase() {
	local phase="$1" timeout_s="$2"
	local deadline=$((SECONDS + timeout_s))
	WL_PHASE_LINE=""
	while ((SECONDS < deadline)); do
		kill -0 "$WL_PID" 2>/dev/null || return 1
		WL_PHASE_LINE="$(grep -m1 -E "^PHASE ${phase}([[:space:]]|\$)" "$WL_LOG" 2>/dev/null || true)"
		[[ -n "$WL_PHASE_LINE" ]] && return 0
		sleep 0.005
	done
	return 1
}

wl_kv() {
	[[ "$WL_PHASE_LINE" =~ [[:space:]]$1=([^[:space:]]+) ]] && echo "${BASH_REMATCH[1]}"
}
