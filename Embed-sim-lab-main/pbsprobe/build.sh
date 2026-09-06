#!/usr/bin/env bash
# pbsprobe/build.sh — pbs_hub / pbs_probe 빌드 (+ 워크로드는 testbed 빌더가 담당)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
mkdir -p "$DIR/bin"
gcc -O2 -Wall -o "$DIR/bin/pbs_hub" "$DIR/pbs_hub.c"
gcc -O2 -Wall -o "$DIR/bin/pbs_probe" "$DIR/pbs_probe.c"
echo "[build] pbsprobe/bin/{pbs_hub,pbs_probe}"
# 워크로드(pbs_mock)는 기존 자동 발견 빌더로 — 계약 플러그인이라 이 한 줄이면 끝
if [[ -x "$ROOT/testbed/workloads/build.sh" ]]; then
	"$ROOT/testbed/workloads/build.sh"
else
	# zip 배포본 등에서 빌더가 없으면 직접 (동일 플래그)
	mkdir -p "$ROOT/testbed/workloads/bin"
	gcc -O2 -Wall -I "$ROOT/testbed/workloads/common" \
		-o "$ROOT/testbed/workloads/bin/pbs_mock" \
		"$ROOT/testbed/workloads/pbs_mock/workload.c"
	echo "[build] testbed/workloads/bin/pbs_mock (직접 빌드)"
fi
