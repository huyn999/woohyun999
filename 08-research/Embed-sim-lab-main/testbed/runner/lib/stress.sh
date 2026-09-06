#!/usr/bin/env bash
# runner/lib/stress.sh — background stress-ng 이식 래퍼
# 이식 소스: testbed_old/runner/run_once.sh 의 stress 시작 블록(§3 섹션, line ~533-554)과
#            maybe_stress_warmup (line ~356-365). stress/{start,verify,stop}.sh 자체는
#            Task 8에서 old 그대로 이식됨(diff 0) — 여기는 그 호출부만 감싼다.
# uses: CFG_STRESS_ENABLED CFG_STRESS_VM_WORKERS CFG_STRESS_VM_BYTES CFG_STRESS_WARMUP_S
#       CFG_STRESS_EXTRA CFG_STRESS_CPU_SATURATE TESTBED_DIR RUN_ID CG_PATH RUN_DIR
# CFG_STRESS_ENABLED=false(또는 미설정)면 stress_start_verified/stress_warmup 모두 no-op.
# cleanup_register stress_stop 은 호출자(러너) 책임 — stress/stop.sh는 pids 파일이 없으면
# 그 자체로 no-op이라(§stress/stop.sh) enabled=false에서도 안전하게 등록해둘 수 있다.

stress_start_verified() {
	case "${CFG_STRESS_ENABLED:-false}" in
		true|yes|1)
			STRESS_EXTRA="${CFG_STRESS_EXTRA:-}" STRESS_CPU_SATURATE="${CFG_STRESS_CPU_SATURATE:-true}" \
				STRESS_FLOOR_MIB="${CFG_STRESS_FLOOR_MIB:-38}" \
				"$TESTBED_DIR/stress/start.sh" "$RUN_ID" "$CG_PATH" "$RUN_DIR" \
				"${CFG_STRESS_VM_WORKERS:-0}" "${CFG_STRESS_VM_BYTES:-0}" || return 1
			"$TESTBED_DIR/stress/verify.sh" "$CG_PATH" "$RUN_DIR" || return 1
			;;
		false|no|0|"")
			: # disabled — no-op (old: "[stress] disabled")
			;;
		*)
			echo "ERROR: invalid stress enabled value: $CFG_STRESS_ENABLED" >&2
			return 1
			;;
	esac
}

stress_warmup() {
	case "${CFG_STRESS_ENABLED:-false}" in
		true|yes|1)
			if awk "BEGIN{exit !(${CFG_STRESS_WARMUP_S:-0} > 0)}"; then
				echo "[stress] warmup: sleeping ${CFG_STRESS_WARMUP_S}s"
				sleep "$CFG_STRESS_WARMUP_S"
			fi
			;;
	esac
}

stress_stop() {
	"$TESTBED_DIR/stress/stop.sh" "$RUN_DIR" || true
}

# 측정 완료 후(창 밖, result_write PASS 직전) 배경 부하가 런 내내 살아있었는지 재확인.
# 기동 시 verify(stress_start_verified)만으로는 측정 *중* stress 사망(크래시 등)을 못 잡아
# 무압박 상태의 PASS가 조건 라벨을 오염시킬 수 있다(감사 구멍 1). stress.pids의 루트 생존만
# 확인한다 — kill -0 수십 회(µs)라 값싸고, --vm-keep 인스턴스는 루트가 워커를 관리하므로
# 루트 생존이 인스턴스 생존의 대리 지표다. enabled=false면 no-op.
stress_assert_alive() {
	case "${CFG_STRESS_ENABLED:-false}" in
		true|yes|1) : ;;
		*) return 0 ;;
	esac
	[[ -f "$RUN_DIR/stress.pids" ]] || { echo "ERROR: stress enabled but stress.pids missing" >&2; return 1; }
	local p dead=0
	while read -r p; do
		[[ -n "$p" ]] || continue
		kill -0 "$p" 2>/dev/null || dead=$((dead + 1))
	done < "$RUN_DIR/stress.pids"
	if (( dead > 0 )); then
		echo "ERROR: $dead stress instance root(s) died during the run (background load lost)" >&2
		return 1
	fi
}
