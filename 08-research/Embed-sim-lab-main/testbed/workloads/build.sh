#!/usr/bin/env bash
# workloads/build.sh — 플러그인 발견·빌드 (멱등): */workload.c → bin/<dirname>
# 소스가 bin보다 새로울 때만 재빌드. common/ 헤더 변경 시 전체 재빌드.
#
# 크로스/비트니스 빌드(이식 — testbed/README "이식" 절): WL_CC/WL_CFLAGS로 툴체인 교체.
# ARM에서 CRIU와 dump 대상은 비트니스가 일치해야 하므로(compat C/R은 x86 전용), 32-bit
# CRIU로 TV(64커널+32유저스페이스)를 모사할 땐 워크로드도 armhf로 빌드한다:
#   WL_CC=arm-linux-gnueabihf-gcc WL_CFLAGS="-O2 -Wall -static" workloads/build.sh
# (-static이면 armhf 런타임 멀티아치 설치가 필요 없다.) 툴체인이 바뀌면 전체 재빌드된다.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="${WL_CC:-gcc}"
CFLAGS="${WL_CFLAGS:--O2 -Wall}"
mkdir -p "$DIR/bin"
# 툴체인 마커: CC/CFLAGS가 직전 빌드와 다르면 bin 전체를 비우고 재빌드 — 64/32 산출물이
# 섞이는 것(비트니스 혼합은 CRIU dump 실패)을 원천 차단한다.
tc="$CC $CFLAGS"
marker="$DIR/bin/.toolchain"
if [[ ! -f "$marker" || "$(cat "$marker")" != "$tc" ]]; then
	rm -f "$DIR/bin"/*
	printf '%s' "$tc" > "$marker"
	echo "toolchain: $tc (전체 재빌드)"
fi
common_newest="$(find "$DIR/common" -name '*.h' -newer "$DIR/bin" 2>/dev/null | head -1 || true)"
for src in "$DIR"/*/workload.c; do
	name="$(basename "$(dirname "$src")")"
	out="$DIR/bin/$name"
	if [[ ! -x "$out" || "$src" -nt "$out" || -n "$common_newest" ]]; then
		# shellcheck disable=SC2086  # CFLAGS는 의도적 단어분할
		"$CC" $CFLAGS -I "$DIR/common" -o "$out" "$src"
		echo "built: bin/$name ($tc)"
	else
		echo "up-to-date: bin/$name"
	fi
done
