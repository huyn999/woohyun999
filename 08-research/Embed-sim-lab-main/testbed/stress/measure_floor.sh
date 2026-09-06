#!/usr/bin/env bash
# stress/measure_floor.sh — 이 머신의 stress-ng 인스턴스 floor(MiB) 실측
#
# floor = (--vm 1 --vm-bytes 1M 인스턴스 1개의 정착 memory.current) − 1MiB.
# 이 값은 플랫폼(아키텍처·stress-ng 버전) 의존이다 — 실측: x86_64/0.17 ≈ 38~40MiB,
# RPi(aarch64) ≈ 3MiB. 측정값을 scenario.yaml의 `stress: { floor_mib: <값> }`에 기록하라
# (testbed/README "이식" 절). 정수 내림이라 실제보다 약간 작게 잡히는데, 그 방향이 안전하다
# — floor를 실제보다 작게 잡으면 점유가 목표를 살짝 넘고(occupancy 하한 검증 통과),
# 크게 잡으면 목표 미달로 verify가 실패한다.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "ERROR: root 필요 (cgroup 생성)" >&2; exit 1; }
command -v stress-ng >/dev/null || { echo "ERROR: stress-ng 없음" >&2; exit 1; }

CG=/sys/fs/cgroup/stress_floor_probe
echo +memory > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
mkdir -p "$CG"
[[ -f "$CG/memory.current" ]] || { echo "ERROR: memory controller 미위임" >&2; rmdir "$CG"; exit 1; }

cleanup() {
	local p
	while read -r p; do [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null; done < "$CG/cgroup.procs" || true
	sleep 0.3
	rmdir "$CG" 2>/dev/null || true
}
trap cleanup EXIT

( echo "$BASHPID" > "$CG/cgroup.procs" && exec stress-ng --timeout 60 --vm 1 --vm-bytes 1M --vm-keep --vm-populate --vm-hang 0 ) >/dev/null 2>&1 &
sleep 5   # populate + 정착

cur="$(cat "$CG/memory.current")"
floor_mib=$(( cur / 1048576 - 1 ))
(( floor_mib >= 1 )) || floor_mib=1
echo "measured: memory.current=$(( cur / 1048576 ))MiB (vm-bytes 1M 인스턴스 1개, 정착 5s, 이 머신 stress-ng $(stress-ng --version | awk '{print $3}'))"
echo "→ scenario.yaml에 기록:  stress: { floor_mib: ${floor_mib} }"
