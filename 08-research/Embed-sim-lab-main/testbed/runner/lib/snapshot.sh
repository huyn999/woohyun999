#!/usr/bin/env bash
# runner/lib/snapshot.sh — uses: TESTBED_DIR RUN_DIR CG_PATH MEM_TIMELINE
# snap_take <tag> [with_meminfo] — 2번째 인자는 mem_snapshot.sh 4번째 인자로 그대로 pass-through
# (old의 drop_caches 시점 스냅샷이 with_meminfo를 쓴다 — Task 12에서 확장, §비고)
snap_take() {
	"$TESTBED_DIR/runner/mem_snapshot.sh" "$CG_PATH" "$1" "$MEM_TIMELINE" "${2:-}" || true
}
