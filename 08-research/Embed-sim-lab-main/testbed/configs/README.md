# campaign YAML 저작 가이드 — 실험을 파일 하나로 정의하기

이 디렉터리의 `campaign_<이름>.yaml`이 **실험의 정의 전부**다. 환경(memory/cpu/storage/stress
기본값)은 `testbed/scenario.yaml`(기기 baseline)이 대고, 캠페인 파일은 **"거기서 뭘 바꿔가며
몇 번 돌릴지"만** 선언한다 — 캠페인에 안 적은 건 전부 scenario를 상속한다(삼분법은
`testbed/README.md` 참조). 실제 예: `campaign_crossover2.yaml`, `campaign_parity.yaml`.

실행:

```bash
tmux new -s camp && sudo -i && cd <repo>
SMOKE=1 YES=1 RUN_TIMEOUT=600 testbed/runner/run_campaign.sh testbed/configs/campaign_foo.yaml  # 리허설
YES=1        RUN_TIMEOUT=600 testbed/runner/run_campaign.sh testbed/configs/campaign_foo.yaml  # 본 실험
```

| env 옵션 | 뜻 |
|---|---|
| `SMOKE=1` | 대표 1셀×1반복으로 축소 리허설 (캠페인명 `_smoke` 격리, calibration 2점) |
| `YES=1` | "PLAN: N runs, proceed?" 확인 프롬프트 생략 (무인 실행 필수) |
| `RUN_TIMEOUT=초` | 런 1개당 제한시간(기본 360) — hang 런이 캠페인을 인질로 못 잡게. 느린 기기는 600+ |

---

## 1. 전체 스키마 — 캠페인 파일에 올 수 있는 키 전부

이 8개 외의 top-level 키는 전개기가 즉시 거부한다(오타 침묵 통과 방지).

```yaml
campaign: my_experiment      # [필수] 이름 = run_id 접두 + experiments/<이름>/ 디렉터리.
                             #   ^[a-z0-9_-]+$ 만 허용 (셸/파일/cgroup 안전)
reps: 10                     # [필수] 셀(조건 조합)당 반복 횟수 — median/CI엔 10 권장, 탐색은 5
stress:                      # [필수] Option B absorb의 입력 (배경 메모리 점유 설계)
  target_total_mib: 1278     #   배경 점유 총량(MiB). 워커당 크기는 자동:
  workers: 29                #   vm_bytes = (target_total − 워크로드 resident) / workers
axes:                        # [선택] 조건 축들 — 여기 적은 모든 값의 데카르트 곱이 셀이 된다
  cpu: [busy, idle]          #   내장 축: busy = --cpu 새추레이터가 허용 코어 포화 / idle = 메모리만
  kdat: [on, off]            #   내장 축(restore 런에만): kerndat 캐시 재사용 여부. 값이 하나여도
                             #   run_id에 항상 토큰화된다(cold/restore 구분자 역할)
  mem:                       #   자유 축: 이름은 임의(run_id 토큰이 됨), key는 config 경로
    key: stress.target_total_mib   #   ★absorb 특례 2종: stress.target_total_mib / stress.workers 는
    values: [1150, 1278, 1400]     #     config에 쓰이지 않고 absorb 계산에만 들어간다(값 int 필수).
                             #     그 외 key(memory.max, checkpoint_after_s,
                             #     workload.params.<p> …)는 조건 YAML에 그대로 주입되고,
                             #     오타는 전개 시점에 die(스키마 검증)
workloads:                   # [필수] 측정 대상 목록 (여러 개면 각각 전개)
  - name: initburst          #   workloads/<name>/ 디렉터리명 (manifest 검증)
    sweep:                   #   [필수] 주 파라미터 sweep — 형식 셋 중 하나:
      param: iters           #     ① values: [10, 20, 40]          — 값 그대로
      calibrate_from_ms: [50, 100, 200]   # ② "몇 ms짜리"로 선언 → PHASE 1 calibration이
                             #        cold 런들로 선형 fit해서 param 값으로 자동 환산
                             #        (manifest에 calibration: {param, metric} 필요)
                             #     ③ values_mib: [30, 50, 70]      — MiB 선언 → bytes 자동 환산
    dump_at: [served_first]  #   [선택, 기본 served_first] dump 시점 phase 리스트.
                             #     manifest phases 중에서; 여러 개면 축이 된다(d<phase> 토큰).
                             #     ready 이전 phase(예: init)면 pre-ready dump 실험
warmup_pings: 1              # [선택] dump 전 워밍 핑 횟수 — dump_at=served_first면 ≥1 필수
checkpoint_after_s: 1.0      # [선택] 워밍 후 quiesce 대기(초)
cache_policy: best_effort_cold_cache   # [선택] 현재 유일한 정책
```

### 값 표현식 3형 — `values`/`values_mib`/`calibrate_from_ms`/자유축 `values` 어디든

```yaml
values: [50, 100, 200]                   # 명시 리스트
values: {from: 30, to: 70, step: 10}     # 등차: 30,40,50,60,70
values: {from: 50, to: 800, factor: 2}   # 등비: 50,100,200,400,800
```

---

## 2. 런 수 계산 — 밤샘인지 커피 한 잔인지 미리 알기

```
셀 수   = sweep값 수 × cpu값 수 × (자유축 값 수들의 곱)
총 런 수 = 셀 수 × reps × (cold 1 + dump_at수 × kdat수)
```

예: crossover2 = 7(sweep) × 2(cpu) × 10(reps) × (1 + 1×2) = **420런**.
전개기가 `PLAN: N runs, est ~X h`로 출력하니(런당 예상초는 `--est-run-s`, 직전 캠페인 실측으로
보정) **그 숫자를 보고 나서 진행**하는 게 원칙이다. 참고 실측: 서버 x86 ≈ 75s/런(420런 ≈ 9h),
RPi4 ≈ 2~3배.

포트는 런마다 18100부터 자동 배정(중복·65535 초과는 전개기가 die), run_id는 "값이 변하는
축만 토큰화" + 캠페인 접두(예: `crossover2_initburst_50_cpubusy_koff_rep01`), 총 100자 제한.

---

## 3. 레시피 모음 (복붙 후 이름/값만 수정)

### A. 상주 크기 sweep (dirty)

```yaml
campaign: dirty_sweep
reps: 10
stress: {target_total_mib: 1278, workers: 29}
axes:
  cpu: [busy, idle]
  kdat: [on, off]
workloads:
  - name: dirty
    sweep: {param: bytes, values_mib: {from: 30, to: 70, step: 10}}
    dump_at: [served_first]
```
→ 5×2×10×3 = 300런. "이미지가 커질수록 restore가 언제까지 이기나".

### B. 초기화 연산량 crossover (initburst) — ms로 선언

```yaml
campaign: crossover3
reps: 10
stress: {target_total_mib: 1278, workers: 29}
axes:
  cpu: [busy, idle]
  kdat: [on, off]
workloads:
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [50, 100, 150, 200, 300, 500, 700]}
    dump_at: [served_first]
warmup_pings: 1
```
→ 420런. calibration이 기기 속도에 맞는 iters를 자동 산출하므로 **기기가 바뀌어도 파일 그대로**.

### C. 배경 메모리 준위 축 (memory.max 고정, 점유만 sweep)

```yaml
campaign: memlevel
reps: 10
stress: {target_total_mib: 1278, workers: 29}    # 기본값 — calibration은 이 조건에서 fit
axes:
  cpu: [idle]
  kdat: [on, off]
  mem: {key: stress.target_total_mib, values: {from: 1150, to: 1550, step: 100}}
workloads:
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [100]}
    dump_at: [served_first]
```
- **하한** = `워크로드 resident + workers × floor_mib` (floor는 기기 실측 — scenario 참조.
  x86 풀옵션 stress-ng ≈38MiB로 29워커 하한 ≈1140MiB; RPi 미니멀 빌드 ≈2MiB로 하한 ≈60MiB).
  미달이면 전개가 정확한 숫자와 함께 die.
- **상한** 감각 = memory.max − (워크로드 resident + CRIU peak(≈워크로드 2배) + ~100MiB 여유).
  넘치면 타깃이 OOM 희생자가 되어 FAIL로 기록된다(`oom_kill` 컬럼).
- **N(workers)은 캠페인 내 고정이 정석** — 낮은 준위가 필요하면 workers 줄인 **별도 캠페인**
  (근거: `stress/README.md` "워커 수 N" 절). 그래프 x축은 headroom(= max − 준위 − resident) 권장.

### D. dump 시점 축 (pre-ready vs warm)

```yaml
workloads:
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [200]}
    dump_at: [init, served_first]     # run_id에 dinit / dserved_first 토큰
```
→ "init 도중에 얼리면(잔여 연산이 restore 후에 남음) vs 다 데운 뒤 얼리면". pre-ready 런은
`dump_phase_missed`(seize보다 init이 짧아 라벨이 어긋났는지)와 `warmup_pings_sent=0`이 기록된다.

### E. 자유 축 일반형 — 아무 config 키나 축으로

```yaml
axes:
  ckpt: {key: checkpoint_after_s, values: [0.2, 1.0, 3.0]}     # quiesce 대기 축
  # buf:  {key: workload.params.buf_bytes, values: [1048576, 4194304]}   # 워크로드 파라미터 축
```

---

## 4. 설계 원칙 체크리스트 (제출 전 자문)

- [ ] **비교하려는 축이 한 캠페인 안에 리스트로 들어있나?** 캠페인을 복사해 값 하나씩 돌리는
  방식은 금지 — run_id 토큰이 안 갈려 비교가 흐려진다(접두 덕에 데이터 오염은 없지만).
- [ ] **한 축만 움직이나?** 준위와 workers를 같이 흔들면 교란. 통제변인은 공짜일 때 고정.
- [ ] **reps가 결론의 무게를 감당하나?** median+bootstrap CI 기준 n=10 권장, 탐색 스크리닝은 5.
- [ ] **calibration의 의미를 아는가?** fit은 기준 조건(cpu-idle, campaign stress 기본값)에서 —
  다른 셀에선 nominal ms 라벨이 어긋날 수 있으니 **그림은 실측 `wl_compute_ms`를 축으로**.
- [ ] **런 수 × 런당 시간**이 일정에 들어오나? (PLAN 출력 확인)
- [ ] SMOKE 먼저 돌렸나? (기기·설정·워크로드 조합의 10분짜리 리허설)

---

## 5. 산출물 읽기 — `testbed/experiments/<캠페인>/`

| 파일 | 내용 |
|---|---|
| `plan.tsv` | 발주 목록: run_id / cold·restore / 조건 YAML 경로 / kdat |
| `configs/<run_id>.yaml` | 런별 완성 조건(①+② 병합) — 재현성 기록물, 손대지 않음 |
| `expansion.json` | 정규화된 sweep 값·포트 배정·셀별 absorb 계산(재현성 메타) |
| `progress.log` | 실행 로그 (`tail -f`로 관전) |
| `all_runs.csv` | **분석의 진실** — 전 런의 result.env 합본 (PASS/FAIL 포함) |
| `summary_by_condition.csv` | 조건별 median/p95/bootstrap 95% CI |
| `fails.txt` | 실행 당시 실패 **이력** (재실행해도 안 지워짐 — 현재 상태는 all_runs의 result 열) |
| `calibration_*.csv/txt` | PHASE 1 산출(요약과 분리 수집 — median 미오염) |

paired 비교(같은 조건·같은 rep의 cold↔restore delta):

```bash
testbed/runner/compare_cold_restore.py testbed/experiments/<캠페인>/all_runs.csv <출력디렉터리>
# → paired_runs.csv(쌍별 delta) + comparison_by_condition.csv(조건별 median delta·CI·winner)
```

## 6. 운영·트러블슈팅

- **중단**: Ctrl-C 해도 그때까지 끝난 런은 자동 롤업(finalize EXIT trap). 단 밤샘 무산이니
  나갈 땐 tmux `Ctrl-b d`.
- **동시 실행 금지**: `runs/.campaign.lock`(flock)이 강제 — 두 번째 캠페인은 즉시 거부된다.
- **일부 런 FAIL 시 재실행(top-up)**: `fails.txt`의 run_id를 `plan.tsv`에서 찾아 단발 재실행 후
  재수집:
  ```bash
  grep <run_id> testbed/experiments/<캠페인>/plan.tsv    # kind와 config 경로 확인
  sudo testbed/runner/run_once.sh --run-id <run_id> --config <그 경로> --kdat-cache <kdat열>
  # cold면 run_cold_start.sh --run-id ... --config ... (kdat 옵션 없음)
  testbed/runner/collect.py testbed/runs testbed/experiments/<캠페인>/run_ids.txt \
    > testbed/experiments/<캠페인>/all_runs.csv
  testbed/runner/summarize.py testbed/experiments/<캠페인>/all_runs.csv \
    > testbed/experiments/<캠페인>/summary_by_condition.csv
  ```
- **개별 런 부검**: `testbed/runs/<run_id>/result.env`(fail_reason), 같은 디렉터리의
  `dump.log`/`restore.log`/`workload.log`, 캠페인이 만든 `testbed/runs/<run_id>.console.log`.
- **기기 이식**: 캠페인 파일은 기기 중립 — scenario(①)만 기기에 맞으면 그대로 재사용.
  기기 간 결과는 **구조 비교만**(절대값 비교 금지 — `kernel_version`이 매 런 기록됨).
