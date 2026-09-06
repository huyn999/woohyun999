/* workloads/common/flags.h — 계약 §4-A1 named flag 파서 (전 워크로드 공용)
 * 모든 파라미터는 "--name value" 형태. 미지정 시 default. 잘못된 값은 exit(2). */
#ifndef WL_FLAGS_H
#define WL_FLAGS_H
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 중복 플래그(--x a --x b)는 첫 값(a) 우선 — 앞에서부터 찾아 첫 매치에서 즉시 반환.
 * render_flags가 중복 플래그를 만들지 않으므로 사실상 미도달 경로; 동작 변경 금지. */
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
	errno = 0;
	long v = strtol(s, &end, 10);
	if (end == s || *end != '\0') {   /* end==s: 자릿수 0개(빈 문자열/비숫자)로 조용히 0 반환되던 것 방지 */
		fprintf(stderr, "bad value for %s: %s\n", name, s);
		exit(2);
	}
	if (errno == ERANGE) {
		fprintf(stderr, "value out of range for %s: %s\n", name, s);
		exit(2);
	}
	return v;
}
#endif
