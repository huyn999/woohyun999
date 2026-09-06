#!/usr/bin/env bash
# webos_probe/check_webos_usage.sh — "webOS는 mq/SysV를 안 쓴다" 판정의 근거 수집
#
# 사용:
#   ./check_webos_usage.sh /path/to/webos_rootfs      # OSE 이미지/rootfs 대상
#   ./check_webos_usage.sh --live                     # 루팅 실기/에뮬레이터에서 직접
#
# 출력은 판정이 아니라 증거다 — 0건이면 "미사용" 주장을 근거화, 발견되면
# 해당 클러스터(④ mq / 레거시 SysV)를 C급에서 승격하고 재평가한다.
set -u
MODE="${1:-}"
scan_rootfs() {
  local R="$1"
  echo "== rootfs 심볼 스캔: $R"
  echo "-- [④ mq] mq_open/mq_send 심볼을 가진 ELF (동적 심볼표 기준):"
  find "$R" -type f \( -path '*/bin/*' -o -path '*/sbin/*' -o -name '*.so*' \) 2>/dev/null \
    | while read -r f; do
        if command -v objdump >/dev/null; then
          objdump -T "$f" 2>/dev/null | grep -qE ' (mq_open|mq_send)$' && echo "   $f"
        else
          strings -a "$f" 2>/dev/null | grep -qx "mq_open" && echo "   $f (strings)"
        fi
      done | sort -u | tee /tmp/webos_mq_users.txt | head -20
  echo "   합계: $(wc -l < /tmp/webos_mq_users.txt)건"
  echo "-- [레거시] shmget/shmat 심볼을 가진 ELF:"
  find "$R" -type f \( -path '*/bin/*' -o -path '*/sbin/*' -o -name '*.so*' \) 2>/dev/null \
    | while read -r f; do
        if command -v objdump >/dev/null; then
          objdump -T "$f" 2>/dev/null | grep -qE ' (shmget|shmat)$' && echo "   $f"
        else
          strings -a "$f" 2>/dev/null | grep -qx "shmget" && echo "   $f (strings)"
        fi
      done | sort -u | tee /tmp/webos_sysv_users.txt | head -20
  echo "   합계: $(wc -l < /tmp/webos_sysv_users.txt)건"
  echo "   ※ 정직한 한계: 정적 심볼 스캔은 dlopen/정적링크를 놓칠 수 있음 — --live 대조 권장"
}
scan_live() {
  echo "== 실기/에뮬레이터 런타임 스캔"
  echo "-- [④ mq] 현재 존재하는 메시지 큐:"
  mount | grep -q mqueue || mount -t mqueue mqueue /dev/mqueue 2>/dev/null
  ls -la /dev/mqueue 2>/dev/null || echo "   (mqueue 마운트 불가/비어있음)"
  echo "-- [레거시] 현재 존재하는 SysV shm 세그먼트:"
  ipcs -m 2>/dev/null || cat /proc/sysvipc/shm 2>/dev/null || echo "   (조회 불가)"
  echo "-- 프로세스별 mqueue fd 보유자:"
  for p in /proc/[0-9]*; do
    for fd in "$p"/fd/*; do
      link=$(readlink "$fd" 2>/dev/null) || continue
      case "$link" in *mqueue*) echo "   $(cat $p/comm 2>/dev/null) ($p) → $link";; esac
    done
  done 2>/dev/null | sort -u | head
  echo "   ※ 부팅 직후·주요 앱 실행 중 두 시점에서 각각 떠서 비교할 것"
}
case "$MODE" in
  --live) scan_live ;;
  "") echo "사용법: $0 <rootfs경로> | --live"; exit 1 ;;
  *) scan_rootfs "$MODE" ;;
esac
