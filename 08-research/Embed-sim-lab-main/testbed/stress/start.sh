#!/usr/bin/env bash
# stress/start.sh — background stress-ng를 같은 cgroup 안에서 시작
#
# stress는 하드웨어/policy 제약이 아니라 "다른 프로세스들이 자원을 점유하는 상황"이다.
# 따라서 target/CRIU와 같은 cgroup에 넣어 같은 budget 안에서 경쟁하게 한다.
#
# 메모리: 한 stress-ng 인스턴스의 --vm N 다중 worker는 메모리를 상주시키지 않으므로(실측),
#   "프로세스 N개"는 vm_workers개의 *독립 인스턴스*(각 --vm 1)로 띄운다. 인스턴스당 ~38MB
#   floor가 있어 vm_bytes는 "프로세스당 총 메모리(오버헤드 포함, >= 38M)"로 받고, 내부에서
#   floor를 빼 stress-ng의 --vm-bytes로 넘긴다.
# CPU: cpu_saturate=true이면 cgroup이 허용한 코어를 saturate한다 — cpuset 코어 수만큼
#   cpu spinner를 자동 투입한다. false이면 VM worker만 띄워 메모리는 점유하고 CPU는 idle로 둔다.
#
# Usage:
#   sudo stress/start.sh <run_id> <cg_path> <run_dir> <vm_workers> <vm_bytes>

set -euo pipefail

if [[ $# -ne 5 ]]; then
	echo "usage: $0 <run_id> <cg_path> <run_dir> <vm_workers> <vm_bytes>" >&2
	exit 2
fi

RUN_ID="$1"
CG_PATH="$2"
RUN_DIR="$3"
VM_WORKERS="$4"
VM_BYTES="$5"
# 추가 stressor (raw stress-ng args, optional). memory/cpu 외 cache/io/switch 등 다양한 부하.
# 메모리는 vm_workers/vm_bytes로(occupancy 검증됨); extra는 그 외 특성용(membership/OOM만 검증).
STRESS_EXTRA="${STRESS_EXTRA:-}"
# CPU saturator on/off. 기본 true(기존 동작: cgroup cpuset 코어를 항상 saturate).
# false면 cpu spinner를 띄우지 않아 "메모리는 점유하되 CPU는 idle한 배경 부하"를 모델한다
# (예: CPU 여유 + 메모리 빡빡한 디바이스). 메모리 점유(vm_workers/vm_bytes)와는 독립.
STRESS_CPU_SATURATE="${STRESS_CPU_SATURATE:-true}"

# stress-ng 인스턴스 1개의 메모리 floor(MiB). vm_bytes(프로세스당 총 메모리)에서 이만큼을
# 빼서 실제 --vm-bytes(데이터)를 구한다. **플랫폼 의존 실측값**이다: x86_64/0.17에서
# 1M→39MB 등으로 ~38MiB였지만 RPi(aarch64)는 ~3MiB(실측: 29워커 점유가 1276MB 기대에
# 271MB만 도달해 발각). stress/measure_floor.sh로 재서 scenario.yaml stress.floor_mib →
# CFG_STRESS_FLOOR_MIB → 여기로 전달된다. 미지정 시 x86 기본 38.
FLOOR_MIB="${STRESS_FLOOR_MIB:-38}"
[[ "$FLOOR_MIB" =~ ^[0-9]+$ && "$FLOOR_MIB" -ge 1 ]] \
	|| { echo "ERROR: STRESS_FLOOR_MIB must be an integer >= 1 (got '$FLOOR_MIB')" >&2; exit 2; }
# 부하는 OOM 1순위가 되면 안 된다(PLAN_FULL §6.3): 죽으면 background load가 사라져 실험이
# 무효가 된다. target/CRIU는 oom_score_adj=0(기본)으로 두어 정당한 OOM 희생자가 되게 하고,
# stress만 음수로 낮춰 후순위로 보호한다.
STRESS_OOM_SCORE_ADJ=-800

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
[[ -d "$CG_PATH" ]] || { echo "ERROR: cgroup not found: $CG_PATH" >&2; exit 1; }
command -v stress-ng >/dev/null || {
	echo "ERROR: stress-ng not installed; disable stress or install stress-ng" >&2
	exit 1
}
[[ "$VM_WORKERS" =~ ^[0-9]+$ ]] || { echo "ERROR: vm_workers must be an integer" >&2; exit 2; }
case "$STRESS_CPU_SATURATE" in
	true|yes|1|false|no|0) : ;;
	*) echo "ERROR: STRESS_CPU_SATURATE must be true/false (got: '$STRESS_CPU_SATURATE')" >&2; exit 2 ;;
esac

mkdir -p "$RUN_DIR"

# vm_bytes(프로세스당 총 메모리) → stress-ng --vm-bytes(데이터) 변환
STRESS_VM_BYTES=0
if (( VM_WORKERS > 0 )); then
	vm_total_bytes="$(numfmt --from=iec "$VM_BYTES" 2>/dev/null || true)"
	[[ -n "$vm_total_bytes" ]] || { echo "ERROR: invalid vm_bytes: '$VM_BYTES'" >&2; exit 2; }
	floor_bytes=$(( FLOOR_MIB * 1024 * 1024 ))
	if (( vm_total_bytes < floor_bytes )); then
		echo "ERROR: vm_bytes must be >= ${FLOOR_MIB}M (stress-ng instance floor; got '$VM_BYTES')" >&2
		exit 2
	fi
	STRESS_VM_BYTES=$(( vm_total_bytes - floor_bytes ))
	(( STRESS_VM_BYTES >= 1048576 )) || STRESS_VM_BYTES=1048576   # stress-ng 최소 1MB
fi

# cgroup이 허용한 코어 수 = cpuset.cpus.effective의 코어 개수. 그만큼 cpu spinner를 띄워
# 허용 코어를 모두 바쁘게 만든다(cpu.max가 총 bandwidth를 cap). 알 수 없으면 nproc.
count_cpus() {
	local list="$1" total=0 part lo hi
	[[ -n "$list" ]] || { echo 0; return; }
	local IFS=','
	for part in $list; do
		if [[ "$part" == *-* ]]; then
			lo="${part%-*}"; hi="${part#*-}"
			total=$(( total + hi - lo + 1 ))
		else
			total=$(( total + 1 ))
		fi
	done
	echo "$total"
}
CPU_SAT="$(count_cpus "$(cat "$CG_PATH/cpuset.cpus.effective" 2>/dev/null || true)")"
(( CPU_SAT > 0 )) || CPU_SAT="$(nproc 2>/dev/null || echo 1)"

: > "$RUN_DIR/stress.log"
: > "$RUN_DIR/stress.stderr"

collect_descendants() {
	local root="$1" child
	for child in $(pgrep -P "$root" 2>/dev/null || true); do
		echo "$child"
		collect_descendants "$child"
	done
}

# stress-ng 인스턴스 하나를 cgroup에 join시킨 뒤 exec. PID를 전역 배열에 모은다.
STRESS_PIDS=()
launch() {
	(
		trap '' HUP
		echo "$BASHPID" > "$CG_PATH/cgroup.procs"
		exec stress-ng "$@"
	) >> "$RUN_DIR/stress.log" 2>> "$RUN_DIR/stress.stderr" &
	STRESS_PIDS+=("$!")
}

# vm 인스턴스: 각 --vm 1 (인스턴스 단위로만 메모리가 상주·합산된다)
#   --vm-populate(MAP_POPULATE)로 mmap 시점에 상주시키고 --vm-keep로 매핑을 유지한다. populate 후
#   워커는 사실상 idle이라(실측: steady-state cgroup cpu ≈ 0) cpu_saturate=false면 "상주하지만 CPU
#   idle한 배경 데몬"이 된다. (시동 시 fork+populate transient로 잠깐 CPU가 뜨지만 warmup 안에서 가라앉음)
i=0
while (( i < VM_WORKERS )); do
	launch --timeout 1d --metrics-brief --vm 1 --vm-bytes "$STRESS_VM_BYTES" --vm-keep --vm-populate --vm-hang 0
	i=$((i + 1))
done
# cpu saturator: cgroup 허용 코어를 바쁘게 만든다. cpu_saturate=false면 생략해
# "메모리만 점유, CPU는 idle"한 배경 부하를 만든다(CPU 여유 디바이스 모델).
case "$STRESS_CPU_SATURATE" in
	true|yes|1)
		launch --timeout 1d --metrics-brief --cpu "$CPU_SAT"
		;;
	false|no|0)
		echo "[stress] cpu saturator OFF (cpu_saturate=false): memory-only background load, CPU left idle"
		CPU_SAT=0
		;;
esac
# 추가 stressor 인스턴스 (raw args). vm/cpu 외 다양한 부하(예: --cache 2 --switch 4 --io 1).
# 메모리(--vm)는 여기 넣지 말 것 — 상주가 안 되고 occupancy 검증도 안 된다. vm_workers를 쓰라.
if [[ -n "$STRESS_EXTRA" ]]; then
	read -ra extra_args <<< "$STRESS_EXTRA"
	launch --timeout 1d --metrics-brief "${extra_args[@]}"
fi

cleanup_failed() {
	local p
	for p in "${STRESS_PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
}

# 모든 인스턴스가 cgroup에 들어왔는지 확인
for pid in "${STRESS_PIDS[@]}"; do
	ok=0
	for _ in $(seq 1 30); do
		grep -qx "$pid" "$CG_PATH/cgroup.procs" 2>/dev/null && { ok=1; break; }
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if (( ! ok )); then
		echo "ERROR: stress instance pid=$pid did not enter cgroup" >&2
		echo "cgroup.procs: $(tr '\n' ' ' < "$CG_PATH/cgroup.procs" 2>/dev/null)" >&2
		cleanup_failed
		exit 1
	fi
done

# stress-ng는 실제 worker를 oom_score_adj=+1000(OOM 1순위)으로 만든다 — 부하 보호 의도와 정반대다.
# 모든 인스턴스의 main/manager/worker를 protected 값으로 덮는다. worker는 --vm-populate 중 늦게
# 뜰 수 있어, 트리 전체가 protected로 "안정될 때까지" 반복 적용한다.
# stress 기동 시점의 cgroup.procs는 stress 프로세스뿐이므로(target/canary 미투입) 이를 authoritative
# 소스로 쓴다 — verify가 검사하는 descendant 집합을 빠짐없이 덮는다(--vm-keep라 안정 후 유지).
#
# break 조건은 "전원 보호"만으로는 부족하다(실측): worker가 아직 fork되지 않은 순간에 현재
# 프로세스가 전부 보호돼 보이면 루프가 조기 종료하고, 직후 fork된 worker가 +1000으로 떠서
# 수십 ms 뒤의 verify ④가 실패한다(vm 워커 수만큼 unprotected — audit_fix_cold 재현).
# 그래서 "proc 집합이 직전 패스와 동일(트리 정착) + 전원 보호"가 연속 3패스(≥0.4s 정지 상태)
# 유지될 때만 종료한다. fork가 계속되는 동안은 집합이 변해 카운터가 리셋된다.
oom_deadline=$(( SECONDS + 8 ))
stable_passes=0
prev_procs=""
while :; do
	procs="$(tr '\n' ' ' < "$CG_PATH/cgroup.procs" 2>/dev/null)"
	unprot=0
	for pid in $procs; do
		# 명단을 읽은 뒤 죽은 PID(기동 churn)는 redirect open이 실패한다 — bash는
		# `> file 2>/dev/null`의 open 실패 메시지를 원래 stderr에 찍으므로(리다이렉트
		# 좌→우 적용) 그룹으로 감싸야 조용하다(RPi 이식 때 스팸으로 발각).
		{ echo "$STRESS_OOM_SCORE_ADJ" > "/proc/$pid/oom_score_adj"; } 2>/dev/null || true
		adj="$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || true)"
		# 죽은 PID는 보호 대상이 아니다 — 이전엔 fallback 0으로 unprot에 세어져서,
		# churn이 있는 한 stable에 영영 못 가고 8s WARN이 보장되는 버그였다.
		[[ -n "$adj" ]] || continue
		(( adj > STRESS_OOM_SCORE_ADJ )) && unprot=$((unprot + 1))
	done
	if (( unprot == 0 )) && [[ -n "$procs" && "$procs" == "$prev_procs" ]]; then
		stable_passes=$((stable_passes + 1))
		(( stable_passes >= 3 )) && break
	else
		stable_passes=0
	fi
	prev_procs="$procs"
	if (( SECONDS >= oom_deadline )); then
		echo "[stress] WARN: oom-protect not stable after 8s (unprot=$unprot, continuing)" >&2
		break
	fi
	sleep 0.2
done
if (( stable_passes >= 3 )); then
	echo "[stress] oom_score_adj<=$STRESS_OOM_SCORE_ADJ applied to stress tree (background load OOM-protected, stable)"
else
	echo "[stress] oom_score_adj<=$STRESS_OOM_SCORE_ADJ applied (best-effort — 기동 churn으로 정착 미확인; verify ④가 최종 판정)"
fi

printf '%s\n' "${STRESS_PIDS[@]}" > "$RUN_DIR/stress.pids"
# verify.sh가 이 파일을 `source`한다 — 값은 반드시 %q로 인용해야 한다. 무인용 heredoc이던
# 시절엔 STRESS_EXTRA에 공백 포함 인자(예: "--cache 2 --switch 4")가 오면 그 줄이
# `VAR=--cache` + 명령 `2`로 해석돼 verify가 "2: command not found"로 죽었다(실측) —
# 광고된 extra 사용법 전부가 verify 단계에서 항상 실패하는 버그였다.
{
	printf 'RUN_ID=%q\n' "$RUN_ID"
	printf 'VM_WORKERS=%q\n' "$VM_WORKERS"
	printf 'VM_BYTES=%q\n' "$VM_BYTES"
	printf 'STRESS_VM_BYTES=%q\n' "$STRESS_VM_BYTES"
	printf 'CPU_SAT=%q\n' "$CPU_SAT"
	printf 'STRESS_CPU_SATURATE=%q\n' "$STRESS_CPU_SATURATE"
	printf 'STRESS_OOM_SCORE_ADJ=%q\n' "$STRESS_OOM_SCORE_ADJ"
	printf 'FLOOR_MIB=%q\n' "$FLOOR_MIB"
	printf 'STRESS_EXTRA=%q\n' "$STRESS_EXTRA"
	printf 'STRESS_PIDS=%q\n' "${STRESS_PIDS[*]}"
} > "$RUN_DIR/stress.env"

if (( CPU_SAT > 0 )); then cpu_note="cpu saturate=$CPU_SAT core(s)"; else cpu_note="cpu saturate=off"; fi
echo "[stress] started: ${#STRESS_PIDS[@]} instance(s) — vm=$VM_WORKERS x $VM_BYTES/proc, $cpu_note${STRESS_EXTRA:+, extra=[$STRESS_EXTRA]}"
