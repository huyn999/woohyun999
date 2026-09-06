#ifndef __MYLIB_HASH_H
#define __MYLIB_HASH_H

/* Hash table.

  This is a standard hash table with chaining.  To locate an
   element in the table, we compute a hash function over the
   element's data and use that as an index into an array of
   doubly linked lists, then linearly search the list.

   The chain lists do not use dynamic allocation.  Instead, each
   structure that can potentially be in a hash must embed a
   struct hash_elem member.  All of the hash functions operate on
   these `struct hash_elem's.  The hash_entry macro allows
   conversion from a struct hash_elem back to a structure object
   that contains it.  This is the same technique used in the
   linked list implementation.  Refer to ./list.h for a
   detailed explanation. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include "list.h"

/* Hash element. */
struct hash_elem 
  {
    struct list_elem list_elem;
  };

// hash_item: 해시 테이블에 정수를 저장하기 위한 래퍼 구조체 이전 리스트와 유사
typedef struct 
{
    int value;             // 실제 정수 데이터
    struct hash_elem elem; // 해시 테이블 연결용 내부 노드
    
} hash_item;

/* Computes and returns the hash value for hash element E, given
   auxiliary data AUX. */
typedef unsigned hash_hash_func (const struct hash_elem *e, void *aux);

// hash_elem 포인터로부터 감싸는 구조체의 주소를 구하는 매크로.
// list_entry와 동일한 방식으로 list_elem의 next 멤버 오프셋을 이용한다.
#define hash_entry(HASH_ELEM, STRUCT, MEMBER)                          \
  ((STRUCT *) ((uint8_t *) &(HASH_ELEM)->list_elem.next               \
               - offsetof (STRUCT, MEMBER.list_elem.next)))


/* Compares the value of two hash elements A and B, given
   auxiliary data AUX.  Returns true if A is less than B, or
   false if A is greater than or equal to B. */
typedef bool hash_less_func (const struct hash_elem *a,
                             const struct hash_elem *b,
                             void *aux);

/* Performs some operation on hash element E, given auxiliary
   data AUX. */
typedef void hash_action_func (struct hash_elem *e, void *aux);

/* Hash table. */
struct hash 
  {
    size_t elem_cnt;            /* Number of elements in table. */
    size_t bucket_cnt;          /* Number of buckets, a power of 2. */
    struct list *buckets;       /* Array of `bucket_cnt' lists. */ //리스트 배열 버캣
    hash_hash_func *hash;       /* Hash function. */
    hash_less_func *less;       /* Comparison function. */
    void *aux;                  /* Auxiliary data for `hash' and `less'. */
  };


/* A hash table iterator. */
struct hash_iterator 
  {
    struct hash *hash;          /* The hash table. */
    struct list *bucket;        /* Current bucket. */
    struct hash_elem *elem;     /* Current hash element in current bucket. */
  };

/* Basic life cycle. */
bool hash_init (struct hash *, hash_hash_func *, hash_less_func *, void *aux);
void hash_clear (struct hash *, hash_action_func *);
void hash_destroy (struct hash *, hash_action_func *);

/* Search, insertion, deletion. */
struct hash_elem *hash_insert (struct hash *, struct hash_elem *);
struct hash_elem *hash_replace (struct hash *, struct hash_elem *);
struct hash_elem *hash_find (struct hash *, struct hash_elem *);
struct hash_elem *hash_delete (struct hash *, struct hash_elem *);

/* Iteration. */
void hash_apply (struct hash *, hash_action_func *);
void hash_first (struct hash_iterator *, struct hash *);
struct hash_elem *hash_next (struct hash_iterator *);
struct hash_elem *hash_cur (struct hash_iterator *);

/* Information. */
size_t hash_size (struct hash *);
bool hash_empty (struct hash *);

/* Sample hash functions. */
unsigned hash_bytes (const void *, size_t);
unsigned hash_string (const char *);
unsigned hash_int (int);
unsigned hash_int_2 (int);//새로 구현


// 비교 함수: a의 value < b의 value이면 true 반환
bool hash_int_less(const struct hash_elem *a, const struct hash_elem *b, void *aux);

// 해시 함수: 원소의 value를 해시값(unsigned 정수)으로 변환
unsigned hash_int_func(const struct hash_elem *e, void *aux);

// 출력 함수: 원소의 value를 printf로 출력
void print_hash_elem(struct hash_elem *e, void *aux);

// 소멸 함수: 원소를 감싸는 int_hash_elem 구조체를 free()
void free_hash_elem(struct hash_elem *e, void *aux);

// 변환 함수: 원소의 value를 제곱으로 변경 (value = value * value)
void apply_square(struct hash_elem *e, void *aux);

// 변환 함수: 원소의 value를 세제곱으로 변경 (value = value * value * value)
void apply_triple(struct hash_elem *e, void *aux);

#endif /* hash.h */
