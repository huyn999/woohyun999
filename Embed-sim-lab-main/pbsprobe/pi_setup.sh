#!/usr/bin/env bash
# pbsprobe/pi_setup.sh — 라즈베리파이(데모 타깃) 준비·점검
#
# 대상: Raspberry Pi OS (64-bit, bookworm 권장) — Pi 4/5의 Cortex-A72/A76은
# TV SoC(Cortex-A73)와 같은 ARMv8 계열이라 데모 타깃으로 적절하다.
#
#   sudo pbsprobe/pi_setup.sh          # 설치 + 점검 + 판정
#   sudo pbsprobe/pi_setup.sh check    # 점검만
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
MODE="${1:-install}"
warn=0; fatal=0
ok()  { echo "  OK   $1"; }
wr()  { echo "  WARN $1"; warn=$((warn+1)); }
ng()  { echo "  FAIL $1"; fatal=$((fatal+1)); }

echo "[1] 플랫폼"
arch="$(uname -m)"; echo "  arch=$arch kernel=$(uname -r)"
[[ "$arch" == "aarch64" ]] && ok "aarch64 (TV와 같은 ARMv8 — 이상적)" \
	|| wr "arch=$arch — armv7l(32bit)도 동작하나 TV 대응성은 aarch64 권장"

if [[ "$MODE" == "install" ]]; then
	echo "[2] 패키지 설치"
	apt-get update -qq
	apt-get install -y -qq criu stress-ng gcc python3 python3-yaml util-linux 2>&1 | tail -1
fi

echo "[3] CRIU"
if command -v criu >/dev/null; then
	v="$(criu --version | head -1)"
	echo "  $v"
	# glibc≥2.35의 rseq 자동등록 때문에 CRIU≥3.17 필수 (gh#1696).
	ver="$(criu --version | grep -oE '[0-9]+\.[0-9]+' | head -1)"
	maj="${ver%%.*}"; min="${ver##*.}"
	if (( maj > 3 || (maj == 3 && min >= 17) )); then
		ok "버전 ≥3.17 (rseq 지원 — glibc $(ldd --version | grep -oE '[0-9]+\.[0-9]+' | head -1) 대응)"
	else
		ng "CRIU <3.17 — 복원 후 rseq 크래시 위험. testbed/criu/build.sh 로 v4.2 소스 빌드 권장"
	fi
else
	ng "criu 없음 — apt 실패 시: testbed/criu/build.sh (v4.2 소스 빌드)"
fi

echo "[4] 커널 기능 (criu check)"
if command -v criu >/dev/null; then
	if criu check > /tmp/criu_check.out 2>&1; then
		ok "criu check 통과"
	else
		grep -E "Error" /tmp/criu_check.out | sed 's/^/  /' | head -6
		wr "criu check 경고/오류 — 위 항목이 실험 셀과 겹치는지 확인 (전체가 막히는 건 아님)"
	fi
fi
for m in unix_diag inet_diag tcp_diag dm_delay; do
	if modprobe "$m" 2>/dev/null || grep -qw "$m" /proc/modules 2>/dev/null; then
		ok "모듈 $m"
	else
		[[ "$m" == "dm_delay" ]] && wr "dm_delay 없음 — CONSTRAINED 느린디스크만 영향" \
			|| ng "$m 없음 — 소켓 dump 불가 (raspi 커널 config 확인)"
	fi
done

echo "[5] cgroup v2 memory 컨트롤러"
if [[ "$(stat -fc %T /sys/fs/cgroup)" == "cgroup2fs" ]] \
   && grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
	ok "cgroup v2 + memory 컨트롤러 활성"
else
	ng "memory 컨트롤러 비활성 — Raspberry Pi OS 기본값. /boot/firmware/cmdline.txt 한 줄 끝에
       'cgroup_enable=memory cgroup_memory=1' 추가 후 재부팅 (D 가족·CONSTRAINED·memd 필수)"
fi

echo "[6] 기타"
swapon --noheadings 2>/dev/null | grep -q . && wr "swap 활성 — 메모리 셀 판정 왜곡: 'sudo dphys-swapfile swapoff' 권장" || ok "swap 없음"
command -v iptables >/dev/null || command -v nft >/dev/null && ok "netfilter 도구 (droplock 셀)" || wr "iptables/nft 없음 — C_*_droplock 셀 제한"
free -m | awk '/Mem:/{ if ($2 < 1800) print "  WARN 총 RAM "$2"M — D_tv_budget(1708M) 셀은 물리 한도로 대체 해석"; else print "  OK   RAM "$2"M" }'

echo
if (( fatal > 0 )); then
	echo "PI_SETUP: FAIL=$fatal WARN=$warn — 위 FAIL 해결 후 재실행"
	exit 1
fi
echo "PI_SETUP: OK (WARN=$warn) — 다음: pbsprobe/build.sh && bash pbsprobe/selftest.sh && sudo pbsprobe/run_all.sh"
