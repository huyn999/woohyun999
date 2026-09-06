# failprobe — CRIU 호환성/실패 모드 매트릭스 (라인 단위)

webOS TV에서 실제로 나타나는 앱 자원 사용 패턴 100종을 계약 v2 워크로드로 만들어,
**"어떤 자원 상태를 가진 프로세스를 어느 소스 라인 직후에 얼리면 dump/restore가
성공하는가, 실패하면 CRIU의 어느 서브시스템이 왜 거부하는가"** 를 자동 측정한다.

crossover(성능) 실험과 상보적인 축: crossover = "언제 이득인가"(RQ2),
failprobe = "애초에 가능한가 + 실패의 분류학"(RQ1).

## 구성

```
failprobe/
├── gen_workloads.py     # 워크로드 100개 생성기 (feature/line 두 해상도)
├── compat_sweep.sh      # 스윕 러너: 워크로드 × phase → dump/restore → 에러 파싱 → CSV
├── summarize_compat.py  # CSV → 실패 매트릭스 + 에러 클러스터 + feature별 실패율 (markdown)
├── timing_sweep.sh      # RQ2: compat 통과 워크로드의 cold vs restore 시간 (기존 러너 배치)
├── scenarios.csv        # 100개 시나리오 표 (이름/feature/phase/사전 리스크 가설)
├── phase_map.csv        # phase → workload.c 줄번호·문장 역추적표 (생성 시 갱신)
└── results/             # 스윕 산출물 (compat_<mode>.csv, runs/<셀>/ 로그)
```

## 100개 시나리오 구성 (결정적 — 실행마다 동일)

- **단일 feature 탐침 44개** (`fp_s_<feature>`): CRIU 리스크 단위 하나씩.
  파일(로그 fd/ghost/FIFO/mmap/락 2종), 소켓(UNIX 3종/TCP listen·**established**/UDP/netlink),
  이벤트(timerfd/eventfd/signalfd/epoll/inotify), 메모리(대형 힙/dirty/memfd/POSIX·SysV shm/mlock),
  프로세스(스레드 1·4/futex 블록/자식/손자/setsid), 기타(타이머 2종/sigaltstack/cwd/디바이스 fd/
  rlimit/세마포어/mq).
- **composite 30개** (`fp_c_<앱유형>`): webOS 앱 시나리오 — 미디어(HLS/로컬), luna 버스
  (클라이언트/데몬), DVR, EPG, 런처, 브라우저, 게임, 앱스토어, 오디오 서버, DB, 설정,
  업데이터, Wi-Fi/BT 매니저, 워치독, 썸네일러 등. 조합 근거는 scenarios.csv의 desc.
- **pair 26개** (`fp_p<NN>_<위험>__<흔함>`): 위험 feature × 흔한 feature 결정적 교차.

`scenarios.csv`의 `risks` 컬럼은 **측정 전 사전 가설**이다(pre-registration 역할) —
실측과의 일치/불일치 자체가 결과다.

## 두 해상도

```bash
# feature 단위 (~584셀): 자원 획득 덩어리별 판정 — 빠른 1차 지도
python3 failprobe/gen_workloads.py --workloads-dir testbed/workloads --count 100

# line 단위 (~1139셀): setup 구간의 모든 최상위 문장 뒤에 덤프 지점 —
# "socket()까지는 OK, connect() 라인부터 NG" 수준의 문장 경계 판정
python3 failprobe/gen_workloads.py --workloads-dir testbed/workloads --count 100 --granularity line
```

line 모드 phase 이름은 `f_<feature>_l<NN>`이고, 각 phase가 어느 줄·어떤 문장인지는
`phase_map.csv`로 역추적한다. 예외: fork 계열 3종(child/grandchild/…launcher류)은 통짜 —
fork 직후 부모·자식이 후속 라인을 둘 다 실행해 라인 계측이 로그를 오염시키기 때문(기술적 필연).
서비스 루프 내부는 steady 하나로 대표(매 반복 동일 상태), for 루프 내부도 반복 단위로는 안 쪼갠다.

## 계약 v2 준수 (testbed/workloads/README.md)

A1(named flags: --bytes/--port/--phase_gap_ms), A2(PHASE+fflush), A3, A5,
A6(핑퐁, common/probe_server.h → served_first 자동), manifest C절 전부 준수.
**A4(dump 시점 깨끗한 fd)만 의도적 위반** — 그것이 탐침의 목적. 따라서 이 워크로드들은
기존 build.sh가 자동 발견·빌드하고, 기존 run_once.sh/캠페인으로도 그대로 돌릴 수 있다
(단, 아래 "시간 측정과의 관계" 참고).

`--phase_gap_ms`(기본 400): 각 phase 직후 머무는 창. phase 관측→freeze 사이 at-or-after
스큐를 제거해 dump가 "정확히 그 라인 직후 상태"를 얼리게 한다. **시간 측정에 쓸 땐 반드시 0.**

## 스윕 사용법

```bash
# 전체 (glob 생략 = fp_* 전부 × 모든 phase)
sudo failprobe/compat_sweep.sh
PHASE_GAP_MS=150 sudo failprobe/compat_sweep.sh    # gap 축소로 단축 (150ms ≫ 폴링 20ms라 안전)

# 부분 (glob)
sudo failprobe/compat_sweep.sh 'fp_s_*'            # 단일 탐침만
sudo failprobe/compat_sweep.sh 'fp_s_shm_sysv'     # 특정 워크로드만

# 모드
PERMISSIVE=1 sudo failprobe/compat_sweep.sh        # --tcp-established --file-locks --ext-unix-sk
                                                   # --link-remap 허용 → strict와의 diff = "옵션 처방전"
CONSTRAINED=1 sudo failprobe/compat_sweep.sh       # TV 제약 모드: scenario.yaml 조건으로
                                                   #  - cgroup: memory.max/swap/cpu.max/cpuset
                                                   #  - stress 배경부하 상주 (floor_mib 반영)
                                                   #  - 느린 스토리지: loop+dm-delay+io.max 디스크에
                                                   #    CRIU 이미지를 쓰고 읽음
                                                   # 결과는 compat_<mode>_tv.csv 로 분리 저장.
                                                   # CPU saturate로 느려지므로 PHASE_TIMEOUT_S=40 권장
# 제어 env
RESUME=1          # 기존 CSV의 완료 셀 skip (중단 이어가기)
ONLY_PHASES="ready steady"
PHASE_TIMEOUT_S=30
CRIU_BIN=/path/to/criu   # 다른 CRIU 버전 비교 축
```

strict 모드도 `--shell-job`은 포함한다 — 러너 자식 프로세스는 세션 리더가 아니라서 이 옵션
없이는 전 셀이 pstree 에러로 죽는 하네스 아티팩트가 생기기 때문. 기존 run_once.sh의 CRIU
호출 조건(--shell-job -v4)과 정확히 일치시켜 두 실험 축의 조건 정합성을 확보했다.

## 셀당 검사 4단계와 CSV 스키마

| 열 | 의미 |
|---|---|
| launch_ok | 워크로드가 해당 phase까지 도달했나 |
| dump_rc | criu dump 성공(0)/실패. 실패 시 dump_err에 첫 `Error (criu/<파일>.c:<줄>)` |
| restore_rc | dump 성공 셀만. restore_err 동일 |
| verify | post-ready 셀: cprobe **PONG** (end-to-end). pre-ready 셀: 복원 프로세스가 잔여 setup을 이어 **ready 도달**하는지 (resumed_to_ready / resume_stalled) |

실패 셀의 -v4 전체 로그는 `results/runs/<wl>__<phase>__<mode>/img/*.log`에 보존.
성공 셀 이미지는 용량 절약을 위해 삭제(로그만 유지).

## 권장 워크플로

1. feature 단위 strict 전체 → 1차 실패 지도
2. line 단위 재생성 → 전체 또는 실패 워크로드 glob 재스윕 → 문장 경계 확정 (phase_map 조인)
3. `PERMISSIVE=1` → strict와 diff = 옵션으로 구제되는 실패 vs 구조적 한계 분리
4. `timing_sweep.sh`로 통과 워크로드의 cold vs restore 시간 비교 (RQ2)

## 시간 측정 — timing_sweep.sh (RQ2)

compat 스윕은 **가능/불가 판정 전용**이며 시간을 재지 않는다. cold vs restore 시간은
`timing_sweep.sh`가 잰다 — 단, 측정 방법 자체는 새로 만든 것이 아니라 **기존 러너를
그대로 호출**한다(run_cold_start.sh / run_once.sh — cgroup·stress·storage 제약 전부 적용,
cprobe 5ms 폴링 단일 측정 창, kdat/restore_work 분해 포함). timing_sweep은 그 위의
배치 자동화다: compat 통과 워크로드 선별 → 워크로드별 config 생성 → 반복 실행 →
result.env 수집 → median/승자 요약.

```bash
# 전제: compat strict 결과 존재 + bootstrap 완료(scenario.yaml이 이 머신에서 doctor PASS)
REPS=1 sudo failprobe/timing_sweep.sh 'fp_s_timerfd'   # 스모크 (~1분)
REPS=3 sudo failprobe/timing_sweep.sh                  # 통과 전체 (~70개면 420런 ≈ 3~4h)
REPS=5 sudo failprobe/timing_sweep.sh 'fp_c_*'         # composite만 정밀
cat failprobe/results/timing_summary.csv               # 워크로드별 median·승자·배율
# env: REPS / RESUME=1 / SKIP_FILTER=1 / RUN_TIMEOUT(기본 300s) / COMPAT_CSV
```

측정 정합성 규칙 (스크립트가 자동 보장):
- `phase_gap_ms: 0` 강제 — gap(compat용 라인 정지)이 켜져 있으면 응답시간이 통째로 오염
- strict 통과 워크로드만 — 실패 워크로드는 기존 러너에서도 dump FAIL이라 측정 불가
- `dump_at: served_first` (warm dump). pre-ready 시점 시간 측정은 F2 물리 한계
  (seize 지연 > gap 0일 때의 phase 간격)로 대부분 dump_phase_missed — 의미 있는 시간 축은
  ready 이후다
- 조건(memory/cpu/stress/storage)은 testbed/scenario.yaml을 base로 상속 — 클럭 고정
  (frequency_khz)이 가능한 머신이면 scenario.yaml에서 되살리는 것만으로 timing에 반영된다

## 주의 / threats to validity

- 커널 의존성: WSL2/x86_64 결과 ≠ webOS/ARM. 측정 시 `uname -r` + criu 버전 기록 필수,
  가능하면 RPi4(aarch64) 재실행 diff 리포트.
- 셀당 1회 실행: 간헐적(비결정적) 실패는 놓칠 수 있음 — 의심 셀(예: PID 충돌 계열)은
  같은 glob 반복으로 재현율 측정.
- PONG 너머의 상태 무결성(조용한 데이터 손상)은 범위 밖.
- feature별 실패율 표 해석: composite 실패는 동승 오염 포함 — 인과 귀속은 단일 탐침
  (fp_s_*) 기준으로, composite 비율은 "현실 앱의 동반 노출률"로 읽을 것.
- tty 탐침은 실행 환경의 controlling tty 유무에 따라 의미가 달라짐 (터미널 sudo 실행 시
  tty 상속 → dump 불가 실측). SysV sem은 커널에 잔재 가능: `ipcs -s` 확인, `ipcrm` 정리.
- 스윕 잔재: /tmp/criuprobe_*, /dev/shm/criuprobe_* 는 종료 시 자동 정리(베스트에포트).

## 남은 갭과 발전 방향 (future work)

이 파이프라인이 아직 답하지 못하는 것들 — 논문 limitations이자 다음 실험 후보:

1. **실제 앱 검증**: 워크로드는 webOS 앱 유형의 자원 패턴 프록시다. 실패가 자원 종류의
   함수임이 확립되었으므로, 실제 앱의 fd/자원 목록 조사(`ls /proc/<pid>/fd`, maps, task 트리)
   → 본 매트릭스로 checkpointability **예측** → 실기기에서 예측-검증하는 실험이 자연스러운
   다음 단계다.
2. **아키텍처/실기기**: x86_64/WSL 결과의 aarch64(RPi4, 32-bit CRIU Track A) 재현 확인.
   특히 mq internal mount 건은 네이티브 재현 여부가 "CRIU 일반 한계 vs 플랫폼 상호작용"을
   가른다. 두 x86 커널(6.6/6.18) 동일 재현까지는 확보됨.
3. **webOS 스택 층**: luna-service 실제 버스, ACG 보안 정책, 실제 앱 기동 방식(세션/tty 구성)은
   모사 밖 — tty·PID 충돌 클래스의 실기기 양상 확인 필요.
4. **상태 무결성 검증(2층 verify)**: 현재는 기능적 소생(PONG/ready)까지. manifest에
   `verify_cmd`류 확장으로 워크로드별 심층 self-check(메모리 체크섬, 타이머 틱 지속,
   락 유효성)를 측정 창 밖에서 수행하는 2층 구조 후보.
5. **비결정 실패의 재현율**: PID 충돌 클래스는 시스템 상태 의존 — 동일 셀 반복 실행으로
   실패 확률을 정량화하고, restore_gap(덤프 후 경과 시간)을 축으로 추가하면 "시간이 지난 뒤
   복원"의 가혹 조건을 잴 수 있다.
6. **과도 상태 fuzzing**: 라인 계측은 문장 경계 해상도다. 시스템 콜 한복판·시그널 핸들러
   내부 같은 라인 내부 순간은 랜덤 타이밍 dump 반복으로 확률적으로 때리는 별도 축 후보
   (In-flight TCP 발견이 이 방향의 가치를 시사).
7. **CRIU 버전/옵션 축**: CRIU_BIN 교체로 버전 비교, --lazy-pages·--track-mem 등
   dump 옵션 sweep은 상위 저장소 ROADMAP과 합류 지점.
