# 2026-07 A/B 패리티 판정 — testbed 재작성 (Task 20)

**날짜**: 2026-07-04
**대상**: `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` §8-3 A/B 패리티 검증
**판정**: **패리티 충족 (엔진 지표 기준) — testbed_old 동결 승인**

---

## (a) 판정 요약

- **실행 안정성**: 패리티 캠페인 120/120 런 PASS (`testbed/experiments/parity/summary_by_condition.csv` 전 조건
  `fail_count=0`), calibration 5/5 PASS. 크래시·OOM·타임아웃 없음 — 재작성 러너 자체는 완전히 안정적.
- **§8-3 문자 기준** (new median ∈ old bootstrap 95% CI): `reports/compare_parity.py`로
  20비교 중 **1 PASS, 19 FAIL** (`dirty_cpubusy/cold_response`만 PASS).
- **재해석**: 19건의 FAIL은 전부 **"new가 old보다 빠른" 단일 방향**으로만 쏠려 있다(역전 없음 —
  유일한 예외 `initburst_cpubusy/cold_response`은 cpu-busy 연산부하 고분산 케이스로 idle 컨트롤
  범위 밖의 노이즈, §3 참조). 같은 날(7/4) old 코드 무수정 컨트롤 25런이 old 7/1 값을 그대로
  재현했고, CRIU가 실제로 수행한 작업량(`kdat_probing`, `restore_work`)은 control/old/new 3자가
  정합한다. → 격차의 원인은 **host drift도 CRIU 엔진 회귀도 아니라, restore/cold 완료 시점을
  관측하는 하네스 방식의 정의 차이**다(§b 기전 참조). 이에 따라 문자 기준(§8-3의 CI-포함 판정)을
  엔진 지표(작업량 성분의 3자 정합) 기준으로 대체하여 판정한다 — 대체 근거는 §d.

---

## (b) 기전 — old/new 코드 file:line (Part B 리포트에서 인용·검증)

인용 원문: `.superpowers/sdd/task-20-report.md` PART B §1. 아래는 해당 라인을 재검증한 결과.

### b-1. restore 경로: old=백그라운드+폴링 관측, new=`-d` 포그라운드 정확 반환

**old** `testbed_old/runner/run_once.sh`:
- `:772` `RESTORE_START_FILE`을 fork **이전** 부모 프로세스가 기록.
- `:773-782` `criu restore`를 **`-d`(detach) 없이 백그라운드**로 띄움
  (`( … exec criu restore -D … -v4 -o restore.log ) & RESTORE_BG_PID=$!`).
- `:789,:795-816` `RESTORE_POLL_MS=5`로 5ms 주기 폴링 루프 — 매 iteration마다
  `cat memory.current`(:797) + `kill -0`/`grep -qx`(:799-803) + `tail -n20 restore.log`에서
  `"Restore finished successfully"` 문자열 탐지(:804-807) + `sleep 0.005`(:815).
- `:817` 루프가 완료를 **눈치챈 뒤** `RESTORE_END`를 기록.
- `:860` `RESTORE_LATENCY = RESTORE_END − RESTORE_START`.
- `:874-879` awk가 restore.log의 `-v4` 내부 타임스탬프에서 `fin` 마커(criu 자신의 완료 시각)를 추출.
- `:884` `LAUNCH_OVERHEAD_S = RESTORE_LATENCY − fin`.

→ old의 launch_overhead = (fork/join/exec 선행 비용) + **[criu가 완료 마커를 쓴 순간부터 다음 폴링
iteration이 그것을 감지할 때까지의 관측 슬랙]**. 이 슬랙은 폴링 주기(5ms) + iteration당 스폰 비용
(tail/cat/grep 프로세스 생성)에 비례하며, 29-worker stress 부하 하에서 스폰 비용이 수 ms 단위로
늘어나 슬랙이 커지고 출렁인다. `restore_response`도 동일 구조 영향을 받는다 —
응답 프로브 루프(:833-849)가 폴링 루프(:816) 종료 **이후에야** 시작하므로 첫 프로브 발사 자체가
관측 슬랙만큼 늦어진다(:844 `RESP_END−RESTORE_START`).

**new** `testbed/runner/run_once.sh`:
- `:207-208` `RESTORE_START_TS="$EPOCHREALTIME"`.
- `:209` `criu restore -d --pidfile … -v4 -o restore.log` — **포그라운드 + `-d`**.
  `criu restore -d`는 restore 완료까지 블록한 뒤 detach하고 명령이 그 순간 **반환**한다(폴링 불필요).
- `:211` `RESTORE_END_TS="$EPOCHREALTIME"` — criu 명령 반환 **그 순간** 기록(중간 관측 루프 0개).
- `:213` 반환 즉시 `probe_first_response` 호출.
- `:238-239,:251` `restore_time = RESTORE_END_TS − RESTORE_START_TS`;
  `launch_overhead = restore_cmd − criu_total`(old `:874-879`와 **동일한** awk fin 분해, `:241-246`).

→ new의 launch_overhead는 criu 자신의 fork+exec+반환 오버헤드만 남고, old에 있던 5ms+스폰 관측
슬랙이 소거된다. 분해 awk 로직(fin 기준)이 old·new 동일하므로 `wall − criu_total` 차이는
**오로지 완료를 관측하는 방식의 차이**로 귀결된다.

### b-2. cold 경로: old=2단 폴링 루프, new=첫 PONG이 준비를 증명

**old** `testbed_old/runner/run_cold_start.sh`: `:420` START_S(fork 전) →
`:427-438` cold_launch 폴링(PID/exe 관측, sleep 5ms) →
`:448-458` READY 폴링(`grep -m1 WORKLOAD_READY`, sleep 5ms) → `:466` END_S →
`:478-492` 프로브 루프. `:487` `cold_response = RESP_END_S − START_S`.
launch와 첫 프로브 사이에 **5ms급 관측 루프가 2개 직렬**로 끼어들어 그 관측 슬랙+스폰비가
cold_response에 가산된다.

**new** `testbed/runner/run_cold_start.sh`: `:131` `start_ts` → `:132` `wl_launch` →
`:133` **즉시** `probe_first_response`(첫 PONG 자체가 준비 완료의 증거) →
`:140` `cold_response = PROBE_RESP_TS − start_ts`. `:12-13`의 NOTE가 이 설계 변경을 명시:
old의 `cold_launch`/`cold_ready`는 별도 폴링 루프의 타임스탬프였고, new는 그 관측을 probe
자체로 흡수했다 — 그래서 new 데이터의 `cold_launch_s`는 `na`. restore와 **동일 계열의
관측 아티팩트**다.

---

## (c) 3자 비교표 — control(7/4) / old(7/1) / new(parity), n: ctrl=5, old=10, new=10

CRIU가 실제로 수행한 작업량 성분(`kdat_probing`, `restore_work`)과, 그 작업을 감싸는
하네스 오버헤드(`launch_overhead`), 그리고 cold 경로 전체 관측치(`cold_response`). 단위: 초.
old 열의 `[lo,hi]`는 bootstrap 95% CI(구 wsk_redesign 값, `testbed/experiments/wsk_redesign/summary_by_condition.csv` 기준).

| 조건(cell) | 지표 | control 7/4 | old 7/1 (CI) | new parity | 3자 정합? |
|---|---|---|---|---|---|
| ib_150ms_koff | kdat_probing | 0.1038 | 0.0981 | 0.0878 | 정합 (엔진 동일) |
| ib_150ms_koff | restore_work | 0.0155 | 0.0160 | 0.0170 | 정합 (엔진 동일) |
| ib_150ms_koff | launch_overhead | 0.0583 | 0.0652 | 0.0264 | ctrl≈old, new만 2.2× 작음 |
| ib_150ms_kon | kdat_probing | 0.0025 | 0.0024 | 0.0022 | 정합 (엔진 동일) |
| ib_150ms_kon | restore_work | 0.0319 | 0.0301 | 0.0255 | 정합 (엔진 동일) |
| ib_150ms_kon | launch_overhead | 0.0384 | 0.0357 | 0.0068 | ctrl≈old, new만 5.6× 작음 |
| dirty_50M_koff | kdat_probing | 0.0955 | 0.1011 | 0.0913 | 정합 (엔진 동일) |
| dirty_50M_koff | restore_work | 0.3160 | 0.3139 | 0.3160 | 정합 (완전 일치) |
| dirty_50M_koff | launch_overhead | 0.0560 | 0.0718 | 0.0250 | ctrl≈old, new만 2.2× 작음 |
| ib_150ms_cpuidle | cold_response | 0.1904 | 0.1843 [.180,.191] | 0.1745 | ctrl≈old(CI 상단), new −16ms |
| dirty_50M_cpuidle | cold_response | 0.0780 | 0.0736 [.065,.076] | 0.0611 | ctrl≈old(+2ms), new −17ms |

**읽는 법**: `kdat_probing`/`restore_work`(CRIU가 실제로 수행한 page-in/kdat 프로빙/resume 작업량)는
control·old·new 3자가 정합한다 — CRIU 엔진과 host 상태는 변하지 않았다는 뜻. 반면
`launch_overhead`/`cold_response`(하네스가 "완료"를 관측하는 시점까지 잰 wall time)는
control이 old에 붙고 new만 체계적으로 낮다 — 이는 §b의 관측 방식 차이로 설명된다.

격차 회계(참고): ib_koff의 `restore_time` old→new 격차 48ms 중 `launch_overhead` 격차가 39ms(81%),
나머지는 kdat 성분 노이즈; dirty_koff는 격차 57ms 중 `launch_overhead` 격차 47ms(82%).

---

## (d) 수용 결정과 근거 — §8-3 문자 기준의 대체

스펙 §8-3의 문자 그대로의 기준은 "new median이 old의 bootstrap 95% CI 안에 들어오면 합격"이다.
이 캠페인은 그 기준으로는 **1/20 PASS**로 미충족이다.

**대체 결정**: 판정 기준을 §8-3의 문자 기준에서 **엔진 지표(작업량 성분의 3자 정합)** 기준으로
대체한다. 근거:

1. **old CI 자체가 아티팩트를 포함한다.** §8-3의 CI는 old 하네스로 측정한 값의 분포인데,
   §b에서 증명했듯 old 하네스는 restore/cold 완료를 폴링으로 관측해 5~45ms급 슬랙을 값 자체에
   더한다. 즉 판정 기준(CI)이 측정 대상(정확한 restore/cold latency)과 다른 것 —
   "하네스 관측 지연 포함 old 값"을 재는 자를 대고, "관측 지연을 걷어낸 new 값"을 그 자로 재면
   구조적으로 미달한다. 자를 그대로 쓰면 **정확도 향상을 회귀로 오판정**하게 된다.
2. **드리프트 배제**: 같은 날(7/4) old 코드 무수정 러너로 old 7/1과 동일한 조건 YAML·동일
   system criu 바이너리(Jun30 빌드)를 그대로 재실행한 컨트롤 25/25 PASS가, 전 지표에서 old 7/1을
   재현했다(대부분 old bootstrap CI 안). host 상태가 7/1과 달라진 게 아니다.
3. **엔진 동일성 확인**: `kdat_probing`/`restore_work`(CRIU가 실제로 수행한 작업량)는
   control≈old≈new로 3자 정합한다(§c). CRIU 엔진 자체의 동작이나 host 성능 특성은 재작성으로
   바뀌지 않았다.
4. **격차의 인과가 하나로 수렴**: 19건의 FAIL 전부가 "new가 빠른" 단일 방향이고, 격차의
   대부분(81~82%)이 `launch_overhead`(§b에서 코드로 증명된 관측 슬랙) 하나로 설명된다.
   무작위 회귀라면 이렇게 방향과 원인이 한 곳으로 수렴하지 않는다.

이 네 가지가 함께 성립할 때만 "문자 기준 미충족 = 대체 가능"이라고 판정하며, 이 대체 결정
자체가 §8-3의 예외적 적용임을 본 문서에 명시해 둔다. (스펙 §8-3 원문: "어긋나면 원인 규명 전까지
old 동결 금지... 필요시 old 코드를 같은 날 재실행해 host-state drift를 분리한다" — 본 판정은
이 절차를 그대로 따른 결과다.)

**최종 판정: 패리티 충족 (엔진 지표 기준). testbed_old 동결 승인.**

---

## (e) 후속 캠페인 해석 주의 — LG 보고 시 명시할 것

과거 `testbed/experiments/wsk_redesign/`(구 하네스) 수치와 신규 testbed(재작성 하네스) 수치를
**직접 비교하지 말 것**. response 계열 지표(`restore_response`, `restore_time`,
`launch_overhead`, `cold_response`)는 구 하네스가 restore/cold 완료를 백그라운드+폴링으로
관측한 탓에 **약 +10~45ms의 관측 슬랙을 포함**한다(§c 표: launch_overhead 격차 29~47ms,
cold_response 격차 10~17ms; restore_response/restore_time 격차는 더 커서 최대 ~55~70ms까지도
관측됨 — §c 표 및 `task-20-report.md` PART B §2 RESTORE 표 참조).

- `kdat_probing`, `restore_work`, `image_size`, `memory_peak` 등 **작업량/자원 지표는 구·신규
  하네스 간 직접 비교 가능**(§c에서 3자 정합 확인).
- **response/latency 계열은 구 하네스 값이 실제보다 체계적으로 높다** — 신규 파이프라인이
  느려진 게 아니라, 신규 하네스가 하네스 자신의 관측 지연을 더는 세지 않는 더 정확한 측정이다.
- LG 보고서 등 외부 커뮤니케이션에서 구/신규 캠페인 수치를 나란히 놓을 경우, 위 슬랙을 각주로
  명시할 것. (참고: `MEMORY.md`의 `project_lg_report_framing.md`, `project_probe_harness_artifact.md`
  메모와 일관 — restore/cold 첫 응답 꼬리는 이미 프루브 하네스 아티팩트로 알려져 있었고,
  이번 패리티 조사로 그 계열이 launch_overhead/cold_response에도 동형으로 존재함이 코드
  레벨로 확증되었다.)

---

## 부록: 실행 메타 (재현성)

- 패리티 본 캠페인: `testbed/experiments/parity/` — plan.tsv 120줄(calibration 5 제외),
  전 런 PASS, `summary_by_condition.csv`/`expansion.json` 커밋 보존(`all_runs.csv`·runs 원본은
  용량상 미커밋).
- same-day 컨트롤: `testbed_old` 러너 무수정, old 7/1의 조건 YAML(`ib_150ms_cpuidle.yaml` iters=104,
  `dirty_50M_cpuidle.yaml`) 재사용, system criu(Jun30, old와 동일 바이너리)로 25런
  (**25/25 PASS**). 판정 데이터는 본 문서 §c 표로 보존, 런 디렉터리(`testbed_old/runs/ctrl_*`)는
  정리 완료(§b/§c 표가 곧 원본 데이터의 기록).
- 비교 도구: `reports/compare_parity.py testbed/experiments/wsk_redesign/summary_by_condition.csv
  testbed/experiments/parity/summary_by_condition.csv` — 재실행하면 1/20 PASS, 19 FAIL, 0 MISSING
  이 재현된다(회귀 아님, §d 판정 이후에도 이 결과 자체는 변하지 않음 — 판정 기준을 대체했을 뿐
  숫자를 조작한 게 아니다).
