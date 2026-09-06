# 측정 불변식 20개 1:1 감사 — testbed 전면 재작성 (branch: testbed-rewrite)

- 대상 스펙: `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` §6 (불변식 1~20)
- 감사 방식: 재작성 코드를 **직접 열어 라인 확인** (레저/리포트 재인용 없음). 창 안 스폰은 §Step2 strace로 기계 검증.
- 판정 요약: **PASS 20 / 20** (원 감사 시점: PASS 19/20, FAIL 1 — §6-16 검증 사다리). §6-16 FAIL은
  후속 수정 태스크에서 해소됐다 — 상세는 표 아래 "§6-16 FAIL 상세" + "§6-16 FIX (재검증)".
- 감사일: 2026-07-04 (감사자: Task 19). 코드는 수정하지 않는다(감사만). FAIL 수정은 컨트롤러가 별도 태스크
  파견(수정 리포트: `.superpowers/sdd/task-19-report.md` "Fix report (invariant §6-16)").

## 판정 표

| # | 판정 | 증거(file:line) + 한 줄 설명 |
|---|---|---|
| 1 | PASS | `runner/lib/probe.sh:8-25` — 단일 함수 `probe_first_response`를 restore(`run_once.sh:207-213`)·cold(`run_cold_start.sh:131-133`)가 공유. 창 내용: `kill -0`(빌트인, :15) → `cprobe`(유일한 스폰, :16) → `$EPOCHREALTIME`(빌트인, :18). sed/awk/date/seq/grep 없음. strace(§Step2)로 창 안 execve = cprobe + `/usr/bin/sleep`(5ms 페이싱)뿐임을 확인. **뉘앙스**: `sleep`은 외부 스폰이지만 브리프 strace 필터가 화이트리스트하고 §6-3의 5ms 페이싱 기본자라 허용 대상이며, 성공→timestamp 경로엔 절대 끼지 않는다(성공 시 sleep 전에 break, :20-21). |
| 2 | PASS | `runner/run_once.sh:207-214` — 측정 창(RESTORE_START_TS…probe) 직후 `# ---- 창 밖 ----`로 snapshot/decompose/verify/result 분리. `run_cold_start.sh:130-134` 동일(창 4줄 → `# ---- 창 밖: bookkeeping ----`). `-v4` awk 분해는 `run_once.sh:237-256`(창 밖 별도 step). |
| 3 | PASS | `runner/lib/probe.sh:10` `polls=$((timeout_s*200))` — 함수 진입 시 bash 산술 1회 계산(스폰 아님; 컨트롤러 §6-3 판례). 폴 간격 `sleep 0.005`(:23). strace-B: 데드 포트 1s → 정확히 200 cprobe + 200 sleep = 5ms 주기 실측. |
| 4 | PASS | `runner/lib/cgroup.sh:4-11` `cgroup_join_self`(러너 PID를 `$CG_PATH/cgroup.procs`에 write) — restore `run_once.sh:310`·cold `run_cold_start.sh:117`에서 호출. teardown이 원래 자리로 퇴거(`env/teardown.sh:63-87`, cgroup_home 복귀). |
| 5 | PASS | `ldd testbed/runner/cprobe` → `not a dynamic executable`(static 확인). 소스 빌드 규약 `runner/cprobe.c:11` `-static`. 바이너리 825KB(정적 링크 크기). |
| 6 | PASS | `workloads/common/probe_server.h:55` `write(c, "PONG\n", 5)` — 고정 5바이트, 가변 페이로드 없음. 3개 워크로드 모두 이 헬퍼 사용(체크섬 등 미탑재). |
| 7 | PASS | `runner/run_once.sh:129-140` `step_cache_policy`: `sync`(:131) → `echo 3 > /proc/sys/vm/drop_caches`(:133). main에서 dump(`:326`) **다음**·restore 전(`:327`)에 호출. image fadvise DONTNEED까지 이어짐(:149-162). |
| 8 | PASS(코드) | `runner/run_once.sh:170-196` `step_kdat_control`: off=`rm -f /dev/shm/criu.kdat`(:175), on=`criu check` 워밍 후 존재확인·보존(:183-188). main 배치: cache_policy 다음·restore 직전(`:328`) = 실제로 "dump 후·restore 직전 삭제"(dump가 kdat 재생성하므로 이 타이밍이라야 restore가 cold; old 동일). **스펙 §6-8 문구는 본 태스크에서 "dump 후·restore 직전 삭제"로 수정함**(컨트롤러 판례). paired-delta 비교는 분석 규율(`runner/README.md:79` 명문화), 코드 강제 대상 아님. |
| 9 | PASS | `runner/run_once.sh:237-256` `step_decompose_restore_log` — restore.log(`-v4`) awk 파싱으로 `kdat_probing_s`/`restore_work_s`/`launch_overhead_s` 산출(:249-251), 창 밖(main `:334`). `restore_time_s`=RESTORE_END−START(:238-239). |
| 10 | PASS | `runner/expand_campaign.py:186-197` `make_cell`: `total_bytes = target_total_mib*MiB − resident`(:186), `per_worker = total//workers`(:187), 워커 수 고정(`campaign["stress"]["workers"]`), floor 하한 가드(:189-195). `configs/campaign_parity.yaml:2` `target_total_mib:1278, workers:29`. resident는 config_to_env 재사용(:183-184)으로 sweep과 동일 계산. |
| 11 | PASS | 일=iterations: `workloads/initburst/workload.c:86` `for(it<compute_iters)`, `dirty` `--bytes`; 시간은 실측 보고 `initburst:89,93` `compute_ms`. calibration cpu-idle: `runner/run_campaign.sh:135` `make_cell(..., "idle", ())` 고정, 선형 fit `fit_iters:145-175`. (그림 x축 라벨링은 리포트 영역 — 코드 범위 밖.) |
| 12 | PASS | phase 기반 트리거만: `runner/run_once.sh:325` `wl_wait_phase "$CFG_DUMP_AT"`(문자열 매칭, 시간 기반 없음). quiesce: warmup 요청은 요청당 즉시 close(`probe_server.h:57`) + `checkpoint_after_s` idle 대기(`run_once.sh:66-72`)로 dump 시점 established 연결 0. |
| 13 | PASS | `stress/start.sh:167-182` — oom_score_adj를 `cgroup.procs` 전 PID에 반복 적용하는 **while loop-until-stable**(unprot==0까지, deadline `SECONDS+8`). 고정 횟수 sweep 아님. |
| 14 | PASS | `env/hardware/cpufreq.sh:76` cpuset 없으면 거부(전역 clamp 금지); apply가 orig를 mutation 전 저장(:88-98). teardown 무조건 원복 `env/teardown.sh:43`(가장 먼저, best-effort). setup 적용 `env/setup.sh:68-70`(cpuset 필수 분기). |
| 15 | PASS | CRIU 이미지 제약 스토리지: `env/hardware/storage.sh:277` data_dev(loop+dm-delay)를 `IMAGE_DIR`에 mount, dump/restore `-D "$IMAGE_DIR"`(`run_once.sh:88,209`). 타깃 바이너리: cold가 `IMAGE_DIR/app`에 복사(`run_cold_start.sh:26-41`). restore는 host fs exec(컨트롤러 판례: §6-15 타깃 바이너리 조항은 cold 전용 관심사, Task 13 리뷰). |
| 16 | PASS | (수정 후 재검증) canary preflight를 두 러너 모두에 복원 — `runner/run_once.sh:319`, `runner/run_cold_start.sh:125` (둘 다 env verify 후·stress 전, old 호출 위치 그대로; 실패 시 `result_write FAIL "canary preflight failed"`). cold에 L2 membership 신설 — `runner/run_cold_start.sh:90-98` `step_verify_recovery`(측정 창 밖, probe 성공 후 bookkeeping에서 호출, `:143`), `generic_recovery` yes/no 확정. cold의 env setup/verify에 `run_once.sh`와 동형 가드 추가 — `run_cold_start.sh:114,116` (`\|\| { result_write FAIL …; exit 1; }`). 실측 재검증: cold+koff 각 1런 PASS(`generic_recovery=yes`, 콘솔에 `[membership] OK: canary …`/`[membership] OK: cold target …`), 고의 실패(존재하지 않는 cpuset `97-98`) 주입 시 result.env에 `result=FAIL fail_reason="env setup failed"` 기록 확인(이전엔 NO_RESULT_ENV로 뭉뚱그려짐). 상세는 하단 "§6-16 FIX (재검증)". |
| 17 | PASS | `runner/lib/result.sh:47-134` old 공통 키 스키마 유지 + `dump_phase`(:120) 신설. wl_ 접두(:129-131). summarize 그룹 키 `(exp_id, condition, dump_phase)`(`summarize.py:132`). collect union-of-keys(`collect.py:104-107`). `cold_launch_s`/`cold_ready_s`는 **키 존재·값 na·컨트롤러 승인**(`result.sh:86-87` 기본 na, `run_cold_start.sh:12-17` 의도적 생략, `runner/README.md:97-101`). |
| 18 | PASS | `runner/run_once.sh:295-296` `CRIU_BIN="${CRIU_BIN:-$TESTBED_DIR/criu/bin/criu}"` (override 허용) + `[[ -x ]] || { "…build.sh 먼저 실행"; exit 1; }`. dump/restore/kdat/version 모두 `$CRIU_BIN` 사용. (cold는 criu 미사용.) |
| 19 | PASS | fflush 의무: `probe_server.h:61` served_first 직후 fflush; 각 워크로드 PHASE ready 직후 fflush(`simple:24`, `dirty:75`, `initburst:80,94`). `workloads/README.md:36-38` 계약 조문화. |
| 20 | PASS | 측정 런 port 명시 배정: `expand_campaign.py:312-319`(cold), `:328-336`(restore) 매 런 `PORT_BASE+idx` 서로소 배정, 유일성 가드(:356-358). workload.yaml 기본 `port:0`은 수동 단발 전용. cold 창은 `WL_PORT`로 connect-재시도(`run_cold_start.sh:133`), 로그 파싱 없음. |

## §6-16 FAIL 상세

스펙은 검증 사다리를 **4룽**으로 규정한다: `L1 readback → canary preflight → L2 membership → 기능 회생(PONG)`
(§3 인벤토리 design doc:131, §6-16 design doc:356). §3 "버릴 것"(design doc:142)이 폐기를 명시한 것은
**generic recovery의 이원화 검증 하나뿐**(PONG 필수화로 대체) — canary preflight·L2 membership은 폐기 목록에 없다.
스펙/브리프/리포트 어디에도 preflight 폐기의 승인 기록이 없다(전 문서 grep 확인).

재작성 코드의 실제 사다리:

| 룽 | restore(`run_once.sh`) | cold(`run_cold_start.sh`) |
|---|---|---|
| L1 readback (`env/verify.sh` settings) | ✅ `:309` (FAIL 가드 있음) | ✅ `:96` (**FAIL 가드 없음** — set -e로 result.env 없이 abort) |
| canary preflight (`env/verify.sh` preflight) | ❌ **미호출** | ❌ **미호출** |
| L2 membership (`env/verify.sh` membership) | ✅ `:262` `step_verify_recovery` (복원 타깃) | ❌ **부재** |
| 기능 회생 = PONG | ✅ probe | ✅ probe |

근거:
1. **canary preflight 미배선**: `do_preflight`는 `env/verify.sh:184`에 정의·dispatch(`:273`)돼 있으나
   `run_once.sh`/`run_cold_start.sh` main() 어디서도 `verify.sh <run_dir> preflight`를 호출하지 않는다
   (grep 전수 확인). old는 두 러너 모두 호출했다(`testbed_old/runner/run_once.sh:525`,
   `testbed_old/runner/run_cold_start.sh:365`). §6-16의 "사다리 **유지**"에 위배.
2. **cold L2 membership 부재**: cold 러너는 L1 settings(`:96`) 뒤 곧장 launch+PONG으로 간다 — 워크로드 PID의
   cgroup membership 검증이 없다. restore만 복원 타깃에 대해 `step_verify_recovery`(`:262`)를 수행한다.
   old cold는 membership을 검증했다(`testbed_old/runner/run_cold_start.sh:511`).
3. **부수 "침묵 스킵" 약점**: cold의 L1 verify(`run_cold_start.sh:96`)와 env setup(`:95`)엔 `|| { result_write FAIL … }`
   가드가 없어(run_once는 `:303`,`:309`에 있음) set -e abort 시 FAIL 사유 있는 result.env를 못 남긴다 —
   §6-16 "실패 시 result.env에 FAIL 사유 기록(침묵 스킵 금지)"의 취지와 어긋난다.

완화(참고): PONG은 liveness+기능을 증명하고, cgroup-join이 하드하게 실패하면 cold는 결국 "no response within
timeout" FAIL을 남긴다(`run_cold_start.sh:119`). 다만 그 FAIL은 membership 원인으로 귀속되지 않아 오라벨된다.
canary preflight의 목적(측정 타깃 기동 **전에** cgroup-join 메커니즘을 값싼 canary로 사전 검증)이 사라진 상태다.

**판정 근거 요약**: §6-16이 명시적으로 "유지"를 요구한 4룽 중 preflight(양 경로)·L2 membership(cold)이 빠졌고,
폐기 승인 기록이 없다 → FAIL. (수정은 본 감사 태스크 범위 밖 — 컨트롤러가 수정 태스크 파견.)

## §6-16 FIX (재검증)

컨트롤러 파견 수정 태스크에서 위 세 결함을 모두 해소했다 (수정 리포트: `.superpowers/sdd/task-19-report.md`
"Fix report (invariant §6-16)"). 코드 근거:

1. **canary preflight 복원** — 두 러너 모두 old 호출 위치(env verify 후·stress 시작 전) 그대로 복원.
   `runner/run_once.sh:319` `runner/run_cold_start.sh:125`:
   `"$TESTBED_DIR/env/verify.sh" "$RUN_DIR" preflight || { result_write FAIL "canary preflight failed"; exit 1; }`
2. **cold L2 membership 신설** — `runner/run_cold_start.sh:90-98` `step_verify_recovery()`가
   `env/verify.sh membership "cold target" "$WL_PID"`를 호출해 `generic_recovery` yes/no를 확정한다.
   호출 지점은 `run_cold_start.sh:143`, 측정 창(`:131-133`, `local start_ts`~`probe_first_response`) 뒤의
   "창 밖: bookkeeping" 구간(`:134` 주석) 안, probe 성공 분기(`PROBE_OK`) 내부 — 창 순수성(§6-1~2) 위반 없음.
   run_once.sh의 기존 `step_verify_recovery`(restored target 전용, `:258-268`)와 동형 패턴.
3. **cold env setup/verify 실패 가드** — `run_cold_start.sh:114` (`env/setup.sh ... || { result_write FAIL
   "env setup failed"; exit 1; }`), `:116` (`env/verify.sh ... || { result_write FAIL "env verify failed";
   exit 1; }`). run_once.sh의 기존 패턴(`:303`,`:309`)과 동형.

**측정 창 자가 감사**: 세 수정 모두 `run_once.sh`의 측정 창(`:207-213`, `step_restore_and_probe` 내부)과
`run_cold_start.sh`의 측정 창(`:131-133`) 바깥에 위치 — grep으로 두 창의 라인 범위를 재확인, 신규 코드 없음.

**실측 재검증** (`bash -n` + `shellcheck -x` 클린 확인 후):
- cold+koff 1런: `runs/verify_fix_cold_koff/result.env` → `result=PASS fail_reason= generic_recovery=yes`.
  콘솔 로그: `[membership] OK: canary pid=… is in …` (preflight), `[membership] OK: cold target pid=… is in …` (L2).
- restore+koff 1런(`run_once.sh --kdat-cache off`): `runs/verify_fix_restore_koff/result.env` →
  `result=PASS fail_reason= generic_recovery=yes kdat_cache=off`. 콘솔에 동일하게 canary + `restored target` membership OK.
- 고의 실패: `cpuset_cpus: 97-98`(30-core 호스트에 존재하지 않는 core)로 cold 1런 →
  `env/hardware/cpu.sh`가 `cpuset.cpus` write에서 `Numerical result out of range`로 실패, 스크립트가 가드로
  걸려 `result.env`에 `result=FAIL fail_reason="env setup failed"` 기록(이전엔 `set -e` 즉사로 result.env
  미기록 → 캠페인 집계에서 `NO_RESULT_ENV(rc=…)`로 뭉뚱그려졌던 증상, `run_campaign.sh:44-46` 주석 참조).

세 검증 런의 임시 run 디렉터리/cgroup/mount는 확인 후 정리했다(`testbed/runs/`는 gitignore 대상이라
커밋에 영향 없음).

**결론**: §6-16 검증 사다리 4룽(L1 readback → canary preflight → L2 membership → PONG) 전부 두 러너에서
호출됨을 코드+실행 양쪽으로 확인 → **PASS**로 갱신.

## Step 2 — 창 안 스폰 기계 검증 (execve trace)

환경에 strace가 없어 설치(`apt-get install strace`, 6.8) 후 실행. 브리프 원본 one-liner는 워크로드 기동(`&`)까지
함께 추적해 창 밖 execve(simple)가 섞이므로, **측정 창(`probe_first_response` 호출)만** 격리해 추적하도록 등가
수정했다(목적 = execve 추적으로 창 안 스폰 종류 확인, 그대로 유지). 두 경로를 실측:

**Trace A — 서비스 UP(성공 경로)**: 창 안 execve 2건뿐
```
execve("/root/Embed-sim-lab/testbed/runner/cprobe", ["…/cprobe","127.0.0.1","18995"], …) = 0
execve("/usr/bin/bash", ["bash","-c", …], …) = 0
→ grep -vE 'cprobe|sleep|bash'  ⇒  window clean A   (PROBE_OK=1, 성공 시 sleep 0회)
```

**Trace B — 데드 포트 1s 폴링(페이싱 경로)**: 정확히 5ms×200
```
    200 execve("/root/Embed-sim-lab/testbed/runner/cprobe" …
      1 execve("/usr/bin/bash" …
    200 execve("/usr/bin/sleep" …
→ grep -vE 'cprobe|sleep|bash'  ⇒  window clean B   (sed/awk/date/seq/grep 0건)
```

결론: 측정 창의 외부 스폰은 **cprobe(측정, §6-1)** + **/usr/bin/sleep(5ms 페이싱, §6-3)** 둘뿐이며 금지 스폰
(sed/awk/date/seq)은 0건. cprobe는 static(§6-5, `ldd` = not a dynamic executable). §6-1/§6-3/§6-5 기계 검증 통과.

(원시 트레이스: `/tmp/claude-0/winA.trace`, `/tmp/claude-0/winB.trace`. 재현 스크립트는 감사 과정 로그 참조.)
