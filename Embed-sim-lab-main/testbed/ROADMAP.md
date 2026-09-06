# Testbed Roadmap

교수 시선에서의 원칙: 파이프라인은 먼저 작고 검증 가능한 vertical slice로 유지한다. 제약 축을
늘릴 때는 실험 의미가 섞이지 않도록 `workload`(측정 대상, `workload-*`), `memory`, `cpu`,
`storage`, `stress`(배경 부하, `stress-*`), `policy`를 계속 분리한다.

> 2026-07: testbed 전면 재작성 완료 (설계:
> `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md`). 이 문서는 재작성 이후
> 기준으로 갱신했다 — 재작성 이전 코드는 `testbed_old/`에 동결(참조 전용).

## Current Stable Slice

`testbed/scenario.yaml` 기반 1-cycle 파이프라인(cold-start baseline / CRIU restore)이 동작한다.
기본 scenario는 LG webOS TV의 LG Channel-like app을 겨냥한 resource-tight embedded
approximation이다. 측정 디바이스(aarch64 Cortex-A73 x4, RAM ~1.7GB, ~360 task가 ~1.2GB 점유,
CPU 10~30%) 기반으로 `memory.max=1708M` + 고정 클럭(1.235GHz) + storage throttle +
stress(vm occupancy + cpu_saturate)를 함께 건 profile이다. 단, ARM/webOS와 x86_64/Linux 차이,
webOS swap 정책(디바이스는 ZRAM 사용; host엔 미구현이라 baseline은 `swap_max=0`), 실제 LG
Channel process/thread tree는 아직 열린 조건으로 남긴다.

```text
scenario.yaml (+ campaign이 전개한 조건별 YAML)
  -> env setup (cgroup + hardware 5종)
  -> L1 readback verify
  -> stress start + verify + warmup
  -> workload 기동 + PHASE ready 대기
  -> (restore 경로) warmup pings -> dump_at phase 대기 -> quiesce -> criu dump
  -> cache policy (drop_caches) -> kdat 제어
  -> (cold 경로) 제약 스토리지에 바이너리 배치 -> drop_caches -> exec
  -> first response (cold_response / restore_response, 메인 지표)  ← lib/probe.sh 단일 측정 창
  -> membership verify (L2) + resident 정직성 체크
  -> teardown
```

현재 제약/축:

```text
memory:   memory.max / memory.swap.max
cpu:      cpu.max bandwidth / cpuset.cpus / 고정 클럭(cpufreq)
storage:  image capacity(loop ext4) / bandwidth(io.max) / latency(dm-delay)
stress:   stress-ng 배경 부하 (vm occupancy + cpu_saturate on/off로 메모리/CPU 분리)
criu:     kdat_cache on/off (criu/ vendoring의 /dev/shm 패치로 둘 다 가능)
workload: 계약 기반 플러그인 (simple / dirty / initburst) — dump_at phase 축 포함
```

## Workload 플러그인화 (완료)

워크로드 지식이 runner(launch 분기)·campaign(sweep 하드코딩)·C 코드 세 곳에 흩어져 있던 문제를
계약 v2(`workloads/README.md`, 스펙 §4)로 해소했다. 새 워크로드 추가 = `workloads/<name>/`
디렉터리 1개(`workload.c` + `workload.yaml`) + campaign YAML 1항목, runner/campaign 코드
수정 0줄. named flags·`PHASE` 생애주기·핑퐁 서버(필수)·`dump_at` phase 축이 계약의 핵심이다.

## Batch sweep + analysis

```text
runner/run_campaign.sh   campaign YAML(스펙 §4-C) 해석 -> calibration -> expand -> 실행 -> finalize.
                         SMOKE=1(축소 스모크)/YES=1(비대화)/RUN_TIMEOUT(런당 timeout) env.
runner/expand_campaign.py  값 표현식(등차/등비)·자유 축·cold 중복 제거·포트 배정·조합 폭발 가드.
result.env               per-run flat key=value (실패 run 포함). dump_phase/wl_* 등 신규 키 포함.
runner/collect.py        모든 result.env -> all_runs.csv (union, 미측정=NA, 캠페인 스코프 필터).
runner/summarize.py      (exp_id, condition, dump_phase)별 median/bootstrap 95% CI -> summary_by_condition.csv.
```

`scenario.yaml`은 여전히 단일 hand-edit 기준 입력이고, sweep은 campaign YAML(`configs/campaign_*.yaml`
자리, 스펙 §2)이 그 위에 축을 얹어 조건별 완전 YAML을 만든다(과거의 per-run CLI override 방식은
새 러너에서 폐기 — `--run-id`/`--config`/`--kdat-cache` 3개 플래그만 남았다, positional 인자
누적 금지 원칙).

## Near-Term / Later Plan

이 로드맵의 세부 계획(YAML 인체공학, 파라미터 이름 정규화, storage/stress 축 분리,
cold/restore 공정성 등)은 재작성으로 대부분 반영됐다 — 남은 열린 항목은 설계 스펙과
`PLAN.md`(§1 현황·§5 미래 확장)로 이관한다:

1. **env/policy/** (swap backend/zram/swappiness) — 이번 재작성 범위 밖(스펙 §11,
   PLAN.md §5; 상세 노브 표는 git history의 구 PLAN_FULL §4.2). seam(디렉터리 + README + 훅 주석)만 존재.
2. **§8 검증 잔여**: 정적 검사(`bash -n`+`shellcheck`)는 태스크마다 통과 확인됨. 스모크
   (`SMOKE=1 run_campaign.sh`)와 A/B 패리티(대표 4조건 × 10 reps × 3경로 = 120런, old
   wsk_redesign bootstrap 95% CI와 비교)는 이 문서 갱신 시점 기준 다음 단계로 남아 있다
   (스펙 §8·§9-9).
3. **CRIU dump 옵션 sweep** (`--track-mem`/`--lazy-pages`/`--page-server`, PLAN.md §5) —
   미구현. campaign 스펙 YAML에 미래 `criu_opts:` 필드가 자연스럽게 들어갈 자리는 확인됨.
4. **LHS/통계 sampling** (스펙 §4-C-2-5) — `sample: {method: lhs, n: ...}`가 지금의 값 표현식
   정규화 위에 드롭인으로 얹히는 설계까지만 확정, 구현은 아직.
