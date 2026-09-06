#!/usr/bin/env bash
# runner/lib/result.sh — result.env 산출 (old 공통 스키마 유지 §6-17; result.sh는 워크로드/러너-무지)
# 이식 소스: testbed_old/runner/run_once.sh 의 write_result_env(line ~387-468, restore 경로)와
#            testbed_old/runner/run_cold_start.sh 의 write_result_env(line ~226-288, cold 경로)를
#            나란히 놓고 키를 합집합으로 통합했다. 순서는 두 old 함수 각각의 상대 순서를 보존:
#            run_once 전용 키(checkpoint_after_s/restore_gap_s/kdat_cache 등)는 run_once가 두던
#            자리(workload_port 앞)에, cold 전용 키(cold_launch_s 등)는 cold가 두던 자리
#            (workload_port 뒤)에 그대로 끼워 넣었다. 키 이름은 old 그대로(분석 호환).
# uses: RUN_ID RUN_DIR CG_PATH MEM_TIMELINE WL_METRICS(wl_* 방출용, 공백 구분)
#       WL_PARAM_KEYS(wl_param_* 방출용, 공백 구분) + WL_PARAM_<대문자>(각 값) / consumes: RESULT_KV
# RESULT_KV에 없는 키는 na (positional 인자인 result/fail_reason은 예외 — old도 fail_reason은
# 공백 기본값이었다).
declare -A RESULT_KV

result_set() { RESULT_KV["$1"]="$2"; }

# result_write <PASS|FAIL> [fail_reason]
result_write() {
	local result="${1:-UNKNOWN}" fail_reason="${2:-}"
	local f="$RUN_DIR/result.env"
	local peak oom_n oom_kill_n
	local kdat_probing kdat_restore kdat_ratio
	local m p p_ref

	# memory.peak/memory.events — Task 18 스모크 §b "부가 관찰 1" 순서 결함 수정(Fix 2).
	# env/teardown.sh가 RUN_DIR/memory.peak 등을 뜨는 시점은 cgroup destroy 직전(EXIT trap 내부,
	# cleanup_run_all → env_teardown)인데, result_write는 두 러너 모두 그 trap이 돌기 *전에*
	# main() 안에서 먼저 호출된다(PASS든 각 단계의 FAIL이든) — 그래서 RUN_DIR의 파일은 신선한
	# 런에선 아직 없고(na), 있어도 같은 run_id의 이전 실행이 남긴 stale 값이었다(실측 확인).
	# CG_PATH는 이 시점에 아직 살아있으므로(destroy는 이후) cgroup 파일을 직접 읽는다 —
	# memory.peak은 단조증가라 "모든 측정이 끝난 지금" 읽어도 destroy 직전에 읽는 것과 같은
	# 최종값이다. cgroup 자체가 아직 없으면(예: env setup 실패로 인한 초기 FAIL) na로 남는다.
	peak="$(cat "${CG_PATH:-}/memory.peak" 2>/dev/null || echo na)"
	oom_kill_n="$(awk '/^oom_kill /{print $2}' "${CG_PATH:-}/memory.events" 2>/dev/null || true)"
	[[ -n "$oom_kill_n" ]] || oom_kill_n=na
	oom_n="$(awk '/^oom /{print $2}' "${CG_PATH:-}/memory.events" 2>/dev/null || true)"
	[[ -n "$oom_n" ]] || oom_n=na

	# 렌즈4 F3: memory_current_before/memory_current_after_stress/restore_peak_current는
	# 지금까지 항상 na였다(아무 러너도 result_set한 적이 없다) — 하지만 값은 이미
	# snap_take(lib/snapshot.sh)가 같은 런의 MEM_TIMELINE에 떠 둔 상태다. 새로 측정하지 않고
	# 그 파일을 grep만 해서 채운다(창 밖, bookkeeping — snap_take 자체가 이미 그 시점에
	# memory.current를 읽어 뒀다). 해당 라벨의 snap_take를 호출하지 않는 경로(예: cold는
	# after_restore가 없음)에서는 awk가 못 찾아 na로 남는다 — "없으면 na 유지" 그대로.
	local mtl="${MEM_TIMELINE:-/dev/null}"
	[[ -n "${RESULT_KV[memory_current_before]:-}" ]] || RESULT_KV[memory_current_before]="$(
		awk -F= '$1=="memstat_before_stress_current"{print $2; found=1} END{if(!found) print "na"}' "$mtl" 2>/dev/null || echo na)"
	[[ -n "${RESULT_KV[memory_current_after_stress]:-}" ]] || RESULT_KV[memory_current_after_stress]="$(
		awk -F= '$1=="memstat_after_stress_warmup_current"{print $2; found=1} END{if(!found) print "na"}' "$mtl" 2>/dev/null || echo na)"
	[[ -n "${RESULT_KV[restore_peak_current]:-}" ]] || RESULT_KV[restore_peak_current]="$(
		awk -F= '$1=="memstat_after_restore_current"{print $2; found=1} END{if(!found) print "na"}' "$mtl" 2>/dev/null || echo na)"

	# kdat_ratio = kdat_probing_s / restore_time_s (둘 다 수치일 때만) — old assembly 그대로,
	# 입력은 RESULT_KV의 kdat_probing_s/restore_time_s 자신(호출자가 restore 경로에서만 채운다).
	kdat_probing="${RESULT_KV[kdat_probing_s]:-na}"
	kdat_restore="${RESULT_KV[restore_time_s]:-na}"
	kdat_ratio="na"
	if [[ "$kdat_probing" != "na" && "$kdat_restore" != "na" ]]; then
		kdat_ratio="$(awk "BEGIN{ if ($kdat_restore > 0) printf \"%.4f\", $kdat_probing / $kdat_restore; else print \"na\" }")"
	fi

	# timestamp: result 기록 시각 (측정 창 밖 — result_write는 bookkeeping 구간)
	[[ -n "${RESULT_KV[timestamp]:-}" ]] || RESULT_KV[timestamp]="$(date -Iseconds)"

	{
		printf 'run_id=%s\n' "${RUN_ID:-na}"
		printf 'exp_id=%s\n' "${RESULT_KV[exp_id]:-na}"
		printf 'repeat_id=%s\n' "${RESULT_KV[repeat_id]:-na}"
		printf 'timestamp=%s\n' "${RESULT_KV[timestamp]:-na}"
		printf 'runner=%s\n' "${RESULT_KV[runner]:-na}"
		printf 'result=%s\n' "$result"
		printf 'fail_reason=%s\n' "$fail_reason"
		printf 'kernel_version=%s\n' "${RESULT_KV[kernel_version]:-na}"
		printf 'memory_max=%s\n' "${RESULT_KV[memory_max]:-na}"
		printf 'memory_swap_max=%s\n' "${RESULT_KV[memory_swap_max]:-na}"
		printf 'cpu_bandwidth=%s\n' "${RESULT_KV[cpu_bandwidth]:-na}"
		printf 'cpuset_cpus=%s\n' "${RESULT_KV[cpuset_cpus]:-na}"
		printf 'cpu_freq_khz=%s\n' "${RESULT_KV[cpu_freq_khz]:-na}"
		printf 'storage_enabled=%s\n' "${RESULT_KV[storage_enabled]:-na}"
		printf 'storage_capacity=%s\n' "${RESULT_KV[storage_capacity]:-na}"
		printf 'storage_rbps=%s\n' "${RESULT_KV[storage_rbps]:-na}"
		printf 'storage_wbps=%s\n' "${RESULT_KV[storage_wbps]:-na}"
		printf 'storage_delay_enabled=%s\n' "${RESULT_KV[storage_delay_enabled]:-na}"
		printf 'storage_delay_read_ms=%s\n' "${RESULT_KV[storage_delay_read_ms]:-na}"
		printf 'storage_delay_write_ms=%s\n' "${RESULT_KV[storage_delay_write_ms]:-na}"
		printf 'stress_enabled=%s\n' "${RESULT_KV[stress_enabled]:-na}"
		printf 'stress_vm_workers=%s\n' "${RESULT_KV[stress_vm_workers]:-na}"
		printf 'stress_vm_bytes=%s\n' "${RESULT_KV[stress_vm_bytes]:-na}"
		printf 'stress_cpu_saturate=%s\n' "${RESULT_KV[stress_cpu_saturate]:-na}"
		printf 'workload=%s\n' "${RESULT_KV[workload]:-na}"
		printf 'target_bytes=%s\n' "${RESULT_KV[target_bytes]:-na}"
		printf 'dynamic_mode=%s\n' "${RESULT_KV[dynamic_mode]:-na}"
		printf 'dynamic_dirty_bytes=%s\n' "${RESULT_KV[dynamic_dirty_bytes]:-na}"
		printf 'dynamic_interval_ms=%s\n' "${RESULT_KV[dynamic_interval_ms]:-na}"
		printf 'dynamic_init_work_ms=%s\n' "${RESULT_KV[dynamic_init_work_ms]:-na}"
		printf 'compute_iters=%s\n' "${RESULT_KV[compute_iters]:-na}"
		printf 'compute_ms=%s\n' "${RESULT_KV[compute_ms]:-na}"
		# --- run_once(restore) 전용, old 순서: workload_port 앞 ---
		printf 'checkpoint_after_s=%s\n' "${RESULT_KV[checkpoint_after_s]:-na}"
		printf 'restore_gap_s=%s\n' "${RESULT_KV[restore_gap_s]:-na}"
		printf 'kdat_cache=%s\n' "${RESULT_KV[kdat_cache]:-na}"
		printf 'workload_port=%s\n' "${RESULT_KV[workload_port]:-na}"
		# --- run_cold_start 전용, old 순서: workload_port 뒤 ---
		printf 'cold_launch_s=%s\n' "${RESULT_KV[cold_launch_s]:-na}"
		printf 'cold_ready_s=%s\n' "${RESULT_KV[cold_ready_s]:-na}"
		printf 'cold_response_s=%s\n' "${RESULT_KV[cold_response_s]:-na}"
		# --- run_once(restore) 전용 계속 ---
		printf 'dump_time_s=%s\n' "${RESULT_KV[dump_time_s]:-na}"
		printf 'restore_time_s=%s\n' "$kdat_restore"
		printf 'restore_response_s=%s\n' "${RESULT_KV[restore_response_s]:-na}"
		printf 'kdat_probing_s=%s\n' "$kdat_probing"
		printf 'restore_work_s=%s\n' "${RESULT_KV[restore_work_s]:-na}"
		printf 'launch_overhead_s=%s\n' "${RESULT_KV[launch_overhead_s]:-na}"
		printf 'kdat_ratio=%s\n' "$kdat_ratio"
		printf 'task_visible_s=%s\n' "${RESULT_KV[task_visible_s]:-na}"
		printf 'image_size_bytes=%s\n' "${RESULT_KV[image_size_bytes]:-na}"
		printf 'generic_recovery=%s\n' "${RESULT_KV[generic_recovery]:-na}"
		# --- 공통 ---
		printf 'memory_current_before=%s\n' "${RESULT_KV[memory_current_before]:-na}"
		printf 'memory_current_after_stress=%s\n' "${RESULT_KV[memory_current_after_stress]:-na}"
		printf 'memory_peak_bytes=%s\n' "$peak"
		printf 'oom=%s\n' "$oom_n"
		printf 'oom_kill=%s\n' "$oom_kill_n"
		printf 'cache_policy=%s\n' "${RESULT_KV[cache_policy]:-na}"
		printf 'drop_caches_rc=%s\n' "${RESULT_KV[drop_caches_rc]:-na}"
		printf 'drop_caches_ts=%s\n' "${RESULT_KV[drop_caches_ts]:-na}"
		printf 'probe_interval_ms=%s\n' "${RESULT_KV[probe_interval_ms]:-na}"
		printf 'probe_timeout_s=%s\n' "${RESULT_KV[probe_timeout_s]:-na}"
		printf 'probe_attempts=%s\n' "${RESULT_KV[probe_attempts]:-na}"
		printf 'first_success_attempt=%s\n' "${RESULT_KV[first_success_attempt]:-na}"
		# --- run_once(restore) 전용 ---
		printf 'restore_peak_current=%s\n' "${RESULT_KV[restore_peak_current]:-na}"
		printf 'criu_dump_log=%s\n' "${RESULT_KV[criu_dump_log]:-na}"
		printf 'criu_restore_log=%s\n' "${RESULT_KV[criu_restore_log]:-na}"
		# --- 공통 ---
		printf 'target_log=%s\n' "${RESULT_KV[target_log]:-na}"
		# --- 신규 키 (Task 11 브리프 지시, old에 없음) ---
		printf 'dump_phase=%s\n' "${RESULT_KV[dump_phase]:-na}"
		# F2: pre-ready dump이 seize 창보다 짧은 init을 놓쳐(라벨 init인데 실제 freeze는 at-ready)
		# dump_phase_missed=1로 기록됨 — run_once.sh step_quiesce_and_dump가 dump 직후(freeze 상태)에
		# 판정. 비-pre-ready 런은 0, 기록이 없으면(cold 등) na.
		printf 'dump_phase_missed=%s\n' "${RESULT_KV[dump_phase_missed]:-na}"
		printf 'warmup_pings=%s\n' "${RESULT_KV[warmup_pings]:-na}"
		# warmup_pings/checkpoint_after_s는 config echo(조건 메타 — cold/restore 페어링 키).
		# 실제 동작(pre-ready dump는 핑 0회·checkpoint 대기 0s)은 아래 *_sent/_wait 키가 기록한다
		# (F7 정직 기록 승계; additive — 기존 키/순서 불변).
		printf 'warmup_pings_sent=%s\n' "${RESULT_KV[warmup_pings_sent]:-na}"
		printf 'checkpoint_wait_s=%s\n' "${RESULT_KV[checkpoint_wait_s]:-na}"
		printf 'criu_version=%s\n' "${RESULT_KV[criu_version]:-na}"
		printf 'criu_patch_sha=%s\n' "${RESULT_KV[criu_patch_sha]:-na}"
		# CRIU fault-injection 스위치(기기 속성 — 예: RPi compat의 PAGEMAP_SCAN 우회 135).
		# CRIU 동작 경로를 바꾸는 조건이므로 정직하게 기록한다(additive — 기존 키/순서 불변).
		printf 'criu_fault=%s\n' "${RESULT_KV[criu_fault]:-na}"
		printf 'resident_mismatch=%s\n' "${RESULT_KV[resident_mismatch]:-na}"
		printf 'resident_rss_bytes=%s\n' "${RESULT_KV[resident_rss_bytes]:-na}"
		# --- wl_* (워크로드 매니페스트 metrics). WL_METRICS의 각 이름 m에 대해
		#     result_set "wl_$m" "$(wl_kv "$m")"은 호출자(러너)가 수행 — 여기서는 순서대로 방출만.
		# shellcheck disable=SC2086,SC2153
		for m in ${WL_METRICS:-}; do
			printf 'wl_%s=%s\n' "$m" "${RESULT_KV["wl_$m"]:-na}"
		done
		# wl_param_* (병합된 workload 파라미터, hardening v2 §3). WL_METRICS 방출과 동형이되,
		# 값은 RESULT_KV가 아니라 config_to_env.py가 config.env로 방출한 WL_PARAM_<대문자> 셸 변수를
		# 간접 확장(${!var})으로 직접 읽는다 — 파라미터는 런타임 관측치가 아니라 정적 설정값이라
		# 러너가 RESULT_KV에 seed할 필요가 없다(additive-only, 기존 키/순서 무변). WL_PARAM_KEYS의
		# 정렬 순서(config_to_env sorted) 그대로 방출.
		# shellcheck disable=SC2086,SC2153
		for p in ${WL_PARAM_KEYS:-}; do
			p_ref="WL_PARAM_${p^^}"
			printf 'wl_param_%s=%s\n' "$p" "${!p_ref:-na}"
		done
		# 시점별 memstat_*/meminfo_* 스냅샷 fragment — old처럼 끝에 cat (append-only; 기존 키 불변)
		cat "$MEM_TIMELINE" 2>/dev/null || true
	} > "$f.tmp" && mv "$f.tmp" "$f"
	# ↑ 원자적 교체(감사 구멍 2): 직접 `> $f`로 쓰면 timeout의 최종 SIGKILL이 쓰기 도중에
	# 꽂혔을 때 `result=PASS` 줄까지만 있는 partial 파일이 남고, collect.py가 그걸 정상 행으로
	# 편입한다(행 수는 맞아 finalize count 가드도 통과). tmp에 다 쓴 뒤 같은 fs 안 rename이라
	# result.env는 "완전한 파일" 아니면 "없음" 두 상태만 가진다. 잘린 .tmp 잔재는 무해 —
	# collect는 */result.env만 읽고, run_one이 런 시작 전 result.env를 지울 때 같이 안 지워져도
	# 다음 result_write가 덮어쓴다.
}
