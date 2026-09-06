/* workloads/initburst/workload.c — 상주 버퍼 + 시작 시 컴퓨트 버스트 워크로드 (계약 v2)
 * 이식원: testbed_old/workloads/target_compute.c
 *   컴퓨트 버스트 로직(mix/compute_pass/monotonic_ms, clock_gettime 계측)은 그대로,
 *   인터페이스만 교체:
 *     - positional args → flags.h(--buf_bytes/--iters/--interval_ms/--port)
 *     - 자체 소켓(service_open/service_wait) → probe_server.h
 *     - WORKLOAD_READY → PHASE ready(compute_ms=%.1f) / PHASE init(버스트 시작 전, pre-ready
 *       dump 지점, §4-A6)
 *     - [idle|recompute] 모드 제거 — recompute 폐기, idle 고정(steady-state 재계산 없음).
 *       should_exit 기반 신호 핸들링도 함께 제거(다른 워크로드와 동일하게 SIGTERM 기본 동작으로
 *       종료, §4-A5)
 * PHASE: init(버스트 직전) → ready(버스트 완료+포트 open, compute_ms 보고)
 *        → served_first(probe_server 자동, §4-A6) */
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "flags.h"
#include "probe_server.h"

/* 구 target_compute.c:66-75 이식, verbatim (에러 프리픽스만 target_compute → initburst) */
static uint64_t monotonic_ms(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
		fprintf(stderr, "initburst: clock_gettime failed: %s\n", strerror(errno));
		exit(1);
	}
	return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

/* 구 target_compute.c:77-86 이식, verbatim.
 * splitmix64-style mixing — real compute the compiler can't optimize away. */
static inline uint64_t mix(uint64_t x)
{
	x ^= x >> 30;
	x *= 0xbf58476d1ce4e5b9ULL;
	x ^= x >> 27;
	x *= 0x94d049bb133111ebULL;
	x ^= x >> 31;
	return x;
}

/* 구 target_compute.c:88-96 이식, verbatim.
 * One compute pass over the buffer: read + mix + write-back. Returns running checksum. */
static uint64_t compute_pass(uint64_t *buf, size_t n, uint64_t acc)
{
	for (size_t i = 0; i < n; i++) {
		acc = mix(acc ^ buf[i]);
		buf[i] = acc;
	}
	return acc;
}

int main(int argc, char **argv)
{
	size_t buf_bytes = (size_t)wl_flag_long(argc, argv, "--buf_bytes", 1048576);
	long iters = wl_flag_long(argc, argv, "--iters", 100);
	long interval_ms = wl_flag_long(argc, argv, "--interval_ms", 200);
	long port = wl_flag_long(argc, argv, "--port", 0);

	if (iters <= 0) {
		fprintf(stderr, "initburst: --iters must be > 0 (got %ld)\n", iters);
		return 2;
	}
	unsigned long long compute_iters = (unsigned long long)iters;

	size_t n = buf_bytes / sizeof(uint64_t);
	if (n == 0) {
		n = 1;
	}
	uint64_t *buf = malloc(n * sizeof(uint64_t));
	if (!buf) {
		fprintf(stderr, "initburst: malloc failed: %s\n", strerror(errno));
		return 1;
	}
	/* 구 target_compute.c:210-213 이식, verbatim — deterministic seed, 모든 페이지 상주화 */
	for (size_t i = 0; i < n; i++) {
		buf[i] = mix((uint64_t)i + 0x9e3779b97f4a7c15ULL);
	}

	printf("PHASE init\n");   /* 버스트 시작 전 — pre-ready dump 지점 (§4-A6) */
	fflush(stdout);

	/* 구 target_compute.c:218-224 이식, verbatim — heavy startup compute: 정확히 CRIU
	 * restore가 건너뛰는 구간. (구의 "&& !should_exit" 조건은 신호 핸들러 제거에 맞춰 삭제) */
	uint64_t start_ms = monotonic_ms();
	uint64_t acc = 0;
	for (unsigned long long it = 0; it < compute_iters; it++) {
		acc = compute_pass(buf, n, acc);
	}
	uint64_t compute_ms = monotonic_ms() - start_ms;

	int p = -1;
	int fd = probe_listen((int)port, &p);
	printf("PHASE ready port=%d compute_ms=%.1f\n", p, (double)compute_ms);
	fflush(stdout);

	for (;;)
		probe_serve_pending(fd, interval_ms > 0 ? (interval_ms > INT_MAX ? INT_MAX : (int)interval_ms) : 1000);
	free(buf);   /* not reached; SIGTERM 기본 동작으로 종료 (§4-A5) */
	return 0;
}
