# testbed — CRIU/임베디드 모사 파이프라인

임베디드(예: LG webOS TV) 자원 제약 + 배경 부하 위에서 CRIU checkpoint/restore가
cold start 대비 실용적인지 측정하는 자동화 파이프라인. 설계 전체는
`docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md`(§0~§11) 참고 — 이 문서는
지도·quickstart·용어만 다룬다. 과거 코드(2026-07 재작성 이전)는 `testbed_old/`에 동결돼 있다.

## 디렉터리 지도

```text
testbed/
├── scenario.yaml       # 기준(base) 설정 — 모든 조건 YAML의 출발점
├── ROADMAP.md          # 현재 상태 + 다음 계획
├── configs/            # 캠페인 스펙 YAML (campaign_*.yaml — run_campaign.sh 입력)
│                        #   ★실험 저작 가이드: configs/README.md (스키마 전체·레시피·체크리스트)
├── criu/               # CRIU 4.2 vendoring (kdat-shm.patch + build.sh)
├── env/                # 물리 제약 오케스트레이터 (setup/verify/teardown)
│   ├── hardware/        #   cgroup/memory/cpu/cpufreq/storage (무변경 이식)
│   └── policy/          #   미구현 seam (swap 등, 범위 밖)
├── stress/             # 배경 부하 (stress-ng)
├── workloads/           # 측정 대상 워크로드 (계약 기반 플러그인: simple/dirty/initburst)
├── runner/              # 러너(run_once/run_cold_start) + 캠페인 드라이버 + lib/ + 분석 3종
├── experiments/         # 캠페인 산출물 (all_runs.csv/summary_by_condition.csv/…, git 추적)
└── runs/                # per-run 산출물 (result.env/*.log/…, .gitignore)
```

각 디렉터리에 README가 있다: `criu/README.md`, `env/README.md`, `env/hardware/README.md`,
`env/policy/README.md`, `stress/README.md`, `workloads/README.md`, `runner/README.md`.

## 용어 규약

- **`stress-*`** — **배경 부하**. `stress/` 디렉터리, stress-ng 기반. 측정 대상이 **아니다** —
  target/CRIU와 같은 cgroup에서 자원을 같이 점유하는 "다른 프로세스들"을 흉내낸다.
- **`workload-*`** — **측정 대상**. `workloads/` 디렉터리, 계약 기반 플러그인(`workloads/README.md`
  §A). CRIU가 dump/restore하는 그 프로세스이고, first-response(PONG) 시간이 메인 지표다.

이 둘을 혼동하면 "무엇을 dump하고 무엇을 배경으로 두는지"가 헷갈린다 — 코드 전체
(`config_to_env.py`의 `stress`/`workload` 섹션, `result.env`의 `stress_*` 키 계열과 워크로드
메트릭의 `wl_*` 계열)가 이 접두 구분을 따른다.

## 설정 YAML 세 종류 — 뭘 언제 고치나

처음 오면 "YAML이 겉에도 있고 configs/에도 있고 experiments/ 안에도 생기는데 뭐가 뭐냐"가
제일 헷갈린다. 역할이 전부 다르다:

| 파일 | 내용 | 누가 만드나 | 언제 손대나 |
|---|---|---|---|
| ① `testbed/scenario.yaml` | 환경 전체(memory/cpu/storage/stress + 워크로드 기본) — **그 자체로 완전한 조건 1개** | 사람 | 머신이 바뀔 때(이식), 기본값을 바꿀 때 |
| ② `testbed/configs/campaign_*.yaml` | reps·축·sweep — "①에서 **뭘 바꿔가며** 몇 번 돌릴지"만 | 사람 | 실험 설계마다 (실험 1개 = 파일 1개) |
| ③ `experiments/<캠페인>/configs/<run_id>.yaml` | ①+②를 병합한 런별 완성 조건 | expander 자동 | **절대 안 건드림** (재현성 기록물 — `plan.tsv`가 목차) |

핵심 규칙 세 가지:

- **②에 안 적은 건 전부 ①을 상속한다.** 캠페인 파일에 memory.max가 없는 게 정상 — ①과의
  차이만 선언하는 파일이다. 그래서 이식 때 ①만 고치면 모든 캠페인 파일(②)은 기기 중립으로
  재사용된다.
- **단발 실행은 완전한 조건 YAML(① 또는 ③)을** `--config`로: 디버그/스모크용.
  **본 실험은 항상 ②를** `run_campaign.sh`에: expand→실행→collect/summarize까지 자동.
- `workloads/*/workload.yaml`은 네 번째 종류지만 실험 설정이 아니다 — 워크로드 플러그인의
  선언(manifest: params/phases/resident). 실험 돌릴 땐 신경 쓸 일 없다.

## Quickstart

```bash
# 0. 부트스트랩 — 의존성 설치 + 전체 빌드(워크로드·cprobe·CRIU) + 환경 진단, 원샷·멱등.
#    fresh clone에서 이거 하나면 실행 가능 상태가 된다 (Debian/Ubuntu/Raspberry Pi OS).
sudo testbed/bootstrap.sh
sudo testbed/bootstrap.sh --skip-criu    # CRIU를 직접 배치할 기기(예: RPi에서 교체)용
sudo testbed/bootstrap.sh --check-only   # 설치/빌드 없이 진단(doctor)만

# (개별 빌드가 필요할 때: testbed/criu/build.sh, testbed/workloads/build.sh —
#  cprobe는 bootstrap만이 빌드한다. python 의존성은 apt가 기본, 비-apt 환경은
#  pip install -r testbed/requirements.txt)

# 1. 단발 실행: cold-start 기준선 vs CRIU restore (둘 다 root 필요 — cgroup mutate)
sudo testbed/runner/run_cold_start.sh --run-id demo_cold    --config testbed/scenario.yaml
sudo testbed/runner/run_once.sh       --run-id demo_restore --config testbed/scenario.yaml

# 2. 배치 캠페인 (calibration -> expand -> 실행 -> collect/summarize)
sudo testbed/runner/run_campaign.sh <campaign.yaml>
```

## 이식 (다른 머신 / RPi4)

원칙: **git pull → `sudo testbed/bootstrap.sh` → doctor ALL PASS**가 이식의 정의다. C 소스
(workloads·cprobe)는 아키텍처 중립이라 aarch64에서 그대로 컴파일되고, stress-ng·dm-delay·
loop 등은 전부 apt/커널 표준 기능이다. RPi4에서 주의할 것 3가지:

1. **memory cgroup** — Raspberry Pi OS는 기본 비활성. `/boot/firmware/cmdline.txt`에
   `cgroup_enable=memory cgroup_memory=1` 추가 후 재부팅 (doctor의 controller 검사가 잡아준다).
2. **`scenario.yaml`의 `cpu.frequency_khz`** — 기기 cpufreq 범위 안이어야 한다(doctor가
   범위를 검사·출력). RPi4는 예: 600000~1500000kHz — 목표 클럭을 기기에 맞게 조정하라.
   `memory.max`/`cpuset_cpus`도 기기 스펙에 맞게 재검토.
3. **CRIU 교체** — `--skip-criu`로 부트스트랩한 뒤 원하는 CRIU 바이너리를 `criu/bin/criu`에
   배치(러너는 `CRIU_BIN` env로도 오버라이드 가능). 버전을 바꿔 빌드하려면 `criu/build.sh`의
   `TAG`를 수정. `kdat_cache=on` 축: 캐시 경로가 tmpfs면 되는데, **실호스트(RPi·TV)는 /run이
   tmpfs라 stock CRIU 그대로** scenario에 `criu: {kdat_file: /run/criu.kdat}` 한 줄이면 된다 —
   kdat-shm.patch는 /run이 overlayfs인 Docker/샌드박스 환경 전용 땜빵이다.
4. **비트니스(webOS 모사)** — TV는 64-bit 커널 + **32-bit userspace**다. ARM에선 CRIU와
   dump 대상 프로세스의 비트니스가 **반드시 일치**해야 한다(64↔32 compat C/R은 x86 전용;
   aarch64 CRIU는 aarch32 태스크를 못 다루고 역방향도 마찬가지 — 혼합 금지, doctor가 검사).
   - **Track A(충실도)**: 64-bit OS + 32-bit CRIU(직접 빌드 — **restore 쪽 compat 수정
     `criu/compat-aarch32-on-aarch64.patch` 필수**, LG TV 빌드와 동일 패치; `--skip-criu`
     후 배치) + 32-bit 워크로드: `apt install gcc-arm-linux-gnueabihf` 후
     `WL_CC=arm-linux-gnueabihf-gcc WL_CFLAGS="-O2 -Wall -static" testbed/workloads/build.sh`
     (-static이라 armhf 멀티아치 런타임 불필요). 단 "arm32 CRIU on arm64 커널"은 업스트림
     시험 밖 조합 — **`criu check` + 스모크 dump/restore가 판정선**이고, 거기서 막히면
     시간 태우지 말고 Track B로.
     **알려진 지뢰(RPi 실증 → 근본 원인 검거)**: 32-bit CRIU dump가 **큰 프로세스에서만**
     `pagemap-cache: PAGEMAP_SCAN: Bad address`(EFAULT)로 죽는다. 커널 문제가 아니라 CRIU의
     32-bit 버그(vec 포인터 sign-extension — 작은 프로세스는 힙 저주소라 우연히 통과) —
     **근본 수정은 `criu/pagemap-scan-32bit-vec.patch`를 32-bit 빌드에 적용**하는 것이고,
     재빌드가 곤란할 때만 scenario `criu: {fault: 135}`(PAGEMAP_SCAN 회피, 러너가 CRIU_FAULT
     env로 전달·result.env 기록)로 비상 우회한다. 64/64 조합은 애초에 무관. 같은 코드가
     TV의 CRIU 4.1에도 있으므로 TV의 실배치도 동일 점검 필요.
   - **Track B(안전)**: 전부 64-bit(부트스트랩 기본). 비트니스 충실도만 잃고 구조적
     결론(crossover 존재·kdat 효과·준위 곡선)은 유지 — 보고서에 캐비앗 한 줄.
   - cprobe·러너·stress-ng는 dump 대상이 아니라서 비트니스 무관(64 유지).
5. **스토리지 모사 전략** — dm-delay(+io.max)는 "빠르고 결정적인 매체 위에 TV eMMC를
   재현"하는 장치다. 기기 매체에 따라 판단이 갈린다:
   - **USB-SSD(권장)**: SSD는 eMMC보다 빨라서 **제약 스택을 그대로 유지**하는 게 맞다
     (끄면 TV보다 좋은 스토리지로 측정하게 됨).
   - **SD카드**: 매체 자체가 느려서 delay를 끄는 게 합리적일 수 있다
     (`storage.image.delay.enabled: false` 한 줄) — 단 SD의 지연 편차가 그대로 측정
     노이즈가 된다는 트레이드오프. "느리지만 통제 안 되는 실물" vs "빠른 매체 위의
     결정적 모사" 중 후자가 측정엔 유리하다는 게 이 테스트베드의 기본 입장.
   - delay를 끈 scenario에서는 doctor의 dm-delay 부재가 FAIL이 아니라 WARN으로 완화된다.
   - 교체 CRIU가 kdat-shm 패치 없는 stock 빌드면: `kdat off` 축은 러너가 stock 캐시 경로
     (`/run/criu.kdat`)까지 지워 어떤 빌드에서든 정직하고, **`kdat on` 축만 패치가 필요**하다.
6. **stress-ng floor 재측정 (필수)** — 인스턴스 floor는 플랫폼 의존이다(x86 ~38MiB,
   RPi aarch64 ~3MiB). 틀리면 배경 점유가 목표에 못 미쳐 stress verify가 FAIL한다(occupancy).
   ```bash
   sudo testbed/stress/measure_floor.sh    # → "stress: { floor_mib: N }" 제안 출력
   ```
   나온 값을 scenario.yaml `stress.floor_mib`에 기록 — absorb 분배와 expander 하한 가드가
   같은 키를 읽으므로 이 한 줄로 정합된다.

각 런은 `testbed/runs/<run-id>/result.env`(flat key=value, PASS/FAIL 공통 스키마)를 남긴다.
캠페인은 `testbed/experiments/<campaign-name>/`에 `plan.tsv`/`all_runs.csv`/
`summary_by_condition.csv` 등을 남긴다. 필드·CLI 상세는 `runner/README.md`.

**★철칙(캠페인 축 비교)**: 두 조건을 비교하려면 여전히 **한 캠페인 YAML 안에서 그 축에 값
2개를 리스트로** 선언하는 게 정석이다(예: `axes: {stress_cpu_saturate: [true, false]}`) — `run_id`는
"값이 변하는 축만 토큰화"하므로(`expand_campaign.py`) 한 캠페인 안에서 리스트로 선언해야 축이
run_id 토큰으로 갈린다. 다만 hardening v2부터 모든 run_id가 `<campaign>_` **접두(namespace)**를
달아(예: `parity_dirty_cpubusy_koff_rep03`), 캠페인 파일을 복사해 따로 돌려도 두 캠페인의 run_id는
접두가 달라 **구조적으로 겹치지 않는다** — `runs/` 덮어쓰기와 캠페인 간 병합·median 오염은 이제
소멸했다. `summarize.py`의 조건 균일성 가드(같은 조건인데 조건 정의 컬럼/`wl_param_*`이 갈리면
거부, 렌즈3)는 **2차 방어선**으로만 남는다. 접두는 "값이 변하는 축만 토큰화" 규칙의 유일한
예외이고(namespace이지 축이 아님), `kdat` 축도 예외로 값이 하나여도 항상 토큰화된다
(`cold`/`restore`를 구분할 다른 표식이 없을 수 있어서 — `expand_campaign.py` kdat 토큰화 주석 참고).

## 읽는 순서 (더 깊이 볼 때)

1. `testbed/scenario.yaml` — 지금 돌릴 기준 설정 한 장
2. `testbed/workloads/README.md` — 새 워크로드를 추가하려면 (계약 §4 전문)
3. `testbed/runner/README.md` — lib 모듈, 측정 불변식, 캠페인 흐름, result.env 스키마
4. `testbed/ROADMAP.md` — 현재 상태 + 다음 계획
5. `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` — 이 구조 전체의 설계 근거
6. 최상위 `PLAN.md` (프로젝트 통합 계획 — 현황·측정의 역사·미래 확장)
