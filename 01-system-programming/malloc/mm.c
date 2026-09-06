
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <unistd.h>
#include <string.h>

#include "mm.h"
#include "memlib.h"

team_t team = {
    "20200025",                 
    "Kim Woohyun",              
    "sogang910@naver.com",      
};

// 상수 정의
#define WORD          4     //워드 = 헤더/풋터 한 칸 크기(바이트). 32비트라 4 
#define DWORD         8     // 더블워드 = 정렬 단위(payload는 8의 배수 주소) 
#define MINBLK        16    // 최소 블록(헤더4 + pred4 + succ4 + 풋터4) 
#define CHUNK         256   // 일반 요청이 힙을 늘릴 때의 기본 확장 단위 
#define SPLIT_LIMIT   480   // 분할 잔여가 이 값 이하면 tail, 초과면 front 배치 
#define NCLASS        12    // 분리 가용 리스트의 크기 클래스 개수 
#define MED_LO        96    // 중간 크기 front-split 구간 하한 
#define MED_HI        768   // 중간 크기 front-split 구간 상한 
#define SMALL_LIMIT   96    // 이 값 이하 요청은 소형으로 분류
#define ARENA_THRESH  32    // 동시 생존 소형 수가 이 이상이면 아레나로 분리 
#define ARENA_MAXSZ   48    // 아레나 대상은 가장 작은 블록(<=48B)만 
#define ARENA_CHUNK   704   // 아레나가 힙을 늘릴 때의 확장 단위 

//포인터/헤더 조작 매크로 
#define MAX(a, b)      ((a) > (b) ? (a) : (b))           
#define ALIGN8(s)      (((s) + 7) & ~0x7)     //8의 배수로 올림 

// 블록 크기와 플래그(prev:0/2, alloc:0/1)를 한 워드로 묶는다
#define PACK(size, prev, alloc)  ((size) | (prev) | (alloc))

#define READ(p)        (*(unsigned int *)(p))            // 주소 p에서 한 워드 읽기 
#define WRITE(p, v)    (*(unsigned int *)(p) = (unsigned int)(v)) //주소 p에 한 워드 쓰기 

#define SIZE_OF(p)     (READ(p) & ~0x7)   // 헤더에서 블록 크기만 추출 
#define ALLOC_OF(p)    (READ(p) & 0x1)    // 현재 블록 할당 여부(0x1) 
#define PREV_OF(p)     (READ(p) & 0x2)    // 직전 블록 할당 여부(0x2) 
#define POOL_OF(p)     (READ(p) & 0x4)    // 아레나 소속 표식(0x4) 

#define HEAD(bp)       ((char *)(bp) - WORD)                          // payload ->헤더 
#define FOOT(bp)       ((char *)(bp) + SIZE_OF(HEAD(bp)) - DWORD)     // payload ->풋터 
#define NEXT(bp)       ((char *)(bp) + SIZE_OF(HEAD(bp)))             // 다음 블록 payload 
#define PREV(bp)       ((char *)(bp) - SIZE_OF((char *)(bp) - DWORD)) //이전 블록 payload 

// 가용 블록의 pred/succ 링크는 payload 자리(앞 두 워드)에 저장 
#define PRED(bp)       (*(char **)(bp))                  //리스트상 이전 블록 
#define SUCC(bp)       (*(char **)((char *)(bp) + WORD)) //리스트상 다음 블록 

//힙 내부 루트 배열의 i번째 셀(클래스 i의 리스트 헤드) 
#define ROOT(i)        (*(char **)(class_table + (i) * WORD))

// 전역 스칼라
static char *heap_base;        // 프롤로그 블록을 가리키는 힙 시작 기준점
static char *class_table;      // 힙 내부에 둔 루트 배열의 시작 주소 
static long  live_small_cnt;   // 현재 살아있는 소형 블록 개수(아레나 판단용) 


static int   size_class(size_t size);
static void  list_push(char *bp);
static void  list_unlink(char *bp);
static char *search_fit(size_t req, int scope);
static char *put_block(char *bp, size_t req);
static void *coalesce_block(char *bp);
static void *grow_heap(size_t bytes, size_t tag);


 //크기 클래스 및 가용 리스트 조작
 

// 블록 크기를 2의 거듭제곱 경계 기준 클래스 인덱스(0~NCLASS-1)로 매핑
static int size_class(size_t size)
{
    int ci = 0;                                  //클래스 인덱스 누적 
    if (size <= 16) return 0;                    //16B 이하는 0번 클래스로 고정 
    size = (size - 1) >> 4;                       // 16으로 나눈 뒤(>>4) 경계 보정
    while (size && ci < NCLASS - 1) {            // 남은 비트가 있고 마지막 클래스 전이면 
        size >>= 1;                               // 한 단계씩 더 큰 클래스로 
        ci++;
    }
    return ci;                                    //결정된 클래스 반환 
}

// 가용 블록을 해당 클래스 리스트의 머리에 삽입(LIFO)
static void list_push(char *bp)
{
    int ci = size_class(SIZE_OF(HEAD(bp)));       // 이 블록이 속할 클래스 계산
    char *first = ROOT(ci);                       // 현재 그 클래스의 머리 블록
    PRED(bp) = NULL;                              // 새 블록을 헤드로 -> 이전 없음
    SUCC(bp) = first;                             // 새 블록의 다음 = 기존 헤드
    if (first != NULL) PRED(first) = bp;          // 기존 헤드가 있으면 그 이전을 새 블록으로
    ROOT(ci) = bp;                                // 루트가 새 블록을 가리키게 갱신
}

// 가용 블록을 리스트에서 분리
static void list_unlink(char *bp)
{
    char *pv = PRED(bp);                          // 리스트상 이전 블록
    char *nx = SUCC(bp);                          // 리스트상 다음 블록
    if (pv != NULL) SUCC(pv) = nx;                // 이전이 있으면 이전의 다음을 nx로 연결
    else ROOT(size_class(SIZE_OF(HEAD(bp)))) = nx;// 이전이 없으면 루트를 nx로
    if (nx != NULL) PRED(nx) = pv;               // 다음이 있으면 다음의 이전을 pv로 연결
}


/* 탐색 및 배치 */


// 전역 best-fit. scope 0=일반, 1=비아레나 전용, 2=아레나 전용.
// 정확히 맞는 블록을 만나면 즉시 반환한다.
static char *search_fit(size_t req, int scope)
{
    for (int ci = size_class(req); ci < NCLASS; ci++) {   // 요청 크기 클래스부터 위로 스캔
        char  *fit = NULL;                                // 지금까지 찾은 최적합 블록
        size_t fitsz = (size_t)-1;                        // 그 블록의 크기(초기 최대)
        for (char *bp = ROOT(ci); bp != NULL; bp = SUCC(bp)) { // 클래스 리스트 순회
            size_t tag = POOL_OF(HEAD(bp));               // 이 블록의 아레나 표식
            if (scope == 1 && tag)  continue;             // 비아레나 전용인데 아레나 블록이면 건너뜀
            if (scope == 2 && !tag) continue;             // 아레나 전용인데 일반 블록이면 건너뜀
            size_t bs = SIZE_OF(HEAD(bp));                // 후보 블록 크기
            if (bs == req) return bp;                     // 정확히 맞으면 즉시 반환(최적)
            if (bs > req && (bs < fitsz || (bs == fitsz && bp < fit))) {
                fit = bp;                                 // 더 작은(또는 동률+더 낮은 주소) 적합 블록 갱신
                fitsz = bs;
            }
        }
        if (fit != NULL) return fit;                      
    }
    return NULL;                                          
}

/*가용 블록 bp 에 req 만큼 배치. 충분히 남으면 분할하되,
중간 크기거나 잔여가 크면 front-split, 그 외에는 tail-split */
static char *put_block(char *bp, size_t req)
{
    size_t cap  = SIZE_OF(HEAD(bp));             // 이 가용 블록의 전체 용량
    size_t pbit = PREV_OF(HEAD(bp));             // 직전 블록 할당 비트
    size_t tag  = POOL_OF(HEAD(bp));             // 아레나 표식
    list_unlink(bp);                             // 배치 전 가용 리스트에서 제거

    size_t slack = cap - req;                     // 요청을 빼고 남는 양

    // 남는 조각이 최소 블록보다 작으면 분할하지 않고 통째로 할당
    if (slack < MINBLK) {
        WRITE(HEAD(bp), PACK(cap, pbit, 1) | tag); // 전체 크기로 할당 표시
        char *nx = NEXT(bp);                       // 다음 블록에게
        WRITE(HEAD(nx), READ(HEAD(nx)) | 0x2);     // 앞이 할당됨 통보(prev 비트 set)
        return bp;
    }

    // 분할 방향을 결정, 중간 크기이거나 잔여가 크면 front, 아니면 tail
    int front = (req >= MED_LO && req <= MED_HI) || (slack > SPLIT_LIMIT);

    if (front) {
        // front 배치: 앞(bp)에 할당, 뒤(rest)에 가용 잔여를 둔다
        WRITE(HEAD(bp), PACK(req, pbit, 1) | tag);     // 앞쪽을 요청 크기로 할당
        char *rest = NEXT(bp);                         // 잔여 블록 시작
        WRITE(HEAD(rest), PACK(slack, 2, 0) | tag);    // 잔여 헤더(앞이 할당이므로 prev=2)
        WRITE(FOOT(rest), PACK(slack, 2, 0) | tag);    // 잔여 풋터
        char *behind = NEXT(rest);                     // 잔여 다음 블록
        WRITE(HEAD(behind), READ(HEAD(behind)) & ~0x2);// 앞이 가용 통보(prev 비트 clear)
        list_push(rest);                               // 잔여를 가용 리스트에 삽입
        return bp;                                      
    } else {
        // tail 배치: 앞(bp)에 가용 잔여, 뒤(abp)에 할당을 둔다
        WRITE(HEAD(bp), PACK(slack, pbit, 0) | tag);   // 앞쪽을 가용 잔여로
        WRITE(FOOT(bp), PACK(slack, pbit, 0) | tag);   // 가용 풋터
        char *abp = NEXT(bp);                          // 뒤쪽 할당 블록 시작
        WRITE(HEAD(abp), PACK(req, 0, 1) | tag);       // 할당 표시(앞이 가용이므로 prev=0)
        char *behind = NEXT(abp);                      // 그 다음 블록
        WRITE(HEAD(behind), READ(HEAD(behind)) | 0x2); // 앞이 할당됨 통보
        list_push(bp);                                 // 앞쪽 잔여를 가용 리스트에 삽입
        return abp;                                     
    }
}


/* 병합 / 힙 확장 */

// 인접 가용 블록과 즉시 병합. 단, pool 표식이 같은 이웃끼리만 합친다.
static void *coalesce_block(char *bp)
{
    size_t tag = POOL_OF(HEAD(bp));               // 현재 블록의 아레나 표식
    char  *nx  = NEXT(bp);                         // 주소상 다음 블록
    char  *pv  = PREV(bp);                         // 주소상 이전 블록(prev가 가용일 때만 유효)
    size_t prev_alloc = PREV_OF(HEAD(bp));         // 직전 블록 할당 여부(0 또는 2)
    size_t next_alloc = ALLOC_OF(HEAD(nx));        // 다음 블록 할당 여부
    size_t size = SIZE_OF(HEAD(bp));               // 현재 블록 크기(병합하며 누적)

    int merge_next = (!next_alloc) && (POOL_OF(HEAD(nx)) == tag); // 다음과 합칠 수 있나
    int merge_prev = (!prev_alloc) && (POOL_OF(HEAD(pv)) == tag); // 이전과 합칠 수 있나

    if (!merge_prev && !merge_next) {
        // 양쪽 다 할당/다른표식 -> 합칠 이웃 없음
    }
    else if (!merge_prev && merge_next) {               // 다음 블록과 병합
        list_unlink(nx);                                // 다음 블록을 리스트에서 제거
        size += SIZE_OF(HEAD(nx));                       // 크기 합산
        WRITE(HEAD(bp), PACK(size, 2, 0) | tag);        // 합친 헤더(앞은 할당이라 prev=2)
        WRITE(FOOT(bp), PACK(size, 2, 0) | tag);        // 합친 풋터
    }
    else if (merge_prev && !merge_next) {               // 이전 블록과 병합
        size_t ppbit = PREV_OF(HEAD(pv));               // 이전 블록의 prev 비트 보존
        list_unlink(pv);                                // 이전 블록을 리스트에서 제거
        size += SIZE_OF(HEAD(pv));                       // 크기 합산
        WRITE(HEAD(pv), PACK(size, ppbit, 0) | tag);    // 이전 블록 위치에 합친 헤더
        WRITE(FOOT(pv), PACK(size, ppbit, 0) | tag);    // 합친 풋터
        bp = pv;                                        // 병합 결과의 시작은 이전 블록
    }
    else {                                              // 앞뒤 양쪽과 병합
        size_t ppbit = PREV_OF(HEAD(pv));               // 이전 블록 prev 비트 보존
        list_unlink(pv);                                // 이전 제거
        list_unlink(nx);                                // 다음 제거
        size += SIZE_OF(HEAD(pv)) + SIZE_OF(HEAD(nx));  // 세 블록 크기 합산
        WRITE(HEAD(pv), PACK(size, ppbit, 0) | tag);    // 합친 헤더
        WRITE(FOOT(pv), PACK(size, ppbit, 0) | tag);    // 합친 풋터
        bp = pv;                                        // 결과 시작은 이전 블록
    }

    list_push(bp);                                      // 병합 결과를 가용 리스트에 삽입
    return bp;
}

// 힙을 bytes(정렬 보정) 만큼 늘려 새 가용 블록을 만들고 병합
static void *grow_heap(size_t bytes, size_t tag)
{
    size_t size = ALIGN8(bytes);                  // 8의 배수로 정렬
    if (size < MINBLK) size = MINBLK;             // 최소 블록 크기 보장

    char *bp = mem_sbrk(size);                    // 힙을 size만큼 확장
    if ((long)bp == -1) return NULL;              // 실패 시 NULL

    size_t prev_alloc = PREV_OF(HEAD(bp));        // 옛 에필로그의 prev 비트 승계
    WRITE(HEAD(bp), PACK(size, prev_alloc, 0) | tag); // 새 가용 블록 헤더
    WRITE(FOOT(bp), PACK(size, prev_alloc, 0) | tag); // 새 가용 블록 풋터
    WRITE(HEAD(NEXT(bp)), PACK(0, 0, 1));             // 새 에필로그 헤더(크기0+할당)

    return coalesce_block(bp);                    // 직전 블록과 병합 후 반환
}


/* 인터페이스 (mm_init / mm_malloc / mm_free / mm_realloc)*/


// 힙 초기 구조(루트 배열/프롤로그/에필로그)를 만들고 전역을 초기화
int mm_init(void)
{
    size_t setup_sz = NCLASS * WORD + 4 * WORD;   // 루트배열 + 패딩 + 프롤로그(2) + 에필로그
    char *base = mem_sbrk(setup_sz);              // 초기 영역 확보
    if (base == (void *)-1) return -1;            // 실패 시 -1

    class_table    = base;                         // 루트 배열의 시작을 기록
    live_small_cnt = 0;                            // 생존 소형 수 초기화
    for (int i = 0; i < NCLASS; i++)              // 모든 클래스 머리를
        ROOT(i) = NULL;                            // 빈 리스트로 초기화

    char *p = base + NCLASS * WORD;                // 루트 배열 다음 위치
    WRITE(p,            0);                        // 정렬 패딩
    WRITE(p + WORD,     PACK(DWORD, 2, 1));        // 프롤로그 헤더(할당)
    WRITE(p + 2 * WORD, PACK(DWORD, 2, 1));        // 프롤로그 풋터
    WRITE(p + 3 * WORD, PACK(0, 2, 1));            // 에필로그 헤더(크기0+할당)
    heap_base = p + 2 * WORD;                      // 프롤로그 payload를 기준점으로

    if (grow_heap(64u, 0) == NULL) return -1;     
    return 0;                                       
}

// size 바이트 이상을 담는 블록을 할당해 8바이트 정렬 포인터를 반환
void *mm_malloc(size_t size)
{
    if (size == 0) return NULL;                    

    size_t req = (size <= DWORD) ? MINBLK : ALIGN8(size + WORD); // 헤더+정렬 보정한 실제 블록 크기
    if (req < MINBLK) req = MINBLK;               // 최소 블록 보장

    int small    = (req <= ARENA_MAXSZ);          // 아레나 대상이 될 만큼 작은지 체크
    int to_arena = small && (live_small_cnt >= ARENA_THRESH); // 작고 + 생존 소형이 많으면 아레나
    if (small) live_small_cnt++;                   // 소형이면 생존 수 증가

    int scope = to_arena ? 2 : (req <= SMALL_LIMIT ? 0 : 1); // 탐색 범위는 아레나/일반/비아레나
    char *bp = search_fit(req, scope);            // 적합 가용 블록 탐색
    if (bp != NULL)                                // 찾으면
        return put_block(bp, req);                // 그 자리에 배치 후 반환

    size_t tag  = to_arena ? 0x4 : 0;             // 새로 확장할 때 붙일 표식
    size_t grow = to_arena ? MAX(req, ARENA_CHUNK) // 확장 크기 결정
                           : ((req <= 128) ? MAX(req, 512u) : MAX(req, CHUNK)); // 소형은 큰 풀, 그 외 기본
    if ((bp = grow_heap(grow, tag)) == NULL)      // 힙 확장(실패 시)
        return NULL;
    return put_block(bp, req);                    // 새 블록에 배치 후 반환
}

// 블록을 해제하고 인접 가용 블록과 즉시 병합
void mm_free(void *bp)
{
    if (bp == NULL) return;                        

    size_t size = SIZE_OF(HEAD(bp));               // 블록 크기
    size_t pbit = PREV_OF(HEAD(bp));               // 직전 할당 비트 보존
    size_t tag  = POOL_OF(HEAD(bp));               // 아레나 표식 보존
    if (size <= ARENA_MAXSZ && live_small_cnt > 0) live_small_cnt--; // 소형이면 생존 수 감소

    WRITE(HEAD(bp), PACK(size, pbit, 0) | tag);    // 헤더를 가용으로
    WRITE(FOOT(bp), PACK(size, pbit, 0) | tag);    // 풋터를 가용으로(가용 블록은 풋터 둠)
    char *nx = NEXT(bp);                           // 다음 블록에게
    WRITE(HEAD(nx), READ(HEAD(nx)) & ~0x2);        // 앞이 가용 통보(prev 비트 clear)

    coalesce_block(bp);                            // 인접 병합 후 리스트 삽입
}

// 기존 블록 ptr 을 size 로 재조정(축소/제자리확장/재배치)
void *mm_realloc(void *ptr, size_t size)
{
    if (ptr == NULL)  return mm_malloc(size);      // ptr이 NULL이면 malloc과 동일
    if (size == 0)  { mm_free(ptr); return NULL; } // size 0이면 free와 동일

    size_t req = (size <= DWORD) ? MINBLK : ALIGN8(size + WORD); // 보정한 새 블록 크기
    if (req < MINBLK) req = MINBLK;

    size_t old = SIZE_OF(HEAD(ptr));               // 기존 블록 크기

    // 1) 같거나 작으면 제자리 축소
    if (req <= old) {
        if (old - req >= MINBLK) {                 // 잘라낸 뒤 남는 게 최소 블록 이상이면
            size_t pbit = PREV_OF(HEAD(ptr));      // 직전 할당 비트 보존
            WRITE(HEAD(ptr), PACK(req, pbit, 1));  // 앞부분을 줄인 크기로 할당
            char *rest = NEXT(ptr);                // 잘라낸 뒤쪽
            WRITE(HEAD(rest), PACK(old - req, 2, 0)); // 가용 잔여 헤더
            WRITE(FOOT(rest), PACK(old - req, 2, 0)); // 가용 잔여 풋터
            char *behind = NEXT(rest);             // 그 다음 블록
            WRITE(HEAD(behind), READ(HEAD(behind)) & ~0x2); //앞이 가용 통보
            coalesce_block(rest);                  // 잔여를 병합/삽입
        }
        return ptr;                               
    }

    // 2) 다음 블록 / 힙 끝을 이용한 제자리 확장
    char  *nx   = NEXT(ptr);                       // 다음 블록
    size_t pbit = PREV_OF(HEAD(ptr));              // 직전 할당 비트
    size_t nsz  = SIZE_OF(HEAD(nx));               // 다음 블록 크기
    size_t nal  = ALLOC_OF(HEAD(nx));              // 다음 블록 할당 여부

    if (nsz == 0) {                       // 다음이 에필로그(힙 끝)면
        size_t deficit = req - old;       // 부족한 만큼만
        if (grow_heap(deficit, 0) == NULL) return NULL; // 힙을 늘려서
        nx  = NEXT(ptr);                  // 새 가용 블록을 다시 가리킴
        nsz = SIZE_OF(HEAD(nx));
        nal = ALLOC_OF(HEAD(nx));
    }

    if (!nal && old + nsz >= req) {                // 다음이 가용이고 합치면 충분하면
        list_unlink(nx);                           // 다음 블록을 리스트에서 빼고
        size_t merged = old + nsz;                 // 합친 총 크기
        if (merged - req >= MINBLK) {              // 합친 뒤에도 분할할 여유가 있으면
            WRITE(HEAD(ptr), PACK(req, pbit, 1));  // 앞을 요청 크기로 할당
            char *rest = NEXT(ptr);                // 남는 잔여
            WRITE(HEAD(rest), PACK(merged - req, 2, 0)); // 가용 잔여 헤더
            WRITE(FOOT(rest), PACK(merged - req, 2, 0)); // 가용 잔여 풋터
            list_push(rest);                       // 잔여 삽입
        } else {                                   // 여유가 적으면 통째로 사용
            WRITE(HEAD(ptr), PACK(merged, pbit, 1)); // 합친 전체를 할당
            char *nn = NEXT(ptr);                  // 그 다음 블록에
            WRITE(HEAD(nn), READ(HEAD(nn)) | 0x2); // 앞이 할당됨 통보
        }
        return ptr;                                // 제자리 확장 성공
    }

    // 3) 마지막 수단: 새로 할당해 내용 복사 후 옛 블록 해제
    char *np = mm_malloc(size);                    // 새 블록 확보
    if (np == NULL) return NULL;
    size_t keep = old - WORD;                      // 옛 블록의 payload 가용 바이트
    if (size < keep) keep = size;                  // 요청보다 많이 복사하지 않게
    memcpy(np, ptr, keep);                         // 내용 복사
    mm_free(ptr);                                  // 옛 블록 해제
    return np;                                      // 새 포인터 반환
}


//  힙 일관성 검사기 디버깅용
int mm_check(void)
{
    char *bp;
    // 모든 블록을 주소 순으로 순회하며 불변식 점검
    for (bp = NEXT(heap_base); SIZE_OF(HEAD(bp)) > 0; bp = NEXT(bp)) {
        if (((size_t)bp & 0x7) != 0) {             // 8바이트 정렬 위반체크
            printf("check: %p not 8-byte aligned\n", (void *)bp);
            return 0;
        }
        char *nx = NEXT(bp);
        int abit = ALLOC_OF(HEAD(bp)) ? 2 : 0;     // 내 할당 상태를
        if ((int)PREV_OF(HEAD(nx)) != abit) {      // 다음 블록의 prev 비트와 비교
            printf("check: prev-alloc bit mismatch at %p\n", (void *)nx);
            return 0;
        }
        if (!ALLOC_OF(HEAD(bp)) && !ALLOC_OF(HEAD(nx))) { // 연속 가용 블록이 안 합쳐졌는지 확인
            printf("check: contiguous free blocks not coalesced at %p\n", (void *)bp);
            return 0;
        }
    }
    
    // 모든 가용 리스트 점검
    for (int i = 0; i < NCLASS; i++) {
        for (bp = ROOT(i); bp != NULL; bp = SUCC(bp)) {
            if (ALLOC_OF(HEAD(bp))) {              // 리스트에 할당 블록이 섞였는지 확인
                printf("check: allocated block in free list (class %d)\n", i);
                return 0;
            }
            if (size_class(SIZE_OF(HEAD(bp))) != i) { // 엉뚱한 클래스에 들어갔는지 확인
                printf("check: block in wrong size class\n");
                return 0;
            }
        }
    }
    return 1;                                       
}