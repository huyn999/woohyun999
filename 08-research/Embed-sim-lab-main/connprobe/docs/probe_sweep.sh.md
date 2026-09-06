# probe_sweep.sh — 연결·생존 통합 러너

흩어져 있던 `criu_x3/x4/x5/x7/x8` 다섯 러너를 하나로 합친 것. 모두 단일 워크로드
`connprobe --mode ...` 를 dump/restore 하고, 상대 서버는 인라인 파이썬(별도 프로세스)이다.

## 서브커맨드 (원본 대응)

| 커맨드 | 원본 | 하는 일 |
|---|---|---|
| `syn_sent` | criu_x3 | iptables 로 SYN DROP → SYN_SENT 고정 → dump 가능 여부 |
| `syn_alive` | criu_x4 | 진짜 리스너 + SYN DROP → dump/restore → 방화벽 해제 → 연결 성사 확인 |
| `freeze` | criu_x5 | 정지 0/15/45/90s × (서버 idle / streaming) → `freeze_duration.csv` |
| `stream` | criu_x7 | 스트리밍 리더, iptables A(없음)/B(있음) 대조 |
| `roundtrip` | criu_x8 | 스트리밍 + PING→PONG 왕복, iptables A/B 대조 |
| `all` | — | 위 다섯을 순서대로 |

```bash
sudo ./probe_sweep.sh <커맨드>
FREEZE=90 sudo ./probe_sweep.sh roundtrip   # 정지 초 조절 (stream/roundtrip, 기본 45)
CRIU_BIN=/path/criu sudo ./probe_sweep.sh all
```

## 구조

- `run_syn_sent` / `run_syn_alive` / `run_freeze` / `run_stream` / `run_roundtrip` — 서브커맨드.
- `_freeze_case` — freeze 매트릭스의 셀 하나(정지 초 × 서버 송신 여부).
- `_ab_case` — stream/roundtrip 공통 골격(서버 함수·모드·판정선만 파라미터로 다름).
- `_stream_server` / `_pong_server` — 인라인 파이썬 상대 서버.
- 공용: `wait_line`(로그 grep 폴링), `tcp_state`(/proc/net/tcp 상태 파싱).

## 원본과의 차이 (정합성)

- 워크로드가 `/tmp/*.c` heredoc → 단일 `bin/connprobe` 바이너리. 없으면 build.sh 자동 호출.
- 정지 신호 파일은 서브커맨드별 고유(`--resume-file`)로 분리 — 병렬/연속 실행 시 충돌 방지.
- CRIU 옵션(`--shell-job --tcp-established --file-locks --ext-unix-sk --link-remap
  --ghost-limit 64M`), 폴링 간격, 판정 문자열은 원본과 동일.
- 결과·로그: `connprobe/results/`(구 `failprobe/results/` 에서 패키지 자립형으로 이동).

## 주의

root + iptables 필요. iptables 미지원 환경(일부 WSL)에서는 `syn_sent`/`syn_alive`/`stream`/
`roundtrip` 이 iptables 규칙 삽입에서 실패한다. `freeze` 는 iptables 없이 돈다.
