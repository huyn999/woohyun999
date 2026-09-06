# testbed/runner — 오케스트레이터 + 배치 + 분석

두 경로 러너(`run_once.sh`=restore, `run_cold_start.sh`=cold)가 `lib/`을 공유하고,
`run_campaign.sh`가 그 위에서 조건 sweep을 돈다. 설계 근거는
`docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` §5(모듈 경계)·§6(측정 불변식).

## lib/ — 두 러너 공용 모듈 (2+ 호출자 규칙)

각 모듈은 `<module>_<verb>` 함수를 정의만 하고(`source`), 실행은 러너의 `main()`이 순서대로
호출한다. 헤더 주석의 `uses:`/`sets:`가 전역 변수 계약이다.

| 모듈 | 함수 | uses | sets |
|---|---|---|---|
| `config.sh` | `config_load(run_id, yaml)`<br>`config_seed_result_meta()` | `TESTBED_DIR`, `RUNS_ROOT`(기본 `$TESTBED_DIR/runs`) | `RUN_ID` `RUN_DIR` `CG_PATH` `MEM_TIMELINE`(truncate까지) + `CFG_*`/`WL_*`(config.env 소싱) + `RESULT_KV[exp_id\|repeat_id\|kernel_version\|probe_interval_ms\|probe_timeout_s]` |
| `cgroup.sh` | `cgroup_join_self()` | `RUN_DIR` `CG_PATH` | 러너 자신을 `CG_PATH`에 join + `RUN_DIR/cgroup_home`에 원래 자리 기록(teardown 퇴거용) |
| `snapshot.sh` | `snap_take(tag, [with_meminfo])` | `TESTBED_DIR` `RUN_DIR` `CG_PATH` `MEM_TIMELINE` | `MEM_TIMELINE`에 라벨 스냅샷 append |
| `cleanup.sh` | `cleanup_register(fn)`<br>`cleanup_run_all()`<br>`cleanup_install_trap()` | - | `CLEANUP_FNS[]`, `EXIT` trap(등록 역순 실행) |
| `workload.sh` | `wl_launch()`<br>`wl_wait_phase(phase, timeout_s)`<br>`wl_kv(key)` | `WL_BIN` `WL_FLAGS` `RUN_DIR` `CG_PATH` | `WL_PID` `WL_LOG` `WL_PHASE_LINE` |
| `probe.sh` | `probe_first_response(pid, port, timeout_s)` | `PROBE_CPROBE`(기본 `runner/cprobe`) | `PROBE_RESP_TS` `PROBE_OK` |
| `stress.sh` | `stress_start_verified()`<br>`stress_warmup()`<br>`stress_stop()`<br>`stress_assert_alive()` — 측정 후 PASS 직전 루트 생존 재확인(런 중 stress 사망 → 무압박 PASS 방지) | `CFG_STRESS_*` `TESTBED_DIR` `RUN_ID` `CG_PATH` `RUN_DIR` | - (stress-*/README 참고) |
| `result.sh` | `result_set(k, v)`<br>`result_write(PASS\|FAIL, [fail_reason])` | `RUN_ID` `RUN_DIR` `MEM_TIMELINE` `WL_METRICS` `WL_PARAM_KEYS`/`WL_PARAM_*` | `RESULT_KV[...]`, `RUN_DIR/result.env` 작성 |

`workload.sh`는 **워크로드-무지**다 — YAML manifest를 읽지 않고 `WL_BIN`/`WL_FLAGS`(이미
`config_to_env.py`가 전개해 준 값)만 소비한다.

## 측정 창 불변식 (§6-1~6 요약)

`lib/probe.sh`의 `probe_first_response()`가 **cold·restore 유일한 측정 경로**다. 수정 시
스펙 §6-1~6을 반드시 재검토한다.

1. 창 내용은 두 경로에서 동일 함수(`probe_first_response`): `kill -0`(빌트인) → `cprobe` →
   `$EPOCHREALTIME`(빌트인) 반복. 성공 경로(이벤트→cprobe 성공→`PROBE_RESP_TS` 기록)엔 cprobe가
   유일한 외부 스폰이다. 폴 실패 사이의 `sleep 0.005`(항목 3, §6-3)도 외부 스폰이지만
   `PROBE_RESP_TS`는 성공 시 sleep 이전에 이미 찍혀 지표에 안 들어가고, cold/restore 양 경로가
   동일 메커니즘이라 편향 없음. `sed`/`awk`/`date`/`seq`/`grep` 등 다른 스폰 추가 금지.
2. probe는 기준 이벤트(cold: `wl_launch` 직후, restore: `criu restore` 완료 직후) **직후 즉시**
   시작한다. snapshot·`-v4` 로그 분해·`verify.sh`·result 기록은 전부 창 **밖(뒤)**.
3. 폴링 주기 5ms, 양 경로 동일. 폴 횟수(`timeout_s * 200`)는 `probe_first_response` 진입 시
   빌트인 산술로 1회만 계산(반복마다 재계산하지 않는다).
4. 러너 프로세스 자신도 대상 cgroup에 join한다(`cgroup_join_self`) — probe가 워크로드와 동일한
   memcg 압박을 받아야 공정.
5. `cprobe`는 **static 빌드**(동적 로더·libc major fault 제거) — python 스폰(구
   `request_probe.py`, 수십~수백ms) 대신.
6. `PONG` 응답은 고정 비용(`PONG\n` 5바이트) — 워크로드별 가변 작업을 싣지 않는다(계약 §4-A6).

## cprobe

`cprobe.c` — `cprobe <host> <port> [timeout_ms]`. loopback TCP로 `PING\n` 1회 보내고 `PONG`
확인, 성공 시 응답 줄 출력 후 exit 0, 실패(연결거부/타임아웃/형식불일치) 시 exit 1(러너 폴링
루프가 재시도). `gcc -O2 -static -o cprobe cprobe.c`로 이미 빌드돼 있다(`.gitignore`, 소스
변경 시 수동 재빌드).

## 두 러너

### `run_cold_start.sh --run-id <id> --config <yaml>`

측정 정의: `cold_response_s` = exec 직전 → PONG. 고유 단계(`lib/` 아님, in-file):
`step_prepare_binary`(제약 스토리지 위에 바이너리 복사 + fadvise DONTNEED),
`step_drop_caches`(sync + `drop_caches=3`), `step_resident_check`(VmRSS vs 선언 resident).
측정 창 4줄(`wl_launch` → `probe_first_response`)에는 코드 추가 금지.
`cgroup_join_self` 직후 `snap_take before_stress`(부하 전 baseline, run_once.sh와 공통 시점 —
old `MEM_CURRENT_BEFORE`와 동일; Task 18 스모크 회귀 Fix 1).

### `run_once.sh --run-id <id> --config <yaml> [--kdat-cache on|off]`

측정 정의: `restore_response_s` = `criu restore` 명령 시작 → 복원된 서비스의 첫 PONG. 고유 단계:
`step_kdat_init`(target 기동 *전* kdat 상태를 이 런의 축으로 확정 — dump도 같은 상태에서 시작하게
해 런 독립성 확보, 아래 참고), `step_warmup_pings`(`warmup_pings`회 PING, 측정 제외 — 계약 §4-A6
warm dump 의미론), `step_quiesce_and_dump`(`checkpoint_after_s` idle 대기 → `criu dump -v4` →
restore gap), `step_cache_policy`(drop_caches + image fadvise), `step_kdat_control`(kdat on/off
상태 재확정 — 아래 참고), `step_restore_and_probe`(★측정 창), `step_decompose_restore_log`(`-v4`
awk 분해, 창 밖), `step_verify_recovery`(L2 membership), `step_resident_check`.
`--kdat-cache`는 config.env의 `CFG_KDAT_CACHE`를 override한다.

**pre-ready dump** (계약 §4-A6): `dump_at`이 manifest `phases`에서 `ready`보다 **앞**이면
(예: initburst의 `init`) ready 대기·warm-up ping·`checkpoint_after_s` 대기를 전부 생략하고
그 phase 관측 즉시 dump한다 (소켓·연결이 없어 quiesce가 무의미하고, 기다리면 워크로드가
phase를 지나쳐 at-or-after 스큐만 커짐). restore 후 `restore_response_s`에는 **잔여 init
비용이 포함**된다 — 버그가 아니라 측정 대상("init 중간에 얼리면 얼마나 이득인가").
이때 `wl_*` 메트릭은 na(ready 미도달)로 남고, **`warmup_pings`/`checkpoint_after_s`는 config
echo(조건 메타)를 유지**한 채 실제 동작은 `warmup_pings_sent=0`·`checkpoint_wait_s=0`으로
기록된다 — 두 키를 실제값 0으로 덮어쓰면 cold(조건 echo)와 페어링 키가 어긋나 dump_at 혼합
캠페인의 pre-ready 페어가 전부 탈락한다(Codex 교차검토 합의).

**물리 한계 (F2)**: pre-ready dump은 `criu dump` 기동(kerndat+seize) 동안에도 타깃이 계속
달린다 — 그래서 **seize 지연(kdat warm ~4ms / cold ~50ms — F1 수정으로 축별 결정적)보다 짧은
init phase는 dump 시점에 이미 `ready`를 지나 있어 포착이 물리적으로 불가능**하다(라벨은
pre-ready인데 실제 freeze는 at-ready). 러너는 이걸 제거하지 못하므로 **정직하게 기록**한다:
dump 직후(freeze 상태, restore 재발행 전)에 `WL_LOG`에 이미 `PHASE ready`가 있으면
`dump_phase_missed=1`, 아니면 `0`(비-pre-ready 런도 `0`, 기록 없는 cold 등은 `na`).
주의: 워크로드 내부 자기계측(`compute_ms` 등)은 pre-ready dump에서 dump 전(pre-freeze)과 restore
후(post-restore) 두 구간으로 **분할 실행**된다. 다만 CRIU가 time namespace로 `CLOCK_MONOTONIC`을
보정하므로(`restore.log`의 `timens: monotonic ...` 라인 — 실측 확인됨) freeze 구간의 벽시계 갭
자체는 `compute_ms`에 **포함되지 않는다**. 그래도 분할 실행이라는 사실은 남으므로, 판단은
여전히 하네스 지표(`restore_response_s`)를 우선하고 `compute_ms`는 보조 참고로만 쓸 것.
`cgroup_join_self` 직후 `snap_take before_stress`(cold와 공통 시점), `step_kdat_control` 다음·
`step_restore_and_probe` 진입 전에 `snap_take before_restore`(반드시 `RESTORE_START_TS` 이전 —
측정 창 밖; old `run_once.sh:770`과 동일 시점, Task 18 스모크 회귀 Fix 1).

**kdat 제어 정확한 타이밍 (F1 — 런 독립성)**: kdat 축은 **두 지점**에서 확정된다.
1. `step_kdat_init`(target 기동 *전*, 측정과 무관한 초기 구간): off면 `/dev/shm/criu.kdat`을
   삭제해 **이 런의 dump가 cold-kdat에서** seize하게 하고, on이면 tmpfs 확인 후 `criu check`로 1회
   워밍해(이미 있으면 skip) **dump가 warm-kdat에서** seize하게 한다.
2. `step_kdat_control`(`step_cache_policy` 다음, `step_restore_and_probe` 직전): dump가 파일을
   재생성/보존했을 수 있어 restore 직전 상태를 **재확정**한다 — off면 다시 삭제(cold restore),
   on이면 이미 warm이면 skip(중복 `criu check` 회피).

왜 둘 다 필요한가: 예전엔 `step_kdat_control`만 있어 kdat 상태를 dump *후*에만 맞췄다 — 그래서
이 런의 dump가 **직전 런이 남긴 kdat 상태를 물려받아**(런 간 전역 상태 누수) `dump_time_s`가 이웃
런의 kdat 축에 따라 ±33ms 계통 편향되고 seize 시점도 4~50ms 출렁였다. `step_kdat_init`이 dump까지
같은 축으로 끌어와, 한 런 안에서 dump와 restore가 **동일한 kdat 상태**(off=cold, on=warm)를 보게 한다.
`/dev/shm`이 tmpfs가 아니면 on은 (init에서) 즉시 FAIL(CRIU가 non-tmpfs엔 캐시 보존을 거부하므로).
캐시 경로는 `testbed/criu/kdat-shm.patch`가 만든다(`testbed/criu/README.md` 참고). kdat probing
절대값은 런 간 최대 3배까지 출렁이므로 **paired delta로만 비교**한다(절대값 비교 금지).

`restore`는 host filesystem의 `WL_BIN`을 그대로 exec한다(cold처럼 제약 스토리지에 복사하지
않는다) — 복사하면 그 실행 파일 매핑이 dm-delay 스토리지를 가리켜 restore가 페이지를 그 위에서
채워야 하므로 `restore_response`가 부풀고 cold/restore 대응 비교의 패리티가 깨진다.

`run_once.sh`(cold는 CRIU를 아예 쓰지 않는다)는 `criu/build.sh`가 만든
`testbed/criu/bin/criu`를 명시적으로 쓴다(`CRIU_BIN` env로 override 가능). 없으면 "먼저
build.sh를 실행하라"는 에러로 즉시 중단한다.

## result.env 스키마

`lib/result.sh`가 공통 키(old wsk_redesign CSV와 호환: `cold_response_s`/`restore_response_s`/
`restore_time_s`/`kdat_probing_s`/`restore_work_s`/`launch_overhead_s`/`kdat_ratio`/
`memory_peak_bytes`/`oom`/`oom_kill`/`generic_recovery` 등)에 더해 신규 키
(`dump_phase`, `dump_phase_missed`, `warmup_pings`, `warmup_pings_sent`, `checkpoint_wait_s`,
`criu_version`, `criu_patch_sha`, `resident_mismatch`, `resident_rss_bytes`)를 방출한다.
`warmup_pings`/`checkpoint_after_s`는 **config echo(조건 메타, cold도 기록 — 페어링 키)**,
`warmup_pings_sent`/`checkpoint_wait_s`는 **실제 동작**(pre-ready dump에선 0/0, restore 전용)이다. `dump_phase_missed`는 pre-ready dump이
seize 창보다 짧은 init을 놓쳤으면 `1`, 아니면 `0`(비-pre-ready 런도 `0`), 기록 없으면 `na`(F2). 워크로드 메트릭은 manifest의 `metrics`에 선언된 이름마다
`wl_` 접두로 붙는다(예: `wl_checksum`, `wl_compute_ms`) — runner 키와의 충돌을 원천 차단한다.
병합된 workload 파라미터는 manifest `params`의 이름마다 `wl_param_` 접두로 붙는다(예:
`wl_param_bytes`, `wl_param_port`; hardening v2 §3, `WL_PARAM_KEYS` 순회로 방출 — additive-only).
값이 없는 키는 전부 `na`. **의도적 na 고정 키**(이식 대응물이 없어 영구히 `na`로 남는 것 —
값이 실재하는데 안 채운 게 아니다):

- `cold_launch_s`/`cold_ready_s` — old는 이 둘을 측정 창 안의 추가 폴링(PID/exe 관측,
  `WORKLOAD_READY` grep)으로 얻었는데, 새 설계는 그 관측을 `probe_first_response` 하나로
  흡수했고 측정 창 안에 스폰을 더 넣는 건 불변식 위반이라 포기했다(컨트롤러 승인 사항,
  DONE_WITH_CONCERNS로 기록됨).
- `task_visible_s` — old는 restore 중 `DUMPED_TARGET_PID`가 cgroup에 처음 보이는 시점을
  창 안에서 폴링해 얻었다. 새 설계는 `RESTORED_PID`를 `criu restore --pidfile`에서 읽고
  그 창 내 폴링 자체를 없앴다(§6-1~2 창 내 추가 폴링 금지) — 대응물 없음.
  (run_once.sh `step_restore_and_probe` 헤더 주석 참고.)
- `probe_attempts`/`first_success_attempt` — old의 폴링 횟수 카운터. 새
  `probe_first_response`는 시도 횟수를 세지 않는다(Task 18 스모크 회귀 Fix 3, 대응물 없음).
- legacy old 스키마 키 `target_bytes`/`dynamic_mode`/`dynamic_dirty_bytes`/
  `dynamic_interval_ms`/`dynamic_init_work_ms`/`compute_iters`/`compute_ms` — old의
  `run`/`workload` 섹션(고정 워크로드 파라미터 하드코딩) 잔재다. 새 스키마는 이걸 workload
  manifest 병합 + `wl_*` 메트릭(예: `wl_compute_ms`)으로 대체했다(`config_to_env.py` 상단
  주석 참고) — CSV 열 호환을 위해 컬럼 자체는 남기되 항상 `na`.

그 외 na는 전부 "값이 실재하면 채워지는" 키다 — 예: `memory_current_before`/
`memory_current_after_stress`/`restore_peak_current`는 `result_write`가 `MEM_TIMELINE`의
`memstat_before_stress_current`/`memstat_after_stress_warmup_current`/
`memstat_after_restore_current`를 grep해 채운다(그 라벨의 `snap_take`를 안 부르는 경로,
예: cold의 `after_restore`에서만 na로 남는다 — 렌즈4 F3). `criu_dump_log`/`criu_restore_log`
(run_once 전용)와 `target_log`(양 러너)도 각각 `dump.log`/`restore.log`/`workload.log`의
실제 경로로 채워진다(창 밖 bookkeeping에서 `result_set`).

`memory_peak_bytes`/`oom`/`oom_kill`은 `result_write` 시점에 `CG_PATH`(살아있는 cgroup)의
`memory.peak`/`memory.events`를 직접 읽는다 — `env/teardown.sh`가 cgroup destroy 직전에
`RUN_DIR`로 복사해두는 스냅샷을 읽는 게 아니다(그 복사는 `result_write`보다 항상 나중인
EXIT trap에서 일어나 신선한 런에선 늘 `na`였다 — Task 18 스모크 회귀 Fix 2). `exp_id`/
`repeat_id`(`RUN_ID`의 마지막 `_repNN` 토큰에서 유도)·`kernel_version`(`uname -r`)·
`probe_interval_ms`/`probe_timeout_s`(고정 상수 5ms/0.300s)는 `config_seed_result_meta`가 채운다.

`resident_mismatch`(§4-B 선언 정직성)는 cold/restore가 방향이 다르다: cold는 프로세스가
직접 그 바이트를 만들어 즉시 상주시키므로 양방향 가드, restore는 CRIU의 lazy fault-in
(페이지가 restore 시점에 한꺼번에 매핑되지 않고 접근 시 fault-in) 때문에 선언값 **미만이
정상**이라 편도(one-sided, 초과만) 가드다(렌즈4 F6). 문턱은 두 경로 모두
**max(선언의 10%, 절대 4MiB)** — 상대 10%만 쓰면 MiB급 소형 선언에서 고정 잡음이 상시
오탐을 만들어 가드가 죽는다(실측: crossover2 cold 140/140 mismatch=1, 절대 하한으로 수정).
가드의 목적이 Option B absorb 산식(절대 바이트) 보호라 절대 하한이 의미에 맞다.

**주의(압박 조건 리포트 각주 의무, PLAN.md §4)**: restore는 criu 자신의 메모리(이미지 read+
프로세스 재구성, 실측 peak ≈ 워크로드의 2배)도 같은 cgroup 예산(`CG_PATH`, 위 `memory_peak_bytes`/
`oom`이 읽는 그 cgroup)에 계상한다 — 압박 조건에서는 restore만 reclaim/OOM에 더 노출된다.
버그가 아니라 "LG도 같은 cgroup에서 CRIU를 돌린다"는 설계 의도의 실제 비용이므로, 압박 조건
결과를 리포트할 때는 이 사실을 각주로 명시할 것.

## 캠페인 (`run_campaign.sh <campaign.yaml>`)

`<campaign.yaml>`은 임의 경로 인자다(스크립트가 강제하는 고정 위치 없음) — 관례는
`testbed/configs/campaign_<이름>.yaml`에 손으로 쓰는 것이고, 실제 예가 그 디렉터리에 있다
(`campaign_parity.yaml`, `campaign_crossover2.yaml`). 문법은 아래 "campaign YAML 예시로
배우기" 참고. (old `wsk_redesign`의 `testbed/runs/_cfg_<name>/`는 손으로 쓴 스펙이 아니라
당시 전개 산출물이다.)

```bash
testbed/runner/run_campaign.sh configs/campaign_foo.yaml
SMOKE=1 testbed/runner/run_campaign.sh configs/campaign_foo.yaml   # reps=1 + 워크로드당 대표 1셀
YES=1   testbed/runner/run_campaign.sh configs/campaign_foo.yaml   # expand_campaign.py 확인 프롬프트 생략
RUN_TIMEOUT=360 testbed/runner/run_campaign.sh configs/campaign_foo.yaml   # 런당 timeout(초, 기본 360)
```

캠페인은 **한 번에 하나만** 돈다 — `runs/.campaign.lock`(flock)이 강제한다. 동시 실행은 포트
충돌(시끄럽게 죽음) 외에도 drop_caches·cpufreq clamp·`/dev/shm/criu.kdat` 같은 호스트 전역
상태를 서로 *조용히* 오염시키기 때문. `RUNS_ROOT` override도 거부된다(env/hardware가
canonical `testbed/runs/<run_id>`를 재계산하는 구조와 정합).

흐름:

1. **PHASE 1 calibration** — campaign의 워크로드 sweep에 `calibrate_from_ms`가 있으면(현재:
   `initburst`), `CALIB_ITERS=(50 200 500 1000 1800)`(SMOKE는 `(200 800)`)로 cpu-idle cold 런을
   돌려 `<param> → <metric>` 표본을 모으고 선형 fit(`a·<param>+b`)으로 목표 ms들을 param 값으로
   환산한다. 표본 <2개거나 기울기 ≤0이면(구 워크로드별 매직 상수 fallback 대신) 즉시 die.
   **calibration param/metric은 manifest의 `calibration.param`/`calibration.metric`에서 읽는다**
   (hardening v2 §2) — fit 루프가 `wl_<metric>`(예: `wl_compute_ms`)를 읽고, sweep.param과
   manifest `calibration.param`이 다르면 `expand_campaign.py`가 전개 시점에 die한다. calibration
   run_id도 캠페인 접두(`<campaign>_calib_<wl>_<param>_it<it>`)를 단다.
2. **PHASE 2 expand** — `expand_campaign.py`가 campaign YAML을 `plan.tsv` + `configs/<run_id>.yaml`
   + `expansion.json`으로 전개(아래 참고). 총 런 수 + 예상 소요시간을 출력하고 확인받는다
   (`--yes`/`YES=1`로 생략 가능) — 조용히 시작하지 않는다.
3. **PHASE 3 실행** — `plan.tsv`를 순회하며 각 줄을 `timeout -k 30 $RUN_TIMEOUT`으로 감싸
   `run_cold_start.sh` 또는 `run_once.sh --kdat-cache <kd>`를 실행한다. 실패는 `fails.txt`에 기록.
4. **PHASE 4 finalize** — main과 calibration을 분리 수집한다(hardening v2 §2). `run_ids.txt`는
   `plan.tsv`의 rid열(본 sweep)만 담고 → `all_runs.csv`(main 전용) → `summarize.py` →
   `summary_by_condition.csv`. calibration 런은 `calibration_run_ids.txt` → `calibration_runs.csv`로
   **따로** 수집한다(main all_runs.csv/summary/조건 median에 미포함). 둘 다 `collect.py`가
   run_id manifest로 캠페인 스코프를 필터링한다. `EXIT` trap에도 걸려 있어(once 가드) Ctrl-C로
   중단해도 그때까지 끝난 런은 롤업된다.
5. **PHASE 5 요약** — 총/PASS/FAIL을 항상 로그에 출력(침묵 스킵 금지).

산출물은 `testbed/experiments/<campaign-name>/` 아래: `plan.tsv`, `configs/<run_id>.yaml`,
`expansion.json`, `progress.log`, `fails.txt`, `calibration_fails.txt`,
`calibration/{configs,*_points.txt,*_fit.txt}/`, `run_ids.txt`(main만), `all_runs.csv`(main만),
`summary_by_condition.csv`(main만), `calibration_run_ids.txt` + `calibration_runs.csv`(calibration
분리 산출물)(`SMOKE=1`이면 캠페인명에 `_smoke` 접미).

**run_id 접두(namespace, hardening v2 §1)**: expand된 모든 run_id는 `<campaign>_`로 시작한다
(예: `parity_dirty_cpubusy_koff_rep03`). 이는 "값이 변하는 축만 토큰화" 규칙(§4-C-2-4)의 유일한
예외 — 접두는 축이 아니라 캠페인 간 이름공간이라 캠페인이 단일값이어도 항상 붙는다. 덕분에 서로
다른 캠페인의 run_id가 구조적으로 겹치지 않아 `runs/` 덮어쓰기·summarize median 오염이 원천
차단된다(summarize의 조건 가드는 2차 방어선). 캠페인명은 `^[a-z0-9_-]+$`여야 하고, 최종 run_id가
100자를 넘으면(cgroup/dm/파일명 안전) expand가 die한다. `SMOKE=1`은 캠페인명에 `_smoke`를 붙여
(`parity_smoke_...`) 본 캠페인 run_id와 겹치지 않게 한다.

### campaign YAML 예시로 배우기

> **전체 저작 가이드는 `testbed/configs/README.md`** — 스키마 레퍼런스 전부, 런 수 계산 공식,
> 레시피 5종(크기/연산량/준위/dump시점/자유축), 설계 체크리스트, 산출물 읽기, top-up 절차까지.
> 아래는 그 축약판이다.

**최소 예시** — dirty의 상주 크기를 30→70MiB로 sweep, cpu·kdat 전 조합, 10반복:

```yaml
# testbed/configs/campaign_dirty_sweep.yaml
campaign: dirty_sweep          # run_id 접두 + experiments/<이름>/ 디렉터리 (^[a-z0-9_-]+$)
reps: 10                       # 셀(조건 조합)당 반복 횟수
stress: {target_total_mib: 1278, workers: 29}   # 배경 점유 총량(MiB)·인스턴스 수 (Option B absorb)
axes:
  cpu: [busy, idle]            # 내장 축 — 배경 부하가 허용 코어를 saturate하는가
  kdat: [on, off]              # 내장 축 — restore 전 kerndat 캐시 재사용 (restore 런에만 적용)
workloads:
  - name: dirty                # workloads/<name>/ 디렉터리명
    sweep: {param: bytes, values_mib: [30, 40, 50, 60, 70]}   # MiB → bytes 자동 환산
    dump_at: [served_first]    # dump 시점 phase (manifest phases 중 하나; 여러 개면 축이 된다)
```

```bash
tmux new -s camp   # 밤새 캠페인은 반드시 detach 가능한 세션에서
YES=1 testbed/runner/run_campaign.sh testbed/configs/campaign_dirty_sweep.yaml
```

이것만으로: 5값 × 2cpu × 10rep = cold 100런 + restore 400런(× kdat 2)이 전개·실행되고,
`experiments/dirty_sweep/summary_by_condition.csv`에 조건별 median/CI가 모인다. run_id는
`dirty_sweep_dirty_30M_cpubusy_koff_rep01`처럼 **값이 변하는 축만** 이름에 박힌다.
vm_workers/vm_bytes는 손대지 않는다 — `target_total_mib − 워크로드 resident`를 `workers`로
나눠 셀마다 자동 재계산된다(absorb).

**값 표현식 3형** — `values`/`values_mib`/자유 축 `values` 어디든 동일:

```yaml
values: [50, 100, 200]                   # 명시 리스트
values: {from: 30, to: 70, step: 10}     # 등차 → 30,40,50,60,70
values: {from: 50, to: 800, factor: 2}   # 등비 → 50,100,200,400,800
```

**연산량 sweep(initburst)** — "몇 ms짜리 초기화"로 선언하면 PHASE 1 calibration이 iters로 환산:

```yaml
workloads:
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [50, 100, 200, 400]}
    dump_at: [served_first]
```

**stress 메모리 준위 축** — memory.max는 고정한 채 배경 점유량만 축으로 흔든다:

```yaml
campaign: memlevel
reps: 10
stress: {target_total_mib: 1278, workers: 29}   # 기본값 — calibration은 이 조건(cpu-idle)에서 fit
axes:
  cpu: [idle]
  kdat: [on, off]
  mem: {key: stress.target_total_mib, values: {from: 1150, to: 1550, step: 100}}
workloads:
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [100]}
    dump_at: [served_first]
```

- run_id에 `mem1150`…`mem1550` 토큰이 붙고, 준위별로 vm_bytes가 자동 재계산된다.
- **준위 하한 = resident + workers×38MiB** (29워커 ≈ 1140MiB) — 미달이면 expand가 즉시 die.
  더 낮은 준위는 **별도 캠페인**에서 `workers: 10`(하한 ≈ 415MiB)처럼 줄여서 연다. 한 캠페인
  안에서 workers와 준위를 같이 흔들면 "점유량"과 "프로세스 수"가 교란되므로 금지 습관.
- 상한은 memory.max − (타깃 resident + CRIU peak(≈워크로드 2배) + 여유 ~100MiB) 감각으로 —
  넘치면 타깃이 OOM 희생자가 되어 FAIL로 기록된다(`oom_kill` 컬럼으로 사후 확인).
- 그래프 x축은 raw 준위보다 **headroom = memory.max − 준위 − resident**가 물리적으로 정직하다.
- 자유 축 key는 임의 config 키 가능(`memory.max`, `checkpoint_after_s`, `workload.params.<p>`…)
  — 오타는 전개 시점 die. `stress.target_total_mib`/`stress.workers`만 config에 쓰이지 않는
  absorb 입력 특례다(값 int 필수).

**dump 시점 축** — pre-ready dump와 warm dump 비교:

```yaml
    dump_at: [init, served_first]    # run_id에 dinit/dserved_first 토큰
```

**돌리기 전 습관**: ① `SMOKE=1`로 워크로드당 대표 1셀 먼저(수 분), ② expand가 출력하는
`PLAN: N runs, est ~X h`를 보고 규모 확인(`--est-run-s`는 직전 캠페인 실측으로 보정), ③ 본
실행은 tmux에서.

## python 도구

- **`config_to_env.py <config.yaml>`** — 조건 YAML(+workload manifest 병합)을 flattened env로
  낮춘다(`CFG_*`/`WL_*`). YAML 파싱은 이 파일만 한다(bash로 새지 않는다). 4종 설계 시점 검증:
  ① manifest `name` == 디렉터리명 ② `workload.params` ⊆ manifest `params` ③ `dump_at` ∈
  manifest `phases` ④ `resident` 필드 정합. phase/metric/param 이름은 `^[a-z0-9_]+$` 강제.
  병합된 workload 파라미터를 `WL_PARAM_KEYS`(공백 구분, 정렬 고정) + `WL_PARAM_<대문자>`(각 값)로도
  방출한다(hardening v2 §3 — `result.sh`가 `wl_param_<name>` 키로 기록). 미지 top-level 섹션/키는
  `exit 2`(구조 오류), manifest 병합 실패는 `exit 1`(설계 오류).
- **`expand_campaign.py <campaign.yaml> <out_dir> [--resolve wl.param=v1,v2,...] [--yes]`** —
  값 표현식(`[..]` / `{from,to,step}` / `{from,to,factor}`) 정규화, 자유 축(임의 config 키 sweep),
  cold 중복 제거(cold는 workload×param×환경축당 1회만 — dump_at/kdat과 무관), restore는
  `dump_at × kdat` 조합마다 생성, 포트는 `18100`부터 런마다 서로소 배정. run_id는 캠페인 접두
  `<campaign>_` + 값이 변하는 축만 토큰화(`parity_dirty_cpubusy_koff_rep03`) — 접두는 namespace
  예외(위 "run_id 접두" 참고), 캠페인명 `^[a-z0-9_-]+$`·run_id ≤100자 검증. `calibrate_from_ms`
  워크로드는 sweep.param이 manifest `calibration.param`과 다르면 die. `stress.target_total_mib −
  resident`를 `stress.workers`로 나눈 값이 인스턴스 floor(38MiB) 미만이면 설계 시점 에러(Option B
  absorb 가드). **stress 준위 축**: 자유 축 key로 absorb 입력 2종(`stress.target_total_mib`/
  `stress.workers`)을 주면 config 키로 쓰이지 않고 absorb 계산에만 반영된다 — memory.max는
  base 고정한 채 stress 점유 준위(또는 인스턴스 수)를 축으로 여는 실험용. 예:
  `axes: {mem: {key: stress.target_total_mib, values: {from: 1150, to: 1500, step: 50}}}`
  (값은 int 강제 — float면 die). 준위 하한 = `resident + workers×38MiB`(29워커면 ≈1106MiB+resident)
  — 더 낮은 준위가 필요하면 **workers를 줄인 별도 캠페인**으로 연다. 준위 비교엔 workers
  고정이 정석: 총량 고정 시 N 파티션은 steady 압박·CRIU 천장에 동치임이 실측됐지만(근거는
  `stress/README.md` "워커 수 N" 절), N은 배경 프로세스 수라는 조건의 일부고 통제변인은
  공짜로 고정할 수 있을 때 고정하는 것이다. 그 밖의 자유 축
  key는 config_to_env 스키마 상수로 전개 시점에 검증된다(오타 → 즉시 die; 이전엔 PHASE 3 전
  런이 늦게 죽었다). calibration(PHASE 1)은 축 미적용 — campaign `stress:` 기본값·cpu-idle
  조건에서 fit한다. 주의: `sweep.calibrate_from_ms`를 쓰는 워크로드(`initburst`)를 이 스크립트만 단독
  실행하려면 `--resolve wl.param=v1,v2,...`가 반드시 필요하다(안 주면 die) — `run_campaign.sh`는
  PHASE1 calibration이 이 값을 자동으로 채워 넘긴다.
- **`collect.py [runs_dir] [run_id_manifest]`** — `runs/*/result.env`를 union-of-keys CSV로.
  새 워크로드의 `wl_*`/`wl_param_*`이나 `dump_phase` 같은 키도 이 파일을 고치지 않아도 자동 수집된다.
  `run_id_manifest`(선택, 캠페인 스코프 필터)를 주면 그 run_id들만 담는다 — `RUNS_ROOT`가
  캠페인 간 공유 디렉터리라 안 주면 다른 캠페인/수동 테스트 런까지 섞인다.
- **`summarize.py [all_runs.csv]`** — `(exp_id, condition, dump_phase)`별 median/p95/bootstrap
  median 95% CI(`BOOTSTRAP_RESAMPLES=2000`, 고정 seed). `condition`은 run_id에서 끝의
  `_rep<NN>`만 제거해 만든다(`run_name()`이 `rep{NN}`을 항상 마지막 토큰으로 붙이므로).
  `restore_n`은 `result.env`의 `runner == "restore"`로 판정한다. 조건 균일성 가드에는
  CSV에 실재하는 `wl_param_*`(단 `wl_param_port` 제외)을 동적으로 더한다(hardening v2 §4 — 구
  CSV엔 그 열이 없어 기존 통과 유지).
- **`compare_cold_restore.py <all_runs.csv> <out_dir>`** — main all_runs.csv에서 cold/restore를
  `[workload, 환경 조건 컬럼(summarize CONDITION_COLS와 동일 집합, kdat_cache 제외), wl_param_*(port
  제외), repeat_id]`로 짝지어 `delta = restore_response − cold_response`를 낸다(hardening v2 §5).
  `paired_runs.csv`(쌍별 delta + kdat_cache/dump_phase/repeat_id 라벨)와
  `comparison_by_condition.csv`((cold조건, kdat_cache, dump_phase)별 pair수·median delta·bootstrap
  95% CI·winner)를 쓴다. CI/seed는 `summarize.py`의 `median_ci`를 import해 재사용한다. `delta<0`이면
  restore 우세, `delta>0`이면 cold 우세. repeat_id가 없는 cold(calibration 등)는 페어링에서 제외,
  missing cold는 스킵+stderr 집계, 같은 키 cold 2개는 die. `wl_param_*` 열이 없는 구 CSV는
  메타데이터만으로 fallback.

## 그 외

- **`mem_snapshot.sh <cg_path> <label> <out_env> [with_meminfo]`** — cgroup `memory.stat`/
  `memory.current`/`memory.peak` + (선택) `/proc/meminfo`를 라벨 붙여 `out_env`에 append.
  `lib/snapshot.sh`의 `snap_take`가 감싼다.
- **`fadvise_dontneed.py <file>...`** — 파일에 `POSIX_FADV_DONTNEED`를 best-effort로 적용
  (cold의 바이너리 복사본, restore의 image 파일에 사용 — page cache 이득 배제).

## 단발 실행 예시

```bash
testbed/criu/build.sh          # 최초 1회 (또는 criu 버전 갱신 시)
testbed/workloads/build.sh     # 워크로드 재빌드 필요 시

testbed/runner/run_cold_start.sh --run-id demo_cold    --config testbed/scenario.yaml
testbed/runner/run_once.sh       --run-id demo_restore --config testbed/scenario.yaml --kdat-cache off
```

둘 다 `sudo`(또는 root)가 필요하다 — `env/setup.sh`가 cgroup v2를 만들고 조작한다.
