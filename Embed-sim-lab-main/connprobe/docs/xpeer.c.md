# xpeer.c — 외부 피어 (덤프 밖 상대)

criu_x.sh 에서 추출. `xmatrix.sh` / `capture.sh` 가 셀마다 워크로드보다 먼저 띄우는 상대
프로세스. `criu dump -t <워크로드>` 의 트리에 **들어가지 않는다** — 즉 "소켓의 반대편이
경계 밖에 있는" 조건을 만든다.

## 인터페이스

```
xpeer --port <N> [--no-accept]
  --port       UNIX 추상 소켓 "criuprobe_xpeer_p<N>" + TCP 포트 <N>+3000 을 listen
  --no-accept  accept 하지 않음 → 연결이 백로그에 걸린 채 방치
               (= 상대가 아직 accept 안 한 "진행 중" 창; luna 등록/HLS 수립 재현)
```

## 왜 별도 프로세스인가

CRIU 의 소켓 dump 는 "소켓의 양 끝이 모두 덤프 집합 안"일 때와 "반대편이 밖"일 때 판정이
다르다. 워크로드 안에서 self-loopback 으로 연결하면 두 조건이 섞인다. xpeer 를 덤프 밖의
독립 프로세스로 두어 그 교란을 제거한다.

- `est` (accept 완료) — 성립된 외부 연결의 dump/restore
- `pend` (`--no-accept`) — 상대가 아직 안 받은 진행 중 연결 = 실전의 위험 창

## 빌드

`build.sh` 가 `bin/xpeer` 로 빌드한다. `probe_sweep.sh` 는 이 파일을 쓰지 않는다(그쪽은
파이썬 서버를 상대로 씀). `xmatrix.sh`/`capture.sh` 전용.
