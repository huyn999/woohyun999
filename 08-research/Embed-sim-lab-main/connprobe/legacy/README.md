# legacy/ — 원본 자기 압축 해제형 스크립트 (보존)

정리 이전, repo 최상위에 흩어져 있던 여덟 개의 원본 스크립트. **재현·감사용으로 그대로
보존**한다. 각 스크립트는 자기 워크로드 C 를 `/tmp` 에 heredoc 으로 풀어 빌드했다.

| 원본 | 대체물 (connprobe 패키지) |
|---|---|
| `criu_x3.sh` (synsent.c) | `probe_sweep.sh syn_sent` + `connprobe.c --mode syn_sent` |
| `criu_x4.sh` (ss2.c) | `probe_sweep.sh syn_alive` + `--mode syn_sent_epoll` |
| `criu_x5.sh` (cl.c) | `probe_sweep.sh freeze` + `--mode idle_client` |
| `criu_x7.sh` (rd.c) | `probe_sweep.sh stream` + `--mode stream_reader` |
| `criu_x8.sh` (c8.c) | `probe_sweep.sh roundtrip` + `--mode pingpong` |
| `criu_x.sh` (xpeer.c + gen_workloads_x.py) | `xmatrix.sh` (+ `xpeer.c`, `gen_workloads_x.py`) |
| `criu_cap.sh` | `capture.sh` |
| `criu_p2.sh` | `restore_pressure.sh` |

## 주의

- 이 스크립트들은 `ROOT` 를 **자기 위치**로 잡는다. 원래 repo 최상위에 있었기에 `ROOT`=repo
  루트였다. `legacy/` 에서 그대로 실행하면 `$ROOT/testbed/...` 경로가 깨진다 — 실행은
  상위 패키지(`connprobe/*.sh`)를 쓸 것. 이 파일들은 **참조용**이다.
- 원본이 궁금할 때(정확히 어떤 소켓 조작을 했는지, 판정 문자열이 무엇이었는지)의 근거로 둔다.
  통합본 `connprobe.c` 는 이들과 동일한 관측이 나오도록 만들었다.
