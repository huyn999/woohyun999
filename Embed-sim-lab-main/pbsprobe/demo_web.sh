#!/usr/bin/env bash
# pbsprobe/demo_web.sh — 브라우저 라이브 데모: hub+앱을 띄우고 웹서버 기동
#
#   sudo pbsprobe/demo_web.sh          # http://<Pi IP>:8899 접속 → ❄정지/▶부활 버튼
#   SMOKE=1 pbsprobe/demo_web.sh       # criu 없이 화면·폴링만 (버튼은 오류 응답)
#   HTTP_PORT=8899 APP_PORT=24700 ...
#
# 화면: TV 배너(지금/다음 방송 = 복원되는 인덱스 메모리에서 읽은 값, 시계 =
# 실시간). ❄정지를 누르면 처방+dump로 프로세스가 사라지고 이미지 크기가 뜨며,
# ▶부활을 누르면 restore+재등록 — 정지 전 '다음 예고'가 부활 후 '지금'과
# 일치하면 ★ 인계 배지가 뜬다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WL="$ROOT/testbed/workloads/bin/pbs_mock"; HUB="$DIR/bin/pbs_hub"
SMOKE="${SMOKE:-0}"; APP_PORT="${APP_PORT:-24700}"; HTTP_PORT="${HTTP_PORT:-8899}"
D="$DIR/results/demo_live"; IMG="$D/img"

CRIU=""
if [[ "$SMOKE" != "1" ]]; then
	[[ $EUID -eq 0 ]] || { echo "root 필요 (sudo). 화면만 보려면 SMOKE=1"; exit 1; }
	CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
	command -v "$CRIU" >/dev/null 2>&1 || CRIU="$(command -v criu || true)"
	[[ -x "${CRIU:-/nonexistent}" ]] || { echo "criu 없음 — pi_setup.sh 먼저"; exit 1; }
fi
[[ -x "$WL" && -x "$HUB" ]] || { echo "먼저 pbsprobe/build.sh"; exit 1; }

pkill -9 -f "pbs_mock --port $APP_PORT" 2>/dev/null
pkill -9 -f "pbs_hub --port $APP_PORT" 2>/dev/null
pkill -9 -f "demo_web.py" 2>/dev/null
rm -rf "$D"; mkdir -p "$IMG"; rm -f "/tmp/pbsprobe_db_p$APP_PORT.bin"

setsid "$HUB" --port "$APP_PORT" --pending 3 --feed reqresp > "$D/hub.log" 2>&1 < /dev/null &
for _i in $(seq 1 100); do grep -q "HUB ready" "$D/hub.log" 2>/dev/null && break; sleep 0.05; done
setsid bash -c "exec '$WL' --port $APP_PORT --resume_file '$D/resume' --db_mib 8 --index_mib 24 \
  --parse_iters 60000 --hub_conns 3 --hub_pending 3 --tcp reqresp --channels 120 --slots 8640 \
  --refresh_ms 0 --refresh_kib 0 --timer 1 --timer_s 30 --watch 1 --phase_gap_ms 0" \
  > "$D/wl.log" 2>&1 < /dev/null &
for _i in $(seq 1 200); do grep -q "^PHASE ready" "$D/wl.log" 2>/dev/null && break; sleep 0.05; done
grep -q "^PHASE ready" "$D/wl.log" || { echo "앱 기동 실패"; cat "$D/wl.log"; exit 1; }

trap 'pkill -9 -f "pbs_mock --port $APP_PORT" 2>/dev/null; pkill -9 -f "pbs_hub --port $APP_PORT" 2>/dev/null; rm -f "/tmp/pbsprobe_db_p$APP_PORT.bin"' EXIT
echo "[demo_web] 앱 준비 완료 (10초 슬롯, 채널 120) — 브라우저에서 열기:"
ip -4 addr 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/    http:\/\/\1:'"$HTTP_PORT"'\//p' | grep -v 127.0.0.1 || true
echo "    http://localhost:$HTTP_PORT/"
APP_PORT="$APP_PORT" HTTP_PORT="$HTTP_PORT" DEMO_DIR="$D" CRIU_BIN="$CRIU" \
	exec python3 "$DIR/demo_web.py"
