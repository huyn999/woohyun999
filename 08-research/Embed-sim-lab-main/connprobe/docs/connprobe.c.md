# connprobe.c — 단일 통합 워크로드

CRIU dump 의 **대상 프로세스**. 흩어져 있던 다섯 워크로드(synsent/ss2/cl/rd/c8)를 `--mode`
하나로 합친 것. 상대(서버/피어)는 항상 별도 프로세스(덤프 밖)이며 러너가 띄운다.

## 인터페이스

```
connprobe --mode <M> --port <N> [--resume-file <PATH>]
  --mode         syn_sent | syn_sent_epoll | idle_client | stream_reader | pingpong
  --port         상대가 듣는 loopback TCP 포트 (필수)
  --resume-file  "정지 해제" 신호 파일 (기본 /tmp/webos_probe_go).
                 idle_client / stream_reader / pingpong 에서만 의미.
```

## 생애주기 계약

- 상태 전이마다 stdout 한 줄 + 즉시 `fflush` (러너가 grep 폴링으로 관측). dump 는
  안정 지점(`PHASE ...` / `READY`) 도달 직후에 일어난다.
- 정지 해제는 `--resume-file` 의 **존재**로 신호한다. 복원된 프로세스는 그 파일이 생길 때까지
  정지 지점에서 스핀하다가, 러너의 `touch` 후 검증 코드로 진입한다.

## 모드별 동작 (원본 대응)

| mode | 원본 | 핵심 출력 라인 |
|---|---|---|
| `syn_sent` | criu_x3 synsent.c | `PHASE syn_sent fd=.. errno=..` → 무한 정지 |
| `syn_sent_epoll` | criu_x4 ss2.c | `PHASE syn_sent` → epoll 대기 → `CONNECTED`/`FAILED` |
| `idle_client` | criu_x5 cl.c | `PHASE ready`+`READY` → resume → `ALIVE got=..`/`DEAD_*` |
| `stream_reader` | criu_x7 rd.c | `READY` → recv 루프 → `RESUMED` → `SO_ERROR`/`ALIVE_READ`/`WRITE_OK` |
| `pingpong` | criu_x8 c8.c | `READY` → recv 루프 → `DRAINED` → `VERDICT=ALIVE`/`DEAD` |

## 통합 시 보존한 것 / 바꾼 것

- **보존**: 각 모드의 소켓 조작 순서, 판정 출력 문자열(러너 grep 이 의존), 논블로킹/블로킹
  전환, SO_RCVTIMEO 등 — 원본과 바이트 단위로 동일한 관측이 나오도록.
- **바꾼 것**: 정지 신호를 모드별 하드코딩 파일(`/tmp/cl_go`, `/tmp/rd_go`, `/tmp/c8_go`)에서
  `--resume-file` 인자로. 공통 헬퍼(`connect_loopback`, `wait_resume`,
  `make_blocking_with_timeout`)로 중복 제거.

## 빌드

`build.sh` 가 `gcc -O2 -Wall -o bin/connprobe connprobe.c` 로 빌드. 표준 POSIX 소켓/epoll 만
쓰므로 의존성 없음.
