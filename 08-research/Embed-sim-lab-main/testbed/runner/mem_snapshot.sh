#!/usr/bin/env bash
# runner/mem_snapshot.sh — labeled cgroup + system memory snapshot.
#
# 한 시점의 메모리 상태를 라벨 prefix를 붙인 flat key=value로 <out_env>에 append한다.
# 두 runner(run_once=restore, run_cold_start=cold)가 여러 시점(before_stress,
# after_stress_warmup, before/after_drop_caches, before/after_restore ...)에서 호출하므로
# 중복을 피해 공용 헬퍼로 둔다(호출처 다수 → 추출 정당).
#
# cgroup memory.stat/current/peak는 항상 기록한다. drop_caches 경계처럼 system page cache
# 변화를 보고 싶은 지점에서는 with_meminfo를 줘서 /proc/meminfo 필드도 같이 기록한다.
# 값 단위: memory.* 와 memory.stat 은 bytes(cgroup v2), /proc/meminfo 는 kB(키에 _kb 표기).
# 읽을 수 없는 필드는 na로 남긴다(커널/환경에 따라 memory.peak/memory.stat kernel이 없을 수 있음).
#
# Usage:
#   mem_snapshot.sh <cg_path> <label> <out_env> [with_meminfo]

set -uo pipefail

CG_PATH="${1:-}"
LABEL="${2:-}"
OUT="${3:-}"
WITH_MEMINFO="${4:-}"

if [[ -z "$CG_PATH" || -z "$LABEL" || -z "$OUT" ]]; then
	echo "usage: $0 <cg_path> <label> <out_env> [with_meminfo]" >&2
	exit 2
fi

ts="$(date +%s.%N 2>/dev/null || echo na)"

# memory.stat에서 한 필드만 뽑는다. 없으면 na.
statval() {
	awk -v k="$1" '$1==k{print $2; found=1} END{if(!found)print "na"}' \
		"$CG_PATH/memory.stat" 2>/dev/null || echo na
}

cur="$(cat "$CG_PATH/memory.current" 2>/dev/null || echo na)"
peak="$(cat "$CG_PATH/memory.peak" 2>/dev/null || echo na)"
anon="$(statval anon)"
file="$(statval file)"
kernel="$(statval kernel)"
slab_recl="$(statval slab_reclaimable)"

{
	echo "memstat_${LABEL}_ts=$ts"
	echo "memstat_${LABEL}_current=$cur"
	echo "memstat_${LABEL}_peak=$peak"
	echo "memstat_${LABEL}_anon=$anon"
	echo "memstat_${LABEL}_file=$file"
	echo "memstat_${LABEL}_kernel=$kernel"
	echo "memstat_${LABEL}_slab_reclaimable=$slab_recl"
} >> "$OUT"

if [[ -n "$WITH_MEMINFO" ]]; then
	# /proc/meminfo는 "Field:   <num> kB" 형식. 필드명에 콜론을 붙여 매칭한다.
	meminfoval() {
		awk -v k="$1:" '$1==k{print $2; found=1} END{if(!found)print "na"}' \
			/proc/meminfo 2>/dev/null || echo na
	}
	{
		echo "meminfo_${LABEL}_cached_kb=$(meminfoval Cached)"
		echo "meminfo_${LABEL}_buffers_kb=$(meminfoval Buffers)"
		echo "meminfo_${LABEL}_sreclaimable_kb=$(meminfoval SReclaimable)"
		echo "meminfo_${LABEL}_dirty_kb=$(meminfoval Dirty)"
		echo "meminfo_${LABEL}_writeback_kb=$(meminfoval Writeback)"
	} >> "$OUT"
fi
