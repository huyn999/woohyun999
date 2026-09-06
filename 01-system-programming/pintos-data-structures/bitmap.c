#include "bitmap.h"
#include <assert.h>	
#include "limits.h"	
#include "round.h"	
#include <stdio.h>
#include <stdlib.h>	
#include "hex_dump.h"	
#include <string.h>
#define ASSERT(CONDITION) assert(CONDITION)	

/* Element type.

   This must be an unsigned integer type at least as wide as int.

   Each bit represents one bit in the bitmap.
   If bit 0 in an element represents bit K in the bitmap,
   then bit 1 in the element represents bit K+1 in the bitmap,
   and so on. */
typedef unsigned long elem_type;

/* Number of bits in an element. */
#define ELEM_BITS (sizeof (elem_type) * CHAR_BIT)

/* From the outside, a bitmap is an array of bits.  From the
   inside, it's an array of elem_type (defined above) that
   simulates an array of bits. */
struct bitmap
  {
    size_t bit_cnt;     // Number of bits. 가지고 있는 비트수
    elem_type *bits;    // Elements that represent bits. 실제 elem_type의 비트 배열
  };

/* Returns the index of the element that contains the bit
   numbered BIT_IDX. */
static inline size_t
elem_idx (size_t bit_idx) 
{
  return bit_idx / ELEM_BITS;// 비트 인덱스를 포함하고 있는 엘리먼트 인덱스를 반환 
}

/* Returns an elem_type where only the bit corresponding to
   BIT_IDX is turned on. */
static inline elem_type
bit_mask (size_t bit_idx) 
{
  return (elem_type) 1 << (bit_idx % ELEM_BITS);
}

/* Returns the number of elements required for BIT_CNT bits. */
static inline size_t
elem_cnt (size_t bit_cnt)
{
  return DIV_ROUND_UP (bit_cnt, ELEM_BITS);
}

/* Returns the number of bytes required for BIT_CNT bits. */
static inline size_t
byte_cnt (size_t bit_cnt)// 총 비트 수 → 필요한 바이트 수
{
  return sizeof (elem_type) * elem_cnt (bit_cnt);
}

/* Returns a bit mask in which the bits actually used in the last
   element of B's bits are set to 1 and the rest are set to 0. */
static inline elem_type
last_mask (const struct bitmap *b) 
{
  int last_bits = b->bit_cnt % ELEM_BITS;
  return last_bits ? ((elem_type) 1 << last_bits) - 1 : (elem_type) -1;
}

/* Creation and destruction. */

/* Initializes B to be a bitmap of BIT_CNT bits
   and sets all of its bits to false.
   Returns true if success, false if memory allocation
   failed. */
struct bitmap *
bitmap_create (size_t bit_cnt) 
{
  struct bitmap *b = malloc (sizeof *b);// 비트맵 구조체 동적할당
  if (b != NULL)
    {
      b->bit_cnt = bit_cnt;// 비트수 
      b->bits = malloc (byte_cnt (bit_cnt));//elemtype의 배열 동적할당
      if (b->bits != NULL || bit_cnt == 0)
        {
          bitmap_set_all (b, false);//모든 비트를 초기에 false로 설정
          return b;
        }
      free (b);// bitmap 구조체 동적 해제
    }
  return NULL;
}

/* Creates and returns a bitmap with BIT_CNT bits in the
   BLOCK_SIZE bytes of storage preallocated at BLOCK.
   BLOCK_SIZE must be at least bitmap_needed_bytes(BIT_CNT). */
struct bitmap * // 미리 할당된 메모리 블록 안에 비트맵을 생성
bitmap_create_in_buf (size_t bit_cnt, void *block, size_t block_size )
	// Remove KERNEL MACRO 'UNUSED')
{
  struct bitmap *b = block;
  
  ASSERT (block_size >= bitmap_buf_size (bit_cnt));

  b->bit_cnt = bit_cnt;
  b->bits = (elem_type *) (b + 1);
  bitmap_set_all (b, false);
  return b;
}

/* Returns the number of bytes required to accomodate a bitmap
   with BIT_CNT bits (for use with bitmap_create_in_buf()). */
size_t
bitmap_buf_size (size_t bit_cnt) 
{
  return sizeof (struct bitmap) + byte_cnt (bit_cnt);
}

/* Destroys bitmap B, freeing its storage.
   Not for use on bitmaps created by
   bitmap_create_preallocated(). */
void
bitmap_destroy (struct bitmap *b) 
{
  if (b != NULL) 
    {
      free (b->bits);// bits 배열 동적 해제
      free (b);// bitmap 구조체 동적 해제
    }
}

/* Bitmap size. */

/* Returns the number of bits in B. */
size_t
bitmap_size (const struct bitmap *b)
{
  return b->bit_cnt;// 비트 개수 반환
}

/* Setting and testing single bits. */

/* Atomically sets the bit numbered IDX in B to VALUE. */
void
bitmap_set (struct bitmap *b, size_t idx, bool value) 
{ // idx번째 비트를 value(true/false)로 설정
  ASSERT (b != NULL);
  ASSERT (idx < b->bit_cnt);
  if (value)
    bitmap_mark (b, idx);
  else
    bitmap_reset (b, idx);
}

/* Atomically sets the bit numbered BIT_IDX in B to true. */
void
bitmap_mark (struct bitmap *b, size_t bit_idx) 
{
  size_t idx = elem_idx (bit_idx);
  elem_type mask = bit_mask (bit_idx);

  /* This is equivalent to `b->bits[idx] |= mask' except that it
     is guaranteed to be atomic on a uniprocessor machine.  See
     the description of the OR instruction in [IA32-v2b]. */
  asm ("orl %k1, %k0" : "=m" (b->bits[idx]) : "r" (mask) : "cc");
}

/* Atomically sets the bit numbered BIT_IDX in B to false. */
void
bitmap_reset (struct bitmap *b, size_t bit_idx) 
{ // bit_idx번째 비트를 0으로 리셋 
  size_t idx = elem_idx (bit_idx); 
  elem_type mask = bit_mask (bit_idx);

  /* This is equivalent to `b->bits[idx] &= ~mask' except that it
     is guaranteed to be atomic on a uniprocessor machine.  See
     the description of the AND instruction in [IA32-v2a]. */
  asm ("andl %k1, %k0" : "=m" (b->bits[idx]) : "r" (~mask) : "cc");
}

/* Atomically toggles the bit numbered IDX in B;
   that is, if it is true, makes it false,
   and if it is false, makes it true. */
void
bitmap_flip (struct bitmap *b, size_t bit_idx) 
{
  size_t idx = elem_idx (bit_idx);
  elem_type mask = bit_mask (bit_idx);

  /* This is equivalent to `b->bits[idx] ^= mask' except that it
     is guaranteed to be atomic on a uniprocessor machine.  See
     the description of the XOR instruction in [IA32-v2b]. */
  asm ("xorl %k1, %k0" : "=m" (b->bits[idx]) : "r" (mask) : "cc");
}

/* bitmap_expand: 기존 비트맵을 더 큰 크기(size)로 확장
   새 비트맵을 할당하고, 기존 비트 데이터를 바이트 단위로 복사한 뒤,
   새 비트맵의 포인터를 반환
   size가 기존 크기 이하이면 원래 비트맵을 그대로 반환
   호출자는 반환값이 원래와 다르면 기존 비트맵을 직접 해제함 */
struct bitmap *
bitmap_expand (struct bitmap *bm, int size)
{
  size_t old_sz = bitmap_size (bm); // 기존 비트맵의 비트 수

  // 요청 크기가 기존 크기 이하이면 확장할 필요 없음
  if (size <= (int) old_sz)
    return bm; //원래 비트맵 그대로 반환

  // 새 크기의 비트맵을 생성 (모든 비트가 0으로 초기화됨)
  struct bitmap *nb = bitmap_create ((size_t) size);
  if (nb == NULL)
    return NULL; //메모리 할당 실패시 null 반환

  /* 기존 비트 데이터를 새 비트맵으로 바이트 단위 복사.
     byte_cnt()는 old_sz 비트를 저장하는 데 필요한 바이트 수를 계산
     elem_type 배열의 내용을 memcpy로 한번에 복사*/
  memcpy (nb->bits, bm->bits, byte_cnt (old_sz));

  return nb; // 확장된 새 비트맵 반환
}

/* Returns the value of the bit numbered IDX in B. */
bool
bitmap_test (const struct bitmap *b, size_t idx) 
{
  ASSERT (b != NULL);
  ASSERT (idx < b->bit_cnt);
  return (b->bits[elem_idx (idx)] & bit_mask (idx)) != 0;// idx번째 비트가 1인지 확인
  // 반환: 1이면 true, 0이면 false
}

/* Setting and testing multiple bits. */

/* Sets all bits in B to VALUE. */
void
bitmap_set_all (struct bitmap *b, bool value) 
{
  ASSERT (b != NULL);

  bitmap_set_multiple (b, 0, bitmap_size (b), value);// 비트맵의 모든 bit를 전부 value로 설정
}

/* Sets the CNT bits starting at START in B to VALUE. */
void
bitmap_set_multiple (struct bitmap *b, size_t start, size_t cnt, bool value) 
{ // [start, start+cnt) 범위의 비트를 value로 설정
  size_t i;
  
  ASSERT (b != NULL);
  ASSERT (start <= b->bit_cnt);
  ASSERT (start + cnt <= b->bit_cnt);

  for (i = 0; i < cnt; i++)
    bitmap_set (b, start + i, value);
}

/* Returns the number of bits in B between START and START + CNT,
   exclusive, that are set to VALUE. */
size_t
bitmap_count (const struct bitmap *b, size_t start, size_t cnt, bool value) 
{ // [start, start+cnt) 범위에서 value와 같은 비트가 몇 개인지 셈
  size_t i, value_cnt;

  ASSERT (b != NULL);
  ASSERT (start <= b->bit_cnt);
  ASSERT (start + cnt <= b->bit_cnt);

  value_cnt = 0;
  for (i = 0; i < cnt; i++)
    if (bitmap_test (b, start + i) == value)
      value_cnt++;
  return value_cnt;
}

/* Returns true if any bits in B between START and START + CNT,
   exclusive, are set to VALUE, and false otherwise. */
bool
bitmap_contains (const struct bitmap *b, size_t start, size_t cnt, bool value) 
{ // [start, start+cnt) 범위에 value인 비트가 하나라도 있으면 true
  size_t i;
  
  ASSERT (b != NULL);
  ASSERT (start <= b->bit_cnt);
  ASSERT (start + cnt <= b->bit_cnt);

  for (i = 0; i < cnt; i++)
    if (bitmap_test (b, start + i) == value)
      return true;
  return false;
}

/* Returns true if any bits in B between START and START + CNT,
   exclusive, are set to true, and false otherwise.*/
bool
bitmap_any (const struct bitmap *b, size_t start, size_t cnt) 
{ // 범위 내에 1인 비트가 하나라도 있는가?
  return bitmap_contains (b, start, cnt, true);
}

/* Returns true if no bits in B between START and START + CNT,
   exclusive, are set to true, and false otherwise.*/
bool
bitmap_none (const struct bitmap *b, size_t start, size_t cnt) 
{ // 범위 내에 1인 비트가 하나도 없는가? (= 전부 0인가?)
  return !bitmap_contains (b, start, cnt, true);
}

/* Returns true if every bit in B between START and START + CNT,
   exclusive, is set to true, and false otherwise. */
bool
bitmap_all (const struct bitmap *b, size_t start, size_t cnt) 
{ // 범위 내 모든 비트가 1인가?
  return !bitmap_contains (b, start, cnt, false);
}

/* Finding set or unset bits. */

/* Finds and returns the starting index of the first group of CNT
   consecutive bits in B at or after START that are all set to
   VALUE.
   If there is no such group, returns BITMAP_ERROR. */
size_t
bitmap_scan (const struct bitmap *b, size_t start, size_t cnt, bool value) 
{// start부터 연속 cnt개의 value 비트가 있는 구간을 찾음
  ASSERT (b != NULL);
  ASSERT (start <= b->bit_cnt);

  if (cnt <= b->bit_cnt) 
    {
      size_t last = b->bit_cnt - cnt;
      size_t i;
      for (i = start; i <= last; i++)
        if (!bitmap_contains (b, i, cnt, !value))
          return i; 
    }
  return BITMAP_ERROR;
}

/* Finds the first group of CNT consecutive bits in B at or after
   START that are all set to VALUE, flips them all to !VALUE,
   and returns the index of the first bit in the group.
   If there is no such group, returns BITMAP_ERROR.
   If CNT is zero, returns 0.
   Bits are set atomically, but testing bits is not atomic with
   setting them. */
size_t
bitmap_scan_and_flip (struct bitmap *b, size_t start, size_t cnt, bool value)
{// scan과 동일하되, 찾은 구간의 비트를 반전(!value)까지 수행
  size_t idx = bitmap_scan (b, start, cnt, value);
  if (idx != BITMAP_ERROR) 
    bitmap_set_multiple (b, idx, cnt, !value);
  return idx;
}

/* Returns the number of bytes needed to store B in a file. */
size_t
bitmap_file_size (const struct bitmap *b) 
{
  return byte_cnt (b->bit_cnt);
}

/* Debugging. */

/* Dumps the contents of B to the console as hexadecimal. */
void
bitmap_dump (const struct bitmap *b) 
{ // 비트맵 내용을 16진수로 콘솔에 출력
  hex_dump (0, b->bits, byte_cnt (b->bit_cnt)/2, false);
}

