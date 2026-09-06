# env/policy — 미래 자리 (이번 재작성 범위 밖)

swap backend(none/zram/emmc_sim)·memory.swap.max·vm.swappiness 등 OS 정책 노브.
PLAN.md §5 참조 (상세 노브 Tier 표는 git history의 구 PLAN_FULL §4.2). 미구현 근거·증분 추가 계획: 스펙 §11.
setup.sh의 주석 훅( policy/*.sh apply )이 진입점이 된다.
verb 규약: <module>.sh apply|restore <run_id> … (hardware와 동형)
