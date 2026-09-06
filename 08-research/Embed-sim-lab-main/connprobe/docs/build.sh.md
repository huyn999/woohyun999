# build.sh — 워크로드·피어 빌드

```bash
./build.sh          # bin/connprobe, bin/xpeer
CC=clang ./build.sh # 컴파일러 지정 (기본 gcc)
CFLAGS="-O2 -Wall -g" ./build.sh
```

- `connprobe.c` → `bin/connprobe` (통합 연결-생존 워크로드)
- `xpeer.c` → `bin/xpeer` (덤프 밖 외부 피어)

`probe_sweep.sh` / `xmatrix.sh` 는 바이너리가 없으면 이 스크립트를 자동으로 부른다. 표준
POSIX 소켓/epoll 만 쓰므로 외부 의존성 없음. `failprobe`/`webos_probe` 워크로드(fp_*)는 이
스크립트가 아니라 `testbed/workloads/build.sh` 가 빌드한다.
