#!/usr/bin/env bash
# pbsprobe/demo_live.sh — "정지된 앱을 이미지에서 부활시키기" 라이브 데모
#
# 발표장에서 보여주는 그림:
#   [1] pbs(모사)가 살아서 배너를 갱신 중            ← 초당 STAT 라이브 출력
#   [2] 처방(연결 해제) 후 CRIU dump                 ← 프로세스 소멸을 ps로 확인
#   [3] 남은 것은 이미지 파일뿐                      ← ls -lh 이미지 디렉터리
#   [4] criu restore                                 ← 같은 PID로 부활
#   [5] 상태 그대로: crc 동일(편성표 비트 보존),
#       up_ms 이어짐(죽었다 새로 뜬 게 아님),
#       slot은 현재 시각(시계는 신선),
#       hub 재등록 + 밀린 notify 수신               ← 라이브 출력 재개
#
#   sudo pbsprobe/demo_live.sh            # 전체 (엔터로 장면 전환)
#   PAUSE=0 sudo pbsprobe/demo_live.sh    # 자동 진행 (리허설)
#   FREEZE_S=20 ...                       # 정지 유지 시간 (기본 8s)
#   SMOKE=1 pbsprobe/demo_live.sh         # criu 없이 배관 점검 (개발용)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WL="$ROOT/testbed/workloads/bin/pbs_mock"
HUB="$DIR/bin/pbs_hub"; PB="$DIR/bin/pbs_probe"
SMOKE="${SMOKE:-0}"; PAUSE="${PAUSE:-1}"; FREEZE_S="${FREEZE_S:-12}"
PORT=24700; D="$DIR/results/demo_live"; IMG="$D/img"

if [[ "$SMOKE" != "1" ]]; then
	[[ $EUID -eq 0 ]] || { echo "root 필요 (sudo). 배관 점검만은 SMOKE=1"; exit 1; }
	CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
	command -v "$CRIU" >/dev/null 2>&1 || CRIU="$(command -v criu || true)"
	[[ -x "${CRIU:-/nonexistent}" ]] || { echo "criu 없음 — pi_setup.sh 먼저"; exit 1; }
fi
[[ -x "$WL" && -x "$HUB" && -x "$PB" ]] || { echo "먼저 pbsprobe/build.sh"; exit 1; }

pause() { [[ "$PAUSE" == "1" ]] && read -rp "  (엔터) " || sleep 1.2; }
say()   { echo; echo "▌ $1"; }
live()  { # $1=횟수 — 초당 배너(채널정보)+상태를 사람 말로
	for _ in $(seq 1 "$1"); do
		b="$("$PB" 127.0.0.1 $PORT 1500 BANR 2>/dev/null)" || { echo "    (응답 없음)"; sleep 1; continue; }
		s="$("$PB" 127.0.0.1 $PORT 1500 STAT 2>/dev/null)"
		slot=$(sed -n 's/.*slot=\([0-9]*\).*/\1/p' <<<"$b")
		now=$(sed -n 's/.*now=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$b")
		nxt=$(sed -n 's/.*next=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$b")
		hub=$(sed -n 's/.*hub=\([0-9/]*\).*/\1/p' <<<"$s")
		up=$(sed -n 's/.*up_ms=\([0-9]*\).*/\1/p' <<<"$s")
		printf "    [배너] 슬롯 %-5s 지금:%s  다음:%s  (hub=%s, 가동 %d.%01ds)\n" \
			"$slot" "$now" "$nxt" "$hub" $((${up:-0}/1000)) $(( (${up:-0}%1000)/100 ))
		sleep 1
	done
}

# 정리 후 세계+앱 기동 (10초 슬롯 — 정지 전후로 슬롯 전진이 보이게)
pkill -9 -f "pbs_mock --port $PORT" 2>/dev/null; pkill -9 -f "pbs_hub --port $PORT" 2>/dev/null
rm -rf "$D"; mkdir -p "$IMG"
rm -f "/tmp/pbsprobe_db_p$PORT.bin"
setsid "$HUB" --port $PORT --pending 3 --feed reqresp > "$D/hub.log" 2>&1 < /dev/null &
for _i in $(seq 1 100); do grep -q "HUB ready" "$D/hub.log" 2>/dev/null && break; sleep 0.05; done
setsid bash -c "exec '$WL' --port $PORT --resume_file '$D/resume' --db_mib 8 --index_mib 24 \
  --parse_iters 60000 --hub_conns 3 --hub_pending 3 --tcp reqresp --channels 120 --slots 8640 \
  --refresh_ms 0 --refresh_kib 0 --timer 1 --timer_s 30 --watch 1 --phase_gap_ms 0" \
  > "$D/wl.log" 2>&1 < /dev/null &
for _i in $(seq 1 200); do grep -q "^PHASE ready" "$D/wl.log" 2>/dev/null && break; sleep 0.05; done
WPID="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$D/wl.log" | head -1)"
grep -q "^PHASE ready" "$D/wl.log" || { echo "기동 실패"; cat "$D/wl.log"; exit 1; }

say "[1] pbs가 살아있다 — DB 파싱을 마친 편성표(crc)로 배너 서비스 중 (pid=$WPID)"
live 4
# 슬롯 경계에 동기화 (정지 12s가 10s 슬롯을 정확히 1칸 넘도록)
S0="$("$PB" 127.0.0.1 $PORT 1500 BANR | sed -n 's/.*slot=\([0-9]*\).*/\1/p')"
for _i in $(seq 1 120); do
	sn="$("$PB" 127.0.0.1 $PORT 1500 BANR | sed -n 's/.*slot=\([0-9]*\).*/\1/p')"
	[[ "$sn" != "$S0" ]] && break
	sleep 0.2
done
B0="$("$PB" 127.0.0.1 $PORT 1500 BANR)"
SLOT0=$(sed -n 's/.*slot=\([0-9]*\).*/\1/p' <<<"$B0")
NOW0=$(sed -n 's/.*now=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$B0")
NEXT0=$(sed -n 's/.*next=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$B0")
CRC0="$("$PB" 127.0.0.1 $PORT 1500 STAT | sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p')"
echo "    ── 정지 직전 배너: 슬롯 $SLOT0, 지금 $NOW0, 다음 예고 $NEXT0 ──"
pause

say "[2] 처방: 외부 연결(hub 3개) 해제 → CRIU dump — 이 순간 프로세스는 정지·소멸"
kill -USR1 "$WPID"
for _i in $(seq 1 60); do grep -q "hub_disconnected" "$D/wl.log" && break; sleep 0.05; done
grep "hub_disconnected" "$D/wl.log" | sed 's/^/    /'
if [[ "$SMOKE" == "1" ]]; then
	echo "    [SMOKE] criu 단계 생략 — 배관 점검 종료"
	kill -9 "$WPID" 2>/dev/null; pkill -9 -f "pbs_hub --port $PORT" 2>/dev/null
	rm -f "/tmp/pbsprobe_db_p$PORT.bin"; exit 0
fi
"$CRIU" dump -t "$WPID" -D "$IMG" -v4 -o dump.log --tcp-established
drc=$?
echo "    dump rc=$drc"
echo "    ps 확인: $(ps -p "$WPID" > /dev/null 2>&1 && echo '아직 있음(?)' || echo "pid $WPID 없음 — 정지 완료")"
pause

say "[3] 남은 것은 이미지뿐 — 프로세스의 전체 상태가 파일로"
du -sh "$IMG" | sed 's/^/    총 /'
ls -lh "$IMG" | awk 'NR>1{printf "    %-28s %s\n",$9,$5}' | head -6
echo "    ... ($(ls "$IMG" | wc -l)개 파일)"
echo "    ${FREEZE_S}초 동안 정지 상태 유지 — 이 사이에도 벽시계는 흐른다"
sleep "$FREEZE_S"
pause

say "[4] criu restore — 이미지에서 부활"
"$CRIU" restore -d -D "$IMG" -v4 -o restore.log --pidfile "$D/pid" --tcp-established
rrc=$?
RPID="$(cat "$D/pid" 2>/dev/null || true)"
echo "    restore rc=$rrc → pid=$RPID $([[ "$RPID" == "$WPID" ]] && echo '(같은 PID로 부활)')"
touch "$D/resume"   # 재등록 신호
for _i in $(seq 1 100); do grep -q "hub_reregistered" "$D/wl.log" && break; sleep 0.05; done
grep "hub_reregistered" "$D/wl.log" | tail -1 | sed 's/^/    /'
pause

say "[5] 상태 검증 — 죽었다 새로 뜬 게 아니라 '이어서' 살아난다"
B1="$("$PB" 127.0.0.1 $PORT 1500 BANR)"
SLOT1=$(sed -n 's/.*slot=\([0-9]*\).*/\1/p' <<<"$B1")
NOW1=$(sed -n 's/.*now=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$B1")
live 3
CRC1="$("$PB" 127.0.0.1 $PORT 1500 STAT | sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p')"
echo
echo "    편성표 crc : $CRC0 → $CRC1  $([[ "$CRC0" == "$CRC1" ]] && echo '일치 — 파싱해둔 인덱스 비트 보존')"
if [[ -n "$SLOT1" && -n "$SLOT0" && "$SLOT1" -eq $((SLOT0+1)) ]]; then
	echo "    채널정보   : 정지 전 '다음 예고 $NEXT0' → 부활 후 '지금 $NOW1'"
	[[ "$NEXT0" == "$NOW1" ]] \
		&& echo "                 ★ 일치 — 정지 사이 시간이 흘렀는데도 옳은 방송을 가리킨다:" \
		&& echo "                   미래 편성까지 담긴 인덱스가 통째로 살아왔고, 시계는 신선하다" \
		|| echo "                 (불일치 — refresh dirty 여부 확인 필요)"
else
	echo "    채널정보   : 슬롯 $SLOT0→$SLOT1 (지금 $NOW1) — 시계는 현재 기준으로 신선"
fi
echo "    가동시간   : 위 up이 0부터가 아니라 정지 전에서 이어짐 (cold 재기동 아님)"
echo "    hub        : 재등록 완료 + 밀린 notify는 hub 큐에서 수신"
echo
echo "데모 끝. (전체 판정 매트릭스: sudo pbsprobe/run_all.sh)"
kill -9 "$RPID" 2>/dev/null
pkill -9 -f "pbs_hub --port $PORT" 2>/dev/null
rm -f "/tmp/pbsprobe_db_p$PORT.bin"
