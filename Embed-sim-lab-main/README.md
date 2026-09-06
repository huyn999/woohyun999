# criu-sim

임베디드 환경 모사 + CRIU dump/restore 자동화 파이프라인.

구현은 `testbed/` 아래에 있다. `scenario.yaml`(+ campaign YAML)에 워크로드와 제약을 적으면,
러너가 cgroup 환경을 만들고 target/CRIU/stress를 같은 constrained cgroup 안에서 실행해
"cold start"와 "CRIU restore"의 첫 응답(first-response) 시간을 비교한다.

## 읽는 순서

1. **`PLAN.md`** — 프로젝트 전체 계획 통합판: 문제·접근·현황·측정의 역사(old→new 변경점)·미래 확장
2. **`testbed/README.md`** — 디렉터리 지도, quickstart, 용어 규약(아래에도 요약)
3. **`testbed/scenario.yaml`** — 지금 돌릴 기준 설정
4. **`testbed/ROADMAP.md`** — 현재 상태와 다음 계획
5. **`docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md`** — 현 구조의 설계 근거
6. 각 디렉터리 README (`testbed/{criu,env,env/hardware,stress,workloads,runner}/README.md`)

## 용어 규약

- **`stress-*`** — **배경 부하**(`testbed/stress/`, stress-ng 기반). 측정 대상이 아니라
  target/CRIU와 같은 cgroup에서 자원을 같이 점유하는 "다른 프로세스들"의 모사.
- **`workload-*`** — **측정 대상**(`testbed/workloads/`, 계약 기반 플러그인). CRIU가 dump/restore
  하는 프로세스이고, first-response(PONG) 시간이 메인 지표다.

## 현재 파이프라인

```text
scenario.yaml (또는 campaign이 전개한 조건 YAML)
  -> env setup (cgroup v2 + hardware: memory/cpu/cpufreq/storage)
  -> L1 readback verify
  -> stress-ng 배경 부하 시작 + verify + warmup (선택)
  -> workload 기동 + PHASE ready 대기 (계약 §4-A2)
  -> [restore 경로] warm-up ping(들) -> dump_at phase 대기 -> quiesce -> criu dump
                 -> cache policy(drop_caches) -> kdat 캐시 제어(on/off) -> criu restore
  -> [cold 경로]   제약 스토리지에 워크로드 바이너리 배치 -> drop_caches -> exec
  -> first response (cold_response_s / restore_response_s)  ← 메인 지표, 단일 측정 창
  -> membership verify (L2) + resident 선언 정직성 체크
  -> teardown
```

현재 제약/축:

```text
memory: memory.max / memory.swap.max
cpu:    cpu.max bandwidth / cpuset.cpus / 고정 클럭(cpufreq)
storage: image capacity(loop-backed ext4) / bandwidth(cgroup io.max) / latency(dm-delay)
stress:  stress-ng 배경 부하 (vm occupancy + cpu_saturate on/off로 메모리/CPU 분리)
criu:    kdat_cache on/off (testbed/criu/의 /dev/shm 패치로 둘 다 가능)
workload: 계약 기반 플러그인 — simple / dirty / initburst (+ dump_at phase 축)
```

## 빠른 시작

```bash
# 사전 조건
stat -fc %T /sys/fs/cgroup      # -> "cgroup2fs" 나와야 함
stress-ng --version              # stress 축을 켤 때만 필요

# 빌드 (둘 다 멱등)
testbed/criu/build.sh             # CRIU v4.2 + kdat-shm 패치 (최초 1회)
testbed/workloads/build.sh        # 워크로드 바이너리

# 단발 실행 (root 필요 — cgroup mutate)
sudo testbed/runner/run_cold_start.sh --run-id demo_cold    --config testbed/scenario.yaml
sudo testbed/runner/run_once.sh       --run-id demo_restore --config testbed/scenario.yaml
```

기대 결과: 각 런의 `testbed/runs/<run-id>/result.env`에 `result=PASS`.

## 시나리오 수정

`testbed/scenario.yaml`을 수정하면 다음 실행부터 바로 반영된다. 예:

```yaml
workload: {name: dirty, params: {bytes: 52428800, dirty_bytes: 1048576, port: 18080}}
dump_at: served_first        # ready 이후 첫 핑퐁 처리 직후 (old의 "워밍업 1회 후 dump"와 동치)
warmup_pings: 1
checkpoint_after_s: 1.0

memory: {max: 1708M, swap_max: 0}
cpu:    {bandwidth_cores: 4.0, cpuset_cpus: "0-3", frequency_khz: 1235000}

storage:
  image:
    enabled: true
    capacity: 1G
    rbps: 150M
    wbps: 50M
    delay: {enabled: true, read_ms: 1, write_ms: 3}

stress:
  enabled: true
  vm_workers: 29
  vm_bytes: 44M          # 인스턴스 1개의 총 메모리(오버헤드 포함, >= 38M 하한)
  cpu_saturate: true     # true=cgroup 코어 saturate(busy) / false=메모리만 점유, CPU idle
  warmup_s: 2.0

criu: {kdat_cache: "off"}   # off: restore마다 kerndat 재probe / on: 캐시 재사용(/dev/shm)
```

새 워크로드를 추가하려면 `testbed/workloads/README.md`(계약 §4)를 따른다 — 디렉터리 1개
(`workload.c` + `workload.yaml`)만 추가하면 되고, runner 코드는 건드릴 필요가 없다.

값 단위(예: `44M`, `1G`)와 필드 전체 목록은 `testbed/runner/config_to_env.py`(스키마 진실 —
미지 키/타입 불일치는 exit 2로 거부)와 각 `env/hardware/*.sh`의 헤더 주석을 참고한다.

## Cold Start ↔ CRIU Restore 비교

두 경로는 서로 다른 런으로 측정한다.

```bash
sudo testbed/runner/run_cold_start.sh --run-id cold_demo    --config testbed/scenario.yaml
sudo testbed/runner/run_once.sh       --run-id restore_demo --config testbed/scenario.yaml
```

**메인 지표는 "첫 요청 응답"이다.** 워크로드는 계약(§4-A6)에 따라 `ready` 이후 핑퐁 서버를
열고 `PHASE ready port=<P> ...`를 발행한다. 러너는 그 포트로 `cprobe`(static 빌드 C 클라이언트,
`runner/cprobe.c`)를 5ms 간격으로 재시도해 첫 성공 응답 시각을 잰다 — 이 창이 cold/restore
양쪽의 유일한 측정 경로다(`runner/lib/probe.sh`, 스펙 §6-1~6).

```text
cold_response_s     execve 명령 -> 서비스의 첫 성공 응답. init(메모리 touch 또는 CPU 연산)을
                    다시 치른 뒤 응답한다.
restore_response_s  criu restore 명령 -> 복원된 서비스의 첫 성공 응답. dump 당시
                    service-ready(warm) 상태에서 resume되므로 init을 건너뛴다.
```

`restore_response_s`는 `restore_time_s`(criu 완료까지) = `kdat_probing_s`(kerndat probe —
kdat on/off 비교의 핵심 축) + `restore_work_s`(page-in+resume) + `launch_overhead_s`로
분해된다(`-v4` 로그 파싱, 측정 창 밖). kdat probing 절대값은 런 간 최대 3배까지 출렁이므로
**paired delta로만 비교**한다. 필드 전체 목록·의미는 `testbed/runner/README.md` 참고.

## 배치 실험 (campaign)

```bash
sudo testbed/runner/run_campaign.sh <campaign.yaml>
SMOKE=1 sudo testbed/runner/run_campaign.sh <campaign.yaml>   # 대표 1셀 + reps=1
```

`run_campaign.sh`가 calibration(필요한 워크로드만) → `expand_campaign.py`(campaign YAML을
`plan.tsv` + 조건별 YAML로 전개, 조합 폭발 가드) → 실행 → `collect.py`/`summarize.py` finalize
까지 전부 처리한다. 산출물은 `testbed/experiments/<campaign-name>/`. 상세는
`testbed/runner/README.md`.

## 디렉토리 한눈에

| 위치 | 역할 |
|---|---|
| `testbed/scenario.yaml` | 기준 설정 |
| `testbed/criu/` | CRIU 4.2 vendoring (kdat-shm.patch + build.sh) |
| `testbed/env/hardware/` | cgroup 기반 물리 제약 (memory/cpu/cpufreq/storage) |
| `testbed/env/policy/` | OS 정책 — 미구현 seam |
| `testbed/stress/` | 배경 부하 (`stress-*`, stress-ng) |
| `testbed/workloads/` | 측정 대상 (`workload-*`, 계약 기반 플러그인: simple/dirty/initburst) |
| `testbed/runner/` | 러너(run_once/run_cold_start) + 캠페인 드라이버 + lib/ + collect/summarize |
| `testbed/experiments/` | 캠페인 산출물 (all_runs.csv/summary_by_condition.csv/…, git 추적) |
| `testbed/runs/` | per-run 산출물 (result.env 등, `.gitignore`) |
| `testbed_old/` | 재작성 이전 코드 — 동결·참조 전용 |

## 다음 단계

현재 상태와 남은 미구현 항목(env/policy, CRIU dump 옵션 sweep, LHS 샘플링 등)은
`testbed/ROADMAP.md`와 `PLAN.md` §1(현황)·§5(미래 확장) 참고. A/B 패리티 검증은
2026-07-04 완료 (`docs/superpowers/reviews/2026-07-parity-verdict.md`).
