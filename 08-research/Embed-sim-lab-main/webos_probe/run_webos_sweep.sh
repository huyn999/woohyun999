#!/usr/bin/env bash
# webos_probe/run_webos_sweep.sh — 원커맨드: 생성 → 빌드 → 스윕(fp_w_*) → 비교 리포트
#
#   sudo ./run_webos_sweep.sh                 # TV 제약 + permissive (기본, 기존 지침과 동일)
#   sudo RESUME=1 ./run_webos_sweep.sh        # 중단 지점부터 재개
#   DRY=1 ./run_webos_sweep.sh                # 생성·빌드·기동검증까지만 (criu 미실행)
#
# 전제: Embed-sim-lab-main 루트에서 실행하거나 ROOT= 로 지정.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/.." && pwd)}"
WL="$ROOT/testbed/workloads"
FP="$ROOT/failprobe"
[[ -f "$WL/common/probe_server.h" ]] || { echo "ERROR: $WL 이 워크로드 트리가 아님 (ROOT=... 지정)"; exit 1; }
[[ -f "$FP/compat_sweep.sh" ]] || { echo "ERROR: $FP/compat_sweep.sh 없음"; exit 1; }

echo "[1/4] webOS 충실 워크로드 생성 (fp_w_*, 23종)"
python3 "$HERE/gen_workloads_w.py" --workloads-dir "$WL"

echo "[2/4] 빌드"
"$WL/build.sh" >/dev/null
built=$(ls "$WL"/bin/fp_w_* 2>/dev/null | wc -l || true)
echo "  built: ${built:-확인불가}"

echo "[3/4] 기동 스모크 (각 워크로드 ready 도달 확인)"
BIN_DIR="$WL/bin"
if [[ -n "$BIN_DIR" ]]; then
  ok=0; tot=0
  for b in "$BIN_DIR"/fp_w_*; do
    tot=$((tot+1)); log=$(mktemp "/tmp/wsmk_$(basename "$b").XXXX")
    timeout 8 "$b" --port $((27000+RANDOM%800)) --bytes 4194304 --phase_gap_ms 0 >"$log" 2>&1 &
    sleep 2.5
    grep -q "PHASE ready" "$log" && ok=$((ok+1)) || echo "  !! $(basename "$b") ready 미도달 — $(tail -1 "$log")"
    pkill -9 -f "$(basename "$b") --port" 2>/dev/null || true
  done; wait 2>/dev/null || true
  echo "  smoke: $ok/$tot"
else
  echo "  (bin 디렉터리 미발견 — 스모크 생략)"
fi

if [[ "${DRY:-0}" == 1 ]]; then echo "[DRY] criu 스윕 생략"; exit 0; fi

echo "[4/4] 스윕 (기존 지침 파라미터 그대로)"
sudo CONSTRAINED="${CONSTRAINED:-1}" PERMISSIVE="${PERMISSIVE:-1}" \
     PHASE_GAP_MS="${PHASE_GAP_MS:-150}" PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-40}" \
     RESUME="${RESUME:-0}" "$FP/compat_sweep.sh" 'fp_w_*'

CSV=$(ls -t "$FP"/results/compat_*.csv 2>/dev/null | head -1)
echo; echo "== 비교 리포트 =="
python3 "$HERE/summarize_webos.py" "$CSV"
echo; echo "다음 단계: ./check_webos_usage.sh <rootfs|--live> 로 '④·레거시 미사용' 근거 수집"
