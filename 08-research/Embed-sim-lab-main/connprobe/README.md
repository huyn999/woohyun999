# connprobe — CRIU TCP 연결·소켓 생존 실험

`failprobe/`, `webos_probe/` 와 나란히 두는 실험 패키지. 이 축의 질문은 하나다:

> **TCP 연결(또는 소켓)을 든 프로세스를 CRIU 로 얼렸다(dump) 되살리면(restore),
> 그 연결이 정말 살아 있는가 — 그리고 dump~restore 사이 정지 시간과 상대의 행동에
> 따라 언제 조용히 죽는가?**

`failprobe`(어떤 자원이 애초에 checkpointable 한가)와 상보적이다. failprobe 가 "가능/불가의
분류학"이라면, connprobe 는 **성립·진행 중인 네트워크 연결의 생존**을 시간·상대 행동 축에서 캔다.

## 왜 이 패키지가 생겼나 (정리 배경)

원래 이 실험들은 repo 최상위에 `criu_x.sh / criu_x3 / x4 / x5 / x7 / x8 / criu_cap / criu_p2`
**여덟 개의 자기 압축 해제형 셸 스크립트**로 흩어져 있었다. 각 스크립트가 자기 워크로드 C 를
`/tmp` 에 heredoc 으로 풀어 빌드했다(synsent.c, ss2.c, cl.c, rd.c, c8.c …). 워크로드가 다섯
갈래로 중복돼 있어 고치기 어려웠다.

정리 결과:

- **다섯 워크로드를 단일 [`connprobe.c`](connprobe.c) 하나로 통합** (`--mode` 로 선택).
- 실험 러너 다섯(x3/x4/x5/x7/x8)을 **하나의 [`probe_sweep.sh`](probe_sweep.sh)** 서브커맨드로.
- 프레임워크 실험 셋(x/cap/p2)은 경로만 고쳐 패키지 안으로.
- **원본 8개는 [`legacy/`](legacy/) 에 그대로 보존** (재현·감사용).

## 폴더 구성

```
connprobe/
├── connprobe.c          단일 통합 워크로드 (--mode syn_sent|syn_sent_epoll|idle_client|stream_reader|pingpong)
├── xpeer.c              외부 피어 (덤프 밖 상대 프로세스; xmatrix/capture 가 씀)
├── build.sh             connprobe.c + xpeer.c → bin/
├── probe_sweep.sh       연결-생존 통합 러너 (구 x3/x4/x5/x7/x8)
├── xmatrix.sh           봉쇄 조건 행렬 (구 criu_x.sh xmatrix) — fp_x_* 생성·스윕
├── capture.sh           세 실패 상황 캡처용 정렬 출력 (구 criu_cap.sh)
├── restore_pressure.sh  복원 메모리 압박: 침묵형 실패 관측 (구 criu_p2.sh)
├── gen_workloads_x.py   fp_x_* 6종 생성기 (failprobe gen 재사용; xmatrix 가 호출)
├── bin/                 빌드 산출물 (connprobe, xpeer)
├── results/             스윕 산출물 (CSV, runs/<셀>/) — 실행 시 생성
├── docs/                파일별 README
└── legacy/              원본 criu_*.sh 8개 (보존)
```

## 통합 워크로드 — 모드 ↔ 원본 대응

`connprobe.c` 한 파일이 다섯 실험의 덤프 대상을 모두 담는다. 상대(서버/피어)는 항상
별도 프로세스(덤프 밖)로, 러너가 띄운다.

| `--mode` | 원본 | 무엇을 재현하나 |
|---|---|---|
| `syn_sent` | criu_x3 / synsent.c | 논블로킹 connect 로 **SYN_SENT** 에 붙잡힌 소켓을 dump 할 수 있나 |
| `syn_sent_epoll` | criu_x4 / ss2.c | 위 + epoll. 복원·방화벽 해제 후 SYN 재전송으로 **연결이 성사**되나 |
| `idle_client` | criu_x5 / cl.c | 성립 연결을 조용히 얼렸다 깨워 write+read 로 생존 확인 (정지 시간 축) |
| `stream_reader` | criu_x7 / rd.c | 계속 recv 하는 스트리밍 앱. iptables 유/무로 RST 여부 비교 |
| `pingpong` | criu_x8 / c8.c | 스트리밍 + 복원 후 **PING→PONG 왕복**까지 확인 (write 성공은 증거 아님) |

정지 해제 신호는 `--resume-file` 의 존재다: 복원된 프로세스는 그 파일이 생길 때까지 정지
지점에서 스핀하고, 러너가 restore 후 `touch` 하면 이어서 검증 코드를 실행한다.

## 빠른 시작

```bash
cd Embed-sim-lab-main
connprobe/build.sh                        # bin/{connprobe,xpeer}

# 연결-생존 실험 (root + iptables 필요; WSL 은 iptables 지원 확인)
sudo connprobe/probe_sweep.sh syn_sent    # SYN_SENT dump 가능한가
sudo connprobe/probe_sweep.sh syn_alive   # 복원 후 연결 성사되나
sudo connprobe/probe_sweep.sh freeze      # 정지 0/15/45/90s × idle/streaming → CSV
sudo connprobe/probe_sweep.sh stream      # iptables 유/무 (스트리밍 리더)
sudo connprobe/probe_sweep.sh roundtrip   # iptables 유/무 + 왕복 검증
sudo connprobe/probe_sweep.sh all         # 다섯 개 전부
FREEZE=90 sudo connprobe/probe_sweep.sh roundtrip   # 정지 시간 조절

# 프레임워크 실험 (failprobe 워크로드 빌드 필요)
sudo connprobe/xmatrix.sh                 # 봉쇄 조건 행렬 (fp_x_* 생성·스윕)
sudo connprobe/capture.sh all             # 캡처용 정렬 출력 (hub/tcp/mem)
sudo connprobe/restore_pressure.sh        # 복원 메모리 압박 (침묵형 실패)
```

전제: `testbed/criu/bin/criu` 빌드 완료. `CRIU_BIN=/path/criu` 로 다른 버전 지정 가능.
결과 CSV·로그는 `connprobe/results/` 아래에 남는다.

## 판정 읽는 법 (요지)

- **연결 죽음(silent)** — CRIU `restore_rc=0` 인데 소켓은 시체. 앱은 살아서 헬스체크(PING/PONG)는
  통과하지만 그 연결 하나가 증발한 상태. dump~restore 정지 중 상대가 RST 를 보냈을 때 발생.
- **iptables 차단** — dump~restore 구간에 상대→나 패킷을 막아야 RST 를 피한다(CRIU 공식 가이드).
  `stream`/`roundtrip` 의 A(없음)/B(있음) 대조가 그 필요성을 실측한다.
- **왕복이 유일한 증거** — `write()` 성공은 커널 송신 버퍼에 넣기만 해도 나므로 생존 증거가
  아니다. `roundtrip` 의 PING→PONG 만이 end-to-end 생존을 확정한다.

## 한계 / 주의

- 커널 의존: WSL2/x86_64 결과 ≠ webOS/ARM. iptables 미지원 환경(일부 WSL)에서는 SYN_SENT/
  스트리밍 실험이 돌지 않는다. 측정 시 `uname -r` + CRIU 버전 기록.
- 상대 서버/피어는 loopback 파이썬/xpeer 프록시다. 실제 원격 RTT·중간 장비는 모사 밖.
- 자세한 파일별 설명은 [`docs/`](docs/) 참고.
