# testbed 전면 재작성 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 검증된 구조를 유지하며 testbed를 계약 기반 플러그인 구조로 재작성하고, CRIU 4.2를 repo 내 vendoring하며, A/B 패리티 120런으로 old와 동치임을 증명한다.

**Architecture:** old 코드(`testbed_old/`)를 동작 스펙으로 삼아 모듈별 이식+재구성. 두 러너의 복붙 중복을 `runner/lib/` 8모듈로 단일화(특히 측정 창 `lib/probe.sh`), 워크로드는 디렉터리+manifest 플러그인(§4 계약), campaign은 python 전개 + bash 실행.

**Tech Stack:** bash (측정·오케스트레이션), C (workload/probe, gcc), python3 (YAML 전개·수집·요약, 표준 라이브러리만), CRIU v4.2 (vendored+patched), cgroup v2, stress-ng, dm-delay.

**Spec:** `docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md` — 이하 "스펙". 모든 태스크는 스펙 §6 측정 불변식 20개를 암묵 요구사항으로 갖는다.

## Global Constraints

- 언어: bash + C + python3 표준 라이브러리만. 새 언어/외부 pip 패키지 금지.
- CRIU: upstream tag **v4.2** + `testbed/criu/kdat-shm.patch`. 러너는 `testbed/criu/bin/criu`만 사용 (`CRIU_BIN` override 허용), PATH의 criu 사용 금지.
- YAML 파싱은 **python만** (bash에서 YAML 읽기 금지). bash는 flattened env만 소비.
- `runner/lib/`에는 **두 러너 공용 코드만** (2+ 호출자 규칙). 호출자 1개인 코드는 러너 파일 in-file 함수.
- lib가 설정하는 전역은 모듈 접두: `PROBE_*`, `WL_*`, `STRESS_*`, `SNAP_*`, `RESULT_*`, `CFG_*`.
- 모듈 함수 명명: `<module>_<verb>` (예: `probe_first_response`, `wl_launch`).
- positional 인자 누적 금지: env/setup.sh 등은 flattened env 파일 경로 하나만 받는다.
- 측정 창(§6-1~3): 창 안 외부 스폰은 cprobe뿐. `kill -0`(빌트인) → cprobe → `$EPOCHREALTIME`(빌트인). 폴링 5ms(`sleep 0.005`), 폴 수는 창 밖 사전계산.
- 측정 런의 포트는 expander가 명시 배정 (base 18100+). `port=0`은 수동 실행 전용.
- 모든 bash 스크립트: `set -euo pipefail` + `bash -n` + shellcheck 통과.
- 실행 테스트는 root 필요 (`sudo`). dm-delay/loop 디바이스 사용 가능 호스트 전제.
- 동작이 바뀌는 디렉터리의 README는 같은 커밋에서 갱신 (Task 17에서 총정리, 그 전 태스크는 새 파일의 머리주석으로 대신).

## 이식(port) 규약

old 코드는 repo 안(`testbed_old/`)에 그대로 있으므로, 검증된 로직 블록은 계획에 재전사하지 않고 **정확한 파일:함수(또는 라인) 참조 + 변경 지시**로 이식한다. 이식 태스크에서 "이식: `testbed_old/X` `함수명`"은 해당 함수 본문을 복사한 뒤 명시된 변경만 가하라는 뜻이다. 신규 파일은 계획에 전체 코드를 싣는다.

## 태스크 ↔ 스펙 §9 마이그레이션 단계 대응

| 스펙 단계 | 태스크 |
|---|---|
| 1 testbed_old | Task 1 |
| 2 criu/ | Task 2 |
| 3 workloads/ | Task 3–6 |
| 4 env/ | Task 7 |
| 5 stress/ | Task 8 |
| 6 runner/ | Task 9–13 |
| 6b campaign | Task 14–15 |
| 7 python | Task 9, 16 |
| 8 README·PLAN | Task 17 |
| 9 검증 | Task 18–20 |

---

### Task 1: testbed_old/ 동결 이동

**Files:**
- Move: `testbed/{env,runner,stress,workloads,configs,scenario.yaml}` → `testbed_old/`
- Create: `testbed_old/README.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `testbed_old/` = 이후 모든 이식 태스크의 소스 경로. `testbed/experiments/`, `testbed/runs/`, `testbed/criu/kdat-shm.patch`는 제자리.

- [ ] **Step 1: 코드 디렉터리만 git mv**

```bash
cd /root/Embed-sim-lab
mkdir testbed_old
git mv testbed/env testbed/runner testbed/stress testbed/workloads testbed/configs testbed/scenario.yaml testbed_old/
```

- [ ] **Step 2: 데이터가 안 딸려갔는지 확인**

Run: `ls testbed/ && ls testbed_old/`
Expected: `testbed/` = `criu/ experiments/ runs/` (+잔여 캐시), `testbed_old/` = `configs/ env/ runner/ scenario.yaml stress/ workloads/`

- [ ] **Step 3: testbed_old/README.md 작성**

```markdown
# testbed_old — 동결된 참조 스펙 (2026-07-03)

2026-07 재작성 이전의 testbed 코드. **수정 금지, 참조 전용.**
재작성의 동작 스펙이며, A/B 패리티(spec §8) 검증 통과 전까지 진실의 원천이다.
필요 시 그대로 실행 가능 (runs는 testbed_old/runs에 생김).
재작성 설계: docs/superpowers/specs/2026-07-03-testbed-rewrite-design.md
패리티 검증: (Task 20 통과 후 날짜 기입)
```

- [ ] **Step 4: .gitignore에 새 빌드 산출물 추가**

`.gitignore`에 아래 3줄 추가 (기존 내용 유지):

```
testbed/criu/bin/
testbed/criu/.build/
testbed/workloads/bin/
```

- [ ] **Step 5: 이전 참조 무결성 확인 후 커밋**

Run: `grep -rn "testbed/runner\|testbed/env\|testbed/stress\|testbed/workloads" reports/*.py | head`
Expected: `make_wsk_figures.py`는 `testbed/experiments/...`만 참조하므로 매치 없음 (매치가 있으면 해당 스크립트가 old 코드를 참조하는 것 — 내용 확인 후 testbed_old로 경로 수정).

```bash
git add -A && git commit -m "rewrite(1/9): testbed 코드 디렉터리를 testbed_old/로 동결 (데이터는 제자리)"
```

---

### Task 2: CRIU 4.2 vendoring (build.sh + 검증)

**Files:**
- Create: `testbed/criu/build.sh`, `testbed/criu/README.md`
- Exists: `testbed/criu/kdat-shm.patch` (커밋 0e5aa60에서 구출)

**Interfaces:**
- Produces: `testbed/criu/bin/criu` (v4.2 + kdat patch). 러너(Task 12–13)는 `CRIU_BIN="${CRIU_BIN:-$TESTBED_DIR/criu/bin/criu}"`로 소비.

- [ ] **Step 1: build.sh 작성**

```bash
#!/usr/bin/env bash
# criu/build.sh — CRIU v4.2 + kdat-shm.patch 재현 빌드 (멱등)
# 산출물: testbed/criu/bin/criu   (스펙 §7)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$DIR/.build"
TAG="v4.2"

# 1. 의존성 확인 — 없으면 목록 출력 후 중단
missing=()
for pkg in gcc make pkg-config protoc-c; do
	command -v "$pkg" >/dev/null || missing+=("$pkg")
done
for lib in libprotobuf-c libnet libnl-3.0; do
	pkg-config --exists "$lib" 2>/dev/null || missing+=("$lib(dev)")
done
if ((${#missing[@]})); then
	echo "ERROR: missing deps: ${missing[*]}" >&2
	echo "hint: apt install build-essential protobuf-c-compiler libprotobuf-c-dev libnet1-dev libnl-3-dev pkg-config libcap-dev libbsd-dev" >&2
	exit 1
fi

# 2. clone (멱등: 이미 있으면 tag 일치만 확인)
if [[ ! -d "$BUILD/criu" ]]; then
	mkdir -p "$BUILD"
	git clone --depth 1 --branch "$TAG" https://github.com/checkpoint-restore/criu "$BUILD/criu"
fi
got_tag="$(git -C "$BUILD/criu" describe --tags 2>/dev/null || true)"
[[ "$got_tag" == "$TAG" ]] || { echo "ERROR: $BUILD/criu is '$got_tag', want $TAG (rm -rf $BUILD to refetch)" >&2; exit 1; }

# 3. patch 적용 (이미 적용돼 있으면 통과, 아니면 적용 — 그 외는 버전 드리프트로 간주 중단)
if git -C "$BUILD/criu" apply --reverse --check "$DIR/kdat-shm.patch" 2>/dev/null; then
	echo "patch: already applied"
elif git -C "$BUILD/criu" apply --check "$DIR/kdat-shm.patch" 2>/dev/null; then
	git -C "$BUILD/criu" apply "$DIR/kdat-shm.patch"
	echo "patch: applied"
else
	echo "ERROR: kdat-shm.patch does not apply to $TAG (drift?)" >&2; exit 1
fi

# 4. build → bin/criu
make -C "$BUILD/criu" -j"$(nproc)"
mkdir -p "$DIR/bin"
cp "$BUILD/criu/criu/criu" "$DIR/bin/criu"

# 5. 검증 출력
"$DIR/bin/criu" --version
if strings "$DIR/bin/criu" | grep -q '/dev/shm/criu.kdat'; then
	echo "kdat patch: OK (/dev/shm/criu.kdat present in binary)"
else
	echo "ERROR: kdat patch missing from binary" >&2; exit 1
fi
```

- [ ] **Step 2: README.md 작성**

```markdown
# testbed/criu — vendored CRIU 4.2

- `kdat-shm.patch`: kdat 캐시 경로를 `/dev/shm/criu.kdat`로 (이 샌드박스의 /run은
  overlayfs라 CRIU가 캐시 보존을 거부; /dev/shm은 tmpfs. 실호스트/webOS TV는 /run이
  tmpfs라 stock으로 복원 가능). 스펙 §1·§7 참조.
- `build.sh`: upstream v4.2 clone → patch → make → `bin/criu` (멱등).
- 러너는 `bin/criu`만 사용 (`CRIU_BIN` env로 override 가능). PATH criu 미사용.
- 버전 pin 근거: 기존 720런(wsk_redesign)과 동일 엔진 → 비교성 유지.
```

- [ ] **Step 3: 정적 검사 + 빌드 실행**

Run: `bash -n testbed/criu/build.sh && shellcheck testbed/criu/build.sh && sudo testbed/criu/build.sh`
Expected: 마지막 두 줄이 `Version: 4.2` 와 `kdat patch: OK (...)`

- [ ] **Step 4: kdat 동작 확인 (패치가 실효하는지)**

```bash
sudo rm -f /dev/shm/criu.kdat
sudo testbed/criu/bin/criu check >/dev/null 2>&1 || true
ls -la /dev/shm/criu.kdat
```

Expected: `/dev/shm/criu.kdat` 파일이 생성돼 있음 (kdat 캐시가 tmpfs에 저장됨 = kdat ON 가능).

- [ ] **Step 5: Commit**

```bash
git add testbed/criu && git commit -m "rewrite(2/9): CRIU v4.2 vendoring — build.sh(멱등)+README, kdat /dev/shm 패치 검증"
```

---

### Task 3: workloads/common — probe_server.h + flags.h

**Files:**
- Create: `testbed/workloads/common/probe_server.h`, `testbed/workloads/common/flags.h`
- Test: `/tmp/claude-0/.../scratchpad/test_probe_server.c` (scratchpad, 커밋 안 함)

**Interfaces:**
- Produces (모든 워크로드가 사용):
  - `int probe_listen(int port, int *out_port)` — 127.0.0.1 listen fd 반환, 실제 포트 out.
  - `int probe_serve_pending(int lfd, int timeout_ms)` — 최대 1개 연결 서비스(PING→PONG), 서비스했으면 1, 타임아웃 0. **첫 서비스 직후 `PHASE served_first` 자동 발행+fflush** (스펙 §4-A6).
  - `long wl_flag_long(int argc, char **argv, const char *name, long def)` / `const char *wl_flag_str(...)` — named flag 파서 (스펙 §4-A1).

- [ ] **Step 1: probe_server.h 작성**

```c
/* workloads/common/probe_server.h — 계약 §4-A6 핑퐁 서버 (전 워크로드 공용)
 * PONG은 고정 비용("PONG\n" 5바이트) — 가변 작업 싣기 금지 (스펙 §6-6).
 * 첫 요청 처리 직후 PHASE served_first를 자동 발행한다 (warm dump 의미론, §4-A6). */
#ifndef PROBE_SERVER_H
#define PROBE_SERVER_H
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int probe_served_first_ = 0;

/* 127.0.0.1:<port>에 listen. port==0이면 커널 배정, *out_port에 실제 포트. 실패 시 exit(1). */
static int probe_listen(int port, int *out_port)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) { perror("probe_listen: socket"); exit(1); }
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in a;
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)port);
	if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("probe_listen: bind"); exit(1); }
	if (listen(fd, 8) < 0) { perror("probe_listen: listen"); exit(1); }
	socklen_t len = sizeof(a);
	if (getsockname(fd, (struct sockaddr *)&a, &len) == 0 && out_port)
		*out_port = ntohs(a.sin_port);
	return fd;
}

/* 최대 1개 대기 연결을 서비스: "PING"이면 "PONG\n" 응답 후 close.
 * timeout_ms 동안 연결 없으면 0 반환. 서비스했으면 1.
 * dump 시점에 established 연결이 남지 않도록 요청당 즉시 close (계약 §4-A4). */
static int probe_serve_pending(int lfd, int timeout_ms)
{
	struct pollfd p = { .fd = lfd, .events = POLLIN };
	int r = poll(&p, 1, timeout_ms);
	if (r <= 0)
		return 0;
	int c = accept(lfd, NULL, NULL);
	if (c < 0)
		return 0;
	char buf[16];
	ssize_t n = read(c, buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = 0;
		if (strncmp(buf, "PING", 4) == 0)
			(void)!write(c, "PONG\n", 5);
	}
	close(c);
	if (!probe_served_first_) {
		probe_served_first_ = 1;
		printf("PHASE served_first\n");
		fflush(stdout);   /* 계약 §4-A2 fflush 의무 */
	}
	return 1;
}
#endif
```

- [ ] **Step 2: flags.h 작성**

```c
/* workloads/common/flags.h — 계약 §4-A1 named flag 파서 (전 워크로드 공용)
 * 모든 파라미터는 "--name value" 형태. 미지정 시 default. 잘못된 값은 exit(2). */
#ifndef WL_FLAGS_H
#define WL_FLAGS_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *wl_flag_str(int argc, char **argv, const char *name, const char *def)
{
	for (int i = 1; i + 1 < argc; i++)
		if (strcmp(argv[i], name) == 0)
			return argv[i + 1];
	return def;
}

static long wl_flag_long(int argc, char **argv, const char *name, long def)
{
	const char *s = wl_flag_str(argc, argv, name, NULL);
	if (!s)
		return def;
	char *end;
	long v = strtol(s, &end, 10);
	if (*end != '\0') {
		fprintf(stderr, "bad value for %s: %s\n", name, s);
		exit(2);
	}
	return v;
}
#endif
```

- [ ] **Step 3: 컴파일+동작 테스트 (scratchpad)**

`/tmp/claude-0/-root-Embed-sim-lab/*/scratchpad/test_probe_server.c`:

```c
#include "../../../root/Embed-sim-lab/testbed/workloads/common/probe_server.h"
#include "../../../root/Embed-sim-lab/testbed/workloads/common/flags.h"
/* 주의: 위 상대경로 대신 -I 로 include 경로를 주는 편이 안전:
 *   gcc -O2 -I/root/Embed-sim-lab/testbed/workloads/common -o t t.c
 *   그 경우 #include "probe_server.h" / "flags.h" 로 작성 */
int main(int argc, char **argv)
{
	long port = wl_flag_long(argc, argv, "--port", 0);
	int p;
	int fd = probe_listen((int)port, &p);
	printf("PHASE ready port=%d\n", p);
	fflush(stdout);
	for (int i = 0; i < 3; i++)
		probe_serve_pending(fd, 5000);
	return 0;
}
```

Run:

```bash
S=/tmp/claude-0/-root-Embed-sim-lab/*/scratchpad
gcc -O2 -I testbed/workloads/common -o "$S"/tps "$S"/test_probe_server.c
"$S"/tps --port 18999 & sleep 0.3
exec 3<>/dev/tcp/127.0.0.1/18999 && printf 'PING\n' >&3 && head -1 <&3
```

Expected: 서버 stdout에 `PHASE ready port=18999` → 클라이언트에 `PONG` → 서버 stdout에 `PHASE served_first`

- [ ] **Step 4: Commit**

```bash
git add testbed/workloads/common && git commit -m "rewrite(3/9a): workloads/common — probe_server.h(핑퐁+served_first 자동발행)+flags.h"
```

---

### Task 4: workloads/build.sh + simple/ (계약 v2 신규 작성)

**Files:**
- Create: `testbed/workloads/build.sh`, `testbed/workloads/simple/workload.c`, `testbed/workloads/simple/workload.yaml`

**Interfaces:**
- Consumes: Task 3의 `probe_listen`/`probe_serve_pending`/`wl_flag_*`.
- Produces: `workloads/bin/<name>` 바이너리 규약 (build.sh가 `<dir>/workload.c` 발견·빌드). manifest 스키마 인스턴스 1호.

- [ ] **Step 1: build.sh 작성 (디렉터리 발견·멱등 빌드)**

```bash
#!/usr/bin/env bash
# workloads/build.sh — 플러그인 발견·빌드 (멱등): */workload.c → bin/<dirname>
# 소스가 bin보다 새로울 때만 재빌드. common/ 헤더 변경 시 전체 재빌드.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DIR/bin"
common_newest="$(find "$DIR/common" -name '*.h' -newer "$DIR/bin" 2>/dev/null | head -1 || true)"
for src in "$DIR"/*/workload.c; do
	name="$(basename "$(dirname "$src")")"
	out="$DIR/bin/$name"
	if [[ ! -x "$out" || "$src" -nt "$out" || -n "$common_newest" ]]; then
		gcc -O2 -Wall -I "$DIR/common" -o "$out" "$src"
		echo "built: bin/$name"
	else
		echo "up-to-date: bin/$name"
	fi
done
```

- [ ] **Step 2: simple/workload.c 작성**

old `target_simple`(소켓 없음)의 계약 v2 승계: anon 메모리 점유 + 핑퐁 (§4-A6 필수화로 소켓 획득).

```c
/* workloads/simple/workload.c — 최소 상주 워크로드 (계약 v2)
 * --bytes 만큼 anon 메모리를 잡아 touch(dirty)한 뒤 서비스 루프.
 * PHASE: ready → (probe_server가 served_first 자동 발행) */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "flags.h"
#include "probe_server.h"

int main(int argc, char **argv)
{
	long bytes = wl_flag_long(argc, argv, "--bytes", 52428800);
	long port = wl_flag_long(argc, argv, "--port", 0);

	unsigned char *buf = malloc((size_t)bytes);
	if (!buf) { fprintf(stderr, "simple: malloc(%ld) failed\n", bytes); return 1; }
	for (long i = 0; i < bytes; i += 4096)   /* 실제 상주시키기 (RSS = 선언 resident) */
		buf[i] = (unsigned char)(i & 0xff);

	int p;
	int fd = probe_listen((int)port, &p);
	printf("PHASE ready port=%d bytes=%ld\n", p, bytes);
	fflush(stdout);

	for (;;)
		probe_serve_pending(fd, 1000);
	free(buf);   /* not reached; SIGTERM 기본 동작으로 종료 (§4-A5) */
	return 0;
}
```

- [ ] **Step 3: simple/workload.yaml 작성**

```yaml
name: simple
params:
  bytes: {default: 52428800}
  port:  {default: 0}        # 0 = kernel-assigned (수동 단발 전용 — 스펙 §4-B port 규칙)
phases: [ready, served_first]
metrics: []
resident:
  from_param: bytes
  bytes_per_unit: 1
  overhead_mib: 2
```

- [ ] **Step 4: 빌드 + 계약 준수 테스트**

```bash
bash -n testbed/workloads/build.sh && shellcheck testbed/workloads/build.sh
testbed/workloads/build.sh
testbed/workloads/bin/simple --bytes 10485760 --port 18998 > /tmp/claude-0/simple.log & WPID=$!
sleep 0.5
grep '^PHASE ready port=18998' /tmp/claude-0/simple.log
exec 3<>/dev/tcp/127.0.0.1/18998 && printf 'PING\n' >&3 && head -1 <&3   # → PONG
grep '^PHASE served_first' /tmp/claude-0/simple.log
ps -o rss= -p $WPID   # → ≈ 10240 KiB + 소량 (선언 resident 정직성)
kill -TERM $WPID && sleep 0.2 && (kill -0 $WPID 2>/dev/null && echo "STILL ALIVE (FAIL)" || echo "clean exit OK")
```

Expected: PHASE 두 줄 매치, `PONG`, RSS ≈ 10–13MB, `clean exit OK`.

- [ ] **Step 5: Commit**

```bash
git add testbed/workloads && git commit -m "rewrite(3/9b): workloads build.sh(플러그인 발견) + simple(계약 v2, 소켓 획득)"
```

---

### Task 5: workloads/dirty/ (구 target_memory 이식)

**Files:**
- Create: `testbed/workloads/dirty/workload.c`, `testbed/workloads/dirty/workload.yaml`
- 이식 소스: `testbed_old/workloads/target_memory.c`

**Interfaces:**
- Consumes: Task 3 헬퍼.
- Produces: `bin/dirty`. 메트릭 `checksum` (PHASE ready에 동승). phases `[ready, served_first, steady]`.

- [ ] **Step 1: workload.c 이식**

이식: `testbed_old/workloads/target_memory.c`에서 **메모리 로직 함수들(할당·touch·dirty 갱신·checksum 계산)을 그대로 복사**하고, 다음만 교체:

1. positional 인자 파싱(main 앞부분) → `flags.h`: `--bytes`(구 size_bytes), `--dirty_bytes`(구 dynamic_bytes_per_iter), `--interval_ms`, `--port`. 구 `[dirty|grow]` mode 인자는 `dirty` 고정으로 제거 (grow는 과거 실험 정리 때 폐기된 모드).
2. 자체 소켓 코드(`service_open`/응답 루프) 삭제 → `probe_server.h` 사용.
3. `WORKLOAD_READY ...` 출력 → `printf("PHASE ready port=%d bytes=%ld checksum=%lu\n", ...); fflush(stdout);`
4. 메인 루프를 아래 형태로 (dirty 갱신과 서비스 인터리브, interval 후 steady 발행):

```c
	long passes = 0;
	for (;;) {
		probe_serve_pending(fd, interval_ms > 0 ? (int)interval_ms : 1000);
		touch_dirty_pages(buf, bytes, dirty_bytes);   /* old의 주기 dirty 함수 그대로 */
		if (++passes == 1) {                          /* 첫 dirty 갱신 완료 = steady */
			printf("PHASE steady\n");
			fflush(stdout);
		}
	}
```

(함수명이 old와 다르면 old의 실제 이름을 유지 — 로직 블록은 수정하지 않는다.)

- [ ] **Step 2: workload.yaml 작성**

```yaml
name: dirty
params:
  bytes:       {default: 52428800}
  dirty_bytes: {default: 1048576}
  interval_ms: {default: 200}
  port:        {default: 0}   # 수동 단발 전용 (스펙 §4-B port 규칙)
phases: [ready, served_first, steady]
metrics: [checksum]
resident:
  from_param: bytes
  bytes_per_unit: 1
  overhead_mib: 2
```

- [ ] **Step 3: 빌드 + 계약 테스트**

```bash
testbed/workloads/build.sh
testbed/workloads/bin/dirty --bytes 31457280 --port 18997 > /tmp/claude-0/dirty.log & WPID=$!
sleep 0.5
grep -E '^PHASE ready port=18997 bytes=31457280 checksum=[0-9]+' /tmp/claude-0/dirty.log
exec 3<>/dev/tcp/127.0.0.1/18997 && printf 'PING\n' >&3 && head -1 <&3
sleep 0.5; grep '^PHASE steady' /tmp/claude-0/dirty.log
ps -o rss= -p $WPID   # ≈ 30720 KiB + 소량
kill -TERM $WPID
```

Expected: 세 PHASE 라인 순서대로(ready → served_first → steady), `PONG`, RSS ≈ 30–33MB.

- [ ] **Step 4: Commit**

```bash
git add testbed/workloads/dirty && git commit -m "rewrite(3/9c): dirty 워크로드 — target_memory 로직 이식, 계약 v2 인터페이스"
```

---

### Task 6: workloads/initburst/ (구 target_compute 이식)

**Files:**
- Create: `testbed/workloads/initburst/workload.c`, `testbed/workloads/initburst/workload.yaml`
- 이식 소스: `testbed_old/workloads/target_compute.c`

**Interfaces:**
- Produces: `bin/initburst`. 메트릭 `compute_ms` (PHASE ready 동승 — collect에서 `wl_compute_ms`로 승격). phases `[init, ready, served_first]` — `init`은 pre-ready dump 실험용(§4-A6).

- [ ] **Step 1: workload.c 이식**

이식: `testbed_old/workloads/target_compute.c`에서 **compute burst 함수(버퍼 순회 연산)와 clock_gettime 계측을 그대로 복사**하고, 다음만 교체:

1. positional → flags: `--buf_bytes`(기본 1048576 — 1MiB CPU-bound, 스펙 배경: 16MiB는 memory-bandwidth-bound였음), `--iters`, `--interval_ms`, `--port`. 구 `[idle|recompute]` mode는 `idle` 고정으로 제거 (recompute 폐기).
2. burst 시작 **전에** `printf("PHASE init\n"); fflush(stdout);` 발행 (pre-ready dump 지점).
3. 자체 소켓 → `probe_server.h`. `WORKLOAD_READY` → `printf("PHASE ready port=%d compute_ms=%.1f\n", p, ms); fflush(stdout);`
4. 메인 루프: `for (;;) probe_serve_pending(fd, 1000);`

- [ ] **Step 2: workload.yaml 작성**

```yaml
name: initburst
params:
  buf_bytes:   {default: 1048576}
  iters:       {default: 100}
  interval_ms: {default: 200}
  port:        {default: 0}   # 수동 단발 전용
phases: [init, ready, served_first]
metrics: [compute_ms]
resident:
  mib: 4                      # 버퍼 1MiB + 코드/스택
calibration:
  param: iters
  metric: compute_ms
```

- [ ] **Step 3: 빌드 + 계약 테스트 (iters 비례성 포함)**

```bash
testbed/workloads/build.sh
for it in 100 200; do
  testbed/workloads/bin/initburst --iters $it --port 0 > /tmp/claude-0/ib_$it.log & WPID=$!
  sleep 3; kill -TERM $WPID 2>/dev/null
  grep -oE 'compute_ms=[0-9.]+' /tmp/claude-0/ib_$it.log
done
grep '^PHASE init' /tmp/claude-0/ib_100.log
```

Expected: `PHASE init`이 ready보다 먼저; compute_ms(200) ≈ 2× compute_ms(100) (±20% — idle 호스트 기준, A3 작업단위 정의 확인).

- [ ] **Step 4: Commit**

```bash
git add testbed/workloads/initburst && git commit -m "rewrite(3/9d): initburst 워크로드 — target_compute 이식, PHASE init(pre-ready dump 지점) 추가"
```

---

### Task 7: env/ 이식 (flattened-env 인터페이스)

**Files:**
- Create: `testbed/env/{setup.sh,verify.sh,teardown.sh}`, `testbed/env/hardware/{cgroup.sh,memory.sh,cpu.sh,cpufreq.sh,storage.sh}`, `testbed/env/policy/README.md`
- 이식 소스: `testbed_old/env/` 전체

**Interfaces:**
- Consumes: (없음 — 최하층)
- Produces: `setup.sh <run_dir>` / `verify.sh <run_dir>` / `teardown.sh <run_dir>` — **run_dir 하나만 받고**, 설정은 `<run_dir>/config.env`(flattened env, config_to_env 산출)에서 source (스펙 §5-6 positional 누적 금지). hardware 모듈들의 `apply|restore <run_id> ...` verb 인터페이스는 old 그대로 유지 (setup.sh 내부 호출이라 외부 계약 아님). `setup.sh`는 old처럼 `<run_dir>/storage.env`(CRIU 이미지 경로 등)를 산출.

- [ ] **Step 1: hardware 5종 이식 (무변경 복사)**

```bash
cp testbed_old/env/hardware/{cgroup.sh,memory.sh,cpu.sh,cpufreq.sh,storage.sh} testbed/env/hardware/
```

검증된 저수준 로직 — 수정하지 않는다 (§6-13/14/15가 여기 산다).

- [ ] **Step 2: setup.sh 이식 + 인터페이스 교체**

이식: `testbed_old/env/setup.sh` 전체 복사 후, 앞부분의 positional 파싱
(`RUN_ID=$1; MEMORY_MAX=$2; ...`)만 아래로 교체 (hardware 호출부·storage.env 생성은 무변경):

```bash
# 인터페이스: setup.sh <run_dir>   — 설정은 <run_dir>/config.env에서 (스펙 §5-6)
RUN_DIR="${1:?usage: setup.sh <run_dir>}"
# shellcheck source=/dev/null
source "$RUN_DIR/config.env"
RUN_ID="${CFG_RUN_ID:?config.env missing CFG_RUN_ID}"
MEMORY_MAX="${CFG_MEMORY_MAX:?}"
MEMORY_SWAP_MAX="${CFG_MEMORY_SWAP_MAX:-0}"
CPU_BANDWIDTH_CORES="${CFG_CPU_BANDWIDTH_CORES:-}"
CPUSET_CPUS="${CFG_CPUSET_CPUS:-}"
CPU_FREQ_KHZ="${CFG_CPU_FREQ_KHZ:-}"
STORAGE_IMAGE_ENABLED="${CFG_STORAGE_IMAGE_ENABLED:-false}"
# (storage 나머지 키들도 같은 CFG_* → 구 변수명 매핑으로 나열 — old setup.sh가 쓰는
#  변수 목록은 old 파일 상단 참조. 새 키 추가 없음, 이름만 CFG_ 접두 매핑.)
```

`verify.sh`/`teardown.sh`도 동일 패턴 (run_dir 하나 + config.env source). 나머지 본문 무변경.

- [ ] **Step 3: policy seam**

```markdown
# env/policy — 미래 자리 (이번 재작성 범위 밖)

swap backend(none/zram/emmc_sim)·memory.swap.max·vm.swappiness 등 OS 정책 노브.
PLAN_FULL §4.2 Tier 1–3 참조. 미구현 근거·증분 추가 계획: 스펙 §11.
setup.sh의 주석 훅( policy/*.sh apply )이 진입점이 된다.
verb 규약: <module>.sh apply|restore <run_id> … (hardware와 동형)
```

- [ ] **Step 4: 정적 검사 + 왕복 테스트**

```bash
bash -n testbed/env/*.sh testbed/env/hardware/*.sh
shellcheck testbed/env/*.sh testbed/env/hardware/*.sh
# 왕복: 수동 config.env로 setup→verify→teardown
R=/tmp/claude-0/envtest; sudo rm -rf $R; mkdir -p $R
cat > $R/config.env <<'EOF'
CFG_RUN_ID='envtest'
CFG_MEMORY_MAX='268435456'
CFG_MEMORY_SWAP_MAX='0'
CFG_CPUSET_CPUS='0'
CFG_STORAGE_IMAGE_ENABLED='false'
EOF
sudo testbed/env/setup.sh $R && sudo testbed/env/verify.sh $R && sudo testbed/env/teardown.sh $R
```

Expected: setup이 cgroup 생성+memory.max=256M 로그, verify L1 PASS, teardown 후 `/sys/fs/cgroup/*envtest*` 없음.

- [ ] **Step 5: Commit**

```bash
git add testbed/env && git commit -m "rewrite(4/9): env 이식 — hardware 무변경, setup/verify/teardown은 flattened-env 인터페이스로"
```

---

### Task 8: stress/ 이식

**Files:**
- Create: `testbed/stress/{start.sh,verify.sh,stop.sh}`
- 이식 소스: `testbed_old/stress/`

**Interfaces:**
- Produces: old와 동일 CLI (`start.sh`/`verify.sh`/`stop.sh` — run_id·cgroup·워커 파라미터는 old 시그니처 유지; 러너측 래퍼 lib/stress.sh(Task 11)가 감싼다).

- [ ] **Step 1: 무변경 이식**

```bash
cp testbed_old/stress/{start.sh,verify.sh,stop.sh} testbed/stress/
```

start.sh의 **oom-protect loop-until-stable(deadline 8s)은 그대로** — §6-13. 고정 횟수 sweep으로 "단순화"하지 말 것 (late-spawn race로 ~50% 실패율 재발).

- [ ] **Step 2: 정적 검사 + 단독 왕복**

```bash
bash -n testbed/stress/*.sh && shellcheck testbed/stress/*.sh
# 단독 왕복 (old CLI 그대로 — 인자 순서는 testbed_old/stress/start.sh usage 참조):
sudo mkdir -p /sys/fs/cgroup/stresstest
sudo testbed/stress/start.sh   # old usage에 맞는 최소 인자로 (vm 2워커×32M 등)
sudo testbed/stress/verify.sh  # 워커 수/점유 OK
sudo testbed/stress/stop.sh
sudo rmdir /sys/fs/cgroup/stresstest
```

Expected: start가 `oom-protect: stable (N procs)` 로그, verify PASS, stop 후 stress-ng 프로세스 0개 (`pgrep stress-ng` 빈 출력).

- [ ] **Step 3: Commit**

```bash
git add testbed/stress && git commit -m "rewrite(5/9): stress 이식 — oom-protect loop-until-stable 보존"
```

---

### Task 9: runner/config_to_env.py (manifest 병합 + 검증)

**Files:**
- Create: `testbed/runner/config_to_env.py` (이식+확장: `testbed_old/runner/config_to_env.py`)

**Interfaces:**
- Consumes: 조건 YAML (base scenario 병합본), `workloads/<name>/workload.yaml`.
- Produces (stdout, shell-quoted 한 줄 1키 — bash가 source):
  - `CFG_*`: 환경/정책 키 전부 (old 키명에 `CFG_` 접두: `CFG_MEMORY_MAX`, `CFG_MEMORY_SWAP_MAX`, `CFG_CPU_BANDWIDTH_CORES`, `CFG_CPUSET_CPUS`, `CFG_CPU_FREQ_KHZ`, `CFG_STORAGE_*`, `CFG_STRESS_ENABLED`, `CFG_STRESS_VM_WORKERS`, `CFG_STRESS_VM_BYTES`, `CFG_STRESS_CPU_SATURATE`, `CFG_CACHE_POLICY`)
  - 신규 runner 노브: `CFG_KDAT_CACHE`(기본 off), `CFG_DUMP_AT`(기본 served_first), `CFG_WARMUP_PINGS`(기본 1), `CFG_CHECKPOINT_AFTER_S`(old 기본값 유지)
  - `WL_NAME`, `WL_BIN`(절대경로 `workloads/bin/<name>`), `WL_FLAGS`(렌더링된 `--k v ...` 문자열, 키 정렬 순), `WL_PORT`(port 파라미터 값), `WL_RESIDENT_BYTES`(manifest resident 평가값), `WL_PHASES`(공백 구분), `WL_METRICS`(공백 구분)
- 검증 (실패 시 stderr + exit 1 — **설계 시점 에러**): ① manifest `name`==디렉터리명 ② config params ⊆ manifest params ③ `dump_at` ∈ phases ④ resident 필드 정합 (`from_param`+`bytes_per_unit` 또는 `mib`).

- [ ] **Step 1: 이식 + 확장 작성**

이식: old 파일의 YAML 로더(표준 라이브러리 파서)와 shell-quote 함수를 그대로 두고, (a) 키 출력에 `CFG_` 접두, (b) 아래 함수를 추가:

```python
def load_manifest(testbed_dir, wl_name):
    path = os.path.join(testbed_dir, "workloads", wl_name, "workload.yaml")
    m = load_yaml(path)  # old의 로더 재사용
    if m.get("name") != wl_name:
        die(f"manifest name '{m.get('name')}' != dir '{wl_name}'")
    return m

def resident_bytes(m, params):
    r = m["resident"]
    if "mib" in r:
        base = int(r["mib"]) * 1048576
    else:
        base = int(params[r["from_param"]]) * int(r.get("bytes_per_unit", 1))
    return base + int(r.get("overhead_mib", 0)) * 1048576

def render_flags(m, params):
    # manifest 선언 순 아닌 키 정렬 순 — 렌더링 결정성
    merged = {k: v.get("default") for k, v in m["params"].items()}
    for k, v in params.items():
        if k not in merged:
            die(f"param '{k}' not in manifest params")
        merged[k] = v
    return " ".join(f"--{k} {merged[k]}" for k in sorted(merged)), merged
```

메인 흐름: config의 `workload: {name, params}` 블록 → `load_manifest` → 검증(위 ①~④, `dump_at`은 config의 `dump_at` 값이 `m["phases"]`에 있는지) → `WL_*` 키 출력. 나머지 config 키는 old 변환 로직 그대로 + `CFG_` 접두.

- [ ] **Step 2: 단위 테스트 (수동 YAML)**

```bash
cat > /tmp/claude-0/t.yaml <<'EOF'
memory: {max: 268435456, swap_max: 0}
workload: {name: dirty, params: {bytes: 31457280, port: 18101}}
dump_at: served_first
EOF
testbed/runner/config_to_env.py /tmp/claude-0/t.yaml | grep -E '^(WL_NAME|WL_FLAGS|WL_RESIDENT_BYTES|CFG_DUMP_AT|CFG_MEMORY_MAX)='
# 검증 에러 경로:
sed 's/served_first/nonexistent_phase/' /tmp/claude-0/t.yaml > /tmp/claude-0/bad.yaml
testbed/runner/config_to_env.py /tmp/claude-0/bad.yaml; echo "exit=$?"
```

Expected: `WL_FLAGS='--bytes 31457280 --dirty_bytes 1048576 --interval_ms 200 --port 18101'`, `WL_RESIDENT_BYTES='33554432'`(30MiB+2MiB), `CFG_DUMP_AT='served_first'`; bad.yaml은 stderr에 dump_at 에러 + `exit=1`.

- [ ] **Step 3: Commit**

```bash
git add testbed/runner/config_to_env.py && git commit -m "rewrite(6/9a): config_to_env — manifest 병합·검증·WL_/CFG_ 네임스페이스"
```

---

### Task 10: runner/lib 1차 (config, cgroup, snapshot, cleanup) + cprobe·mem_snapshot·fadvise 이식

**Files:**
- Create: `testbed/runner/lib/{config.sh,cgroup.sh,snapshot.sh,cleanup.sh}`
- Copy: `testbed_old/runner/cprobe.c` → `testbed/runner/cprobe.c` (무변경), `testbed_old/runner/mem_snapshot.sh` → `testbed/runner/mem_snapshot.sh` (무변경), `testbed_old/runner/fadvise_dontneed.py` → 동일 (무변경)

**Interfaces:**
- Produces:
  - `config_load <run_id> <config_yaml>` — sets `RUN_ID RUN_DIR CG_PATH MEM_TIMELINE` + `CFG_* WL_*` 전부 (config.env를 RUN_DIR에 생성·source). `TESTBED_DIR`은 각 러너가 자기 위치에서 설정.
  - `cgroup_join_self` — uses `CG_PATH` (§6-4).
  - `snap_take <tag>` — uses `RUN_DIR CG_PATH MEM_TIMELINE`.
  - `cleanup_register <fn>` / `cleanup_install_trap` — 역순 실행 EXIT trap.

- [ ] **Step 1: lib/config.sh 작성**

```bash
# runner/lib/config.sh — 설정 로딩 (두 러너 공용)
# uses: TESTBED_DIR (러너가 설정), RUNS_ROOT(기본 $TESTBED_DIR/runs)
# sets: RUN_ID RUN_DIR CG_PATH MEM_TIMELINE + CFG_* WL_* (config.env 경유)
config_load() {
	RUN_ID="$1"
	local yaml="$2"
	RUN_DIR="${RUNS_ROOT:-$TESTBED_DIR/runs}/$RUN_ID"
	mkdir -p "$RUN_DIR"
	"$TESTBED_DIR/runner/config_to_env.py" "$yaml" > "$RUN_DIR/config.env"
	printf "CFG_RUN_ID='%s'\n" "$RUN_ID" >> "$RUN_DIR/config.env"
	# shellcheck source=/dev/null
	source "$RUN_DIR/config.env"
	# cgroup 경로 규약: testbed_old/env/hardware/cgroup.sh와 동일 (이식 시 old의
	# 경로 조립식을 그대로 가져와 아래 한 줄을 완성한다)
	CG_PATH="/sys/fs/cgroup/criu_test_${RUN_ID}"
	MEM_TIMELINE="$RUN_DIR/mem_timeline.env"
}
```

- [ ] **Step 2: lib/cgroup.sh, lib/snapshot.sh, lib/cleanup.sh 작성**

```bash
# runner/lib/cgroup.sh — uses: CG_PATH
# 러너 자신을 대상 cgroup에 넣는다 — probe가 memcg 압박을 동일하게 받아야 공정 (§6-4)
cgroup_join_self() {
	echo $$ > "$CG_PATH/cgroup.procs"
}
```

```bash
# runner/lib/snapshot.sh — uses: TESTBED_DIR RUN_DIR CG_PATH MEM_TIMELINE
snap_take() {
	"$TESTBED_DIR/runner/mem_snapshot.sh" "$CG_PATH" "$1" "$MEM_TIMELINE" || true
}
```

(mem_snapshot.sh의 실제 인자 순서가 old와 다르면 old 호출부(`testbed_old/runner/run_once.sh`의 `$SNAP` 사용처)를 기준으로 맞춘다.)

```bash
# runner/lib/cleanup.sh — 등록 역순 실행 EXIT trap (두 러너 공용)
CLEANUP_FNS=()
cleanup_register() { CLEANUP_FNS+=("$1"); }
cleanup_run_all() {
	local i
	for ((i = ${#CLEANUP_FNS[@]} - 1; i >= 0; i--)); do
		"${CLEANUP_FNS[$i]}" || true
	done
}
cleanup_install_trap() { trap cleanup_run_all EXIT; }
```

- [ ] **Step 3: cprobe 빌드 + 정적 검사**

```bash
cp testbed_old/runner/cprobe.c testbed/runner/cprobe.c
cp testbed_old/runner/mem_snapshot.sh testbed/runner/mem_snapshot.sh
cp testbed_old/runner/fadvise_dontneed.py testbed/runner/fadvise_dontneed.py
gcc -O2 -static -o testbed/runner/cprobe testbed/runner/cprobe.c   # §6-5 static
bash -n testbed/runner/lib/*.sh && shellcheck testbed/runner/lib/*.sh
# cprobe 동작: Task 4의 simple을 띄워 → testbed/runner/cprobe 127.0.0.1 <port> → PONG/exit 0
```

Expected: 컴파일 경고 0, shellcheck 통과, cprobe exit 0.

- [ ] **Step 4: Commit**

```bash
git add testbed/runner && git commit -m "rewrite(6/9b): runner/lib 1차(config/cgroup/snapshot/cleanup) + cprobe·mem_snapshot·fadvise 이식"
```

---

### Task 11: runner/lib 2차 (workload, probe, stress, result)

**Files:**
- Create: `testbed/runner/lib/{workload.sh,probe.sh,stress.sh,result.sh}`
- 이식 소스: `testbed_old/runner/run_once.sh`의 `maybe_stress_warmup`·`write_result_env`·target 기동 블록

**Interfaces:**
- Produces:
  - `wl_launch` — uses `WL_BIN WL_FLAGS RUN_DIR CG_PATH`; sets `WL_PID WL_LOG`. cgroup 안 기동(subshell join→exec).
  - `wl_wait_phase <phase> <timeout_s>` — sets `WL_PHASE_LINE`; 프로세스 사망/타임아웃 시 return 1. **측정 창 밖 전용** (내부 grep 스폰).
  - `wl_kv <key>` — `WL_PHASE_LINE`에서 `key=value` 추출(echo).
  - `probe_first_response <pid> <port> <timeout_s>` — sets `PROBE_RESP_TS PROBE_OK`. **측정 창 그 자체** (§6-1~3).
  - `stress_start_verified` / `stress_warmup` / `stress_stop` — uses `CFG_STRESS_*`, CG_PATH.
  - `result_set <k> <v>` / `result_write <PASS|FAIL> [fail_reason]` — result.env 산출 (old 스키마 + 신규 키).

- [ ] **Step 1: lib/workload.sh 작성**

```bash
# runner/lib/workload.sh — 워크로드-무지 기동·PHASE 관측 (YAML은 안 읽음 — env만)
# uses: WL_BIN WL_FLAGS RUN_DIR CG_PATH / sets: WL_PID WL_LOG WL_PHASE_LINE

wl_launch() {
	WL_LOG="$RUN_DIR/workload.log"
	: > "$WL_LOG"
	# cgroup join 후 exec — 첫 할당부터 memcg 계정 (old target 기동 방식 계승)
	# shellcheck disable=SC2086
	( echo "$BASHPID" > "$CG_PATH/cgroup.procs" && exec "$WL_BIN" $WL_FLAGS ) \
		> "$WL_LOG" 2>&1 &
	WL_PID=$!
}

# 측정 창 밖 전용 (grep 스폰 있음). dump_at 대기·ready 대기용.
wl_wait_phase() {
	local phase="$1" timeout_s="$2"
	local deadline=$((SECONDS + timeout_s))
	WL_PHASE_LINE=""
	while ((SECONDS < deadline)); do
		kill -0 "$WL_PID" 2>/dev/null || return 1
		WL_PHASE_LINE="$(grep -m1 -E "^PHASE ${phase}([[:space:]]|\$)" "$WL_LOG" 2>/dev/null || true)"
		[[ -n "$WL_PHASE_LINE" ]] && return 0
		sleep 0.005
	done
	return 1
}

wl_kv() {
	[[ "$WL_PHASE_LINE" =~ [[:space:]]$1=([^[:space:]]+) ]] && echo "${BASH_REMATCH[1]}"
}
```

- [ ] **Step 2: lib/probe.sh 작성 — 측정 공정성의 single source**

```bash
# runner/lib/probe.sh — first-response 측정 창. 이 함수가 cold·restore 유일한 측정 경로 (§6-1).
# 창 내용: kill -0(빌트인) → cprobe(유일한 스폰) → $EPOCHREALTIME(빌트인).
# sed/awk/date/seq/grep 등 다른 스폰 추가 절대 금지. 수정 시 스펙 §6-1~6 재검토 필수.
# uses: PROBE_CPROBE (기본: runner/cprobe) / sets: PROBE_RESP_TS PROBE_OK
probe_first_response() {
	local pid="$1" port="$2" timeout_s="$3"
	local polls=$((timeout_s * 200))   # 5ms 폴링 (§6-3) — 창 밖 사전계산
	PROBE_RESP_TS=""
	PROBE_OK=""
	local _pi
	for ((_pi = 0; _pi < polls; _pi++)); do
		kill -0 "$pid" 2>/dev/null || break
		if "$PROBE_CPROBE" 127.0.0.1 "$port" >/dev/null 2>&1; then
			PROBE_RESP_TS="$EPOCHREALTIME"
			PROBE_OK=1
			break
		fi
		sleep 0.005
	done
}
```

probe.sh 상단에 `PROBE_CPROBE="${PROBE_CPROBE:-$TESTBED_DIR/runner/cprobe}"` 초기화 라인 포함.

- [ ] **Step 3: lib/stress.sh 작성 (old 래핑 이식)**

이식: old `run_once.sh`의 stress 시작 블록(§3 섹션, `stress/start.sh` 호출 인자 조립)과 `maybe_stress_warmup` 함수를 각각 `stress_start_verified`/`stress_warmup`으로 감싼다. `CFG_STRESS_ENABLED=false`면 둘 다 no-op. `stress_start_verified`는 start 후 `stress/verify.sh` 실패 시 return 1. `cleanup_register stress_stop`은 호출자(러너) 책임.

- [ ] **Step 4: lib/result.sh 작성 (write_result_env 통합 이식)**

이식: old `run_once.sh`의 `write_result_env`(82줄)와 `run_cold_start.sh`의 것(63줄)을 **합집합 스키마**로 통합. 구현:

```bash
# runner/lib/result.sh — result.env 산출 (old 공통 스키마 유지 §6-17)
declare -A RESULT_KV
result_set() { RESULT_KV["$1"]="$2"; }
result_write() { # <PASS|FAIL> [fail_reason]
	local f="$RUN_DIR/result.env"
	{
		# old write_result_env의 키 순서·조립식을 이식 (run_id/exp_id/... 공통 키 먼저).
		# 신규 키: dump_phase, warmup_pings, criu_version, criu_patch_sha,
		#          resident_mismatch, wl_* (WL_METRICS에 선언된 것만)
		...
		cat "$MEM_TIMELINE" 2>/dev/null || true
	} > "$f"
}
```

키 조립 로직은 old 두 파일의 해당 함수를 나란히 열고 합치되, **키 이름은 old 그대로** (분석 호환). `RESULT_KV`에 안 담긴 키는 `na`. `wl_` 메트릭: `WL_METRICS`의 각 이름 `m`에 대해 `result_set "wl_$m" "$(wl_kv "$m")"`은 호출자(러너)가 수행.

- [ ] **Step 5: 통합 리허설 테스트 (cgroup 없이 기능만)**

```bash
bash -n testbed/runner/lib/*.sh && shellcheck testbed/runner/lib/*.sh
sudo bash -c '
set -euo pipefail
TESTBED_DIR=/root/Embed-sim-lab/testbed
for m in config cgroup snapshot cleanup workload probe stress result; do source $TESTBED_DIR/runner/lib/$m.sh; done
mkdir -p /sys/fs/cgroup/libtest /tmp/claude-0/librun
CG_PATH=/sys/fs/cgroup/libtest RUN_DIR=/tmp/claude-0/librun
WL_BIN=$TESTBED_DIR/workloads/bin/simple WL_FLAGS="--bytes 8388608 --port 18996"
wl_launch
wl_wait_phase ready 5 && echo "ready OK, port=$(wl_kv port)"
T0="$EPOCHREALTIME"
probe_first_response "$WL_PID" 18996 5
[[ -n "$PROBE_OK" ]] && awk "BEGIN{printf \"probe OK, latency=%.4fs\n\", $PROBE_RESP_TS-$T0}"
kill -TERM "$WL_PID"; rmdir /sys/fs/cgroup/libtest 2>/dev/null || true
'
```

Expected: `ready OK, port=18996` → `probe OK, latency=0.0xxx` (수십 ms 이내).

- [ ] **Step 6: Commit**

```bash
git add testbed/runner/lib && git commit -m "rewrite(6/9c): runner/lib 2차 — workload/probe(측정창 single source)/stress/result"
```

---

### Task 12: run_cold_start.sh (cold 오케스트레이터)

**Files:**
- Create: `testbed/runner/run_cold_start.sh` (목표 150–200줄)
- 이식 소스: `testbed_old/runner/run_cold_start.sh`

**Interfaces:**
- Consumes: lib 8종 (Task 10–11), env/·stress/ (Task 7–8), workloads/bin (Task 4–6).
- Produces: CLI `run_cold_start.sh --run-id <id> --config <yaml>`; `RUN_DIR/result.env` (old cold 스키마 키 + 신규 키).

- [ ] **Step 1: 골격 작성 — main = 모듈 호출 나열**

```bash
#!/usr/bin/env bash
# runner/run_cold_start.sh — cold-start 경로 오케스트레이터 (재작성판)
# 측정 정의: cold_response = exec 직전 → PONG (lib/probe.sh 측정 창, 스펙 §6-1~5)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"
for m in config cgroup snapshot cleanup workload probe stress result; do
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/lib/$m.sh"
done

# ---- cold 고유 in-file steps (이식 지시는 아래 Step 2) ----
step_prepare_binary() { ...; }   # 제약 스토리지에 바이너리 복사, WL_BIN 갱신
step_drop_caches() { ...; }      # sync + drop_caches=3 (exec 직전)

main() {
	local run_id="" cfg=""
	while (($#)); do case "$1" in
		--run-id) run_id="$2"; shift 2 ;;
		--config) cfg="$2"; shift 2 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac; done
	config_load "$run_id" "$cfg"
	result_set runner cold
	cleanup_install_trap
	"$TESTBED_DIR/env/setup.sh" "$RUN_DIR";   cleanup_register env_teardown
	"$TESTBED_DIR/env/verify.sh" "$RUN_DIR"
	cgroup_join_self
	stress_start_verified && cleanup_register stress_stop
	stress_warmup; snap_take after_stress_warmup
	step_prepare_binary
	step_drop_caches
	# ---- 측정 창: 이 4줄 사이에 어떤 코드도 추가 금지 (§6-1~2) ----
	local start_ts="$EPOCHREALTIME"
	wl_launch
	probe_first_response "$WL_PID" "$WL_PORT" "${READY_TIMEOUT_S:-60}"
	# ---- 창 밖: bookkeeping ----
	snap_take after_response
	wl_wait_phase ready 5 || true          # 이미 발행돼 있음 — 메트릭 파싱용
	local m; for m in $WL_METRICS; do result_set "wl_$m" "$(wl_kv "$m" || echo na)"; done
	step_resident_check                    # 선언 정직성 (§4-B): VmRSS vs WL_RESIDENT_BYTES
	if [[ -n "$PROBE_OK" ]]; then
		result_set cold_response_s "$(awk "BEGIN{print $PROBE_RESP_TS - $start_ts}")"
		result_write PASS
	else
		result_write FAIL "no response within timeout"
	fi
}
env_teardown() { "$TESTBED_DIR/env/teardown.sh" "$RUN_DIR"; }
main "$@"
```

- [ ] **Step 2: in-file step 이식**

- `step_prepare_binary`: 이식 `testbed_old/runner/run_cold_start.sh` `prepare_target_binary_on_constrained_storage` — WL_BIN을 제약 스토리지 사본 경로로 재설정 (§6-15).
- `step_drop_caches`: 이식 old의 "3b. drop caches" 섹션 (`CFG_CACHE_POLICY` 분기 포함).
- `cold_ready_s`·`cold_launch_s` 산출: 이식 old의 "측정 창 밖: cold_ready 계산" 블록 → `result_set`으로.
- `step_resident_check` (신규, cold·restore 공용이 아니므로 각 러너 in-file — 동일 5줄):

```bash
step_resident_check() {   # 선언 정직성 (§4-B): 편차 >10%면 경고 플래그
	local rss_kb; rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/$WL_PID/status" 2>/dev/null || echo 0)"
	local mism; mism="$(awk "BEGIN{d=($rss_kb*1024-$WL_RESIDENT_BYTES)/$WL_RESIDENT_BYTES; print (d>0.1||d<-0.1)?1:0}")"
	result_set resident_rss_bytes "$((rss_kb * 1024))"
	result_set resident_mismatch "$mism"
}
```

- [ ] **Step 3: 단발 실행 테스트**

```bash
bash -n testbed/runner/run_cold_start.sh && shellcheck testbed/runner/run_cold_start.sh
cat > /tmp/claude-0/cold1.yaml <<'EOF'
memory: {max: 268435456, swap_max: 0}
workload: {name: dirty, params: {bytes: 31457280, port: 18102}}
stress: {enabled: false}
EOF
sudo testbed/runner/run_cold_start.sh --run-id coldtest01 --config /tmp/claude-0/cold1.yaml
grep -E '^(result|cold_response_s|wl_checksum)=' testbed/runs/coldtest01/result.env
```

Expected: `result=PASS`, `cold_response_s=0.x`, `wl_checksum=<수>`. teardown 후 cgroup 잔존 없음.

- [ ] **Step 4: Commit**

```bash
git add testbed/runner/run_cold_start.sh && git commit -m "rewrite(6/9d): run_cold_start — thin 오케스트레이터 (측정 창 4줄 고정)"
```

---

### Task 13: run_once.sh (restore 오케스트레이터)

**Files:**
- Create: `testbed/runner/run_once.sh` (목표 250–350줄)
- 이식 소스: `testbed_old/runner/run_once.sh`

**Interfaces:**
- Consumes: lib 8종, `CRIU_BIN`, `CFG_DUMP_AT`/`CFG_WARMUP_PINGS`/`CFG_CHECKPOINT_AFTER_S`/`CFG_KDAT_CACHE`.
- Produces: CLI `run_once.sh --run-id <id> --config <yaml> [--kdat-cache on|off]`; result.env (old restore 스키마 + `dump_phase`/`warmup_pings`/`criu_version`/`criu_patch_sha`).

- [ ] **Step 1: 골격 작성**

main 순서 (cold와 같은 lib 시퀀스 후 restore 고유 단계):

```bash
main() {
	# ... 인자 파싱(--kdat-cache가 CFG_KDAT_CACHE를 override), config_load, 검사:
	CRIU_BIN="${CRIU_BIN:-$TESTBED_DIR/criu/bin/criu}"
	[[ -x "$CRIU_BIN" ]] || { echo "ERROR: $CRIU_BIN 없음 — testbed/criu/build.sh 먼저 실행 (§6-18)" >&2; exit 1; }
	result_set runner restore
	result_set dump_phase "$CFG_DUMP_AT"
	result_set warmup_pings "$CFG_WARMUP_PINGS"
	result_set criu_version "$("$CRIU_BIN" --version | head -1)"
	result_set criu_patch_sha "$(sha256sum "$TESTBED_DIR/criu/kdat-shm.patch" | cut -c1-12)"
	cleanup_install_trap
	# env setup/verify → cgroup_join_self → stress_start_verified/warmup → snap  (cold와 동일)
	step_place_binary            # 제약 스토리지 (old run_once target 준비 블록 이식)
	wl_launch
	wl_wait_phase ready "${READY_TIMEOUT_S:-60}" || { result_write FAIL "target not ready"; exit 1; }
	step_warmup_pings            # CFG_WARMUP_PINGS × cprobe (측정 제외, §4-A6 warm 의미론)
	wl_wait_phase "$CFG_DUMP_AT" "${DUMP_AT_TIMEOUT_S:-60}" || { result_write FAIL "dump_at phase not reached"; exit 1; }
	step_quiesce_and_dump        # checkpoint_after_s 대기 → established 없음 확인 → criu dump -v4 (시간 기록)
	step_cache_policy            # sync + drop_caches=3 / fadvise (CFG_CACHE_POLICY)
	step_kdat_control            # off: rm -f /dev/shm/criu.kdat; on: 보존
	step_restore_and_probe       # ★측정 창 포함 (아래)
	step_decompose_restore_log   # -v4 awk 분해 (창 밖, §6-9)
	step_verify_recovery         # L2 membership (이식) — PONG은 probe가 이미 증명
	result_write PASS
}
```

`step_restore_and_probe` — 측정 창 부분은 아래 형태 고정:

```bash
step_restore_and_probe() {
	local pidfile="$RUN_DIR/restored.pid"
	# ---- 측정 창: 아래 블록에 코드 추가 금지 (§6-1~2) ----
	RESTORE_START_TS="$EPOCHREALTIME"
	"$CRIU_BIN" restore -d --pidfile "$pidfile" ... -v4 -o "$RUN_DIR/restore.log"   # 인자 old 이식
	RESTORE_END_TS="$EPOCHREALTIME"
	RESTORED_PID="$(< "$pidfile")"
	probe_first_response "$RESTORED_PID" "$WL_PORT" "${RESTORE_TIMEOUT_S:-120}"
	# ---- 창 밖 ----
	snap_take after_restore
	result_set restore_cmd_s "$(awk "BEGIN{print $RESTORE_END_TS - $RESTORE_START_TS}")"
	[[ -n "$PROBE_OK" ]] \
		&& result_set restore_response_s "$(awk "BEGIN{print $PROBE_RESP_TS - $RESTORE_START_TS}")" \
		|| { result_write FAIL "no response after restore"; exit 1; }
}
```

(`restore_response`의 기준점 = RESTORE_START — old 정의와 동일. old 파일의 restore 섹션에서 기준점 정의를 재확인하고 다르면 old를 따른다.)

- [ ] **Step 2: in-file step 이식**

| step | 이식 소스 (`testbed_old/runner/run_once.sh`) |
|---|---|
| step_place_binary | §4 target 섹션의 스토리지 배치 부분 |
| step_warmup_pings | warm-up 블록 (line ~624–646) — request_probe.py 호출을 `"$PROBE_CPROBE" 127.0.0.1 "$WL_PORT"`로, 횟수를 `CFG_WARMUP_PINGS` 루프로 |
| step_quiesce_and_dump | §5 dump 섹션 (checkpoint_after_s, criu dump 인자, dump 시간 기록) — `criu` → `"$CRIU_BIN"` |
| step_cache_policy | dump 후 cache_policy 블록 + `fadvise_restore_image_files` |
| step_kdat_control | old의 kdat 분기 (`CRIU_KDAT_CACHE`→`CFG_KDAT_CACHE`) |
| step_decompose_restore_log | restore `-v4` awk 분해 블록 (kdat_probing_s/restore_work_s/launch_overhead_s) |
| step_verify_recovery | §7 generic recovery 중 membership 검증만 (liveness/기능은 PONG이 대체 — 스펙 §3 '버릴 것') |
| step_resident_check | Task 12 Step 2의 동일 5줄 (restore 쪽은 `WL_PID` 대신 `RESTORED_PID` 사용) — bookkeeping 구간에서 호출 |

- [ ] **Step 3: 단발 restore 테스트 (koff + kon)**

```bash
bash -n testbed/runner/run_once.sh && shellcheck testbed/runner/run_once.sh
cat > /tmp/claude-0/rst1.yaml <<'EOF'
memory: {max: 268435456, swap_max: 0}
workload: {name: dirty, params: {bytes: 31457280, port: 18103}}
stress: {enabled: false}
dump_at: served_first
warmup_pings: 1
EOF
sudo testbed/runner/run_once.sh --run-id rsttest01 --config /tmp/claude-0/rst1.yaml --kdat-cache off
grep -E '^(result|restore_response_s|kdat_probing_s|dump_phase)=' testbed/runs/rsttest01/result.env
sudo testbed/runner/run_once.sh --run-id rsttest02 --config /tmp/claude-0/rst1.yaml --kdat-cache on
sudo testbed/runner/run_once.sh --run-id rsttest03 --config /tmp/claude-0/rst1.yaml --kdat-cache on
grep '^kdat_probing_s=' testbed/runs/rsttest0{1,3}/result.env
```

Expected: 세 런 모두 `result=PASS`, `dump_phase=served_first`; rsttest03(kon, 캐시 워밍 후)의 `kdat_probing_s` ≪ rsttest01(koff) — 대략 수 ms vs 수십~백 ms.

- [ ] **Step 4: Commit**

```bash
git add testbed/runner/run_once.sh && git commit -m "rewrite(6/9e): run_once — dump_at/warmup_pings/kdat, 측정 창 고정 블록"
```

---

### Task 14: expand_campaign.py (campaign YAML → 실행 계획) + base scenario.yaml

**Files:**
- Create: `testbed/runner/expand_campaign.py`, `testbed/scenario.yaml`

- [ ] **Step 0: testbed/scenario.yaml (base) 작성**

이식: `testbed_old/scenario.yaml`을 복사하되 workload 블록을 새 스키마로 교체:

```yaml
workload: {name: simple, params: {bytes: 52428800, port: 0}}
dump_at: served_first
warmup_pings: 1
```

(memory/cpu/storage/stress/cache_policy 등 나머지 키·기본값은 old 그대로 — config_to_env가
`CFG_` 접두로 읽는 그 키들이다. 구 workload 키 `target_bytes`/`dynamic_*`/`compute_iters`는 삭제.)

**Interfaces:**
- Consumes: `configs/campaign_*.yaml` (스펙 §4-C/C-2), `scenario.yaml`(base), workload manifest들.
- Produces: `<campaign_dir>/plan.tsv` (탭 구분: `run_id  kind(cold|restore)  config_yaml  kdat(on|off|-)`) + `<campaign_dir>/configs/<run_id>.yaml` (조건별 완전 YAML) + `<campaign_dir>/expansion.json` (정규화된 값·포트 배정 기록 — 재현성).
- CLI: `expand_campaign.py <campaign.yaml> <out_dir> [--resolve wl.param=v1,v2,...] [--est-run-s 75] [--yes]`

- [ ] **Step 1: 작성 — 핵심 함수**

```python
#!/usr/bin/env python3
"""campaign YAML → 실행 계획 전개 (스펙 §4-C, §4-C-2).
값 표현식 정규화 / 자유 축 / cold 중복 제거 / 포트 명시 배정 / 조합 폭발 가드."""
import json, os, sys

PORT_BASE = 18100

def norm_values(v):
    """[..] | {from,to,step} | {from,to,factor} → 명시 리스트 (§4-C-2)"""
    if isinstance(v, list):
        return v
    if "step" in v:
        out, x = [], v["from"]
        while x <= v["to"]:
            out.append(x); x += v["step"]
        return out
    if "factor" in v:
        out, x = [], v["from"]
        while x <= v["to"]:
            out.append(x); x *= v["factor"]
        return out
    sys.exit(f"bad values expr: {v}")

def expand(campaign, resolves):
    axes = campaign.get("axes", {})
    kdat_vals = axes.pop("kdat", ["off"])          # 내장: restore 전용
    cpu_vals = axes.pop("cpu", ["idle"])           # 내장: stress.cpu_saturate 매핑
    free_axes = [(k, a["key"], norm_values(a["values"])) for k, a in axes.items()]
    runs, port_idx = [], 0
    for wl in campaign["workloads"]:
        vals = sweep_values(wl, resolves)          # calibrate_from_ms는 --resolve 필수
        for v in vals:
            for cpu in cpu_vals:
                for combo in cross(free_axes):     # itertools.product 래핑
                    cell = make_cell(campaign, wl, v, cpu, combo)  # base 병합 + 오버라이드
                    for rep in range(1, campaign["reps"] + 1):
                        port = PORT_BASE + port_idx; port_idx += 1   # §6-20 명시 배정
                        rid = run_name(wl, v, cpu, combo, rep)
                        runs.append(cold_run(rid, cell, port, rep))  # 셀당 1회/rep — kdat·dump_at 무관 (§4-C)
                        for da in wl.get("dump_at", ["served_first"]):
                            for kd in kdat_vals:
                                port = PORT_BASE + port_idx; port_idx += 1
                                runs.append(restore_run(rid, cell, port, rep, da, kd))
    return runs
```

보조 함수: `run_name`은 **값이 변하는 축만** 토큰으로 (`dirty_50M_cpubusy_koff_rep03` — dump_at이 1개뿐이면 이름에서 생략, §4-C-2-4). `make_cell`은 base `scenario.yaml` 로드 후 dict 병합(workload params, stress.cpu_saturate=cpu, 자유 축 key 경로 세팅, `stress.vm_bytes = target_total − WL_RESIDENT`(Option B, §6-10 — resident는 manifest 평가)). 마지막에:

```python
    total = len(runs)
    est_h = total * est_run_s / 3600
    print(f"PLAN: {total} runs, est ~{est_h:.1f}h (--est-run-s {est_run_s})")
    if not yes and input("proceed? [y/N] ").lower() != "y":
        sys.exit("aborted")   # §4-C-2-3 조용히 시작 금지
```

- [ ] **Step 2: 단위 테스트 (2셀 미니 campaign)**

```bash
cat > /tmp/claude-0/camp_mini.yaml <<'EOF'
campaign: mini
reps: 2
stress: {target_total_mib: 1278, workers: 29}
axes: {cpu: [busy, idle], kdat: [on, off]}
workloads:
  - name: dirty
    sweep: {param: bytes, values_mib: {from: 30, to: 40, step: 10}}
    dump_at: [served_first]
EOF
testbed/runner/expand_campaign.py /tmp/claude-0/camp_mini.yaml /tmp/claude-0/camp_mini --yes
wc -l /tmp/claude-0/camp_mini/plan.tsv
awk -F'\t' '{print $2}' /tmp/claude-0/camp_mini/plan.tsv | sort | uniq -c
```

Expected: 계산 = 2값 × 2cpu × 2rep = 8 cold + (8 × kdat 2) = 16 restore → **24줄**; `8 cold / 16 restore`; 모든 config YAML의 port가 서로 다름 (`grep -h 'port' /tmp/claude-0/camp_mini/configs/*.yaml | sort | uniq -d` 빈 출력); `expansion.json`에 `values: [30, 40]` 명시 기록.

- [ ] **Step 3: Commit**

```bash
git add testbed/runner/expand_campaign.py && git commit -m "rewrite(6/9f): expand_campaign — 값표현식·자유축·cold중복제거·포트배정·런수 가드"
```

---

### Task 15: run_campaign.sh (실행 드라이버)

**Files:**
- Create: `testbed/runner/run_campaign.sh`
- 이식 소스: `testbed_old/runner/run_campaign_redesign.sh` (calibration fit·finalize·log 함수)

**Interfaces:**
- Consumes: `plan.tsv`(Task 14), 두 러너(Task 12–13), collect/summarize(Task 16).
- Produces: CLI `run_campaign.sh <configs/campaign_*.yaml>` (env: `SMOKE=1`, `YES=1`); 산출 `testbed/experiments/<campaign>/{all_runs.csv,summary_by_condition.csv}` + `progress.log`.

- [ ] **Step 1: 작성**

구조 (old의 검증된 흐름 계승, YAML 해석은 전부 expander에 위임):

```bash
#!/usr/bin/env bash
set -euo pipefail
# 1. calibration (campaign에 calibrate_from_ms 있는 워크로드만):
#    이식: old PHASE 1 — CALIB_ITERS=(50 200 500 1000 1800)로 cold 런 → compute_ms 수집
#    → 선형 fit (old의 pure-python fit 블록 이식) → "--resolve initburst.iters=..." 문자열 생성
# 2. expand_campaign.py <yaml> <campaign_dir> $RESOLVE ${YES:+--yes}
#    (SMOKE=1이면 expander에 넘기기 전에 reps=1·대표 2셀로 줄인 임시 YAML 생성)
# 3. plan.tsv 순회:
while IFS=$'\t' read -r rid kind cfg kdat; do
	case "$kind" in
		cold)    sudo "$SCRIPT_DIR/run_cold_start.sh" --run-id "$rid" --config "$cfg" || echo "FAIL $rid" >> "$FAILS" ;;
		restore) sudo "$SCRIPT_DIR/run_once.sh" --run-id "$rid" --config "$cfg" --kdat-cache "$kdat" || echo "FAIL $rid" >> "$FAILS" ;;
	esac
done < "$CAMPAIGN_DIR/plan.tsv"
# 4. finalize: 이식 old의 collect+summarize 호출부 → experiments/<campaign>/
# 5. 요약 출력: 총/PASS/FAIL 수 + FAIL run_id 목록 (침묵 스킵 금지, §6-16)
```

- [ ] **Step 2: 정적 검사 + SMOKE 관통**

```bash
bash -n testbed/runner/run_campaign.sh && shellcheck testbed/runner/run_campaign.sh
# SMOKE는 Task 18에서 공식 실행 — 여기서는 plan 생성까지만 (--yes 없이 run count 출력 확인)
```

- [ ] **Step 3: Commit**

```bash
git add testbed/runner/run_campaign.sh && git commit -m "rewrite(6/9g): run_campaign — calibration→expand→실행→finalize"
```

---

### Task 16: collect.py / summarize.py 갱신

**Files:**
- Create: `testbed/runner/collect.py`, `testbed/runner/summarize.py` (이식: `testbed_old/runner/` 동명 파일)

**Interfaces:**
- Produces: `all_runs.csv` (열 = 전 run의 result.env **키 합집합**, 미측정 `na` — `wl_*`·`dump_phase` 자동 포함), `summary_by_condition.csv` (그룹 키에 `dump_phase` 추가, bootstrap CI 로직 무변경).

- [ ] **Step 1: 이식 + 확장**

- `collect.py`: old를 복사. 키 수집이 고정 목록이면 **동적 합집합**으로 교체 (모든 result.env의 키 union → 열; 새 키가 코드 수정 없이 CSV에 들어가는 것이 §4 플러그인 목표). 이미 동적이면 무변경.
- `summarize.py`: old를 복사. condition 도출(run_id에서 `_repNN` 제거)은 유지하고, 그룹 키에 `dump_phase` 열 추가.

- [ ] **Step 2: 테스트 (Task 12–13의 수동 런 3개로)**

```bash
testbed/runner/collect.py testbed/runs /tmp/claude-0/all.csv
head -1 /tmp/claude-0/all.csv | tr ',' '\n' | grep -E '^(wl_checksum|dump_phase)$'
testbed/runner/summarize.py /tmp/claude-0/all.csv /tmp/claude-0/sum.csv && head -3 /tmp/claude-0/sum.csv
```

Expected: 두 신규 열 존재, summarize 정상 산출.

- [ ] **Step 3: Commit**

```bash
git add testbed/runner/{collect.py,summarize.py} && git commit -m "rewrite(7/9): collect(키 합집합)/summarize(dump_phase 그룹키)"
```

---

### Task 17: README 전체 + PLAN 진척 노트 갱신

**Files:**
- Create: `testbed/README.md`, `testbed/{env,env/hardware,stress,workloads,runner}/README.md`
- Modify: `PLAN_FULL.md`(§0.5), `PLAN_MIN.md`(진척 노트)

- [ ] **Step 1: README 작성 지침**

| 파일 | 필수 내용 |
|---|---|
| testbed/README.md | 디렉터리 지도, quickstart(criu/build → workloads/build → run_campaign), 용어 규약(`stress-*`=배경부하 / `workload-*`=측정대상), 스펙·플랜 링크 |
| workloads/README.md | **계약 §4 전문 전사** (A1–A6 + manifest 필드표 + "새 워크로드 추가 3단계" 예시) — 새 워크로드 작성자의 유일한 필독 문서 |
| runner/README.md | lib 8모듈 표(함수·uses/sets), 측정 창 불변식 요약(§6-1~6), 두 러너 CLI, campaign 흐름 |
| env/README.md, env/hardware/README.md | flattened-env 인터페이스, verb 규약, policy seam 안내 |
| stress/README.md | oom-protect loop-until-stable 근거(§6-13) 포함 |

- [ ] **Step 2: PLAN 스테일 수정**

- `PLAN_FULL.md` §0.5: "kdat은 /run=overlayfs라 off 고정" → "kdat on/off 모두 가능 (criu/ vendoring + /dev/shm 패치)"; `audit_profile.sh` 참조 삭제; workloads 문단을 계약 기반 플러그인 서술로.
- `PLAN_MIN.md` 다음 단계 표: "workloads/modules·generator 미구현" → "✅ 계약 기반 플러그인으로 이행 (스펙 §4)".

- [ ] **Step 3: Commit**

```bash
git add testbed/*/README.md testbed/README.md testbed/env/hardware/README.md PLAN_FULL.md PLAN_MIN.md
git commit -m "rewrite(8/9): README 전체 + PLAN 진척 노트 (kdat 스테일 수정, 플러그인 이행 표기)"
```

---

### Task 18: 스모크 (6런) + 스키마 diff

- [ ] **Step 1: SMOKE 캠페인 실행**

```bash
sudo SMOKE=1 YES=1 testbed/runner/run_campaign.sh testbed/configs/campaign_parity.yaml
```

(campaign_parity.yaml은 Task 20 Step 1에서 미리 작성 — 스모크는 그 축소판을 씀. 순서상 여기서 먼저 작성해도 됨.)
Expected: 6런(2셀 × cold/koff/kon) 전부 PASS, `experiments/<campaign>_smoke/` 산출.

- [ ] **Step 2: 스키마 키 diff (old 대비)**

```bash
old_run=$(ls testbed/runs | grep -m1 'dirty_50M_cpubusy_koff.*restore')
new_run=$(ls testbed/runs | grep -m1 'smoke.*koff.*')   # 스모크 restore 런
diff <(awk -F= '{print $1}' testbed/runs/$old_run/result.env | sort) \
     <(awk -F= '{print $1}' testbed/runs/$new_run/result.env | sort)
```

Expected: 차이는 **추가 키만** (`dump_phase`, `warmup_pings`, `criu_version`, `criu_patch_sha`, `wl_*`, `resident_mismatch`). old 키가 새 쪽에 없으면(< 행) 스키마 회귀 — result.sh로 돌아가 수정.

- [ ] **Step 3: Commit (스모크 산출물은 커밋 안 함 — 통과 기록만)**

```bash
git commit --allow-empty -m "rewrite(9/9a): smoke 6/6 PASS, 스키마 diff = 추가 키만 (기록)"
```

---

### Task 19: 측정 불변식 20개 1:1 감사

**Files:**
- Create: `docs/superpowers/reviews/2026-07-testbed-rewrite-invariants.md`

- [ ] **Step 1: 감사 문서 작성**

스펙 §6의 20개 항목 각각에 대해 `| # | 판정(PASS/FAIL) | 증거(file:line) |` 표를 채운다.
예: `#1 | PASS | runner/lib/probe.sh:12-28 (kill -0→cprobe→EPOCHREALTIME, 스폰 cprobe뿐)`.
FAIL이 하나라도 있으면 해당 태스크로 돌아가 수정 후 재감사.

- [ ] **Step 2: 창 안 스폰 기계 검증 (보조)**

```bash
# probe_first_response 실행 중 자식 프로세스 종류 확인: cprobe와 sleep만 허용
sudo strace -f -e trace=execve -o /tmp/claude-0/win.trace bash -c '
  source testbed/runner/lib/probe.sh; TESTBED_DIR=$PWD/testbed
  testbed/workloads/bin/simple --bytes 4194304 --port 18995 & sleep 0.3
  PROBE_CPROBE=testbed/runner/cprobe probe_first_response $! 18995 5; kill %1'
grep execve /tmp/claude-0/win.trace | grep -vE 'cprobe|/bin/sleep|bash' || echo "window clean"
```

Expected: `window clean`.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/reviews/ && git commit -m "rewrite(9/9b): 측정 불변식 20개 감사 — 전 항목 PASS + 증거"
```

---

### Task 20: A/B 패리티 120런 + old 동결

**Files:**
- Create: `testbed/configs/campaign_parity.yaml`, `reports/compare_parity.py`
- Modify: `testbed_old/README.md` (동결 확정)

- [ ] **Step 1: campaign_parity.yaml 작성**

```yaml
campaign: parity
reps: 10
stress: {target_total_mib: 1278, workers: 29}
axes:
  cpu: [busy, idle]
  kdat: [on, off]
workloads:
  - name: dirty
    sweep: {param: bytes, values_mib: [50]}
    dump_at: [served_first]      # = old "워밍업 1회 후 dump" (§4-A6)
  - name: initburst
    sweep: {param: iters, calibrate_from_ms: [150]}
    dump_at: [served_first]
warmup_pings: 1
```

(2 workload × 2 cpu = 4셀; 셀당 cold 10 + koff 10 + kon 10 = 120런.)

- [ ] **Step 2: tmux로 실행 + 완료 알람**

```bash
tmux new-session -d -s parity \
  'sudo YES=1 testbed/runner/run_campaign.sh testbed/configs/campaign_parity.yaml; echo PARITY_DONE'
# 완료 감지: tmux capture-pane에서 PARITY_DONE 폴링 (기존 캠페인 관행)
```

Expected: 120/120 PASS (FAIL 있으면 목록 확인 후 원인별 재실행).

- [ ] **Step 3: compare_parity.py 작성 + 판정**

```python
#!/usr/bin/env python3
"""새 parity 캠페인 중앙값이 old wsk_redesign bootstrap 95% CI 안인지 판정 (스펙 §8-3)."""
import csv, statistics, sys
# 조건 매핑: (새 run_id prefix) → (old condition, [비교 지표])
MAP = {
    "dirty_50M_cpubusy":  ("dirty_50M_cpubusy",  ["cold_response"]),
    "dirty_50M_cpuidle":  ("dirty_50M_cpuidle",  ["cold_response"]),
    "dirty_50M_cpubusy_koff": ("dirty_50M_cpubusy_koff", ["restore_response", "restore_time"]),
    # ... (cpuidle/kon, initburst→ib_150ms 4조합 — 같은 패턴으로 전 12조건 나열)
}
old = {r["condition"]: r for r in csv.DictReader(open(
    "testbed/experiments/wsk_redesign/summary_by_condition.csv"))}
new_rows = list(csv.DictReader(open(sys.argv[1])))   # parity all_runs.csv
fails = []
for new_pfx, (old_cond, metrics) in MAP.items():
    for m in metrics:
        vals = [float(r[f"{m}_s"]) for r in new_rows
                if r["run_id"].startswith(new_pfx) and r.get(f"{m}_s", "na") != "na"]
        med = statistics.median(vals)
        lo, hi = float(old[old_cond][f"{m}_s_ci_lo"]), float(old[old_cond][f"{m}_s_ci_hi"])
        ok = lo <= med <= hi
        print(f"{'PASS' if ok else 'FAIL'} {new_pfx}/{m}: new_med={med:.3f} old_CI=[{lo:.3f},{hi:.3f}] n={len(vals)}")
        if not ok:
            fails.append((new_pfx, m))
sys.exit(1 if fails else 0)
```

(주의: 새 run_id·CSV의 실제 열 이름을 먼저 확인해 MAP·필드명을 맞춘다. initburst의 새 이름은 iters 기반이므로 expander 산출 `expansion.json`에서 실명을 읽어 MAP을 완성한다.)

Run: `python3 reports/compare_parity.py testbed/experiments/parity/all_runs.csv`
Expected: 전 항목 PASS. **FAIL 시**: 스펙 §8-3 — 원인 규명 전 old 동결 금지. testbed_old로 같은 조건 소규모 재실행(host drift 분리) → 코드 원인이면 해당 태스크 수정 → 재실행.

- [ ] **Step 4: old 동결 확정 + 최종 커밋**

`testbed_old/README.md`의 "패리티 검증:" 줄에 날짜 + `compare_parity.py 전 항목 PASS` 기입.

```bash
git add testbed/configs/campaign_parity.yaml reports/compare_parity.py testbed_old/README.md \
        testbed/experiments/parity/summary_by_condition.csv
git commit -m "rewrite(9/9c): A/B 패리티 120런 PASS — old 동결 확정, 재작성 완료"
```

---

## Self-Review 기록

- 스펙 커버리지: §9 마이그레이션 9단계 ↔ Task 1–20 대응표(문서 상단) 확인. §6 불변식은 Task 19에서 1:1 감사.
- 타입/시그니처 일관성: `config_load(run_id, yaml)` / `wl_launch`·`wl_wait_phase`·`wl_kv` / `probe_first_response(pid, port, timeout_s)` / `result_set`·`result_write` — Task 10–13에서 동일 시그니처 사용 확인.
- 이식 규약(계획 상단)에 따라 old 참조는 전부 `testbed_old/` 경로+함수명 명시.

