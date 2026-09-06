# testbed 전면 재작성 설계 (2026-07-03)

> 상태: **확정** (2026-07-03 최종 검토 완료) — 구현은 별도 implementation plan을 따른다.

## 0. 왜 다시 짜는가

현 testbed는 720런(wsk_redesign)을 무사히 완주했지만, 코드 상태가 다음 문제를 안고 있다:

1. **파일 비대**: `runner/run_once.sh` 951줄, `runner/run_cold_start.sh` 540줄.
2. **러너 간 복붙 중복**: `load_config`/`parse_args`/`join_current_process_to_cgroup`(동일)/
   `maybe_stress_warmup`(동일)/`write_result_env`(스키마 공유)/`cleanup`(거의 동일)이 양쪽에 사본으로 존재.
   특히 **cprobe 측정 창 로직이 양쪽에 복붙**돼 있어, 한쪽만 수정하면 cold/restore 측정이
   다시 비대칭이 되는 구조적 위험이 있다 (2026-07 초에 실제로 이 비대칭 때문에 꼬리 아티팩트 발생).
3. **CRIU 엔진이 repo 밖**: kdat tmpfs 패치가 `/root/criu-webOS`(별개 repo)에 **커밋도 안 된
   dirty 상태**로만 존재. `git checkout` 한 번이면 kdat ON 실험 기반이 소실된다.
   (2026-07-03 패치 파일로 구출 완료 → 본 재작성에서 정식 편입)
4. **워크로드 확장 불가**: 워크로드 지식이 runner(launch 분기)·campaign(sweep 하드코딩)·
   C 코드(각자 소켓 구현) 세 곳에 흩어져, 워크로드 하나 추가에 세 군데를 고쳐야 한다.
   앞으로 다양한 워크로드 × **다양한 dump 타이밍**을 실험할 계획이므로,
   "디렉터리 하나 추가 + campaign YAML 한 항목"으로 편입되는 플러그인 구조가 필요하다.

재작성의 목표: **① 중복 제거(측정 공정성의 single-source화), ② 파일 기능별 분할,
③ CRIU 엔진의 repo 내 재현 가능화, ④ 워크로드 플러그인화(계약 기반).**
**현재 모사하는 것들은 전부 유지한다** (§3 인벤토리).

## 1. 확정된 결정 ✅

| 결정 | 내용 |
|---|---|
| CRIU 버전 | **4.2 pin** (720런과 동일 엔진, 비교성 유지). upstream `checkpoint-restore/criu` tag `v4.2` clone → kdat patch → build |
| kdat 패치 | `criu/kerndat.c`의 `KERNDAT_CACHE_FILE`을 `/dev/shm/criu.kdat`로 (이 샌드박스의 `/run`은 overlayfs라 CRIU가 캐시 보존 거부; `/dev/shm`은 tmpfs). 구출본을 `testbed/criu/kdat-shm.patch`로 편입 |
| old/new 배치 | **코드 디렉터리만** `testbed_old/`로 이동 (`env/ runner/ stress/ workloads/ configs/ scenario.yaml`). `testbed/experiments/` 데이터는 제자리 → `reports/make_wsk_figures.py` 경로 안 깨짐. old는 동결된 참조 스펙(필요시 실행 가능) |
| 언어 스택 | 유지: bash(측정·오케스트레이션) + C(workload/probe) + python(설정 변환·수집·요약). 측정 경로 재작성에 새 언어 도입 금지 |
| configs/ | **유지**. 손으로 쓰는 기준 설정 + campaign 스펙 YAML을 여기에 둔다 (조건별 생성 YAML은 runs/ 산출물 쪽) |
| 워크로드 구조 | **디렉터리 + manifest 플러그인** (§4 계약). 워크로드 추가 = `workloads/<name>/` 디렉터리 1개 + campaign YAML 1항목, runner/campaign 코드 수정 0줄 |
| dump 타이밍 | **phase 기반** (`dump_at: <phase>`). 시간 기반 트리거 금지 — stress-CPU 아래서 같은 시각 ≠ 같은 상태 (initburst nominal 700ms → busy 실측 938ms 교훈) |
| 핑퐁 | **전 워크로드 필수** (§4-A6). "다시 살아났다"의 최저가 end-to-end 증명이자 first-response 측정 통로. fd 모양도 전 워크로드 균일화(stdio+listen)되어 비교 공정성 ↑ |

## 2. 새 디렉터리 구조 (제안)

기존 최상위 구조는 검증됐으므로 유지. 변화는 `criu/` 신설, `runner/lib/` 신설,
`workloads/` 플러그인화.

```
testbed/
├── README.md                  # 전체 지도: 구조, quickstart, 용어(stress-* / workload-*)
├── scenario.yaml              # 기준(base) 설정 — 모든 조건 YAML의 출발점
├── configs/                   # 손으로 쓴 기준 설정 + campaign 스펙 YAML
│   └── campaign_<이름>.yaml    #   실험 설계: 워크로드 선택·sweep grid·dump_at·축·reps
├── criu/                      # ★신설: 엔진 vendoring
│   ├── README.md              #   왜 패치가 필요한가(/run overlayfs), 빌드법, 버전 pin 근거
│   ├── kdat-shm.patch         #   /dev/shm kdat 캐시 패치 (구출본)
│   ├── build.sh               #   clone v4.2 → patch 적용 → make → bin/criu 설치 (멱등)
│   └── bin/criu               #   빌드 산출물 (.gitignore, 존재 검증은 러너가)
├── env/
│   ├── README.md
│   ├── setup.sh               # 오케스트레이터 (현행 verb 패턴 유지: <module>.sh apply <run_id> …)
│   ├── verify.sh              # L1 readback 검증
│   ├── teardown.sh
│   ├── hardware/
│   │   ├── README.md
│   │   ├── cgroup.sh          # cgroup v2 생성/삭제
│   │   ├── memory.sh          # memory.max / swap.max
│   │   ├── cpu.sh             # cpu.max bandwidth + cpuset
│   │   ├── cpufreq.sh         # 고정 클럭 (cpuset 필수, teardown 원복 보장)
│   │   └── storage.sh         # loop ext4 + dm-delay
│   └── policy/                # ★seam만: 이번 범위 밖 (§11) — swap/zram/swappiness 미래 자리
│       └── README.md          #   설계 스케치 + verb 패턴 규약만, 구현 없음
├── stress/
│   ├── README.md
│   ├── start.sh               # stress-ng 기동 + oom-protect loop-until-stable
│   ├── verify.sh              # 워커 수/점유 검증
│   └── stop.sh
├── workloads/                 # ★플러그인화: 디렉터리 = 워크로드
│   ├── README.md              #   계약 명세(§4) 전문 — 새 워크로드 작성자의 유일한 필독 문서
│   ├── build.sh               #   전 워크로드 발견·빌드 (멱등): */workload.c → bin/<name>
│   ├── common/
│   │   └── probe_server.h     #   공용 핑퐁 서버 헬퍼 (~60줄 C; 전 워크로드가 사용 — 계약은 행동 규약이므로 직접 구현도 허용)
│   ├── bin/                   #   빌드 산출물 (.gitignore)
│   ├── simple/
│   │   ├── workload.c         #   재작성 때 소켓 획득 (§4-A6 필수화)
│   │   └── workload.yaml
│   ├── dirty/                 #   구 target_memory
│   │   ├── workload.c
│   │   └── workload.yaml      #   resident: {from_param: bytes}
│   └── initburst/             #   구 target_compute
│       ├── workload.c
│       └── workload.yaml      #   calibration: {param: iters, metric: compute_ms}
└── runner/
    ├── README.md
    ├── lib/                   # ★신설: 두 러너가 공유하는 것"만" (2+ 호출자 규칙, §5)
    │   ├── config.sh          #   공통 인자 파싱 + config_to_env 소싱 + 파생 변수
    │   ├── cgroup.sh          #   join_current_process_to_cgroup 등 cgroup 헬퍼
    │   ├── stress.sh          #   stress start/verify/warmup/stop 러너측 래퍼
    │   ├── workload.sh        #   인자 전개·기동·PHASE 대기/파싱 (워크로드-무지의 핵심; YAML은 안 읽음)
    │   ├── probe.sh           #   ★first-response 측정 창 (공정성의 single source, §6-1~5)
    │   ├── snapshot.sh        #   mem_snapshot 시점 래퍼 (SNAP 태그)
    │   ├── result.sh          #   result.env 공통 스키마 + mem_timeline 병합
    │   └── cleanup.sh         #   공통 trap/정리
    ├── cprobe.c               # static C probe 클라이언트
    ├── run_once.sh            # restore 경로 오케스트레이터 (단계는 in-file 함수, §5)
    ├── run_cold_start.sh      # cold 경로 오케스트레이터
    ├── run_campaign.sh        # 캠페인 드라이버: campaign YAML 해석 (구 run_campaign_redesign.sh 일반화)
    ├── config_to_env.py       # YAML → shell-quoted env (workload manifest 병합 포함 — YAML 파싱은 python만)
    ├── collect.py             # runs/ → all_runs.csv (manifest metrics 열 승격 포함)
    ├── summarize.py           # 조건별 중앙값 + bootstrap CI (그룹 키에 dump_phase 포함)
    ├── mem_snapshot.sh        # memory.stat/meminfo 스냅샷
    └── fadvise_dontneed.py    # cache_policy fadvise 변형
```

`testbed/experiments/` (데이터)와 `testbed/runs/` (런 산출물)는 지금 위치·스키마 그대로.

## 3. 모사 인벤토리 — 전부 유지 + 신규 축

새 코드가 빠짐없이 커버해야 하는 "지금 모사하는 것들":

| 모사 대상 | 구현 | 새 코드 위치 |
|---|---|---|
| TV급 메모리 제약 | cgroup v2 `memory.max`/`swap.max` | env/hardware/memory.sh |
| CPU 제약 | cpuset 핀 + `cpu.max` bandwidth | env/hardware/cpu.sh |
| 고정 클럭 | cpufreq governor/frequency 고정 | env/hardware/cpufreq.sh |
| 느린 스토리지 | loop ext4 + dm-delay (CRIU 이미지·타깃 바이너리 여기 배치) | env/hardware/storage.sh |
| 배경 부하 | stress-ng: memory 상시 + CPU saturate 토글, Option B 총량 흡수 | stress/ + campaign |
| 앱 워크로드 | simple / dirty(30–70MiB) / initburst(calibrated iters) — 계약 기반 확장 가능 | workloads/<name>/ |
| CRIU C/R | dump → (cache policy) → restore, 같은 cgroup | runner/run_once.sh |
| kdat 캐시 | /dev/shm/criu.kdat 존재 제어 (on: 1회 워밍 후 보존, off: dump 후·restore 직전 삭제) | runner + criu/ 패치 |
| cold page cache | dump 후 `sync + drop_caches=3` | runner (cache_policy) |
| cold start 기준선 | 제약 스토리지에서 바이너리 exec | runner/run_cold_start.sh |
| 첫 응답 측정 | cprobe PING→PONG, 5ms 폴링 | runner/lib/probe.sh |
| restore 분해 | kdat_probing + restore_work + launch_overhead (‑v4 로그, 창 밖 파싱) | runner/run_once.sh |
| 검증 사다리 | L1 readback → canary preflight → L2 membership → 기능 회생(PONG) | env/verify.sh + runner |
| 수집·요약 | result.env → all_runs.csv → 조건별 median + bootstrap 95% CI | collect.py / summarize.py |
| **★신규: dump 타이밍 축** | `dump_at: <phase>` — 워크로드 생애주기의 의미 지점에서 dump. "앱 생애 어느 지점의 checkpoint가 restore가 싼가"를 정식 실험축으로 (기존 "워밍업 1회 후 dump"는 이 축의 한 점이었음) | 계약 §4-A2 + runner |

버릴 것 (old에는 남음):

| 파일 | 이유 |
|---|---|
| `runner/request_probe.py` | cprobe로 완전 대체됨 (python 스폰 51ms 꼬리의 원흉) |
| `runner/audit_profile.sh` | 호출자 0 (수동 진단용이었음) — 부활 필요하면 old에서 가져옴 |
| `runner/run_campaign_redesign.sh`의 "redesign" 이름 | `run_campaign.sh`로 일반화 (내용은 계승) |
| generic recovery의 이원화 검증 | 핑퐁 필수화(§4-A6)로 기능 회생 증명이 전 워크로드 단일 경로화 |

## 4. 워크로드 계약 v2 ★신설

"코드만 추가하면 알아서 측정"의 근간. runner가 워크로드에 대해 아는 것은 이 계약이 전부다.
계약은 **행동 규약**(언어 불문) — 지금은 C 단일 바이너리, 계약만 지키면 무엇이든 편입 가능.

### A. 필수 조항 (모든 워크로드)

- **A1. 기동 인터페이스**: manifest에 선언된 파라미터를 **named flag**로 받는다
  (`--bytes 52428800 --port 0`). runner는 config의 params dict를 `--키 값`으로 기계적으로
  전개할 뿐, 의미를 모른다. (현행 positional 인자는 runner가 순서를 알아야 해서 폐기.)
- **A2. 생애주기 발표**: 상태 전이마다 stdout에 `PHASE <이름> [키=값 ...]` 한 줄.
  - `PHASE ready`는 필수 (현행 `WORKLOAD_READY`의 일반화). port·메트릭 등 메타데이터를
    키=값으로 동승 (`PHASE ready port=34121 compute_ms=812`).
  - 그 외 phase는 자유 — dump해볼 만한 지점마다 발행 (`loading`, `served_first`,
    `compute_50`…). 이름은 `[a-z0-9_]`만, `ready`는 예약어. config의 `dump_at`이
    manifest의 phases에 없으면 **설계 시점 에러**.
  - **at-or-after 의미론**: dump는 "phase 도달 직후"에 일어난다 — 관측 지연(로그 폴링
    수 ms)과 freeze 사이에도 워크로드는 계속 진행한다. ready/steady 같은 안정 상태
    phase는 무해하나, 과도(transient) phase(`compute_50` 등)는 조건 간(특히 busy/idle)
    스큐가 생기므로 비교 주장 시 리포트에 명시한다. "phase에서 정지 후 dump 대기(hold)"
    방식은 의도적으로 배제 — block된 프로세스는 mid-compute 프로세스와 dump 상태가
    달라져 현상 자체를 바꾼다.
  - **매 PHASE 라인 직후 `fflush(stdout)` 의무.** 파일 리다이렉트 시 stdio는 전체 버퍼링이라
    flush 없으면 runner가 phase를 못 보고 dump 타이밍이 밀린다 (침묵성 버그 → 계약 조문화).
- **A3. 일은 작업 단위로 정의**: 내부 루프는 "N ms 동안"이 아니라 "N iterations".
  시간 기반 정의는 stress-CPU 아래서 일의 양이 변한다 (nominal 700ms → busy 실측 938ms 교훈).
  시간은 **측정해 보고**하는 것이지 일을 **정의**하는 게 아니다.
- **A4. CRIU dump 가능성**: dump 시점 보유 fd = stdio 3개(일반 파일 리다이렉트) +
  listen 소켓 1개뿐. established/outbound 연결·특수 장치 fd 금지.
  단일 프로세스 기본, 스레드는 manifest 선언 시 허용 (그 자체가 실험축이 될 수 있음).
- **A5. 종료 규약**: SIGTERM에 깨끗이 종료 (teardown이 의존).
- **A6. 핑퐁 서버 (필수)**: `ready` 이후 accept, 연결당 `PING\n` → `PONG\n` → close.
  - 근거: "다시 살아났다"의 최저가 end-to-end 증명 (kill -0/proc 검사는 존재만 증명,
    PONG은 스케줄+메인루프+기능 서비스를 증명). first-response 측정 통로이기도 함.
  - **PONG은 고정 비용 유지** — 상태 체크섬 등을 응답에 싣지 말 것 (첫 응답이 측정 지표인데
    응답 비용이 워크로드마다 달라지면 지표 오염). 항상 `PONG\n` 5바이트.
    상태 무결성 검증(checksum 등)은 측정 창 밖에서 별도 수행.
  - `workloads/common/probe_server.h` 헬퍼 제공 (전 워크로드 사용 → 추출 정당).
    헬퍼는 **첫 요청 처리 직후 `PHASE served_first`를 자동 발행** — 전 워크로드 균일.
  - **warm dump 의미론 보존 (old 호환)**: old runner는 dump 전에 워밍업 요청 1회(측정 제외)
    → idle 대기(`checkpoint_after_s`) → dump했다 (dump 상태 = "첫 요청까지 처리한 warm").
    새 runner도 restore 경로에서 `warmup_pings`(config, 기본 1) 만큼 ready 후 PING을 보낸다
    → `dump_at: served_first`가 old 의미론과 정확히 동치. `warmup_pings: 0` + `dump_at: ready`는
    "안 데워진" 새 측정점. quiesce(연결 종료 확인)와 `checkpoint_after_s`는 runner config로 유지.
  - **pre-ready dump 의미론**: `dump_at`이 ready 이전 phase면 소켓 없는 상태로 dump되고,
    restore 후 first-response에 잔여 init 비용이 포함된다. 버그가 아니라 측정 대상
    ("init 중간에 얼리면 얼마나 이득인가").

### B. manifest (workload.yaml) 명세

```yaml
name: dirty                     # = 디렉터리명 (검증)
params:                         # A1 named flags 선언 (기본값 포함)
  bytes:    {default: 52428800}
  interval: {default: 200}
  port:     {default: 0}        # 0 = kernel-assigned (수동 단발 실행 전용 — port 규칙 참조)
phases: [ready, steady]         # A2 발행 목록 (ready 필수) — dump_at 검증용
metrics: [checksum]             # PHASE 라인에 싣는 보고 키 → collect가 CSV 열로 승격
resident:                       # Option B absorb용 — 실행 '전' 예측이어야 하므로 선언식
  from_param: bytes             #   파라미터 비례형 (param 단위가 byte가 아니면
  bytes_per_unit: 1             #    bytes_per_unit로 환산; 또는 mib: 8 고정형)
  overhead_mib: 2               #   (선택) 코드·스택 등 고정 오버헤드
calibration:                    # (선택) initburst형: campaign이 calibration 페이즈 자동 수행
  param: iters
  metric: compute_ms
threads: 1                      # (선택, 기본 1) A4 선언
```

- resident는 **steady(최대) 기준**: stress 크기는 워크로드 실행 전에 정해야 하므로
  phase별 점유 변화는 현상의 일부로 두고, absorb는 steady resident로 계산한다.
- **선언 정직성 검증**: 런 종료 후 측정 RSS(mem_snapshot)와 선언 resident를 비교,
  편차 >10%면 result.env에 `resident_mismatch=1` 경고 플래그 (absorb가 틀어진 런 식별).
- **port 규칙**: 측정 런에서는 campaign이 port를 **명시 배정**한다 (`0` 금지) —
  cold 측정 창이 포트를 알아내려 로그를 읽는 순간 §6-1(창 안 스폰 0개)이 깨진다.
  창은 순수 connect-재시도. 부수 이득: restore는 dump된 포트가 비어 있어야 하므로,
  병렬 캠페인의 포트 충돌도 런별 서로소 포트 풀로 함께 해결. `port: 0`은 수동 단발 실행 전용.
- **metrics 네임스페이스**: CSV 승격 시 워크로드 메트릭은 `wl_` 접두(`wl_compute_ms`) —
  runner 키(restore_time 등)와의 충돌 원천 차단.

### C. campaign 스펙 YAML (configs/campaign_*.yaml)

실험 설계(어떤 워크로드를 어떤 grid로)는 워크로드 속성이 아니므로 manifest가 아닌
campaign 스펙에 둔다. 워크로드 추가 = 디렉터리 1개 + 여기 1항목.

```yaml
campaign: wsk_redesign2
reps: 10
stress:
  target_total_mib: 1278        # Option B 총량 (§6-10)
  workers: 29
axes:
  cpu:  [busy, idle]            # stress-CPU
  kdat: [on, off]               # restore 경로만
workloads:
  - name: dirty
    sweep: {param: bytes, values_mib: [30, 40, 50, 60, 70]}
    dump_at: [steady]
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [50, 100, 150, 200, 300, 500, 700]}
    dump_at: [ready]
```

전개 의미론 (python 전개기가 보장):
- **cold는 dump·kdat과 무관** → 셀(workload×param×환경축)당 **1회만** 생성.
  dump_at·kdat 값 수만큼 cold를 중복 생성하면 paired 비교의 분모가 틀어진다.
- restore는 dump_at × kdat 조합마다 생성. 포트는 런별 명시 배정(§4-B port 규칙).
- calibration 선언 워크로드는 본 sweep 전에 calibration 페이즈 자동 실행,
  fit 계수를 campaign 산출물에 기록 (재현성).

### C-2. sweep 편의 문법 — 값 표현식·자유 축

반복 실험("X를 10~70까지 10씩")을 YAML에서 짧게 쓰기 위한 규칙.
전부 python 전개기가 정규화하며, **전개된 명시 리스트가 campaign 산출물에 기록**된다
(재현성 — "range 썼는데 값이 뭐였더라" 방지).

1. **값 표현식**: 값 리스트 자리 어디서나 세 형태 허용:
   ```yaml
   values: [10, 20, 30]                     # 명시 리스트
   values: {from: 10, to: 70, step: 10}     # 등차 (양끝 포함)
   values: {from: 1, to: 1000, factor: 10}  # 등비 (latency 등 로그 축)
   ```
2. **자유 축**: cpu/kdat 내장 토글 외에 임의 config 키를 축으로 sweep:
   ```yaml
   axes:
     kdat: [on, off]                        # 내장: restore 전용 (cold 중복 생성 안 함)
     pressure:                              # 자유 축: 아무 config 키나
       key: stress.target_total_mib
       values: {from: 1000, to: 1280, step: 70}
   ```
   자유 축은 cold·restore 양쪽 적용 (restore 전용은 kdat 내장 규칙뿐).
   주의: "스트레스 메모리 sweep"은 Option B에서 `target_total`(총 점유 = 압박 수준)
   sweep으로 표현한다 — 워커별 vm_bytes를 직접 돌리면 총량 일정 원칙(§6-10)이 깨진다.
3. **조합 폭발 가드**: 축은 곱셈 (값 7개 축 하나 = 720런 → 5,040런). 전개기는 실행 전
   총 런 수 + 예상 소요시간(직전 캠페인 실측 기반)을 출력하고 확인받는다 — 조용히 시작 금지.
4. **조건명 자동 생성**: run_id는 값이 **변하는 축만** 포함해 자동 생성
   (`dirty_50M_tot1140_cpubusy_koff_rep03`). 손 명명 금지 (오타·불일치 방지).
5. (미래 자리) full cross 대신 `sample: {method: lhs, n: 100}` — PLAN_FULL §7.2의
   LHS 샘플링이 이 정규화 위에 드롭인으로 얹힌다. 지금은 미구현.

### D. 계약 ↔ runner 동작 매핑

| 계약 조항 | runner가 하는 일 (lib/workload.sh) |
|---|---|
| A1 named flags | config params → `--k v` 기계적 전개 |
| A2 `PHASE ready` | readiness 대기 (경로 공통) + port/메트릭 파싱 |
| A2 임의 phase | `dump_at` 문자열 매칭 → quiesce(연결 없음 보장) → dump |
| A6 핑퐁 | lib/probe.sh로 first-response 측정 + 기능 회생 증명 |
| A5 SIGTERM | teardown |
| B manifest | 설계 시점 검증 (params/phases/dump_at 정합), resident→absorb, metrics→CSV |

## 5. 모듈 경계 원칙

1. **2+ 호출자 규칙**: `runner/lib/`에는 **두 러너가 모두 쓰는 코드만** 들어간다.
   한 러너만 쓰는 단계(예: cold의 `prepare_target_binary_on_constrained_storage`,
   restore의 `fadvise_restore_image_files`)는 해당 러너 파일 안의 in-file 함수로 남긴다.
   조기 추출 금지 — 호출자가 하나뿐인 코드를 lib로 빼지 않는다.
2. **러너 = 모듈 호출 + 경로 고유 step만**: old 11단계의 대부분(setup·cgroup join·
   stress 기동·워크로드 기동/ready 대기·probe·snapshot·result·teardown)은 사실 두 러너
   **공용**이었다(복붙이라 러너 고유처럼 보였을 뿐) → 전부 lib으로. 러너 파일에는
   그 경로의 정체성을 정의하는 in-file step 함수만 남는다:
   - run_once 고유: dump phase 대기/quiesce → dump → cache policy → kdat 제어 → restore → `-v4` 분해
   - run_cold 고유: 제약 스토리지 바이너리 준비 → drop_caches → exec
   main()은 lib/step 함수 호출 나열 ~20줄 — old 머리주석의 11단계 설명이 코드 그 자체가 된다.
   크기 목표: run_once 951→**250~350줄**, run_cold_start 540→**150~200줄**,
   각 step 함수는 화면 한 장. (호출자 1개인 step을 별도 파일로 빼는 것은 여전히 금지.)
3. **verb 패턴 통일**: env/hardware가 이미 `<module>.sh apply|restore <run_id> …` 패턴.
   stress도 start/verify/stop으로 동형. runner/lib 모듈은 source 후
   `<module>_<verb>` 함수 호출 규약으로 통일한다 (예: `probe_first_response`, `wl_launch`).
4. **전역 공유 최소화·명시화**: lib 함수는 머리 주석에 `# uses: $RUN_DIR $CG_PATH` /
   `# sets: RESP_END RESP_OK` 식으로 읽고 쓰는 변수를 계약으로 명시한다.
   (bash source 공유의 커플링을 없앨 순 없으니, 최소한 보이게 만든다.)
5. **README 동시 갱신**: 동작·설정이 바뀌는 모든 디렉터리의 README를 같은 커밋에서 갱신.
6. **positional 인자 누적 금지**: env/setup.sh 등 모듈 인터페이스는 flattened env
   (config_to_env 산출) 또는 named flag를 소비한다. 현행 `setup.sh <run_id> <mem>
   [cpu] [cpuset] [swap]`처럼 위치 인자가 자라는 구조는 미래 policy 노브 추가 시
   전 호출부 시프트를 유발 → 폐기.
7. **lib가 설정하는 전역은 모듈 접두**: `PROBE_RESP_END`, `WL_PORT`처럼 소속이 이름에
   보이게 (uses/sets 주석과 이중 안전장치). result.env 키 스키마는 별개(불변).

## 6. 측정 불변식 체크리스트 ★가장 중요

재작성에서 하나라도 조용히 빠지면 데이터가 오염되는, 피 흘리며 배운 규칙들.
구현 후 이 목록으로 코드 리뷰를 1:1 대조한다.

**측정 공정성 (cold ↔ restore 대칭)**
- [ ] 1. probe 측정 창 내용이 양 경로에서 **동일 함수**(lib/probe.sh): `kill -0`(빌트인) →
      cprobe → `$EPOCHREALTIME`(빌트인). 창 안 외부 프로세스 스폰 **0개** (sed/awk/date/seq 금지).
- [ ] 2. probe는 이벤트(RESTORE_END / launch) **직후 즉시**. 모든 bookkeeping
      (snapshot, `-v4` 로그 awk 분해, verify.sh, result 기록)은 창 **밖(뒤)**.
- [ ] 3. 폴링 주기 5ms 양 경로 동일. `RESP_POLLS`는 창 밖에서 사전 계산.
- [ ] 4. 러너 프로세스 자신도 대상 cgroup에 join — probe가 memcg 압박을 동일하게 받아야
      공정 (남는 꼬리 ~5–13ms는 cprobe의 memcg page-fault, 실험 해상도 아래 — 리포트 caveat).
- [ ] 5. cprobe는 **static 빌드** (동적 로더·libc major fault 제거; python 스폰 51ms → 0.8ms).
- [ ] 6. PONG 응답은 고정 비용 (`PONG\n` 5바이트) — 워크로드별 가변 작업을 싣지 않는다 (§4-A6).

**실험 의미론**
- [ ] 7. dump 후 cache_policy `sync + drop_caches=3` — restore는 cold page cache에서 출발.
- [ ] 8. kdat on/off는 `/dev/shm/criu.kdat` 존재 제어: off는 **dump 후·restore 직전 삭제**
      (dump가 kdat를 재생성하므로 restore를 cold로 만들려면 이 타이밍이어야 한다; old 동일),
      on은 1회 워밍 후 보존. kdat probing 절대값은 런 간 3배까지 출렁임 →
      **paired delta로만 비교** (절대값 비교 금지).
- [ ] 9. restore_time = kdat_probing + restore_work + launch_overhead 분해 유지
      (CRIU `-v4` 로그 파싱, 창 밖에서).
- [ ] 10. Option B 총량 흡수: `stress_mem = TARGET_TOTAL(1278MiB) − workload_resident(steady 선언값)`,
      워커 수 고정(29), 워커당 vm_bytes만 조정 → 총 점유·headroom 모든 런에서 일정.
- [ ] 11. 워크로드의 일은 작업 단위(iterations)로 정의, 시간은 실측 보고 (§4-A3).
      calibration(선형 fit)은 cpu-idle에서. 그림 x축·라벨은 실측/iters 기준 (nominal ms 라벨 금지).
- [ ] 12. dump 트리거는 phase 기반만 (§4-A2) — 시간 기반 트리거 금지.
      dump 시점엔 established 연결 없음(quiesce)을 runner가 보장.
- [ ] 13. stress oom-protect는 `cgroup.procs` **loop-until-stable**(deadline 8s).
      고정 횟수 sweep으로 되돌리면 late-spawn race 재발 (~50% 실패율의 원인이었음).
- [ ] 14. cpufreq 고정 클럭은 cpuset과 반드시 결합, teardown이 무조건 원복.
- [ ] 15. CRIU 이미지와 타깃 바이너리는 제약 스토리지(dm-delay) 위에.
- [ ] 16. 검증 사다리 유지: L1 readback → canary preflight → L2 membership →
      기능 회생 = PONG (§4-A6). 실패 시 result.env에 FAIL 사유 기록 (침묵 스킵 금지).
- [ ] 17. result.env 공통 키 스키마 유지 + `dump_phase` 키 추가 (조건 명명·collect·summarize
      그룹 키에 포함). 공통 키 = **runner 생성 키**(cold_response, restore_time 등)가 기존
      wsk_redesign CSV와 호환; 워크로드 메트릭은 `wl_` 접두 신설 (구 `compute_ms` →
      `wl_compute_ms` — 구/신 대응은 분석 스크립트에서 명시적 매핑).
- [ ] 18. 러너는 PATH의 criu가 아니라 `testbed/criu/bin/criu`를 명시적으로 사용
      (`CRIU_BIN` override 허용). 없으면 "criu/build.sh를 먼저 실행" 에러로 즉시 중단.
- [ ] 19. 워크로드 PHASE 라인은 fflush 의무 (§4-A2) — workloads/README와 common 헬퍼가 강제.
- [ ] 20. 측정 런의 port는 campaign이 명시 배정 (`0` 금지, §4-B) — cold 측정 창을 순수
      connect-재시도로 유지 (창 안 로그 파싱 금지). 병렬 실행 시 런별 서로소 포트.

## 7. CRIU vendoring 상세

- `criu/build.sh` (멱등):
  1. 의존성 확인 (protobuf-c, libnet, libnl-3 등 — 없으면 목록 출력 후 중단)
  2. `git clone --depth 1 --branch v4.2 https://github.com/checkpoint-restore/criu` (빌드 캐시 디렉터리에)
  3. `git apply testbed/criu/kdat-shm.patch` — 적용 실패 시 중단 (버전 드리프트 감지 겸용)
  4. `make -j` → 산출물을 `testbed/criu/bin/criu`로 복사
  5. `bin/criu --version` + 패치 확인 (`strings`로 `/dev/shm/criu.kdat` 존재 검사) 출력
- `/usr/local/sbin/criu`(수동 설치본)에 대한 의존 제거. 시스템 criu는 건드리지 않는다.
- 패치 원본이던 `/root/criu-webOS`는 학습용 주석 트리로 그대로 두되, testbed는 참조하지 않는다.
- **재현성 메타**: result.env에 `criu_version`(v4.2)·`criu_patch_sha`(kdat-shm.patch 해시) 기록.
  PLAN_FULL §3.4 재현성 원칙과 vendoring의 시너지 — 수동 설치본 시절엔 기록할 방법이 없었다.

## 8. 검증 계획 (old 동결 조건)

1. **정적**: 전 스크립트 `bash -n` + `shellcheck` 통과.
2. **스모크**: `SMOKE=1 run_campaign.sh` (대표 2셀 × 1 rep × cold/koff/kon = 6런) 전부 PASS,
   result.env 키가 old 스키마와 일치(diff로 키 목록 비교; 신규 키 `dump_phase` 등은 추가 허용).
3. **A/B 패리티**: 대표 4조건 (`ib_150ms`, `dirty_50M` × busy/idle) × 10 reps × 3경로 = 120런을
   새 testbed로 실행 → 각 지표(cold_response, restore_response, restore_time)의 **새 중앙값이
   wsk_redesign의 bootstrap 95% CI 안**에 들어오면 합격.
   - 어긋나면: 원인 규명 전까지 old 동결 금지. 필요시 old 코드를 testbed_old에서 같은 날
     재실행해 host-state drift(합격 기준 자체의 이동)를 분리한다.
   - 주의: 새 워크로드 계약(named flags, PHASE 문법)은 old와 인터페이스가 다르므로,
     패리티는 **동일 물리 조건**(bytes/iters/cpu/kdat)을 새 문법으로 표현해 비교한다.
     dump 의미론도 동치로: `warmup_pings: 1` + `dump_at: served_first` = old의
     "워밍업 1회 후 dump" (§4-A6 warm dump 의미론).
4. 합격 후: `testbed_old/README.md`에 "동결·참조 전용, {date} 패리티 검증 완료" 명시.

## 9. 마이그레이션 순서

각 단계마다 커밋 1개, 스모크 가능 시점부터는 스모크 포함.

1. `testbed_old/` 생성: 코드 디렉터리 `git mv` (env, runner, stress, workloads, configs, scenario.yaml)
2. `testbed/criu/`: patch + build.sh + README → 빌드 → kdat ON 동작 확인 (probing 4ms급 재현)
3. `testbed/workloads/`: 계약 문서(README) + common/probe_server.h + simple/dirty/initburst
   3종을 계약 v2로 이식 (named flags·PHASE 문법·simple에 소켓 추가) + build.sh
4. `testbed/env/`: setup/verify/teardown + hardware 5종 (검증된 로직 보존하며 다듬기)
5. `testbed/stress/`: start(loop-until-stable)/verify/stop
6. `testbed/runner/`: lib 8종 → run_cold_start → run_once → run_campaign(campaign YAML 해석)
7. python 3종 (config_to_env/collect/summarize — metrics 열 승격, dump_phase 그룹 키)
8. README 전체 (top-level 포함, 용어 규약 stress-*/workload-* 명시)
   + PLAN_FULL §0.5·PLAN_MIN 진척 노트 갱신 (kdat "off 고정" 스테일 수정,
   workload modularization 완료 표기 — §11)
9. §8 검증: 스모크 → 패리티 120런(tmux+알람) → old 동결

## 10. 열린 질문 → 전부 확정 ✅

1. runner 단계 분해 수준 → §5-2: in-file step 함수 (steps/ 파일 분리는 조기 추출).
2. 패리티 규모 → **120런** (4조건 × 10 reps × 3경로).
3. configs/ → 유지, campaign 스펙 YAML도 여기에.
4. cprobe 위치 → **runner/ 유지** (측정 도구지 워크로드가 아님).
5. campaign YAML 해석기 → **python 전개 + bash 실행** (YAML 파싱을 bash로 하지 않는다).

## 11. PLAN_FULL / PLAN_MIN과의 정합

repo 최상위의 PLAN_MIN(최소 슬라이스)·PLAN_FULL(전체 비전)과 이 재작성의 관계:

- **workload modularization 이행**: PLAN_MIN "다음 단계" 표의 미구현 항목(workloads/modules +
  generator.py)을 §4 계약 기반 플러그인이 대체·이행한다. YAML→코드 생성(generator) 대신
  "계약 준수 디렉터리 추가" 방식 — 같은 목표(다양한 워크로드), 훨씬 작은 기계장치.
  PLAN_FULL §2의 modules/(threads, pipes, …) 아이디어는 필요해질 때 workloads/common/
  헬퍼로 흡수한다.
- **env/policy는 이번 범위 밖** (swap backend/zram/swappiness — PLAN_FULL §4.2). 근거:
  ① 재작성의 합격 기준이 A/B 패리티(§8)인데 새 행동 축을 섞으면 검증이 오염된다.
  ② swappiness 등은 per-cgroup이 아닌 **시스템 단위** 노브라, 병렬 실행 불가·teardown 원복
  책임 등 지금 계약 밖의 문제를 끌고 온다 (PLAN_FULL §3.5도 직렬 sweep 필요를 인정).
  ③ TV의 실제 swap 정책(PLAN_FULL §10 질문 2)이 미확인 — anchor 없이 구현하면 사변적.
  다만 **seam은 유지**: env/policy/ 디렉터리 + README(설계 스케치) + setup.sh의 주석 훅
  (현행에도 있음) — 재작성 뒤 증분으로 얹을 자리를 남긴다.
- **CRIU dump 옵션 sweep** (--track-mem / --lazy-pages / --page-server, PLAN_FULL §6.4):
  미구현 유지. 단 campaign 스펙 YAML(§4-C)에 미래 `criu_opts:` 필드가 자연스럽게 들어가는
  구조 — 스키마 확장만으로 수용 가능함을 확인.
- **스테일 수정 예정**: PLAN_FULL §0.5의 "kdat은 /run=overlayfs라 off 고정" 서술은
  /dev/shm 패치로 해소된 상태. `audit_profile.sh` 참조도 재작성 후 폐기 대상.
  마이그레이션 8단계에서 진척 노트와 함께 갱신한다.
