# 과거 실험 요약 (CRIU webOS-like characterization, ~2026-06)

> 이 문서는 그동안 진행한 CRIU 특성화 실험 전체를 **한 장으로 압축한 기록**이다.
> 원본 raw 런(`testbed/runs/`, 68GB, 1163 runs), 중간 산출물(리포트 draft/notes/tex, figures,
> tables, campaign 스크립트)은 정리하며 삭제했다. 수치의 단일 출처(source of truth)는
> [`testbed/experiments/past_experiments_summary.csv`](../testbed/experiments/past_experiments_summary.csv)
> 이며, 제출용 결과보고서 `.docx` 2개(`reports/`)는 보존한다.

---

## 1. 연구 질문과 셋업

**핵심 질문**: 1~2GB 급 임베디드(LG webOS TV 유사) 환경에서 서비스 프로세스를
*cold start(처음부터 재초기화)* 하는 것과 *CRIU restore(체크포인트 복원)* 하는 것 중
**첫 응답까지가 언제 더 빠른가**, 그리고 그 경계가 무엇으로 갈리는가.

**테스트베드**: x86_64/Linux 호스트에 cgroup v2로 임베디드 자원 제약을 모사 (실제 ARM/webOS 아님).
- 메모리: `memory.max` ≈ 1740 MB, `swap.max` = 0 (ZRAM 미구현)
- CPU: `cpu.max` = 4.0 cores, `cpuset` = 0-3
- 스토리지(CRIU 이미지): loop ext4, `rbps` 150 / `wbps` 50 MB/s + dm-delay 1/3 ms (slow 기본)
- 배경 부하(stress-ng): vm workers ~28 × ~42MB ≈ 1.2~1.4GB 점유, `cpu_saturate=true`(busy)
- 프로파일: `tv_busy_mem_cpu`(main, busy+slow) / `tv_mem_only`(CPU idle) / `tv_busy_fast_storage`(스토리지 언스로틀)

**핵심 지표**:
- `cold_response` / `restore_response`: runner 명령 발행 → 첫 TCP PONG 응답 (fork/exec 비용 대칭 포함)
- `restore_time` = criu `"Restore finished successfully"` 마커까지 (= `kdat_probing_s` + `restore_work_s`)
- 정합성 판정은 항상 criu 성공 마커로 (PID만 보면 OOM 실패가 false PASS로 잡힘)

**워크로드**:
| 이름 | 성격 | 용도 |
|---|---|---|
| target_memory (dirty) | 큰 RSS 고정, 재생성 싼 | 메모리 중심: cold=malloc+touch 저렴, restore=대용량 page-in 비쌈 |
| target_memory (grow) | footprint가 시간에 따라 증가 | dump 타이밍 민감도 |
| target_compute | 작은 상태 + 무거운 초기화 계산 | 계산 중심: cold=CPU-bound, restore가 이를 우회 |
| target_simple | 최소 baseline | smoke / kdat 기준 |

---

## 2. 실험 캠페인과 발견 (P0–P5, broad 227런 + subset 70런)

CSV의 `dataset=broad`(warm-ish, CI 일부) / `dataset=subset`(cache/memcg 계측, CI 포함).

### P1 — 메모리 footprint sweep (RQ1)
128→256→384→512M. **cold은 낮게 유지, restore는 이미지에 비례해 증가.**
- 128M: cold 0.117s / restore 0.873s
- 256M: cold 0.165s / restore 1.852s
- 384M: cold 0.243s / restore 2.678s
- 512M: **20/20 OOM 실패** (예산 초과 = failure boundary, restore-only 실패 아님)
→ **재생성이 싼 대용량 메모리는 cold 승. restore는 I/O-bound.**

### P2 — 초기화 계산 sweep (RQ2)
compute 실측 median ≈ 42 / 328 / 692 ms.
- restore_response는 **거의 평평** (~0.14–0.15s, 이미지 16MB 고정)
- cold_response는 계산량에 **선형 증가** (0.110 → 0.392 → 0.772s)
→ **무거운 초기화는 restore 승** (restore가 계산을 통째로 우회).
→ **crossover**: warm broad ≈ 75ms, cache 통제 subset ≈ 180–200ms 부근.

### P3 — dump 타이밍: dirty vs grow (RQ3)  *(n=3, indicative)*
- dirty(footprint 고정): restore_response ≈ 1.84s로 **타이밍 무관 안정** (이미지 269MB 고정)
- grow(footprint 증가): 1s→1.15s(168MB), 5s→1.57s(235MB), 10s→2.16s(316MB)
→ **dump를 늦게 찍을수록 이미지↑ → restore↑ (grow만 타이밍 결합).**

### P4 — CPU saturation ablation: busy vs idle (RQ4a)
`cpu_saturate` off(`tv_mem_only`).
- compute-high: cold 0.772→0.537s (**~30% 개선, CI 비중첩 → CPU-bound**); restore 0.153→0.222s(소폭)
- memory-256M: cold 0.165→0.119s; restore 1.852→1.867s (**CI 중첩, 차이 없음 → I/O-bound**)
→ **cold 초기화는 CPU-bound, 메모리 중심 restore는 CPU와 무관.**

### P5 — 스토리지 ablation: slow vs fast (RQ4b)
`io.max`/`dm-delay` off. memory-256M.
- restore_response 1.852 → 0.367s (**~5×**), restore_work 1.72 → 0.23s (**~7.4×**), kdat_probing ~0.068s 불변
→ **메모리 중심 restore의 병목은 이미지 I/O.** (단, 실제 TV hardware 스토리지 결과 아님 — 보조 ablation)

### subset V1–V5 (pressure_bound_cache_instrumented, 각 n=10, 70/70 PASS)
broad 대표 조건을 cache/memcg 계측 하에 재측정. 트렌드 전부 재현:
- V1(256M slow) restore 1.939s ↔ V2(fast) 0.446s (**~4.3×**)
- V3(128M) 1.039s, V4(384M) 2.762s (메모리↑ → restore↑)
- V5(compute-high) cold 0.915s > restore 0.333s (계산 중심은 restore 승)

---

## 3. 핵심 결론 (트레이드오프 공식)

```
restore 승 ⇔ regeneration_cost(cold) > restore_fixed_floor + page_in_cost(state)
```
- `regeneration_cost(cold)` = malloc + page-touch + CPU 초기화 (CPU-bound)
- `restore_fixed_floor` ≈ 0.14–0.15s(warm, 소형 이미지) / ≈ 0.3s(cache 통제, 16MB)
- `page_in_cost` = restore_work_s = **이미지 I/O 지배 (스토리지 스로틀에 좌우)**

**세 줄 요약**: ① 메모리 크고 재생성 싼 앱 → cold 승. ② 초기화 무거운 앱 → restore 승.
③ restore의 병목은 CPU가 아니라 **이미지 I/O**.

---

## 4. 반드시 기억할 한계·caveat (다음 설계가 겨냥할 지점)

1. **busy 프로파일은 memcg-pressure-bound다.** restore 중 `memory.current`가 큰 이미지
   (256M/384M)에서 거의 매번 `memory.max`에 도달 → 지배 변수가 **cache 온도가 아니라 memcg reclaim 압박**.
   따라서 "restore 느림 = 스토리지 때문"과 "= reclaim 압박 때문"이 **현재 데이터로 분리 불가**.
2. **drop_caches는 best-effort.** restore 직전 cgroup file cache ~1350→~1101MB(약 250MB만 빠지고
   1.1GB 잔존, reclaim floor). before−after delta가 이미지 크기와 불일치(V4 384M는 ~117MB만 감소).
   → "매 런 이미지 캐시를 깨끗이 비웠다"고 주장 불가.
3. **drop on/off 대조군 부재** → cache 효과를 정량 분리 못 함. **압박을 푼 프로파일에서 별도 ablation 필요.**
4. **kdat_cache=on 이득 미측정.** 리포트 시점 호스트 `/run`이 overlayfs라 on 불가였고, `kdat_probing_s`
   (~47–110ms)는 probe/setup 비용일 뿐 on↔off 효과가 아니다. *(주의: 최근 커밋 d766d14에서 `/dev/shm`
   cache-path 패치로 kdat ON을 구현·검증했고 "saved≈112ms"를 관측했으나, **이 결과는 아직 CSV/리포트에
   반영되지 않았다** — 별도 측정으로 확정 필요.)*
5. **x86_64 호스트다.** 절대 latency는 ARM/webOS로 일반화 불가 (트렌드만 유효). cross-arch calibration 없음.
6. **합성 워크로드다.** 실제 LG Channel/WebKit/Qt/luna-bus process tree·RSS·FD/socket/thread·device
   dependency 프로파일 없음.
7. **ZRAM/swap 미구현** → 512M OOM 경계는 테스트베드 한정일 수 있음(실기기엔 ~450MB ZRAM 여유).
8. **표본 크기**: P3 dirty/grow n=3, 일부 subset은 원래 n=5(→boost로 10). 좁은 조건은 indicative.
9. **broad와 subset은 별개 데이터셋**(다른 목적/캐시 상태) — 하나로 합치지 말 것.

---

## 5. 명시된 후속 과제 (redesign 후보)

- N1: 실제 webOS/LG Channel process 프로파일링 (RSS/PSS, mapped .so, FD/socket/thread, IPC)
- N2: cold vs restore 예측 cost model (상태 크기 + 재생성 비용 기반)
- N3: cold/restore 자동 선택 정책/런타임
- N4: **압박 푼 프로파일에서 drop on/off ablation** → cache 효과 분리
- N5: 실기기 검증 (kdat-on 이득, ZRAM/swap, 실제 워크로드, cross-arch)
- N6: ARM 보드(RPi 등) anchor 측정

---

## 6. 재사용 가능한 테스트베드 자산 (삭제하지 않음)

- `testbed/scenario.yaml`, `testbed/configs/{tv_mem_only,tv_busy_fast_storage}.yaml`
- `testbed/runner/`: `run_once.sh`, `run_cold_start.sh`, `audit_profile.sh`, `request_probe.py`,
  `collect.py`, `summarize.py`, `config_to_env.py`, `fadvise_dontneed.py`, `mem_snapshot.sh`
- `testbed/workloads/`, `testbed/stress/`, `testbed/env/`, `testbed/ROADMAP.md`
- 제출용 결과보고서 `reports/*.docx` 2개

*(삭제됨: `testbed/runs/` raw 런, broad/subset all_runs·summary 원본 CSV, campaign 스크립트,
리포트 draft/notes/boost_results/tex, `reports/figures/`, `reports/tables/`, figure 생성 스크립트.)*
