#!/usr/bin/env bash
# runner/lib/probe.sh — first-response 측정 창. 이 함수가 cold·restore 유일한 측정 경로 (§6-1).
# 창 내용: kill -0(빌트인) → cprobe → $EPOCHREALTIME(빌트인). 성공 경로(이벤트→cprobe 성공→
# PROBE_RESP_TS 기록)엔 cprobe가 유일한 외부 스폰. 폴 실패 사이의 `sleep 0.005`(5ms 페이싱,
# §6-3)도 외부 스폰이지만 PROBE_RESP_TS는 성공 시 sleep 이전에 이미 찍혀 지표에 안 들어가고,
# cold/restore 양 경로가 동일 메커니즘이라 편향 없음(실측: docs/superpowers/reviews/
# 2026-07-testbed-rewrite-invariants.md §Step2).
# sed/awk/date/seq/grep 등 다른 스폰 추가 절대 금지. 수정 시 스펙 §6-1~6 재검토 필수.
# uses: PROBE_CPROBE (기본: runner/cprobe) / sets: PROBE_RESP_TS PROBE_OK
PROBE_CPROBE="${PROBE_CPROBE:-$TESTBED_DIR/runner/cprobe}"

probe_first_response() {
	local pid="$1" port="$2" timeout_s="$3"
	local polls=$((timeout_s * 200))   # 5ms 폴링 (§6-3) — 창 밖 사전계산
	PROBE_RESP_TS=""
	PROBE_OK=""
	local _pi
	for ((_pi = 0; _pi < polls; _pi++)); do
		kill -0 "$pid" 2>/dev/null || break
		if "$PROBE_CPROBE" 127.0.0.1 "$port" >/dev/null 2>&1; then
			# shellcheck disable=SC2034  # PROBE_RESP_TS used externally
			PROBE_RESP_TS="$EPOCHREALTIME"
			# shellcheck disable=SC2034  # PROBE_OK used externally
			PROBE_OK=1
			break
		fi
		sleep 0.005
	done
}
