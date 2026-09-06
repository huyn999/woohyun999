#!/usr/bin/env bash
# webosprobe/build.sh — 통합 워크로드 + 외부 피어를 bin/ 에 빌드한다.
#
#   ./build.sh            # connprobe, xpeer 둘 다
#
# 산출물: webosprobe/bin/{connprobe,xpeer}
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/bin"
mkdir -p "$BIN"

CC="${CC:-gcc}"
CFLAGS="${CFLAGS:--O2 -Wall}"

echo "[build] connprobe (통합 연결-생존 워크로드)"
$CC $CFLAGS -o "$BIN/connprobe" "$HERE/connprobe.c"

echo "[build] xpeer (덤프 밖 외부 피어)"
$CC $CFLAGS -o "$BIN/xpeer" "$HERE/xpeer.c"

echo "[build] 완료 → $BIN"
ls -la "$BIN"
