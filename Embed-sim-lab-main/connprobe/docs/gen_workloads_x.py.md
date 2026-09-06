# gen_workloads_x.py — fp_x_* 생성기

`xmatrix.sh` 가 호출하는 워크로드 생성기. failprobe 의 `gen_workloads.py` 계약·계측·스켈레톤을
재사용해(같은 PHASE/KEEPFD/die 규약), 봉쇄 조건 행렬용 `fp_x_*` 6종을 `testbed/workloads/`
아래에 만든다.

```bash
python3 gen_workloads_x.py --workloads-dir ../testbed/workloads
```

## 생성물 (6 feature → 6 workload)

- `backlog_unix` / `backlog_tcp` — 리스너=워크로드, 커넥터=자식(fork), 미accept.
- `ext_unix_pend` / `ext_tcp_pend` — 외부 xpeer 에 connect, 상대 미accept.
- `ext_unix_est` / `ext_tcp_est` — 외부 xpeer 와 성립 완료(대조군).

`line` 해상도로 생성해 setup 구간의 문장 경계마다 dump 지점을 만든다(`phase_map.csv` 로
역추적). `_UADDR` 매크로가 xpeer 의 UNIX 추상 주소(`criuprobe_xpeer_p<port>`)를 맞춘다.

## 의존

`failprobe/gen_workloads.py` 와 `gen_workloads_v2.py` 를 import 한다(패키지 옆 `failprobe/`
자동 탐색). failprobe 없이는 못 돈다 — 이 파일은 그 프레임워크의 확장축이다.

> 원본 criu_x.sh 는 이 파일을 실행 중 `webos_probe/` 에 heredoc 으로 풀어놓아 기존 패키지를
> 오염시켰다. 이제 이 패키지에 파일로 고정한다.
