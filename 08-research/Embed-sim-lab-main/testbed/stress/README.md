# testbed/stress — 배경 부하 (`stress-*`)

`stress-*`는 하드웨어/policy 제약이 아니라 "**같은 cgroup 안에서 다른 프로세스들이 자원을
점유하는 상황**"이다 — target/CRIU와 같은 cgroup에 넣어 같은 budget 안에서 경쟁하게 한다.
측정 대상(`workload-*`, `testbed/workloads/`)과는 역할이 다르므로 접두로 구분한다
(`testbed/README.md` 용어 규약 참고).

## 스크립트

```bash
sudo testbed/stress/start.sh  <run_id> <cg_path> <run_dir> <vm_workers> <vm_bytes>
     testbed/stress/verify.sh <cg_path> <run_dir>
     testbed/stress/stop.sh   <run_dir>
```

runner의 `lib/stress.sh`(`stress_start_verified`/`stress_warmup`/`stress_stop`)가 이 3개를
`CFG_STRESS_*` config 값으로 감싼다 — 직접 손으로 부를 일은 디버그 외엔 없다.

- **`start.sh`**: `vm_workers`개의 **독립 stress-ng 인스턴스**(각 `--vm 1 --vm-keep --vm-populate`)를
  같은 cgroup에 join시켜 기동. `cpu_saturate`(env `STRESS_CPU_SATURATE`, 기본 true)가 true면
  cgroup이 허용한 코어 수만큼 별도 `--cpu` saturator 인스턴스를 추가로 띄운다. false면 메모리만
  상주하고 CPU는 idle인 배경 부하가 된다(memory-only 모델). 추가 stressor는 `STRESS_EXTRA`
  (raw stress-ng 인자, 예: `--cache 2 --switch 4 --io 1`)로 별도 인스턴스 1개 더 붙일 수 있다
  — 메모리는 이쪽에 넣지 말 것(occupancy 검증 대상이 아님).
- **`verify.sh`**: 4종 검증 — ① membership(모든 인스턴스가 cgroup 안에 있는가)
  ② cpu-saturate(`cpu_saturate=true`면 별도 `--cpu` saturator 루트가 살아 있고 CPU time이 증가하는가;
  `false`면 `--cpu` 루트가 없는가)
  ③ occupancy(`memory.current`가 `vm_workers × vm_bytes`의 90% 이상 도달했는가, 최대 3s 폴)
  ④ oom-protect(아래).
- **`stop.sh`**: `stress.pids`에 기록된 루트 PID들에 SIGTERM → 3s 대기 → 살아있으면 SIGKILL.

## vm_workers / vm_bytes 의미론

`vm_bytes`는 **인스턴스 1개의 총 메모리**(오버헤드 포함)다. `start.sh`는 `vm_bytes`에서
인스턴스 floor(MiB)를 뺀 값만 실제 `stress-ng --vm-bytes`로 넘긴다(하한 미달이면 설계 시점
에러). **floor는 플랫폼(아키텍처·stress-ng 버전) 의존 실측값**이다: x86_64/0.17 실측 ~38MiB
(`1M→39MB, 10M→48MB, 25M→63MB`), RPi(aarch64) 실측 ~3MiB — 이식 시
`sudo testbed/stress/measure_floor.sh`로 재서 scenario.yaml `stress.floor_mib`에 기록한다
(→ `CFG_STRESS_FLOOR_MIB` → `STRESS_FLOOR_MIB`; expander의 absorb 하한 가드도 같은 키를
읽어 자동 정합). 틀린 floor는 verify ③(occupancy)이 잡는다 — RPi에서 38로 두고 돌리면
워커당 3MB짜리 stress-ng가 6MB 데이터만 쥐어 1276MB 목표에 271MB만 점유(실증). **한 stress-ng 인스턴스의 `--vm N` 다중 워커는 메모리를
상주시키지 않는다**(실측) — 그래서 "프로세스 N개"가 필요하면 `vm_workers`개의 독립 인스턴스로
띄운다(캠페인의 Option B absorb 계산도 이 전제 위에 있다 — `runner/README.md`, 스펙 §6-10).

## 워커 수 N — 조건(모사 대상)이지 성능 손잡이가 아니다

vm 인스턴스는 `--vm-keep --vm-populate --vm-hang 0`(**0 = 무한 park** — 0초 대기가 아니다)
조합이라, 시작 시 한 번 폴트인하고는 CPU를 안 쓰는 "상주 메모리 홀더"다(실측: N=1/4 모두
steady cgroup CPU 0ms/5s). 그래서 **총 점유량 T가 같으면 N 파티션(many-small vs few-large)은
steady 압박에 동치**다:

- 상주 anon 총량이 T로 같고(`swap_max=0`이라 양쪽 다 회수 불가), 압박은 pagecache 회수
  → re-fault로만 전달된다 — 파티션이 아니라 T가 결정.
- floor(~38MiB)는 공유 텍스트가 아니라 **인스턴스별 private anon** — 실측 N=1→4에서
  `memory.current` 3.90×(선형의 97.5%; 공유분은 바이너리 텍스트+libc 수 MB뿐).
  "N×floor는 공유라 허수" 가설은 기각(1156런 전수 occupancy ratio ≥1.012도 일치).
- **CRIU 천장에도 N 항이 없다**: 러너는 `criu dump -t <워크로드 PID>`로 타깃만 dump하고
  stress는 이미지에 안 들어간다 — restore transient는 워크로드 이미지 크기에 비례
  (crossover2 실측: steady 1340 → restore peak 1356MiB, +16MiB), N과 무관.

그럼에도 **캠페인 안에서 N은 고정한다**:

1. N=29는 임의값이 아니라 "TV에 배경 서비스 프로세스 여러 개"의 모사 — **조건의 일부**다.
2. 통제변인 원칙: 고정 비용은 0인데, 같이 흔들면 모든 결과 주장에 "N 무영향" 보조 논증이
   붙는다. "무관"은 특정 전제(park 홀더·swap off·steady·CRIU 비접촉) 아래의 *결론*이지
   설계에 심을 *가정*이 아니다 — "설마"의 대가가 kdat 런간 누수(±33ms)와 관측 슬랙
   (아티팩트 2호)였다(PLAN.md §3 측정의 역사).
3. N이 실제로 건드리는 것: 준위 **하한**(`resident + N×38MiB` — expand floor 가드),
   시작 populate 시간(N 비례, 측정 창 밖), floor/버퍼 구성비(해석용 라벨 — 물리 동일).

낮은 준위가 필요해 N을 줄일 땐 **별도 캠페인**으로 연다(`runner/README.md` 준위 축 절).
"N 무영향"을 가정이 아니라 데이터로 만들고 싶으면 T 고정 + N∈{10, 29}, reps 5 미니
캠페인 한 번이면 된다(robustness 각주용). 파티션이 지배 변수로 뒤집히는 유일한 경우는
홀더를 churn 부하로 바꿀 때다(per-instance 크기=워킹셋, N=동시성) — 그 축은 CPU와
얽히므로 열려면 별도 축으로, CPU 소모 실측부터.

## oom-protect: loop-until-stable (§6-13)

stress-ng는 실제 worker 프로세스를 `oom_score_adj=+1000`(OOM 1순위)으로 만든다 — "부하가
죽으면 안 된다"는 의도와 정반대다. `start.sh`는 stress 트리 전체(main/manager/worker)를
`oom_score_adj=-800`으로 덮어써 후순위로 보호한다. 이때 **고정 횟수 재시도가 아니라 8초
deadline까지 "트리가 정착하고 전원이 보호될 때까지" 반복 적용**한다 — worker가 `--vm-populate`
중 지연되어 늦게 뜨는 경우가 있어(고정 몇 회 재시도로는 놓침), 과거 고정 횟수 sweep으로
되돌렸을 때 late-spawn race로 ~50% 실패율이 재발한 경험 때문이다. 종료 조건은 "지금 보이는
프로세스 전원 보호"만으로는 부족하다(아직 fork 안 된 worker를 못 기다려 조기 종료 → 직후
verify ④가 실패하는 레이스, 실측 재현): **proc 집합이 직전 패스와 동일(트리 정착) + 전원 보호가
연속 3패스(≥0.4s)** 유지될 때만 끝낸다. `verify.sh`의 ④는 이 보호가 실제로 걸렸는지(모든
살아있는 stress PID의 `oom_score_adj ≤ threshold`) 독립적으로 재확인한다.
target/CRIU는 `oom_score_adj=0`(기본)으로 남겨 정당한 OOM 희생자가 되게 한다(PLAN.md §4 OOM 우선순위
— 배경 부하가 1순위 희생자가 되면 배경 부하가 사라져 실험 자체가 무효가 된다).
