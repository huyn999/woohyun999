#!/usr/bin/env bash
# env/teardown.sh — 환경 정리 orchestrator
#
# 호출 순서: policy/ 원복 → hardware/ 제거 (확장 시)
#
# Usage:  sudo env/teardown.sh <run_dir>
#
# 인터페이스: run_dir 하나 + 설정은 <run_dir>/config.env에서 CFG_* 변수로 source (스펙 §5-6).

set -uo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <run_dir>" >&2
	exit 2
fi

RUN_DIR="$1"
CONFIG_FILE="$RUN_DIR/config.env"

[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: config file not found: $CONFIG_FILE" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG_FILE"
RUN_ID="${CFG_RUN_ID:?config.env missing CFG_RUN_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# run_dir 정합성 가드: hardware/storage.sh·cpufreq.sh는 run_id로부터
# $PROJECT_ROOT/runs/$run_id를 자체 재계산한다. 경로가 어긋나면 storage.env
# 핸드오프 실패(중간 크래시·cgroup 누수) 또는 teardown의 침묵 부분정리가 생기므로
# mutation 전에 크게 실패한다.
CANON_RUN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/runs/$RUN_ID"
if [[ "$(cd "$RUN_DIR" && pwd)" != "$CANON_RUN_DIR" ]]; then
	echo "ERROR: run_dir '$RUN_DIR' != canonical '$CANON_RUN_DIR' (hardware 모듈이 run_id로 경로를 재계산함)" >&2
	exit 1
fi

CG_PATH="/sys/fs/cgroup/criu_test_$RUN_ID"

echo "[env/teardown] === run_id=$RUN_ID ==="

# --- 1a. cpu 주파수 원복 (호스트 전역 DVFS) ---
# 다른 제약과 달리 cgroup 밖 상태라 자동 정리가 안 된다. apply가 저장한 원래값으로 반드시 되돌린다.
# 가장 먼저(다른 정리보다 우선) 실행해 어떤 경우에도 호스트 주파수가 풀리게 한다. best-effort.
"$SCRIPT_DIR/hardware/cpufreq.sh" restore "$RUN_ID" || true

# --- 1. policy 원복 — TODO ---
# "$SCRIPT_DIR/policy/swap.sh"   cleanup "$RUN_ID"
# "$SCRIPT_DIR/policy/sysctl.sh" restore "$RUN_ID"

# --- 2. cgroup OOM/peak 스냅샷 (destroy 전에 떠야 함) ---
# memory.events(oom/oom_kill)로 이 run에서 cgroup OOM이 났는지 — background load나
# target/CRIU가 압박으로 죽었는지 — 를 사후 판단한다. memory.peak는 측정 구간 peak 사용량.
# cgroup을 destroy하면 사라지므로 반드시 그 전에 기록한다.
if [[ -d "$RUN_DIR" && -d "$CG_PATH" ]]; then
	for f in memory.events memory.events.local memory.peak memory.swap.peak; do
		[[ -r "$CG_PATH/$f" ]] && cat "$CG_PATH/$f" > "$RUN_DIR/$f" 2>/dev/null || true
	done
	oom_kill="$(awk '/^oom_kill /{print $2}' "$CG_PATH/memory.events" 2>/dev/null || true)"
	if [[ -n "${oom_kill:-}" && "$oom_kill" != "0" ]]; then
		echo "[env/teardown] NOTE: cgroup OOM during run (oom_kill=$oom_kill) — see $RUN_DIR/memory.events" >&2
	fi
fi

# --- 2b. teardown 호출자(러너) 자신을 cgroup 밖으로 퇴거 ---
# runner/lib/cgroup.sh의 cgroup_join_self(§6-4)는 러너 자신의 PID를 대상 cgroup에 넣어 probe가
# 워크로드와 동일한 memcg 압박을 받게 한다. 그 결과 teardown.sh(및 이를 호출한 러너 본체)도
# 이 cgroup의 멤버로 남아있는 채로 여기 도달한다. cgroup v2는 cgroup.procs가 완전히 비어야
# rmdir되므로, 살아있는 러너/teardown.sh 자신이 여전히 멤버면 아래 3번(destroy)이 "잔여 프로세스"로
# 보고 무조건 SIGKILL하다가 자기 자신(과 그 조상)까지 죽이거나(관측: teardown이 exit 137로 조용히
# 끊기고 빈 cgroup만 남음), 그게 아니어도 멤버가 있는 한 rmdir이 계속 실패한다.
# cgroup_join_self가 남겨둔 "원래 자리"(RUN_DIR/cgroup_home)로 되돌아간다 — 컨테이너 cgroup
# 네임스페이스에서는 "/sys/fs/cgroup"(겉보기 root)에 직접 넣으면 no-internal-process 제약으로
# EBUSY가 날 수 있어(실측), 반드시 원래 있던 자리로 복귀해야 한다. 기록이 없으면(cgroup_join_self를
# 안 쓴 호출자) 절대 root를 시도하되 실패해도 무해(|| true) — 이하 destroy는 원래도 잔여
# 프로세스를 감당하도록 설계됐다. 측정(cold_response_s 등)은 이미 result_write까지 끝난 뒤라
# 이 시점에 밖으로 나가도 무해하다.
if [[ -d "$CG_PATH" ]]; then
	_cg_home="/"
	[[ -r "$RUN_DIR/cgroup_home" ]] && _cg_home="$(cat "$RUN_DIR/cgroup_home" 2>/dev/null || echo /)"
	_cg_home_path="/sys/fs/cgroup"
	[[ "$_cg_home" != "/" ]] && _cg_home_path="/sys/fs/cgroup${_cg_home}"
	for _p in "$$" "${PPID:-}"; do
		[[ -n "$_p" ]] || continue
		if grep -qx "$_p" "$CG_PATH/cgroup.procs" 2>/dev/null; then
			echo "$_p" > "$_cg_home_path/cgroup.procs" 2>/dev/null || true
		fi
	done
fi

# --- 3. cgroup residual process 제거 ---
# restored target/CRIU 잔여 프로세스가 image mount를 잡고 있으면 umount가 busy가 된다.
# 따라서 먼저 cgroup을 비우고, 그 다음 storage live resource를 정리한다.
# cgroup 디렉토리를 통째로 지우면 cpu.max/cpuset.cpus 등 내부 controller 설정도 함께 사라짐.
# 그래서 cpu.sh는 별도 cleanup이 필요 없음.
"$SCRIPT_DIR/hardware/cgroup.sh" destroy "$RUN_ID" || true

# --- 3b. leaked CRIU cgroup-yard 마운트 정리 (storage umount 전에) ---
# CRIU는 dump/restore 중 cgroup 상태를 staging하려고 image dir 아래에 .criu.cgyard.*
# (tmpfs + 그 안의 cgroup2)를 마운트한다. 정상 종료하면 CRIU가 스스로 지우지만, 중단(SIGKILL 등)
# 되면 남아서 이후 IMAGE_DIR umount를 EBUSY로 막고 정리가 연쇄로 깨진다(실측: orphan run).
# 이 run의 RUN_DIR 하위만 deepest-first로 떼어낸다 — 전역 sweep은 병렬 run의 활성 cgyard를
# 건드릴 수 있어 위험하므로 scope를 좁힌다. (배치 사이 전역 정리는 별도 sweep으로.)
if [[ -d "$RUN_DIR" ]]; then
	mapfile -t _cgyard < <(mount 2>/dev/null \
		| awk -v b="$RUN_DIR/" 'index($3, b) == 1 && $3 ~ /\.criu\.cgyard/ { print length($3) "\t" $3 }' \
		| sort -rn | cut -f2-)
	if (( ${#_cgyard[@]} > 0 )); then
		for mp in "${_cgyard[@]}"; do
			umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
		done
		echo "[env/teardown] cleaned ${#_cgyard[@]} leaked CRIU cgyard mount(s) under $RUN_DIR"
	fi
fi

# --- 4. storage live resource 정리 ---
"$SCRIPT_DIR/hardware/storage.sh" cleanup "$RUN_ID" || true

echo "[env/teardown] DONE"
