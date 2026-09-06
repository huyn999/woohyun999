# restore_pressure.sh — 복원 메모리 압박 (구 criu_p2.sh)

질문: **메모리가 모자라 복원이 안 될 때 CRIU 는 정직하게 실패를 알리는가, 아니면
`restore_rc=0` 을 주고 프로세스는 조용히 죽는가?**

넉넉한 환경에서 dump 한 뒤, 복원 cgroup 의 `memory.max` 를 줄여 가며 restore 한다.
두 축:

- **이미지 RSS**: `f_large_heap_l01`(malloc 만, ~8MB) vs `f_large_heap`(300MB 상주) — phase 를
  다이얼로 사용.
- **복원 예산**: `memory.max` = 1024 → 200MB.

```bash
sudo ./restore_pressure.sh
```

산출: `results/restore_pressure.csv`
(phase,image_rss_mb,budget_mb,dump_rc,restore_rc,alive_5s,verify,criu_said).

## 판정

| 관측 | 뜻 |
|---|---|
| `restore_rc≠0` + OOM 에러 | CRIU 가 정직하게 알림 (좋음) |
| `restore_rc≠0` + 엉뚱한 에러 | 실패는 알리되 원인 오보 (주의) |
| `restore_rc=0` + `alive=NO` | ★ 침묵형: 복원했다고 믿는데 죽어 있음 (최악) |
| `restore_rc=0` + `pong_ok` | 정상 |

## 원본과의 차이

criu_p2.sh(=criu_x.sh pressure 의 버그 수정판: 예산마다 새 dump, gap 300ms, cgroup rmdir)를
그대로 쓰되 ROOT 만 repo 루트로 재계산. 의존: `fp_w_qml_app`(webOS 워크로드),
`testbed/runner/cprobe`, `testbed/criu`.
