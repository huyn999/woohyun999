#!/usr/bin/env python3
"""
runner/config_to_env.py — 조건 YAML(+workload manifest 병합)을 flattened env로 낮춘다.

YAML은 사람이 축별로 읽고 쓰기 좋게 유지하고, shell runner는 검증된 flat 변수만
받는다 (CFG_*/WL_*, 스펙 §5-6 — positional 인자 누적 금지). YAML 파싱은 이 파일만
한다 — bash로 새는 설계 금지.

이식원: testbed_old/runner/config_to_env.py (YAML 로더 + shell-quote 그대로 재사용).
확장: workload manifest(workloads/<name>/workload.yaml) 병합 + 4종 설계 시점 검증
(name==dir, params ⊆ manifest params, dump_at ∈ phases, resident 필드 정합) — 실패 시
`die()`로 stderr + exit 1. 기존 환경/정책 섹션(memory/cpu/stress/storage/criu)의
구조적 스키마 오류(미지 키·타입 불일치)는 old와 동일하게 `fail()`로 stderr + exit 2.
"""

import re
import shlex
import sys
from pathlib import Path

import yaml

# 새 스키마: old의 "run"/"workload"(target_bytes/dynamic_*/compute_iters) 섹션은
# top-level 러너 노브(dump_at/warmup_pings/checkpoint_after_s/cache_policy) +
# workload manifest 병합(WL_*)으로 대체됐다. memory/cpu/stress/storage/criu는 old 그대로.
ALLOWED_TOP_LEVEL = {
    "workload",
    "dump_at",
    "warmup_pings",
    "checkpoint_after_s",
    "cache_policy",
    "memory",
    "cpu",
    "stress",
    "storage",
    "criu",
    "policy",
}
ALLOWED_KEYS = {
    "workload": {"name", "params"},
    "memory": {"max", "swap_max"},
    "cpu": {"bandwidth_cores", "cpuset_cpus", "frequency_khz"},
    "stress": {"enabled", "vm_workers", "vm_bytes", "warmup_s", "extra", "cpu_saturate", "floor_mib"},
    "storage": {"image"},
    "storage.image": {"enabled", "capacity", "rbps", "wbps", "delay"},
    "storage.image.delay": {"enabled", "read_ms", "write_ms"},
    "criu": {"kdat_cache", "fault", "kdat_file"},
}


def fail(message: str) -> None:
    """구조적 스키마 에러 (미지 top-level/키, 타입 불일치) — old와 동일 exit 2."""
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(2)


def die(message: str) -> None:
    """workload manifest 병합·검증 4종 실패 — 설계 시점 에러, exit 1."""
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_yaml(path) -> dict:
    path = Path(path)
    try:
        raw = yaml.safe_load(path.read_text()) or {}
    except FileNotFoundError:
        fail(f"file not found: {path}")
    except yaml.YAMLError as exc:
        fail(f"invalid YAML: {exc}")
    if not isinstance(raw, dict):
        fail(f"top-level YAML value must be a mapping: {path}")
    return raw


def section(config: dict, name: str) -> dict:
    value = config.get(name, {})
    if value is None:
        return {}
    if not isinstance(value, dict):
        fail(f"'{name}' must be a mapping")
    allowed = ALLOWED_KEYS.get(name)
    if allowed is not None:
        unknown = set(value) - allowed
        if unknown:
            fail(f"unknown key(s) in '{name}': {', '.join(sorted(unknown))}")
    return value


def nested_section(config: dict, parent: str, name: str) -> dict:
    value = config.get(name, {})
    full_name = f"{parent}.{name}"
    if value is None:
        return {}
    if not isinstance(value, dict):
        fail(f"'{full_name}' must be a mapping")
    allowed = ALLOWED_KEYS.get(full_name)
    if allowed is not None:
        unknown = set(value) - allowed
        if unknown:
            fail(f"unknown key(s) in '{full_name}': {', '.join(sorted(unknown))}")
    return value


def top_scalar(config: dict, key: str, default):
    """top-level 러너 노브 하나 (dump_at 등) — 미지정 시 기본값, list/dict는 스키마 에러."""
    value = config.get(key, default)
    if isinstance(value, (list, dict)):
        fail(f"'{key}' must be a scalar")
    return value


def scalar(value, name: str) -> str:
    if isinstance(value, (list, dict)):
        fail(f"'{name}' must be a scalar")
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def emit(name: str, value) -> None:
    if value is None:
        return
    print(f"{name}={shlex.quote(scalar(value, name))}")


def load_manifest(testbed_dir, wl_name):
    path = Path(testbed_dir) / "workloads" / wl_name / "workload.yaml"
    m = load_yaml(path)
    if m.get("name") != wl_name:
        die(f"manifest name '{m.get('name')}' != dir '{wl_name}'")
    return m


def resident_bytes(m, params):
    r = m.get("resident")
    if not isinstance(r, dict):
        die(f"manifest '{m.get('name')}': missing 'resident' section")
    if "mib" in r:
        base = int(r["mib"]) * 1048576
    elif "from_param" in r:
        from_param = r["from_param"]
        if from_param not in params:
            die(f"manifest '{m.get('name')}': resident.from_param '{from_param}' not in params")
        base = int(params[from_param]) * int(r.get("bytes_per_unit", 1))
    else:
        die(f"manifest '{m.get('name')}': resident needs 'mib' or 'from_param'")
    return base + int(r.get("overhead_mib", 0)) * 1048576


def render_flags(m, params):
    # manifest 선언 순 아닌 키 정렬 순 — 렌더링 결정성 (WL_FLAGS 재현성).
    merged = {k: v.get("default") for k, v in m["params"].items()}
    for k, v in params.items():
        if k not in merged:
            die(f"param '{k}' not in manifest '{m.get('name')}' params")
        merged[k] = v

    # 가드: unquoted 확장 안전 문자만 허용
    safe_pattern = re.compile(r'^[A-Za-z0-9._-]+$')
    normalized = {}
    for k, v in merged.items():
        # 불린 정규화
        norm_val = scalar(v, k)
        if not safe_pattern.match(norm_val):
            die(f"param '{k}' value '{v}' contains unsafe characters for flag expansion ([A-Za-z0-9._-] only)")
        normalized[k] = norm_val

    return " ".join(f"--{k} {normalized[k]}" for k in sorted(normalized)), normalized


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: config_to_env.py <config.yaml>")

    raw = load_yaml(sys.argv[1])

    unknown_top = set(raw) - ALLOWED_TOP_LEVEL
    if unknown_top:
        fail(f"unknown top-level section(s): {', '.join(sorted(unknown_top))}")

    memory = section(raw, "memory")
    cpu = section(raw, "cpu")
    stress = section(raw, "stress")
    storage = section(raw, "storage")
    storage_image = nested_section(storage, "storage", "image")
    storage_image_delay = nested_section(storage_image, "storage.image", "delay")
    criu = section(raw, "criu")
    section(raw, "policy")  # 미래 seam (env/policy) — 검증만, 소비 없음

    # --- 신규 runner 노브 (top-level scalar, python 쪽 기본값 보장) ---
    dump_at = top_scalar(raw, "dump_at", "served_first")
    warmup_pings = top_scalar(raw, "warmup_pings", 1)
    # 타입 검증: warmup_pings/checkpoint_after_s가 비정수·비숫자면 러너 bash 산술
    # (for ((ping=1; ping<=n; ping++)) / sleep "$CFG_CHECKPOINT_AFTER_S")에서 unbound 크래시로
    # 늦게 터진다 — 설계 시점(config_to_env) 에러로 승격.
    if isinstance(warmup_pings, bool) or not isinstance(warmup_pings, int) or warmup_pings < 0:
        fail(f"'warmup_pings' must be an int >= 0 (got: {warmup_pings!r})")
    # F7: served_first phase는 워밍 핑이 촉발한다(워크로드는 ready 이후 첫 PING/PONG을 처리한
    # 직후에만 PHASE served_first를 발행한다). warmup_pings==0이면 아무 핑도 안 가서 served_first에
    # 영영 도달하지 못하고, 러너가 dump_at phase를 DUMP_AT_TIMEOUT_S(기본 60s) 기다리다 timeout으로
    # "dump_at phase not reached" 오사유 FAIL로 늦게 종료한다. 설계 시점에 거부한다(die, exit 1).
    if dump_at == "served_first" and warmup_pings == 0:
        die("dump_at=served_first requires warmup_pings>=1 — served_first는 워밍 핑이 촉발한다; "
            "핑 없이 dump하려면 dump_at을 ready(또는 pre-ready phase)로")
    checkpoint_after_s = top_scalar(raw, "checkpoint_after_s", 1.0)  # old scenario.yaml 기본
    if isinstance(checkpoint_after_s, bool) or not isinstance(checkpoint_after_s, (int, float)) \
            or checkpoint_after_s < 0:
        fail(f"'checkpoint_after_s' must be a number >= 0 (got: {checkpoint_after_s!r})")
    cache_policy = top_scalar(raw, "cache_policy", "best_effort_cold_cache")  # old run_once.sh 기본
    kdat_cache = criu.get("kdat_cache", "off")

    # --- workload manifest 병합 ---
    workload_cfg = section(raw, "workload")
    wl_name = workload_cfg.get("name")
    if not wl_name:
        fail("'workload.name' is required")
    wl_params = workload_cfg.get("params") or {}
    if not isinstance(wl_params, dict):
        fail("'workload.params' must be a mapping")

    testbed_dir = Path(__file__).resolve().parent.parent
    manifest = load_manifest(testbed_dir, wl_name)            # 검증 ①
    wl_flags, merged_params = render_flags(manifest, wl_params)  # 검증 ②
    phases = manifest.get("phases") or []
    metrics = manifest.get("metrics") or []
    # 계약 §4-A2 문자집합(phase/metric 이름은 [a-z0-9_]만) — bash 쪽(wl_wait_phase grep,
    # result.env의 wl_<metric> 키)이 그대로 셸/파일 키로 쓰므로 여기서 강제한다.
    name_pattern = re.compile(r'^[a-z0-9_]+$')
    for ph in phases:
        if not name_pattern.match(str(ph)):
            die(f"manifest '{wl_name}': phase name '{ph}' must match ^[a-z0-9_]+$ (§4-A2)")
    for met in metrics:
        if not name_pattern.match(str(met)):
            die(f"manifest '{wl_name}': metric name '{met}' must match ^[a-z0-9_]+$ (§4-A2)")
    # param 이름도 같은 문자집합(§4-A2)으로 강제한다 — 이 이름이 그대로 WL_PARAM_KEYS의 토큰,
    # WL_PARAM_<대문자> 셸 변수, result.env의 wl_param_<name> 키가 되므로(hardening v2 §3)
    # phase/metric과 나란히 검증한다(안전하지 않은 문자는 셸 변수명/키를 깨뜨린다).
    for pname in manifest.get("params") or {}:
        if not name_pattern.match(str(pname)):
            die(f"manifest '{wl_name}': param name '{pname}' must match ^[a-z0-9_]+$ (§4-A2)")
    if dump_at not in phases:
        die(f"dump_at '{dump_at}' not in manifest '{wl_name}' phases {phases}")  # 검증 ③
    resident = resident_bytes(manifest, merged_params)         # 검증 ④

    # --- 출력: CFG_* (환경/정책 + runner 노브) ---
    emit("CFG_MEMORY_MAX", memory.get("max"))
    emit("CFG_MEMORY_SWAP_MAX", memory.get("swap_max"))
    emit("CFG_CPU_BANDWIDTH_CORES", cpu.get("bandwidth_cores"))
    emit("CFG_CPUSET_CPUS", cpu.get("cpuset_cpus"))
    emit("CFG_CPU_FREQ_KHZ", cpu.get("frequency_khz"))
    emit("CFG_STRESS_ENABLED", stress.get("enabled"))
    emit("CFG_STRESS_VM_WORKERS", stress.get("vm_workers"))
    emit("CFG_STRESS_VM_BYTES", stress.get("vm_bytes"))
    emit("CFG_STRESS_WARMUP_S", stress.get("warmup_s"))
    emit("CFG_STRESS_EXTRA", stress.get("extra"))
    emit("CFG_STRESS_CPU_SATURATE", stress.get("cpu_saturate"))
    # stress-ng 인스턴스 floor(MiB) — 플랫폼 의존 실측값(measure_floor.sh). 러너가
    # stress/start.sh의 STRESS_FLOOR_MIB로 전달한다(미지정 시 셸 쪽 기본 38 = x86 실측).
    floor_mib = stress.get("floor_mib")
    if floor_mib is not None and (isinstance(floor_mib, bool)
                                  or not isinstance(floor_mib, int) or floor_mib < 1):
        fail(f"'stress.floor_mib' must be an int >= 1 (got: {floor_mib!r})")
    emit("CFG_STRESS_FLOOR_MIB", floor_mib)
    emit("CFG_STORAGE_IMAGE_ENABLED", storage_image.get("enabled"))
    emit("CFG_STORAGE_IMAGE_CAPACITY", storage_image.get("capacity"))
    emit("CFG_STORAGE_IMAGE_RBPS", storage_image.get("rbps"))
    emit("CFG_STORAGE_IMAGE_WBPS", storage_image.get("wbps"))
    emit("CFG_STORAGE_IMAGE_DELAY_ENABLED", storage_image_delay.get("enabled"))
    emit("CFG_STORAGE_IMAGE_DELAY_READ_MS", storage_image_delay.get("read_ms"))
    emit("CFG_STORAGE_IMAGE_DELAY_WRITE_MS", storage_image_delay.get("write_ms"))
    emit("CFG_KDAT_CACHE", kdat_cache)
    # CRIU fault-injection 스위치(기기 속성) — 예: 135 = FI_DONT_USE_PAGEMAP_SCAN.
    # arm64 커널 6.7+의 PAGEMAP_SCAN ioctl이 compat(32-bit CRIU)에서 EFAULT라(RPi 실증)
    # 고전 pagemap 경로로 우회할 때 쓴다. run_once가 CRIU_FAULT env로 criu 자식에 전달.
    criu_fault = criu.get("fault")
    if criu_fault is not None and (isinstance(criu_fault, bool)
                                   or not isinstance(criu_fault, int) or criu_fault < 1):
        fail(f"'criu.fault' must be an int >= 1 (got: {criu_fault!r})")
    emit("CFG_CRIU_FAULT", criu_fault)
    # kdat 캐시 파일 경로(기기 속성). 기본은 kdat-shm 패치 빌드의 /dev/shm/criu.kdat(러너 쪽
    # 기본값) — 그 패치는 Docker/overlayfs-/run 환경의 땜빵이라, /run이 정상 tmpfs인 실호스트
    # (RPi·TV)에서 stock CRIU를 쓸 땐 여기에 /run/criu.kdat을 지정하면 패치 없이 kdat on 축이
    # 동작한다(러너의 kdat init/control·tmpfs 검사·doctor가 이 경로를 따른다).
    kdat_file = criu.get("kdat_file")
    if kdat_file is not None:
        if not isinstance(kdat_file, str) or not re.match(r'^/[A-Za-z0-9._/-]+$', kdat_file):
            fail(f"'criu.kdat_file' must be an absolute path ([A-Za-z0-9._/-]) (got: {kdat_file!r})")
    emit("CFG_KDAT_FILE", kdat_file)
    emit("CFG_DUMP_AT", dump_at)
    emit("CFG_WARMUP_PINGS", warmup_pings)
    emit("CFG_CHECKPOINT_AFTER_S", checkpoint_after_s)
    emit("CFG_CACHE_POLICY", cache_policy)

    # 검증 ⑤: port는 항상 명시(≥1) — 러너의 probe/warm-up이 WL_PORT로 접속하므로
    # kernel-assigned(0)는 config 경로에서는 측정 불가능하다 (P1 프로브 실증: 워크로드는
    # 임의 포트에 멀쩡히 뜨는데 러너가 포트 0을 폴링하다 "no response"로 늦게 오사유 FAIL).
    # 커널 배정은 바이너리 직접 실행(bin/<wl> --port 0)에서만 의미가 있다.
    try:
        port_val = int(merged_params.get("port", 0))
    except (TypeError, ValueError):
        die(f"workload port must be an integer >= 1 (got: {merged_params.get('port')!r})")
    if port_val < 1:
        die("workload port must be explicit (>= 1) — kernel-assigned(0) is unmeasurable "
            "via the runner (probe/warm-up connect to WL_PORT); use bin/<wl> --port 0 directly instead")
    if port_val > 65535:
        die(f"workload port must be <= 65535 (got: {port_val})")

    # --- 출력: WL_* (workload manifest 병합 결과) ---
    emit("WL_NAME", wl_name)
    emit("WL_BIN", str(testbed_dir / "workloads" / "bin" / wl_name))
    emit("WL_FLAGS", wl_flags)
    emit("WL_PORT", port_val)
    emit("WL_RESIDENT_BYTES", resident)
    emit("WL_PHASES", " ".join(phases))
    emit("WL_METRICS", " ".join(metrics))

    # --- 출력: WL_PARAM_* (병합된 workload 파라미터 값, hardening v2 §3) ---
    # merged_params는 render_flags가 돌려준 정규화 dict(전 파라미터 = manifest default + override).
    # 정렬 순서를 고정(sorted)해 WL_PARAM_KEYS/WL_FLAGS와 동일 순서를 보장한다 — 재현성.
    # 각 값을 WL_PARAM_<대문자>로 방출하고, 키 목록을 공백 구분 WL_PARAM_KEYS로 방출한다(result.sh가
    # 이 목록을 순회해 wl_param_<name>=값을 남긴다). port도 포함되지만(캠페인이 런마다 배정),
    # 다운스트림 가드/페어링(summarize·compare_cold_restore)은 wl_param_port를 제외한다.
    param_keys = sorted(merged_params)
    emit("WL_PARAM_KEYS", " ".join(param_keys))
    for pname in param_keys:
        emit(f"WL_PARAM_{pname.upper()}", merged_params[pname])


if __name__ == "__main__":
    main()
