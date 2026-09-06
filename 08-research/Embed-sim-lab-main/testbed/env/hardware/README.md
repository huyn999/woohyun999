# testbed/env/hardware — 물리 제약 모듈

cgroup v2 위에 얹는 물리적 제약 5종. 재작성에서 **무변경 이식**됐다(검증된 로직, 인터페이스도
그대로) — `env/setup.sh`/`verify.sh`/`teardown.sh`가 오케스트레이션하고, 여기 있는 스크립트는
직접 손으로 부를 일이 거의 없다(디버그 제외).

verb 규약은 전부 `<module>.sh <verb> <run_id> ...`(positional 인자, 이 레이어는 flattened-env
경계 밖 — `env/*.sh`가 config.env에서 값을 뽑아 여기로 넘긴다).

| 모듈 | verb | Usage | 모사 대상 |
|---|---|---|---|
| `cgroup.sh` | `create`&#124;`destroy`&#124;`verify` | `cgroup.sh <verb> <run_id>` | cgroup v2 디렉터리 골격(`/sys/fs/cgroup/criu_test_<run_id>`)만 — 자원 한도는 관여 안 함. `destroy`는 잔여 프로세스 SIGKILL 후 `rmdir`(1회 재시도) |
| `memory.sh` | `apply`&#124;`verify` | `memory.sh <verb> <run_id> <memory_max> [swap_max]` | `memory.max`(RAM ceiling) + `memory.swap.max`(swap escape guard, 기본 0). IEC 표기(`256M`,`1G`)/`max` 허용. destroy 없음 — cgroup destroy가 디렉터리째 지움 |
| `cpu.sh` | `apply`&#124;`verify` | `cpu.sh <verb> <run_id> <bandwidth_cores\|max> [cpuset_cpus]` | `cpu.max`(CFS bandwidth, period 100ms) + `cpuset.cpus`(실행 가능 코어 집합) |
| `cpufreq.sh` | `apply`&#124;`restore`&#124;`verify` | `cpufreq.sh apply <run_id> <freq_khz> <cpuset_cpus>` / `cpufreq.sh restore <run_id>` | 대상 코어의 절대 DVFS 클럭 고정(`scaling_min/max_freq`를 한 점으로). **호스트 전역 상태**(cgroup 밖) — `cpuset_cpus` 없이는 거부(전역 clamp 금지), `apply`가 원래값을 `<run_dir>/cpufreq.orig`에 저장하고 `teardown.sh`가 항상 `restore` 호출 |
| `storage.sh` | `apply`&#124;`verify`&#124;`cleanup` | `storage.sh <verb> <run_id> <enabled> <capacity> <rbps\|max> <wbps\|max> [delay_enabled] [read_ms] [write_ms]` | CRIU image 저장소: loop-backed ext4(capacity) + cgroup `io.max`(rbps/wbps) + dm-delay(read/write latency). `<run_dir>/storage.env`로 `IMAGE_DIR` 등을 핸드오프. `cleanup`은 mount/dm/loop만 정리, `image_disk.img`는 run artifact로 남김 |

## 특이점

- **`cpufreq.sh`만 호스트 전역이다.** 다른 4개는 cgroup 삭제로 자동 원복되지만, DVFS는 그렇지
  않다 — `teardown.sh`가 가장 먼저(다른 정리보다 우선) `restore`를 호출해 어떤 경우에도 호스트
  주파수가 풀리게 한다.
- **`storage.sh`/`cpufreq.sh`는 `run_id`로부터 `$TESTBED_DIR/runs/<run_id>`를 자체 재계산**한다
  (무변경 이식이라 이 계산 로직 자체도 그대로) — `env/setup.sh`/`teardown.sh`가 받는 `<run_dir>`이
  이 canonical 경로와 다르면 `env/README.md`에 적힌 정합성 가드가 mutation 전에 즉시 실패시킨다.
- `memory.sh`/`cpu.sh`는 `destroy`/`cleanup` action이 없다 — `cgroup.sh destroy`가 디렉터리째
  지우면 그 안의 컨트롤러 설정(`memory.max`, `cpu.max`, `cpuset.cpus`)도 함께 사라지기 때문.
