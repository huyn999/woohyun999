#!/usr/bin/env bash
# testbed/bootstrap.sh — fresh clone → 실행 가능 상태까지 원샷 (설치 + 빌드 + 진단, 멱등)
#
# 이식성의 진실은 이 파일 하나다: 새 머신(x86_64든 RPi4/aarch64든)에서
#   sudo testbed/bootstrap.sh
# 만 치면 (a) apt 의존성 설치 (b) 워크로드/cprobe/CRIU 빌드 (c) 환경 진단(doctor)까지 끝난다.
#
# Usage:
#   sudo testbed/bootstrap.sh                # 전부 (Debian/Ubuntu/Raspberry Pi OS)
#   sudo testbed/bootstrap.sh --skip-criu    # CRIU 빌드 생략 — criu/bin/criu를 직접 배치하는
#                                            #   기기(예: RPi에서 다른 버전으로 교체)용
#   sudo testbed/bootstrap.sh --check-only   # 설치/빌드 없이 진단만
#
# 비-apt 배포판이면 설치 단계는 패키지 목록만 출력하고 건너뛴다(수동 설치 후 재실행).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_CRIU=0
CHECK_ONLY=0
for a in "$@"; do case "$a" in
	--skip-criu) SKIP_CRIU=1 ;;
	--check-only) CHECK_ONLY=1 ;;
	*) echo "usage: $0 [--skip-criu] [--check-only]" >&2; exit 2 ;;
esac; done

[[ $EUID -eq 0 ]] || { echo "ERROR: root 필요 (apt/modprobe/cgroup 진단)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. 의존성 설치 (apt 계열만 자동 — RPi OS 포함)
# ---------------------------------------------------------------------------
# 런타임: stress-ng(배경 부하) dmsetup(dm-delay) e2fsprogs(mkfs.ext4) util-linux(losetup/flock)
#         python3-yaml(runner 전 도구) python3-matplotlib(reports 그림 전용) tmux(무인 캠페인 권장)
# 빌드:   build-essential pkg-config git + CRIU 의존성(criu/build.sh의 hint와 동일 목록)
CORE_PKGS=(build-essential pkg-config git ca-certificates python3 python3-yaml
	python3-matplotlib stress-ng dmsetup e2fsprogs util-linux coreutils tmux)
CRIU_PKGS=(protobuf-c-compiler libprotobuf-c-dev libnet1-dev libnl-3-dev libcap-dev libbsd-dev)

if ((CHECK_ONLY == 0)); then
	if command -v apt-get >/dev/null; then
		echo "[bootstrap] apt install: ${CORE_PKGS[*]}"
		pkgs=("${CORE_PKGS[@]}")
		((SKIP_CRIU)) || pkgs+=("${CRIU_PKGS[@]}")
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}"
	else
		echo "[bootstrap] WARN: apt 없음 — 아래 패키지를 수동 설치 후 재실행하라:" >&2
		echo "  ${CORE_PKGS[*]} ${CRIU_PKGS[*]}" >&2
		echo "  (python은 pip install -r testbed/requirements.txt 로도 가능)" >&2
	fi

	# -----------------------------------------------------------------------
	# 2. 빌드 (전부 멱등 — 소스가 산출물보다 새로울 때만)
	# -----------------------------------------------------------------------
	echo "[bootstrap] build: workloads"
	"$DIR/workloads/build.sh"

	# cprobe — 측정 창의 유일한 외부 스폰(lib/probe.sh). gitignore된 산출물이라 fresh clone엔
	# 없다 — 여기가 유일한 자동 빌드 지점이다. static 필수: 동적 링커 fault가 첫-응답 측정에
	# 잡음을 넣는 걸 제거하는 게 cprobe의 존재 이유라(runner/cprobe.c 헤더) 실패 시 대체 없이 die.
	if [[ ! -x "$DIR/runner/cprobe" || "$DIR/runner/cprobe.c" -nt "$DIR/runner/cprobe" ]]; then
		echo "[bootstrap] build: cprobe (static)"
		gcc -O2 -static -o "$DIR/runner/cprobe" "$DIR/runner/cprobe.c"
	else
		echo "[bootstrap] up-to-date: runner/cprobe"
	fi

	if ((SKIP_CRIU)); then
		echo "[bootstrap] CRIU 빌드 생략(--skip-criu) — criu/bin/criu를 직접 배치하라 (또는 CRIU_BIN env)"
	else
		echo "[bootstrap] build: CRIU (criu/build.sh — clone+patch+make, 최초 1회만 느림)"
		"$DIR/criu/build.sh"
	fi
fi

# ---------------------------------------------------------------------------
# 3. doctor — 실행 전제조건 진단 (mutation 없음, modprobe만 시도)
# ---------------------------------------------------------------------------
echo
echo "[bootstrap] === doctor ==="
FAILS=0
ok()   { printf '  [PASS] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; }

# cgroup v2 + 필수 controller — RPi OS는 memory controller가 기본 비활성이라 여기서 걸린다
# (수리법: /boot/firmware/cmdline.txt에 cgroup_enable=memory cgroup_memory=1 — README 이식 노트).
if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == "cgroup2fs" ]]; then
	ok "cgroup v2 mounted"
	ctrls="$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || true)"
	for c in cpu cpuset memory io; do
		if grep -qw "$c" <<< "$ctrls"; then ok "cgroup controller: $c"
		else bad "cgroup controller '$c' 없음 (controllers: '$ctrls') — RPi면 cmdline.txt cgroup_enable=memory cgroup_memory=1"
		fi
	done
else
	bad "cgroup v2 아님 (/sys/fs/cgroup: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo '?'))"
fi

# 필수 커맨드
for c in stress-ng dmsetup losetup mkfs.ext4 numfmt flock timeout python3 gcc; do
	if command -v "$c" >/dev/null; then ok "command: $c"
	else bad "command 없음: $c"
	fi
done
command -v tmux >/dev/null && ok "command: tmux" || warn "tmux 없음 — 무인 캠페인은 detach 가능한 세션 필수"

# python 모듈 — runner는 yaml 필수, matplotlib은 reports/ 그림 전용
python3 -c 'import yaml' 2>/dev/null && ok "python3: yaml" \
	|| bad "python3 yaml 없음 (apt python3-yaml 또는 pip install -r testbed/requirements.txt)"
python3 -c 'import matplotlib' 2>/dev/null && ok "python3: matplotlib" \
	|| warn "matplotlib 없음 — 측정은 되고 reports/ 그림만 불가"

# dm-delay target (storage 지연 축) — 모듈이면 로드 시도 후 target 존재 확인.
# scenario가 delay를 끈 기기(예: 매체 자체가 느린 SD의 RPi)에선 FAIL이 아니라 WARN —
# 지금 설정으로는 안 쓰는 기능이므로 부재가 실행을 막지 않는다.
delay_en="$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])) or {}; print((((c.get("storage") or {}).get("image") or {}).get("delay") or {}).get("enabled", False))' "$DIR/scenario.yaml" 2>/dev/null || echo True)"
modprobe dm-delay 2>/dev/null || true
if dmsetup targets 2>/dev/null | grep -q '^delay'; then
	ok "dm-delay target"
elif [[ "$delay_en" == "True" ]]; then
	bad "dm-delay target 없음 — scenario storage.image.delay.enabled=true인데 커널에 없음 (CONFIG_DM_DELAY/modprobe)"
else
	warn "dm-delay target 없음 — scenario delay.enabled=false라 지금은 무관 (지연 축을 켜려면 CONFIG_DM_DELAY 필요)"
fi

# loop device (storage 이미지 축)
losetup -f >/dev/null 2>&1 && ok "loop device available" || bad "loop device 불가 (losetup -f 실패)"

# kdat 캐시 디렉터리 tmpfs (kdat on 축) — 경로는 기기 속성(scenario criu.kdat_file):
# 기본 /dev/shm/criu.kdat(kdat-shm 패치 빌드), 실호스트+stock CRIU는 /run/criu.kdat.
kdat_file="$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])) or {}; print((c.get("criu") or {}).get("kdat_file") or "/dev/shm/criu.kdat")' "$DIR/scenario.yaml" 2>/dev/null || echo /dev/shm/criu.kdat)"
kdat_dir="$(dirname "$kdat_file")"
[[ "$(stat -fc %T "$kdat_dir" 2>/dev/null)" == "tmpfs" ]] && ok "kdat 캐시 디렉터리 tmpfs: $kdat_dir (kdat on 축)" \
	|| bad "$kdat_dir 이(가) tmpfs 아님 — kdat_cache=on 축 사용 불가 (scenario criu.kdat_file 확인)"

# cpufreq clamp (cpu.frequency_khz 축) — sysfs 존재 + scenario 값이 기기 범위 안인지
CF=/sys/devices/system/cpu/cpu0/cpufreq
if [[ -d "$CF" ]]; then
	ok "cpufreq sysfs"
	freq="$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])) or {}; print((c.get("cpu") or {}).get("frequency_khz") or "")' "$DIR/scenario.yaml" 2>/dev/null || true)"
	if [[ "$freq" =~ ^[0-9]+$ ]]; then
		hw_min="$(cat "$CF/cpuinfo_min_freq" 2>/dev/null || echo 0)"
		hw_max="$(cat "$CF/cpuinfo_max_freq" 2>/dev/null || echo 0)"
		if (( freq >= hw_min && freq <= hw_max )); then
			ok "scenario frequency_khz=$freq ∈ [$hw_min, $hw_max]"
		else
			bad "scenario cpu.frequency_khz=$freq 가 이 기기 범위 [$hw_min, $hw_max] 밖 — scenario.yaml을 기기에 맞게 조정 (이식 노트)"
		fi
	fi
else
	warn "cpufreq sysfs 없음 — frequency_khz 고정 축 사용 불가 (scenario에서 비우면 무관)"
fi

# 빌드 산출물
for b in workloads/bin/simple workloads/bin/dirty workloads/bin/initburst runner/cprobe; do
	[[ -x "$DIR/$b" ]] && ok "built: $b" || bad "미빌드: $b (bootstrap을 --check-only 없이 실행)"
done
if [[ -x "$DIR/criu/bin/criu" ]]; then
	ok "built: criu/bin/criu ($("$DIR/criu/bin/criu" --version 2>/dev/null | head -1 || echo '?'))"
	# CRIU↔커널 궁합은 버전 번호가 아니라 기능으로 판정한다 — criu check가 현재 커널에서
	# dump/restore에 필요한 커널 기능을 전수 점검한다("Looks good." = 이 커널에서 동작).
	# 이식(특히 RPi에서 CRIU 교체) 시 제일 먼저 볼 판정선. 참고: dump→restore가 항상 같은
	# 머신 안에서 일어나므로 기기 간 커널 "일치"는 애초에 요구사항이 아니다(이미지 이동 없음).
	if "$DIR/criu/bin/criu" check >/dev/null 2>&1; then
		ok "criu check: 이 커널($(uname -r))에서 dump/restore 기능 전수 통과"
	else
		bad "criu check 실패 — 이 커널에서 CRIU가 동작 불가 (criu/bin/criu check로 상세 확인)"
	fi
	# 비트니스 일치(이식 — webOS 모사): ARM에선 CRIU와 dump 대상 프로세스의 비트니스가
	# 반드시 같아야 한다(64↔32 compat C/R은 x86 전용 기능). 32-bit CRIU + 64-bit 워크로드
	# 같은 혼합은 dump에서 늦게, 혼란스럽게 죽으므로 여기서 먼저 잡는다.
	if [[ -x "$DIR/workloads/bin/simple" ]] && command -v readelf >/dev/null; then
		criu_class="$(readelf -h "$DIR/criu/bin/criu" 2>/dev/null | awk '/Class:/{print $2}')"
		wl_class="$(readelf -h "$DIR/workloads/bin/simple" 2>/dev/null | awk '/Class:/{print $2}')"
		if [[ -n "$criu_class" && "$criu_class" == "$wl_class" ]]; then
			ok "비트니스 일치: criu=$criu_class, workload=$wl_class"
		else
			bad "비트니스 불일치: criu=$criu_class vs workload=$wl_class — ARM에선 dump 불가. 워크로드를 같은 비트니스로 재빌드하라 (WL_CC=arm-linux-gnueabihf-gcc WL_CFLAGS='-O2 -Wall -static' workloads/build.sh)"
		fi
	fi
else
	if ((SKIP_CRIU)); then warn "criu/bin/criu 없음 (--skip-criu) — restore 경로 전 직접 배치 필요"
	else bad "criu/bin/criu 없음 — criu/build.sh 실패 여부 확인"
	fi
fi

echo
if ((FAILS == 0)); then
	echo "[bootstrap] DONE — ALL CHECKS PASSED. 다음: testbed/README.md Quickstart 1·2단계(단발 실행/캠페인)"
else
	echo "[bootstrap] $FAILS CHECK(S) FAILED — 위 [FAIL]부터 해결" >&2
	exit 1
fi
