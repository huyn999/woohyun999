#!/usr/bin/env bash
# runner/run_once.sh — restore(dump/restore) 경로 오케스트레이터 (재작성판)
# 측정 정의: restore_response = criu restore 명령 시작(RESTORE_START_TS) → 복원된 서비스의 첫 PONG
#            (old run_once.sh:828-844 기준점 정의와 동일 — RESTORE_START가 기준점). lib/probe.sh 측정 창.
# 이식 소스: testbed_old/runner/run_once.sh (dump/restore/kdat/cache 블록). 구조 참고: runner/run_cold_start.sh.
#
# errexit(-e)를 쓰지 않는다: old run_once.sh(이 파일의 이식 소스)와 동일한 `set -uo pipefail`이다.
# 이유는 step_restore_and_probe의 verbatim 측정 창(§6-1~2) — criu restore가 비정상 종료해도 그
# 실패가 창 밖의 "no response after restore" 가드로 흘러 FAIL result.env를 쓰게 하려면 그 한 줄에서
# errexit로 즉시 abort하면 안 된다(그러면 result.env 없이 조용히 죽는다). cold(run_cold_start.sh)는
# 창이 wl_launch 백그라운드라 실패가 없어 -e를 쓰지만, 여기선 창이 foreground criu라 -uo가 맞다.
# 그 대신 인프라 단계(env setup/verify, stress)는 old처럼 명시적 `|| { result_write FAIL; exit 1; }`로 가드한다.
set -uo pipefail
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

# RESTORE_GAP_S: dump 완료 후 restore 시작 전의 실험적 간격. dump_time/restore_time에는 포함되지 않는다.
# 새 YAML 스키마엔 후속 키가 없어(§controller ④) old 기본값을 in-file 상수로 이식한다.
# 출처: testbed_old/runner/run_once.sh:35  RESTORE_GAP_S="2.0"
RESTORE_GAP_S="2.0"

# ---- restore 고유 in-file steps ----

# NOTE(바이너리 배치는 cold 전용): 스펙 §5 모듈 경계 원칙 1(design doc:296-298)이
# `prepare_target_binary_on_constrained_storage`를 cold 전용 in-file 함수로 명시하고,
# run_once 고유 단계 목록(design doc:304)에도 배치가 없다. old run_once도 host fs의
# TARGET_BIN을 직접 exec한다(testbed_old/runner/run_once.sh:312-322 TARGET_BIN 조립,
# :565 exec "$TARGET_BIN"). 이전 판(step_place_binary, IMAGE_DIR/app co-locate)은 이
# 근거를 놓친 오독이었다 — 배치된 사본을 dump하면 그 exe 매핑이 제약 스토리지(dm-delay)를
# 가리켜 restore가 페이지를 그 위에서 채워야 하므로 restore_response가 old 대비 부풀고
# Task 20 cold/restore 대응 비교의 패리티가 깨진다(리뷰 라운드 1 Fix 1). config_to_env.py가
# 방출하는 WL_BIN(=$TESTBED_DIR/workloads/bin/$WL_NAME, host fs)을 그대로 wl_launch가 exec한다
# — 이 러너 파일엔 별도 배치 step이 없다.

# 이식: testbed_old/runner/run_once.sh:624-647 warm-up 요청 블록.
# request_probe.py 호출을 "$PROBE_CPROBE" 127.0.0.1 "$WL_PORT"로, 1회 warm-up을 CFG_WARMUP_PINGS
# 루프로 확장(§4-A6 warm 의미론 — dump가 복원하는 상태를 "첫 요청까지 끝낸 service-ready warm 상태"로
# 정의; 첫 성공 요청이 워크로드의 PHASE served_first를 촉발한다). 측정 제외.
step_warmup_pings() {
	local n="${CFG_WARMUP_PINGS:-1}"
	if [[ -z "$WL_PORT" || "$WL_PORT" == "0" ]]; then
		echo "[warmup] skipped (workload has no service port)"
		return 0
	fi
	local ping ok
	for ((ping = 1; ping <= n; ping++)); do
		ok=""
		for _ in $(seq 1 600); do
			kill -0 "$WL_PID" 2>/dev/null || { result_write FAIL "target died before warm-up ping $ping"; exit 1; }
			if "$PROBE_CPROBE" 127.0.0.1 "$WL_PORT" >/dev/null 2>&1; then ok=1; break; fi
			sleep 0.005
		done
		[[ -n "$ok" ]] || { result_write FAIL "warm-up ping $ping got no response (port $WL_PORT)"; exit 1; }
	done
	echo "[warmup] $n ping(s) OK on port $WL_PORT (excluded from timing)"
}

dump_is_pre_ready() {
	local ph
	[[ "$CFG_DUMP_AT" != "ready" ]] || return 1
	for ph in $WL_PHASES; do
		[[ "$ph" == "ready" ]] && break
		[[ "$ph" == "$CFG_DUMP_AT" ]] && return 0
	done
	return 1
}

# 이식: testbed_old/runner/run_once.sh:649-704 (checkpoint 대기 + quiesce + criu dump + image size + restore gap).
# criu → "$CRIU_BIN". 러너 자신이 이미 cgroup_join_self로 대상 cgroup에 있으므로 criu(자식)도 그
# 예산 안에서 실행된다 — old가 dump를 subshell에서 join한 이유(critical-path membership scan 회피)를
# 새 아키텍처는 lib/cgroup.sh의 사전 join으로 대체했다.
step_quiesce_and_dump() {
	# quiesce: warm-up 요청은 cprobe가 요청당 즉시 close하므로(probe_server.h probe_serve_pending),
	# 이어지는 checkpoint_after_s idle 구간이면 dump 시점에 워크로드엔 established 연결 없이 listen
	# 소켓만 남는다(old run_once.sh:624-627 설계 주석) — CRIU가 깨끗하게 dump한다.
	# 단 pre-ready dump(§4-A6)는 소켓·연결이 아예 없어 quiesce가 무의미하고, 기다리는 동안
	# 워크로드가 phase를 지나쳐 버려 at-or-after 스큐만 키운다 → 생략하고 즉시 dump.
	if ((${dump_pre_ready:-0})); then
		result_set checkpoint_wait_s 0    # 실제 대기(조건 echo인 checkpoint_after_s와 별개)
		echo "checkpoint wait: skipped (pre-ready dump — no connection to quiesce, dump close to phase)"
	else
		result_set checkpoint_wait_s "$CFG_CHECKPOINT_AFTER_S"
		echo "checkpoint wait: ${CFG_CHECKPOINT_AFTER_S}s (idle after warm-up; closes warm-up connection before dump)"
		sleep "$CFG_CHECKPOINT_AFTER_S"
	fi
	kill -0 "$WL_PID" 2>/dev/null || { result_write FAIL "target died before dump"; exit 1; }

	# storage 비활성 시(env/hardware/storage.sh가 mkdir -p만 해둔 일반 디렉터리) 같은 run_id를
	# 재실행하면 이전 런의 *.img가 남아있을 수 있다 — image_size_bytes/이어지는 fadvise가 이번
	# 런의 이미지가 아닌 잔재까지 세게 만든다. dump 직전(측정 창 밖)에 걷어낸다.
	rm -f "${IMAGE_DIR:?}"/*.img

	echo "=== criu dump ==="
	# 시간 정의: CRIU dump 명령 시작~종료 (old TIMEFORMAT=%R). criu 자신도 임베디드 제약을 받아야 하므로
	# target/stress와 같은 cgroup에서 실행한다(러너가 이미 그 cgroup 멤버 → 자식 criu도 그 안).
	# subshell로 감싸는 이유: WL_PID는 메인 셸의 백그라운드 job이라 criu가 dump 중 그것을 죽이면
	# 메인 셸이 "Killed" job-control 메시지를 stderr로 찍는다. dump.wall_s(%R) 리다이렉트를 메인 셸에서
	# 직접 걸면 그 메시지가 wall_s를 오염시킨다(실측). subshell의 fd2만 wall_s로 돌리면 job은
	# 부모(메인 셸) 소유라 그 메시지가 wall_s에 섞이지 않는다 (old run_once.sh:662-676 구조 계승).
	if (
		TIMEFORMAT=%R
		{ time "$CRIU_BIN" dump \
			-t "$WL_PID" \
			-D "$IMAGE_DIR" \
			--shell-job \
			-v4 -o "$RUN_DIR/dump.log" \
			2>"$RUN_DIR/dump.stderr" ; } 2>"$RUN_DIR/dump.wall_s"
	)
	then
		local dump_time; dump_time="$(cat "$RUN_DIR/dump.wall_s" 2>/dev/null || echo unknown)"
		[[ -n "$dump_time" ]] || dump_time="unknown"
		result_set dump_time_s "$dump_time"
		# bytes 단위 image 크기 — teardown unmount 전이라 지금 떠야 한다.
		result_set image_size_bytes "$(du -sb "$IMAGE_DIR" 2>/dev/null | cut -f1)"
		# 렌즈4 F3: 실제 경로를 남겨 사후 분석에서 -v4 로그를 바로 열 수 있게 한다(창 밖 bookkeeping).
		result_set criu_dump_log "$RUN_DIR/dump.log"
		echo "dump OK (${dump_time}s), image: $(du -sh "$IMAGE_DIR" 2>/dev/null | cut -f1)"
	else
		echo "--- dump.log (tail) ---" >&2
		tail -30 "$RUN_DIR/dump.log" >&2 2>/dev/null || true
		result_write FAIL "criu dump failed"; exit 1
	fi

	# CRIU dump 성공 시 target은 종료됨 (default; no --leave-running)
	sleep 0.2
	if kill -0 "$WL_PID" 2>/dev/null; then
		echo "WARN: target still alive after dump? killing"
		kill -KILL "$WL_PID" 2>/dev/null || true
	fi
	# F2: pre-ready dump이 seize 창보다 짧은 init을 조용히 놓쳤는지 탐지 (물리 한계 — 제거 불가, 정직 기록).
	# criu dump 기동(kerndat+seize; warm-kdat ~4ms/cold ~50ms — F1 수정으로 축별 결정적) 동안 타깃이
	# 계속 달리므로, seize 지연보다 짧은 init phase는 dump 시점에 이미 ready를 지나 있을 수 있다 —
	# 라벨은 pre-ready(예: initburst의 init)인데 실제 freeze는 at-ready. 판정은 dump 직후·restore 전
	# (창 밖)의 WL_LOG 내용 기준이어야 한다: restore 후 워크로드가 재발행하는 PHASE 줄과 섞이면 오탐이라
	# 반드시 지금(freeze 상태)에 본다. grep은 창 밖. 비-pre-ready 런은 na가 아니라 0으로 기록한다.
	local dump_phase_missed=0
	if ((${dump_pre_ready:-0})) && grep -qE "^PHASE ready([[:space:]]|\$)" "$WL_LOG" 2>/dev/null; then
		dump_phase_missed=1
		echo "[dump] WARN: pre-ready dump reached 'PHASE ready' before freeze — init shorter than seize window; dump_phase_missed=1"
	fi
	result_set dump_phase_missed "$dump_phase_missed"

	# NOTE: old는 DUMPED_TARGET_PID로 restore 중 task-visible(PID가 cgroup에 처음 보인 시점)을
	# 폴링했지만, 새 설계는 RESTORED_PID를 restore -d의 --pidfile에서 읽고 task-visible 폴링을
	# 측정 창에서 제거했다(§6-1~2 창 내 추가 폴링 금지) — dumped-pid 별도 보관이 불필요해졌다.

	# dump/restore 사이의 실험적 간격 (excluded from dump/restore time).
	if awk "BEGIN{exit !($RESTORE_GAP_S > 0)}"; then
		echo "restore gap: sleeping ${RESTORE_GAP_S}s before restore"
		sleep "$RESTORE_GAP_S"
	fi
	result_set restore_gap_s "$RESTORE_GAP_S"
}

# 이식: testbed_old/runner/run_once.sh:706-722 (drop_caches best_effort_cold_cache) + fadvise_restore_image_files.
# cache_policy 분기는 새 run_cold_start.sh:47-70 step_drop_caches와 동일 패턴(알려진 정책만 수행,
# 그 외 값은 조용히 무시하지 않고 크게 실패). 그 뒤 image 파일 단위 fadvise(DONTNEED)까지 이어 붙인다.
step_cache_policy() {
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

	# 이식: testbed_old/runner/run_once.sh:367-383 fadvise_restore_image_files (inline; 단일 호출자 — no premature extraction).
	local image_file_count
	image_file_count="$(find "$IMAGE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$image_file_count" == "0" ]]; then
		echo "[restore] WARN: no image files found for fadvise" >&2
	else
		sync "$IMAGE_DIR" 2>/dev/null || sync
		if find "$IMAGE_DIR" -type f -print0 \
			| xargs -0 "$SCRIPT_DIR/fadvise_dontneed.py" 2>"$RUN_DIR/fadvise_restore.log"; then
			echo "[restore] fadvise DONTNEED applied to $image_file_count image files"
		else
			echo "[restore] WARN: fadvise DONTNEED failed; see $RUN_DIR/fadvise_restore.log" >&2
		fi
	fi
}

# F1: kdat 축을 "런 전체"에 일관 적용 — dump까지 포함해 런 독립성 확보.
# 문제(실증): step_kdat_control은 dump *후*·restore 직전에만 kdat 상태를 맞춘다. 그래서 이 런의
# dump는 직전 런이 남긴 /dev/shm/criu.kdat 상태(koff→삭제됨/kon→보존됨)를 그대로 물려받는다 —
# dump_time_s가 이웃 런의 kdat 축에 따라 ±33ms 계통 편향되고 criu seize 시점도 4~50ms 출렁인다
# (런 간 전역 상태 누수). 해법: target 기동 *전*(측정과 무관한 초기 구간)에 이 런의 kdat 상태를
# 이 런의 축으로 먼저 확정한다. 그러면 같은 런 안에서 dump와 restore가 동일한 kdat 상태(off=cold,
# on=warm)를 보게 되어 이웃 런과의 결합이 끊긴다. restore 직전 step_kdat_control은 그대로 유지한다
# — off는 dump가 파일을 재생성하므로 restore 전 재삭제가 여전히 필요하고, on은 이미 warm이면 skip한다.
step_kdat_init() {
	# kdat 캐시 경로는 기기 속성(scenario criu.kdat_file): 기본 /dev/shm(kdat-shm 패치 빌드,
	# Docker/overlayfs-/run 땜빵), 실호스트+stock CRIU는 /run/criu.kdat을 지정(패치 불필요).
	local kdat_file="${CFG_KDAT_FILE:-/dev/shm/criu.kdat}"
	local kdat_dir; kdat_dir="$(dirname "$kdat_file")"
	case "${CFG_KDAT_CACHE:-off}" in
		off|OFF|false|no|0)
			# 무패치(stock) CRIU는 캐시를 /run/criu.kdat에 둔다 — 교체 CRIU(예: RPi의 32-bit
			# 빌드)가 패치 없이 오면 /dev/shm만 지워선 off가 조용히 warm-kdat으로 오염된다
			# (직전 런이 남긴 stock 캐시를 재사용). 두 경로 모두 지워 어떤 빌드든 off =
			# cold-kdat을 보증한다(패치 빌드에선 /run 쪽 rm이 no-op).
			rm -f "$kdat_file" /run/criu.kdat 2>/dev/null || true
			echo "[kdat] init OFF: removed $kdat_file (+stock /run/criu.kdat) before target launch (dump starts cold-kdat)"
			;;
		on|ON|true|yes|1)
			if [[ "$(stat -fc %T "$kdat_dir" 2>/dev/null)" != "tmpfs" ]]; then
				result_write FAIL "kdat_cache=on requires $kdat_dir to be tmpfs (got: $(stat -fc %T "$kdat_dir" 2>/dev/null)); CRIU won't persist the cache otherwise"
				exit 1
			fi
			if [[ -f "$kdat_file" ]]; then
				echo "[kdat] init ON: $kdat_file already warm — skip criu check (dump starts warm-kdat)"
			else
				"$CRIU_BIN" check >/dev/null 2>&1 || true   # 한 번 probe시켜 캐시를 채운다
				if [[ ! -f "$kdat_file" ]]; then
					result_write FAIL "kdat_cache=on: $kdat_file was not created by warm-up (init)"
					exit 1
				fi
				echo "[kdat] init ON: warmed $kdat_file before target launch (dump starts warm-kdat)"
			fi
			;;
		*)
			result_write FAIL "invalid criu.kdat_cache: '$CFG_KDAT_CACHE' (expected on|off)"
			exit 2
			;;
	esac
}

# 이식: testbed_old/runner/run_once.sh:724-757 kdat(kerndat) 캐시 제어.
# CRIU_KDAT_CACHE→CFG_KDAT_CACHE. off=restore마다 kernel 재probe(고정비용 포함), on=캐시 재사용(생략).
# on은 캐시 경로가 tmpfs일 때만 (CRIU가 non-tmpfs엔 보존 거부). 이 샌드박스는 CRIU 빌드를 패치해
# 캐시 경로를 /dev/shm(tmpfs)로 옮겼다(criu/kdat-shm.patch). dump가 캐시를 만들었을 수 있으니
# restore 직전에 상태를 맞춘다(off면 삭제해 재probe 강제, on이면 warm 보존). warm/rm은 측정 밖.
# F1: kdat 축은 step_kdat_init이 이미 target 기동 전에 이 런의 축으로 확정했다 — 여기선 그 상태를
# restore 직전에 재확정만 한다(off는 dump가 재생성했을 수 있어 다시 삭제, on은 이미 warm이면 skip).
step_kdat_control() {
	local kdat_file="${CFG_KDAT_FILE:-/dev/shm/criu.kdat}"   # step_kdat_init과 동일 규칙
	local kdat_dir; kdat_dir="$(dirname "$kdat_file")"
	case "${CFG_KDAT_CACHE:-off}" in
		off|OFF|false|no|0)
			# step_kdat_init과 동일하게 stock 경로(/run/criu.kdat)도 지운다 — dump가 재생성한
			# 캐시가 어느 경로에 있든 restore는 cold-kdat으로 시작해야 off 라벨이 정직하다.
			rm -f "$kdat_file" /run/criu.kdat 2>/dev/null || true
			echo "[kdat] OFF: removed $kdat_file (+stock /run/criu.kdat) (restore re-probes kerndat)"
			;;
		on|ON|true|yes|1)
			if [[ "$(stat -fc %T "$kdat_dir" 2>/dev/null)" != "tmpfs" ]]; then
				result_write FAIL "kdat_cache=on requires $kdat_dir to be tmpfs (got: $(stat -fc %T "$kdat_dir" 2>/dev/null)); CRIU won't persist the cache otherwise"
				exit 1
			fi
			# F1: step_kdat_init이 기동 전 이미 워밍했고 dump가 그 캐시를 보존/재생성하므로 보통 여기선
			# 이미 존재한다 — 중복 criu check를 피한다(비용 절약·probe 중복 방지). 없을 때만 다시 워밍.
			if [[ -f "$kdat_file" ]]; then
				echo "[kdat] ON: $kdat_file already warm (kept from init/dump) — restore reuses cached kerndat"
			else
				"$CRIU_BIN" check >/dev/null 2>&1 || true   # 한 번 probe시켜 캐시를 채운다
				if [[ ! -f "$kdat_file" ]]; then
					result_write FAIL "kdat_cache=on: $kdat_file was not created after warm-up"
					exit 1
				fi
				echo "[kdat] ON: warmed $kdat_file (restore reuses cached kerndat)"
			fi
			;;
		*)
			result_write FAIL "invalid criu.kdat_cache: '$CFG_KDAT_CACHE' (expected on|off)"
			exit 2
			;;
	esac
	result_set kdat_cache "$CFG_KDAT_CACHE"
}

step_restore_and_probe() {
	local pidfile="$RUN_DIR/restored.pid"
	# criu restore --pidfile은 기존 파일을 덮어쓰지 않고 실패한다("File exists") — 같은 run-id 재실행
	# 흔적을 창 진입 전에 지운다(측정 창 밖, RESTORE_START_TS 이전이라 §6-1~2 무관).
	rm -f "$pidfile"
	echo "=== criu restore ==="
	# criu restore가 비정상 종료해도(예: OOM) 창 밖 "no response after restore" 가드가 FAIL result.env를
	# 쓰도록, 측정 창 동안만 errexit를 명시적으로 유지(스크립트는 -uo라 이미 off — 방어적 재확인). set은
	# 빌트인이라 창 안 스폰 추가가 아니다(§controller ⑤). 창의 verbatim 5줄엔 코드를 더하지 않는다.
	# ---- 측정 창: 아래 블록에 코드 추가 금지 (§6-1~2) ----
	RESTORE_START_TS="$EPOCHREALTIME"
	"$CRIU_BIN" restore -d --pidfile "$pidfile" -D "$IMAGE_DIR" --shell-job -v4 -o "$RUN_DIR/restore.log" 2>"$RUN_DIR/restore.stderr"
	local criu_rc=$?   # 빌트인 $? 캡처(스폰 아님) — §6-1 "창 안 외부 프로세스 스폰 0개" 그대로 유지
	RESTORE_END_TS="$EPOCHREALTIME"
	RESTORED_PID="$(< "$pidfile")"
	probe_first_response "$RESTORED_PID" "$WL_PORT" "${RESTORE_TIMEOUT_S:-120}"
	# ---- 창 밖 ----
	snap_take after_restore
	# 렌즈4 F3: 실제 경로를 남겨 사후 분석에서 -v4 로그를 바로 열 수 있게 한다(창 밖 bookkeeping).
	result_set criu_restore_log "$RUN_DIR/restore.log"
	result_set restore_cmd_s "$(awk "BEGIN{print $RESTORE_END_TS - $RESTORE_START_TS}")"
	# criu 자체의 비정상 종료(exit≠0 또는 --pidfile 미기록)와 "criu는 끝났지만 워크로드가 응답 안 함"을
	# 구분한다 (old:820-824 FAIL_REASON="criu restore did not finish successfully (outcome=...)" —
	# 리뷰 라운드 1 Fix 3). "no response after restore"는 criu 성공 후 probe 실패 전용으로 좁힌다.
	if [[ "$criu_rc" -ne 0 || -z "$RESTORED_PID" ]]; then
		result_write FAIL "criu restore did not finish successfully (exit=$criu_rc, pidfile=${RESTORED_PID:-empty})"
		exit 1
	fi
	# shellcheck disable=SC2015  # 브리프 verbatim 가드: B(result_set)는 항상 성공하므로 C는 A가 false일 때만 실행
	[[ -n "$PROBE_OK" ]] \
		&& result_set restore_response_s "$(awk "BEGIN{print $PROBE_RESP_TS - $RESTORE_START_TS}")" \
		|| { result_write FAIL "no response after restore"; exit 1; }
	echo "restore response OK ($(awk "BEGIN{print $PROBE_RESP_TS - $RESTORE_START_TS}")s; restored_pid=$RESTORED_PID)"
}

# 이식: testbed_old/runner/run_once.sh:869-891 restore -v4 로그 분해 (창 밖, §6-9).
#   kerndat probing = criu start ~ "Reading image tree" (probing 종료·실제 restore 시작; version-stable)
#   restore work    = "Reading image tree" ~ "Restore finished successfully" (page-in + resume)
#   launch overhead = wall restore_cmd - criu 내부 total (fork+exec+observe)
# old의 RESTORE_LATENCY(criu 완료까지 wall)는 새 창에선 restore_cmd = RESTORE_END_TS - RESTORE_START_TS
# (criu restore -d가 완료까지 block 후 종료하므로 명령 wall = 완료 wall). 이를 restore_time_s로 확정.
step_decompose_restore_log() {
	local restore_cmd; restore_cmd="$(awk "BEGIN{print $RESTORE_END_TS - $RESTORE_START_TS}")"
	result_set restore_time_s "$restore_cmd"
	local phases probing_end criu_total
	phases="$(awk '
		{ ts = substr($0, 2, index($0, ")") - 2) + 0
		  if ($0 ~ /Reading image tree/ && pe == "") pe = ts
		  if ($0 ~ /Restore finished successfully/) fin = ts }
		END { printf "%s|%s", (pe == "" ? "na" : pe), (fin == "" ? "na" : fin) }
	' "$RUN_DIR/restore.log" 2>/dev/null)"
	probing_end="${phases%%|*}"; criu_total="${phases##*|}"
	if [[ "$probing_end" != "na" && "$criu_total" != "na" ]]; then
		result_set kdat_probing_s "$probing_end"
		result_set restore_work_s "$(awk "BEGIN{print $criu_total - $probing_end}")"
		result_set launch_overhead_s "$(awk "BEGIN{v=$restore_cmd - $criu_total; print (v < 0 ? 0 : v)}")"
		echo "  decompose: kerndat_probing=${probing_end}s  restore_work=$(awk "BEGIN{print $criu_total - $probing_end}")s"
	else
		echo "  decompose: WARN restore.log phase markers not found; skipping decomposition" >&2
	fi
}

# 이식: testbed_old/runner/run_once.sh:893-912 §7 generic recovery 중 membership(L2) 검증만.
# liveness/기능 검증은 probe의 PONG이 이미 증명하므로 버린다(스펙 §3 '버릴 것'). 사다리 결과에 따라
# generic_recovery yes|no를 명시적으로 확정한다(§controller ② — na 방치 금지).
step_verify_recovery() {
	if "$TESTBED_DIR/env/verify.sh" "$RUN_DIR" membership "restored target" "$RESTORED_PID"; then
		result_set generic_recovery yes
	else
		result_set generic_recovery no
		result_write FAIL "restored target is not in cgroup (membership)"; exit 1
	fi
}

step_resident_check() {   # 선언 정직성 (§4-B): restore 쪽은 RESTORED_PID를 본다.
	local rss_kb; rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/$RESTORED_PID/status" 2>/dev/null || echo 0)"
	local mism
	# 렌즈4 F6: restore 직후 RSS는 CRIU의 lazy fault-in(페이지가 restore 시점에 한 번에 매핑되지
	# 않고 접근 시 fault-in) 때문에 선언값(WL_RESIDENT_BYTES) **미만이 정상**이다 — cold(위
	# run_cold_start.sh)처럼 프로세스가 직접 그 바이트를 만들어 즉시 상주시키는 경로와 다르다.
	# 그래서 여기는 편도(one-sided) 가드: 초과만 이상 신호로 본다. 문턱은 cold와 동일하게
	# max(10%, 절대 4MiB) — 상대 10%만으로는 MiB급 소형 선언에서 고정 잡음이 상시 오탐을
	# 만든다(근거는 run_cold_start.sh step_resident_check 주석).
	if (( ${WL_RESIDENT_BYTES:-0} > 0 )); then
		mism="$(awk "BEGIN{d=$rss_kb*1024-$WL_RESIDENT_BYTES; tol=$WL_RESIDENT_BYTES*0.1; if(tol<4194304)tol=4194304; print (d>tol)?1:0}")"
	else
		mism=na   # 선언 상주량이 0이면 나눗셈 스킵 (§controller ③)
	fi
	result_set resident_rss_bytes "$((rss_kb * 1024))"
	result_set resident_mismatch "$mism"
}

main() {
	local run_id="" cfg="" kdat_override=""
	while (($#)); do case "$1" in
		--run-id) run_id="$2"; shift 2 ;;
		--config) cfg="$2"; shift 2 ;;
		--kdat-cache) kdat_override="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac; done
	config_load "$run_id" "$cfg"
	# --kdat-cache가 config.env의 CFG_KDAT_CACHE를 override (config_load 이후에 적용)
	[[ -n "$kdat_override" ]] && CFG_KDAT_CACHE="$kdat_override"
	config_seed_result_meta      # 조건 메타(memory_max/workload/stress_* 등) RESULT_KV seed (리뷰 R1 Fix 2)

	CRIU_BIN="${CRIU_BIN:-$TESTBED_DIR/criu/bin/criu}"
	[[ -x "$CRIU_BIN" ]] || { echo "ERROR: $CRIU_BIN 없음 — testbed/criu/build.sh 먼저 실행 (§6-18)" >&2; exit 1; }
	# CRIU fault-injection 스위치(기기 속성, scenario criu.fault — 예: RPi 135 = compat에서
	# 깨지는 PAGEMAP_SCAN ioctl을 고전 pagemap 경로로 우회). 여기서 export하면 이 런의 모든
	# criu 자식(kdat warm의 check, dump, restore)에 일관 적용된다. 미설정이면 건드리지 않는다.
	[[ -n "${CFG_CRIU_FAULT:-}" ]] && export CRIU_FAULT="$CFG_CRIU_FAULT"
	result_set runner restore
	result_set dump_phase "$CFG_DUMP_AT"
	local dump_pre_ready=0
	# warmup_pings/checkpoint_after_s는 config echo(조건 메타 — config_seed_result_meta가 이미
	# seed)로 남기고, 실제 동작은 warmup_pings_sent/checkpoint_wait_s에 기록한다. 이전엔
	# pre-ready에서 이 두 키를 실제값 0으로 덮어써서, cold(조건 echo)와 페어링 키가 어긋나
	# dump_at 혼합 캠페인의 pre-ready 페어가 전부 탈락했다(Codex 라운드2 교차검토 — 합성 CSV
	# 재현: 순수 pre-ready는 compare die, 혼합은 init 페어만 조용히 증발). "핑을 안 보냈음을
	# 정직하게 기록"(F7)은 *_sent 키가 승계한다.
	if dump_is_pre_ready; then
		dump_pre_ready=1
		result_set warmup_pings_sent 0        # 실제로 핑을 안 보냈음 (정직 기록)
		result_set checkpoint_wait_s 0
	else
		result_set warmup_pings_sent "$CFG_WARMUP_PINGS"
		result_set checkpoint_wait_s "$CFG_CHECKPOINT_AFTER_S"
	fi
	result_set cache_policy "${CFG_CACHE_POLICY:-best_effort_cold_cache}"
	result_set criu_version "$("$CRIU_BIN" --version | head -1)"
	result_set criu_patch_sha "$(sha256sum "$TESTBED_DIR/criu/kdat-shm.patch" | cut -c1-12)"
	cleanup_install_trap
	# I1: setup 호출보다 먼저 등록 — setup이 cgroup/loop/dm/cpufreq clamp를 일부만 만든 채
	# 실패해도(예: memory.max delegate 실패, storage mkfs 실패) EXIT trap이 teardown을 반드시
	# 태워 그 잔여물을 걷어내게 한다. teardown.sh(및 하위 hardware/*.sh)는 미생성 상태에서도
	# -d/-f 가드와 `|| true`로 안전하게 no-op하도록 이미 작성돼 있다(위 각 스크립트 확인).
	cleanup_register env_teardown
	"$TESTBED_DIR/env/setup.sh" "$RUN_DIR" || { result_write FAIL "env setup failed"; exit 1; }
	# shellcheck source=/dev/null
	source "$RUN_DIR/state.env"   # env/setup.sh가 떠둔 IMAGE_DIR(storage.sh 핸드오프) — dump/cache_policy/restore가 소비.
	# (예전엔 step_place_binary가 이 source를 겸했으나 그 step은 리뷰 R1 Fix 1로 제거됐다 — 배치 없이도
	# IMAGE_DIR 자체는 dump -D/restore -D/이미지 fadvise/image_size_bytes 계산에 여전히 필요하다.)
	"$TESTBED_DIR/env/verify.sh" "$RUN_DIR" || { result_write FAIL "env verify failed"; exit 1; }
	cgroup_join_self || { result_write FAIL "cgroup join failed"; exit 1; }
	# F1: kdat 상태를 target 기동 *전*(측정과 무관한 초기 구간)에 이 런의 축으로 확정한다 — dump가
	# 직전 런의 kdat 상태를 물려받아 dump_time_s가 이웃 축에 계통 편향되는 런-간 누수를 끊는다
	# (근거는 step_kdat_init 헤더 주석). restore 직전 step_kdat_control과 함께 dump·restore가 같은
	# kdat 상태를 보게 만든다. cleanup trap(위)이 이미 걸려 있어 on의 tmpfs FAIL도 teardown을 태운다.
	step_kdat_init
	# 이식: testbed_old/runner/run_once.sh:518-520 (setup+verify 직후·부하 전 baseline —
	# old MEM_CURRENT_BEFORE와 같은 시점). 스모크 회귀 리포트(Task 18 §b) Fix 1: 브리프의
	# snap_take 호출 목록에서 빠졌던 시점을 old 진실대로 복원.
	snap_take before_stress
	# 이식: testbed_old/runner/run_once.sh:522-528 "2. membership preflight" (env verify 후·stress
	# 시작 전, old 호출 위치 그대로). 캐노리(join_current_process_to_cgroup으로 join하는 sleep
	# 서브셸)로 cgroup-join 메커니즘 자체를 실제 target/stress 기동보다 먼저 값싸게 검증한다
	# (§6-16 검증 사다리 2번째 룽 — invariant audit FAIL 수정. old는 두 러너 모두 호출했다).
	"$TESTBED_DIR/env/verify.sh" "$RUN_DIR" preflight || { result_write FAIL "canary preflight failed"; exit 1; }
	# C1: `stress_start_verified && cleanup_register stress_stop`에서 A(start_verified)가 실패하면
	# `&&`가 B(등록)만 건너뛸 뿐 문(statement) 자체는 비-zero로 조용히 끝나고 다음 줄로 흘러간다
	# (bash: `set -e`에서도 `A && B`의 A 실패는 exit를 유발하지 않는다 — 실측 확인) → stress가
	# 죽었는데도 무압박 상태로 런이 계속돼 PASS로 기록될 수 있다(§6-16 위반). 등록은 stress.sh
	# 계약대로 무조건 먼저 한다 — stress/stop.sh는 pids 파일이 없으면 no-op이라 enabled=false에서도,
	# start 실패로 pids가 안 쓰였어도 안전하다.
	cleanup_register stress_stop
	stress_start_verified || { result_write FAIL "stress start/verify failed"; exit 1; }
	stress_warmup; snap_take after_stress_warmup
	wl_launch                    # host fs의 WL_BIN을 그대로 exec (배치는 cold 전용, §5)
	result_set target_log "$WL_LOG"   # 렌즈4 F3: 실제 경로 기록 (창 밖, wl_launch 직후 bookkeeping)
	# pre-ready dump 판정 (§4-A6): manifest phases(WL_PHASES, 선언 순서 보존)에서 dump_at이
	# ready보다 앞이면 소켓이 열리기 전 상태를 dump하는 실험이다 — ready 대기와 warm-up ping
	# (소켓이 없어 불가능)을 건너뛰고 dump_at을 직접 기다린다. restore 후 first-response에는
	# 잔여 init 비용이 포함된다(버그가 아니라 측정 대상). wl_* 메트릭은 ready 미도달이라 na.
	if ((dump_pre_ready)); then
		echo "pre-ready dump: dump_at='$CFG_DUMP_AT' < ready — ready 대기·warm-up ping 생략 (§4-A6)"
		wl_wait_phase "$CFG_DUMP_AT" "${DUMP_AT_TIMEOUT_S:-60}" || { result_write FAIL "dump_at phase not reached"; exit 1; }
	else
		wl_wait_phase ready "${READY_TIMEOUT_S:-60}" || { result_write FAIL "target not ready"; exit 1; }
		# I2: restore 경로도 cold(run_cold_start.sh:137)와 동형으로 wl_* 메트릭을 기록한다 — 다음 줄의
		# dump_at 대기(wl_wait_phase)가 WL_PHASE_LINE을 그 phase 줄로 덮어쓰기 전, ready phase 줄이
		# 아직 살아있는 지금 뽑아야 한다.
		local m; for m in $WL_METRICS; do result_set "wl_$m" "$(wl_kv "$m" || echo na)"; done
		step_warmup_pings            # CFG_WARMUP_PINGS × cprobe (측정 제외, §4-A6 warm 의미론)
		wl_wait_phase "$CFG_DUMP_AT" "${DUMP_AT_TIMEOUT_S:-60}" || { result_write FAIL "dump_at phase not reached"; exit 1; }
	fi
	step_quiesce_and_dump        # checkpoint_after_s 대기 → quiesce → criu dump (시간 기록) → restore gap
	step_cache_policy            # sync + drop_caches=3 + image fadvise (CFG_CACHE_POLICY)
	step_kdat_control            # off: rm /dev/shm/criu.kdat; on: 보존
	# 이식: testbed_old/runner/run_once.sh:770 (criu restore 직전, RESTORE_START 타이밍 시작 전 —
	# 측정 창 밖). Task 18 §b Fix 1: step_restore_and_probe(★) 진입 전, RESTORE_START_TS보다
	# 반드시 앞서야 하므로 별도 step으로 여기 둔다(§6-1~2 창 순수성 무침범).
	snap_take before_restore
	step_restore_and_probe       # ★측정 창
	step_decompose_restore_log   # -v4 awk 분해 (창 밖, §6-9)
	step_verify_recovery         # L2 membership (PONG은 probe가 이미 증명)
	step_resident_check          # 선언 정직성 (§4-B): VmRSS vs WL_RESIDENT_BYTES (bookkeeping)
	# 감사 구멍 1: 조건 보증을 측정 후에도 재확인 — stress가 런 도중 죽었으면 이 PASS는
	# 무압박 측정이라 조건 라벨이 거짓이 된다 (창 밖 bookkeeping, lib/stress.sh 주석 참고).
	stress_assert_alive || { result_write FAIL "stress died during run"; exit 1; }
	result_write PASS
}
env_teardown() { "$TESTBED_DIR/env/teardown.sh" "$RUN_DIR"; }
main "$@"
