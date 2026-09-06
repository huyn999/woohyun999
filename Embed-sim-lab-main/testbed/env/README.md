# testbed/env — 환경 오케스트레이터

`setup.sh`/`verify.sh`/`teardown.sh`가 `hardware/`(물리 제약, 이번 재작성에서 무변경 이식)와
`policy/`(OS 정책, 미구현 seam)를 얹는다. 설계 근거는
`docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` §5-6.

## 인터페이스: flattened-env, `<run_dir>` 하나

세 스크립트 모두 인자는 **`<run_dir>` 하나뿐**이다. 설정은 위치 인자로 쌓지 않고
`<run_dir>/config.env`(runner의 `lib/config.sh`가 `config_to_env.py` 출력으로 미리 써 둔
`CFG_*` flattened env)에서 읽는다.

```bash
sudo testbed/env/setup.sh    <run_dir>
sudo testbed/env/verify.sh   <run_dir> [settings|preflight|membership <label> <pid>|
                                        process-tree-count <pid>|
                                        generic-recovery <label> <pid> <alive_ms> <min_tree_count>]
sudo testbed/env/teardown.sh <run_dir>
```

**run_dir 정합성 가드**: `hardware/storage.sh`와 `hardware/cpufreq.sh`는 run_id로부터
`$TESTBED_DIR/runs/<run_id>`를 **자체 재계산**한다(무변경 이식된 로직이라 경로 계산 자체는
안 건드림). 따라서 `setup.sh`/`teardown.sh`에 넘기는 `<run_dir>`은 반드시 이 canonical
경로와 같아야 하고, 다르면 (cgroup 누수·침묵 부분정리를 막기 위해) mutation 전에 크게 실패한다
— runner의 `lib/config.sh`(`config_load`)가 항상 이 관례로 `RUN_DIR`을 만든다.

## verb 규약

`hardware/`·`stress/`(자매 디렉터리)와 동형: `<module>.sh apply|verify|restore|cleanup <run_id> ...`.
`env/policy/`도 구현되면 같은 규약을 따른다(`policy/README.md` 참고).

## setup.sh — 호출 순서

1. **hardware**: `hardware/cgroup.sh create` → `hardware/memory.sh apply`(필수) →
   `hardware/cpu.sh apply`(bandwidth/cpuset 중 하나라도 지정 시) →
   `hardware/cpufreq.sh apply`(주파수 지정 시, cpuset 필수) → `hardware/storage.sh apply`
   (`storage.env`를 소싱해 `IMAGE_DIR` 등 핸드오프 받음).
2. **policy** — TODO, 훅 주석만 존재.
3. **state file** — `<run_dir>/state.env`에 `RUN_ID`/`CG_PATH`/`IMAGE_DIR`/제약값/`KERNEL_VERSION`
   등을 기록(런너가 `source`해서 씀).

## verify.sh — 검증 사다리

- `settings`(기본) — L1 readback: 각 hardware 모듈의 `verify` action을 호출해 cgroup 존재·
  `memory.max`/`memory.swap.max`/`cpu.max`/`cpuset.cpus`/storage 설정값이 기대와 일치하는지 확인.
- `preflight` — canary(`sleep 60`)를 대상 cgroup에 join시켜 membership을 사전 검증(L1/L2 경계).
- `membership <label> <pid>` — 실제 PID의 cgroup membership 확인(L2, restore 검증에 사용).
- `process-tree-count <pid>` — 프로세스 트리 크기 카운트(descendant 재귀).
- `generic-recovery <label> <pid> <alive_ms> <min_tree_count>` — L3: 살아있음 + `alive_ms` 동안
  생존 + 정상 state(R/S/D/I) + tree_count ≥ 최소값 + thread/fd 존재. 워크로드-무관 sanity check —
  기능 회생(PONG) 증명은 `runner/lib/probe.sh`가 별도로 한다(계약 §4-A6).

## teardown.sh — 정리 순서

1. `hardware/cpufreq.sh restore`(호스트 전역 DVFS라 가장 먼저, best-effort).
2. policy 원복 — TODO.
3. cgroup destroy 전에 `memory.events`/`memory.peak`/`memory.swap.peak` 스냅샷을 `<run_dir>`로 떠
   둔다(사후 OOM 판단용).
4. teardown 호출자(러너) 자신을 `cgroup_home`(runner의 `cgroup_join_self`가 기록해 둔 원래 자리)
   으로 퇴거시킨 뒤 `hardware/cgroup.sh destroy` — 러너 자신이 멤버로 남아 있으면 cgroup v2가
   비워지지 않거나 자기 자신까지 죽는다.
5. `.criu.cgyard.*`(CRIU가 dump/restore 중 만드는 cgroup-yard tmpfs 마운트, 비정상 종료 시 잔류)를
   이 run 범위 안에서만 정리 — storage umount가 EBUSY로 막히기 전에 먼저 뗀다.
6. `hardware/storage.sh cleanup` — mount/dm/loop 등 live resource 정리(`image_disk.img` 자체는
   run artifact로 남긴다).

## env/policy — 미구현 seam

`policy/README.md` 참고. swap backend/zram/swappiness 등 OS 정책 노브는 이번 재작성 범위
밖이다(설계 스펙 §11 — A/B 패리티 검증 오염 방지, swappiness 등은 per-cgroup이 아닌 시스템
단위 노브라 병렬 실행/teardown 원복 문제가 별도로 있음, webOS 실제 swap 정책도 미확인).
디렉터리 + README + `setup.sh`/`verify.sh`/`teardown.sh`의 주석 훅만 존재 — 구현되면
`hardware`와 동일한 verb 규약(`apply|restore`)을 따른다.
