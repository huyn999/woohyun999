# pbsprobe — pbs(EPG 배너 서비스) 상세 모사 + 상황×라인 dump/restore 매트릭스

**실험 구조 (단일 일관 형식)**: 행 = 생애주기 라인(자원 전이 phase + 긴 줄의
25/50/75% 진행점 + 소스 문장 Lsrc), 열 = 상황 190종, 셀 = "그 상황에서
그 라인에 dump→restore하면 문제가 되는가" — 총 2243셀, 요약기가 라인×상황
피벗 표를 자동 생성한다. `gen_matrix.py`가 정의·생성 담당(상황 추가는 SITS
목록에 한 줄). 구세대 가족식 매트릭스(A~O)는 `gen_scenarios.py`로 남아 있다.

상황 171종의 구성: 핵심 구성 10종(순수/hub1·2·4·8/tcp-rr·stream/heavy/light/만물)
× CRIU 옵션 5종 = 50 · 단독 자원 18종 × 옵션 5종 = 90 · 조작 26종(처방 3변형·
lock제거·정지 15/45s·DB/shm/cwd/inode/바이너리 변동·선점·허브교체·사이클·
재복원·동시복원) · cgroup 메모리 한도 7종(heavy 300~1024, light 330/500,
라인별 실복원) · 허브 세계 3종 · GitHub 이슈 계열 12종(half-closed×5옵션·SCM 3·송신자사망·타이머만기·flood 2)(noaccept/부재/경계 안) · 소스 문장 단위 2종.
WORLD=1이면 이 전체가 상시 배경 세계 안에서 재실행된다.

| 대표 상황 | 가정 | 라인 수 |
|---|---|---|
| S01 pure / S02 pure_opt | 순수 앱 × 옵션 없음/총동원 | 20/20 |
| S03 hub / S04 hub_opt | 루나허브 연결 × 옵션 없음/총동원 | 25/25 |
| S05 tcp | 허브+TCP, --tcp-established | 26 |
| S06 all / S07 all_opt | 전체 자원(만물) × 옵션 없음/총동원 | 46/46 |
| S08 rescue | 전체 자원 + 옵션 + **처방(연결해제)** | 16 |
| S09 droplock | TCP의 CRIU lock 제거 공격 | 5 |
| S10 freeze45 / S11 dbgone / S12 ota | 45s 정지 / DB 소실 / 바이너리 교체 | 20/19/20 |
| S13 mem700 | heavy 앱을 700MiB 한도로 복원 | 18 |
| S14/15 srcline(_opt) | **소스 문장 단위**(코드 줄=dump 지점) × 옵션 | 37/37 |


`failprobe/`(자원 종류별 가능/불가 분류학), `connprobe/`(연결 생존 실험)와 나란한
세 번째 실험 패키지. 이 축의 질문은 하나다:

> **실제 webOS 서비스(pbs)를 커널 객체 수준으로 충실히 모사했을 때, 실전에서
> 일어날 법한 1032가지 dump/restore 상황 각각에 대해 "얘는 되고 얘는 안 된다"를
> 판정하고, 안 되는 것에는 처방(disconnect & re-register 등)이 실제로 듣는가?**

07/22 발표의 3대 발견(Luna Hub 경계 문제 · TCP lock 생존 조건 · 메모리 침묵형
실패)을 **한 앱 안에서** 재현하고, Future Work로 공언한 "실서비스 모사 +
line-by-line 실패 목록화"와 "처방 추후 검증"을 실측으로 채운다. 나아가 실기
pbs가 가질 법한 **추가 자원 표면 전체**(잠금·스레드·DGRAM·shm·렌더·cwd)를
전수 검사한다.

---

## 0. 방법론 — 왜 이 구조가 체계적인가

세 가지 원칙 위에 서 있다.

**(1) CRIU는 로직이 아니라 커널 객체를 본다.**
dump/restore의 성패는 비즈니스 로직이 아니라 프로세스가 쥔 커널 객체(fd, 매핑,
잠금, 스레드)와 그 **경계 위치**(상대가 덤프 집합 안인가 밖인가)로 결정된다.
따라서 모사의 충실도 기준은 "EPG 텍스트가 진짜 방송명인가"가 아니라
"커널 객체 목록과 토폴로지가 실기와 같은 계급인가"다. §2의 자원 표가 그 목록이다.

**(2) 사전 등록(pre-registration).**
1032셀 전부에 측정 전 기대 판정(`hypothesis` 열)을 못 박아 둔다. 실측과의
일치는 이해가 맞았다는 증거, **불일치는 실패가 아니라 발견**이다. 요약기가
일치율과 불일치 목록을 자동 산출한다. 결과를 보고 가설을 고쳐 쓰는 오염이
구조적으로 불가능하다.

**(3) rc를 믿지 않는다.**
connprobe/발표의 교훈: `restore rc=0`은 "CRIU 작업 완료"일 뿐 "서비스 회생"이
아니다. 모든 셀은 복원 후 end-to-end로 검증한다 — PONG(서비스), STAT crc(상태
무결성), hub 재등록(양쪽 로그 교차), TCP 실왕복/수신 진행(write 성공은 증거가
아님), +5초 생존(침묵형 OOM은 이 창에서만 잡힌다), 잔여 기동 완주. verdict가
`ok / dump_fail / restore_fail / silent_dead / conn_dead / resume_stalled /
orig_intact` 로 실패의 **계급**을 분리한다.

여기에 운영 원칙 둘: 결정적 생성(시나리오·DB 내용 모두 재현 가능), 셀 격리
(포트/파일/cgroup 셀별 분리 + 멱등 정리 — 셀 하나의 실패가 스윕을 오염시키지
않는다).

---

## 1. pbs가 뭔가, 무엇을 모사했나

pbs는 화면 하단 배너에서 채널 DB를 파싱해 "이 시간대 이 채널은 이 방송"을
텍스트로 보여주는 서비스다. `testbed/workloads/pbs_mock/`이 그 생애주기를
자원 단위로 재현한다:

```text
[기동]  (PmLog 모형) 외부 DGRAM 로그 연결
        → DB open → (sqlite 모형) 파일 잠금 flock|posix
        → 스트리밍 read(io) → 파싱·해시(compute, 작업단위=parse_iters)
        → 편성 인덱스 + EPG 텍스트 캐시(anon mem, touched)
        → 지연 캐시 예약(malloc-untouched — 침묵형 OOM 탐침)
        → 워커 스레드 ≤4 → self-pipe / eventfd (GLib mainloop 모형)
        → POSIX shm 배너 버퍼(surface 모형) → 전용 cwd
        → Luna hub 접속 ×N (외부 hub에 REG/ACK + 미수신 notify queue) → SUB
        → 렌더 채널(별도 외부 STREAM) → (선택) TCP feed(reqresp|stream)
        → timerfd(분 단위 배너 시계) → inotify(DB 갱신 감시) → ready
[상시]  핑퐁 서비스 + 주기 refresh(배너 재렌더: index dirty + reserve 점진
        touch + shm dirty + 로그 틱 송신) + hub 생존 감시/자동 재접속 + feed 수신
```

모든 단계가 `PHASE <이름>`으로 계측되어 line-by-line dump 지점이 된다(계약 A2).
자원별 on/off 플래그라서 "그 자원만 있는 세계"와 "전부 있는 세계"를 같은
코드로 만든다.

### 실기 아키텍처와의 대조 근거 (웹 검증 완료)

- **luna-service2 공식 문서/저장소**: LS2 = 클라이언트 라이브러리 + 중앙 허브
  데몬(ls-hubd), 서비스는 이름(com.webos.*)으로 버스에 등록(LSRegister),
  신호는 구독 등록한 클라이언트에게만 전달, 통신은 로컬(UNIX) 소켓. → 모사의
  `외부 hub connect → REG → ACK → SUB → notify push` 구조와 1:1 대응.
  서비스 사망 시 LS2가 요청을 버퍼링했다가 재시작 후 전달한다는 명세는
  "재등록 처방"이 프로토콜상 자연스러운 동작임을 뒷받침한다.
- **EPG 일반 설계**(sqlite 채널/편성 테이블, now/next를 현재 시각으로 계산,
  주기 갱신, 파일/신호로 갱신 감지) → DB 파일 + 채널×슬롯 인덱스 + `cur_slot()`
  + refresh + inotify 구조와 대응.
- 발표 5-6장의 실기 Batch A/B가 hub 연결이 AF_UNIX established임을 이미 실증
  → 모사는 그 토폴로지의 재현.

### 의도적 단순화 (판정에 무해하다는 근거 포함)

- 프로토콜 페이로드는 한 줄 텍스트 (JSON 프레이밍 아님) — 판정을 가르는 것은
  바이트 내용이 아니라 소켓 토폴로지임을 발표 5-6장이 실증.
- mock 재등록에는 hub의 ACL/role 검사가 없다 — `rereg_ms`는 실기 비용의
  **하한**으로 읽는다.
- 모사 밖 후보(실기 확인 필요): dmabuf/GPU 디바이스 fd(배너를 GPU로 그린다면
  CRIU가 원리적으로 복원 불가 — shm은 그 대역일 뿐), netlink, sqlite WAL의
  실제 매핑 형태. 실기에서 `ls -l /proc/$(pidof pbs)/fd`와 `cat
  /proc/<pid>/maps` 한 번이면 §2 표와 대조해 누락을 확정할 수 있고, 자원
  추가는 "phase 한 줄 + 셀 몇 개" 작업이다.

---

## 2. 모사가 커버하는 커널 객체 표면

| 계급 | 자원 | 플래그 | phase |
|---|---|---|---|
| 파일 | DB regular file (자체 생성, 결정적) | `--db_mib` | db_open/db_read |
| 파일 잠금 | flock / POSIX 읽기락 (sqlite 모형) | `--db_lock` | db_lock |
| 메모리 | anon touched (인덱스+텍스트) | `--index_mib` | epg_index |
| 메모리 | anon untouched 예약 → refresh가 점진 touch | `--reserve_mib` | epg_reserve |
| 메모리 | 파일 MAP_SHARED | `--mmap_db` | db_mmap |
| 메모리 | POSIX shm MAP_SHARED (surface 모형) | `--shm_mib` | shm_map |
| 실행 | 워커 스레드 ≤4 (STAT thr= 진행 확인) | `--threads` | thread1..4 |
| 이벤트 | self-pipe / eventfd / timerfd(armed) / inotify | `--selfpipe/--eventfd/--timer/--watch` | selfpipe/eventfd_open/timer_armed/db_watch |
| UNIX | 경계 안 socketpair (Batch A 대조) | `--selfhub` | hub_connK |
| UNIX | 외부 established ×N + 미수신 queue | `--hub_conns/--hub_pending` | hub_conn1..8 |
| UNIX | accept 전 백로그 (hub `--no-accept`) | (hub 옵션) | hub_connK |
| UNIX | 별도 외부 STREAM (렌더 채널) | `--render` | render_conn |
| UNIX | connected DGRAM (PmLog 모형) | `--log_dgram` | log_open |
| TCP | reqresp / streaming (외부 feed) | `--tcp` | tcp_conn |
| TCP | listen 소켓 (핑퐁 서비스) | `--port` | ready |
| 경로 | 전용 cwd | `--workdir` | workdir |

failprobe의 단일 자원 탐침(fp_s_*)과 달리, 여기서는 이것들이 **한 프로세스에
동시에** 존재한다 — 실서비스의 조건.

---

## 3. 검증 채널 (측정 창 밖 전용)

PONG은 고정 비용 불변식(§6-6) 때문에 상태를 싣지 않는다. 같은 서비스 소켓의
별도 5바이트 명령으로 검증한다:

```text
"STAT\n" → STAT crc=<8hex> slot=<n> hub=<a>/<t> rereg=<n> res=<KiB>
           thr=<ticks> ev=<0|1> shm=<0|1> log=<0|1> up_ms=<n>
  crc  편성 인덱스 FNV-1a — restore 전후 비교로 상태 무결성
  slot 현재 시간대 슬롯 — "지금 뭐 하는지" 답하는가 (기능 판정; 오래 얼렸다
       복원하면 slot이 전진해 있어야 정상)
  thr  워커 스레드 진행 카운터 — 증가하면 스레드 회생
  ev   eventfd write→read 즉석 왕복
  shm  shm 매핑 쓰기 성공
  log  connected DGRAM send 성공 (수신자 죽었으면 ECONNREFUSED로 탐지)
"BANR\n" → BANR slot=<n> now=PGM-<8hex> next=PGM-<8hex>
  지금/다음 방송 ID — 재계산이 아니라 편성 인덱스 메모리의 해당 슬롯 행을
  읽어 해시한 값. 복원 전 'next'가 (슬롯이 넘어간) 복원 후 'now'로 나오면
  "미래 편성까지 담긴 인덱스가 통째로 살아왔고 시계는 신선하다"의 증명
"TCPQ\n" → TCPR mode=<m> ok=<0|1> rx=<bytes>
  reqresp: 즉석 왕복 1회 결과 / stream: 누적 수신(두 번 찍어 증가 확인)
```

### disconnect & re-register 처방 (발표 7장의 대안, 확장판)

```text
SIGUSR1        → 외부 연결 전부 close (hub N개 + render + log),
                 PHASE hub_disconnected closed=N render=<0|1> log=<0|1>, 재접속 보류
--resume_file  → 파일이 생기면 보류 해제 → 전 채널 재접속·재등록
                 PHASE hub_reregistered ms=<비용> conns=<n> render=.. log=..
```

러너가 dump 직전 USR1, restore 직후 resume touch (connprobe 규약). 재등록이
상대까지 닿았는지는 hub 로그(`HUB register`/`RENDER conn`) 증가로 교차 확인.

---

## 4. 폴더 구성

```
pbsprobe/
├── run_all.sh         단일 진입점: 빌드→셀프테스트 관문→시나리오→스윕→요약
├── build.sh           pbs_hub/pbs_probe 빌드 + workloads/build.sh 호출(자동 발견)
├── selftest.sh        CRIU 없는 40항목 기능 관문 (root 불필요) — FAIL이면 스윕 무의미
├── gen_scenarios.py   상황 매트릭스 생성 → scenarios.csv (결정적 136셀 + 사전 가설)
├── scenarios.csv      셀 정의 (커밋 대상 — 재생성 가능)
├── pbs_sweep.sh       스윕 러너: 셀당 기동→dump→조작→restore→검증→CSV 판정
├── summarize_pbs.py   CSV → 가족별 판정 매트릭스 + 에러 클러스터 + 가설 일치율
│                      + 처방 비용 통계 (markdown)
├── pbs_hub.c          바깥 세계: Luna hub(추상 UNIX) + TCP feed(port+3000)
│                      + PmLog DGRAM 싱크 + 렌더 listener. 덤프 경계 밖 상대
├── pbs_probe.c        검증 클라이언트: PING|STAT|TCPQ (cprobe 확장판)
├── bin/               빌드 산출물 (커밋 제외)
└── results/           pbs_matrix[_tv].csv, runs/<셀>/, report[_tv].md (실행 시 생성)

testbed/workloads/pbs_mock/   측정 대상 (계약 v2 플러그인 — 기존 러너·캠페인에서
                              수정 없이 그대로 동작)
```

---

## 5. 상황 매트릭스 1032셀 — 설계와 가족별 상세

### 5a. 셀의 해부 — '상황' 하나는 6축의 조합이다

모든 셀은 `scenarios.csv`의 한 행이고, 같은 6개 축의 값 조합으로 정의된다.
"다양한 상황"이 임의 나열이 아니라 **축의 곱집합에서 의미 있는 점들을 고른 것**
이라서, 어떤 상황이 왜 존재하고 무엇과 대조되는지가 행 자체로 읽힌다:

```text
scenario,family,phase,criu_opts,pre_dump,post_dump,restore_mem_mib,hub_mode,verify,params,hypothesis

phase       ①언제 얼리나: 생애주기 38개 phase 중 하나 (line-by-line의 축)
criu_opts   ②어떻게 얼리나: strict | ext_unix | tcp_est | filelocks | permissive
pre_dump    ③얼리기 전 조작: none | bye(처방: USR1로 외부연결 전부 해제)
post_dump   ④dump~restore 사이 세계 조작: none | sleep15/45(정지) |
             droplock_sleep2(CRIU lock 제거) | rmdb/rmshm/rmwd(자원 소실) |
             hub_restart(허브 교체) | cycle2/restore2/restore_dup(반복·중복) |
             touchdb(감시 대상 갱신) | verify_orig(dump 실패 후 원본 검사)
restore_mem ⑤어디로 복원하나: 0(무제약) | N MiB(cgroup memory.max — OOM 축)
hub_mode    ⑥세계의 상태: none | normal | noaccept(accept 안 함) |
             down_after(재접속 대상 부재) | self(경계 안 socketpair 대조)
params      워크로드 자원 구성 (§2의 플래그들 — 무엇을 들고 있는 앱인가)
verify      이 셀에서 요구하는 검증 채널 집합 (pong,stat,hub,tcp,live5,resume,watch
             — watch: 복원 후 스윕이 DB를 실제 갱신해 inotify 이벤트 로그를 확인)
hypothesis  사전 등록된 기대 판정과 그 이유
```

예: `C_st_droplock` = "steady에서(①) tcp_est로(②) 조작 없이(③) 얼리고,
CRIU의 netfilter lock을 지운 뒤 2초 방치하고(④) 무제약 복원(⑤), 외부 feed
있는 세계(⑥)" — 가설: restore rc=0에 PONG도 ok지만 TCPQ만 죽는다(침묵 연결사).
새 문제를 추가할 때도 축 값 하나(post_dump 종류, params 플래그)를 늘리면 되는
구조라, H 가족(이슈 셀)이 그대로 이 틀에 들어왔다.

### 5b. line-by-line dump — 메커니즘

"기동의 몇 번째 줄까지는 얼 수 있는가"를 재는 장치. 세 부품의 합이다:

**① 워크로드 쪽 — 모든 문장에 계측점.** 생애주기의 각 단계 직후에
`PHASE <이름> <근거값>`을 stdout에 찍고(fflush, 계약 A2), 단계 사이에
`--phase_gap_ms`(스윕 기본 250ms)의 창을 연다. 이 창이 "그 줄에서 멈춘 프로세스"
를 CRIU가 붙잡을 수 있는 시간이다. phase는 자원 획득 **직후**에 찍므로
"phase X에서 dump" = "X까지의 자원을 전부 쥔 상태에서 dump"로 해석이 고정된다.
측정 캠페인으로 이행할 땐 gap을 0으로 끄면 계측 오버헤드가 사라진다
(`E_gap0_steady`가 이행 가능성을 확인).

**② 스윕 쪽 — n번째 등장 대기 후 저격.** `wait_line <log> "^PHASE <이름>"`이
로그에서 해당 phase의 **n번째 등장**(기본 1; 재등록처럼 재발하는 phase는 n=2)
을 50ms 간격 폴링으로 기다렸다가, 등장 즉시 — 즉 gap 창 안에서 —
`criu dump -t <pid>`를 쏜다. 같은 phase 이름이 A(무hub)/F(RICH) 등 다른 params
조합에서 재사용되므로, **같은 줄을 서로 다른 자원 구성에서 얼려보는 것**이
가족 간 대조의 원리다 (예: `epg_reserve` 줄은 A에선 통과, F의 RICH에선 이미
flock을 쥔 뒤라 거부 — 실패 경계선의 이동을 라인 단위로 증명).

**③ 판정 쪽 — pre-ready 셀은 '이어가기'까지가 성공.** ready 전에 얼린 셀은
복원 후 PONG만으론 부족하다 — 프로세스가 **잔여 기동을 이어가 ready에 도달**
해야 회생이다. `v_resume`이 복원 시점 이후의 후속 phase 진행을 로그로 추적해
`resumed_to_ready | resume_stalled`로 판정한다. 멈춘 지점의 마지막 phase가
로그에 남으므로 "어느 줄에서 멈췄나"까지 자동 기록된다.

line-by-line 스윕은 세 벌이다: **A**(기본 pbs, hub 유/무 대조 26셀) →
**F_all_life**(모든 자원을 켠 RICH 구성 15+4셀 — 경계선이 db_lock으로 당겨지는가)
→ **G_life**(상시 세계의 소음 속 8셀 — 경계선이 세계에서도 동일한가).
같은 축을 세 세계에서 반복하므로, 셋의 차이가 곧 "자원 때문인가, 세계 때문인가"
의 분리다.

### 5c. 문제 → 셀 매핑 (어떤 문제가 어디서 검증되나)

| 문제(출처) | 표현 축 | 셀 |
|---|---|---|
| 외부 hub established dump 거부 (발표5, sk-unix.c:881) | hub_mode=normal ×phase | A_life_hub_conn1.., B_conns* |
| accept 전 백로그: dump 성공·restore 'Peer unresolved' (발표6) | hub_mode=noaccept | B_halfopen_* |
| 경계 안이면 queue까지 복원 (발표5 Batch A) | hub_mode=self | B_selfhub_queue, H_scm_selfhub |
| TCP lock 제거 → rc=0 침묵 연결사 (발표8) | post=droplock | C_st_droplock |
| heavy fail-fast vs light 지연 OOM (발표10-11) | restore_mem×refresh | D_heavy_*, D_light_silent/norefresh |
| 처방: 해제·재등록 + 비용 (발표7 '추후 검증') | pre=bye | B_bye_*, E_full_rx, F_all_rx, G_rx |
| 파일 잠금은 --file-locks 필수 (CRIU 정책) | params=db_lock×opts | F_flock/posix_* |
| unlink된 저널: ghost 필요 (sqlite 실전) | params=tmpunlink | H_tmpunlink_* |
| half-closed TCP repair 불가 (gh#505, ARMv8) | params=tcp_halfclose | H_halfclose_* |
| fd 실린 미수신 SCM (PR#2030) | hub --pass_fd | H_scm_pending |
| rseq: glibc≥2.35 × CRIU<3.17 크래시 (gh#1696) | 평범 셀 자체 | H_rseq_baseline |
| 허브 교체 후 복귀 (운영) | post=hub_restart | H_hub_upgraded |
| 재등록 순간 밀린 notify 폭주 (world 고유) | world flood | G_flood_rereg, G_freeze45_flood |
| LMK가 복원을 쏘는가 (world+물리) | world memd | G_mem_heavy |
| 이미지 재사용·동시복원·경로 요구 (criu.org/이슈) | post=restore2/dup, rm* | D_restore_*, E_rmdb, F_shm_gone/wd_gone |
| 프로세스 트리·좀비·보류 시그널 (운영) | params=child/zombie/sigpend | I_child_*, I_zombie, I_sigpend |
| 재시작 경합: listen 이름 선점 (운영) | post=squat | I_name_squat (+대조 I_unix_listen) |
| OTA: 바이너리 교체 중 restore (배포) | post=mvbin[_back] | I_binary_gone/back |
| mmap 대상 절단 → SIGBUS 침묵사 (파일 변동) | post=truncdb×mmap | I_mmap_trunc |
| 감시 대상 inode 교체 → watch 침묵 (파일 변동) | post=rmdb_recreate + watch 토큰 | I_watch_recreate (+ctrl) |
| 블로킹 syscall 중 dump (커널 상태) | pre=settle + 잠금 선점 | I_flock_blocked |
| UDP·netlink 소켓 (소켓 분류 완결) | params=udp/netlink | I_udp, I_netlink |

### 5d. 가족별 상세

| 가족 | n | 질문 | 핵심 셀 |
|---|---|---|---|
| **A lifecycle** | 26 | 기동의 어느 라인까지 얼 수 있는가 (hub 있는 15 phase + hub 없는 대조 11 phase) | `A_life_hub_conn1`(여기부터 죽는가), `A_nohub_*`(순수 파서는 전 구간 통과) |
| **B hub** | 24 | 경계 밖 UNIX의 실패 양상 전모 + 처방 실측 | 아래 상세 |
| **C tcp** | 14 | lock 생존 조건과 반증 | 아래 상세 |
| **D memory** | 17 | fail-fast vs 침묵형, 이미지 크기, 반복성 | 아래 상세 |
| **E ops** | 16 | 운영 상황 + 처방 총합 v1 | `E_full_rx`(완전체+처방 생존) |
| **F surface** | 39 | 추가 자원 전수 + RICH line-by-line + 처방 총합 v2 | `F_all_life_*`, `F_all_rx` |
| **G world** | 15 | 상시 배경 세계 안에서의 상호작용 (WORLD=1 전용) | `G_flood_rereg`, `G_mem_heavy` |
| **H issues** | 13 | CRIU GitHub 이슈에서 도출한 함정 | `H_halfclose_tcpest`, `H_scm_pending`, `H_rseq_baseline` |
| **I reality** | 15 | 운영 현실·환경 변동: 3대 발견 밖 문제 표면 | `I_name_squat`, `I_binary_gone`, `I_mmap_trunc`, `I_flock_blocked` |
| **L exhaustive** | 695 | **완전 격자**: 구성 4종(무자원/hub/hub+tcp/만물) × 각 생애주기 전 라인 × **CRIU 옵션 5종 전부** + 자원 단독 19종 × 3라인 × 옵션 5종. "어느 줄을 · 뭘 쥔 앱에서 · 어떤 옵션으로" 의 3차원 전수표 — 기존 가족과 겹치는 점은 재현성 검증을 겸함 | `L_ev_perm_hub_conn1`, `L_one_lockf_file_db_lock` |
| **M sampling** | 24 | **라인 '사이' 검산**: 기동을 임의 시각 12점 × 2옵션에서 저격 — 판정이 그 시각의 phase 지도 예측과 일치해야 하며, 불일치 표본 = 숨은 상태 발견. "38개 phase가 CRIU-구별가능 상태의 전부"라는 동치류 가설의 통계적 확인 | `M_t900_stri` |
| **K gridmap** | 36 | **상황×라인 일관 격자**: 처방(bye)·lock제거·45s정지·자원소실(rmdb/rmshm/rmwd/truncdb)·바이너리교체·이름선점·허브교체·메모리한도 복원·POSIX락 — 각 조작을 전제조건이 성립하는 모든 라인에 적용. "이 실패는 라인 무관인가, 라인 의존인가"를 조작별로 판정 | `K_bye_hub_conn1`, `K_mem700_epg_index`, `K_droplock_tcp_conn` |
| **J fullmap** | 98 | **전 라인 완전 지도**: 만물 구성(모든 자원 ON)의 생애주기 전 38라인 × {strict, permissive} 76셀 — "strict는 db_lock부터, permissive는 hub_conn1부터"의 2중 경계선 가설을 라인 전수로 검증. + 자원별 단독 구성의 해당 라인 18셀(경계 이동의 자원 귀속: 0개=A ↔ 1개=J_one ↔ 전부=J_all 3점 보간). + 기본 구성 hub 라인 × permissive 4셀(gh#772 'dump만 구제' 축) | `J_all_stri_db_lock`, `J_all_perm_hub_conn1`, `J_one_render` |

**B (hub)**: 연결 수 1/2/8 · queue 0/8/32 무관성 → Batch A(selfhub) 대조
(queue 32건까지 완전 복원?) → half-open(no-accept: dump rc=0인데 restore
'Peer unresolved') → `--ext-unix-sk`의 한계선 → **처방**: conns 1/4/8 비용,
queue 유실 명시 관측, hub 다운 세계, 2회 사이클, 기동 중 처방, 정지 15/45s
무해성, permissive 총합의 불가 확정, dump 실패의 비파괴성(`verify_orig`).

**C (tcp)**: strict 거부 → `--tcp-established` 생존(reqresp/stream) → 정지
15/45s → **lock 제거 반증**(`C_st_droplock`: restore rc=0 + PONG ok인데 TCPQ
사망 = rc로 못 잡는 침묵 연결사) → hub+tcp 복합의 첫 에러 순서 → ready 시점
스트리밍 → 비파괴성.

**D (memory)**: heavy(인덱스 300MiB) × 한도 700/500/330/300 보간 →
light+지연touch 침묵사(`D_light_silent`: rc=0·에러 0줄, 수 초 뒤 OOM) →
**반증 대조**(`D_light_norefresh`: touch만 끄면 같은 한도에서 생존 — 원인
확정) → dump 시점별 이미지 크기(db_read/epg_index/reserve/ready) → dirty
갱신 중 반복 3회 → 같은 이미지 재복원/동시복원(PID 충돌) → TV 총량 1708MiB.

**E (ops)**: timerfd/inotify/mmap 단독 → 감시·매핑 대상 소실(rmdb) → 1s
타이머 15s 정지 후 틱 거동 → restore 후 DB 갱신 시 inotify 실동작
(`E_watch_alive`) → **처방 총합 v1**(`E_full_rx`: 완전체 pbs가 bye+tcp_est로
생존 + stream판 + 메모리 제약 동시 + 3회 반복) → gap 0 이행성(측정 캠페인
호환 확인).

**F (surface)**: ① 자원별 격리 16셀 — 스레드(라인 dump 포함), selfpipe,
eventfd, flock/posix ×(strict→dump_fail vs `--file-locks`→구제), shm(+소실
`rmshm`), connected DGRAM(strict/ext_unix — STREAM과 정책이 다른지는 사전
판정 유보한 진짜 미지 셀), 렌더 채널(hub와 동일 에러 라인인지 + 처방이
render까지 끊는지), cwd 소실(`rmwd`). ② **RICH(전부 켠 구성) line-by-line
15셀** — 핵심 가설: 잠금이 hub보다 앞 라인이므로 실패 경계선이 `hub_conn1`이
아니라 `db_lock`으로 당겨진다. 확인되면 "hub만 문제"가 "잠금·hub·render 3중
차단"으로 바뀐다. ③ permissive 도달선 4셀. ④ **처방 총합 v2**(`F_all_rx`:
전 자원 + bye + permissive 생존 — 최종 헤드라인) + 반복/메모리 동시/비파괴성.

**G (world)**: 상시 배경 세계(§5b)에서만 성립하는 상호작용 셀. 소음 낀 세계의
line-by-line 8셀(경계선이 단독 실험과 같은가) → 처방 성립·반복(공유 hub 경합
비용 = 단독 rereg_ms와의 차) → **재등록 flood**(`G_flood_rereg`: 부재 중 밀린
notify 300건이 재등록 순간 폭주 유입 — 처방의 숨은 비용, 단독 실험에선 원리적으로
안 보임) → 45s 부재 후 복귀+폭주 → dirty 노화-소형판 → 세계 물리 안 200MiB
복원(`G_mem_heavy`: memd가 개입하는가 — memd_kills 공변량으로 판독) → 세계에서의
dump 실패 비파괴성. 모든 G 행에는 세계 공변량(up_s/regs/mem_mib/memd_kills)이
`world` 열로 기록된다.

**H (issues)**: CRIU 실사용 이슈를 pbs 문맥으로 번역한 함정 셀. 근거와 셀:
gh#505(ARMv8 실사례) → half-closed TCP는 TCP_REPAIR 불가(`H_halfclose_*`);
PR#2030 → fd 실린 미수신 SCM_RIGHTS 메시지(`H_scm_pending`, 경계 안 대조
`H_scm_selfhub`) 및 timerfd 만기 복원 계보(`H_timer_expire_freeze`);
gh#772 → ext-unix는 dump만 구제(B 가족과 교차 확인); gh#1696 → glibc≥2.35
rseq 자동등록: 평범한 셀이 곧 rseq C/R 검증(`H_rseq_baseline`, CRIU≥3.17 필요 —
라즈베리파이 직결); sqlite -journal 모형 unlink 파일(`H_tmpunlink_*`,
--link-remap/ghost 구제); GLib epoll 실형태(`H_epoll_*`); /dev/urandom 잔류 fd;
hub 재시작 후 복귀(`H_hub_upgraded`: '허브 업그레이드' 시나리오).

**I (reality)**: 3대 발견과 무관하게 운영 중 터질 법한 문제 표면. 프로세스
트리(`I_child_*`: 헬퍼 자식 포함 통째 복원, STAT chld) · **미수거 좀비**
(`I_zombie_steady`: 죽었는데 wait 안 된 자식이 낀 트리, zomb=Z 보존) ·
**보류 시그널**(`I_sigpend_steady`: 블록+큐잉된 USR2가 복원 후에도 보류인가 —
전달돼도 유실돼도 실패) · 앱 자신의 luna 메서드 listen(`I_unix_listen`)과
**이름 선점**(`I_name_squat`: 복원 사이 다른 프로세스가 추상 주소를 차지한
재시작 경합 — EADDRINUSE 계급) · **OTA 바이너리 교체**(`I_binary_gone/back`:
dump~restore 사이 실행파일 소실이면 복원 불가, 같은 경로 복귀면 무해 —
"restore 전 업데이트 금지" 배포 규칙의 근거) · **mmap 파일 절단**
(`I_mmap_trunc`: rc=0으로 살아나고 다음 접근에서 SIGBUS — 침묵사 3호 후보,
live5로만 포착) · **감시 무효화**(`I_watch_recreate`: 대상 파일이 삭제 후
재생성되면 wd가 옛 inode를 가리켜 복원 후 감시가 침묵 — 신설 watch 검증
토큰이 복원 후 실제 자극→이벤트 로그로 판정, 대조군 `I_watch_alive_ctrl`) ·
**블로킹 syscall 안에서의 dump**(`I_flock_blocked`: 스윕이 잠금을 선점해 앱을
flock() 안에 재운 채 dump→restore→해제→획득→기동 완주) · UDP/netlink 소켓
계급 완결(`I_udp/netlink_steady`) · 총합 `I_all_rx`(트리+시그널+listen+UDP까지
얹은 구성 + 처방 — 헤드라인 v3).

### 5e. world 계층 — 상시 배경 세계 (webOS 근사)

판정·인과는 셀 격리(1층)에서, **실전 조건과 시간 축은 상시 세계(2층)**에서 본다.
2층의 규율은 격리가 아니라 **공변량 기록**: 세계의 상태를 셀마다 CSV에 남겨
드리프트를 오염이 아니라 측정 대상으로 만든다.

```bash
pbsprobe/world_up.sh                          # 가벼운 세계 (어디서나)
WORLD_CONSTRAINED=1 sudo pbsprobe/world_up.sh # TV 물리(cgroup+stress+memd) 포함
pbsprobe/world_status.sh                      # 공변량 스냅샷
WORLD=1 [sudo] pbsprobe/pbs_sweep.sh          # 전 가족을 세계 안에서 재실행 (G 포함)
pbsprobe/world_down.sh
```

구성: world hub(ls-hubd의 자리, 재등록 flood 지원 — 'flood' 이름 서비스에만
발동) + 상주 pbs_mock ×N(sam/audiod류의 자리: 버스 소음·배경 RSS) + [옵션]
scenario.yaml 물리 + memd(LMK 모사: 92% 문턱에서 최대 RSS pbs_mock 처형, 로그).
WORLD 모드에서 셀은 `--hub_port`로 세계 hub에 attach하고 세계 cgroup에 편입되며,
noaccept/down_after 셀은 공유 hub와 비호환이라 자동 skip된다. hub는 실기처럼
cgroup 밖에 산다. CSV는 `pbs_matrix_world.csv`로 분리.

권장 3회 실행: ① 무제약(메커니즘) ② CONSTRAINED(TV 물리) ③ world(상시 세계)
— 세 CSV의 verdict diff가 각각 "원인", "TV라서", "세계라서"를 분리해 준다.

---

## 6. 빠른 시작 — 명령 하나

```bash
cd Embed-sim-lab-main
sudo pbsprobe/run_all.sh                 # 빌드→관문(40항목)→시나리오→스윕→요약 전부
CONSTRAINED=1 sudo pbsprobe/run_all.sh   # TV 제약 모드 — CSV/리포트 _tv로 분리
DRYRUN=1 pbsprobe/run_all.sh             # criu 없이 배관 검증 (root 불필요)
sudo pbsprobe/run_all.sh 'F_*'           # 부분 실행 (glob) / RESUME=1 이어가기
```

산출물: `results/pbs_matrix[_tv].csv` + `results/report[_tv].md` + 판정 분포.
소요 대략: 무제약 전체 ~25-40분 (sleep45 ×3 + sleep15 ×3 + live5 다수 포함).

### CONSTRAINED — TV 제약 모드

`failprobe/compat_sweep.sh`의 검증된 블록 이식. `testbed/scenario.yaml` 값으로
스윕 전체에 1회 적용:

```text
cgroup:   memory.max / memory.swap.max / cpu.max / cpuset
stress:   stress-ng 독립 인스턴스 × vm_workers 상주 + cpu_saturate
          + oom_score_adj -800 보호 + 점유 85% 정착 게이트 (미달 시 중단)
storage:  loop + dm-delay + io.max 느린 디스크 — CRIU 이미지가 이 디스크 경유
편입:     pbs_mock과 criu restore가 TV cgroup 안에서 실행. D 가족의
          restore_mem cgroup은 TV cgroup 아래 중첩(한도 합성). hub/feed는
          경계 밖 세계이므로 밖 (실기의 ls-hubd 위치)
```

전제: cgroup v2, stress-ng, dm_delay 모듈, losetup. 정리는 EXIT trap 자동.
주의: TV cgroup 안에서는 D 가족 heavy 셀의 판정이 무제약과 달라질 수 있다 —
버그가 아니라 결과다. 권장 순서: **무제약 전체 → CONSTRAINED 전체 → 두 CSV의
verdict diff** = "TV라서 안 되는 것"의 목록.

### 단계별 실행 / 기타

```bash
pbsprobe/build.sh && bash pbsprobe/selftest.sh
python3 pbsprobe/gen_scenarios.py
sudo pbsprobe/pbs_sweep.sh            # env: CONSTRAINED/RESUME/ONLY_FAMILY/CRIU_BIN/
                                      #      PHASE_TIMEOUT_S/VERIFY_TIMEOUT_S
python3 pbsprobe/summarize_pbs.py > pbsprobe/results/report.md
```

CRIU 탐색 순서: `CRIU_BIN` > `testbed/criu/bin/criu` > 소스 빌드 관례 위치 >
PATH. TV용 정적 크로스 빌드는 pthread 사용으로
`WL_CFLAGS="-O2 -Wall -static -pthread"` (호스트 glibc ≥2.34는 불필요).

---

## 7. 판정 읽는 법

CSV 한 행 = 셀 하나:

```text
dump_rc / restore_rc  CRIU 반환값 — rc=0은 "CRIU 작업 완료"일 뿐이다
img_kib               이미지 크기 (dump 시점 축 분석용)
v_pong                end-to-end 회생 (PONG)
v_stat                상태 무결성 (crc; refresh 0 셀은 dump 전후 동일성까지 요구)
v_hub                 재등록: 앱 PHASE + hub 로그 증가 교차 확인. rereg_ms 병기
v_tcp                 실왕복/수신 진행 — write 성공은 증거가 아니다
v_live5               복원 +5초 생존 — 침묵형 OOM은 이 창에서만 잡힌다
v_resume              pre-ready 셀: 잔여 기동을 이어가 ready 도달 + PONG
verdict               ok | dump_fail | restore_fail | silent_dead | conn_dead |
                      no_service | resume_stalled | orig_intact | launch_fail
dump_err/restore_err  CRIU 첫 에러 (파일:줄 포함 — 클러스터링 소재)
```

`silent_dead`/`conn_dead`가 이 패키지의 존재 이유다: **rc만 보면 성공인데
실제로는 죽어 있는 상태**를 판정으로 분리한다.

새 실패를 놓치지 않는 3중 장치: ① F 가족이 실패 "종류"의 표면을 넓히고
② 가설 불일치 표가 예상 밖(실패든 성공이든)을 자동 목록화하고 ③ `first_err`가
우리가 이름 붙이지 못한 CRIU 에러도 무차별 수집해 `파일:줄` 클러스터로
떠올린다.

### 결과 분석 순서 (권장)

1. `report.md`의 **가설 불일치 표**부터 — 예상 밖 셀이 보고서의 소재
2. 에러 클러스터 — 새로운 `파일:줄`이 있으면 미지의 실패 원인
3. A/F의 line-by-line 표 — 실패 경계선 위치 (hub_conn1인가 db_lock인가)
4. 처방 비용 통계(rereg_ms 분포) — T_restore 확장 상수 후보
5. 무제약 vs CONSTRAINED verdict diff — "TV라서 안 되는 것"

---

## 8. compat_sweep와의 의도적 차이

- **--shell-job 미사용.** pbs_mock을 `setsid` 자체 세션 리더로 띄운다 — 실기
  데몬 형태와 같고, compat_sweep가 하네스 아티팩트로 안던 옵션을 제거.
- **시간 미측정.** 판정 전용. cold vs restore 시간은 계약 플러그인이므로 기존
  러너/캠페인에 `pbs_mock` 항목만 추가하면 된다 (`--phase_gap_ms 0`;
  `E_gap0_steady` 셀이 이행 가능성을 미리 확인). io/compute/mem 축이
  `db_mib`/`parse_iters`/`index_mib`로 appmix 3축에 1:1 대응하므로 예측식
  무재적합 대입이 그대로 성립한다.

---

## 9. 개발 중 수행된 검증 (신뢰 근거)

이 패키지는 CRIU가 없는 컨테이너에서 개발되었고, 다음이 실행으로 확인되었다:

- **selftest 40항목 PASS**: 생애주기 phase 순서 정합, PING/PONG(A6)+
  served_first, STAT 형식·crc 안정성(refresh 0), 처방 2단계(3종 채널 해제→
  재접속, hub 로그 교차, 비용 측정), TCPQ 양 모드, reserve 점진 touch,
  no-accept 기동 완주, SIGTERM(A5), RICH 확장: flock **실보유**(경합 차단으로
  확인), 스레드 카운터 진행, shm 파일·매핑, eventfd 왕복, hub 쪽 LOG 수신,
  render accept.
- **136셀 전체 DRYRUN 그린**: criu 호출만 생략하고 기동·phase 대기·처방·
  검증·CSV 배관 전부를 살아있는 원본에 대해 통과.
- 개발 중 실제 버그 2건을 검증으로 발견·수정: hub poll 스냅샷 오귀속(재접속
  연결이 500ms마다 오살 — revents/배열 크기 불일치), 스윕의 `grep -c` 이중 0
  출력(재등록 오판). 수정 근거와 재현 절차는 대화 기록에 있음.
- **미검증 영역(정직)**: 실제 criu dump/restore 셀(이 커널이 kcmp/sock diag
  차단)과 CONSTRAINED 환경 구성(cgroup2/dmsetup/stress-ng 부재 — 문법·파서만
  검증, 코드는 compat_sweep 검증본의 이식). 실험 머신 첫 실행은
  `sudo pbsprobe/run_all.sh 'C_none_ctrl'` 같은 셀 하나로 env부터 확인 권장.

## 10. 한계

- 커널 의존: x86_64/WSL 결과 ≠ webOS ARM(32bit userland). `uname -r`+CRIU
  버전 기록, 대표 셀의 실기 교차 확인이 최종 단계.
- 모사 밖 자원(dmabuf/GPU fd, netlink, WAL 실매핑)은 이 실험이 원리적으로 못
  본다 — 실기 `/proc/<pid>/fd`·`maps` 대조로만 닫힌다 (§1).
- mock 재등록 비용은 실기의 하한. `C_*_droplock`은 nft/iptables 필요(WSL2 확인).

## 11. 라즈베리파이 데모 (최종 타깃)

Pi 4/5(aarch64, Cortex-A72/A76)는 TV SoC(Cortex-A73)와 같은 ARMv8 계열 — x86
개발기와 실기 TV 사이의 이상적 중간 검증대다.

```bash
sudo pbsprobe/pi_setup.sh      # criu/stress-ng 설치 + 커널 점검 + 판정
sudo pbsprobe/demo_web.sh      # ★ 메인: 브라우저 TV 배너 데모 (http://<Pi IP>:8899)
sudo pbsprobe/demo_live.sh     # 터미널판 같은 장면 (프로젝터에 브라우저가 없을 때)
sudo pbsprobe/demo.sh          # 발견 요약 데모 (7장, 셀 판정)
sudo pbsprobe/run_all.sh       # 전체 1032셀 (Pi 4 기준 ~40-70분)
```

`demo_web.sh`가 발표의 메인 장면이다: 브라우저에 TV 배너처럼 생긴 화면이
뜨고(지금/다음 방송 = 복원되는 인덱스 메모리에서 읽은 값, 시계 = 실시간),
**❄그냥 정지 시도 버튼**을 누르면 처방 없이 dump를 시도해 — luna hub
established 때문에 **거부되는 것**(배너 테두리가 붉게 번쩍 + CRIU 에러 라인
+ "앱은 무사, PONG 확인")을 먼저 보여주고, **❄처방 후 정지 버튼**을 누르면 처방+dump로 프로세스가 소멸하며 화면에 FROZEN
오버레이와 "남은 것은 이미지 N개, M MiB"가 뜨고 — 그 사이에도 화면 시계는
계속 흐른다 — **▶부활 버튼**으로 restore+재등록되면 배너가 재개된다. 정지
직전의 '다음 예고'가 부활 후 '지금 방송'과 일치하면 ★인계 배지가 뜬다:
"낡은 인덱스 + 신선한 시계 = 옳은 채널정보"의 시각적 증명. 청중용 큰
화면에는 브라우저만 띄우면 된다. `demo_live.sh`는 살아있는 pbs의 배너 상태를 초당
출력하다가, 처방+dump로 프로세스가 소멸하는 것을 ps로 보이고, 남은 이미지
파일들을 보여준 뒤(이 사이에도 벽시계는 흐른다), restore로 같은 PID가
부활해 **정지 전 "다음 예고"가 부활 후 "지금 방송"으로 인계되는 것(BANR — 낡은
인덱스가 현재 시각의 옳은 채널정보를 내놓는 증명) · 편성표 crc 보존 ·
가동시간 이어짐(cold 재기동 아님) · hub 재등록**까지 검증과 함께 출력한다.
복원의 경계: 초기화·파싱 산출물(비싼 것)은 복원, 시계 파생값(슬롯/배너)은
재계산, 편성 변경 델타는 재구독으로 재수신 — "어디까지 복원하고 어디부터
실시간인가"의 답이 데모 구조 자체에 들어 있다.
엔터로 장면을 넘기며(PAUSE=0이면 자동), FREEZE_S로 정지 유지 시간을 조절한다.

**정지 중 채널정보 변동은?** 복원 직후의 pbs는 "시계는 맞고(slot은 질의
순간 벽시계로 계산), 캐시는 낡았을 수 있고, 갱신 경로는 살아있는" 상태다 —
놓친 채널변경 notify의 폭주 유입은 `G_flood_rereg`, DB 갱신 감지 회생은
`E_watch_alive`/`I_watch_recreate`, 타이머 만기 경과는 `H_timer_expire_freeze`
가 각각 판정한다. 낡은 캐시로 첫 응답을 낼지는 정책 문제이며, "복원 직후
강제 refresh 1회"가 처방의 자연스러운 확장이다.

Pi 주의 3가지 (pi_setup.sh가 자동 점검):
1. **cgroup memory 컨트롤러가 기본 비활성** — `/boot/firmware/cmdline.txt` 끝에
   `cgroup_enable=memory cgroup_memory=1` 추가 후 재부팅 (D 가족·CONSTRAINED·
   memd 필수 전제).
2. **CRIU ≥3.17 필수** — bookworm의 glibc(≥2.35)가 rseq를 자동 등록하므로
   구버전 CRIU는 복원 후 크래시(gh#1696). apt criu가 낮으면
   `testbed/criu/build.sh`로 v4.2 소스 빌드. `H_rseq_baseline` 셀이 이 축의
   실측 확인이다.
3. swap off 권장(메모리 셀 판정 왜곡 방지), RAM<1.8G 모델은 `D_tv_budget`을
   물리 한도로 대체 해석.

데모 스크립트는 발표 스토리 순서(순수 앱 생존 → 허브 경계선 → 처방+비용 →
rc=0의 배신 2종 → 완전체 구조 → 세계 위 flood 생존)로 7장을 라이브 실행하고
각 장의 판정을 사람 말로 출력한다.

## 12. 중간보고와의 연결

- 표 1: A/F line-by-line 실패 지도 + 에러 클러스터 ("어디서, 왜, 몇 셀")
- 헤드라인: `E_full_rx`/`F_all_rx` — "처방 세트로 완전체가 살고 비용은 X ms"
  (슬라이드 7의 '추후 검증' 칸을 실측으로 대체)
- 침묵형 실패 3종 세트: `C_st_droplock`(연결 침묵사) + `D_light_silent`(지연
  OOM) + 반증 `D_light_norefresh` → "rc 신뢰 불가, liveness check 필수" 논거
- 2단계: pbs_mock을 기존 캠페인에 편입 → T_cold/T_restore 무재적합 대입 +
  rereg_ms를 T_restore 상수항 확장 후보로.
