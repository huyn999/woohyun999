#!/usr/bin/env bash
# stress/verify.sh — stress-ng 인스턴스들이 같은 cgroup에서 살아있고, 의도한 부하를
# 실제로 만들고 있는지 확인한다.
#
# 검증 4종:
#   1. membership   — 모든 인스턴스의 parent/worker가 같은 cgroup 안에 있는가
#   2. cpu-saturate — cpu_saturate=true면 별도 --cpu saturator가 살아 있고 CPU time이 증가하는가
#   3. occupancy    — cgroup memory.current가 vm_workers x vm_bytes(프로세스당 총 메모리)에 도달했는가
#   4. oom-protect  — 부하(특히 실제 worker)가 OOM 후순위(adj <= threshold)인가
#
# Usage:
#   sudo stress/verify.sh <cg_path> <run_dir>

set -euo pipefail

if [[ $# -ne 2 ]]; then
	echo "usage: $0 <cg_path> <run_dir>" >&2
	exit 2
fi

CG_PATH="$1"
RUN_DIR="$2"
PIDS_FILE="$RUN_DIR/stress.pids"

# 점유량 검증 임계치(%). membership만으론 "부하가 살아있다"는 알지만 "얼마나 점유하는지"는
# 모른다. PLAN_FULL §4.4의 occupancy 단언을 이 값으로 근사한다.
OCCUPANCY_MIN_PCT=90

[[ -f "$PIDS_FILE" ]] || { echo "ERROR: stress pids file not found: $PIDS_FILE" >&2; exit 1; }
mapfile -t STRESS_ROOTS < "$PIDS_FILE"

any_alive=0
for r in "${STRESS_ROOTS[@]}"; do
	[[ -n "$r" ]] || continue
	if kill -0 "$r" 2>/dev/null; then any_alive=1; break; fi
done
(( any_alive )) || { echo "ERROR: no stress instances running" >&2; exit 1; }

collect_descendants() {
	local root="$1"
	local child

	for child in $(pgrep -P "$root" 2>/dev/null || true); do
		echo "$child"
		collect_descendants "$child"
	done
}

proc_cmdline() {
	local pid="$1"
	if [[ -r "/proc/$pid/cmdline" ]]; then
		tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
	fi
}

cpu_tree_ticks() {
	local root="$1"
	local pid line tail ticks total=0
	local tree
	tree="$root $(collect_descendants "$root" | tr '\n' ' ')"
	for pid in $tree; do
		[[ -n "$pid" ]] || continue
		kill -0 "$pid" 2>/dev/null || continue
		line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
		[[ -n "$line" ]] || continue
		tail="${line#*) }"
		ticks="$(awk '{print $12 + $13}' <<< "$tail")"
		[[ "$ticks" =~ ^[0-9]+$ ]] || continue
		total=$((total + ticks))
	done
	echo "$total"
}

cpu_tree_active_delta() {
	local root="$1"
	local before after delta
	before="$(cpu_tree_ticks "$root")"
	for _ in $(seq 1 5); do
		sleep 0.2
		after="$(cpu_tree_ticks "$root")"
		delta=$((after - before))
		if (( delta > 0 )); then
			echo "$delta"
			return 0
		fi
	done
	echo 0
	return 1
}

# stress.env에서 메타(vm_workers/vm_bytes/cpu saturator/oom threshold)를 읽는다.
STRESS_ENV="$RUN_DIR/stress.env"
if [[ -f "$STRESS_ENV" ]]; then
	# shellcheck source=/dev/null
	source "$STRESS_ENV"
fi
VM_WORKERS="${VM_WORKERS:-0}"
VM_BYTES="${VM_BYTES:-0}"
STRESS_CPU_SATURATE="${STRESS_CPU_SATURATE:-true}"
CPU_SAT="${CPU_SAT:-0}"

fail=0
pids=""
for r in "${STRESS_ROOTS[@]}"; do
	[[ -n "$r" ]] || continue
	pids="$pids $r $(collect_descendants "$r" | tr '\n' ' ')"
done
checked=0

# --- 1. membership ---
for pid in $pids; do
	[[ -n "$pid" ]] || continue
	kill -0 "$pid" 2>/dev/null || continue
	checked=$((checked + 1))
	if grep -qx "$pid" "$CG_PATH/cgroup.procs"; then
		:
	else
		echo "ERROR: stress pid=$pid is not in $CG_PATH" >&2
		fail=$((fail + 1))
	fi
done

if (( checked == 0 )); then
	echo "ERROR: no live stress processes found" >&2
	exit 1
fi
echo "[stress] OK: ${#STRESS_ROOTS[@]} instance(s), $checked proc(s) in $CG_PATH"

# --- 2. cpu-saturate ---
# start.sh는 vm_workers개의 VM 루트를 먼저 띄우고, cpu_saturate=true일 때 바로 다음 루트로
# `stress-ng --cpu $CPU_SAT`를 추가한다. membership만으로는 VM 루트들이 살아있는지만 보고 CPU
# saturator만 빠진 회귀를 놓칠 수 있으므로, busy 축은 이 루트를 명시적으로 확인한다.
case "$STRESS_CPU_SATURATE" in
	true|yes|1)
		if [[ ! "$CPU_SAT" =~ ^[0-9]+$ ]] || (( CPU_SAT <= 0 )); then
			echo "ERROR: cpu_saturate=true but CPU_SAT='$CPU_SAT' (expected positive core count)" >&2
			fail=$((fail + 1))
		elif [[ ! "$VM_WORKERS" =~ ^[0-9]+$ ]] || (( VM_WORKERS >= ${#STRESS_ROOTS[@]} )); then
			echo "ERROR: cpu_saturate=true but no CPU saturator root pid after $VM_WORKERS VM root(s)" >&2
			fail=$((fail + 1))
		else
			cpu_root="${STRESS_ROOTS[$VM_WORKERS]}"
			if ! kill -0 "$cpu_root" 2>/dev/null; then
				echo "ERROR: cpu_saturate=true but expected CPU root pid=$cpu_root is not live" >&2
				fail=$((fail + 1))
			else
				cpu_cmd="$(proc_cmdline "$cpu_root")"
				if [[ "$cpu_cmd" != *"--cpu"* ]]; then
					echo "ERROR: cpu_saturate=true but expected CPU root pid=$cpu_root is not stress-ng --cpu (cmd='$cpu_cmd')" >&2
					fail=$((fail + 1))
				else
					if cpu_delta="$(cpu_tree_active_delta "$cpu_root")"; then
						echo "[stress] OK: cpu saturator active (pid=$cpu_root, CPU_SAT=$CPU_SAT, cpu_ticks_delta=$cpu_delta)"
					else
						echo "ERROR: cpu_saturate=true but CPU saturator tree did not accumulate CPU time (pid=$cpu_root)" >&2
						fail=$((fail + 1))
					fi
				fi
			fi
		fi
		;;
	false|no|0)
		if [[ "$CPU_SAT" != "0" ]]; then
			echo "ERROR: cpu_saturate=false but CPU_SAT='$CPU_SAT' (expected 0)" >&2
			fail=$((fail + 1))
		fi
		cpu_roots=""
		for r in "${STRESS_ROOTS[@]}"; do
			[[ -n "$r" ]] || continue
			kill -0 "$r" 2>/dev/null || continue
			cpu_cmd="$(proc_cmdline "$r")"
			if [[ "$cpu_cmd" == *"--cpu"* ]]; then
				cpu_roots="$cpu_roots $r"
			fi
		done
		if [[ -n "$cpu_roots" ]]; then
			echo "ERROR: cpu_saturate=false but stress-ng --cpu root(s) are live:$cpu_roots" >&2
			fail=$((fail + 1))
		else
			echo "[stress] OK: cpu saturator absent (cpu_saturate=false)"
		fi
		;;
	*)
		echo "ERROR: invalid STRESS_CPU_SATURATE='$STRESS_CPU_SATURATE'" >&2
		fail=$((fail + 1))
		;;
esac

# --- 3. occupancy ---
# 기대 총 점유 = vm_workers x vm_bytes(프로세스당 총 메모리, floor 포함). stress-ng 인스턴스
# floor 때문에 per-process는 ±오차가 있지만, 총 점유량은 여기서 보증한다.
if [[ "$VM_WORKERS" =~ ^[0-9]+$ ]] && (( VM_WORKERS > 0 )); then
	per="$(numfmt --from=iec "$VM_BYTES" 2>/dev/null || true)"
	if [[ -z "$per" ]]; then
		echo "[stress] WARN: cannot parse vm_bytes='$VM_BYTES'; skipping occupancy check" >&2
	elif [[ ! -r "$CG_PATH/memory.current" ]]; then
		echo "[stress] WARN: memory.current unreadable; skipping occupancy check" >&2
	else
		expected_bytes=$(( per * VM_WORKERS ))
		min_bytes=$(( expected_bytes * OCCUPANCY_MIN_PCT / 100 ))
		# populate 지연/스케줄링에 강하도록 잠깐 poll한다(최대 ~3s).
		current_bytes=0
		for _ in $(seq 1 15); do
			current_bytes="$(cat "$CG_PATH/memory.current" 2>/dev/null || echo 0)"
			(( current_bytes >= min_bytes )) && break
			sleep 0.2
		done
		if (( current_bytes >= min_bytes )); then
			echo "[stress] OK: occupancy memory.current=$((current_bytes/1024/1024))MB >= ${OCCUPANCY_MIN_PCT}% of $((expected_bytes/1024/1024))MB (${VM_WORKERS} x ${VM_BYTES}/proc)"
		else
			echo "ERROR: stress occupancy too low: memory.current=$((current_bytes/1024/1024))MB < ${OCCUPANCY_MIN_PCT}% of $((expected_bytes/1024/1024))MB (${VM_WORKERS} x ${VM_BYTES}/proc)" >&2
			fail=$((fail + 1))
		fi
	fi
else
	echo "[stress] occupancy check skipped (vm 부하 없음)"
fi

# --- 4. oom-protect ---
# stress-ng는 worker를 oom_score_adj=+1000으로 두므로, start.sh가 protected 값으로 덮었는지
# 독립적으로 확인한다. 하나라도 threshold보다 크면 그 worker가 OOM 1순위라는 뜻이라 실패.
threshold="${STRESS_OOM_SCORE_ADJ:-0}"
unprotected=0
worst=""
for pid in $pids; do
	[[ -n "$pid" ]] || continue
	kill -0 "$pid" 2>/dev/null || continue
	adj="$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo 0)"
	if (( adj > threshold )); then
		unprotected=$((unprotected + 1))
		worst="$worst $pid:$adj"
	fi
done
if (( unprotected > 0 )); then
	echo "ERROR: $unprotected stress proc(s) not OOM-protected (oom_score_adj > $threshold):$worst" >&2
	fail=$((fail + 1))
else
	echo "[stress] OK: all stress procs OOM-protected (oom_score_adj <= $threshold)"
fi

if (( fail > 0 )); then
	echo "cgroup.procs: $(tr '\n' ' ' < "$CG_PATH/cgroup.procs" 2>/dev/null)" >&2
	exit 1
fi
