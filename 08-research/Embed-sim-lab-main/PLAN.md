# PLAN — Embed-sim-lab 프로젝트 계획 (통합판)

> 2026-07-04, 구 `PLAN_MIN.md`(최소 시작점)와 `PLAN_FULL.md`(전체 비전)를 하나로 통합.
> 원문이 필요하면 git history에서 (`git log --follow -- PLAN_FULL.md`).
> 이 문서 하나로 "이 프로젝트가 뭔지, 지금 어디까지 왔는지, 왜 이렇게 만들었는지"를 알 수 있게 쓴다.

---

## 0. 이 프로젝트가 뭔가 (처음 보는 사람용)

**문제.** 스마트 TV 같은 산업용 임베디드 기기(LG webOS 등)에서 앱을 껐다 다시 켜면
초기화(cold start)에 시간이 걸린다. 프로세스를 통째로 저장했다가 되살리는
**CRIU checkpoint/restore**가 대안인데, TV처럼 메모리·CPU·스토리지가 빠듯한 환경에서
실제로 이득인지, 언제 이득인지는 아무도 정량화한 적이 없다.

**접근.** 실제 TV 대신, x86 리눅스 위에 **자원 제약을 재현하는 테스트베드**를 만든다:
cgroup v2로 메모리/CPU 한도, dm-delay로 느린 eMMC 스토리지, stress-ng로 "다른 앱들이
자원을 점유한 상황"을 모사하고, 그 위에서 CRIU restore와 cold start의 **첫 응답 시간
(first response)** 을 공정하게 비교한다. 파라미터(메모리 크기, 부하, 워크로드 종류,
dump 시점…)를 조직적으로 sweep하는 **파라미터 공간 시뮬레이터**다 — 반도체 process
variation을 Monte Carlo로 훑는 것과 같은 사고방식.

**산출.** (a) 임베디드 C/R 적합성을 평가하는 자동화 프레임워크(방법론, 연구 기여),
(b) LG에 줄 자원 조건별 support matrix(실용 기여). LG TV 환경은 파라미터 공간의
**anchor region**이고, LG 결과는 시뮬레이터의 case study + validation이 된다 —
서로가 서로를 정당화한다.

**경계 (중요).** 이 시뮬레이터는 ARM TV의 에뮬레이터가 **아니다**. ISA·page size·vendor
kernel은 재현하지 않는다. 역할은 *architecture-agnostic한 자원 압박*(메모리 ceiling,
배경 점유, 스토리지 지연, CPU 경쟁)이 C/R에 미치는 영향을 통제된 환경에서 모델링하는
것이고, architecture-specific 효과는 나중에 RPi/실기 실측으로 fidelity gap을 정량화해
calibration layer로 얹는다. "x86이 ARM을 완전히 모사한다"가 아니라 "x86에서 trend를
배우고 실기로 보정한다"는 관점.

---

## 1. 시스템 현황 — 한눈에 (2026-07-04, 전면 재작성 완료 기준)

2026-07-03~04에 testbed를 **계약 기반 플러그인 구조로 전면 재작성**했다
(설계: `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md`,
구 코드는 `testbed_old/`에 동결 — 참조 전용, 수정 금지).

### 디렉터리 지도

```
testbed/
├── criu/        CRIU 4.2 vendoring — build.sh가 clone→kdat patch→빌드 (재현 가능)
├── env/         자원 제약: setup/verify/teardown + hardware/{cgroup,memory,cpu,cpufreq,storage}
│   └── policy/  (미래 자리: swap/zram/swappiness — seam만 존재)
├── stress/      배경 부하: stress-ng vm 상주 + CPU saturate 토글, OOM-protect
├── workloads/   ★플러그인: <name>/{workload.c, workload.yaml} — 계약만 지키면 자동 편입
│   └── common/  probe_server.h(핑퐁)·flags.h(named flags) 공용 헬퍼
├── runner/      측정 파이프라인
│   ├── lib/     두 러너 공용 8모듈 — 특히 probe.sh = 측정 창의 single source
│   ├── run_cold_start.sh / run_once.sh     (cold / dump→restore 오케스트레이터)
│   ├── expand_campaign.py → run_campaign.sh (캠페인 전개·실행)
│   └── config_to_env.py / collect.py / summarize.py
├── configs/     campaign_*.yaml (실험 설계 스펙)
└── experiments/ 캠페인 결과 CSV (요약본만 커밋)
```

### 파이프라인 흐름

```
configs/campaign_X.yaml ──expand_campaign.py──→ plan.tsv + 조건별 YAML (+포트 배정, cold 중복 제거)
                                                     │
              run_campaign.sh가 순회: calibration → 각 런 실행(run_cold_start/run_once) → finalize
                                                     │
   runs/<run_id>/result.env (flat key=value) ──collect.py──→ all_runs.csv ──summarize.py──→
                                          summary_by_condition.csv (median + bootstrap 95% CI)
```

### 새 워크로드 추가 = 3단계 (runner/campaign 코드 수정 0줄)

1. `workloads/<name>/workload.c` — 계약 준수: named flags 수신, `PHASE <이름>` 생애주기
   발표(+fflush), 핑퐁 서버(`probe_server.h`), 일은 시간 아닌 **작업 단위**로 정의
2. `workloads/<name>/workload.yaml` — manifest: params/phases/metrics/resident 선언
3. `configs/campaign_X.yaml`에 1항목 — sweep grid(`{from,to,step}` 범위 문법 지원)와
   `dump_at:`(어느 생애주기 지점에서 dump할지 — **phase 기반, 시간 기반 금지**)

계약 전문은 `testbed/workloads/README.md` (그 파일 하나가 새 워크로드 작성자의 필독서).

### 캠페인 실행

```bash
testbed/criu/build.sh && testbed/workloads/build.sh          # 최초 1회
YES=1 testbed/runner/run_campaign.sh testbed/configs/campaign_X.yaml
# SMOKE=1(축소 검증), RUN_TIMEOUT=360(런당 행업 방어)
```

**★철칙(캠페인 축 비교)**: 두 조건을 비교하려면 여전히 **한 캠페인 YAML 안에서 그 축에 값
2개를 리스트로** 선언하는 게 정석이다 — `run_id`는 값이 변하는 축만 토큰화하므로
(`expand_campaign.py`) 한 캠페인 안에서 리스트로 선언해야 축이 run_id 토큰으로 갈린다. 다만
hardening v2부터 모든 run_id가 `<campaign>_` **접두(namespace)**를 달아, 캠페인 파일을 복사해
따로 돌려도 두 캠페인의 `run_id`가 접두로 갈려 **캠페인 간 충돌·병합·median 오염이 구조적으로
소멸**한다(`kdat` 축은 값 하나여도 항상 토큰화 — cold/restore 구분 표식이 그것뿐일 수 있어서).
`summarize.py`의 조건 정의 컬럼/`wl_param_*` 불일치 가드(렌즈3, `testbed/runner/summarize.py`)는
이제 **2차 방어선**으로만 남는다. cold vs restore 대응 비교는 `compare_cold_restore.py`가
`(cold조건, kdat, dump_phase)`별 paired delta(restore−cold)로 낸다.

### 신뢰성 장치 (왜 이 결과를 믿을 수 있나)

- **측정 불변식 20개** 감사 PASS 20/20 — 측정 창 안 스폰 0(strace 기계검증), cold/restore
  대칭, 포트 명시 배정 등: `docs/superpowers/reviews/2026-07-testbed-rewrite-invariants.md`
- **A/B 패리티**: 재작성판 120런 + old 코드 same-day 컨트롤 25런으로 엔진 정합 확증:
  `docs/superpowers/reviews/2026-07-parity-verdict.md` (§3의 아티팩트 2호 참조)
- 검증 사다리: L1 설정 readback → canary preflight → L2 cgroup membership → 기능 회생(PONG).
  실패는 반드시 `result=FAIL`+사유로 기록 (침묵 스킵 금지)

---

## 2. 지금까지의 실험과 발견

**wsk_redesign 캠페인 (2026-07-01~02, 720런, 구 testbed)** — workload(dirty 30–70MiB /
initburst 50–700ms급) × stress-CPU(busy/idle) × kdat(on/off), 조건당 n=10:

| 발견 | 내용 |
|---|---|
| crossover | **crossover2 재산출(2026-07-05, 새 하네스, n=10)**: kdat off면 실측 연산량 busy ≈184ms / idle ≈112ms부터 restore 우세. **kdat on이면 최저 측정점(busy 98ms/idle 48ms) 이하** — 연산형 앱 대부분에서 restore 우세. 데이터: testbed/experiments/crossover2/ |
| dirty | 메모리만 큰 앱은 항상 cold 우세 (restore가 dirty 페이지 I/O를 다 치러야 해서) |
| kdat | kdat 캐시로 restore_response 중앙값 ≈112ms [96,148] 절감 (paired delta 기준 — 절대값은 런 간 3배 출렁여 paired로만 비교) |
| 프레이밍 | restore = I/O-bound, cold = CPU-bound — 자원 압박의 종류에 따라 승자가 갈린다 |

✅ **crossover 재산출 완료 (crossover2, 2026-07-05)**: §3 아티팩트 2호의 예측(슬랙 제거 시
restore 쪽 이동)이 적중 — 같은 보간 기준으로 old→new: busy koff 192→**184ms**(−8),
idle koff 158→**112ms**(−46), idle kon 64→**<48ms**. 실측 compute_ms 자체는 old와 거의
동일(96↔98, 48↔48 — 엔진 재현 확인). crossover 인용은 이제 crossover2가 정식이고,
표의 old 수치(wsk_redesign)는 §3 철칙에 따라 새 수치와 병기 금지.

---

## 3. ★측정의 역사 — old와 바뀐 것 (후대를 위한 기록)

이 프로젝트에서 가장 비싸게 배운 교훈들. **숫자를 비교하기 전에 반드시 읽을 것.**

### 아티팩트 1호 — first-response 꼬리 (2026-07 초 발견·수정, 재작성 전)

- **증상**: restore_response − restore_time 꼬리가 busy ~58ms / idle ~200ms로 크고, idle에서
  더 커 보이는 역전.
- **원인**: 코어 온도/C-state 아님 (최심 C-state exit 127µs로 산술 반증). 진범은
  ① probe마다 python 인터프리터를 새로 스폰 (cold page cache에서 major fault + memcg
  압박 하 reclaim thrashing으로 스폰이 수십~수백 ms) ② restore 쪽만 측정 창 안에
  bookkeeping(스냅샷·로그 파싱)이 껴 있던 비대칭.
- **수정**: python probe → **static C 클라이언트 cprobe**(51ms→0.8ms), probe를 이벤트 직후로
  reorder, 창 안 스폰 제거. 꼬리 busy 5.9ms / idle 16.5ms로 감소.
- wsk_redesign 720런은 **이 수정 이후** 데이터라 이 아티팩트는 없음.

### 아티팩트 2호 — 완료 "관측" 슬랙 (2026-07-04 재작성 패리티에서 발견)

- **증상**: 재작성판 패리티 비교에서 19/20 지표가 old CI 밖 — 전부 새쪽이 빠른 방향.
- **원인**: old 하네스는 완료 시점을 **폴링으로 관측**했다.
  - restore: `criu restore`를 백그라운드로 띄우고 로그를 폴링하며 "끝났나?"를 확인
    → 실제 완료(T)와 관측(T+δ) 사이의 δ(폴링 주기 반올림 + 폴링 1회의 grep 스폰 비용 +
    로그 flush 지연)가 **launch_overhead와 restore_response에 통째로 가산** (+29~47ms).
  - cold: probe 시작 전에 2단 사전 폴링(프로세스 관측 → READY 로그 grep)이 있어
    cold_response에 +9~17ms.
- **검증**: same-day 컨트롤(old 코드 25런)이 old 7/1 값을 재현 → host drift·회귀 배제.
  CRIU 내부 로그 기반 성분(kdat_probing, restore_work)과 calibration은 old/new/컨트롤
  3자 완전 정합 → **엔진은 동일, 하네스만 정확해진 것**.
- **수정**: `criu restore -d --pidfile`(포그라운드 — 커널이 완료 순간 정확히 반환, 폴링
  자체가 없음) + cold는 exec 직후 즉시 probe.
- **결론**: old 데이터의 restore_response/restore_time/launch_overhead/cold_response에는
  +10~45ms 관측 슬랙 포함. 슬랙이 restore 쪽에 더 컸으므로 **old의 cold vs restore 비교는
  restore에게 +15~30ms 불리**했다. 상세 표: `docs/superpowers/reviews/2026-07-parity-verdict.md`

> ⚠️ **철칙**: 구 wsk_redesign 수치와 새 testbed 수치를 같은 그래프/표에서 직접 비교하지
> 말 것. LG 보고서에 old 그림을 쓰면 이 캐비앗을 반드시 병기.

### 그 외 old → new 의미론 변경 (전체 목록)

| 항목 | old | new | 이유 |
|---|---|---|---|
| restore 완료 시점 | 백그라운드+폴링 관측 | `-d --pidfile` 정확 반환 | 아티팩트 2호 |
| cold_launch_s / cold_ready_s | 폴링 관측치 기록 | **na** (의도적 폐기) | 그 관측 자체가 측정 창을 오염 — 가짜 숫자보다 정직한 na |
| kdat off의 캐시 삭제 시점 | dump 후·restore 직전 | 동일 (스펙 문구를 코드에 맞게 정정) | dump가 kdat를 재생성하므로 이 타이밍이어야 restore가 진짜 cold |
| restore의 타깃 바이너리 | host fs에서 exec | 동일 유지 | 제약 스토리지 배치는 **cold 전용** — restore에 넣으면 패리티 깨짐 (최종 리뷰에서 원복) |
| dump 시점 | "워밍업 1회 후" 고정 | `warmup_pings`(기본 1) + `dump_at: <phase>` 노브 | dump 타이밍이 정식 실험 축으로 승격 (old 방식 = warmup_pings:1 + dump_at:served_first) |
| 워크로드 인자 | positional | named flags (manifest 선언) | runner가 워크로드-무지(플러그인) |
| 준비 신호 | `WORKLOAD_READY` 한 줄 | `PHASE <이름> [k=v…]` 문법 (ready 필수) | dump_at 지점을 워크로드가 자유 선언 |
| 회생 검증 | generic recovery(존재 검사) | 핑퐁 필수 — PONG이 기능 회생 증명 | "살아있음"이 아니라 "일한다"를 증명 |
| grow / recompute 모드 | 있음 | 폐기 | 실험 설계에서 제외 결정 (2026-07-01) |
| exp_id | sweep 단위 coarse 라벨 | condition과 동일 (run_id에서 유도) | 스크립트 의존 없음 확인 후 단순화 |
| stress/env 실패 | 일부 침묵 가능 | 반드시 FAIL+사유 기록 | §6-16 (최종 리뷰에서 stress 침묵 경로 발견·수정) |
| kdat 상태의 런 간 누수 | dump가 이웃 런이 남긴 kdat 상태를 상속 (dump_time_s에 ±33ms 이웃-순서 편향 — old도 동일했음) | 런 시작 시 자기 축대로 초기화(step_kdat_init) — 런 독립 | 2026-07-04 적대 리뷰 F1; old 데이터의 dump_time_s 해석 시 주의 |

---

## 4. 설계 원칙 (왜 이렇게 만들었나)

- **Docker/namespace 미사용**: 필요한 건 자원 *예산 부과*지 시야 격리가 아니다. cgroup만
  쓰면 CRIU가 평범한 host 프로세스처럼 동작해 namespace 문제가 아예 없다. LG도 host
  root에서 CRIU를 돌리므로 reality와 일치.
- **모든 프로세스(stress+target+CRIU)가 같은 cgroup**: LG처럼 CRIU도 같은 자원 환경에서
  경쟁. 러너 자신도 cgroup에 들어간다 (probe가 memcg 압박을 동일하게 받아야 공정). restore는
  criu 자신의 메모리(이미지 read+프로세스 재구성, 실측 peak ≈ 워크로드의 2배)도 같은 cgroup
  예산에 계상되므로, 압박 조건에서는 restore만 reclaim/OOM에 더 노출된다 — 버그가 아니라
  의도된 실제 비용이며, 압박 조건 리포트에는 이를 각주로 명시할 것.
- **OOM 우선순위**: stress -800(죽으면 시뮬 무효) / target 0(진짜 앱은 보호 못 받음) /
  CRIU 0(OOM도 측정 가능한 실패 모드).
- **메모리 압박 = 두 직교 차원**: 하드웨어 ceiling(`memory.max`) × 배경 점유(stress-ng).
  따로 sweep해야 sensitivity 분석 가능. Option B 총량 흡수: stress 크기 =
  total − workload_resident로 총 점유를 조건 간 일정하게.
- **일은 작업 단위로 정의, 시간은 측정해서 보고**: "N ms 동안"이 아니라 "N iterations".
  시간 기반 정의는 CPU 경쟁 아래서 일의 양 자체가 변한다 (nominal 700ms → busy 실측 938ms).
- **측정 창 single source**: cold와 restore가 같은 함수(`lib/probe.sh`)로 측정 → 비대칭이
  구조적으로 불가능. 성공 경로(이벤트→cprobe 성공→타임스탬프)엔 cprobe가 유일한 외부 스폰 —
  폴 실패 사이 `sleep 0.005`도 외부 스폰이지만 타임스탬프는 그 이전에 이미 찍혀 지표에 안 들어가고,
  cold/restore 양 경로가 동일 메커니즘이라 편향 없음(상세: `docs/superpowers/reviews/
  2026-07-testbed-rewrite-invariants.md` §Step2).
- **재현성 Day 1**: 매 런에 kernel/criu 버전·patch 해시·전체 파라미터 기록. 캠페인 전개는
  결정적(같은 입력 → 같은 plan), 확장 값 리스트는 `expansion.json`에 박제.
- **작게 시작, 아픔 기반 확장**: 구 PLAN_MIN의 vertical-slice 원칙 — 최소 1사이클을 먼저
  굴리고, 실제로 답답한 것부터 추가한다. 이 원칙으로 지금까지 왔다.

측정 불변식 20개 전문: 스펙 §6 + 감사 문서. **코드를 고칠 때 이 목록과 충돌하면 안 된다.**

---

## 5. 파라미터 공간과 미래 확장 (미구현 — 필요해질 때)

**현재 sweep 가능한 축**: workload 종류·파라미터(sweep 문법: 리스트/`{from,to,step}`/
`{from,to,factor}`), stress-CPU busy/idle, kdat on/off, dump_at(phase), 자유 축(임의 config
키 — 예: `stress.target_total_mib`로 압박 수준 sweep). 조합 폭발 가드: 전개기가 총 런 수·
예상 시간을 먼저 보여주고 확인받는다.

**미래 (구 PLAN_FULL 비전 중 아직 유효한 것):**
- `env/policy/` — swap backend(none/zram/emmc_sim) × `memory.swap.max` × swappiness.
  디바이스는 ZRAM을 쓰는데 아직 미모델. seam(디렉터리+훅)은 준비됨. 단 swappiness는
  시스템 단위 노브라 직렬 sweep 필요.
- CRIU dump 옵션 sweep — `--track-mem`(pre-dump), `--lazy-pages`(임베디드 핵심),
  `--page-server`. campaign YAML에 `criu_opts:` 필드만 추가하면 수용 가능한 구조.
- LHS/통계 샘플링 — 축이 5~6개로 늘면 full cross 대신 `sample: {method: lhs, n: 100}`.
- 합성 워크로드 확장 — multi-process tree, socket/file-I/O 조합 (계약이 언어 불문이라
  C가 아니어도 편입 가능).
- RPi/ARM validation → calibration layer → LG support matrix → surrogate model.

**LG/교수님께 확인할 열린 질문** (변동 없음): ① LG channel의 isolation 모델(container냐
native냐) ② TV의 실제 swap 정책 ③ daemon 메모리 프로파일 ④ "복원 성공"의 LG 정의
⑤ CRIU plugin이 필요한 자원(HW decoder/DRM/GStreamer) ⑥ TV 커널 버전+vendor 패치
⑦ 수용 가능한 downtime ⑧ LG가 받을 수 있는 anchor 데이터.

---

## 6. 문서 지도

| 무엇을 알고 싶나 | 어디를 보나 |
|---|---|
| 프로젝트 전체 (이 문서) | `PLAN.md` |
| testbed 사용법·구조 | `testbed/README.md` (+각 하위 디렉터리 README) |
| 새 워크로드 만들기 | `testbed/workloads/README.md` (계약 전문) |
| 재작성 설계 근거 | `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` |
| 재작성 구현 계획(이력) | `docs/superpowers/plans/2026-07-03-testbed-rewrite.md` |
| 측정 불변식 감사 | `docs/superpowers/reviews/2026-07-testbed-rewrite-invariants.md` |
| old/new 패리티 판정 (아티팩트 2호) | `docs/superpowers/reviews/2026-07-parity-verdict.md` |
| 과거 실험 요약 | `testbed/experiments/past_experiments_summary.csv` + `reports/past_experiments_summary.md` |
| 구 코드 (동결) | `testbed_old/` — 참조 전용, 수정 금지 |
