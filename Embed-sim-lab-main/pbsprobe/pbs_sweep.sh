#!/usr/bin/env bash
# pbsprobe/pbs_sweep.sh — pbs 모사 dump/restore 상황 매트릭스 스윕
#
# scenarios.csv(gen_scenarios.py)의 각 행을 셀 1개로 실행한다:
#   [hub/feed 기동] → [pbs_mock 기동(자체 세션)] → [phase 대기] → [pre_dump 처방]
#   → [criu dump] → [post_dump 조작] → [criu restore(선택: memory.max cgroup 안)]
#   → [resume 신호] → [검증: PONG/STAT(crc)/hub 재등록/TCP 왕복/5s 생존/resume]
#   → CSV 1행 + 판정
#
# compat_sweep.sh와의 의도적 차이:
#   - --shell-job를 쓰지 않는다. pbs_mock을 setsid로 자체 세션 리더로 띄운다 —
#     실제 TV의 데몬 형태와 같고, --shell-job 하네스 아티팩트를 제거한다.
#   - 시간을 재지 않는다(판정 전용). 시간 측정은 계약 준수 플러그인이므로
#     기존 run_once.sh/run_cold_start.sh 로 그대로 돌리면 된다.
#
# Usage:
#   sudo pbsprobe/pbs_sweep.sh                  # 전체 (scenarios.csv 전 행)
#   sudo pbsprobe/pbs_sweep.sh 'B_*'            # glob (scenario 이름 기준)
#   ONLY_FAMILY=C sudo pbsprobe/pbs_sweep.sh    # 가족 필터
#   RESUME=1 sudo ...                           # 기존 CSV 완료 셀 skip
#   CONSTRAINED=1 sudo ...                      # TV 제약 모드 (compat_sweep와 동일 구성):
#                                               #  scenario.yaml의 memory.max/swap/cpu.max/
#                                               #  cpuset + stress-ng 배경부하 상주 +
#                                               #  loop+dm-delay+io.max 느린 디스크에 CRIU
#                                               #  이미지 읽고 씀. CSV는 _tv로 분리 저장
#   DRYRUN=1 pbsprobe/pbs_sweep.sh              # criu 없이 배관 검증 (root 불필요,
#                                               #  검증은 살아있는 원본에 대해 수행)
#   CRIU_BIN=/path/criu sudo ...                # CRIU 지정 (기본: testbed/criu/bin/criu)
#   PHASE_TIMEOUT_S=30 / VERIFY_TIMEOUT_S=8
#
# 산출물: pbsprobe/results/pbs_matrix[_tv].csv, 셀 로그 pbsprobe/results/runs/<셀>/
set -uo pipefail   # -e 없음: 셀 실패가 스윕을 죽이면 안 된다

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
TESTBED="$ROOT/testbed"
BIN_WL="$TESTBED/workloads/bin/pbs_mock"
BIN_WL_LBL="$TESTBED/workloads/bin/pbs_mock_lbl"
BIN_HUB="$DIR/bin/pbs_hub"
BIN_PROBE="$DIR/bin/pbs_probe"
SCEN="$DIR/scenarios.csv"
RESULTS="$DIR/results"; RUNS="$RESULTS/runs"
DRYRUN="${DRYRUN:-0}"
CONSTRAINED="${CONSTRAINED:-0}"
WORLD="${WORLD:-0}"
WORLD_PORT=""; WORLD_CG=""
if [[ "$WORLD" == "1" ]]; then
	[[ -f "$RESULTS/world/state.env" ]] || { echo "ERROR: 세계 없음 — pbsprobe/world_up.sh 먼저" >&2; exit 1; }
	# shellcheck disable=SC1091
	source "$RESULTS/world/state.env"
	[[ "$CONSTRAINED" == "1" ]] && { echo "ERROR: WORLD=1은 CONSTRAINED와 함께 못 씀 (세계가 물리를 소유 — WORLD_CONSTRAINED=1 world_up)" >&2; exit 1; }
	CSV="$RESULTS/pbs_matrix_world.csv"
	PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-40}"
elif [[ "$CONSTRAINED" == "1" ]]; then
	CSV="$RESULTS/pbs_matrix_tv.csv"
	PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-40}"   # CPU saturate로 느려짐 감안 (compat_sweep 권장치)
else
	CSV="$RESULTS/pbs_matrix.csv"
	PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-25}"
fi
VERIFY_TIMEOUT_S="${VERIFY_TIMEOUT_S:-8}"
GLOB="${1:-*}"

# CRIU 결정: env > testbed vendoring > 소스 빌드 관례 위치 > PATH
CRIU="${CRIU_BIN:-}"
if [[ -z "$CRIU" ]]; then
	for c in "$TESTBED/criu/bin/criu" "$HOME/criu-src/criu/criu" "/home/claude/criu-src/criu/criu"; do
		[[ -x "$c" ]] && { CRIU="$c"; break; }
	done
	[[ -z "$CRIU" ]] && CRIU="$(command -v criu || true)"
fi
if [[ "$DRYRUN" != "1" ]]; then
	[[ -x "$CRIU" ]] || { echo "ERROR: criu 없음 — CRIU_BIN 지정 또는 testbed/criu/build.sh" >&2; exit 1; }
	[[ $EUID -eq 0 ]] || { echo "ERROR: root 필요 (criu dump/restore). 배관만 보려면 DRYRUN=1" >&2; exit 1; }
fi
for b in "$BIN_WL" "$BIN_HUB" "$BIN_PROBE"; do
	[[ -x "$b" ]] || { echo "ERROR: $b 없음 — pbsprobe/build.sh 먼저" >&2; exit 1; }
done
[[ -f "$SCEN" ]] || { echo "ERROR: $SCEN 없음 — python3 pbsprobe/gen_scenarios.py 먼저" >&2; exit 1; }

mkdir -p "$RUNS"

# ── TV 제약 모드: scenario.yaml의 memory/cpu/stress/storage 조건을 스윕 전체에 1회
#    적용 (failprobe/compat_sweep.sh의 검증된 블록 이식 — 동일 구성·동일 값 소스) ──
CG_TV=""
if [[ "$CONSTRAINED" == "1" ]]; then
	[[ "$DRYRUN" == "1" ]] && { echo "ERROR: CONSTRAINED=1은 DRYRUN과 함께 쓸 수 없음" >&2; exit 1; }
	command -v stress-ng >/dev/null || { echo "ERROR: stress-ng 필요 (CONSTRAINED)" >&2; exit 1; }
	[[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]] || { echo "ERROR: cgroup v2 필요" >&2; exit 1; }
	CG_TV="/sys/fs/cgroup/pbsprobe_tv_sweep"
	SCEN_Y="$TESTBED/scenario.yaml"
	read -r MEM_MAX SWAP_MAX CPU_MAX CPUSET CPUN VMW VMB FLOOR SAT SCAP SRB SWB SDR SDW <<< "$(python3 - "$SCEN_Y" <<-'PYEOF'
	import sys, yaml, re
	c = yaml.safe_load(open(sys.argv[1]))
	def b(v):
	    s=str(v); m=re.match(r"([0-9.]+)([KMGT]?)",s)
	    mul={"":1,"K":2**10,"M":2**20,"G":2**30,"T":2**40}[m.group(2)]
	    return int(float(m.group(1))*mul)
	mem=c["memory"]; cpu=c["cpu"]; st=c["stress"]
	img=c.get("storage",{}).get("image",{}); dl=img.get("delay",{})
	quota=int(float(cpu["bandwidth_cores"])*100000)
	def ncpu(s):
	    n=0
	    for part in str(s).split(","):
	        if "-" in part: lo,hi=part.split("-"); n+=int(hi)-int(lo)+1
	        else: n+=1
	    return n
	print(b(mem["max"]), b(mem.get("swap_max",0)), f"{quota}:100000",
	      cpu["cpuset_cpus"], ncpu(cpu["cpuset_cpus"]), st["vm_workers"], b(st["vm_bytes"]),
	      int(st.get("floor_mib",38)), 1 if st.get("cpu_saturate") else 0,
	      b(img.get("capacity","2G")), b(img.get("rbps","150M")), b(img.get("wbps","50M")),
	      int(dl.get("read_ms",1)) if dl.get("enabled",True) else 0,
	      int(dl.get("write_ms",3)) if dl.get("enabled",True) else 0)
	PYEOF
)"
	echo "[env] TV 제약: memory.max=$MEM_MAX swap=$SWAP_MAX cpu=$CPU_MAX cpuset=$CPUSET stress=${VMW}x$((VMB/1048576))M(floor ${FLOOR}M) sat=$SAT"
	mkdir -p "$CG_TV"
	echo "+memory +cpu +cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
	echo "$MEM_MAX"  > "$CG_TV/memory.max"
	echo "$SWAP_MAX" > "$CG_TV/memory.swap.max"
	echo "${CPU_MAX/:/ }" > "$CG_TV/cpu.max"
	echo "$CPUSET"   > "$CG_TV/cpuset.cpus"
	# 느린 eMMC 모사: loop + dm-delay + io.max — CRIU 이미지가 이 디스크로 쓰이고 읽힘
	TVIMG_DIR="$RESULTS/tvimg"; TVIMG_FILE="$RESULTS/tvimg.img"; DM_NAME="pbsprobe_tvimg"
	umount "$TVIMG_DIR" 2>/dev/null
	dmsetup remove "$DM_NAME" 2>/dev/null
	losetup -j "$TVIMG_FILE" 2>/dev/null | cut -d: -f1 | xargs -r losetup -d 2>/dev/null
	rm -f "$TVIMG_FILE"; mkdir -p "$TVIMG_DIR"
	truncate -s "$SCAP" "$TVIMG_FILE"
	LOOP_DEV="$(losetup -f --show "$TVIMG_FILE")" \
		|| { echo "[env] ERROR: losetup 실패 — 스토리지 제약 구성 불가. 중단." >&2; exit 1; }
	SECTORS=$(blockdev --getsz "$LOOP_DEV")
	if (( SDR > 0 || SDW > 0 )); then
		modprobe dm_delay 2>/dev/null || true
		dmsetup create "$DM_NAME" --table "0 $SECTORS delay $LOOP_DEV 0 $SDR $LOOP_DEV 0 $SDW" \
			|| { echo "[env] ERROR: dm-delay 생성 실패 (modprobe dm_delay 확인). 중단." >&2; exit 1; }
		IMG_DEV="/dev/mapper/$DM_NAME"
	else
		IMG_DEV="$LOOP_DEV"
	fi
	mkfs.ext4 -q -F "$IMG_DEV" || { echo "[env] ERROR: mkfs 실패 ($IMG_DEV). 중단." >&2; exit 1; }
	mount "$IMG_DEV" "$TVIMG_DIR" || { echo "[env] ERROR: mount 실패. 중단." >&2; exit 1; }
	mountpoint -q "$TVIMG_DIR" || { echo "[env] ERROR: 마운트 검증 실패. 중단." >&2; exit 1; }
	DEV_MM="$(dmsetup info -c --noheadings -o major,minor "$DM_NAME" 2>/dev/null | tr -d ' ')"
	[[ -z "$DEV_MM" ]] && DEV_MM="$(stat -c '%Hr:%Lr' "$LOOP_DEV" 2>/dev/null)"
	if [[ -n "$DEV_MM" ]] && echo "+io" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
		echo "$DEV_MM rbps=$SRB wbps=$SWB" > "$CG_TV/io.max" 2>/dev/null \
			|| echo "[env] WARN: io.max 설정 실패 — 대역폭 제한 없이 delay만 적용"
	fi
	echo "[env] storage: $IMG_DEV → $TVIMG_DIR (delay r${SDR}ms/w${SDW}ms, rbps=$SRB wbps=$SWB)"
	# stress 상주: 독립 인스턴스 × VMW개 (단일 --vm N은 상주 안 함 — 원저자 실측)
	DATA_MB=$(( VMB/1048576 - FLOOR )); [[ $DATA_MB -lt 1 ]] && DATA_MB=1
	STRESS_PIDS=()
	for _i in $(seq 1 "$VMW"); do
		( echo "$BASHPID" > "$CG_TV/cgroup.procs" && exec stress-ng --timeout 1d --vm 1 --vm-bytes "${DATA_MB}M" \
		  --vm-keep --vm-populate --vm-hang 0 ) > /dev/null 2>&1 &
		STRESS_PIDS+=($!)
	done
	if [[ "$SAT" == "1" ]]; then
		( echo "$BASHPID" > "$CG_TV/cgroup.procs" && exec stress-ng --timeout 1d --cpu "$CPUN" ) > /dev/null 2>&1 &
		STRESS_PIDS+=($!)
	fi
	TGT=$(( VMW * VMB )); CUR=0
	for i in $(seq 1 45); do
		sleep 2
		CUR=$(cat "$CG_TV/memory.current" 2>/dev/null || echo 0)
		(( CUR >= TGT * 90 / 100 )) && break
	done
	echo "[env] stress 정착: memory.current=$((CUR/1048576))MB (목표 $((TGT/1048576))MB, $((i*2))s)"
	prot=0
	for p in $(cat "$CG_TV/cgroup.procs" 2>/dev/null); do
		{ echo -800 > "/proc/$p/oom_score_adj"; } 2>/dev/null && prot=$((prot+1))
	done
	echo "[env] oom-protect: $prot proc(s) -> oom_score_adj=-800"
	if (( CUR < TGT * 85 / 100 )); then
		echo "[env] ERROR: 점유 85% 미달 — floor_mib 확인 또는 stress 기동 실패. 중단." >&2
		exit 1
	fi
	cleanup_env() {
		kill -9 "${STRESS_PIDS[@]}" 2>/dev/null; pkill -9 -f "stress-ng" 2>/dev/null; sleep 0.3
		for p in $(cat "$CG_TV/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
		sleep 0.2; rmdir "$CG_TV" 2>/dev/null
		umount "$TVIMG_DIR" 2>/dev/null
		dmsetup remove "$DM_NAME" 2>/dev/null
		[[ -n "${LOOP_DEV:-}" ]] && losetup -d "$LOOP_DEV" 2>/dev/null
	}
	trap cleanup_env EXIT
fi

if [[ "${RESUME:-0}" != "1" || ! -f "$CSV" ]]; then
	echo "scenario,family,phase,criu_opts,pre_dump,post_dump,restore_mem_mib,hub_mode,launch_ok,dump_rc,restore_rc,img_kib,v_pong,v_stat,v_hub,v_tcp,v_live5,v_resume,rereg_ms,verdict,world,dump_err,restore_err" > "$CSV"
fi

# ── 헬퍼 (compat_sweep와 동형) ────────────────────────────────────────────
wait_line() { # $1=log $2=regex $3=timeout_s [$4=최소 등장 횟수(기본 1)]
	local log="$1" re="$2" deadline=$(( $(date +%s) + $3 )) need="${4:-1}"
	while (( $(date +%s) < deadline )); do
		local n
		n=$(grep -cE "$re" "$log" 2>/dev/null || true)
		(( n >= need )) && return 0
		[[ -n "${WLPID:-}" ]] && ! kill -0 "$WLPID" 2>/dev/null && {
			n=$(grep -cE "$re" "$log" 2>/dev/null || true); (( n >= need )) && return 0 || return 1; }
		sleep 0.02
	done
	return 1
}
first_err() {
	[[ -f "$1" ]] || { echo ""; return; }
	grep -m1 -E "Error \(" "$1" | tr ',' ';' | tr -d '"' | cut -c1-300
}
probe() { # $1=port $2=cmd $3=timeout_s → 응답 stdout, 실패 시 빈 문자열
	local port="$1" cmd="$2" deadline=$(( $(date +%s) + $3 )) out=""
	while (( $(date +%s) < deadline )); do
		out="$("$BIN_PROBE" 127.0.0.1 "$port" 400 "$cmd" 2>/dev/null)" && { echo "$out"; return 0; }
		sleep 0.05
	done
	return 1
}
drop_criu_lock() { # CRIU가 dump 때 심은 netfilter 잠금 제거 (반증 실험) — best effort
	local log="$1" any=0
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet CRIU 2>>"$log" && { echo "droplock: nft inet CRIU" >>"$log"; any=1; }
	fi
	if command -v iptables >/dev/null 2>&1; then
		iptables -w -D INPUT -j CRIU 2>>"$log" && any=1
		iptables -w -D OUTPUT -j CRIU 2>>"$log" && any=1
		iptables -w -F CRIU 2>>"$log" && any=1
		iptables -w -X CRIU 2>>"$log" && { echo "droplock: iptables CRIU chain" >>"$log"; any=1; }
	fi
	echo "droplock done any=$any" >>"$log"
}
mem_cg_setup() { # $1=mib $2=name → cgroup 경로 echo (실패 시 빈 문자열)
	local mib="$1" name="$2" parent="${WORLD_CG:-${CG_TV:-/sys/fs/cgroup}}" cg
	cg="$parent/$name"                       # CONSTRAINED면 TV cgroup 아래 중첩 — 한도 합성
	mkdir -p "$cg" 2>/dev/null || { echo ""; return; }
	echo "+memory" > "$parent/cgroup.subtree_control" 2>/dev/null || true
	echo $(( mib * 1048576 )) > "$cg/memory.max" 2>/dev/null || { rmdir "$cg" 2>/dev/null; echo ""; return; }
	echo 0 > "$cg/memory.swap.max" 2>/dev/null || true
	echo "$cg"
}
mem_cg_teardown() {
	local cg="$1"
	[[ -z "$cg" || ! -d "$cg" ]] && return
	for p in $(cat "$cg/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	sleep 0.2
	rmdir "$cg" 2>/dev/null
}
do_restore() { # $1=img $2=pidfile $3=log-suffix $4=cg(옵션) → rc
	local img="$1" pidf="$2" suf="$3" cg="${4:-${WORLD_CG_RUN:-${WORLD_CG:-$CG_TV}}}"   # 셀 cg 없으면 세계/TV cgroup
	if [[ -n "$cg" ]]; then
		( echo "$BASHPID" > "$cg/cgroup.procs" && exec "$CRIU" restore -d -D "$img" -v4 -o "restore${suf}.log" --pidfile "$pidf" "${ROPTS[@]}" ) >/dev/null 2>&1
	else
		"$CRIU" restore -d -D "$img" -v4 -o "restore${suf}.log" --pidfile "$pidf" "${ROPTS[@]}" >/dev/null 2>&1
	fi
	return $?
}
kill_cell() { # $1=port
	local port="$1"
	pkill -9 -f "pbs_mock --port ${port} " 2>/dev/null
	pkill -9 -f "pbs_mock_lbl --port ${port} " 2>/dev/null
	pkill -9 -f "pbs_hub --port ${port} " 2>/dev/null
	pkill -9 -f "pbs_hub --port ${port}$" 2>/dev/null
	rm -f "/tmp/pbsprobe_db_p${port}.bin" "/dev/shm/pbsprobe_shm_p${port}" 2>/dev/null
	rm -rf "/tmp/pbsprobe_wd_p${port}" 2>/dev/null
	rm -f "/tmp/pbsprobe_journal_p${port}" 2>/dev/null
	pkill -f "pbsprobe_svc_p${port}" 2>/dev/null
	sleep 0.05
}

# ── scenarios.csv 파싱: 셸 안전 필드로 전개 (탭 구분, params는 base64) ──
mapfile -t CELLS < <(python3 - "$SCEN" <<-'PYEOF'
	import base64, csv, sys
	with open(sys.argv[1], newline="") as f:
	    for r in csv.DictReader(f):
	        p = base64.b64encode(r["params"].encode()).decode()
	        print("\t".join([r["scenario"], r["family"], r["phase"], r["criu_opts"],
	                         r["pre_dump"], r["post_dump"], r["restore_mem_mib"],
	                         r["hub_mode"], r["verify"], p]))
	PYEOF
)

PORT_BASE=22000
port_ctr=0
total=0
for line in "${CELLS[@]}"; do
	IFS=$'\t' read -r sc fam _ _ _ _ _ hm _ _ <<< "$line"
	[[ "$sc" == $GLOB ]] || continue
	[[ -n "${ONLY_FAMILY:-}" && "$fam" != "$ONLY_FAMILY" ]] && continue
	[[ "$fam" == "G" && "$WORLD" != "1" ]] && continue
	[[ "$WORLD" == "1" && ( "$hm" == "noaccept" || "$hm" == "down_after" ) ]] && continue
	total=$((total+1))
done
echo "[sweep] cells=$total criu=${CRIU:-<dryrun>} dryrun=$DRYRUN → $CSV"

done_n=0
for line in "${CELLS[@]}"; do
	IFS=$'\t' read -r sc fam ph copts pre post memmib hubmode verify pb64 <<< "$line"
	[[ "$sc" == $GLOB ]] || continue
	[[ -n "${ONLY_FAMILY:-}" && "$fam" != "$ONLY_FAMILY" ]] && continue
	if [[ "$fam" == "G" && "$WORLD" != "1" ]]; then continue; fi          # G는 세계 전용
	if [[ "$WORLD" == "1" && ( "$hubmode" == "noaccept" || "$hubmode" == "down_after" ) ]]; then
		continue                                                          # 공유 hub와 비호환
	fi
	if [[ "${RESUME:-0}" == "1" ]] && grep -q "^${sc}," "$CSV"; then continue; fi
	done_n=$((done_n+1))
	params="$(echo "$pb64" | base64 -d)"
	port=$((PORT_BASE + port_ctr)); port_ctr=$((port_ctr+1))
	cell="$RUNS/$sc"; rm -rf "$cell"; mkdir -p "$cell"
	if [[ -n "$CG_TV" && -d "$RESULTS/tvimg" ]]; then
		imgd="$RESULTS/tvimg/$sc"; rm -rf "$imgd"; mkdir -p "$imgd"
		ln -sfn "$imgd" "$cell/img"     # CRIU 이미지가 제약 디스크를 경유 (compat_sweep 규약)
	else
		mkdir -p "$cell/img"
	fi
	wlog="$cell/wl.log"; hlog="$cell/hub.log"; clog="$cell/cell.log"
	resume_f="$cell/resume"

	# CRIU 옵션 번역
	case "$copts" in
		strict)     OPTS=();                       ROPTS=() ;;
		ext_unix)   OPTS=(--ext-unix-sk);          ROPTS=(--ext-unix-sk) ;;
		tcp_est)    OPTS=(--tcp-established);      ROPTS=(--tcp-established) ;;
		filelocks)  OPTS=(--file-locks);           ROPTS=(--file-locks) ;;
		permissive) OPTS=(--tcp-established --ext-unix-sk --file-locks --link-remap --ghost-limit 64M)
		            ROPTS=(--tcp-established --ext-unix-sk --file-locks) ;;
		*)          OPTS=();                       ROPTS=() ;;
	esac

	# params에서 hub/feed 구성 추출
	tcpmode="none"
	[[ "$params" == *"--tcp reqresp"* ]] && tcpmode="reqresp"
	[[ "$params" == *"--tcp stream"* ]] && tcpmode="stream"
	pend="$(sed -n 's/.*--hub_pending \([0-9]*\).*/\1/p' <<< "$params")"; pend="${pend:-2}"

	# ── 1. hub/feed 기동 (덤프 경계 밖 세계) — WORLD 모드에선 세계 hub에 attach ──
	HUBPID=""
	if [[ "$WORLD" == "1" ]]; then
		hlog="$RESULTS/world/hub.log"          # 등록 카운트는 세계 hub 로그에서
	fi
	need_hub=0
	case "$hubmode" in normal|noaccept|down_after) need_hub=1 ;; esac
	if [[ "$WORLD" != "1" ]] && [[ "$need_hub" == 1 || "$tcpmode" != "none" ]]; then
		HARGS=(--port "$port" --pending "$pend" --feed "$tcpmode")
		[[ "$hubmode" == "noaccept" ]] && HARGS+=(--no-accept)
		[[ "$params" == *"--pass_fd"* ]] && HARGS+=(--pass_fd)
		setsid "$BIN_HUB" "${HARGS[@]}" > "$hlog" 2>&1 < /dev/null &
		HUBPID=$!
		if ! wait_line "$hlog" "HUB ready" 10; then
			# 1회 재시도 (순간 부하 방어)
			pkill -9 -f "pbs_hub --port ${port} " 2>/dev/null; sleep 0.3
			setsid "$BIN_HUB" "${HARGS[@]}" > "$hlog" 2>&1 < /dev/null &
			HUBPID=$!
			if ! wait_line "$hlog" "HUB ready" 10; then
				echo "[$done_n/$total] $sc: hub 기동 실패" | tee -a "$clog"
				printf '%s,%s,%s,%s,%s,%s,%s,%s,0,na,na,na,na,na,na,na,na,na,na,launch_fail,"","hub_launch_fail",""\n' \
					"$sc" "$fam" "$ph" "$copts" "$pre" "$post" "$memmib" "$hubmode" >> "$CSV"
				kill_cell "$port"; done_n=$((done_n+1)); continue
			fi
		fi
	fi
	reg_before=$(grep -cE "HUB register|RENDER conn" "$hlog" 2>/dev/null || true); reg_before=${reg_before:-0}

	# ── 1b. flock_wait 셀: DB 잠금을 선점해 앱을 syscall 안에서 재운다 ──
	HOLDER_PID=""
	if [[ "$params" == *flock_wait* ]]; then
		touch "/tmp/pbsprobe_db_p${port}.bin"
		( exec 9>>"/tmp/pbsprobe_db_p${port}.bin" && flock -x 9 && exec sleep 600 ) &
		HOLDER_PID=$!
		sleep 0.2
	fi

	# ── 2. pbs_mock 기동 (자체 세션 — --shell-job 불필요). CONSTRAINED면 TV cgroup 편입 ──
	wlbin="$BIN_WL"
	[[ "$params" == *"--lbl "* ]] && wlbin="$BIN_WL_LBL"
	extra=""
	[[ "$DRYRUN" == "1" && "$params" != *phase_gap_ms* ]] && extra="--phase_gap_ms 30"
	[[ "$WORLD" == "1" ]] && extra="$extra --hub_port $WORLD_PORT"
	if [[ "$WORLD" == "1" && -n "$WORLD_CG" ]]; then
		setsid bash -c "echo \$\$ > '${WORLD_CG_RUN:-$WORLD_CG}/cgroup.procs' && exec '$wlbin' --port $port --resume_file '$resume_f' $params $extra" > "$wlog" 2>&1 < /dev/null &
	elif [[ -n "$CG_TV" ]]; then
		setsid bash -c "echo \$\$ > '$CG_TV/cgroup.procs' && exec '$wlbin' --port $port --resume_file '$resume_f' $params $extra" > "$wlog" 2>&1 < /dev/null &
	else
		setsid bash -c "exec '$wlbin' --port $port --resume_file '$resume_f' $params $extra" > "$wlog" 2>&1 < /dev/null &
	fi
	sleep 0.1
	WLPID="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$wlog" | head -1)"
	for _ in $(seq 1 50); do
		[[ -n "$WLPID" ]] && break
		sleep 0.05
		WLPID="$(sed -n 's/^PHASE init pid=\([0-9]*\).*/\1/p' "$wlog" | head -1)"
	done

	launch_ok=1 dump_rc=na restore_rc=na img_kib=na
	v_pong=na v_stat=na v_hub=na v_tcp=na v_live5=na v_resume=na rereg_ms=na
	derr="" rerr="" verdict=""
	pre_stat=""

	if [[ -z "$WLPID" ]] || ! wait_line "$wlog" "^PHASE ${ph}( |$)" "$PHASE_TIMEOUT_S"; then
		launch_ok=0 verdict=launch_fail
		echo "[$done_n/$total] $sc: phase '$ph' 미도달" | tee -a "$clog"
	else
		# ── 3. pre_dump: 처방 (SIGUSR1 → hub 연결 해제 대기) ──
		if [[ "$pre" == "hubkill" && -n "$HUBPID" ]]; then
			kill -9 "$HUBPID" 2>/dev/null; HUBPID=""; sleep 0.4   # 송신자 사망 상태로 dump
		fi
		if [[ "$pre" == settle* ]]; then
			ms="${pre#settle}"; [[ -z "$ms" ]] && ms=600
			sleep "$(awk "BEGIN{print $ms/1000}")"   # 지정 시각까지 기동 진행 후 저격
		fi
		if [[ "$pre" == "bye" ]]; then
			kill -USR1 "$WLPID" 2>/dev/null
			wait_line "$wlog" "^PHASE hub_disconnected" 5 || echo "WARN: hub_disconnected 미관측" >> "$clog"
		fi
		# post-ready 셀이면 dump 직전 상태 스냅샷 (STAT) — 무결성 비교 기준
		if grep -q "^PHASE ready" "$wlog"; then
			pre_stat="$(probe "$port" STAT 3 || true)"
			echo "pre_stat: $pre_stat" >> "$clog"
		fi

		# ── 4. dump ──
		if [[ "$DRYRUN" == "1" ]]; then
			dump_rc=dry
		else
			"$CRIU" dump -t "$WLPID" -D "$cell/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
			dump_rc=$?
			derr="$(first_err "$cell/img/dump.log")"
			img_kib=$(du -sk "$cell/img" 2>/dev/null | cut -f1)
		fi

		# ── 5. post_dump 조작 + restore + 검증 ──
		if [[ "$post" == "verify_orig" ]]; then
			# dump 실패(예상)의 비파괴성: 원본이 여전히 건강한가
			out="$(probe "$port" PING 3 || true)"
			v_pong=$([[ "$out" == "PONG" ]] && echo ok || echo fail)
			if [[ "$verify" == *stat* ]]; then
				out="$(probe "$port" STAT 3 || true)"
				v_stat=$([[ -n "$out" ]] && echo ok || echo fail)
			fi
			if [[ "$verify" == *tcp* ]]; then
				a="$(probe "$port" TCPQ 3 || true)"; sleep 0.4; b="$(probe "$port" TCPQ 3 || true)"
				ra="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$a")"; rb="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$b")"
				if [[ "$a" == *"mode=stream"* ]]; then
					v_tcp=$([[ -n "$ra" && -n "$rb" && "$rb" -gt "$ra" ]] && echo ok || echo fail)
				else
					v_tcp=$([[ "$a" == *"ok=1"* ]] && echo ok || echo fail)
				fi
			fi
		elif [[ "$dump_rc" == "0" || "$DRYRUN" == "1" ]]; then
			case "$post" in
				sleep15) [[ "$DRYRUN" == 1 ]] && sleep 1 || sleep 15 ;;
				sleep45) [[ "$DRYRUN" == 1 ]] && sleep 1 || sleep 45 ;;
				droplock_sleep2) [[ "$DRYRUN" != 1 ]] && drop_criu_lock "$clog"; sleep 2 ;;
				rmdb) rm -f "/tmp/pbsprobe_db_p${port}.bin" ;;
				rmshm) rm -f "/dev/shm/pbsprobe_shm_p${port}" ;;
				rmwd) rm -rf "/tmp/pbsprobe_wd_p${port}" ;;
				truncdb) truncate -s 4096 "/tmp/pbsprobe_db_p${port}.bin" 2>/dev/null ;;
				rmdb_recreate)
					rm -f "/tmp/pbsprobe_db_p${port}.bin"
					head -c 1048576 /dev/zero > "/tmp/pbsprobe_db_p${port}.bin" ;;
				squat)
					setsid python3 -c "import socket,time;s=socket.socket(socket.AF_UNIX);s.bind('\0pbsprobe_svc_p${port}');time.sleep(600)" > /dev/null 2>&1 < /dev/null &
					sleep 0.2 ;;
				mvbin) mv "$BIN_WL" "${BIN_WL}.aside" 2>/dev/null ;;
				mvbin_back)
					mv "$BIN_WL" "${BIN_WL}.aside" 2>/dev/null; sleep 0.5
					mv "${BIN_WL}.aside" "$BIN_WL" 2>/dev/null ;;
				hub_restart)
					if [[ "$WORLD" != "1" && -n "$HUBPID" ]]; then
						kill -9 "$HUBPID" 2>/dev/null; sleep 0.3
						setsid "$BIN_HUB" "${HARGS[@]}" >> "$hlog" 2>&1 < /dev/null &
						HUBPID=$!
						wait_line "$hlog" "HUB ready" 5 2 || echo "WARN: hub 재기동 실패" >> "$clog"
					fi ;;
			esac
			[[ "$hubmode" == "down_after" && -n "$HUBPID" ]] && { kill -9 "$HUBPID" 2>/dev/null; HUBPID=""; }

			CG=""
			if [[ "$memmib" != "0" && "$DRYRUN" != "1" ]]; then
				CG="$(mem_cg_setup "$memmib" "pbsprobe_$port")"
				[[ -z "$CG" ]] && echo "WARN: cgroup 구성 실패 — 제약 없이 restore" >> "$clog"
			fi

			if [[ "$DRYRUN" == "1" ]]; then
				restore_rc=dry; RPID="$WLPID"   # 배관 검증: 원본에 대해 검증 수행
			else
				do_restore "$cell/img" "$cell/pid" "" "$CG"
				restore_rc=$?
				rerr="$(first_err "$cell/img/restore.log")"
				RPID="$(cat "$cell/pid" 2>/dev/null || true)"
			fi

			if [[ "$restore_rc" == "0" || "$DRYRUN" == "1" ]]; then
				# flock_wait: 복원된 앱은 여전히 잠금 대기 — 홀더 해제로 진행
				if [[ -n "${HOLDER_PID:-}" ]]; then
					kill -9 "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
				fi
				touch "$resume_f"   # 처방 재개 신호 (connprobe --resume-file 규약)

				# post_dump 특수 흐름
				if [[ "$post" == "restore2" && "$DRYRUN" != "1" ]]; then
					probe "$port" PING "$VERIFY_TIMEOUT_S" >/dev/null && kill -9 "$RPID" 2>/dev/null
					sleep 0.3
					do_restore "$cell/img" "$cell/pid2" "2" "$CG"
					restore_rc=$?
					rerr="${rerr};r2=$(first_err "$cell/img/restore2.log")"
					RPID="$(cat "$cell/pid2" 2>/dev/null || true)"
				elif [[ "$post" == "restore_dup" && "$DRYRUN" != "1" ]]; then
					probe "$port" PING "$VERIFY_TIMEOUT_S" >/dev/null
					do_restore "$cell/img" "$cell/pid2" "2" ""
					dup_rc=$?
					rerr="dup_rc=$dup_rc;$(first_err "$cell/img/restore2.log")"
				elif [[ "$post" == "touchdb" ]]; then
					echo "delta" >> "/tmp/pbsprobe_db_p${port}.bin" 2>/dev/null
				elif [[ "$post" == "cycle2" && "$DRYRUN" != "1" ]]; then
					if probe "$port" PING "$VERIFY_TIMEOUT_S" >/dev/null; then
						[[ "$pre" == "bye" ]] && wait_line "$wlog" "^PHASE hub_reregistered" 8
						kill -USR1 "$RPID" 2>/dev/null
						wait_line "$wlog" "^PHASE hub_disconnected" 5 2
						rm -f "$resume_f"
						"$CRIU" dump -t "$RPID" -D "$cell/img2" -v4 -o dump2.log "${OPTS[@]}" >/dev/null 2>&1 \
							|| mkdir -p "$cell/img2"
						d2=$?
						if [[ "$d2" == "0" ]]; then
							do_restore "$cell/img2" "$cell/pid2" "2" "$CG"
							restore_rc="$?"
							RPID="$(cat "$cell/pid2" 2>/dev/null || true)"
							touch "$resume_f"
						else
							derr="${derr};d2=$d2"
						fi
					fi
				fi

				# ── 검증 ──
				if [[ "$verify" == *pong* || "$verify" == *stat* || "$verify" == *hub* || "$verify" == *tcp* ]]; then
					out="$(probe "$port" PING "$VERIFY_TIMEOUT_S" || true)"
					v_pong=$([[ "$out" == "PONG" ]] && echo ok || echo fail)
				fi
				if [[ "$verify" == *stat* ]]; then
					out="$(probe "$port" STAT "$VERIFY_TIMEOUT_S" || true)"
					echo "post_stat: $out" >> "$clog"
					if [[ -z "$out" ]]; then v_stat=fail
					elif [[ -n "$pre_stat" ]]; then
						pc="$(sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p' <<< "$pre_stat")"
						oc="$(sed -n 's/.*crc=\([0-9a-f]*\).*/\1/p' <<< "$out")"
						# refresh가 도는 앱은 crc가 진행하므로 '응답 + crc 형식'을 무결성으로,
						# refresh_ms 0 셀만 동일성으로 판정
						if [[ "$params" == *"--refresh_ms 0"* ]]; then
							v_stat=$([[ "$pc" == "$oc" && -n "$pc" ]] && echo ok || echo crc_diff)
						else
							v_stat=$([[ -n "$oc" ]] && echo ok || echo fail)
						fi
					else
						v_stat=ok
					fi
				fi
				if [[ "$verify" == *hub* ]]; then
					if wait_line "$wlog" "^PHASE hub_reregistered" "$VERIFY_TIMEOUT_S"; then
						rereg_ms="$(sed -n 's/.*hub_reregistered ms=\([0-9]*\).*/\1/p' "$wlog" | tail -1)"
						reg_after=$(grep -cE "HUB register|RENDER conn" "$hlog" 2>/dev/null || true); reg_after=${reg_after:-0}
						v_hub=$([[ "$reg_after" -gt "$reg_before" ]] && echo ok || echo no_hubside)
					else
						v_hub=fail
					fi
				fi
				if [[ "$verify" == *tcp* ]]; then
					a="$(probe "$port" TCPQ "$VERIFY_TIMEOUT_S" || true)"; sleep 0.5; b="$(probe "$port" TCPQ 3 || true)"
					echo "tcpq: $a / $b" >> "$clog"
					ra="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$a")"; rb="$(sed -n 's/.*rx=\([0-9]*\).*/\1/p' <<< "$b")"
					if [[ -z "$a" ]]; then v_tcp=fail
					elif [[ "$a" == *"mode=stream"* ]]; then
						v_tcp=$([[ -n "$ra" && -n "$rb" && "$rb" -gt "$ra" ]] && echo ok || echo dead)
					else
						v_tcp=$([[ "$a" == *"ok=1"* ]] && echo ok || echo dead)
					fi
				fi
				if [[ "$verify" == *resume* ]]; then
					if wait_line "$wlog" "^PHASE ready" 20; then
						out="$(probe "$port" PING "$VERIFY_TIMEOUT_S" || true)"
						v_resume=$([[ "$out" == "PONG" ]] && echo resumed_to_ready || echo ready_no_pong)
					else
						v_resume=resume_stalled
					fi
				fi
				if [[ "$verify" == *watch* ]]; then
			nb=$(grep -c "db_changed" "$wlog" 2>/dev/null || true); nb=${nb:-0}
			echo "watch-stim" >> "/tmp/pbsprobe_db_p${port}.bin"
			sleep 1.2
			na=$(grep -c "db_changed" "$wlog" 2>/dev/null || true); na=${na:-0}
			if [[ "$na" -gt "$nb" ]]; then v_stat="${v_stat}+watch_ok"; else v_stat="${v_stat}+watch_dead"; fi
		fi
		if [[ "$verify" == *live5* ]]; then
					[[ "$DRYRUN" == 1 ]] && sleep 1 || sleep 5
					if [[ "$DRYRUN" == "1" ]] || kill -0 "$RPID" 2>/dev/null; then
						out="$(probe "$port" PING 3 || true)"
						v_live5=$([[ "$out" == "PONG" ]] && echo alive || echo hung)
					else
						v_live5=dead
					fi
				fi
			fi
		fi
	fi

	# ── 판정 ──
	if [[ -z "$verdict" ]]; then
		if [[ "$DRYRUN" == "1" ]]; then verdict=dry
		elif [[ "$post" == "verify_orig" ]]; then
			verdict=$([[ "$dump_rc" != "0" && "$v_pong" == "ok" ]] && echo orig_intact || echo unexpected)
		elif [[ "$dump_rc" != "0" ]]; then verdict=dump_fail
		elif [[ "$restore_rc" != "0" ]]; then verdict=restore_fail
		elif [[ "$v_live5" == "dead" ]]; then verdict=silent_dead
		elif [[ "$v_tcp" == "dead" ]]; then verdict=conn_dead
		elif [[ "$v_pong" == "fail" && "$v_resume" == "na" ]]; then verdict=no_service
		elif [[ "$v_resume" == "resume_stalled" ]]; then verdict=resume_stalled
		else verdict=ok
		fi
	fi

	wcov=""
	[[ "$WORLD" == "1" ]] && wcov="$(bash "$DIR/world_status.sh" 2>/dev/null | tr ',' ';')"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s","%s","%s"\n' \
		"$sc" "$fam" "$ph" "$copts" "$pre" "$post" "$memmib" "$hubmode" \
		"$launch_ok" "$dump_rc" "$restore_rc" "$img_kib" \
		"$v_pong" "$v_stat" "$v_hub" "$v_tcp" "$v_live5" "$v_resume" "$rereg_ms" \
		"$verdict" "$wcov" "$derr" "$rerr" >> "$CSV"
	echo "[$done_n/$total] $sc dump=$dump_rc restore=$restore_rc verdict=$verdict"

	# ── 정리 ──
	[[ -n "${RPID:-}" && "$DRYRUN" != "1" ]] && kill -9 "$RPID" 2>/dev/null
	[[ -n "$WLPID" ]] && kill -9 "$WLPID" 2>/dev/null
	[[ -n "$HUBPID" ]] && kill -9 "$HUBPID" 2>/dev/null
	[[ -n "${HOLDER_PID:-}" ]] && kill -9 "$HOLDER_PID" 2>/dev/null
	[[ -f "${BIN_WL}.aside" ]] && mv "${BIN_WL}.aside" "$BIN_WL" 2>/dev/null   # OTA 셀 원복
	mem_cg_teardown "${CG:-}"
	kill_cell "$port"
	# 성공 셀 이미지는 용량 절약 삭제 (로그만 보존) — compat_sweep 규약
	if [[ "$dump_rc" == "0" && "$restore_rc" == "0" ]]; then
		find -L "$cell/img" "$cell/img2" -type f ! -name '*.log' -delete 2>/dev/null
	fi
	RPID=""
done

echo "[sweep] DONE → $CSV"
echo "[sweep] 요약: python3 $DIR/summarize_pbs.py $CSV"
