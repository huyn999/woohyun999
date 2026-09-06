#!/usr/bin/env python3
"""campaign YAML → 실행 계획 전개 (스펙 §4-C, §4-C-2).
값 표현식 정규화 / 자유 축 / cold 중복 제거 / 포트 명시 배정 / 조합 폭발 가드.

Consumes:
  - <campaign.yaml>  (configs/campaign_*.yaml 스펙, §4-C/C-2)
  - testbed/scenario.yaml (base — 모든 조건 YAML의 출발점)
  - testbed/workloads/<name>/workload.yaml (manifest — params/phases/resident 검증)

Produces (<out_dir>/):
  - plan.tsv        run_id \\t kind(cold|restore) \\t config_yaml(절대경로) \\t kdat(on|off|-)
  - configs/<run_id>.yaml   조건별 완전 YAML (config_to_env.py가 그대로 --config로 받는다)
  - expansion.json  정규화된 sweep 값 · 포트 배정 · 셀 구조 (재현성 메타)

YAML 파싱/manifest 병합/resident 계산은 runner/config_to_env.py의 함수를 그대로 import해
재사용한다(동일 디렉터리 — 브리프: "동일해야 함"의 가장 확실한 보증은 같은 함수를 호출하는 것).
"""
import argparse
import copy
import itertools
import json
import re
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import config_to_env as cte  # noqa: E402  (경로 삽입 후 import)

PORT_BASE = 18100
# 캠페인 이름 문자집합(hardening v2 §1): run_id 접두(namespace)·experiments/<name> 디렉터리·
# collect 필터로 그대로 쓰이므로 셸/파일/cgroup 안전 문자만 허용한다.
CAMPAIGN_NAME_RE = re.compile(r'^[a-z0-9_-]+$')
# run_id 최종 길이 상한(hardening v2 §1): cgroup 경로(criu_test_<run_id>)·dm 이름·파일명 안전.
RUN_ID_MAX_LEN = 100
# stress-ng 인스턴스 1개의 메모리 floor(MiB) 기본값 — 플랫폼 의존 실측값이라(x86 ~38,
# RPi aarch64 ~3; stress/measure_floor.sh로 측정) base scenario의 stress.floor_mib가 있으면
# 그것을 쓴다(make_cell). 이 값이 stress/start.sh의 STRESS_FLOOR_MIB(config 경유)와 같아야
# absorb 하한 가드와 실제 분배가 일치한다 — 둘 다 같은 scenario 키에서 오므로 자동 정합.
VM_FLOOR_MIB = 38
CPU_MAP = {"busy": True, "idle": False}      # 내장 cpu 축 → stress.cpu_saturate
KDAT_VALUES = ("on", "off")                  # 내장 kdat 축 허용값
# Option B absorb의 입력 2종 — config 키가 아니라 make_cell의 계산 변수다(스키마에 없어
# config_to_env가 거부하므로 cell에 쓰면 안 된다). 자유 축이 이 key를 sweep하면 "총 메모리
# (memory.max) 고정 + stress 점유 준위/프로세스 수"를 축으로 여는 실험이 된다:
#   target_total_mib — 준위(총 흡수 목표 MiB). 하한 = resident + workers×38MiB(floor 가드).
#   workers          — 인스턴스 수. 준위를 floor 아래로 내리려면 이 축(또는 캠페인 값)을 줄인다.
ABSORB_AXIS_KEYS = ("stress.target_total_mib", "stress.workers")

# campaign YAML의 인지 top-level 키(§4-C). 이 밖의 키는 die() — 이전엔 무경고로 무시돼
# 오타나 (per-run 노브를 여기 잘못 놓는 등의) 설계 실수가 침묵 통과했다(리뷰 렌즈1 Fix).
# dump_at은 여기 없다 — 워크로드별(workloads[].dump_at)로만 존재, 캠페인 top-level엔 자리가 없다.
KNOWN_CAMPAIGN_KEYS = {
    "campaign", "reps", "stress", "axes", "workloads",
    "warmup_pings", "checkpoint_after_s", "cache_policy",
}
# 캠페인 top-level에 두면 각 셀 YAML(base 값을 override)에 그대로 전파되는 per-run 노브
# (config_to_env.py의 ALLOWED_TOP_LEVEL 스칼라 노브와 동일 키 — 값은 검증 없이 그대로 전달하고
# 타입 검증은 기존대로 config_to_env.py에 맡긴다).
PROPAGATED_RUN_KNOBS = ("warmup_pings", "checkpoint_after_s", "cache_policy")

TESTBED_DIR = Path(__file__).resolve().parent.parent
SCENARIO_PATH = TESTBED_DIR / "scenario.yaml"


def die(message: str) -> None:
    """설계 시점 에러 — stderr + exit 1 (config_to_env.py의 die()와 동일 관례)."""
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# 값 표현식 정규화 (§4-C-2-1)
# ---------------------------------------------------------------------------
def norm_values(v):
    """[..] | {from,to,step} | {from,to,factor} → 명시 리스트 (§4-C-2)."""
    if isinstance(v, list):
        if not v:
            die(f"empty values list: {v!r}")
        return list(v)
    if not isinstance(v, dict):
        die(f"bad values expression (list 또는 {{from,to,step|factor}} 필요): {v!r}")
    if "from" not in v or "to" not in v:
        die(f"values expression needs 'from'/'to': {v!r}")
    lo, hi = v["from"], v["to"]
    if "step" in v:
        step = v["step"]
        if step <= 0:
            die(f"values step must be > 0: {v!r}")
        out = []
        i = 0
        while True:
            x = round(lo + i * step, 9)
            if x > hi:
                break
            out.append(x)
            i += 1
        if not out:
            die(f"values expression produced an empty list: {v!r}")
        return out
    if "factor" in v:
        factor = v["factor"]
        if factor <= 1:
            die(f"values factor must be > 1: {v!r}")
        out, x = [], lo
        while x <= hi:
            out.append(x)
            x *= factor
        if not out:
            die(f"values expression produced an empty list: {v!r}")
        return out
    die(f"values expression needs 'step' or 'factor': {v!r}")


# ---------------------------------------------------------------------------
# 자유 축: dict 경로 세팅 (§4-C-2-2)
# ---------------------------------------------------------------------------
def set_by_path(d: dict, dotted_key: str, value) -> None:
    parts = dotted_key.split(".")
    cur = d
    for p in parts[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[parts[-1]] = value


def validate_axis_key(axis_name: str, key_path: str) -> None:
    """자유 축 key 경로를 설계 시점에 검증한다. 이전엔 오타(예: stress.target_mib)가 그대로
    셀 YAML에 쓰여 PHASE 3의 모든 런이 config_to_env exit 2로 늦게 죽었다(§4-C-2-3 "조용히
    시작 금지" 위반). absorb 입력 2종(ABSORB_AXIS_KEYS)은 config 키가 아니라 make_cell 계산
    변수라 그대로 허용하고, 나머지는 config_to_env.py의 스키마 상수(ALLOWED_TOP_LEVEL/
    ALLOWED_KEYS — 스키마 진실은 한 곳)로 각 경로 조각을 검사한다. ALLOWED_KEYS에 항목이
    없는 깊이(예: workload.params.<이름>)는 여기선 통과 — make_cell의 render_flags가 같은
    전개 시점에 manifest로 검증한다."""
    if key_path in ABSORB_AXIS_KEYS:
        return
    parts = key_path.split(".")
    if parts[0] not in cte.ALLOWED_TOP_LEVEL:
        die(f"free axis '{axis_name}': unknown top-level section in key '{key_path}' "
            f"(allowed: {', '.join(sorted(cte.ALLOWED_TOP_LEVEL))}; "
            f"absorb 입력 축은 {list(ABSORB_AXIS_KEYS)})")
    for i in range(1, len(parts)):
        allowed = cte.ALLOWED_KEYS.get(".".join(parts[:i]))
        if allowed is not None and parts[i] not in allowed:
            die(f"free axis '{axis_name}': key '{key_path}' — '{parts[i]}' not in "
                f"'{'.'.join(parts[:i])}' schema (allowed: {', '.join(sorted(allowed))}; "
                f"absorb 입력 축은 {list(ABSORB_AXIS_KEYS)})")


def cross(free_axes):
    """free_axes: [(axis_name, key_path, values_list), ...] → 각 조합의
    [(axis_name, key_path, value), ...] 리스트를 순서 고정으로 yield (itertools.product 래핑,
    축 없으면 빈 조합 1개 — 결정성: 입력 리스트 순서 그대로, 정렬/난수 없음)."""
    if not free_axes:
        yield ()
        return
    names_keys = [(name, key) for name, key, _ in free_axes]
    value_lists = [vals for _, _, vals in free_axes]
    for combo_vals in itertools.product(*value_lists):
        yield tuple((names_keys[i][0], names_keys[i][1], combo_vals[i]) for i in range(len(combo_vals)))


# ---------------------------------------------------------------------------
# sweep 값 (§4-C-2, values_mib 단위환산 / calibrate_from_ms는 --resolve 필수)
# ---------------------------------------------------------------------------
def sweep_values(wl: dict, resolves: dict):
    """workload 항목의 sweep 블록 → (param, display_vals, actual_vals, is_mib).
    display_vals: 사람이 선언한 단위(예: MiB) 그대로 — run_id/expansion.json 기록용.
    actual_vals : config에 실제로 들어갈 값(bytes로 환산된 것 포함)."""
    wl_name = wl["name"]
    sweep = wl.get("sweep")
    if not isinstance(sweep, dict) or "param" not in sweep:
        die(f"workload '{wl_name}': 'sweep' needs at least 'param'")
    param = sweep["param"]

    if "values_mib" in sweep:
        display_vals = norm_values(sweep["values_mib"])
        actual_vals = [int(round(v)) * 1048576 for v in display_vals]
        return param, display_vals, actual_vals, True

    if "values" in sweep:
        vals = norm_values(sweep["values"])
        return param, vals, vals, False

    if "calibrate_from_ms" in sweep:
        ms_vals = norm_values(sweep["calibrate_from_ms"])
        key = f"{wl_name}.{param}"
        if key not in resolves:
            die(
                f"workload '{wl_name}': sweep.calibrate_from_ms requires "
                f"--resolve {key}=<v1,v2,...> (one value per calibrate_from_ms entry, "
                f"{len(ms_vals)} expected)"
            )
        resolved = resolves[key]
        if len(resolved) != len(ms_vals):
            die(
                f"--resolve {key} has {len(resolved)} value(s), expected "
                f"{len(ms_vals)} (one per calibrate_from_ms entry)"
            )
        return param, ms_vals, resolved, False

    die(f"workload '{wl_name}': sweep needs one of values / values_mib / calibrate_from_ms")


# ---------------------------------------------------------------------------
# 셀 = base 병합 + workload/cpu/자유축 오버라이드 + Option B absorb (§6-10)
# ---------------------------------------------------------------------------
def make_cell(base: dict, campaign: dict, manifest: dict, wl_name: str,
              param: str, value, cpu: str, combo) -> tuple:
    """반환: (cell dict — port/dump_at/kdat 제외 나머지 전부 확정된 조건 YAML 골격,
             target_total_mib 최종값, resident_bytes, vm_bytes_per_worker) — 후자 셋은
             expansion.json 기록용."""
    if cpu not in CPU_MAP:
        die(f"unknown cpu axis value '{cpu}' (allowed: {sorted(CPU_MAP)})")

    cell = copy.deepcopy(base)
    # 캠페인 top-level의 per-run 노브가 base scenario 값을 override(§4-A6 등 캠페인 단위로
    # warmup_pings:0 같은 측정점을 열기 위함) — 캠페인에 없으면 base 값 그대로 유지.
    for knob in PROPAGATED_RUN_KNOBS:
        if knob in campaign:
            cell[knob] = campaign[knob]
    cell["workload"] = {"name": wl_name, "params": {param: value}}
    cell.setdefault("stress", {})["cpu_saturate"] = CPU_MAP[cpu]

    target_total_mib = campaign["stress"]["target_total_mib"]
    workers = campaign["stress"]["workers"]
    for _axis_name, key_path, axis_val in combo:
        if key_path in ABSORB_AXIS_KEYS:
            # absorb 입력 축은 cell에 쓰지 않고 계산 변수로만 소비한다(ABSORB_AXIS_KEYS 주석).
            # int 강제: target_total_mib는 아래 int()가 소수를 조용히 잘라 run_id 라벨(1278.5)과
            # 실제 계산(1278)이 어긋나고, workers는 나눗셈 몫이 달라진다 — 잘림 대신 설계 에러.
            if isinstance(axis_val, bool) or not isinstance(axis_val, int):
                die(f"free axis on '{key_path}' must have int values (got {axis_val!r})")
            if key_path == "stress.target_total_mib":
                target_total_mib = axis_val
            else:
                workers = axis_val
        else:
            set_by_path(cell, key_path, axis_val)

    if workers <= 0:
        die(f"stress workers must be > 0 (got {workers})")

    # resident 평가: config_to_env.py의 render_flags/resident_bytes를 그대로 재사용해야
    # "동일해야 함"(브리프)이 보장된다 — 여기서 로직을 복사하지 않는다.
    # 주의: {param: value}가 아니라 cell["workload"]["params"] 전체(자유축 오버라이드가
    # workload.params.*를 타깃했다면 위 set_by_path에서 이미 반영된 상태)를 넘긴다 —
    # 그렇지 않으면 absorb 계산이 오버라이드 이전 값으로 어긋난다(§6-10 침묵 위반).
    _flags, merged_params = cte.render_flags(manifest, cell["workload"]["params"])
    resident = cte.resident_bytes(manifest, merged_params)

    floor_mib = (base.get("stress") or {}).get("floor_mib", VM_FLOOR_MIB)
    if isinstance(floor_mib, bool) or not isinstance(floor_mib, int) or floor_mib < 1:
        die(f"scenario stress.floor_mib must be an int >= 1 (got {floor_mib!r})")
    total_bytes = int(target_total_mib) * 1048576 - resident
    per_worker = total_bytes // workers
    floor_bytes = floor_mib * 1048576
    if per_worker < floor_bytes:
        die(
            f"workload '{wl_name}' {param}={value}: vm_bytes/worker={per_worker}B "
            f"< floor {floor_bytes}B ({floor_mib}MiB) — target_total_mib={target_total_mib}, "
            f"resident_bytes={resident}, workers={workers}. "
            "Option B absorb가 하한 미달 — 캠페인의 target_total_mib/workers/sweep 값을 조정하라."
        )
    cell["stress"]["vm_workers"] = workers
    cell["stress"]["vm_bytes"] = int(per_worker)
    return cell, target_total_mib, resident, int(per_worker)


# ---------------------------------------------------------------------------
# run_id (§4-C-2-4: 값이 변하는 축만 토큰으로)
# ---------------------------------------------------------------------------
def sweep_token(param: str, display_val, is_mib: bool) -> str:
    if is_mib:
        # int()는 50과 50.5를 둘 다 "50M"으로 뭉개 run_id가 충돌하고(중복 run_id die로
        # 오사유가 남는다) — %g로 정밀도를 보존한다(정수값은 여전히 "50M", 소수는 "50.5M").
        return f"{display_val:g}M"
    return f"{display_val}"


def run_name(wl_name, param, display_val, sweep_varies, is_mib,
             cpu, cpu_varies, combo, free_varies, rep,
             kind, da=None, da_varies=False, kd=None) -> str:
    tokens = [wl_name]
    if sweep_varies:
        tokens.append(sweep_token(param, display_val, is_mib))
    for axis_name, _key_path, val in combo:
        if free_varies[axis_name]:
            tokens.append(f"{axis_name}{val}")
    if cpu_varies:
        tokens.append(f"cpu{cpu}")
    if kind == "restore":
        if da_varies:
            tokens.append(f"d{da}")
        # kdat은 축의 "변화 여부"와 무관하게 항상 토큰화한다: 이게 cold/restore run_id를
        # 구조적으로 구분하는 유일한 표식이다(kdat이 단일값이면 dump_at/free축/cpu/sweep이
        # 전부 고정일 때 cold와 restore의 다른 토큰이 kdat 하나뿐인 경우가 생김 — 생략하면
        # 두 kind가 같은 run_id로 충돌해 run 디렉터리/조건 YAML을 덮어쓴다. 문서 예시
        # dirty_50M_cpubusy_koff_rep03도 kdat을 항상 보여준다).
        tokens.append(f"k{kd}")
    tokens.append(f"rep{rep:02d}")
    return "_".join(tokens)


# ---------------------------------------------------------------------------
# 전개 본체
# ---------------------------------------------------------------------------
def load_campaign(path: Path) -> dict:
    campaign = cte.load_yaml(path)
    unknown = set(campaign) - KNOWN_CAMPAIGN_KEYS
    if unknown:
        die(f"unknown campaign key(s): {', '.join(sorted(unknown))} "
            f"(allowed: {', '.join(sorted(KNOWN_CAMPAIGN_KEYS))})")
    for key in ("campaign", "reps", "stress", "workloads"):
        if key not in campaign:
            die(f"campaign YAML missing required top-level key: '{key}'")
    # 캠페인 이름 검증(hardening v2 §1) — 이 이름이 모든 run_id의 접두(namespace)가 되므로
    # (아래 expand()) 셸/파일/cgroup 안전 문자만 허용한다. bool/숫자 등 비문자열도 거부.
    name = campaign["campaign"]
    if not isinstance(name, str) or not CAMPAIGN_NAME_RE.match(name):
        die(f"campaign name must match ^[a-z0-9_-]+$ (got {name!r})")
    reps = campaign["reps"]
    # bool은 int의 서브클래스라 isinstance(reps, int)만으로는 YAML `reps: true`가 1로
    # 조용히 통과한다 — bool을 명시적으로 배제.
    if isinstance(reps, bool) or not isinstance(reps, int) or reps <= 0:
        die(f"campaign 'reps' must be a positive int (got {reps!r})")
    stress = campaign["stress"]
    if not isinstance(stress, dict) or "target_total_mib" not in stress or "workers" not in stress:
        die("campaign 'stress' needs 'target_total_mib' and 'workers'")
    if not isinstance(campaign["workloads"], list) or not campaign["workloads"]:
        die("campaign 'workloads' must be a non-empty list")
    return campaign


def expand(campaign: dict, base: dict, resolves: dict):
    # 모든 run_id 앞에 붙는 캠페인 접두(namespace, hardening v2 §1). "값이 변하는 축만 토큰화"
    # 규칙(§4-C-2-4, run_name() 참조)의 유일한 예외다 — 접두는 축이 아니라 캠페인 간 격리를
    # 위한 이름공간이라, 캠페인이 값 하나여도(변하지 않아도) 항상 붙는다. 이 덕에 두 캠페인이
    # 우연히 같은 sweep/axes를 써도 run_id가 구조적으로 겹치지 않아 runs/ 덮어쓰기와 summarize
    # median 오염이 애초에 불가능해진다(summarize의 조건 가드는 2차 방어선으로만 남는다).
    prefix = campaign["campaign"]
    axes = dict(campaign.get("axes", {}))  # 복사 — campaign 원본을 훼손하지 않는다
    kdat_vals = axes.pop("kdat", ["off"])          # 내장: restore 전용
    cpu_vals = axes.pop("cpu", ["idle"])           # 내장: stress.cpu_saturate 매핑

    # YAML 1.1 은 맨 bare on/off(도 yes/no/true/false처럼)를 bool로 암묵 resolve한다
    # (config_to_env.py의 criu.kdat_cache: "off" 따옴표 주석과 동일한 함정). campaign YAML에
    # axes: {kdat: [on, off]}처럼 따옴표 없이 쓰는 게 자연스러운 표기이므로, 여기서 bool →
    # 표준 문자열로 되돌린다(kdat의 값 영역이 on/off뿐이라 매핑이 모호하지 않다).
    kdat_vals = [{True: "on", False: "off"}.get(v, v) for v in kdat_vals]

    for kd in kdat_vals:
        if kd not in KDAT_VALUES:
            die(f"unknown kdat axis value '{kd}' (allowed: {list(KDAT_VALUES)})")
    for cpu in cpu_vals:
        if cpu not in CPU_MAP:
            die(f"unknown cpu axis value '{cpu}' (allowed: {sorted(CPU_MAP)})")

    free_axes = []
    for axis_name, a in axes.items():
        if not isinstance(a, dict) or "key" not in a or "values" not in a:
            die(f"free axis '{axis_name}' needs 'key' and 'values'")
        validate_axis_key(axis_name, a["key"])
        free_axes.append((axis_name, a["key"], norm_values(a["values"])))
    free_varies = {name: len(vals) > 1 for name, _key, vals in free_axes}
    cpu_varies = len(cpu_vals) > 1
    kdat_varies = len(kdat_vals) > 1  # 기록용(§4-C-2-4 취지 — run_id 자체는 항상 kdat 표시, 위 참조)

    runs = []          # [{run_id, kind, config(dict), port, kdat}, ...]
    cell_records = []  # expansion.json의 workloads[].cells 기록
    port_idx = 0

    for wl in campaign["workloads"]:
        wl_name = wl["name"]
        manifest = cte.load_manifest(TESTBED_DIR, wl_name)  # 검증: 알 수 없는 워크로드 → die
        dump_at_list = wl.get("dump_at") or ["served_first"]
        for da_check in dump_at_list:
            if da_check not in (manifest.get("phases") or []):
                die(f"workload '{wl_name}': dump_at '{da_check}' not in manifest phases {manifest.get('phases')}")
        da_varies = len(dump_at_list) > 1

        param, display_vals, actual_vals, is_mib = sweep_values(wl, resolves)
        sweep_varies = len(display_vals) > 1

        # calibration 정합 검증(hardening v2 §2): sweep이 calibrate_from_ms를 쓰면 그 sweep.param은
        # manifest calibration.param과 반드시 같아야 한다 — run_campaign.sh PHASE1 calibration이
        # 이 param을 iters로 fit해 --resolve <wl>.<param>로 되먹이므로, 둘이 어긋나면 calibration이
        # 엉뚱한 파라미터를 채운다. 캠페인 실행보다 이른 이 전개 시점(더 이른 지점)에 die.
        sweep = wl.get("sweep") or {}
        if "calibrate_from_ms" in sweep:
            calib = manifest.get("calibration") or {}
            calib_param = calib.get("param")
            if not calib_param:
                die(f"workload '{wl_name}': sweep.calibrate_from_ms needs manifest 'calibration.param' "
                    "(workload.yaml calibration 블록 누락)")
            if param != calib_param:
                die(f"workload '{wl_name}': sweep.param '{param}' != manifest calibration.param "
                    f"'{calib_param}' — calibrate_from_ms는 calibration.param을 sweep해야 한다")

        wl_cells = []
        for v_display, v_actual in zip(display_vals, actual_vals):
            for cpu in cpu_vals:
                for combo in cross(free_axes):
                    cell, target_total_mib, resident, vm_bytes_worker = make_cell(
                        base, campaign, manifest, wl_name, param, v_actual, cpu, combo
                    )
                    wl_cells.append({
                        "sweep_value": v_display,
                        "cpu": cpu,
                        "free_axes": {name: val for name, _k, val in combo},
                        "target_total_mib": target_total_mib,
                        "resident_bytes": resident,
                        "vm_bytes_per_worker": vm_bytes_worker,
                    })
                    for rep in range(1, campaign["reps"] + 1):
                        port = PORT_BASE + port_idx
                        port_idx += 1
                        cold_rid = f"{prefix}_" + run_name(
                            wl_name, param, v_display, sweep_varies, is_mib,
                            cpu, cpu_varies, combo, free_varies, rep, kind="cold",
                        )
                        cold_cfg = copy.deepcopy(cell)
                        cold_cfg["workload"]["params"]["port"] = port
                        runs.append({"run_id": cold_rid, "kind": "cold", "config": cold_cfg,
                                     "port": port, "kdat": "-"})

                        # restore는 dump_at × kdat 조합마다 생성한다(§4-C). 이전에는 이 이중
                        # 루프가 없어서 위 검증 루프에서 누출된 변수(dump_at_list의 마지막
                        # 값)만 쓰였고, 나머지 dump_at 값이 조용히 탈락했다(리뷰 Fix 1).
                        for da in dump_at_list:
                            for kd in kdat_vals:
                                port = PORT_BASE + port_idx
                                port_idx += 1
                                rst_rid = f"{prefix}_" + run_name(
                                    wl_name, param, v_display, sweep_varies, is_mib,
                                    cpu, cpu_varies, combo, free_varies, rep, kind="restore",
                                    da=da, da_varies=da_varies, kd=kd,
                                )
                                rst_cfg = copy.deepcopy(cell)
                                rst_cfg["workload"]["params"]["port"] = port
                                rst_cfg["dump_at"] = da
                                rst_cfg.setdefault("criu", {})["kdat_cache"] = kd
                                runs.append({"run_id": rst_rid, "kind": "restore", "config": rst_cfg,
                                             "port": port, "kdat": kd})

        cell_records.append({
            "name": wl_name,
            "sweep_param": param,
            "values": display_vals,
            "values_actual": actual_vals,
            "dump_at": dump_at_list,
            "cells": wl_cells,
        })

    # 방어적 최종 검증: 런 0개(sweep/axes 표현식이 전부 접혀 아무 것도 안 생성된) 방지 —
    # from>to류 실수를 캠페인 실행 전에 잡는다.
    if not runs:
        die("0-run campaign — sweep/axes 표현식 확인")

    # 방어적 최종 검증: run_id/포트 유일성 (naming/포트 배정 로직 버그의 마지막 안전망)
    ids = [r["run_id"] for r in runs]
    if len(set(ids)) != len(ids):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        die(f"duplicate run_id generated (naming bug): {dupes}")
    # run_id 길이 상한(hardening v2 §1): 접두 + 토큰이 cgroup/dm/파일명 한계를 넘지 않게 —
    # 초과 시 실행 중간에 cgroup 생성/dm 이름에서 조용히 깨지므로 설계 시점에 거른다.
    too_long = [i for i in ids if len(i) > RUN_ID_MAX_LEN]
    if too_long:
        die(f"run_id exceeds {RUN_ID_MAX_LEN} chars (cgroup/dm/filename 안전): "
            f"{[(i, len(i)) for i in too_long]} — 캠페인명/축 토큰 길이를 줄여라")
    ports = [r["port"] for r in runs]
    if len(set(ports)) != len(ports):
        die("duplicate port assigned (port assignment bug)")
    if max(ports) > 65535:
        die(f"port assignment exceeds 65535 (last port={max(ports)}, port_base={PORT_BASE}) — "
            "reduce reps/axes/sweep size or lower campaign scope")

    meta = {
        "axes": {
            "cpu": cpu_vals,
            "kdat": kdat_vals,
            "free": {name: {"key": key, "values": vals} for name, key, vals in free_axes},
        },
        "cpu_varies": cpu_varies,
        "kdat_varies": kdat_varies,
        "free_varies": free_varies,
        "workloads": cell_records,
    }
    return runs, meta


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_resolve(items):
    """--resolve wl.param=v1,v2,... (반복 가능) → {"wl.param": [v1, v2, ...]}."""
    out = {}
    for item in items or []:
        if "=" not in item:
            die(f"bad --resolve (expected key=v1,v2,...): {item!r}")
        key, vals = item.split("=", 1)
        key = key.strip()
        parsed = []
        for tok in vals.split(","):
            tok = tok.strip()
            try:
                parsed.append(int(tok))
            except ValueError:
                try:
                    parsed.append(float(tok))
                except ValueError:
                    parsed.append(tok)
        out[key] = parsed
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("campaign_yaml", type=Path)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--resolve", action="append", default=[],
                     help="wl.param=v1,v2,... (calibrate_from_ms sweep에 필요, 반복 가능)")
    ap.add_argument("--est-run-s", type=float, default=75.0,
                     help="런 1개 예상 소요초(직전 캠페인 실측 기반) — 총 예상 시간 출력용")
    ap.add_argument("--yes", action="store_true", help="확인 프롬프트 생략(비대화 실행용)")
    args = ap.parse_args()

    if not args.campaign_yaml.is_file():
        die(f"campaign YAML not found: {args.campaign_yaml}")
    campaign = load_campaign(args.campaign_yaml)
    base = cte.load_yaml(SCENARIO_PATH)
    resolves = parse_resolve(args.resolve)

    runs, meta = expand(campaign, base, resolves)

    total = len(runs)
    est_h = total * args.est_run_s / 3600
    print(f"PLAN: {total} runs, est ~{est_h:.1f}h (--est-run-s {args.est_run_s})")
    if not args.yes:
        try:
            ans = input("proceed? [y/N] ")
        except EOFError:
            sys.exit("aborted: no stdin (non-interactive) — pass --yes (§4-C-2-3 조용히 시작 금지)")
        if ans.strip().lower() != "y":
            sys.exit("aborted")

    out_dir = args.out_dir.resolve()
    configs_dir = out_dir / "configs"
    configs_dir.mkdir(parents=True, exist_ok=True)
    # 이전 전개의 잔여 파일 제거 — 같은 out_dir 재사용 시 plan.tsv에 없는 stale config가
    # 남지 않게 한다(결정성: 이번 입력에 대응하는 파일 집합만 존재해야 함).
    for stale in configs_dir.glob("*.yaml"):
        stale.unlink()

    plan_lines = []
    run_records = []
    for r in runs:
        cfg_path = configs_dir / f"{r['run_id']}.yaml"
        cfg_path.write_text(yaml.safe_dump(r["config"], sort_keys=True, default_flow_style=False))
        plan_lines.append(f"{r['run_id']}\t{r['kind']}\t{cfg_path}\t{r['kdat']}")
        run_records.append({"run_id": r["run_id"], "kind": r["kind"], "port": r["port"],
                             "kdat": r["kdat"], "config": str(cfg_path)})

    (out_dir / "plan.tsv").write_text("\n".join(plan_lines) + "\n")
    meta_out = {
        "campaign": campaign["campaign"],
        "reps": campaign["reps"],
        "port_base": PORT_BASE,
        "total_runs": total,
        "est_run_s": args.est_run_s,
        **meta,
        "runs": run_records,
    }
    (out_dir / "expansion.json").write_text(json.dumps(meta_out, indent=2, sort_keys=True))

    print(f"WROTE: {out_dir}/plan.tsv ({total} lines), {out_dir}/configs/ ({total} files), "
          f"{out_dir}/expansion.json")


if __name__ == "__main__":
    main()
