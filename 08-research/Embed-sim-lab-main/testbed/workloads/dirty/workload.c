/* workloads/dirty/workload.c — 상주 메모리 + 주기적 dirty 갱신 워크로드 (계약 v2)
 * 이식원: testbed_old/workloads/target_memory.c
 *   메모리 로직(할당·touch·dirty 갱신·checksum)은 그대로, 인터페이스만 교체:
 *     - positional args → flags.h(--bytes/--dirty_bytes/--interval_ms/--port)
 *     - 자체 소켓(service_open/service_wait) → probe_server.h
 *     - WORKLOAD_READY/STATE/EXIT → PHASE ready / served_first(자동) / steady
 *     - grow 모드·init_work_ms 제거(과거 실험 정리 때 폐기된 모드; init_work_ms는
 *       initburst 워크로드가 그 역할을 대체)
 * PHASE: ready → served_first(probe_server 자동) → steady(첫 dirty 갱신 완료 후) */
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "flags.h"
#include "probe_server.h"

static long page_size;
static uint64_t checksum = 0;

/* 구 target_memory.c:260-274 이식 (grow 분기 제거) — 주기적 dirty 갱신, verbatim.
 * cursor/iter는 old에서 main()의 지역변수로 반복(while) 호출에 걸쳐 유지되던
 * 상태이므로 이 함수의 static 지역변수로 보존한다 — 로직 자체는 수정하지 않음. */
static void touch_dirty_pages(uint8_t *buf, size_t bytes, size_t dynamic_bytes)
{
	static size_t cursor = 0;
	static unsigned long long iter = 0;
	size_t dirtied = 0;

	while (dirtied < dynamic_bytes) {
		buf[cursor] = (uint8_t)(buf[cursor] + (uint8_t)(iter + 1));
		checksum += buf[cursor] + cursor + iter;
		cursor += (size_t)page_size;
		if (cursor >= bytes) {
			cursor = 0;
		}
		dirtied += (size_t)page_size;
	}

	iter++;
}

int main(int argc, char **argv)
{
	long bytes = wl_flag_long(argc, argv, "--bytes", 52428800);
	long dirty_bytes = wl_flag_long(argc, argv, "--dirty_bytes", 1048576);
	long interval_ms = wl_flag_long(argc, argv, "--interval_ms", 200);
	long port = wl_flag_long(argc, argv, "--port", 0);

	if (bytes <= 0) {
		fprintf(stderr, "dirty: --bytes must be > 0 (got %ld)\n", bytes);
		return 2;
	}
	if (dirty_bytes < 0) {
		fprintf(stderr, "dirty: --dirty_bytes must be >= 0 (got %ld)\n", dirty_bytes);
		return 2;
	}

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) {
		fprintf(stderr, "dirty: sysconf(_SC_PAGESIZE) failed\n");
		return 1;
	}

	/* 구 target_memory.c:186-189 이식 (dirty 모드 클램프, verbatim) */
	if ((size_t)dirty_bytes > (size_t)bytes) {
		dirty_bytes = bytes;
	}

	/* 구 target_memory.c:197-205 이식 (할당 + touch, verbatim) */
	uint8_t *buf = malloc((size_t)bytes);
	if (!buf) {
		fprintf(stderr, "dirty: malloc failed: %s\n", strerror(errno));
		return 1;
	}
	for (size_t off = 0; off < (size_t)bytes; off += (size_t)page_size) {
		buf[off] = (uint8_t)(off / (size_t)page_size);
	}

	int p = -1;
	int fd = probe_listen((int)port, &p);
	printf("PHASE ready port=%d bytes=%ld checksum=%lu\n", p, bytes, (unsigned long)checksum);
	fflush(stdout);

	long passes = 0;
	for (;;) {
		probe_serve_pending(fd, interval_ms > 0 ? (interval_ms > INT_MAX ? INT_MAX : (int)interval_ms) : 1000);
		touch_dirty_pages(buf, (size_t)bytes, (size_t)dirty_bytes);   /* old의 주기 dirty 함수 그대로 */
		if (++passes == 1) {                          /* 첫 dirty 갱신 완료 = steady */
			printf("PHASE steady\n");
			fflush(stdout);
		}
	}
	free(buf);   /* not reached; SIGTERM 기본 동작으로 종료 (§4-A5) */
	return 0;
}
