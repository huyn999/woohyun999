#!/usr/bin/env bash
# pbsprobe/world_up.sh — 상시 배경 세계(webOS 근사) 기동
#
# 구성:
#   world hub      pbs_hub 1개 (고정 포트, 재등록 flood 지원) — ls-hubd의 자리
#   상주 서비스     pbs_mock 소형 인스턴스 ×N — sam/memd/audiod 등 상주 데몬의 자리.
#                  각자 hub에 등록하고 주기 refresh로 버스에 '소음'을 만든다
#   (선택) TV 물리  WORLD_CONSTRAINED=1: scenario.yaml의 cgroup(memory/cpu/cpuset)
#                  + stress-ng 상주 — 세계 전체가 TV의 자원 예산 안에서 산다
#   (선택) memd    cgroup이 있으면 LMK 모사: memory.current가 문턱(92%)을 넘으면
#                  cgroup 안 최대 RSS pbs_mock을 SIGKILL하고 기록
#
# 사용:
#   pbsprobe/world_up.sh                      # 가벼운 세계 (cgroup 없음 — 어디서나)
#   WORLD_CONSTRAINED=1 sudo pbsprobe/world_up.sh   # TV 물리 포함
#   WORLD_PORT=21000 WORLD_SVCS=3 WORLD_FLOOD=300 ...
#
# 이후: WORLD=1 [sudo] pbsprobe/pbs_sweep.sh  → 셀들이 이 세계에 attach해 실행
# 상태: pbsprobe/world_status.sh / 종료: pbsprobe/world_down.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
WD="$DIR/results/world"
WORLD_PORT="${WORLD_PORT:-21000}"
WORLD_SVCS="${WORLD_SVCS:-3}"
WORLD_FLOOD="${WORLD_FLOOD:-300}"
WORLD_CONSTRAINED="${WORLD_CONSTRAINED:-0}"

[[ -x "$DIR/bin/pbs_hub" && -x "$ROOT/testbed/workloads/bin/pbs_mock" ]] \
	|| { echo "ERROR: 먼저 pbsprobe/build.sh"; exit 1; }
if [[ -f "$WD/state.env" ]]; then
	echo "ERROR: 세계가 이미 떠 있음 — pbsprobe/world_down.sh 먼저"; exit 1
fi
mkdir -p "$WD"

WORLD_CG=""
if [[ "$WORLD_CONSTRAINED" == "1" ]]; then
	[[ $EUID -eq 0 ]] || { echo "ERROR: WORLD_CONSTRAINED=1은 root 필요"; exit 1; }
	command -v stress-ng >/dev/null || { echo "ERROR: stress-ng 필요"; exit 1; }
	[[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]] || { echo "ERROR: cgroup v2 필요"; exit 1; }
	SCEN_Y="$ROOT/testbed/scenario.yaml"
	read -r MEM_MAX SWAP_MAX CPU_MAX CPUSET CPUN VMW VMB FLOOR SAT <<< "$(python3 - "$SCEN_Y" <<-'PYEOF'
	import sys, yaml, re
	c = yaml.safe_load(open(sys.argv[1]))
	def b(v):
	    s=str(v); m=re.match(r"([0-9.]+)([KMGT]?)",s)
	    return int(float(m.group(1))*{"":1,"K":2**10,"M":2**20,"G":2**30,"T":2**40}[m.group(2)])
	mem=c["memory"]; cpu=c["cpu"]; st=c["stress"]
	def ncpu(s):
	    n=0
	    for part in str(s).split(","):
	        if "-" in part: lo,hi=part.split("-"); n+=int(hi)-int(lo)+1
	        else: n+=1
	    return n
	print(b(mem["max"]), b(mem.get("swap_max",0)),
	      f'{int(float(cpu["bandwidth_cores"])*100000)}:100000',
	      cpu["cpuset_cpus"], ncpu(cpu["cpuset_cpus"]),
	      st["vm_workers"], b(st["vm_bytes"]), int(st.get("floor_mib",38)),
	      1 if st.get("cpu_saturate") else 0)
	PYEOF
)"
	WORLD_CG="/sys/fs/cgroup/pbsprobe_world"
	mkdir -p "$WORLD_CG"
	echo "+memory +cpu +cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
	echo "$MEM_MAX"  > "$WORLD_CG/memory.max"
	echo "$SWAP_MAX" > "$WORLD_CG/memory.swap.max"
	echo "${CPU_MAX/:/ }" > "$WORLD_CG/cpu.max"
	echo "$CPUSET"   > "$WORLD_CG/cpuset.cpus"
	echo "+memory" > "$WORLD_CG/cgroup.subtree_control" 2>/dev/null || true
	mkdir -p "$WORLD_CG/run"          # 프로세스 leaf (internal-process 금지 규칙 대응)
	DATA_MB=$(( VMB/1048576 - FLOOR )); [[ $DATA_MB -lt 1 ]] && DATA_MB=1
	for _i in $(seq 1 "$VMW"); do
		( echo "$BASHPID" > "$WORLD_CG/run/cgroup.procs" && exec stress-ng --timeout 7d --vm 1 \
		  --vm-bytes "${DATA_MB}M" --vm-keep --vm-populate --vm-hang 0 ) > /dev/null 2>&1 &
	done
	[[ "$SAT" == "1" ]] && ( echo "$BASHPID" > "$WORLD_CG/run/cgroup.procs" && exec stress-ng --timeout 7d --cpu "$CPUN" ) > /dev/null 2>&1 &
	TGT=$(( VMW * VMB ))
	for i in $(seq 1 45); do
		sleep 2
		CUR=$(cat "$WORLD_CG/memory.current" 2>/dev/null || echo 0)
		(( CUR >= TGT * 90 / 100 )) && break
	done
	for p in $(cat "$WORLD_CG/run/cgroup.procs" 2>/dev/null); do
		{ echo -800 > "/proc/$p/oom_score_adj"; } 2>/dev/null
	done
	echo "[world] TV 물리: mem.max=$((MEM_MAX/1048576))M stress 정착 $((CUR/1048576))M/$((TGT/1048576))M"
fi

launch() {   # $1=cmdline $2=log — cgroup(있으면) 안에서 자체 세션 기동
	if [[ -n "$WORLD_CG" ]]; then
		setsid bash -c "echo \$\$ > '$WORLD_CG/run/cgroup.procs' && exec $1" > "$2" 2>&1 < /dev/null &
	else
		setsid bash -c "exec $1" > "$2" 2>&1 < /dev/null &
	fi
}

# hub는 얼릴 수 없는 세계이므로 cgroup 밖 (실기 ls-hubd의 자리)
setsid "$DIR/bin/pbs_hub" --port "$WORLD_PORT" --pending 2 --feed reqresp \
	--flood_on_rereg "$WORLD_FLOOD" > "$WD/hub.log" 2>&1 < /dev/null &
for _i in $(seq 1 100); do grep -q "HUB ready" "$WD/hub.log" 2>/dev/null && break; sleep 0.05; done
grep -q "HUB ready" "$WD/hub.log" || { echo "ERROR: world hub 기동 실패"; exit 1; }

# 상주 서비스: 소형 pbs_mock ×N — 버스 소음(refresh마다 로그 틱)과 배경 RSS
for i in $(seq 1 "$WORLD_SVCS"); do
	sp=$(( WORLD_PORT + 10 + i ))
	launch "'$ROOT/testbed/workloads/bin/pbs_mock' --port $sp --hub_port $WORLD_PORT \
	  --db_mib 1 --index_mib 6 --parse_iters 5000 --hub_conns 2 --hub_pending 1 \
	  --log_dgram 1 --refresh_ms 700 --refresh_kib 64 --timer 1 --timer_s 30 \
	  --watch 0 --phase_gap_ms 0" "$WD/svc$i.log"
done
sleep 1

# memd(LMK 모사): cgroup이 있을 때만 의미 — 92% 문턱에서 최대 RSS pbs_mock 처형
if [[ -n "$WORLD_CG" ]]; then
	setsid bash -c '
		CG="'"$WORLD_CG"'"; LOG="'"$WD"'/memd.log"
		MAX=$(cat "$CG/memory.max"); THR=$(( MAX / 100 * 92 ))
		echo "MEMD up thr=$((THR/1048576))M" >> "$LOG"
		while sleep 1; do
			CUR=$(cat "$CG/memory.current" 2>/dev/null) || break
			if (( CUR > THR )); then
				VICTIM=$(for p in $(cat "$CG/run/cgroup.procs"); do
					comm=$(cat /proc/$p/comm 2>/dev/null)
					[[ "$comm" == pbs_mock ]] || continue
					rss=$(awk "/VmRSS/{print \$2}" /proc/$p/status 2>/dev/null)
					echo "${rss:-0} $p"
				done | sort -rn | head -1 | cut -d" " -f2)
				if [[ -n "$VICTIM" ]]; then
					RSS=$(awk "/VmRSS/{print \$2}" /proc/$VICTIM/status 2>/dev/null)
					kill -9 "$VICTIM" && echo "MEMD kill pid=$VICTIM rss_kib=$RSS cur=$((CUR/1048576))M" >> "$LOG"
					sleep 2
				fi
			fi
		done' > /dev/null 2>&1 < /dev/null &
	echo "MEMD_PID=$!" >> "$WD/state.env.tmp"
fi

cat >> "$WD/state.env.tmp" <<EOF
WORLD_PORT=$WORLD_PORT
WORLD_CG=$WORLD_CG
WORLD_CG_RUN=${WORLD_CG:+$WORLD_CG/run}
WORLD_T0=$(date +%s)
WORLD_SVCS=$WORLD_SVCS
WORLD_FLOOD=$WORLD_FLOOD
EOF
mv "$WD/state.env.tmp" "$WD/state.env"
regs=$(grep -c "HUB register" "$WD/hub.log" || true)
echo "[world] UP — hub@$WORLD_PORT, 상주 서비스 $WORLD_SVCS (등록 $regs), cgroup='${WORLD_CG:-없음}'"
echo "[world] 다음: WORLD=1 [sudo] pbsprobe/pbs_sweep.sh   상태: pbsprobe/world_status.sh"
