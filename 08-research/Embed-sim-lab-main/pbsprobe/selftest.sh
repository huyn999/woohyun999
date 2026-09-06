#!/usr/bin/env bash
# pbsprobe/selftest.sh — CRIU 없이 검증 가능한 전 기능 자체 시험 (root 불필요)
#
# 스윕을 돌리기 전에 이걸로 pbs_mock/pbs_hub/pbs_probe의 계약·프로토콜·처방 경로가
# 전부 살아있음을 확인한다. 하나라도 FAIL이면 스윕 결과를 믿으면 안 된다.
#
#  1. 빌드 산출물 존재
#  2. hub + pbs_mock 완전체 기동, phase 순서(생애주기) 정합
#  3. PING → PONG (A6) + served_first 발행
#  4. STAT: crc 형식 + 두 번 연속 안정성(refresh 0일 때 동일)
#  5. SIGUSR1 → hub_disconnected (처방 1단계)
#  6. resume_file → hub_reregistered + hub 쪽 재등록 로그 증가 (처방 2단계)
#  7. TCPQ: reqresp 왕복 ok=1 / stream rx 증가
#  8. reserve 점진 touch (침묵형 OOM 경로가 실제로 자람)
#  9. no-accept hub: 연결이 대기열에 걸린 채 기동 완주 (half-open 재현)
# 10. SIGTERM 깨끗한 종료 (A5)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WL="$ROOT/testbed/workloads/bin/pbs_mock"
HUB="$DIR/bin/pbs_hub"
PB="$DIR/bin/pbs_probe"
T="$DIR/results/selftest"
rm -rf "$T"; mkdir -p "$T"
PORT=23100
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  PASS $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
wait_line() { local log="$1" re="$2" n=0; while (( n < ${3:-100} )); do grep -qE "$re" "$log" 2>/dev/null && return 0; sleep 0.05; n=$((n+1)); done; return 1; }
cleanup() { pkill -9 -f "pbs_mock --port $((PORT+2))" 2>/dev/null; pkill -9 -f "pbs_hub --port $((PORT+2))" 2>/dev/null; pkill -9 -f "pbs_mock --port $PORT" 2>/dev/null; pkill -9 -f "pbs_hub --port $PORT" 2>/dev/null; pkill -9 -f "pbs_mock --port $((PORT+1))" 2>/dev/null; pkill -9 -f "pbs_hub --port $((PORT+1))" 2>/dev/null; rm -f /tmp/pbsprobe_db_p${PORT}.bin /tmp/pbsprobe_db_p$((PORT+1)).bin; }
trap cleanup EXIT

echo "[1] 빌드 산출물"
for b in "$WL" "$HUB" "$PB"; do [[ -x "$b" ]] && ok "$(basename "$b")" || bad "$(basename "$b") 없음 (build.sh 먼저)"; done
(( fail > 0 )) && { echo "SELFTEST FAIL($fail)"; exit 1; }

echo "[2] 완전체 기동 + phase 순서"
setsid "$HUB" --port $PORT --pending 3 --feed reqresp > "$T/hub.log" 2>&1 < /dev/null &
wait_line "$T/hub.log" "HUB ready" || bad "hub 기동"
setsid bash -c "exec '$WL' --port $PORT --resume_file '$T/resume' --db_mib 2 --index_mib 4 \
  --parse_iters 50000 --hub_conns 3 --hub_pending 3 --tcp reqresp --refresh_ms 200 \
  --refresh_kib 64 --reserve_mib 16 --timer 1 --timer_s 60 --watch 1 --phase_gap_ms 0" \
  > "$T/wl.log" 2>&1 < /dev/null &
wait_line "$T/wl.log" "^PHASE ready" 200 && ok "ready 도달" || bad "ready 미도달"
want="init db_open db_read db_parse epg_index epg_text epg_reserve hub_conn1 hub_conn2 hub_conn3 hub_subscribed tcp_conn timer_armed db_watch ready"
got="$(grep -oE '^PHASE [a-z0-9_]+' "$T/wl.log" | awk '{print $2}' | tr '\n' ' ')"
seq_ok=1; prev=-1
for w in $want; do
	idx="$(grep -nE "^PHASE ${w}( |$)" "$T/wl.log" | head -1 | cut -d: -f1)"
	[[ -z "$idx" || "$idx" -le "$prev" ]] && { seq_ok=0; break; }
	prev=$idx
done
[[ $seq_ok == 1 ]] && ok "phase 순서 정합 ($want)" || bad "phase 순서 이상: $got"
grep -q "hub_conn3 ok=1 alive=3" "$T/wl.log" && ok "hub 3연결 성립" || bad "hub 연결 실패"
grep -cq "HUB register svc=com.webos.pbs" "$T/hub.log" && ok "hub 쪽 등록 관측" || bad "hub 등록 미관측"

echo "[3] PING → PONG + served_first"
r="$("$PB" 127.0.0.1 $PORT 2000 PING)"
[[ "$r" == "PONG" ]] && ok "PONG" || bad "PONG 응답: '$r'"
wait_line "$T/wl.log" "^PHASE served_first" 40 && ok "served_first 발행" || bad "served_first 미발행"

echo "[4] STAT 무결성 채널"
s1="$("$PB" 127.0.0.1 $PORT 2000 STAT)"
[[ "$s1" =~ crc=[0-9a-f]{8}\ slot=[0-9]+\ hub=3/3 ]] && ok "STAT 형식+hub 3/3: $s1" || bad "STAT: '$s1'"

# BANR: 배너 질의 형식 + 같은 슬롯 재질의 결정성
b1="$("$PB" 127.0.0.1 $PORT 2000 BANR)"
[[ "$b1" =~ ^BANR\ slot=[0-9]+\ now=PGM-[0-9a-f]{8}\ next=PGM-[0-9a-f]{8}$ ]] && ok "BANR 형식" || bad "BANR: $b1"
b2="$("$PB" 127.0.0.1 $PORT 2000 BANR)"
n1=$(sed -n 's/.*now=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$b1"); n2=$(sed -n 's/.*now=\(PGM-[0-9a-f]*\).*/\1/p' <<<"$b2")
s1=$(sed -n 's/.*slot=\([0-9]*\).*/\1/p' <<<"$b1"); s2=$(sed -n 's/.*slot=\([0-9]*\).*/\1/p' <<<"$b2")
if [[ "$s1" == "$s2" ]]; then
	[[ "$n1" == "$n2" ]] && ok "BANR 결정성 (같은 슬롯=같은 방송)" || bad "BANR 비결정: $n1 vs $n2"
else
	ok "BANR 결정성 (슬롯 경계 통과 — skip)"
fi

echo "[5] SIGUSR1 → hub_disconnected (처방 1단계)"
WLPID="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$T/wl.log" | head -1)"
kill -USR1 "$WLPID"
wait_line "$T/wl.log" "^PHASE hub_disconnected closed=3" && ok "hub 연결 3개 해제" || bad "hub_disconnected 미관측"
s2="$("$PB" 127.0.0.1 $PORT 2000 STAT)"
[[ "$s2" == *"hub=0/3"* ]] && ok "STAT hub=0/3 반영" || bad "해제 후 STAT: '$s2'"

echo "[6] resume_file → 재등록 (처방 2단계)"
reg_before=$(grep -c "HUB register" "$T/hub.log")
touch "$T/resume"
wait_line "$T/wl.log" "^PHASE hub_reregistered" 100 && ok "hub_reregistered 발행" || bad "재등록 미발생"
sleep 0.2
reg_after=$(grep -c "HUB register" "$T/hub.log")
(( reg_after > reg_before )) && ok "hub 쪽 재등록 확인 ($reg_before→$reg_after)" || bad "hub 쪽 재등록 미증가"
ms="$(sed -n 's/.*hub_reregistered ms=\([0-9]*\).*/\1/p' "$T/wl.log" | tail -1)"
[[ -n "$ms" ]] && ok "재등록 비용 측정: ${ms}ms" || bad "재등록 ms 미기록"

echo "[7] TCPQ"
t1="$("$PB" 127.0.0.1 $PORT 2500 TCPQ)"
[[ "$t1" == *"mode=reqresp ok=1"* ]] && ok "reqresp 왕복: $t1" || bad "reqresp: '$t1'"

echo "[8] reserve 점진 touch (침묵형 OOM 경로)"
r1="$(sed -n 's/.*res=\([0-9]*\).*/\1/p' <<< "$("$PB" 127.0.0.1 $PORT 2000 STAT)")"
sleep 1.2
r2="$(sed -n 's/.*res=\([0-9]*\).*/\1/p' <<< "$("$PB" 127.0.0.1 $PORT 2000 STAT)")"
[[ -n "$r1" && -n "$r2" && "$r2" -gt "$r1" ]] && ok "reserve touch 진행 (${r1}→${r2} KiB)" || bad "reserve 정체 ($r1→$r2)"

echo "[9] stream feed + no-accept hub"
P2=$((PORT+1))
setsid "$HUB" --port $P2 --feed stream --no-accept > "$T/hub2.log" 2>&1 < /dev/null &
wait_line "$T/hub2.log" "HUB ready"
setsid bash -c "exec '$WL' --port $P2 --db_mib 1 --index_mib 2 --parse_iters 1000 \
  --hub_conns 2 --tcp stream --refresh_ms 0 --timer 0 --watch 0 --phase_gap_ms 0" \
  > "$T/wl2.log" 2>&1 < /dev/null &
wait_line "$T/wl2.log" "^PHASE ready" 200 && ok "no-accept hub에서도 기동 완주 (대기열 연결)" || bad "no-accept 기동 실패"
sleep 0.5
a="$("$PB" 127.0.0.1 $P2 2000 TCPQ)"; sleep 0.5; b="$("$PB" 127.0.0.1 $P2 2000 TCPQ)"
ra="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$a")"; rb="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$b")"
[[ -n "$ra" && -n "$rb" && "$rb" -gt "$ra" ]] && ok "stream 수신 증가 ($ra→$rb)" || bad "stream 정체: '$a' '$b'"
# refresh 0 → crc 동일성
c1="$(sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p' <<< "$("$PB" 127.0.0.1 $P2 2000 STAT)")"
c2="$(sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p' <<< "$("$PB" 127.0.0.1 $P2 2000 STAT)")"
[[ -n "$c1" && "$c1" == "$c2" ]] && ok "refresh 0 → crc 안정 ($c1)" || bad "crc 불안정 ($c1 vs $c2)"

echo "[10] SIGTERM 종료 (A5)"
kill -TERM "$WLPID" 2>/dev/null
sleep 0.3
kill -0 "$WLPID" 2>/dev/null && bad "SIGTERM 후 생존" || ok "깨끗한 종료"

echo "[11] 확장 자원(RICH): 스레드·잠금·shm·eventfd·log DGRAM·render·workdir"
P3=$((PORT+2))
setsid "$HUB" --port $P3 --pending 1 --feed reqresp > "$T/hub3.log" 2>&1 < /dev/null &
wait_line "$T/hub3.log" "HUB ready"
rm -f "/dev/shm/pbsprobe_shm_p$P3"; rm -rf "/tmp/pbsprobe_wd_p$P3"
setsid bash -c "exec '$WL' --port $P3 --resume_file '$T/resume3' --db_mib 1 --index_mib 2 \
  --parse_iters 1000 --hub_conns 2 --hub_pending 1 --tcp reqresp --refresh_ms 150 \
  --refresh_kib 32 --timer 0 --watch 0 --phase_gap_ms 0 --threads 3 --selfpipe 1 \
  --eventfd 1 --db_lock flock --shm_mib 2 --log_dgram 1 --render 1 --workdir 1" \
  > "$T/wl3.log" 2>&1 < /dev/null &
wait_line "$T/wl3.log" "^PHASE ready" 200 && ok "RICH 기동 완주" || bad "RICH 기동 실패"
for ph in log_open db_lock thread3 selfpipe eventfd_open shm_map workdir render_conn; do
	grep -qE "^PHASE ${ph}.* ok=1" "$T/wl3.log" && ok "phase $ph ok=1" || bad "phase $ph 실패: $(grep "PHASE $ph" "$T/wl3.log")"
done
[[ -e "/dev/shm/pbsprobe_shm_p$P3" ]] && ok "shm 파일 생성" || bad "shm 파일 없음"
s3="$("$PB" 127.0.0.1 $P3 2000 STAT)"
[[ "$s3" =~ ev=1 ]] && ok "STAT ev=1 (eventfd 왕복)" || bad "eventfd: $s3"
[[ "$s3" =~ shm=1 ]] && ok "STAT shm=1" || bad "shm: $s3"
[[ "$s3" =~ log=1 ]] && ok "STAT log=1 (DGRAM 송신)" || bad "log: $s3"
t3a="$(sed -n 's/.*thr=\([0-9]*\).*/\1/p' <<< "$s3")"
sleep 0.6
t3b="$(sed -n 's/.*thr=\([0-9]*\).*/\1/p' <<< "$("$PB" 127.0.0.1 $P3 2000 STAT)")"
[[ -n "$t3a" && -n "$t3b" && "$t3b" -gt "$t3a" ]] && ok "스레드 진행 (thr $t3a→$t3b)" || bad "스레드 정체 ($t3a→$t3b)"
# flock이 실제로 잡혀 있는가: 두 번째 flock 시도가 즉시 실패해야 함
flock -n "/tmp/pbsprobe_db_p$P3.bin" true 2>/dev/null && bad "flock 미보유 (경합 성공해버림)" || ok "flock 보유 확인 (경합 차단)"
wait_line "$T/hub3.log" "LOG rx" 40 && ok "hub 쪽 LOG 수신" || bad "LOG 미수신"
grep -q "RENDER conn" "$T/hub3.log" && ok "render 채널 accept" || bad "render 미접속"
# 처방이 render/log까지 끊고 되살리는가
W3="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$T/wl3.log" | head -1)"
kill -USR1 "$W3"
wait_line "$T/wl3.log" "hub_disconnected closed=2 render=1 log=1" && ok "처방: hub+render+log 해제" || bad "확장 해제 실패: $(grep hub_disconnected "$T/wl3.log")"
touch "$T/resume3"
wait_line "$T/wl3.log" "hub_reregistered .*render=1 log=1" 100 && ok "처방: render/log 포함 재접속" || bad "확장 재접속 실패"
kill -9 "$W3" 2>/dev/null; pkill -9 -f "pbs_hub --port $P3" 2>/dev/null
rm -f "/dev/shm/pbsprobe_shm_p$P3" "/tmp/pbsprobe_db_p$P3.bin"; rm -rf "/tmp/pbsprobe_wd_p$P3"

echo "[12] 이슈 자원(H) + 세계(world) 왕복"
P4=$((PORT+3))
setsid "$HUB" --port $P4 --pending 1 --pass_fd --feed stream > "$T/hub4.log" 2>&1 < /dev/null &
wait_line "$T/hub4.log" "HUB ready"
setsid bash -c "exec '$WL' --port $P4 --db_mib 1 --index_mib 2 --parse_iters 1000 \
  --hub_conns 1 --tcp stream --tcp_halfclose 1 --epoll 1 --eventfd 1 --selfpipe 1 \
  --urandom 1 --tmpunlink 1 --refresh_ms 0 --timer 0 --watch 0 --phase_gap_ms 0" \
  > "$T/wl4.log" 2>&1 < /dev/null &
wait_line "$T/wl4.log" "^PHASE ready" 200 && ok "H 자원 세트 기동 완주" || bad "H 기동 실패"
for ph in dev_urandom tmp_journal tcp_halfclosed epoll_open; do
	grep -qE "^PHASE ${ph}.* ok=1" "$T/wl4.log" && ok "phase $ph ok=1" || bad "phase $ph: $(grep "PHASE $ph" "$T/wl4.log")"
done
grep -qE "epoll_open ok=1 nreg=[3-9]" "$T/wl4.log" && ok "epoll 등록 ≥3 fd" || bad "epoll nreg 부족"
grep -q "HUB passfd" "$T/hub4.log" && ok "SCM_RIGHTS fd 전달" || bad "passfd 미발생"
ls -l "/tmp/pbsprobe_journal_p$P4" 2>/dev/null && bad "저널 unlink 안 됨" || ok "저널 unlink 확인 (fd만 생존)"
pkill -9 -f "pbs_mock --port $P4" 2>/dev/null; pkill -9 -f "pbs_hub --port $P4" 2>/dev/null
rm -f "/tmp/pbsprobe_db_p$P4.bin"

# 세계: 기동 → 상주 등록 확인 → 셀 attach(hub_port 재지향) → flood → 종료
bash "$DIR/world_down.sh" > /dev/null 2>&1
WORLD_PORT=23900 WORLD_SVCS=2 WORLD_FLOOD=50 bash "$DIR/world_up.sh" > "$T/world_up.out" 2>&1 \
  && ok "world 기동" || bad "world 기동 실패: $(cat "$T/world_up.out")"
grep -q "상주 서비스 2" "$T/world_up.out" && wait_line "$DIR/results/world/hub.log" "HUB register" 40 \
  && ok "상주 서비스 hub 등록" || bad "상주 등록 미관측"
P5=23950
setsid bash -c "exec '$WL' --port $P5 --hub_port 23900 --resume_file '$T/resume5' --db_mib 1 \
  --index_mib 2 --parse_iters 1000 --hub_conns 2 --flood_name 1 --refresh_ms 0 --timer 0 \
  --watch 0 --phase_gap_ms 0" > "$T/wl5.log" 2>&1 < /dev/null &
wait_line "$T/wl5.log" "^PHASE ready" 200 && ok "셀 앱이 world hub에 attach (hub_port 재지향)" || bad "attach 실패"
W5="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$T/wl5.log" | head -1)"
kill -USR1 "$W5"; wait_line "$T/wl5.log" "hub_disconnected"; touch "$T/resume5"
wait_line "$T/wl5.log" "hub_reregistered" 100 && ok "world 안 재등록" || bad "world 재등록 실패"
wait_line "$DIR/results/world/hub.log" "HUB flood .*sent=50" 40 && ok "재등록 flood 50건 방출" || bad "flood 미발생"
"$PB" 127.0.0.1 $P5 2000 PING | grep -q PONG && ok "flood 후 서비스 생존" || bad "flood 후 사망"
bash "$DIR/world_status.sh" | grep -qE "up_s=[0-9]+ regs=[0-9]+" && ok "world_status 공변량" || bad "status 이상"
kill -9 "$W5" 2>/dev/null; rm -f "/tmp/pbsprobe_db_p$P5.bin"
bash "$DIR/world_down.sh" > /dev/null 2>&1 && ok "world 종료" || bad "world 종료 실패"

echo
echo "[13] 현실 자원(I): 트리·좀비·보류시그널·listen·udp·netlink·잠금대기·감시계측"
P6=$((PORT+4))
touch "/tmp/pbsprobe_db_p$P6.bin"
( exec 9>>"/tmp/pbsprobe_db_p$P6.bin" && flock -x 9 && exec sleep 60 ) & HOLD=$!
sleep 0.2
setsid bash -c "exec '$WL' --port $P6 --db_mib 1 --index_mib 2 --parse_iters 800 \
  --hub_conns 0 --child 1 --zombie 1 --sigpend 1 --unix_listen 1 --udp 1 --netlink 1 \
  --db_lock flock_wait --watch 1 --refresh_ms 200 --timer 0 --phase_gap_ms 0" \
  > "$T/wl6.log" 2>&1 < /dev/null &
wait_line "$T/wl6.log" "^PHASE db_open" 100 && ok "db_open 도달" || bad "기동 실패"
sleep 0.5
grep -q "db_lock" "$T/wl6.log" && bad "flock_wait가 블록 안 됨 (홀더 무시)" || ok "flock_wait: syscall 안에서 대기 중"
kill -9 "$HOLD" 2>/dev/null
wait_line "$T/wl6.log" "db_lock mode=flock_wait ok=1" 60 && ok "홀더 해제 후 잠금 획득" || bad "잠금 획득 실패"
wait_line "$T/wl6.log" "^PHASE ready" 200 && ok "I 자원 세트 기동 완주" || bad "ready 미도달"
for ph in sig_pending helper_forked svc_listen udp_open netlink_open; do
	grep -qE "^PHASE ${ph}" "$T/wl6.log" && ok "phase $ph" || bad "phase $ph 없음"
done
grep -qE "zombie_made pid=[0-9]+ state=Z" "$T/wl6.log" && ok "좀비 상태 Z 확인" || bad "좀비: $(grep zombie_made "$T/wl6.log")"
s6="$("$PB" 127.0.0.1 $P6 2000 STAT)"
[[ "$s6" =~ chld=S || "$s6" =~ chld=R ]] && ok "헬퍼 자식 생존 (chld)" || bad "chld: $s6"
[[ "$s6" =~ zomb=Z ]] && ok "STAT zomb=Z" || bad "zomb: $s6"
[[ "$s6" =~ sigp=1 ]] && ok "보류 시그널 유지 (sigp=1)" || bad "sigp: $s6"
echo "stim" >> "/tmp/pbsprobe_db_p$P6.bin"
wait_line "$T/wl6.log" "db_changed" 40 && ok "inotify 이벤트 계측 (db_changed)" || bad "감시 계측 실패"
W6="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$T/wl6.log" | head -1)"
kill -9 "$W6" 2>/dev/null; pkill -P "$W6" 2>/dev/null; pkill -9 -f "pbs_mock --port $P6" 2>/dev/null
rm -f "/tmp/pbsprobe_db_p$P6.bin"

echo "SELFTEST: PASS=$pass FAIL=$fail"
(( fail == 0 )) || exit 1
