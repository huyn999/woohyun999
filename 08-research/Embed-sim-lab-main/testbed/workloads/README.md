# testbed/workloads — 워크로드 계약 v2 (플러그인)

이 문서는 **새 워크로드를 추가하는 사람의 유일한 필독 문서**다. runner(`run_once.sh`/
`run_cold_start.sh`/`run_campaign.sh`)는 워크로드에 대해 아래 계약 말고는 아무것도 모른다 —
"디렉터리 하나 추가 + campaign YAML 한 항목"만으로 새 워크로드가 편입되는 게 목표다.
설계 근거는 `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` §4.

계약은 **행동 규약**(언어 불문)이다. 지금은 C 단일 바이너리 3종(`simple`/`dirty`/`initburst`)뿐이지만,
계약만 지키면 어떤 언어·구현이든 편입될 수 있다.

## 지금 있는 워크로드

| 이름 | 이식원 | 뭘 하나 |
|---|---|---|
| `simple/` | (신규, 재작성 때 소켓 추가) | `--bytes`만큼 anon 메모리 touch 후 서비스 루프. CRIU 고정 오버헤드/kdat baseline |
| `dirty/` | `testbed_old/workloads/target_memory.c` | 상주 메모리 + 주기적 dirty page 갱신 (`--interval_ms`마다 `--dirty_bytes`씩) |
| `initburst/` | `testbed_old/workloads/target_compute.c` | 상주 버퍼 + 시작 시 CPU 컴퓨트 버스트(`--iters`) 후 서비스 루프 |

## A. 필수 조항 (모든 워크로드)

- **A1. 기동 인터페이스**: manifest에 선언된 파라미터를 **named flag**로 받는다
  (`--bytes 52428800 --port 0`). runner는 config의 `params` dict를 `--키 값`으로 기계적으로
  전개할 뿐, 의미를 모른다 (positional 인자는 순서를 runner가 알아야 해서 금지).
  공용 파서 `common/flags.h`(`wl_flag_str`/`wl_flag_long`)를 쓰면 이 조항이 저절로 충족된다.
- **A2. 생애주기 발표**: 상태 전이마다 stdout에 `PHASE <이름> [키=값 ...]` 한 줄.
  - `PHASE ready`는 필수. port·메트릭 등 메타데이터를 키=값으로 동승시킨다
    (`PHASE ready port=34121 compute_ms=812`).
  - 그 외 phase는 자유 — dump해볼 만한 지점마다 발행(`init`, `steady`, `served_first`…).
    이름은 `[a-z0-9_]`만, `ready`는 예약어. campaign의 `dump_at`이 manifest의 `phases`에 없으면
    **설계 시점 에러**(`config_to_env.py`/`expand_campaign.py`가 거부).
  - **at-or-after 의미론**: dump는 "phase 도달 직후" 일어난다 — 관측 지연(로그 폴링 수 ms)과
    freeze 사이에도 워크로드는 계속 진행한다. `ready`/`steady` 같은 안정 상태는 무해하나,
    과도(transient) phase(예: `compute_50`)는 조건 간(특히 busy/idle) 스큐가 생기므로 비교
    주장 시 리포트에 명시한다. "phase에서 정지 후 dump 대기(hold)"는 의도적으로 배제한다 —
    block된 프로세스는 mid-compute 프로세스와 dump 상태가 달라져 현상 자체를 바꾼다.
  - **매 `PHASE` 라인 직후 `fflush(stdout)` 의무.** 파일 리다이렉트 시 stdio는 전체 버퍼링이라
    flush 없으면 runner(`lib/workload.sh`의 `wl_wait_phase`, grep 폴링)가 phase를 못 보고
    dump 타이밍이 밀린다 — 침묵성 버그라 계약으로 조문화했다.
- **A3. 일은 작업 단위로 정의**: 내부 루프는 "N ms 동안"이 아니라 "N iterations". 시간 기반
  정의는 stress-CPU 아래서 일의 양이 변한다(nominal 700ms → busy 실측 938ms 교훈). 시간은
  **측정해 보고**하는 것이지 일을 **정의**하는 게 아니다(`initburst`의 `compute_ms`가 그 예).
- **A4. CRIU dump 가능성**: dump 시점 보유 fd는 stdio 3개(일반 파일 리다이렉트) + listen 소켓
  1개뿐이어야 한다. established/outbound 연결·특수 장치 fd 금지. 단일 프로세스가 기본,
  스레드는 manifest에 선언 시 허용(그 자체가 실험축이 될 수 있음) — 단, 이 필드는 현재
  `config_to_env.py`가 소비하지 않는 **선언용 자리**이고, 지금 3개 워크로드 모두 단일 스레드다.
- **A5. 종료 규약**: SIGTERM에 깨끗이 종료(기본 동작 그대로 두면 충분). teardown이 이에 의존한다.
- **A6. 핑퐁 서버 (필수)**: `ready` 이후 accept, 연결당 `PING\n` → `PONG\n` → close.
  - 근거: "다시 살아났다"의 최저가 end-to-end 증명(`kill -0`/proc 검사는 존재만 증명, PONG은
    스케줄+메인루프+기능 서비스를 증명). first-response 측정 통로이기도 하다.
  - **PONG은 고정 비용** — `PONG\n` 5바이트 항상. 상태 체크섬 등을 응답에 싣지 말 것(첫 응답이
    측정 지표인데 응답 비용이 워크로드마다 달라지면 지표가 오염된다). 상태 무결성 검증은
    측정 창 밖에서 별도 수행한다.
  - `common/probe_server.h`가 이 조항 전체를 구현해 제공한다(아래 참고) — **첫 요청 처리
    직후 `PHASE served_first`를 자동 발행**하므로 워크로드 코드가 따로 챙길 필요 없다.
  - **warm dump 의미론 (old 호환)**: `run_once.sh`는 restore 경로에서 `ready` 도달 후
    `warmup_pings`(config, 기본 1)회 PING을 보낸 뒤 dump한다 → `dump_at: served_first`가
    old의 "워밍업 1회 후 dump"와 정확히 동치. `warmup_pings: 0` + `dump_at: ready`는 "안
    데워진" 새 측정점.
  - **pre-ready dump**: `dump_at`이 `ready` 이전 phase(예: `initburst`의 `init`)면 소켓 없는
    상태로 dump되고, restore 후 first-response에 잔여 init 비용이 포함된다. 버그가 아니라
    측정 대상이다("init 중간에 얼리면 얼마나 이득인가").

## B. 공용 헬퍼

- `common/flags.h` — A1 named-flag 파서.
  - `wl_flag_str(argc, argv, "--name", default)`, `wl_flag_long(argc, argv, "--name", default)`.
  - 미지정 시 `default`, 정수로 파싱 안 되는 값은 `exit(2)`.
- `common/probe_server.h` — A6 핑퐁 서버 (~60줄).
  - `probe_listen(port, &out_port)` — `127.0.0.1:<port>`에 bind/listen (`port==0`이면 커널
    배정 후 `out_port`에 실제 값).
  - `probe_serve_pending(fd, timeout_ms)` — 최대 1개 대기 연결을 서비스, `PING\n`(5바이트,
    A6 프레이밍)을 끝까지 소비한 뒤 `PONG\n` 응답 후 즉시 close(established 연결을 안 남겨야
    dump가 깨끗하다, A4 — 요청을 다 읽고 닫아야 RST가 아닌 정상 FIN으로 닫힌다). 첫 서비스
    성공 직후 `PHASE served_first` + `fflush` 자동 발행.
  - 계약은 행동 규약이므로 이 헤더를 안 쓰고 직접 구현해도 되지만, 3종 모두 이 헤더를
    쓴다(공용 헤더 추출 정당화 — "2+ 호출자" 원칙).

## C. manifest (`workload.yaml`) 필드

| 필드 | 필수 | 의미 |
|---|---|---|
| `name` | ✅ | 디렉터리명과 일치해야 함 — `config_to_env.py`의 `load_manifest()`가 불일치 시 `die()` |
| `params` | ✅ | A1 named flag 선언. `{flag: {default: <값>}}`. campaign/scenario가 지정 안 한 파라미터는 `default` 사용, manifest에 없는 파라미터를 config가 주면 설계 시점 에러 |
| `phases` | ✅ | A2 발행 phase 이름 목록(`ready` 포함). `dump_at`이 이 목록에 없으면 설계 시점 에러 |
| `metrics` | ✅ (빈 리스트 허용) | `PHASE` 라인에 실을 키 이름. 러너(`lib/result.sh`)가 이 이름마다 `wl_` 접두를 붙여 `result.env`에 쓴다(예: `checksum` → `wl_checksum`) — runner 키(`restore_time_s` 등)와 충돌 방지. `collect.py`는 이 접두를 그대로 CSV 열로 옮길 뿐이다 |
| `resident` | ✅ | Option B absorb(총량 흡수)용 **실행 전 예측치**. `mib: <고정 MiB>` 또는 `from_param: <param명>` + `bytes_per_unit: <배수>`(param 단위가 byte가 아니면 환산) + 선택 `overhead_mib: <고정 오버헤드>`. steady(최대) 기준으로 선언 — stress 크기는 워크로드 실행 전에 정해야 하므로, phase별 점유 변화는 현상의 일부로 두고 absorb는 이 선언값으로 계산한다 |
| `calibration` | 선택 | `param`/`metric` — 이 워크로드가 어떤 파라미터를 어떤 시간 메트릭으로 보정하는지 선언. 캠페인 트리거는 campaign YAML의 `sweep.calibrate_from_ms`이고, 그때 `run_campaign.sh` PHASE 1이 이 블록의 `metric`으로 `wl_<metric>`을 읽어 fit하며 `param`을 `--resolve <wl>.<param>`으로 되먹인다(hardening v2 §2 — 하드코딩 아님). `expand_campaign.py`는 `sweep.param == calibration.param`을 전개 시점에 검증한다. `config_to_env.py`는 소비하지 않는다 |
| `threads` | 선택, 기본 1 | A4 선언 자리(다중 스레드 fd 계약). **`config_to_env.py`가 아직 소비하지 않는다** — 지금 3개 워크로드는 전부 단일 스레드 |

**선언 정직성 검증**: 런 종료 후 측정 RSS(`/proc/<pid>/status`의 `VmRSS`)와 선언 `resident`를
비교해 편차가 **max(선언의 10%, 절대 4MiB)** 를 넘으면 `result.env`에 `resident_mismatch=1`
경고(`run_once.sh`/`run_cold_start.sh`의 `step_resident_check`). absorb가 틀어진 런을 식별하기
위함이다 — 절대 하한 4MiB가 없으면 MiB급 소형 선언(initburst 2MiB)에서 고정 잡음(libc/stdio/
소켓, 수백 KiB)이 10% 문턱을 상시 넘어 가드가 오탐으로 죽는다(실측: crossover2 cold 140/140).

**port 규칙**: 측정 런에서는 campaign이 port를 **명시 배정**한다(`0` 금지) — cold 측정 창이
포트를 알아내려 로그를 읽으면 측정 불변식(창 안 스폰 0개)이 깨진다. 3개 workload.yaml 모두
`port` 기본값은 **18080**이다(config 경로 — `config_to_env.py`가 `0`을 명시적으로 거부한다).
kernel-assigned `0`은 `bin/<name> --port 0` 직접 실행 전용이다.

## D. 새 워크로드 추가 3단계

1. **`workloads/<name>/` 디렉터리 생성**: `workload.c`(또는 다른 언어) + `workload.yaml`.
   - `workload.c`는 `common/flags.h` + `common/probe_server.h`를 include하고, `PHASE ready
     port=<p> ...` + `fflush(stdout)`를 찍은 뒤 `probe_serve_pending()` 루프를 돈다
     (`workloads/simple/workload.c`가 가장 짧은 예시).
   - `workload.yaml`은 위 C절 필드를 채운다(`name`은 디렉터리명과 반드시 일치).
2. **campaign YAML(임의 경로, 스펙 §2 관례상 `configs/campaign_*.yaml`)에 1항목 추가**(스펙 §4-C):
   ```yaml
   workloads:
     - name: <new-name>
       sweep: {param: <flag-name>, values_mib: [10, 20, 30]}   # 또는 values / calibrate_from_ms
       dump_at: [ready]                                          # manifest phases 중에서
   ```
3. **그걸로 끝** — `workloads/build.sh`가 `*/workload.c`를 자동 발견해 `bin/<name>`으로 빌드하고
   (`common/*.h` 변경 시 전체 재빌드), `runner/config_to_env.py`/`expand_campaign.py`는 manifest를
   그대로 읽어 검증·전개한다. runner/campaign 코드 수정은 0줄이다.

## 빌드

```bash
testbed/workloads/build.sh
```

멱등: 소스가 `bin/`보다 새로울 때만 재빌드(`common/*.h` 변경 시 전체 재빌드).
산출물은 `workloads/bin/<name>`(`.gitignore`, `gcc -O2 -Wall -I common`).

## 단발 실행 (디버그용)

named flag를 직접 줘서 서비스가 뜨는지만 확인하고 싶으면:

```bash
testbed/workloads/bin/dirty --bytes 52428800 --dirty_bytes 1048576 --interval_ms 200 --port 18080
```

(측정 캠페인에서는 runner가 manifest params를 `--k v`로 자동 전개한다 — 위 명령을 손으로 만들 일은 없다.)
