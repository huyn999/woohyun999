#!/usr/bin/env bash
# pbsprobe/run_all.sh — 단일 진입점: 빌드 → 셀프테스트 관문 → 시나리오 생성 →
#                       스윕 → 요약까지 한 명령으로. (compat_sweep 스타일의 "한 방" 복원)
#
#   sudo pbsprobe/run_all.sh                    # 본 실행 전체 (97셀, ~20-30분)
#   CONSTRAINED=1 sudo pbsprobe/run_all.sh      # TV 제약(cgroup+stress+느린 디스크) 모드
#   DRYRUN=1 pbsprobe/run_all.sh                # criu 없이 배관 검증 (root 불필요)
#   sudo pbsprobe/run_all.sh 'B_*'              # 부분 실행 (glob은 스윕에 전달)
#   RESUME=1 sudo pbsprobe/run_all.sh           # 중단 이어가기 (빌드/관문은 재실행, 셀은 skip)
#   SKIP_SELFTEST=1 ...                         # 관문 생략 (권장하지 않음)
#
# 모든 env(CRIU_BIN/ONLY_FAMILY/PHASE_TIMEOUT_S 등)는 pbs_sweep.sh로 그대로 전달된다.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "══ [1/4] build ══"
bash "$DIR/build.sh"

if [[ "${SKIP_SELFTEST:-0}" != "1" ]]; then
	echo "══ [2/4] selftest (CRIU 없는 기능 관문 — FAIL이면 스윕 결과 신뢰 불가) ══"
	bash "$DIR/selftest.sh"
else
	echo "══ [2/4] selftest SKIP (SKIP_SELFTEST=1) ══"
fi

echo "══ [3/4] scenarios ══"
python3 "$DIR/gen_lbl.py"
python3 "$DIR/gen_matrix.py"

echo "══ [4/4] sweep ══"
set +e                                   # 스윕 내부는 셀 단위 내성 — 여기서 -e 해제
bash "$DIR/pbs_sweep.sh" "${1:-}"
rc=$?
set -e
[[ $rc -ne 0 ]] && { echo "sweep 비정상 종료 rc=$rc"; exit $rc; }

if [[ "${CONSTRAINED:-0}" == "1" ]]; then
	MTX="$DIR/results/pbs_matrix_tv.csv"; REP="$DIR/results/report_tv.md"
else
	MTX="$DIR/results/pbs_matrix.csv"; REP="$DIR/results/report.md"
fi
python3 "$DIR/summarize_pbs.py" "$MTX" > "$REP"
echo
echo "══ 완료 ══"
echo "  판정 CSV : $MTX"
echo "  리포트   : $REP"
echo "  판정 분포:"
python3 - "$MTX" <<-'PYEOF'
	import csv, sys, collections
	c = collections.Counter(r["verdict"] for r in csv.DictReader(open(sys.argv[1])))
	for v, n in c.most_common():
	    print(f"    {v:16s} {n}")
	PYEOF
