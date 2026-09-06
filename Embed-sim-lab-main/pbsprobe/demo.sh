#!/usr/bin/env bash
# pbsprobe/demo.sh — 라즈베리파이 데모: 이야기 순서대로 셀을 골라 라이브 실행
#
# 먼저 볼 것: sudo pbsprobe/demo_live.sh — "정지된 앱을 이미지에서 부활"을
# 눈으로 보는 메인 장면 (라이브 STAT → dump/ps 소멸 → 이미지 → restore →
# crc 보존·uptime 이어짐·slot 신선). 이 스크립트(demo.sh)는 그 다음, 발견들을
# 셀 판정으로 훑는 요약 데모다.
#
# 흐름 (각 장이 발표의 발견 하나씩):
#   1장  순수 EPG 앱은 얼었다 살아난다            (A_nohub_steady)
#   2장  루나 허브에 붙는 순간부터 못 얼린다       (A_life_hub_conn1 — 라인 단위)
#   3장  처방: 끊고-얼리고-재등록, 비용은 X ms     (B_bye_conns4)
#   4장  rc=0의 배신 ①: lock 없으면 연결만 침묵사  (C_st_droplock)
#   5장  rc=0의 배신 ②: 몇 초 뒤 조용한 OOM       (D_light_silent, cgroup 필요)
#   6장  전 자원 완전체 + 처방 세트 = 생존         (F_all_rx)
#   7장  [세계] 상주 OS 위에서: 재등록 폭주도 생존  (world + G_flood_rereg)
#
#   sudo pbsprobe/demo.sh            # 전체 (약 5-8분)
#   sudo pbsprobe/demo.sh 1 2 3      # 장 선택
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "root 필요 (sudo)"; exit 1; }
CSV="$DIR/results/pbs_matrix.csv"

chapters=("${@:-1 2 3 4 5 6 7}")
[[ $# -eq 0 ]] && chapters=(1 2 3 4 5 6 7)

banner() { echo; echo "══════════════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════════════"; }
show() {   # $1=cell — CSV에서 그 행을 읽어 사람 말로
	local row
	row="$(grep "^$1," "$CSV" | tail -1)"
	[[ -z "$row" ]] && { echo "  (결과 없음)"; return; }
	IFS=, read -r sc fam ph copts pre post mem hub launch drc rrc img pong stat vhub vtcp live5 res rereg verdict rest <<< "$row"
	echo "  → dump_rc=$drc restore_rc=$rrc | PONG=$pong 무결성=$stat hub=$vhub tcp=$vtcp +5s=$live5"
	echo "  → 판정: $verdict $([[ -n "$rereg" && "$rereg" != na ]] && echo "(재등록 ${rereg}ms)")"
}
runcell() { RESUME=1 bash "$DIR/pbs_sweep.sh" "$1" | grep -E "^\[" ; show "$1"; }

# 헤더 보존을 위해 첫 실행 전 CSV 준비
[[ -f "$CSV" ]] || RESUME=0 bash "$DIR/pbs_sweep.sh" '__none__' >/dev/null 2>&1 || true

for ch in ${chapters[@]}; do
	case "$ch" in
	1) banner "1장. 순수 EPG 앱은 얼었다 살아난다"
	   runcell A_nohub_steady ;;
	2) banner "2장. 루나 허브에 붙는 순간부터 못 얼린다 (라인 단위)"
	   runcell A_life_epg_index
	   runcell A_life_hub_conn1
	   echo "  ↑ epg_index 라인까진 되고, hub_conn1 라인부터 거부 — 경계선이 이 한 줄"
	   ;;
	3) banner "3장. 처방 — 끊고, 얼리고, 재등록"
	   runcell B_bye_conns4 ;;
	4) banner "4장. rc=0의 배신 ① — lock을 지우면 연결만 조용히 죽는다"
	   runcell C_st_tcpest
	   runcell C_st_droplock
	   echo "  ↑ 같은 restore rc=0인데 위는 tcp=ok, 아래는 tcp=dead"
	   ;;
	5) banner "5장. rc=0의 배신 ② — 몇 초 뒤의 조용한 OOM"
	   runcell D_light_roomy
	   runcell D_light_silent
	   echo "  ↑ 복원 직후엔 둘 다 PONG — +5초 생존 검사에서만 갈린다"
	   ;;
	6) banner "6장. 전 자원 완전체 + 처방 세트 = 생존"
	   runcell F_all_rx ;;
	7) banner "7장. 상시 OS 세계 위에서 — 재등록 폭주까지 견딘다"
	   if [[ ! -f "$DIR/results/world/state.env" ]]; then
	       echo "  세계 기동 중..."; bash "$DIR/world_up.sh" | sed 's/^/  /'
	   fi
	   bash "$DIR/world_status.sh" | sed 's/^/  세계: /'
	   WORLD=1 RESUME=1 bash "$DIR/pbs_sweep.sh" 'G_flood_rereg' | grep -E "^\["
	   grep "^G_flood_rereg," "$DIR/results/pbs_matrix_world.csv" | tail -1 | \
	       awk -F, '{print "  → 판정: "$20"  (재등록 "$19"ms, 폭주 300건 후 생존)"}'
	   grep "HUB flood" "$DIR/results/world/hub.log" | tail -1 | sed 's/^/  hub: /'
	   ;;
	esac
done
echo
echo "데모 끝. 전체 매트릭스: sudo pbsprobe/run_all.sh (164셀)"
