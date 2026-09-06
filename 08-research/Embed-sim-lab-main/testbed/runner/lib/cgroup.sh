#!/usr/bin/env bash
# runner/lib/cgroup.sh — uses: CG_PATH RUN_DIR
# 러너 자신을 대상 cgroup에 넣는다 — probe가 워크로드와 동일한 memcg 압박을 받아야 공정 (§6-4)
cgroup_join_self() {
	# teardown(env/teardown.sh)이 destroy 전에 러너 자신을 원래 cgroup으로 되돌릴 수 있도록
	# 현재 위치를 기록해둔다. cgroup 네임스페이스 환경(예: 컨테이너)에서는 "/sys/fs/cgroup"가
	# 보기엔 root처럼 보여도 커널이 보는 실제 계층에서는 non-root일 수 있어(no-internal-process
	# 제약 적용), 무조건 절대 root로 되돌리면 EBUSY가 난다 — 반드시 원래 있던 자리로 복귀해야 한다.
	awk -F: '$1==0{print $NF; exit}' /proc/$$/cgroup > "$RUN_DIR/cgroup_home" 2>/dev/null || true
	echo $$ > "$CG_PATH/cgroup.procs"
}
