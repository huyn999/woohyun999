#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <limits.h>
#include "list.h"
#include "hash.h"
#include "bitmap.h"
#include "debug.h"

#define MAX_DS  10       // 동시에 생성할 수 있는 자료구조의 최대 개수
#define BUF_SZ  256      // 입력 버퍼 크기
#define TOK_MAX 6        // 한 줄에서 분리할 최대 토큰 수  예: "list_splice dst 0 src 1 3" → 6개 토큰


/* 자료구조 통합 관리 구조체 */
// 이름, 타입, 실제 데이터를 하나의 구조체로 묶어 관리
// 타입: 'L' = list, 'H' = hashtable, 'B' = bitmap, '\0' = 미사용
typedef struct {
    char          name[BUF_SZ]; // 자료구조 이름 (예: "mylist")
    char          type;         // 자료구조 종류: 'L' / 'H' / 'B' / '\0'
    struct list   lst;          // 리스트 (type == 'L'일 때 사용)
    struct hash   ht;           // 해시 테이블 (type == 'H'일 때 사용)
    struct bitmap *bmp;         // 비트맵 포인터 (type == 'B', bitmap_expand 때문에 포인터)
} ds_entry;

static ds_entry ds[MAX_DS]; // 자료구조 슬롯 배열: 최대 10개
static int ds_total = 0;    // 현재까지 생성된 자료구조 총 수


static int lookup(const char *name) // 자료구조의 이름을 가지고 그 해당 자료구조 인덱스를 찾음
{
    for (int i = 0; i < ds_total; i++)
        if (strcmp(ds[i].name, name) == 0)
            return i; // 이름이 일치하는 인덱스 반환
    return -1;
}


/*  create 명령 처리 */
// create list/hashtable/bitmap 명령을 처리하여 자료구조를 초기화
static void cmd_create(int argc, char *tok[])
{
    if (strcmp(tok[1], "list") == 0) {
        // 리스트 생성: list_init으로 head/tail 초기화
        list_init(&ds[ds_total].lst);
        strcpy(ds[ds_total].name, tok[2]); // 이름 저장
        ds[ds_total].type = 'L';           // 타입 표시
    }
    else if (strcmp(tok[1], "hashtable") == 0) {
        // 해시 테이블 생성: hash_int_func과 hash_int_less를 함수 포인터로 전달
        hash_init(&ds[ds_total].ht, hash_int_func, hash_int_less, NULL);
        strcpy(ds[ds_total].name, tok[2]);
        ds[ds_total].type = 'H';
    }
    else if (strcmp(tok[1], "bitmap") == 0) {
        // 비트맵 생성: tok[3]에서 비트 수를 읽어 bitmap_create 호출
        ds[ds_total].bmp = bitmap_create((size_t)atoi(tok[3])); // tok[3] = 비트맵 비트 수 
        strcpy(ds[ds_total].name, tok[2]);
        ds[ds_total].type = 'B';
    }
    ds_total++; // 자료구조 수가 추가 될때마다 ++
}

/* delete 명령 처리 */
// 자료구조를 삭제하고 내부 원소들의 메모리를 해제
static void cmd_delete(int argc, char *tok[])
{
    int id = lookup(tok[1]); // 이름으로 삭제할 자료구조의 인덱스 검색
    if (id < 0) return;

    if (ds[id].type == 'L') {
        // 리스트: 모든 원소를 pop하면서 동적 해제
        while (!list_empty(&ds[id].lst)) {
            struct list_elem *e = list_pop_front(&ds[id].lst);
            free(list_entry(e, list_item, elem)); // list_entry 매크로: list_elem 포인터 → 감싸는 list_item 포인터로 변환
        }
    }
    else if (ds[id].type == 'H') {
        // 해시: hash_clear에 소멸 함수(free_hash_elem) 전달
        hash_clear(&ds[id].ht, free_hash_elem);
    }
    else { // 'B'
        // 비트맵: bitmap_destroy로 bits 배열과 구조체 해제
        bitmap_destroy(ds[id].bmp);
        ds[id].bmp = NULL;
    }
    ds[id].name[0] = '\0'; // 이름 초기화: 이름의 첫 부분만 널로 바꿔도 이름 못 찾음
    ds[id].type    = '\0'; // 타입 초기화
}

/* dumpdata 명령 처리  */
// 자료구조 내부 데이터를 표준 출력으로 인쇄
static void cmd_dumpdata(int argc, char *tok[])
{
    int id = lookup(tok[1]); // id 넘버를 반환
    if (id < 0) return;

    if (ds[id].type == 'L') {
        // 리스트가 비어있지 않으면 모든 원소의 value를 출력
        if (!list_empty(&ds[id].lst)) {
            struct list_elem *e;
            for (e = list_begin(&ds[id].lst); e != list_end(&ds[id].lst); e = list_next(e)) {
                list_item *it = list_entry(e, list_item, elem); // elem에서 list_item으로 변환
                printf("%d ", it->value);
            }
            printf("\n");
        }
    }
    else if (ds[id].type == 'H') {
        // 해시가 비어있지 않으면 hash_apply로 print_hash_elem을 적용해 모든 원소 출력
        if (!hash_empty(&ds[id].ht)) {
            hash_apply(&ds[id].ht, print_hash_elem);
            printf("\n");
        }
    }
    else { // 'B'
        // 비트맵의 각 비트를 0 또는 1로 출력
        size_t sz = bitmap_size(ds[id].bmp);
        for (size_t i = 0; i < sz; i++) // 반복문으로 bitmap_test 이용해 출력
            printf("%d", bitmap_test(ds[id].bmp, i) ? 1 : 0);
        printf("\n");
    }
}

/* list 계열 명령 처리 */
// sub = "list_" 이후의 접미사 (예: "push_back", "splice" …)
static void cmd_list(const char *sub, int argc, char *tok[])
{
    int id = lookup(tok[1]);
    if (id < 0 || ds[id].type != 'L') return; // 리스트가 아니면 무시

    struct list *lst = &ds[id].lst; // id번째 리스트의 주소값 저장

    // list_push_back: 리스트 뒤에 새 원소 추가
    if (strcmp(sub, "push_back") == 0) {
        list_item *ni = malloc(sizeof(list_item)); // 새 list_item 동적 할당
        ni->value = atoi(tok[2]);                  // 문자열을 정수로 변환하여 값 저장
        list_push_back(lst, &ni->elem);            // 리스트 tail 앞에 삽입
    }
    // list_push_front: 리스트 앞에 새 원소 추가
    else if (strcmp(sub, "push_front") == 0) {
        list_item *ni = malloc(sizeof(list_item));
        ni->value = atoi(tok[2]);
        list_push_front(lst, &ni->elem); // 리스트 head 뒤에 삽입
    }
    // list_front: 리스트 첫 번째 원소의 값 출력
    else if (strcmp(sub, "front") == 0) {
        if (list_empty(lst)) return; // 비어있으면 무시
        printf("%d\n", list_entry(list_front(lst), list_item, elem)->value);
    }
    // list_back: 리스트 마지막 원소의 값 출력
    else if (strcmp(sub, "back") == 0) {
        if (list_empty(lst)) return; // 비어있으면 무시
        printf("%d\n", list_entry(list_back(lst), list_item, elem)->value); // 리스트 아이템으로 복구 후 value 출력
    }
    // list_pop_front: 첫 번째 원소를 제거하고 메모리 해제
    else if (strcmp(sub, "pop_front") == 0) {
        if (list_empty(lst)) return;
        free(list_entry(list_pop_front(lst), list_item, elem)); // 복구 후 동적 해제
    }
    // list_pop_back: 마지막 원소를 제거하고 메모리 해제
    else if (strcmp(sub, "pop_back") == 0) {
        if (list_empty(lst)) return;
        free(list_entry(list_pop_back(lst), list_item, elem));
    }
    // list_insert: 지정 위치에 원소 삽입
    else if (strcmp(sub, "insert") == 0) {
        list_item *ni = malloc(sizeof(list_item));
        ni->value = atoi(tok[3]); // 삽입할 값
        // pos번째 elem을 직접 탐색하여 그 원소 앞에 삽입
        int pos = atoi(tok[2]); // 삽입 위치
        struct list_elem *pos_e = list_begin(lst);
        while (pos-- > 0 && pos_e != list_end(lst)) pos_e = list_next(pos_e);
        list_insert(pos_e, &ni->elem);
    }
    // list_insert_ordered: 오름차순 정렬 유지하며 삽입
    else if (strcmp(sub, "insert_ordered") == 0) {
        int val = atoi(tok[2]);
        list_item *ni = malloc(sizeof(list_item));
        ni->value = val;
        // val보다 큰 첫 원소 앞을 탐색; 없으면 list_end → list_push_back과 동일
        struct list_elem *cur;
        for (cur = list_begin(lst); cur != list_end(lst); cur = list_next(cur))
            if (list_entry(cur, list_item, elem)->value > val) break;
        list_insert(cur, &ni->elem);
    }

    // list_empty: 비어있는지 확인
    else if (strcmp(sub, "empty") == 0) {
        printf("%s\n", list_empty(lst) ? "true" : "false");
    }
    // list_size: 원소 개수 출력
    else if (strcmp(sub, "size") == 0) {
        printf("%zu\n", list_size(lst));
    }
    // list_max: 최대값 출력
    else if (strcmp(sub, "max") == 0) {
        if (list_empty(lst)) return;
        int mx = INT_MIN;
        struct list_elem *e; // e를 이동해가면서 max값 찾음
        for (e = list_begin(lst); e != list_end(lst); e = list_next(e)) {
            int v = list_entry(e, list_item, elem)->value;
            if (v > mx) mx = v;
        }
        printf("%d\n", mx);
    }
    // list_min: 최소값 출력
    else if (strcmp(sub, "min") == 0) {
        if (list_empty(lst)) return;
        int mn = INT_MAX;
        struct list_elem *e;
        for (e = list_begin(lst); e != list_end(lst); e = list_next(e)) {
            int v = list_entry(e, list_item, elem)->value;
            if (v < mn) mn = v;
        }
        printf("%d\n", mn);
    }
    // list_remove: 지정 위치의 원소 제거
    else if (strcmp(sub, "remove") == 0) {
        if (list_empty(lst)) return;
        int rm_idx = atoi(tok[2]); // 제거할 위치
        struct list_elem *target = list_begin(lst);
        while (rm_idx-- > 0 && target != list_end(lst)) target = list_next(target);
        list_remove(target);
        free(list_entry(target, list_item, elem));
    }
    // list_reverse: 원소 순서 뒤집기
    else if (strcmp(sub, "reverse") == 0) {
        if (!list_empty(lst)) list_reverse(lst);
    }
    // list_shuffle: 직접 list.c에 구현함
    else if (strcmp(sub, "shuffle") == 0) {
        if (list_size(lst) >= 2) list_shuffle(lst); // 리스트 원소 2개 이상이면 셔플 진행
    }
    // list_sort로 오름차순 정렬
    else if (strcmp(sub, "sort") == 0) {
        if (list_size(lst) >= 2) list_sort(lst, list_less, NULL);
    }
    // list_splice: src 리스트의 일부를 dst로 이동
    else if (strcmp(sub, "splice") == 0) {
        int dst_id = id;             // tok[1]은 이미 id로 확인된 dst 리스트
        int src_id = lookup(tok[3]); // tok[3]에서 src 리스트 검색

        int di = atoi(tok[2]); // dst 삽입 위치
        struct list_elem *dst_e = list_begin(&ds[dst_id].lst);
        while (di-- > 0 && dst_e != list_end(&ds[dst_id].lst)) dst_e = list_next(dst_e);

        int bi = atoi(tok[4]); // src 시작 위치
        struct list_elem *s_beg = list_begin(&ds[src_id].lst);
        while (bi-- > 0 && s_beg != list_end(&ds[src_id].lst)) s_beg = list_next(s_beg);

        int ei = atoi(tok[5]); // src 끝 위치 (exclusive)
        struct list_elem *s_end = list_begin(&ds[src_id].lst);
        while (ei-- > 0 && s_end != list_end(&ds[src_id].lst)) s_end = list_next(s_end);

        list_splice(dst_e, s_beg, s_end);
    }
    // list_swap: 두 위치의 원소 교환
    else if (strcmp(sub, "swap") == 0) {
        if (list_empty(lst)) return;
        int i1 = atoi(tok[2]); // 첫 번째 위치
        struct list_elem *e1 = list_begin(lst);
        while (i1-- > 0 && e1 != list_end(lst)) e1 = list_next(e1);//그 원소까지 이동

        int i2 = atoi(tok[3]); // 두 번째 위치
        struct list_elem *e2 = list_begin(lst);
        while (i2-- > 0 && e2 != list_end(lst)) e2 = list_next(e2);

        if (e1 != list_end(lst) && e2 != list_end(lst))
            list_swap(e1, e2);
    }

    // list_unique: 연속 중복 원소 제거
    else if (strcmp(sub, "unique") == 0) {
        struct list *dup = NULL;
        if (argc >= 3) // 만약 명령어에 옮길 리스트 인자 있다면
        {
            int did = lookup(tok[2]);
            if (did >= 0 && ds[did].type == 'L')
                dup = &ds[did].lst; // 그 리스트 주소 지정
        }
        list_unique(lst, dup, list_less, NULL);
    }
}

/*  hash 계열 명령 처리  */
// sub = "hash_" 이후의 접미사 (예: "insert", "find" …)
static void cmd_hash(const char *sub, int argc, char *tok[])
{
    int id = lookup(tok[1]);
    if (id < 0 || ds[id].type != 'H') return;

    struct hash *ht = &ds[id].ht;

    // hash_insert: 새 원소 삽입
    if (strcmp(sub, "insert") == 0) {
        hash_item *ne = malloc(sizeof(hash_item)); // 래퍼 구조체 해시 아이템 동적할당
        ne->value = atoi(tok[2]);
        struct hash_elem *old = hash_insert(ht, &ne->elem);
        if (old != NULL) free(ne); // 이미 존재하면 새 원소 해제
    }
    // hash_apply: 모든 원소에 함수 적용
    else if (strcmp(sub, "apply") == 0)
    {   // 아래 경우는 명령어 파싱에 의해
        if (strcmp(tok[2], "square") == 0) hash_apply(ht, apply_square);// 제곱 적용
        else if (strcmp(tok[2], "triple") == 0) hash_apply(ht, apply_triple);//세제곱 적용
    }
    // hash_delete: 해시 테이블내에 특정 값과 동일한 원소 삭제
    else if (strcmp(sub, "delete") == 0) {
        hash_item tmp;            // 임시 해시 아이템 선언
        tmp.value = atoi(tok[2]); // 값 설정
        struct hash_elem *del = hash_delete(ht, &tmp.elem); // 위 값과 동일한 원소 제거 및 반환
        if (del) free(hash_entry(del, hash_item, elem)); // 있었다면 감싸는 구조체 동적 해제
    }
    // hash_empty: 비어있는지 확인
    else if (strcmp(sub, "empty") == 0) {
        printf("%s\n", hash_empty(ht) ? "true" : "false");
    }
    // hash_size: 원소 개수 출력
    else if (strcmp(sub, "size") == 0) {
        printf("%zu\n", hash_size(ht));
    }
    // hash_clear: 해시테이블 내 모든 원소 제거, 해시테이블의 버켓들을 해제하지는 않는다
    else if (strcmp(sub, "clear") == 0) {
        hash_clear(ht, free_hash_elem);
    }
    // hash_find: 원소 검색 후 값 출력
    else if (strcmp(sub, "find") == 0) 
    {
        hash_item tmp; // 마찬가지로 값을 가진 임시구조체를 만들어서 찾는다
        tmp.value = atoi(tok[2]); // 해시 아이템 구조체에 값 삽입
        struct hash_elem *found = hash_find(ht, &tmp.elem);
        if (found) // 찾으면 출력 
            printf("%d\n", hash_entry(found, hash_item, elem)->value);
    }
    // hash_replace: 원소 교체
    else if (strcmp(sub, "replace") == 0) 
    {
        hash_item *ne = malloc(sizeof(hash_item));
        ne->value = atoi(tok[2]);
        struct hash_elem *old = hash_replace(ht, &ne->elem);
        if (old) free(hash_entry(old, hash_item, elem)); // 이미 존재했다면 그 래퍼 구조체도 동적 해제
    }
}

/*  bitmap 계열 명령 처리  */
// "bitmap_*" 명령어를 파싱하여 해당 bitmap 함수를 호출하는 핸들러
// sub = "bitmap_" 이후의 접미사 (예: "mark", "expand" …)
static void cmd_bitmap(const char *sub, int argc, char *tok[])
{
    // 이름으로 자료구조 인덱스 조회, bitmap 타입이 아니면 무시
    int id = lookup(tok[1]);
    if (id < 0 || ds[id].type != 'B') return;

    struct bitmap *bm = ds[id].bmp;

    // 지정 위치의 비트를 1로 설정
    if (strcmp(sub, "mark") == 0)
        bitmap_mark(bm, (size_t)atoi(tok[2]));

    // 주어진 범위(start, cnt)의 비트가 모두 1인지 검사
    else if (strcmp(sub, "all") == 0)
        printf("%s\n", bitmap_all(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3])) ? "true" : "false");

    // 주어진 범위에 1인 비트가 하나라도 있는지 검사
    else if (strcmp(sub, "any") == 0)
        printf("%s\n", bitmap_any(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3])) ? "true" : "false");

    // 주어진 범위에 특정 값(true/false)의 비트가 존재하는지 검사
    else if (strcmp(sub, "contains") == 0)
        printf("%s\n", bitmap_contains(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3]),strcmp(tok[4], "true") == 0) ? "true" : "false");

    // 주어진 범위에서 특정 값(true/false)인 비트의 개수를 셈
    else if (strcmp(sub, "count") == 0)
        printf("%zu\n", bitmap_count(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3]),strcmp(tok[4], "true") == 0));

    // 비트맵 전체 내용을 16진수로 덤프 출력
    else if (strcmp(sub, "dump") == 0)
        bitmap_dump(bm);

    // 비트맵 크기를 add만큼 확장, 새 비트맵 반환 시 기존 것 해제 후 교체
    else if (strcmp(sub, "expand") == 0) {
        size_t newsz = bitmap_size(bm) + (size_t)atoi(tok[2]); // 새로운 사이즈 계산
        struct bitmap *nb = bitmap_expand(bm, (int)newsz); // 그 사이즈에 맞는 비트맵 새로 생성
        if (nb != NULL && nb != bm)
        {
            bitmap_destroy(bm); ds[id].bmp = nb; // 기존의 비트맵은 제거 후 새 비트맵을 포인터 연결
        }
    }
    // 모든 비트를 일괄적으로 true 또는 false로 설정
    else if (strcmp(sub, "set_all") == 0)
        bitmap_set_all(bm, strcmp(tok[2], "true") == 0);

    // 지정 위치의 비트를 반전
    else if (strcmp(sub, "flip") == 0)
        bitmap_flip(bm, (size_t)atoi(tok[2]));

    // 주어진 범위의 비트가 모두 0인지 검사
    else if (strcmp(sub, "none") == 0)
        printf("%s\n", bitmap_none(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3])) ? "true" : "false");

    // 지정 위치의 비트를 0으로 리셋
    else if (strcmp(sub, "reset") == 0)
        bitmap_reset(bm, (size_t)atoi(tok[2]));

    // start부터 연속 cnt개의 특정 값 비트를 탐색하여 시작 인덱스 반환
    else if (strcmp(sub, "scan") == 0)
        printf("%lu\n", bitmap_scan(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3]),strcmp(tok[4], "true") == 0));

    // scan과 동일하되, 찾은 범위의 비트를 반전까지 수행
    else if (strcmp(sub, "scan_and_flip") == 0)
        printf("%lu\n", bitmap_scan_and_flip(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3]),strcmp(tok[4], "true") == 0));

    // 지정 위치의 비트를 true 또는 false로 설정
    else if (strcmp(sub, "set") == 0)
        bitmap_set(bm, (size_t)atoi(tok[2]), strcmp(tok[3], "true") == 0);

    // 주어진 범위(start, cnt)의 비트를 일괄적으로 true 또는 false로 설정
    else if (strcmp(sub, "set_multiple") == 0)
        bitmap_set_multiple(bm, (size_t)atoi(tok[2]), (size_t)atoi(tok[3]),strcmp(tok[4], "true") == 0);

    // 비트맵의 전체 크기(비트 수)를 출력
    else if (strcmp(sub, "size") == 0)
        printf("%lu\n", bitmap_size(bm));

    // 지정 위치의 비트 값을 읽어서 true/false 출력
    else if (strcmp(sub, "test") == 0)
        printf("%s\n", bitmap_test(bm, (size_t)atoi(tok[2])) ? "true" : "false");
}

/* 메인 함수  */
// stdin에서 한 줄씩 읽어 명령어를 토큰으로 분리하고 적절한 핸들러 호출
int main(void)
{
    char  buf[BUF_SZ];
    char *tok[TOK_MAX];
    int   tc;

    // stdin에서 한 줄씩 읽는 메인 루프
    while (fgets(buf, sizeof(buf), stdin) != NULL) 
    {

        // strtok으로 공백/탭/개행 기준 토큰 분리, 첫 토큰은 buf로 이후는 NULL로 호출
        for (tc = 0; tc < TOK_MAX; tc++) {
            tok[tc] = strtok(tc == 0 ? buf : NULL, " \t\n");
            if (tok[tc] == NULL) break;
        }
        if (tc == 0) continue; // 빈 줄 무시

        const char *cmd = tok[0];

        if (cmd[0] == 'q') break; // quit

        // tok[0]을 기준으로 명령어 파싱 후 명령어에 따라 핸들러 함수로 분기
        // 첫 글자로 빠르게 분류하고, 각 핸들러에는 prefix를 제거한 접미사만 전달
        else if (cmd[0] == 'c')                  cmd_create(tc, tok);           // create
        else if (cmd[0] == 'd' && cmd[1] == 'e') cmd_delete(tc, tok);           // delete
        else if (cmd[0] == 'd' && cmd[1] == 'u') cmd_dumpdata(tc, tok);         // dumpdata
        else if (cmd[0] == 'l')                  cmd_list(cmd + 5, tc, tok);    // list_* → 접미사만 전달
        else if (cmd[0] == 'h')                  cmd_hash(cmd + 5, tc, tok);    // hash_* → 접미사만 전달
        else if (cmd[0] == 'b')                  cmd_bitmap(cmd + 7, tc, tok);  // bitmap_* → 접미사만 전달
    }

    return 0;
}
