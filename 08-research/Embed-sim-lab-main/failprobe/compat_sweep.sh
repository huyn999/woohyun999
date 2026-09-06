#!/usr/bin/env bash
# failprobe/compat_sweep.sh — CRIU 호환성 매트릭스 스윕
#
# fp_* 워크로드 각각을, manifest에 선언된 모든 phase에서 dump→restore 해보고
# (성공/실패 + CRIU 로그의 첫 에러) 를 CSV 한 행으로 남긴다.
#
# crossover 측정과 달리 시간을 재지 않으므로 무거운 env(cgroup/storage/stress)는 걸지 않는다 —
# 목적이 "CRIU가 이 자원 상태를 다룰 수 있는가"의 순수 판정이기 때문. 제약 환경과의 교차
# 실험이 필요하면 이 워크로드들은 계약 준수 플러그인이므로 기존 run_once.sh로도 돌릴 수 있다.
#
# Usage:
#   sudo failprobe/compat_sweep.sh [워크로드 glob 기본 'fp_*']
#   PERMISSIVE=1 sudo failprobe/compat_sweep.sh      # --tcp-established --file-locks 등 허용 모드
#   CONSTRAINED=1 sudo ...                           # TV 제약 모드: cgroup(RAM 1.7G/4코어) + stress 배경부하
#                                                    #   안에서 전 셀 실행 (scenario.yaml 값 사용)
#   ONLY_PHASES="ready steady" sudo ...              # 특정 phase만
#   RESUME=1 sudo ...                                # 기존 CSV에 이어쓰기(이미 있는 행 skip)
#
# 산출물: failprobe/results/compat_<mode>.csv, 로그는 failprobe/results/runs/<wl>__<phase>/
set -uo pipefail   # -e 없음: 개별 셀 실패가 스윕 전체를 죽이면 안 된다

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED="$(cd "$DIR/.." && pwd)/testbed"
[[ -d "$TESTBED/workloads" ]] || { echo "ERROR: $TESTBED/workloads 없음 — failprobe/는 repo 루트 아래여야 함" >&2; exit 1; }
CRIU="${CRIU_BIN:-$TESTBED/criu/bin/criu}"
CPROBE="$TESTBED/runner/cprobe"
BIN="$TESTBED/workloads/bin"
[[ -x "$CRIU" ]] || { echo "ERROR: $CRIU 없음 — bootstrap/criu build 먼저" >&2; exit 1; }
[[ -x "$CPROBE" ]] || { echo "ERROR: $CPROBE 없음 — bootstrap 먼저" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: root 필요 (criu dump/restore)" >&2; exit 1; }

GLOB="${1:-fp_*}"
RESULTS="$DIR/results"; RUNS="$RESULTS/runs"
mkdir -p "$RUNS"
MODE="strict"; OPTS=(--shell-job)
if [[ "${PERMISSIVE:-0}" == "1" ]]; then
	MODE="permissive"
	OPTS=(--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap --ghost-limit 64M)
fi

# ── TV 제약 모드: scenario.yaml의 memory/cpu/stress 조건을 스윕 전체에 1회 적용 ──
CG=""
if [[ "${CONSTRAINED:-0}" == "1" ]]; then
	MODE="${MODE}_tv"
	CG="/sys/fs/cgroup/criu_compat_sweep"
	SCEN="$TESTBED/scenario.yaml"
	read -r MEM_MAX SWAP_MAX CPU_MAX CPUSET CPUN VMW VMB FLOOR SAT SCAP SRB SWB SDR SDW <<< "$(python3 - "$SCEN" <<-'PYEOF'
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
	mkdir -p "$CG"
	echo "+memory +cpu +cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
	echo "$MEM_MAX"  > "$CG/memory.max"
	echo "$SWAP_MAX" > "$CG/memory.swap.max"
	echo "${CPU_MAX/:/ }" > "$CG/cpu.max"
	echo "$CPUSET"   > "$CG/cpuset.cpus"
	# ── 느린 eMMC 모사: loop + dm-delay + io.max — CRIU 이미지가 이 디스크로 쓰이고 읽힘 ──
	TVIMG_DIR="$RESULTS/tvimg"; TVIMG_FILE="$RESULTS/tvimg.img"; DM_NAME="criu_compat_tvimg"
	# 이전 비정상 종료 잔재 자동 정리 (멱등)
	umount "$TVIMG_DIR" 2>/dev/null
	dmsetup remove "$DM_NAME" 2>/dev/null
	losetup -j "$TVIMG_FILE" 2>/dev/null | cut -d: -f1 | xargs -r losetup -d 2>/dev/null
	rm -f "$TVIMG_FILE"
	mkdir -p "$TVIMG_DIR"
	truncate -s "$SCAP" "$TVIMG_FILE"
	LOOP_DEV="$(losetup -f --show "$TVIMG_FILE")" \
		|| { echo "[env] ERROR: losetup 실패 — 스토리지 제약 구성 불가. 중단." >&2; exit 1; }
	SECTORS=$(blockdev --getsz "$LOOP_DEV")
	if (( SDR > 0 || SDW > 0 )); then
		modprobe dm_delay 2>/dev/null || true   # 재부팅 후 모듈 미적재 대비
		dmsetup create "$DM_NAME" --table "0 $SECTORS delay $LOOP_DEV 0 $SDR $LOOP_DEV 0 $SDW" \
			|| { echo "[env] ERROR: dm-delay 생성 실패 (modprobe dm_delay 확인). 중단." >&2; exit 1; }
		IMG_DEV="/dev/mapper/$DM_NAME"
	else
		IMG_DEV="$LOOP_DEV"
	fi
	mkfs.ext4 -q -F "$IMG_DEV" \
		|| { echo "[env] ERROR: mkfs 실패 ($IMG_DEV). 중단." >&2; exit 1; }
	mount "$IMG_DEV" "$TVIMG_DIR" \
		|| { echo "[env] ERROR: mount 실패. 중단." >&2; exit 1; }
	mountpoint -q "$TVIMG_DIR" \
		|| { echo "[env] ERROR: $TVIMG_DIR 마운트 검증 실패. 중단." >&2; exit 1; }
	DEV_MM="$(dmsetup info -c --noheadings -o major,minor "$DM_NAME" 2>/dev/null | tr -d ' ')"
	[[ -z "$DEV_MM" ]] && DEV_MM="$(stat -c '%Hr:%Lr' "$LOOP_DEV" 2>/dev/null)"
	if [[ -n "$DEV_MM" ]] && echo "+io" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
		echo "$DEV_MM rbps=$SRB wbps=$SWB" > "$CG/io.max" 2>/dev/null \
			|| echo "[env] WARN: io.max 설정 실패 — 대역폭 제한 없이 delay만 적용"
	fi
	echo "[env] storage: $IMG_DEV → $TVIMG_DIR (delay r${SDR}ms/w${SDW}ms, rbps=$SRB wbps=$SWB)"
	# stress 상주: 메인 start.sh와 동일하게 "독립 인스턴스 × VMW개(각 --vm 1)"로.
	# (단일 인스턴스 --vm N은 메모리를 상주시키지 않음 — 원저자 실측, start.sh 주석 참조)
	DATA_MB=$(( VMB/1048576 - FLOOR )); [[ $DATA_MB -lt 1 ]] && DATA_MB=1
	STRESS_PIDS=()
	for _i in $(seq 1 "$VMW"); do
		( echo "$BASHPID" > "$CG/cgroup.procs" && exec stress-ng --timeout 1d --vm 1 --vm-bytes "${DATA_MB}M" \
		  --vm-keep --vm-populate --vm-hang 0 ) > /dev/null 2>&1 &
		STRESS_PIDS+=($!)
	done
	if [[ "$SAT" == "1" ]]; then
		( echo "$BASHPID" > "$CG/cgroup.procs" && exec stress-ng --timeout 1d --cpu "$CPUN" ) > /dev/null 2>&1 &
		STRESS_PIDS+=($!)
	fi
	TGT=$(( VMW * VMB ))
	CUR=0
	for i in $(seq 1 45); do        # 최대 90초 정착 대기 (느린 머신 + saturate 감안)
		sleep 2
		CUR=$(cat "$CG/memory.current" 2>/dev/null || echo 0)
		(( CUR >= TGT * 90 / 100 )) && break
	done
	echo "[env] stress 정착: memory.current=$((CUR/1048576))MB (목표 $((TGT/1048576))MB, $((i*2))s)"
	# OOM 보호 (메인 §6.3): stress-ng은 워커를 +1000(1순위 희생자)으로 올린다 —
	# 압박 셀에서 배경부하가 먼저 죽는 침묵 오염을 막기 위해 -800으로 강제.
	prot=0
	for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do
		{ echo -800 > "/proc/$p/oom_score_adj"; } 2>/dev/null && prot=$((prot+1))
	done
	echo "[env] oom-protect: $prot proc(s) -> oom_score_adj=-800"
	if (( CUR < TGT * 85 / 100 )); then
		echo "[env] ERROR: 점유 85% 미달 — floor_mib 확인 또는 stress 기동 실패. 중단." >&2
		exit 1
	fi
	cleanup_env() {
		kill -9 "${STRESS_PIDS[@]}" 2>/dev/null; pkill -9 -f "stress-ng" 2>/dev/null; sleep 0.3
		for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
		sleep 0.2; rmdir "$CG" 2>/dev/null
		umount "$TVIMG_DIR" 2>/dev/null
		dmsetup remove "$DM_NAME" 2>/dev/null
		[[ -n "${LOOP_DEV:-}" ]] && losetup -d "$LOOP_DEV" 2>/dev/null
	}
	trap cleanup_env EXIT
fi

CSV="$RESULTS/compat_${MODE}.csv"
if [[ "${RESUME:-0}" != "1" || ! -f "$CSV" ]]; then
	echo "workload,phase,mode,launch_ok,dump_rc,restore_rc,verify,dump_err,restore_err" > "$CSV"
fi

PORT_BASE=21000
port_ctr=0
PHASE_TIMEOUT_S="${PHASE_TIMEOUT_S:-20}"

# manifest에서 phases 파싱 (served_first는 warm ping이 필요해 pre-ready 스윕과 결이 달라
# 기본 제외하고 ready/steady로 대표한다 — INCLUDE_SERVED=1로 포함 가능)
phases_of() {
	python3 - "$TESTBED/workloads/$1/workload.yaml" <<-'EOF'
	import sys, yaml
	m = yaml.safe_load(open(sys.argv[1]))
	ph = [p for p in m.get("phases", []) if p != "served_first"]
	print(" ".join(ph))
	EOF
}

wait_phase() { # $1=log $2=phase $3=timeout_s → 0/1
	local log="$1" ph="$2" deadline=$(( $(date +%s) + $3 ))
	while (( $(date +%s) < deadline )); do
		grep -qE "^PHASE ${ph}( |$)" "$log" 2>/dev/null && return 0
		# 프로세스가 이미 죽었으면 무한 대기 방지
		[[ -n "${WLPID:-}" ]] && ! kill -0 "$WLPID" 2>/dev/null && return 1
		sleep 0.02
	done
	return 1
}

first_err() { # $1=logfile → 첫 CRIU Error 라인 (CSV-safe)
	[[ -f "$1" ]] || { echo ""; return; }
	grep -m1 -E "Error \(" "$1" | tr ',' ';' | tr -d '"' | cut -c1-400
}

kill_cell() { # 셀 정리: "바이너리경로 --port N" 정밀 매치 (스윕 자신 오살 방지)
	local wl="$1" port="$2"
	pkill -9 -f "bin/${wl} --port ${port} " 2>/dev/null
	pkill -9 -f "bin/${wl} --port ${port}$" 2>/dev/null
	sleep 0.05
	# 셀 잔재 즉시 정리 — tmpfs 기반 자원(POSIX shm/mq)은 프로세스가 죽어도
	# 파일이 남는 한 cgroup 메모리 과금이 유지된다. 셀마다 포트가 달라 잔재가
	# 계속 쌓이면 수십 셀 뒤 한도가 잠식되어 모든 신규 기동이 OOM으로 죽는
	# 누적형 붕괴(전량 미도달)가 발생 → 포트 키로 셀 종료 직후 정밀 삭제.
	rm -f "/dev/shm/criuprobe_shm_p${port}" 2>/dev/null
	rm -f "/dev/mqueue/criuprobe_mq_p${port}" 2>/dev/null
	rm -f /tmp/criuprobe_*_p"${port}" /tmp/criuprobe_ghost_* 2>/dev/null
	rm -rf "/tmp/criuprobe_watch_p${port}" "/tmp/criuprobe_cwd_p${port}" 2>/dev/null
}

total=0; done_n=0
WLS=()
for d in "$TESTBED/workloads/"$GLOB/; do
	[[ -f "$d/workload.c" ]] && WLS+=("$(basename "$d")")
done
for wl in "${WLS[@]}"; do
	for ph in $(phases_of "$wl"); do total=$((total+1)); done
done
echo "[sweep] mode=$MODE workloads=${#WLS[@]} cells=$total → $CSV"

for wl in "${WLS[@]}"; do
	[[ -x "$BIN/$wl" ]] || { echo "[skip] $wl: 미빌드 (workloads/build.sh 먼저)"; continue; }
	for ph in $(phases_of "$wl"); do
		if [[ -n "${ONLY_PHASES:-}" ]] && ! grep -qw "$ph" <<< "$ONLY_PHASES"; then continue; fi
		done_n=$((done_n+1))
		if [[ "${RESUME:-0}" == "1" ]] && grep -q "^${wl},${ph},${MODE}," "$CSV"; then continue; fi

		port=$((PORT_BASE + port_ctr)); port_ctr=$((port_ctr+1))
		cell="$RUNS/${wl}__${ph}__${MODE}"
		rm -rf "$cell"; mkdir -p "$cell"
		if [[ -n "$CG" && -d "$RESULTS/tvimg" ]]; then
			imgd="$RESULTS/tvimg/${wl}__${ph}"; rm -rf "$imgd"; mkdir -p "$imgd"
			ln -sfn "$imgd" "$cell/img"
		else
			mkdir -p "$cell/img"
		fi
		wlog="$cell/wl.log"

		# launch (runner의 wl_launch와 동형: 서브셸 exec + 로그 리다이렉트)
		if [[ -n "$CG" ]]; then
			( echo "$BASHPID" > "$CG/cgroup.procs" && exec "$BIN/$wl" --port "$port" --bytes 8388608 --phase_gap_ms "${PHASE_GAP_MS:-400}" ) > "$wlog" 2>&1 &
		else
			( exec "$BIN/$wl" --port "$port" --bytes 8388608 --phase_gap_ms "${PHASE_GAP_MS:-400}" ) > "$wlog" 2>&1 &
		fi
		WLPID=$!

		launch_ok=1 dump_rc=na restore_rc=na verify=na derr="" rerr=""
		if ! wait_phase "$wlog" "$ph" "$PHASE_TIMEOUT_S"; then
			launch_ok=0
			echo "[$done_n/$total] $wl@$ph: phase 미도달 (워크로드 로그 확인)"
		else
			"$CRIU" dump -t "$WLPID" -D "$cell/img" -v4 -o dump.log "${OPTS[@]}" >/dev/null 2>&1
			dump_rc=$?
			derr="$(first_err "$cell/img/dump.log")"
			if [[ $dump_rc -eq 0 ]]; then
				sleep 0.2
				"$CRIU" restore -d -D "$cell/img" -v4 -o restore.log --pidfile "$cell/pid" "${OPTS[@]}" >/dev/null 2>&1
				restore_rc=$?
				rerr="$(first_err "$cell/img/restore.log")"
				if [[ $restore_rc -eq 0 ]]; then
					# 검증: post-ready phase면 PONG, pre-ready면 복원 후 ready까지 진행하는지
					case "$ph" in
						ready|steady)
							ok=0
							for _ in $(seq 1 100); do
								if "$CPROBE" 127.0.0.1 "$port" 200 >/dev/null 2>&1; then ok=1; break; fi
								sleep 0.05
							done
							verify=$([[ $ok -eq 1 ]] && echo pong_ok || echo pong_fail) ;;
						*)
							if wait_phase "$wlog" ready 15; then verify=resumed_to_ready
							else verify=resume_stalled; fi ;;
					esac
				fi
			fi
		fi
		printf '%s,%s,%s,%s,%s,%s,%s,"%s","%s"\n' \
			"$wl" "$ph" "$MODE" "$launch_ok" "$dump_rc" "$restore_rc" "$verify" "$derr" "$rerr" >> "$CSV"
		echo "[$done_n/$total] $wl@$ph dump=$dump_rc restore=$restore_rc verify=$verify"
		kill_cell "$wl" "$port"
		# 이미지가 성공 셀이면 용량 절약을 위해 정리 (실패 셀은 로그 포함 보존)
		if [[ "$dump_rc" == "0" && "$restore_rc" == "0" ]]; then
			find -L "$cell/img" -type f ! -name '*.log' -delete
		fi
	done
done

# 스윕 잔재 정리 (베스트에포트)
rm -f /tmp/criuprobe_* /dev/shm/criuprobe_* 2>/dev/null
rm -rf /tmp/criuprobe_watch_p* /tmp/criuprobe_cwd_p* 2>/dev/null
echo "[sweep] DONE → $CSV"
echo "[sweep] 요약: python3 $DIR/summarize_compat.py $CSV"
