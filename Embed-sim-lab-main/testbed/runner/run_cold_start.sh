#!/usr/bin/env bash
# runner/run_cold_start.sh — cold-start 경로 오케스트레이터 (재작성판)
# 측정 정의: cold_response = exec 직전 → PONG (lib/probe.sh 측정 창, 스펙 §6-1~5)
set -euo pipefail
# 렌즈4 F4: locale 지뢰 — $EPOCHREALTIME(빌트인)과 `time`/TIMEFORMAT=%R의 소수점(radix)은
# locale(LC_NUMERIC)을 탄다(예: de_DE류는 ','). 측정 창의 산술(awk BEGIN{...})이 그 문자열을
# 그대로 숫자로 파싱하므로, 실행 환경 locale이 바뀌면 소수점이 콤마인 값이 들어와 조용히
# NaN/오파싱될 수 있다 — 어느 환경에서 실행되든 고정하기 위해 LC_ALL=C를 강제한다.
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"
for m in config cgroup snapshot cleanup workload probe stress result; do
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/lib/$m.sh"
done

# NOTE(cold_launch_s/cold_ready_s, §비고): old의 이 두 키는 각각 별도 폴링 루프(PID/exe 관측,
# WORKLOAD_READY grep)로 얻은 타임스탬프였다. 새 아키텍처는 그 두 관측을 probe_first_response
# 하나로 흡수했고(§6-1 "cold·restore 유일한 측정 경로"), Task 13 restore plan도 대응하는
# launch/ready 분리 계산을 두지 않는다 — 이 두 키를 이식하려면 측정 창 안에 추가 폴링/스폰을
# 넣어야 하는데 이는 §6-1~2 위반이다. 따라서 여기서는 의도적으로 result_set을 생략했다
# (lib/result.sh 기본값 na로 남음) — 브리프 Step 2와 old 구조 간 충돌, report에 DONE_WITH_CONCERNS로 명시.

# ---- cold 고유 in-file steps ----

# 이식: testbed_old/runner/run_cold_start.sh:306-323 prepare_target_binary_on_constrained_storage
# storage.enabled=false(CFG_STORAGE_IMAGE_ENABLED=false)여도 old와 동일하게 무조건 복사한다 — old도
# STORAGE_IMAGE_ENABLED로 분기하지 않고 IMAGE_DIR(비활성 시엔 env/hardware/storage.sh do_apply가
# mkdir -p만 해둔 일반 디렉터리)에 무조건 사본을 뒀다. cold-start의 목적은 "제약 스토리지 여부"와
# 무관하게 원본 바이너리의 host page cache 오염을 배제하는 것이라 이 무조건성을 그대로 유지한다.
step_prepare_binary() {
	# shellcheck source=/dev/null
	source "$RUN_DIR/state.env"   # env/setup.sh가 떠둔 IMAGE_DIR (storage.sh 핸드오프)
	local app_dir="$IMAGE_DIR/app"
	local app_bin="$app_dir/$WL_NAME"
	mkdir -p "$app_dir"
	cp "$WL_BIN" "$app_bin"
	chmod +x "$app_bin"
	sync "$app_bin" 2>/dev/null || sync
	if "$SCRIPT_DIR/fadvise_dontneed.py" "$app_bin" 2>"$RUN_DIR/fadvise.log"; then
		echo "[cold-start] fadvise DONTNEED applied to $app_bin"
	else
		echo "[cold-start] WARN: fadvise DONTNEED failed; see $RUN_DIR/fadvise.log" >&2
	fi
	WL_BIN="$app_bin"   # 측정 창의 wl_launch가 이 값을 exec — 전역 갱신(local 아님)
}

# 이식: testbed_old/runner/run_cold_start.sh:398-414 "3b. drop caches" 섹션.
# CFG_CACHE_POLICY 분기: old는 상수 하나(best_effort_cold_cache)뿐이었으나 새 config_to_env.py는
# top-level cache_policy를 자유 문자열로 받는다 — 여기서 실제로 분기해 알려진 정책만 수행하고,
# 그 외 값은 (실험 조건을 조용히 무시하는 대신) 크게 실패시킨다.
step_drop_caches() {
	local policy="${CFG_CACHE_POLICY:-best_effort_cold_cache}"
	case "$policy" in
		best_effort_cold_cache)
			echo "=== drop caches (cache_policy=$policy) ==="
			snap_take before_drop_caches with_meminfo
			sync
			result_set drop_caches_ts "$(date +%s.%N)"
			if echo 3 > /proc/sys/vm/drop_caches 2>"$RUN_DIR/drop_caches.err"; then
				result_set drop_caches_rc 0
			else
				# shellcheck disable=SC2320  # 의도: 방금 실패한 echo 리다이렉트의 rc (old와 동일 패턴)
				result_set drop_caches_rc "$?"
				echo "[cache] WARN: drop_caches failed; see $RUN_DIR/drop_caches.err" >&2
			fi
			snap_take after_drop_caches with_meminfo
			;;
		*)
			echo "ERROR: invalid cache_policy value: $policy" >&2
			result_write FAIL "invalid cache_policy: $policy"
			exit 2
			;;
	esac
	result_set cache_policy "$policy"
}

step_resident_check() {   # 선언 정직성 (§4-B): 편차 >max(10%, 4MiB)면 경고 플래그
	local rss_kb; rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/$WL_PID/status" 2>/dev/null || echo 0)"
	local mism
	if (( ${WL_RESIDENT_BYTES:-0} > 0 )); then
		# 상대 10%만 쓰면 MiB급 소형 선언(예: initburst 2MiB)에서 고정 잡음(libc/stdio/소켓/heap
		# arena, 수백 KiB)이 항상 문턱을 넘어 가드가 상시 오탐된다(실측: crossover2 cold 140/140
		# mismatch=1 — 가드 사망). 이 가드의 목적은 Option B absorb 산식(절대 바이트) 보호이므로
		# 절대 하한 4MiB(스트레스 1278MiB 대비 0.3%)를 둔다 — 총량 대비 무의미한 편차는 무시하고,
		# "선언 50MiB인데 실제 1MiB" 같은 진짜 부정직은 그대로 잡는다. run_once.sh와 동일 하한.
		mism="$(awk "BEGIN{d=$rss_kb*1024-$WL_RESIDENT_BYTES; if(d<0)d=-d; tol=$WL_RESIDENT_BYTES*0.1; if(tol<4194304)tol=4194304; print (d>tol)?1:0}")"
	else
		mism=na   # 선언 상주량이 0이면 나눗셈 스킵 (§controller ③, run_once.sh와 동일 가드)
	fi
	result_set resident_rss_bytes "$((rss_kb * 1024))"
	result_set resident_mismatch "$mism"
}

# 이식: testbed_old/runner/run_cold_start.sh:511-514 L2 membership(cold target). §6-16 검증
# 사다리 3번째 룽 — invariant audit FAIL 수정(cold 경로엔 이 룽이 아예 없었다). run_once.sh의
# step_verify_recovery(run_once.sh:258-268)와 동형: generic_recovery yes/no를 확정하고, 실패
# 여부는 non-zero 반환으로 알린다 — old와 달리 이 러너는 probe 결과(PONG)와 합쳐서 최종
# result_write를 결정해야 하므로(측정 창을 건드리지 않고 창 밖 bookkeeping에서만 판정) exit는
# 호출자(main)가 한다.
step_verify_recovery() {
	if "$TESTBED_DIR/env/verify.sh" "$RUN_DIR" membership "cold target" "$WL_PID"; then
		result_set generic_recovery yes
		return 0
	else
		result_set generic_recovery no
		return 1
	fi
}

main() {
	local run_id="" cfg=""
	while (($#)); do case "$1" in
		--run-id) run_id="$2"; shift 2 ;;
		--config) cfg="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac; done
	config_load "$run_id" "$cfg"
	config_seed_result_meta      # 조건 메타(memory_max/workload/stress_* 등) RESULT_KV seed (리뷰 R1 Fix 2)
	result_set runner cold
	result_set cache_policy "${CFG_CACHE_POLICY:-best_effort_cold_cache}"
	cleanup_install_trap
	# run_once.sh와 동형 가드(§6-16 부수 결함 수정): 인프라 실패도 result.env에 FAIL 사유를 남겨야
	# 캠페인이 "NO_RESULT_ENV(rc=…)"로 뭉뚱그리지 않고 실제 사유로 집계한다 — 이 스크립트는 set -e라
	# 가드 없이 실패하면 result_write 없이 즉시 죽는다(invariant audit §6-16 FAIL 상세 근거 3).
	# I1: setup 호출보다 먼저 등록 — setup이 cgroup/loop/dm/cpufreq clamp를 일부만 만든 채
	# 실패해도(예: memory.max delegate 실패, storage mkfs 실패) EXIT trap이 teardown을 반드시
	# 태워 그 잔여물을 걷어내게 한다. teardown.sh(및 하위 hardware/*.sh)는 미생성 상태에서도
	# -d/-f 가드와 `|| true`로 안전하게 no-op하도록 이미 작성돼 있다(위 각 스크립트 확인).
	cleanup_register env_teardown
	"$TESTBED_DIR/env/setup.sh" "$RUN_DIR" || { result_write FAIL "env setup failed"; exit 1; }
	"$TESTBED_DIR/env/verify.sh" "$RUN_DIR" || { result_write FAIL "env verify failed"; exit 1; }
	cgroup_join_self || { result_write FAIL "cgroup join failed"; exit 1; }
	# 이식: testbed_old/runner/run_cold_start.sh:359-361 (setup+verify 직후·부하 전 baseline —
	# run_once.sh와 동일 시점). Task 18 §b Fix 1: 브리프의 snap_take 호출 목록에서 빠졌던
	# 시점을 old 진실대로 복원(cold+restore 공통).
	snap_take before_stress
	# 이식: testbed_old/runner/run_cold_start.sh:363-368 "2. membership preflight" (env verify 후·
	# stress 시작 전, old 호출 위치 그대로). run_once.sh와 동형 호출(§6-16 검증 사다리 2번째 룽 —
	# invariant audit FAIL 수정. old는 두 러너 모두 호출했다).
	"$TESTBED_DIR/env/verify.sh" "$RUN_DIR" preflight || { result_write FAIL "canary preflight failed"; exit 1; }
	# C1: `stress_start_verified && cleanup_register stress_stop`는 A(start_verified) 실패를 삼켜
	# 등록을 건너뛴다 — stress가 죽은 채 무압박으로 계속 진행되면 PASS가 §6-16을 위반한다.
	# 등록은 stress.sh 계약대로 무조건 먼저 한다 — stress/stop.sh는 pids 파일이 없으면 no-op이라
	# enabled=false에서도, start 실패로 pids가 안 쓰였어도 안전하다.
	cleanup_register stress_stop
	stress_start_verified || { result_write FAIL "stress start/verify failed"; exit 1; }
	stress_warmup; snap_take after_stress_warmup
	step_prepare_binary || { result_write FAIL "binary prep failed"; exit 1; }
	step_drop_caches
	# ---- 측정 창: 이 4줄 사이에 어떤 코드도 추가 금지 (§6-1~2) ----
	local start_ts="$EPOCHREALTIME"
	wl_launch
	probe_first_response "$WL_PID" "$WL_PORT" "${READY_TIMEOUT_S:-60}"
	# ---- 창 밖: bookkeeping ----
	snap_take after_response
	result_set target_log "$WL_LOG"   # 렌즈4 F3: 실제 경로 기록 (WL_LOG는 창 안 wl_launch가 이미 설정)
	wl_wait_phase ready 5 || true          # 이미 발행돼 있음 — 메트릭 파싱용
	local m; for m in $WL_METRICS; do result_set "wl_$m" "$(wl_kv "$m" || echo na)"; done
	step_resident_check                    # 선언 정직성 (§4-B): VmRSS vs WL_RESIDENT_BYTES
	if [[ -n "$PROBE_OK" ]]; then
		result_set cold_response_s "$(awk "BEGIN{print $PROBE_RESP_TS - $start_ts}")"
		# 감사 구멍 1: 측정 후 stress 생존 재확인 (run_once.sh와 동형 — 창 밖 bookkeeping).
		if ! stress_assert_alive; then
			result_write FAIL "stress died during run"
		# L2 membership (§6-16 검증 사다리 3번째 룽, 측정 창 밖) — old도 cold response 성공 후에만
		# membership을 확인했다(testbed_old/runner/run_cold_start.sh:511, 실패 시 그 이전에 exit).
		elif step_verify_recovery; then
			result_write PASS
		else
			result_write FAIL "cold target is not in cgroup (membership)"
		fi
	else
		result_write FAIL "no response within timeout"
	fi
}
env_teardown() { "$TESTBED_DIR/env/teardown.sh" "$RUN_DIR"; }
main "$@"
