#!/usr/bin/env bash
# runner/run_campaign.sh — 캠페인 실행 드라이버 (calibration → expand → 실행 → finalize)
#
# 이식 소스: testbed_old/runner/run_campaign_redesign.sh
#   - PHASE 1 calibration(50/200/500/1000/1800 iters cold 런 → compute_ms 수집 → 선형 fit)
#     → 아래 "PHASE 1: calibration" 블록 + fit_iters()
#   - finalize()(collect.py + summarize.py 호출부) → 아래 finalize()
#   - log() 함수 → 그대로
# YAML 해석은 전부 python에 위임한다(bash로 YAML 파싱 금지) — 캠페인 스펙 자체의 축/sweep 전개는
# Task 14 expand_campaign.py의 몫이고, 여기서는 (a) SMOKE 축소, (b) calibration 조건 YAML 생성만
# python으로 처리한다. calibration 조건 YAML도 expand_campaign.make_cell()을 그대로 import해
# 재사용한다 — Option B absorb(§6-10) 계산이 본 sweep과 반드시 동일해야 하므로 로직을 복제하지
# 않는다(Task 14 expand_campaign.py가 config_to_env.py를 재사용하는 것과 동일 원칙).
#
# Usage:
#   testbed/runner/run_campaign.sh <campaign.yaml>
#   SMOKE=1 testbed/runner/run_campaign.sh <campaign.yaml>   # reps=1 + 워크로드당 대표 1셀
#   YES=1   testbed/runner/run_campaign.sh <campaign.yaml>   # expander 확인 프롬프트 생략(비대화용)
#   RUN_TIMEOUT=360 testbed/runner/run_campaign.sh <campaign.yaml>  # 런당 timeout 초(기본 360)
set -euo pipefail
# 렌즈4 F4: locale 지뢰 — 이 스크립트가 부르는 러너들의 $EPOCHREALTIME/`time` radix가 locale을
# 타므로(위 두 러너 참고), 캠페인 드라이버 자신도 같은 환경에서 timeout/awk 산술(fit_iters 등)을
# 하니 동일하게 고정한다.
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"

[[ $# -eq 1 ]] || { echo "Usage: $0 <campaign.yaml>  (env: SMOKE=1 YES=1 RUN_TIMEOUT=360)" >&2; exit 2; }
[[ -f "$1" ]] || { echo "ERROR: campaign YAML not found: $1" >&2; exit 1; }
CAMPAIGN_YAML="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

SMOKE="${SMOKE:-0}"
YES="${YES:-0}"
CANON_RUNS_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$TESTBED_DIR/runs")"
REQUESTED_RUNS_ROOT="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${RUNS_ROOT:-$CANON_RUNS_ROOT}")"
if [[ "$REQUESTED_RUNS_ROOT" != "$CANON_RUNS_ROOT" ]]; then
	echo "ERROR: RUNS_ROOT override is not supported: '$REQUESTED_RUNS_ROOT' != canonical '$CANON_RUNS_ROOT' (env/hardware modules recalculate testbed/runs/<run_id>)" >&2
	exit 1
fi
export RUNS_ROOT="$CANON_RUNS_ROOT"
CALIB_PORT="${CALIB_PORT:-18099}"   # calibration 런은 순차 실행(1개씩 끝나고 다음 시작) — 고정 포트 재사용 무해
RUN_TIMEOUT="${RUN_TIMEOUT:-360}"   # 런 1개당 timeout(초). old run_campaign_redesign.sh:134,144 이식 —
                                     # criu restore hang(실재 고장 모드)이 무인 캠페인 전체를 정지시키지 않게.

# 1MiB 버퍼 기준 iters→compute_ms fit용 측정점 (old PHASE 1 CALIB_ITERS 그대로 이식)
CALIB_ITERS=(50 200 500 1000 1800)

mkdir -p "$RUNS_ROOT"

# 동시 캠페인 직렬화(감사 구멍 3): 포트 충돌은 bind에서 시끄럽게 죽지만, drop_caches(전역 페이지
# 캐시 — 상대 측정 창 한복판을 오염), cpufreq clamp/restore(호스트 전역 DVFS — teardown 순서
# 꼬임), /dev/shm/criu.kdat(kdat 축 전역 상태 상호 삭제)은 *조용히* 오염된다. 전역 lock으로
# 한 번에 캠페인 하나만 허용한다. fd 9는 스크립트 수명 동안 유지되고 종료 시 자동 해제된다.
LOCK_FILE="$RUNS_ROOT/.campaign.lock"
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
	echo "ERROR: another campaign holds $LOCK_FILE — 동시 캠페인은 전역 상태(drop_caches/cpufreq/kdat)를 서로 오염시킨다. 끝나길 기다렸다 실행하라." >&2
	exit 1
fi

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$PROG"; }
field(){ awk -F= -v k="$2" '$1==k{print $2; exit}' "$RUNS_ROOT/$1/result.env" 2>/dev/null; }

# run_one <script> <run_id> [extra args...] — 러너 1개 실행, result.env의 result 필드로 PASS 판정.
# 주의: run_cold_start.sh는 set -e라 인프라 단계 실패 시 result.env를 아예 안 쓰고 즉시 죽을 수
# 있다(run_once.sh는 각 단계를 `|| { result_write FAIL ...; exit 1; }`로 가드해 항상 쓴다) — 두
# 경로 모두 여기서 동일하게 다루기 위해 스크립트 자체의 종료코드도 함께 본다(REPLY_RESULT 빈 값 방지).
# old(run_campaign_redesign.sh:134,144) 이식: 러너를 `timeout`으로 감싼다 — criu restore hang이
# 무인 캠페인 전체를 정지시키지 않게. `-k 30`은 timeout의 기본 SIGTERM 뒤 30초 유예를 두고서야
# SIGKILL하는 것 — 러너 자신의 EXIT trap(cleanup_install_trap, lib/cleanup.sh)이 SIGTERM에서
# teardown을 실행할 기회를 준다(default SIGTERM 유지, -s KILL로 바꾸지 말 것).
run_one() {
	local script="$1" rid="$2"; shift 2
	local rc=0
	mkdir -p "$RUNS_ROOT/$rid"
	rm -f "$RUNS_ROOT/$rid/result.env"
	# stdin은 /dev/null로 봉인(감사 구멍 4): PHASE 3 while-read 루프 안에서 러너가 stdin을 물려받는데,
	# 자식 중 stdin을 읽는 게 생기면(미래 워크로드 등) plan.tsv 라인을 먹어 런이 조용히 스킵된다.
	# fd 9(campaign flock)도 닫는다(9>&-): 안 닫으면 러너→wl_launch exec까지 상속돼 워크로드가
	# .campaign.lock의 잠금을 쥔 채 dump 대상이 되고, CRIU가 "Some file locks are hold by dumping
	# tasks!"로 모든 restore 런의 dump를 거부한다(RPi SMOKE 실증 — flock 방어선의 자책골 수정).
	timeout -k 30 "$RUN_TIMEOUT" "$script" --run-id "$rid" "$@" > "$RUNS_ROOT/${rid}.console.log" 2>&1 < /dev/null 9>&- || rc=$?
	if [[ "$rc" -eq 124 ]]; then
		REPLY_RESULT="TIMEOUT(${RUN_TIMEOUT}s)"
	else
		REPLY_RESULT="$(field "$rid" result)"
		[[ -n "$REPLY_RESULT" ]] || REPLY_RESULT="NO_RESULT_ENV(rc=$rc)"
		if [[ "$rc" -ne 0 && "$REPLY_RESULT" == "PASS" ]]; then
			REPLY_RESULT="PASS_BUT_RC($rc)"
		fi
	fi
	# 렌즈4 F5: rc=124(timeout이 SIGTERM 후 `-k 30` 유예까지 다 쓴 경우)나 rc=137(128+SIGKILL —
	# timeout 자신의 최종 SIGKILL이든 러너가 직접 SIGKILL당했든)이면 러너의 EXIT trap
	# (cleanup_install_trap, lib/cleanup.sh)이 못 돈다 — SIGKILL은 트랩할 수 없으므로 cgroup/
	# loop/dm/cpufreq clamp 등이 누수된 채 남을 수 있다. best-effort로 teardown을 태워 다음 런
	# 전에 회수를 시도한다(teardown.sh는 미생성 상태에서도 -d/-f 가드로 안전하게 no-op).
	if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
		"$TESTBED_DIR/env/teardown.sh" "$RUNS_ROOT/$rid" >>"$PROG" 2>&1 || true
	fi
	[[ "$rc" -eq 0 && "$REPLY_RESULT" == "PASS" ]]
}

# ---------------------------------------------------------------------------
# SMOKE 축소: reps=1 + 축/자유축/sweep 값을 전부 "첫 값 1개"로 줄인 임시 campaign YAML.
# (bash로 YAML 파싱 금지 — python -c로 원본 표현식 형태는 유지한 채 얕게 축소만 한다. 실제
#  정규화/absorb 계산은 여전히 expand_campaign.py 몫이다.) 워크로드가 N개면 결과는 N셀
# (old smoke의 "대표 2셀" = dirty 1셀 + initburst 1셀을 일반화한 것).
# ---------------------------------------------------------------------------
shrink_for_smoke() {  # <campaign_yaml_in> <campaign_yaml_out>
	python3 - "$1" "$2" <<'PY'
import sys

import yaml

path_in, path_out = sys.argv[1], sys.argv[2]
c = yaml.safe_load(open(path_in))
c["reps"] = 1
c["campaign"] = f"{c['campaign']}_smoke"


def first(expr, where):
	if isinstance(expr, list):
		if not expr:
			sys.exit(f"ERROR: SMOKE shrink: empty list at {where}")
		return [expr[0]]
	if isinstance(expr, dict) and "from" in expr:
		return [expr["from"]]
	sys.exit(f"ERROR: SMOKE shrink: unsupported values expression at {where}: {expr!r}")


axes = c.get("axes") or {}
for name, val in list(axes.items()):
	if isinstance(val, list):
		axes[name] = first(val, f"axes.{name}")
	elif isinstance(val, dict) and "values" in val:
		val["values"] = first(val["values"], f"axes.{name}.values")
	else:
		sys.exit(f"ERROR: SMOKE shrink: unknown axis shape axes.{name}={val!r}")

for wl in c.get("workloads") or []:
	sweep = wl.get("sweep")
	if not isinstance(sweep, dict):
		sys.exit(f"ERROR: SMOKE shrink: workload '{wl.get('name')}' missing sweep")
	for key in ("values", "values_mib", "calibrate_from_ms"):
		if key in sweep:
			sweep[key] = first(sweep[key], f"workload.{wl.get('name')}.sweep.{key}")
	da = wl.get("dump_at")
	if isinstance(da, list) and da:
		wl["dump_at"] = [da[0]]

with open(path_out, "w") as f:
	yaml.safe_dump(c, f, sort_keys=True, default_flow_style=False)
PY
}

# gen_calib_cfg <campaign_yaml> <wl_name> <param> <iters> <port> <out_yaml>
# expand_campaign.py의 make_cell()을 그대로 import해 calibration 조건 YAML을 만든다 — cpu=idle
# 고정(§6-11 "calibration은 cpu-idle에서"), 자유축 오버라이드 없음(combo=()), campaign의
# stress.target_total_mib/workers를 그대로 써서 본 sweep과 동일한 압박 조건에서 잰다.
gen_calib_cfg() {
	python3 - "$SCRIPT_DIR" "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import sys
from pathlib import Path

script_dir, campaign_yaml, wl_name, param, iters, port, out_path = sys.argv[1:8]
sys.path.insert(0, script_dir)
import yaml  # noqa: E402
import config_to_env as cte  # noqa: E402
import expand_campaign as ec  # noqa: E402

campaign = ec.load_campaign(Path(campaign_yaml))
base = cte.load_yaml(ec.SCENARIO_PATH)
manifest = cte.load_manifest(ec.TESTBED_DIR, wl_name)
cell, _ttm, _resid, _vmb = ec.make_cell(base, campaign, manifest, wl_name, param, int(iters), "idle", ())
cell["workload"]["params"]["port"] = int(port)
Path(out_path).write_text(yaml.safe_dump(cell, sort_keys=True, default_flow_style=False))
PY
}

# fit_iters <points_txt> <targets_ms_csv> <coeffs_out_txt> -> stdout: 각 target당 iters 1줄
# 이식: old PHASE 1 선형 fit 블록(pure python, no numpy). old는 n<2나 a<=0일 때 workload별
# 매직 상수(7.4ms/iter, initburst 1MiB 버퍼 기준)로 조용히 fallback했다 — 이 재작성판은 그 상수가
# 다른 워크로드엔 안 맞을 수 있어(§6-16 침묵 스킵 금지) fallback 대신 die 한다.
fit_iters() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys

points_path, targets_csv, coeffs_path = sys.argv[1], sys.argv[2], sys.argv[3]
targets = [float(x) for x in targets_csv.split(",")]
xs, ys = [], []
for line in open(points_path):
	parts = line.split()
	if len(parts) == 2:
		xs.append(float(parts[0]))
		ys.append(float(parts[1]))
n = len(xs)
if n < 2:
	sys.exit(f"ERROR: calibration produced {n} valid point(s) (<2) — cannot fit iters->ms (see {points_path})")
mx = sum(xs) / n
my = sum(ys) / n
den = sum((x - mx) ** 2 for x in xs) or 1e-9
a = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
b = my - a * mx
if a <= 0:
	sys.exit(f"ERROR: calibration fit slope a={a} <= 0 (degenerate data, see {points_path})")
with open(coeffs_path, "w") as f:
	f.write(f"a={a}\nb={b}\nn_points={n}\n")
for ms in targets:
	it = round((ms - b) / a)
	if it < 1:
		it = 1
	print(int(it))
PY
}

# finalize — collect+summarize 롤업. old(run_campaign_redesign.sh:160)처럼 EXIT trap으로도 걸어
# Ctrl-C/kill로 중도 중단해도 그때까지 끝난 런들은 CSV로 롤업되게 한다. PHASE 4에서 정상 경로로도
# 명시 호출되므로, 이중 실행(정상 완료 후 스크립트 exit → trap이 다시 호출) 방지용 once 가드
# (FINALIZED=1)를 둔다 — 실패로 끝났어도 재시도하지 않고 그 결과를 최종으로 삼는다. 이번 invocation의
# PHASE 2 expand가 성공하기 전이면, 같은 campaign dir에 남은 stale plan.tsv를 재사용하지 않고 no-op.
finalize() {
	[[ "${FINALIZED:-0}" == "1" ]] && return 0
	FINALIZED=1
	if [[ "${EXPANDED:-0}" != "1" ]]; then
		log "FINALIZE: PHASE 2 expand 미완료 — stale plan.tsv 재사용 방지를 위해 collect/summarize 스킵"
		return 0
	fi
	if [[ ! -f "$CAMPAIGN_DIR/plan.tsv" ]]; then
		log "FINALIZE: plan.tsv 없음(PHASE 2 expand 전 중단) — collect/summarize 스킵"
		return 0
	fi
	log "FINALIZE: collect + summarize -> $CAMPAIGN_DIR"
	local collect="$SCRIPT_DIR/collect.py" summarize="$SCRIPT_DIR/summarize.py"
	local rc=0
	if [[ ! -f "$collect" || ! -f "$summarize" ]]; then
		log "ERROR: Task 16 미완 — collect.py/summarize.py 없음 (collect=$collect summarize=$summarize)"
		return 1
	fi
	# Task 16: RUNS_ROOT는 캠페인 간 공유 디렉터리다(Task 15 §검증 2에서 실측 — 다른 캠페인/수동
	# 테스트가 같은 run_id를 재사용하면 result.env를 덮어쓴다). collect.py에 RUNS_ROOT를 그대로
	# 넘기면 이 캠페인이 발주하지 않은 run까지 섞인다 — run_id manifest로 이 캠페인 것만 필터링한다.
	# hardening v2 §2: main과 calibration을 분리한다 — run_ids.txt = plan.tsv rid열(본 sweep)만 담아
	# all_runs.csv/summary_by_condition.csv를 main 전용으로 유지하고, calibration 런은
	# calibration_run_ids.txt + calibration_runs.csv로 별도 수집한다(요약/조건 median에 미포함).
	awk -F'\t' 'NF{print $1}' "$CAMPAIGN_DIR/plan.tsv" | sed '/^$/d' > "$CAMPAIGN_DIR/run_ids.txt"
	"$collect" "$RUNS_ROOT" "$CAMPAIGN_DIR/run_ids.txt" > "$CAMPAIGN_DIR/all_runs.csv" 2>>"$PROG" || { log "collect failed"; rc=1; }
	local expected_rows collected_rows
	expected_rows="$(wc -l < "$CAMPAIGN_DIR/run_ids.txt" 2>/dev/null || echo 0)"
	collected_rows="$(awk 'END{print (NR > 0 ? NR - 1 : 0)}' "$CAMPAIGN_DIR/all_runs.csv" 2>/dev/null || echo 0)"
	if [[ "$collected_rows" -ne "$expected_rows" ]]; then
		log "collect incomplete: all_runs.csv has $collected_rows row(s), expected $expected_rows from run_ids.txt"
		rc=1
	fi
	"$summarize" "$CAMPAIGN_DIR/all_runs.csv" > "$CAMPAIGN_DIR/summary_by_condition.csv" 2>>"$PROG" || { log "summarize failed"; rc=1; }
	if [[ "${#CALIB_RUN_IDS[@]}" -gt 0 ]]; then
		printf '%s\n' "${CALIB_RUN_IDS[@]}" | sed '/^$/d' > "$CAMPAIGN_DIR/calibration_run_ids.txt"
		"$collect" "$RUNS_ROOT" "$CAMPAIGN_DIR/calibration_run_ids.txt" \
			> "$CAMPAIGN_DIR/calibration_runs.csv" 2>>"$PROG" || { log "calibration collect failed"; rc=1; }
		expected_rows="$(wc -l < "$CAMPAIGN_DIR/calibration_run_ids.txt" 2>/dev/null || echo 0)"
		collected_rows="$(awk 'END{print (NR > 0 ? NR - 1 : 0)}' "$CAMPAIGN_DIR/calibration_runs.csv" 2>/dev/null || echo 0)"
		if [[ "$collected_rows" -ne "$expected_rows" ]]; then
			log "calibration collect incomplete: calibration_runs.csv has $collected_rows row(s), expected $expected_rows from calibration_run_ids.txt"
			rc=1
		fi
		log "  calibration: $(wc -l < "$CAMPAIGN_DIR/calibration_run_ids.txt") run_id(s) -> calibration_runs.csv"
	fi
	local rows; rows="$(wc -l < "$CAMPAIGN_DIR/all_runs.csv" 2>/dev/null || echo 1)"
	log "DONE. rows=$((rows - 1)) (main only; calibration in calibration_runs.csv)"
	return "$rc"
}

# ======================= 캠페인 이름/디렉터리 =======================
CAMPAIGN_NAME="$(python3 - "$SCRIPT_DIR" "$CAMPAIGN_YAML" <<'PY'
import sys
from pathlib import Path

script_dir, campaign_yaml = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
import expand_campaign as ec  # noqa: E402

print(ec.load_campaign(Path(campaign_yaml))["campaign"])
PY
)"

if [[ "$SMOKE" == "1" ]]; then
	CAMPAIGN_NAME="${CAMPAIGN_NAME}_smoke"
	CALIB_ITERS=(200 800)
fi

CAMPAIGN_DIR="$TESTBED_DIR/experiments/$CAMPAIGN_NAME"
mkdir -p "$CAMPAIGN_DIR"
PROG="$CAMPAIGN_DIR/progress.log"
: > "$PROG"
FAILS="$CAMPAIGN_DIR/fails.txt"     # 본 sweep(plan.tsv) 런 실패만 (PHASE 3)
: > "$FAILS"
CALIB_FAILS="$CAMPAIGN_DIR/calibration_fails.txt"   # calibration 런 실패만 (PHASE 1, 별도 집계)
: > "$CALIB_FAILS"
CALIB_RUN_IDS=()   # Task 16 finalize()가 캠페인-스코프 manifest를 짤 때 plan.tsv rid열에 더할 calibration run_id들
EXPANDED=0         # 이번 invocation에서 PHASE 2가 성공했을 때만 finalize가 plan.tsv를 신뢰한다.

# old(run_campaign_redesign.sh:160) 이식: Ctrl-C/kill로 중도 중단돼도 여기까지 끝난 런들은
# finalize()의 once 가드 덕에 안전하게 CSV 롤업이 시도된다(PHASE 4의 정상 호출과 안 겹침).
trap finalize EXIT

EFFECTIVE_YAML="$CAMPAIGN_YAML"
if [[ "$SMOKE" == "1" ]]; then
	SMOKE_YAML="$CAMPAIGN_DIR/campaign.smoke.yaml"
	shrink_for_smoke "$CAMPAIGN_YAML" "$SMOKE_YAML"
	EFFECTIVE_YAML="$SMOKE_YAML"
	log "SMOKE: shrunk campaign -> $EFFECTIVE_YAML (reps=1, CALIB_ITERS=(${CALIB_ITERS[*]}))"
fi

log "CAMPAIGN=$CAMPAIGN_NAME yaml=$EFFECTIVE_YAML"

# ======================= PHASE 1: calibration (calibrate_from_ms 있는 워크로드만) =======================
# 이식: old PHASE 1 — cold 런들로 iters->compute_ms 표본을 모으고 선형 fit으로 목표 ms들을
# iters로 환산한다. §6-11: calibration(선형 fit)은 cpu-idle에서 — gen_calib_cfg가 cpu="idle" 고정.
RESOLVE_ARGS=()
# 각 calibrate_from_ms 워크로드 1줄: <wl>\t<param>\t<metric>\t<ms_csv>. param/metric은 manifest의
# calibration 블록에서 읽는다(hardening v2 §2 — bash가 wl_compute_ms를 하드코딩하지 않게). YAML은
# python만 파싱한다는 규약대로 이 인라인 블록이 manifest를 읽어 bash에 넘긴다. sweep.param과
# manifest calibration.param 정합은 expand_campaign.load_campaign/expand가 더 이른 시점에 검증하지만,
# 여기서도 metric을 안전하게 확정하려 calibration 블록 존재를 확인한다.
CALIB_LINES="$(python3 - "$SCRIPT_DIR" "$EFFECTIVE_YAML" <<'PY'
import sys
from pathlib import Path

script_dir, campaign_yaml = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
import config_to_env as cte  # noqa: E402
import expand_campaign as ec  # noqa: E402

campaign = ec.load_campaign(Path(campaign_yaml))
for wl in campaign["workloads"]:
	sweep = wl.get("sweep") or {}
	if "calibrate_from_ms" in sweep:
		manifest = cte.load_manifest(ec.TESTBED_DIR, wl["name"])
		calib = manifest.get("calibration") or {}
		metric = calib.get("metric")
		param = calib.get("param")
		if not metric or not param:
			sys.exit(f"ERROR: workload '{wl['name']}': manifest calibration.metric/param 누락")
		if sweep.get("param") != param:
			sys.exit(f"ERROR: workload '{wl['name']}': sweep.param {sweep.get('param')!r} != "
			         f"calibration.param {param!r}")
		ms_vals = ec.norm_values(sweep["calibrate_from_ms"])
		print(f"{wl['name']}\t{param}\t{metric}\t{','.join(str(v) for v in ms_vals)}")
PY
)"

if [[ -n "$CALIB_LINES" ]]; then
	CALIB_DIR="$CAMPAIGN_DIR/calibration"
	mkdir -p "$CALIB_DIR/configs"
	while IFS=$'\t' read -r wl_name param metric ms_csv; do
		[[ -n "$wl_name" ]] || continue
		log "PHASE 1: calibration $wl_name.$param->wl_$metric (targets_ms=$ms_csv) @ cpu-idle, CALIB_ITERS=(${CALIB_ITERS[*]})"
		POINTS_TXT="$CALIB_DIR/${wl_name}_${param}_points.txt"
		: > "$POINTS_TXT"
		for it in "${CALIB_ITERS[@]}"; do
			cfg="$CALIB_DIR/configs/calib_${wl_name}_${param}_it${it}.yaml"
			gen_calib_cfg "$EFFECTIVE_YAML" "$wl_name" "$param" "$it" "$CALIB_PORT" "$cfg"
			# calibration run_id도 캠페인 접두를 붙인다(hardening v2 §1) — RUNS_ROOT는 캠페인 간
			# 공유라, 접두 없으면 다른 캠페인의 동명 calibration run과 result.env가 겹친다.
			rid="${CAMPAIGN_NAME}_calib_${wl_name}_${param}_it${it}"
			# main run은 expand_campaign.py가 run_id ≤100을 검증하지만 calibration은 그보다 먼저
			# 여기서 만들어지므로 같은 한도를 선검증한다 (Codex 교차검토 low-1: cgroup/dm/파일명 안전).
			if (( ${#rid} > 100 )); then
				log "FATAL: calibration run_id too long (${#rid} > 100): $rid — 캠페인 이름을 줄여라"
				exit 1
			fi
			CALIB_RUN_IDS+=("$rid")   # PASS/FAIL 무관하게 기록 — finalize()가 calibration_runs.csv로 분리 수집
			if run_one "$SCRIPT_DIR/run_cold_start.sh" "$rid" --config "$cfg"; then
				ms="$(field "$rid" "wl_${metric}")"
				log "  CALIB $rid -> PASS wl_${metric}=$ms"
				if [[ "$ms" =~ ^[0-9.]+$ ]]; then
					echo "$it $ms" >> "$POINTS_TXT"
				else
					log "  WARN: $rid wl_${metric}='$ms' not numeric — excluded from fit"
				fi
			else
				log "  CALIB $rid -> FAIL ($REPLY_RESULT)"
				echo "FAIL $rid" >> "$CALIB_FAILS"
			fi
		done

		COEFFS_TXT="$CALIB_DIR/${wl_name}_${param}_fit.txt"
		if ! resolved_raw="$(fit_iters "$POINTS_TXT" "$ms_csv" "$COEFFS_TXT")"; then
			log "FATAL: calibration fit failed for $wl_name.$param — aborting campaign"
			exit 1
		fi
		mapfile -t resolved <<< "$resolved_raw"
		log "  fit: $(tr '\n' ' ' < "$COEFFS_TXT") -> iters=(${resolved[*]})"

		IFS=',' read -ra ms_arr <<< "$ms_csv"
		n_targets="${#ms_arr[@]}"
		if [[ "${#resolved[@]}" -ne "$n_targets" ]]; then
			log "FATAL: fit produced ${#resolved[@]} iters value(s), expected $n_targets — aborting"
			exit 1
		fi
		resolve_csv="$(IFS=,; echo "${resolved[*]}")"
		RESOLVE_ARGS+=("${wl_name}.${param}=${resolve_csv}")
	done <<< "$CALIB_LINES"
fi

# ======================= PHASE 2: expand =======================
resolve_flags=()
for r in "${RESOLVE_ARGS[@]}"; do
	resolve_flags+=(--resolve "$r")
done
yes_flag=()
[[ "$YES" == "1" ]] && yes_flag=(--yes)

log "PHASE 2: expand -> $CAMPAIGN_DIR (resolve: ${RESOLVE_ARGS[*]:-none})"
"$SCRIPT_DIR/expand_campaign.py" "$EFFECTIVE_YAML" "$CAMPAIGN_DIR" "${resolve_flags[@]}" "${yes_flag[@]}"
EXPANDED=1

# ======================= PHASE 3: 실행 (plan.tsv 순회) =======================
# 새 러너(run_cold_start.sh/run_once.sh)는 각자 EXIT trap으로 env/stress teardown을 보장하므로
# (lib/cleanup.sh) old의 between()(pkill stress-ng + teardown + drop_caches + sleep 1) 같은
# 런 사이 수동 정리는 필요 없다 — 다음 런은 이전 런의 trap이 완전히 끝난 뒤에만 시작된다.
log "PHASE 3: run -> $CAMPAIGN_DIR/plan.tsv"
while IFS=$'\t' read -r rid kind cfg kdat; do
	[[ -n "$rid" ]] || continue
	case "$kind" in
		cold)
			log "COLD    $rid"
			if run_one "$SCRIPT_DIR/run_cold_start.sh" "$rid" --config "$cfg"; then
				log "  -> PASS cold_response_s=$(field "$rid" cold_response_s)"
			else
				log "  -> FAIL ($REPLY_RESULT)"
				echo "FAIL $rid" >> "$FAILS"
			fi
			;;
		restore)
			log "RESTORE $rid (kdat=$kdat)"
			if run_one "$SCRIPT_DIR/run_once.sh" "$rid" --config "$cfg" --kdat-cache "$kdat"; then
				log "  -> PASS restore_response_s=$(field "$rid" restore_response_s) kdat_probing_s=$(field "$rid" kdat_probing_s)"
			else
				log "  -> FAIL ($REPLY_RESULT)"
				echo "FAIL $rid" >> "$FAILS"
			fi
			;;
		*)
			log "  -> FAIL $rid (unknown kind '$kind')"
			echo "FAIL $rid" >> "$FAILS"
			;;
	esac
done < "$CAMPAIGN_DIR/plan.tsv"

# ======================= PHASE 4: finalize (collect + summarize) =======================
# 정상 완료 경로의 명시 호출 — finalize() 내부 once 가드 덕에, 이 뒤 스크립트가 exit할 때 EXIT
# trap이 finalize를 다시 부르더라도 두 번째 호출은 즉시 no-op(FINALIZED=1)이라 이중 실행 없음.
finalize_rc=0
finalize || finalize_rc=$?

# ======================= PHASE 5: 요약 (§6-16 침묵 스킵 금지 — 항상 총/PASS/FAIL 출력) =======================
total="$(wc -l < "$CAMPAIGN_DIR/plan.tsv" 2>/dev/null || echo 0)"
fail_n="$(wc -l < "$FAILS" 2>/dev/null || echo 0)"
pass_n="$((total - fail_n))"
calib_fail_n="$(wc -l < "$CALIB_FAILS" 2>/dev/null || echo 0)"
log "SUMMARY: total=$total pass=$pass_n fail=$fail_n (calibration fail=$calib_fail_n, not counted in total)"
if [[ "$fail_n" -gt 0 ]]; then
	log "FAILED run_ids (main sweep):"
	while IFS= read -r line; do log "  - $line"; done < "$FAILS"
fi
if [[ "$calib_fail_n" -gt 0 ]]; then
	log "FAILED run_ids (calibration):"
	while IFS= read -r line; do log "  - $line"; done < "$CALIB_FAILS"
fi

overall_rc=0
[[ "$fail_n" -gt 0 ]] && overall_rc=1
[[ "$calib_fail_n" -gt 0 ]] && overall_rc=1
[[ "$finalize_rc" -ne 0 ]] && overall_rc=1
exit "$overall_rc"
