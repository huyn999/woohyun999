# 실험 재설계 스펙 — workload sweep × stress-CPU × kdat (720런)

작성일: 2026-07-01 · 대상: CRIU webOS-like characterization 테스트베드(`/root/Embed-sim-lab`)
목적: LG 보고용 재실험. cold start vs CRIU restore의 **첫 응답(startup latency)** 트레이드오프를,
현실적 앱 크기(workload ≤70MB)와 새 축(stress-CPU, kdat)에서 처음부터 다시 측정한다.

> 용어 규칙(엄수): 배경 부하는 `stress-*`, 측정 대상 프로세스는 `workload-*`로 접두어를 붙여 구분한다.

---

## 0. 고정 조건 (안 바꿈)

- 하드웨어/자원 프로파일: 기존 `scenario.yaml`의 `tv_busy_mem_cpu` 앵커 그대로
  - `memory.max` ≈ 1740 MB, `swap.max` = 0
  - `cpu.max` = 4.0 cores, `cpuset` = 0-3
  - storage(CRIU 이미지): slow (rbps 150 / wbps 50 MB/s + dm-delay 1/3 ms)
- 반복: **10회/조건**, cold·restore **양쪽 경로** 측정
- 정합성 판정: criu `"Restore finished successfully"` 마커 (PID 관찰만으로 판정 금지)
- **dynamic 워크로드(grow/recompute)·지속 관측 창은 이번 설계에서 제외** → 순수 첫 응답 연구

---

## 1. 실험 축

### 1.1 workload (측정 대상, 메모리 점유 최대 70MB)

| 이름 | 성격 | sweep |
|---|---|---|
| **workload-dirty** | memory-bound, static. 처음부터 끝까지 같은 크기 익명 메모리를 선점·touch | **30 / 40 / 50 / 60 / 70 MB** (5수준) |
| **workload-initburst** | compute-bound. 초기 1회에만 몰린 연산(init burst), 이후 idle | **50 / 100 / 150 / 200 / 300 / 500 / 700 ms** (7수준) |

- 총 workload 수준 = 5 + 7 = **12**
- `workload-initburst`의 sweep은 저역을 촘촘히 둔다: 과거 crossover가 ~75–200ms였으므로 그 구간을
  촘촘하게 잡아 **restore가 cold를 역전하는 임계점**을 추적한다. (dirty는 이 셋업에서 교차하지 않고
  cold 단조 우세일 것으로 예상.)

### 1.2 stress (배경 부하)

- **stress-memory**: 항상 busy(고정 무대). **총량 흡수 방식(방식 B)** — §2 참조.
- **stress-CPU**: **idle / busy** (2수준). `cpu_saturate` 토글.
- 비대칭(memory=고정, CPU=축)은 의도된 것: 기기 앵커가 "RAM 상시 빡빡(~1.2GB 상시 사용) +
  CPU 변동(10–30%, 버스티)"이므로 그대로 반영.

### 1.3 kdat cache

- **on / off** (2수준). **restore 경로에만** 적용(cold은 CRIU를 안 쓰므로 kdat 축 없음).
- on/off 이득(~100ms 추정)은 kdat probing 절대값이 최대 3배 출렁이므로 **같은 조건 paired로** 비교.

---

## 2. stress-memory 총량 흡수 (방식 B)

workload-dirty가 커질 때 stress-memory를 같은 양만큼 줄여 **총 점유량을 상수로 유지**한다.

```
stress_mem = TARGET_TOTAL − workload_target_bytes
TARGET_TOTAL ≈ 1370 MB   (= 기존 stress ~1.3GB + 최대 workload 70MB)
```

| workload-dirty | stress-memory | 총 점유 | headroom (=1740−총) |
|---|---|---|---|
| 30 MB | 1340 MB | 1370 MB | 370 MB |
| 40 MB | 1330 MB | 1370 MB | 370 MB |
| 50 MB | 1320 MB | 1370 MB | 370 MB |
| 60 MB | 1310 MB | 1370 MB | 370 MB |
| 70 MB | 1300 MB | 1370 MB | 370 MB |

- workload-initburst sweep에서도 동일 규칙: workload 메모리(~십수 MB, 거의 고정)를 빼서
  `stress_mem ≈ TARGET_TOTAL − (작은 상수)` → 사실상 상수. 결과적으로 **720런 전체의 메모리 무대가 동일**.
- 조정 구현: stress-ng 워커 수는 고정(예: 28), **워커당 vm_bytes만 미세 조정**
  (`vm_bytes = stress_mem / workers`). stress-ng 실제 점유는 목표와 약간 어긋나므로
  `audit_profile`의 readback으로 **총 점유 ≈ TARGET_TOTAL**을 best-effort 검증.
- `cpu_saturate`(CPU 스피너)는 memory 워커와 **독립 knob** — 총량 흡수는 vm_bytes만 건드리고
  CPU 축엔 영향 없음.
- 기대 부수효과: workload ≤70MB + headroom 370MB 고정이면 restore가 `memory.max`를 안 건드릴
  가능성이 커져, **과거 연구의 memcg-pressure 교란이 상당 부분 제거**될 수 있다(`restore_peak_current`로 확인).

---

## 3. 조건 수(런 카운트)

- 환경 셀 = workload 12 × stress-CPU 2 = **24 셀**
- 각 셀 안:

| 경로 | kdat | 반복 | 런 |
|---|---|---|---|
| cold | 해당없음 | 10 | 10 |
| restore | off | 10 | 10 |
| restore | on | 10 | 10 |
| **셀당** | | | **30** |

- cold 합계: 24 × 10 = **240**
- restore 합계: 24 × 2(kdat) × 10 = **480**
- **총 720런**

---

## 4. 지표

- **1차**: `cold_response`, `restore_response` (runner 명령 발행 → 첫 TCP PONG; fork/exec 대칭 포함)
- **분해**: `restore_time = kdat_probing_s + restore_work_s`, `launch_overhead_s`
- **보조**: `cold_ready_s`, `dump_time_s`, `image_size_bytes`, `memory_peak_bytes`,
  `restore_peak_current`(memcg 압박 확인), `oom`, `oom_kill`
- **환경 readback**: memory_max, cpu_bandwidth, cpuset, storage(rbps/wbps/delay),
  stress(vm_workers/vm_bytes/cpu_saturate), workload(target_bytes/compute_ms), kdat_cache,
  실측 총 점유(≈TARGET_TOTAL 검증)

---

## 5. 연구 질문(RQ)

- **RQ-W (crossover)**: workload 크기/연산량에 따라 cold vs restore 승자가 어디서 갈리나?
  - 예상: workload-dirty → cold 단조 우세(교차 없음). workload-initburst → 저역 어딘가에서
    restore가 역전, 그 위로는 restore 우세.
- **RQ-S (stress-CPU)**: stress-CPU busy가 crossover를 이동시키나?
  - 예상: cold init은 CPU-bound라 busy에서 느려짐 → restore 유리 구간이 **넓어짐**.
    메모리 restore는 I/O-bound라 stress-CPU에 둔감.
- **RQ-K (kdat)**: kdat-on이 restore 고정비용을 얼마나 줄이나(paired), 그리고 crossover를
  얼마나 앞당기나? 이미지가 작아진(≤70MB) 지금 처음으로 의미 있게 측정됨.

---

## 6. 실행 계획(구현)

1. **새 캠페인 러너** 작성: 기존 인프라(`run_once.sh`, `run_cold_start.sh`, `config_to_env.py`,
   `workloads/`, `stress/`, `audit_profile.sh`, `collect.py`, `summarize.py`) **재사용**.
   - 720 조건을 루프하며 셀마다 (workload_type, size|compute_ms, stress_mem=TARGET_TOTAL−size,
     cpu_saturate, kdat) 설정 후 cold/restore 호출.
   - run-id 네이밍에 조건과 rep, cold/restore, kdat을 인코딩해 summarize의 `condition` 파생이 되게.
2. **preflight**: `audit_profile.sh`로 자원·stress 점유 readback 검증.
3. **스모크 검증**: 대표 소수 조건(예: dirty-70 / initburst-700, stress-CPU busy, kdat on&off) 1rep로
   end-to-end 확인 — Option B stress 조정·kdat on/off·result.env·CSV 수집이 실제로 도는지.
4. **본 캠페인**: tmux 세션에서 720런 실행(진행 로그 tee). stop-rule: 특정 조건 연속 실패 시 스킵/기록.
5. **집계**: `collect.py` → `all_runs.csv`, `summarize.py`(seed=12345, bootstrap CI) →
   `summary_by_condition.csv`. 산출물은 `testbed/experiments/`의 새 캠페인 폴더에.

---

## 7. 하지 말 것 / 한계 (미리 못박기)

- x86_64 호스트 — 절대 latency는 ARM/webOS로 일반화 금지(트렌드만).
- 합성 workload — 실제 LG Channel 재현 아님.
- storage는 slow 고정(이번엔 storage 축 없음). fast-storage 결과와 혼동 금지.
- stress-memory=idle(비압박) 조건은 앵커 밖이라 제외 — "압박 유무 대비"는 이번 스코프 아님.
- kdat on/off는 §1.3대로 paired로만 해석(절대값 출렁임 주의).
