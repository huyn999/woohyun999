#!/usr/bin/env bash
# runner/lib/config.sh — 설정 로딩 (두 러너 공용)
# uses: TESTBED_DIR (러너가 설정), RUNS_ROOT(기본 $TESTBED_DIR/runs)
# sets: RUN_ID RUN_DIR CG_PATH MEM_TIMELINE + CFG_* WL_* (config.env 경유)
config_load() {
	RUN_ID="$1"
	local yaml="$2"
	RUN_DIR="${RUNS_ROOT:-$TESTBED_DIR/runs}/$RUN_ID"
	mkdir -p "$RUN_DIR"
	# 설계 시점 검증 실패(비-0 exit)를 명시 가드 — run_once는 set -e가 아니라서 가드 없이는
	# 부분 config.env를 source하고 진행하다 나중에 unbound 크래시로 오사유가 남는다 (P1 프로브).
	"$TESTBED_DIR/runner/config_to_env.py" "$yaml" > "$RUN_DIR/config.env" || {
		echo "ERROR: config_to_env failed for '$yaml' (설계 시점 검증 실패 — stderr 참조)" >&2
		exit 1
	}
	printf "CFG_RUN_ID='%s'\n" "$RUN_ID" >> "$RUN_DIR/config.env"
	# shellcheck source=/dev/null
	source "$RUN_DIR/config.env"
	# cgroup 경로 규약: testbed_old/env/hardware/cgroup.sh와 동일 (이식 시 old의
	# 경로 조립식을 그대로 가져와 아래 한 줄을 완성한다)
	# shellcheck disable=SC2034  # CG_PATH used externally
	CG_PATH="/sys/fs/cgroup/criu_test_${RUN_ID}"
	# shellcheck disable=SC2034  # MEM_TIMELINE used externally
	MEM_TIMELINE="$RUN_DIR/mem_timeline.env"
	# 같은 run_id를 재실행하면(예: Task 20 "FAIL 원인별 재실행" 시나리오) 이전 실행이 남긴
	# 스냅샷 fragment가 append로 누적돼 result.env 끝의 memstat_*/meminfo_* 블록이 중복된다
	# (Task 18 스모크 §b "부가 관찰 2" — 실측: 3회 실행된 run_id에서 3벌 확인). 여기서 truncate해
	# 매 실행이 자기 시점만 기록하게 한다(old도 각 러너 진입부에서 `: > "$MEM_TIMELINE"`로 동일하게
	# truncate — testbed_old/runner/run_once.sh:517, run_cold_start.sh:359).
	: > "$MEM_TIMELINE" 2>/dev/null || true
}

# config_seed_result_meta — 조건 메타데이터를 RESULT_KV에 seed (리뷰 라운드 1 Fix 2).
# 이전엔 memory_max/workload/stress_enabled 등 config-echo 키가 러너가 채우지 않아 result.env에서
# 항상 na였다(Task 13 report §DONE_WITH_CONCERNS "sparse result.env"). config_load가 이미 방출한
# CFG_*/WL_* 값을 lib/result.sh 스키마의 키 이름(old 스키마, 진실)으로 그대로 옮겨 심는다.
# uses: CFG_MEMORY_MAX CFG_MEMORY_SWAP_MAX CFG_CPU_BANDWIDTH_CORES CFG_CPUSET_CPUS CFG_CPU_FREQ_KHZ
#       CFG_STORAGE_IMAGE_* CFG_STRESS_* CFG_KDAT_CACHE CFG_WARMUP_PINGS CFG_CHECKPOINT_AFTER_S
#       WL_NAME WL_PORT / sets: RESULT_KV[...]
# 값이 있는 키만 seed하고 없는 키는 건드리지 않는다(result.sh 기본값 na 유지) — config_to_env.py의
# emit()이 YAML 미지정 값은 아예 방출하지 않으므로 해당 CFG_* 변수 자체가 정의 안 될 수 있다
# (set -u 가드로 ${VAR:-} 사용).
# 호출 시점: 러너 main()에서 result 모듈 sourcing 후, config_load 다음 줄에 (두 러너 모두).
# 순서 문제 없음 확인: config.sh/result.sh 둘 다 러너 상단 for-loop에서 함수 "정의"만 되고, 그 루프가
# 전부 끝난 뒤 main()이 호출되어 이 함수 body가 실행된다 — result.sh 최상위 `declare -A RESULT_KV`는
# 이미 그 loop 중에 실행 완료돼 있으므로 RESULT_KV는 이 함수 호출 시점에 항상 존재한다.
config_seed_result_meta() {
	[[ -n "${CFG_MEMORY_MAX:-}" ]]                    && result_set memory_max "$CFG_MEMORY_MAX"
	[[ -n "${CFG_MEMORY_SWAP_MAX:-}" ]]                && result_set memory_swap_max "$CFG_MEMORY_SWAP_MAX"
	[[ -n "${CFG_CPU_BANDWIDTH_CORES:-}" ]]            && result_set cpu_bandwidth "$CFG_CPU_BANDWIDTH_CORES"
	[[ -n "${CFG_CPUSET_CPUS:-}" ]]                    && result_set cpuset_cpus "$CFG_CPUSET_CPUS"
	[[ -n "${CFG_CPU_FREQ_KHZ:-}" ]]                   && result_set cpu_freq_khz "$CFG_CPU_FREQ_KHZ"
	[[ -n "${CFG_STORAGE_IMAGE_ENABLED:-}" ]]          && result_set storage_enabled "$CFG_STORAGE_IMAGE_ENABLED"
	[[ -n "${CFG_STORAGE_IMAGE_CAPACITY:-}" ]]         && result_set storage_capacity "$CFG_STORAGE_IMAGE_CAPACITY"
	[[ -n "${CFG_STORAGE_IMAGE_RBPS:-}" ]]             && result_set storage_rbps "$CFG_STORAGE_IMAGE_RBPS"
	[[ -n "${CFG_STORAGE_IMAGE_WBPS:-}" ]]             && result_set storage_wbps "$CFG_STORAGE_IMAGE_WBPS"
	[[ -n "${CFG_STORAGE_IMAGE_DELAY_ENABLED:-}" ]]    && result_set storage_delay_enabled "$CFG_STORAGE_IMAGE_DELAY_ENABLED"
	[[ -n "${CFG_STORAGE_IMAGE_DELAY_READ_MS:-}" ]]    && result_set storage_delay_read_ms "$CFG_STORAGE_IMAGE_DELAY_READ_MS"
	[[ -n "${CFG_STORAGE_IMAGE_DELAY_WRITE_MS:-}" ]]   && result_set storage_delay_write_ms "$CFG_STORAGE_IMAGE_DELAY_WRITE_MS"
	[[ -n "${CFG_STRESS_ENABLED:-}" ]]                 && result_set stress_enabled "$CFG_STRESS_ENABLED"
	[[ -n "${CFG_STRESS_VM_WORKERS:-}" ]]              && result_set stress_vm_workers "$CFG_STRESS_VM_WORKERS"
	[[ -n "${CFG_STRESS_VM_BYTES:-}" ]]                && result_set stress_vm_bytes "$CFG_STRESS_VM_BYTES"
	[[ -n "${CFG_STRESS_CPU_SATURATE:-}" ]]            && result_set stress_cpu_saturate "$CFG_STRESS_CPU_SATURATE"
	[[ -n "${CFG_KDAT_CACHE:-}" ]]                     && result_set kdat_cache "$CFG_KDAT_CACHE"
	[[ -n "${CFG_CRIU_FAULT:-}" ]]                     && result_set criu_fault "$CFG_CRIU_FAULT"
	[[ -n "${CFG_WARMUP_PINGS:-}" ]]                   && result_set warmup_pings "$CFG_WARMUP_PINGS"
	[[ -n "${CFG_CHECKPOINT_AFTER_S:-}" ]]             && result_set checkpoint_after_s "$CFG_CHECKPOINT_AFTER_S"
	[[ -n "${WL_NAME:-}" ]]                            && result_set workload "$WL_NAME"
	[[ -n "${WL_PORT:-}" ]]                            && result_set workload_port "$WL_PORT"

	# exp_id/repeat_id — Task 18 스모크 §b Fix 3: RUN_ID의 마지막 "_repNN" 토큰에서 bash
	# 파라미터 확장으로 유도한다. expand_campaign.py의 run_name()이 `rep{NN:02d}`를 항상 마지막
	# 토큰으로 붙이고(runner/expand_campaign.py:230), summarize.py의 condition_of()가 정확히 그
	# "_repNN" 접미사만 떼어 exp_id 동등물(condition)을 만드므로(runner/summarize.py:101-104)
	# 같은 의미로 여기서도 나눈다. 그 형태가 아닌 run_id(수동 --run-id, 기본 once_<ts>/cold_<ts>
	# 등 rep 토큰이 없는 경우)는 exp_id=run_id 전체로 두고 repeat_id는 na로 남긴다.
	local _last_tok="${RUN_ID##*_}"      # 마지막 "_" 토큰, 예: "rep01"
	local _rep_num="${_last_tok#rep}"    # "rep" 접두어 제거, 예: "01" (접두어 없으면 원본 그대로)
	if [[ "$_last_tok" != "$_rep_num" && "$_rep_num" =~ ^[0-9]+$ ]]; then
		result_set repeat_id "$_rep_num"
		result_set exp_id "${RUN_ID%_*}"  # 마지막 "_repNN" 토큰 제거
	else
		result_set exp_id "$RUN_ID"
	fi

	# kernel_version — uname -r (bookkeeping, 측정 창 밖).
	result_set kernel_version "$(uname -r)"

	# probe_interval_ms/probe_timeout_s — old(testbed_old/runner/run_once.sh:82-83)와 같은 의미의
	# "설정 상수"(런마다 바뀌는 관측치가 아니다) — 채운다. 값 자체를 바꾸려면 lib/probe.sh의 폴링
	# 간격(`sleep 0.005`)과 cprobe.c의 기본 timeout_ms(300, 3번째 인자 생략 시)도 함께 바꿔야
	# 한다 — 진실은 그 두 곳에 있고, 여기는 result.env 기록용 사본이다.
	result_set probe_interval_ms 5
	result_set probe_timeout_s 0.300
	return 0
}
