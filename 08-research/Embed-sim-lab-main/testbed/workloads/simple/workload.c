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

	if (bytes <= 0) {
		fprintf(stderr, "simple: --bytes must be > 0 (got %ld)\n", bytes);
		return 2;
	}

	unsigned char *buf = malloc((size_t)bytes);
	if (!buf) { fprintf(stderr, "simple: malloc(%ld) failed\n", bytes); return 1; }
	for (long i = 0; i < bytes; i += 4096)   /* 실제 상주시키기 (RSS = 선언 resident) */
		buf[i] = (unsigned char)(i & 0xff);

	int p = -1;
	int fd = probe_listen((int)port, &p);
	printf("PHASE ready port=%d bytes=%ld\n", p, bytes);
	fflush(stdout);

	for (;;)
		probe_serve_pending(fd, 1000);
	free(buf);   /* not reached; SIGTERM 기본 동작으로 종료 (§4-A5) */
	return 0;
}
