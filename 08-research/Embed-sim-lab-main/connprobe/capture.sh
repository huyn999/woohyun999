#!/usr/bin/env bash
# criu_cap.sh — 세 상황의 실패를 "관측 지점" 형식으로 화면에 정렬한다 (캡처용)
#
#   sudo ./criu_cap.sh hub        # ① 루나 허브 — CRIU가 거부한다 (dump / restore)
#   sudo ./criu_cap.sh tcp        # ② TCP 클라이언트 — 거부하지 않는다 (대조군)
#   sudo ./criu_cap.sh mem-heavy  # ③-a 메모리, 무거운 이미지 → CRIU가 거부한다
#   sudo ./criu_cap.sh mem-light  # ③-b 메모리, 가벼운 이미지 → 거부하지 않는다. 그런데 죽는다 ★
#   sudo ./criu_cap.sh all        # 넷 다
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "sudo 필요" >&2; exit 1; }
CRIU="${CRIU_BIN:-$ROOT/testbed/criu/bin/criu}"
BIN="$ROOT/testbed/workloads/bin"
XPEER="${XPEER:-$HERE/bin/xpeer}"  # connprobe/build.sh 가 빌드
OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음"; exit 1; }
hr(){ printf '═%.0s' {1..76}; echo; }
head2(){ hr; echo "  $1"; echo "  $2"; hr; }
obs(){ printf "\n[관측 %s]  %s\n" "$1" "$2"; }
cmd(){ printf "          \$ %s\n" "$1"; }
out(){ printf "          %s\n" "$1"; }

wait_phase(){ for _ in $(seq 1 1200); do grep -qE "^PHASE $2( |$)" "$1" && return 0; sleep 0.05; done; return 1; }

# ═══════════════ ① 루나 허브 ═══════════════
# ── ①-A 허브를 함께 얼린다 → 통과 ────────────────────────────────────
cap_hub_ok(){
  head2 "①-A 루나 허브를 함께 얼린다 — CRIU가 거부하지 않는다" \
        "워크로드: fp_w_hub  (listen + 성립 연결 8쌍 + 큐에 남은 미소비 JSON, 전부 경계 안)"
  local WL=fp_w_hub PORT=$((28500 + RANDOM % 80)) C=/tmp/cap_hub_ok
  [[ -x "$BIN/$WL" ]] || { echo "  [skip] $WL 미빌드"; return; }
  rm -rf "$C"; mkdir -p "$C/img"
  "$BIN/$WL" --port "$PORT" --bytes 8388608 --phase_gap_ms 400 > "$C/wl.log" 2>&1 & local WP=$!
  wait_phase "$C/wl.log" "f_unix_fanin" || { echo "  phase 미도달"; kill -9 $WP 2>/dev/null; return; }

  obs 1 "덤프 순간의 커널 상태 — 소켓의 양 끝이 모두 내 것인가"
  cmd "ss -x -p | grep $WL | head -4"
  ss -x -p 2>/dev/null | grep -F "$WL" | head -4 | cut -c1-92 | sed 's/^/          /'
  out "→ 연결 8쌍의 양쪽 끝(client fd, accepted fd)이 전부 이 프로세스 것이다."
  cmd "ls /proc/$WP/fd | wc -l    # 붙들고 있는 fd 개수"
  out "$(ls /proc/$WP/fd 2>/dev/null | wc -l)"
  cmd "cat /proc/$WP/net/unix | grep criuprobe_hub | head -2"
  grep -F "criuprobe_hub" /proc/$WP/net/unix 2>/dev/null | head -2 | cut -c1-88 | sed 's/^/          /'

  "$CRIU" dump -t "$WP" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1; local DRC=$?
  obs 2 "CRIU dump — 뭐라고 하나?"
  cmd "criu dump -t $WP ... ; echo \$?"
  out "rc = $DRC   $([[ $DRC -eq 0 ]] && echo '✅ 거부하지 않는다')"
  cmd "grep -c 'Error (' img/dump.log"
  out "$(grep -c 'Error (' "$C/img/dump.log" 2>/dev/null || echo 0)"
  pkill -9 -f "bin/$WL --port $PORT" 2>/dev/null
  [[ $DRC -ne 0 ]] && { grep -m1 "Error (" "$C/img/dump.log" | sed 's/^/          /'; return; }

  "$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1; local RRC=$?
  local RPID; RPID=$(cat "$C/pid" 2>/dev/null || echo 0)
  obs 3 "CRIU restore"
  cmd "criu restore ... ; echo \$?"; out "rc = $RRC   $([[ $RRC -eq 0 ]] && echo '✅')"
  sleep 1
  obs 4 "복원된 프로세스 — 소켓과 큐가 그대로인가"
  cmd "ps -o pid,state,comm -p $RPID"
  ps -o pid,state,comm -p "$RPID" 2>/dev/null | sed 's/^/          /'
  cmd "cat /proc/$RPID/net/unix | grep criuprobe_hub | head -2"
  grep -F "criuprobe_hub" /proc/$RPID/net/unix 2>/dev/null | head -2 | cut -c1-88 | sed 's/^/          /'
  cmd "ls /proc/$RPID/fd | wc -l    # fd 개수 — 덤프 전과 같은가"
  out "$(ls /proc/$RPID/fd 2>/dev/null | wc -l)"
  echo
  out "▶ 판정: 통과. 허브 위상 전체 — listen 소켓, 연결 8쌍, 그리고"
  out "   소켓 버퍼에 아직 읽지 않고 남아 있던 JSON까지 — 그대로 되살아났다."
  out "   우체국을 통째로 얼렸다 녹여도 편지가 사라지지 않는다."
  kill -9 "$RPID" 2>/dev/null
}

# ── ①-B 서비스만 떼어 얼린다 → 거부 ──────────────────────────────────
cap_hub(){
  head2 "①-B 서비스만 떼어 얼린다 — 허브가 경계 밖이면 CRIU가 거부한다" \
        "워크로드: fp_x_ext_unix_est / _pend      허브: 별도 프로세스(xpeer) = 덤프 트리 밖"
  for KIND in est pend; do
    WL="fp_x_ext_unix_${KIND}"; PORT=$((28600 + RANDOM % 100))
    [[ -x "$BIN/$WL" ]] || { echo "  [skip] $WL 미빌드 (criu_x.sh xmatrix 먼저)"; continue; }
    PEER=(); [[ "$KIND" == "pend" ]] && PEER=(--no-accept)
    C=/tmp/cap_$WL; rm -rf "$C"; mkdir -p "$C/img"
    "$XPEER" --port "$PORT" "${PEER[@]}" > "$C/peer.log" 2>&1 & XP=$!
    sleep 0.5
    "$BIN/$WL" --port "$PORT" --bytes 8388608 --phase_gap_ms 400 > "$C/wl.log" 2>&1 & WP=$!
    wait_phase "$C/wl.log" "f_ext_unix_${KIND}_l05" || { echo "  phase 미도달"; kill -9 $XP $WP 2>/dev/null; continue; }

    echo
    echo "  ┌─ $WL  ($([[ $KIND == est ]] && echo '허브가 accept 완료' || echo '허브가 아직 미accept'))"
    obs 1 "덤프 순간의 커널 상태 — 소켓의 반대편은 누구인가"
    cmd "ss -x -p | grep \$(pidof $WL)"
    ss -x -p 2>/dev/null | grep -F "$(cat /proc/$WP/comm 2>/dev/null)" | head -2 | cut -c1-92 | sed 's/^/          /'
    out "→ 상대편 소켓은 xpeer의 것. xpeer는 덤프 트리에 없다."

    "$CRIU" dump -t "$WP" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1; DRC=$?
    obs 2 "CRIU dump — 뭐라고 하나?"
    cmd "criu dump -t $WP ... ; echo \$?"
    out "rc = $DRC   $([[ $DRC -ne 0 ]] && echo '❌ 거부' || echo '✅ 통과')"
    if [[ $DRC -ne 0 ]]; then
      cmd "grep -m1 'Error (' img/dump.log"
      grep -m1 "Error (" "$C/img/dump.log" | cut -c1-88 | sed 's/^/          /'
      out "▶ CRIU가 정직하게 거부했다. 이미지 자체가 만들어지지 않는다."
    else
      "$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1; RRC=$?
      obs 3 "dump는 통과했다 → restore는?"
      cmd "criu restore -D img ... ; echo \$?"
      out "rc = $RRC   $([[ $RRC -ne 0 ]] && echo '❌ 실패' || echo '✅ 통과')"
      cmd "grep -m1 'Error (' img/restore.log"
      grep -m1 "Error (" "$C/img/restore.log" | cut -c1-88 | sed 's/^/          /'
      out "▶ 이미지는 멀쩡히 만들어졌다. 되살려 보기 전엔 아무도 모른다."
      [[ -f "$C/pid" ]] && kill -9 "$(cat $C/pid)" 2>/dev/null
    fi
    pkill -9 -f "bin/$WL --port $PORT" 2>/dev/null; kill -9 $XP 2>/dev/null; sleep 0.3
  done
  echo; out "▶ 대조: 허브를 함께 얼리면(fp_w_hub) 전 지점 통과한다 — 경계가 전부다."
}

# ═══════════════ ② TCP ═══════════════
cap_tcp(){
  head2 "② TCP 클라이언트 — CRIU는 거부하지 않는다 (대조군)" \
        "워크로드: fp_x_ext_tcp_pend      서버: 별도 프로세스 = 덤프 트리 밖, accept 안 함"
  WL=fp_x_ext_tcp_pend; PORT=$((28700 + RANDOM % 100))
  [[ -x "$BIN/$WL" ]] || { echo "  [skip] $WL 미빌드"; return; }
  C=/tmp/cap_tcp; rm -rf "$C"; mkdir -p "$C/img"
  "$XPEER" --port "$PORT" --no-accept > "$C/peer.log" 2>&1 & XP=$!
  sleep 0.5
  "$BIN/$WL" --port "$PORT" --bytes 8388608 --phase_gap_ms 400 > "$C/wl.log" 2>&1 & WP=$!
  wait_phase "$C/wl.log" "f_ext_tcp_pend_l04" || { echo "  phase 미도달"; kill -9 $XP $WP 2>/dev/null; return; }

  obs 1 "덤프 순간의 커널 상태 — 임자 없는 연결은 누구 쪽에 있나"
  cmd "cat /proc/net/tcp   # 상태 01=ESTABLISHED, inode=0 = 어느 fd에도 안 붙음"
  python3 - "$PORT" <<'PY' | sed 's/^/          /'
import sys
sp = int(sys.argv[1]) + 3000
for ln in open('/proc/net/tcp').readlines()[1:]:
    f = ln.split(); lp = int(f[1].split(':')[1], 16); rp = int(f[2].split(':')[1], 16)
    if sp in (lp, rp):
        st = {'01':'ESTABLISHED','02':'SYN_SENT','0A':'LISTEN'}.get(f[3], f[3])
        tag = '  <- 임자 없음 (서버 백로그, 덤프 밖)' if f[9]=='0' and st=='ESTABLISHED' else ''
        print(f"local={lp:<6} remote={rp:<6} {st:<12} inode={f[9]}{tag}")
PY
  out "→ inode=0인 소켓은 서버(덤프 밖) 쪽이다. 우리는 클라이언트 소켓만 쥐고 있다."

  "$CRIU" dump -t "$WP" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1; DRC=$?
  obs 2 "CRIU dump"; cmd "criu dump -t $WP ... ; echo \$?"
  out "rc = $DRC   $([[ $DRC -eq 0 ]] && echo '✅ 거부하지 않는다')"
  "$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" >/dev/null 2>&1; RRC=$?
  obs 3 "CRIU restore + 복원된 소켓이 살아 있나"
  cmd "criu restore ... ; echo \$?"; out "rc = $RRC   $([[ $RRC -eq 0 ]] && echo '✅')"
  sleep 1
  cmd "cat /proc/net/tcp   # 복원 후"
  python3 - "$PORT" <<'PY' | sed 's/^/          /'
import sys
sp = int(sys.argv[1]) + 3000
for ln in open('/proc/net/tcp').readlines()[1:]:
    f = ln.split(); lp = int(f[1].split(':')[1], 16); rp = int(f[2].split(':')[1], 16)
    if sp in (lp, rp) and f[9] != '0':
        st = {'01':'ESTABLISHED','02':'SYN_SENT','0A':'LISTEN'}.get(f[3], f[3])
        print(f"local={lp:<6} remote={rp:<6} {st:<12} inode={f[9]}  <- 클라이언트 소켓, 복원됨")
PY
  out "▶ 리스너의 백로그를 함께 덤프하면 sk-inet.c:185로 거부된다. 그러나 webOS는 클라이언트다."
  pkill -9 -f "bin/$WL --port $PORT" 2>/dev/null; kill -9 $XP 2>/dev/null
  [[ -f "$C/pid" ]] && kill -9 "$(cat $C/pid)" 2>/dev/null
}

# ═══════════════ ③ 메모리 ═══════════════
cap_mem(){
  local MODE=$1 PH LABEL
  if [[ "$MODE" == heavy ]]; then PH=f_large_heap;     LABEL="③-a 무거운 이미지 (힙 실체화 후) — CRIU가 거부한다";
  else                            PH=f_large_heap_l01; LABEL="③-b 가벼운 이미지 (malloc만) — 거부하지 않는다. 그런데 죽는다 ★"; fi
  head2 "$LABEL" "워크로드: fp_w_qml_app      복원 예산: cgroup memory.max = 300MB"
  local WL=fp_w_qml_app CG=/sys/fs/cgroup/criu_cap C=/tmp/cap_mem_$MODE
  [[ -x "$BIN/$WL" ]] || { echo "  [skip] $WL 미빌드"; return; }
  rm -rf "$C"; mkdir -p "$C/img"
  "$BIN/$WL" --port 28800 --bytes 8388608 --phase_gap_ms 400 > "$C/wl.log" 2>&1 & WP=$!
  wait_phase "$C/wl.log" "$PH" || { echo "  phase 미도달"; kill -9 $WP 2>/dev/null; return; }
  local RSS=$(( $(awk '/VmRSS/{print $2}' /proc/$WP/status) / 1024 ))
  obs 0 "덤프 직전 — 이미지가 짊어질 무게"
  cmd "grep VmRSS /proc/$WP/status"; out "VmRSS:  ${RSS} MB"
  "$CRIU" dump -t "$WP" -D "$C/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1; local DRC=$?
  pkill -9 -f "bin/$WL --port 28800" 2>/dev/null
  obs 1 "CRIU dump"; cmd "criu dump ... ; echo \$?"; out "rc = $DRC"
  [[ $DRC -ne 0 ]] && return

  obs "1.5" "이미지가 실제로 얼마나 무거운가 — 이게 운명을 가른다"
  cmd "du -sh img/"
  out "$(du -sh "$C/img" 2>/dev/null | cut -f1)"
  cmd "ls -lh img/pages-*.img"
  ls -lh "$C/img"/pages-*.img 2>/dev/null | awk '{printf "%-8s %s\n", $5, $9}' | sed 's/^/          /'
  if [[ "$MODE" == heavy ]]; then
    out "→ 페이지 데이터가 통째로 들어 있다. restore가 이걸 전부 메모리에 올려야 한다."
  else
    out "→ malloc은 주소만 예약했을 뿐 물리 페이지가 없다(VMA 메모만).\n          restore는 올릴 게 거의 없다 — 가뿐히 성공한다. 문제는 그 다음이다."
  fi

  rmdir "$CG" 2>/dev/null; mkdir -p "$CG"
  echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
  echo $((300*1048576)) > "$CG/memory.max"; echo 0 > "$CG/memory.swap.max"
  ( echo $BASHPID > "$CG/cgroup.procs"
    exec "$CRIU" restore -d -D "$C/img" -v4 -o restore.log --pidfile "$C/pid" "${OPTS[@]}" ) >/dev/null 2>&1
  local RRC=$? RPID NERR
  RPID=$(cat "$C/pid" 2>/dev/null || echo 0)
  NERR=$(grep -c "Error (" "$C/img/restore.log" 2>/dev/null || echo 0)

  obs 2 "CRIU restore — 300MB 예산 안에서"
  cmd "criu restore ... ; echo \$?"; out "rc = $RRC   $([[ $RRC -ne 0 ]] && echo '❌ 거부' || echo '✅ 성공')"
  cmd "grep -c 'Error (' img/restore.log"; out "$NERR   $([[ $NERR -eq 0 ]] && echo '← 에러 한 줄도 없음')"
  if [[ $RRC -ne 0 ]]; then
    grep -m1 "Error (" "$C/img/restore.log" | cut -c1-88 | sed 's/^/          /'
    echo; out "▶ 판정: 정직한 실패. 복원 중 페이지를 매핑하다 한도에 부딪혔고, CRIU가 알려줬다."
    rmdir "$CG" 2>/dev/null; return
  fi
  obs 3 "복원 직후 — 살아 있나?  (운영 스크립트가 보통 확인하는 마지막 지점)"
  cmd "ps -o pid,rss,state,comm -p $RPID"
  ps -o pid,rss,state,comm -p "$RPID" 2>/dev/null | sed 's/^/          /'
  out "→ 살아 있다. RSS도 작다. 여기까지 보면 완벽한 성공이다."
  out "⏳ 5초 대기 — 복원된 프로세스가 재개해서 for 문으로 힙을 채우기 시작한다..."
  sleep 5
  obs 4 "5초 뒤 — 아직 살아 있나?"
  cmd "ps -o pid,rss,state,comm -p $RPID"
  if ps -o pid= -p "$RPID" >/dev/null 2>&1; then
    ps -o pid,rss,state,comm -p "$RPID" | sed 's/^/          /'
  else
    out "(출력 없음)                        ☠  사라졌다"
  fi
  obs 5 "진짜 사인(死因) — CRIU 로그가 아니라 커널에 있다"
  cmd "cat /sys/fs/cgroup/criu_cap/memory.events"
  grep -E "oom" "$CG/memory.events" 2>/dev/null | sed 's/^/          /'
  cmd "dmesg | grep -i 'out of memory' | tail -1"
  dmesg 2>/dev/null | grep -i "out of memory" | tail -1 | cut -c1-100 | sed 's/^/          /'
  echo
  if ! ps -o pid= -p "$RPID" >/dev/null 2>&1; then
    out "▶ 판정: 침묵형 실패 ★"
    out "   CRIU: rc=0 · 에러 0줄 · 복원 직후 생존.   현실: 5초 뒤 시체."
    out "   CRIU는 자기 일을 정확히 했다. 죽인 것은 커널이고, 기록은 CRIU 로그에 없다."
  fi
  kill -9 "$RPID" 2>/dev/null; rmdir "$CG" 2>/dev/null
}

case "${1:-all}" in
  hub-ok)    cap_hub_ok ;;                       # ①-A 허브 함께 → 통과
  hub)       cap_hub ;;                          # ①-B 허브 밖   → 거부
  tcp)       cap_tcp ;;                          # ②   클라이언트 → 거부 안 함
  mem-heavy) cap_mem heavy ;;                    # ③-a 무거운 이미지 → 거부
  mem-light) cap_mem light ;;                    # ③-b 가벼운 이미지 → 침묵 ★
  all)       cap_hub_ok; echo; cap_hub; echo; cap_tcp; echo; cap_mem heavy; echo; cap_mem light ;;
  *) echo "usage: sudo $0 [hub-ok|hub|tcp|mem-heavy|mem-light|all]"; exit 1 ;;
esac
