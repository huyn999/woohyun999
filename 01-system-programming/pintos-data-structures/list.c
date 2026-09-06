#include "list.h"
#include <assert.h>	
#include <stdlib.h>
#define ASSERT(CONDITION) assert(CONDITION)	


/* Our doubly linked lists have two header elements: the "head"
   just before the first element and the "tail" just after the
   last element.  The `prev' link of the front header is null, as
   is the `next' link of the back header.  Their other two links
   point toward each other via the interior elements of the list.

   An empty list looks like this:

                      +------+     +------+
                  <---| head |<--->| tail |--->
                      +------+     +------+

   A list with two elements in it looks like this:

        +------+     +-------+     +-------+     +------+
    <---| head |<--->|   1   |<--->|   2   |<--->| tail |<--->
        +------+     +-------+     +-------+     +------+

   The symmetry of this arrangement eliminates lots of special
   cases in list processing.  For example, take a look at
   list_remove(): it takes only two pointer assignments and no
   conditionals.  That's a lot simpler than the code would be
   without header elements.

   (Because only one of the pointers in each header element is used,
   we could in fact combine them into a single header element
   without sacrificing this simplicity.  But using two separate
   elements allows us to do a little bit of checking on some
   operations, which can be valuable.) */

static bool is_sorted (struct list_elem *a, struct list_elem *b,
                       list_less_func *less, void *aux);
                       
/* Returns true if ELEM is a head, false otherwise. */
static inline bool
is_head (struct list_elem *elem)
{
  return elem != NULL && elem->prev == NULL && elem->next != NULL;
}

/* Returns true if ELEM is an interior element,
   false otherwise. */
static inline bool
is_interior (struct list_elem *elem)
{
  return elem != NULL && elem->prev != NULL && elem->next != NULL;
}

/* Returns true if ELEM is a tail, false otherwise. */
static inline bool
is_tail (struct list_elem *elem)
{
  return elem != NULL && elem->prev != NULL && elem->next == NULL;
}

/* Initializes LIST as an empty list. */
void 
list_init (struct list *list)//리스트 처음 생성시에 초기화 해야할 부분
{  //리스트 요소 헤드 와 테일에 대한 작업 수행
  ASSERT (list != NULL);
  list->head.prev = NULL;
  list->head.next = &list->tail;
  list->tail.prev = &list->head;
  list->tail.next = NULL;
}

/* Returns the beginning of LIST.  */
struct list_elem *
list_begin (struct list *list)
{
  ASSERT (list != NULL);
  return list->head.next;
}

/* Returns the element after ELEM in its list.  If ELEM is the
   last element in its list, returns the list tail.  Results are
   undefined if ELEM is itself a list tail. */
struct list_elem *
list_next (struct list_elem *elem)
{
  ASSERT (is_head (elem) || is_interior (elem));
  return elem->next;
}

/* Returns LIST's tail.

   list_end() is often used in iterating through a list from
   front to back.  See the big comment at the top of list.h for
   an example. */
struct list_elem *list_end (struct list *list)
{
  ASSERT (list != NULL);
  return &list->tail;// 그 리스트에서 tail 요소의 주소값을 반환
}

/* Returns the LIST's reverse beginning, for iterating through
   LIST in reverse order, from back to front. */
struct list_elem *
list_rbegin (struct list *list) 
{
  ASSERT (list != NULL);
  return list->tail.prev;
}

/* Returns the element before ELEM in its list.  If ELEM is the
   first element in its list, returns the list head.  Results are
   undefined if ELEM is itself a list head. */
struct list_elem *
list_prev (struct list_elem *elem)
{
  ASSERT (is_interior (elem) || is_tail (elem));
  return elem->prev;
}

/* Returns LIST's head.

   list_rend() is often used in iterating through a list in
   reverse order, from back to front.  Here's typical usage,
   following the example from the top of list.h:

      for (e = list_rbegin (&foo_list); e != list_rend (&foo_list);
           e = list_prev (e))
        {
          struct foo *f = list_entry (e, struct foo, elem);
          ...do something with f...
        }
*/
struct list_elem *
list_rend (struct list *list) 
{
  ASSERT (list != NULL);
  return &list->head;
}

/* Return's LIST's head.

   list_head() can be used for an alternate style of iterating
   through a list, e.g.:

      e = list_head (&list);
      while ((e = list_next (e)) != list_end (&list)) 
        {
          ...
        }
*/
struct list_elem *
list_head (struct list *list) 
{
  ASSERT (list != NULL);
  return &list->head;
}

/* Return's LIST's tail. */
struct list_elem *
list_tail (struct list *list) 
{
  ASSERT (list != NULL);
  return &list->tail;// 그 리스트에서 tail 요소의 주소 값(struct list_elem *)반환
}

/* Inserts ELEM just before BEFORE, which may be either an
   interior element or a tail.  The latter case is equivalent to
   list_push_back(). */
void 
list_insert (struct list_elem *before, struct list_elem *elem)// 리스트에 삽입,before 노드 이전에 삽입
{
  ASSERT (is_interior (before) || is_tail (before));
  ASSERT (elem != NULL);

  elem->prev = before->prev;
  elem->next = before;
  before->prev->next = elem;
  before->prev = elem;
}

/* Removes elements FIRST though LAST (exclusive) from their
   current list, then inserts them just before BEFORE, which may
   be either an interior element or a tail. */
void 
list_splice (struct list_elem *before,
             struct list_elem *first, struct list_elem *last)
{
  ASSERT (is_interior (before) || is_tail (before));
  if (first == last)
    return;
  last = list_prev (last);// 우리가 스플라이스에서 포함하는 실제 원소

  ASSERT (is_interior (first));
  ASSERT (is_interior (last));

  /* Cleanly remove FIRST...LAST from its current list. */
  first->prev->next = last->next;// 기존 리스트에서 그 부분 제거
  last->next->prev = first->prev;

  /* Splice FIRST...LAST into new list. */
  //스플라이스 한부분을  새로운 리스트의 before 이전에 삽입한다
  first->prev = before->prev;
  last->next = before;
  before->prev->next = first;
  before->prev = last;// 비포의 이전은 라스트이다.
}

/* Inserts ELEM at the beginning of LIST, so that it becomes the
   front in LIST. */
void 
list_push_front (struct list *list, struct list_elem *elem)
{
  list_insert (list_begin (list), elem); // 리스트 삽입 맨 앞에
}

/* Inserts ELEM at the end of LIST, so that it becomes the
   back in LIST. */
void 
list_push_back (struct list *list, struct list_elem *elem)
{
  list_insert (list_end (list), elem);// tail 전 자리에 삽입한다.
}

/* Removes ELEM from its list and returns the element that
   followed it.  Undefined behavior if ELEM is not in a list.

   It's not safe to treat ELEM as an element in a list after
   removing it.  In particular, using list_next() or list_prev()
   on ELEM after removal yields undefined behavior.  This means
   that a naive loop to remove the elements in a list will fail:

   ** DON'T DO THIS **
   for (e = list_begin (&list); e != list_end (&list); e = list_next (e))
     {
       ...do something with e...
       list_remove (e);
     }
   ** DON'T DO THIS **

   Here is one correct way to iterate and remove elements from a
   list:

   for (e = list_begin (&list); e != list_end (&list); e = list_remove (e))
     {
       ...do something with e...
     }

   If you need to free() elements of the list then you need to be
   more conservative.  Here's an alternate strategy that works
   even in that case:

   while (!list_empty (&list))
     {
       struct list_elem *e = list_pop_front (&list);
       ...do something with e...
     }
*/
struct list_elem *
list_remove (struct list_elem *elem)// 리스트의 한 요소를 삭제하는 함수
{
  ASSERT (is_interior (elem));
  elem->prev->next = elem->next;
  elem->next->prev = elem->prev;
  return elem->next;
}

/* Removes the front element from LIST and returns it.
   Undefined behavior if LIST is empty before removal. */
struct list_elem *
list_pop_front (struct list *list)
{
  struct list_elem *front = list_front (list);
  list_remove (front);
  return front;
}

/* Removes the back element from LIST and returns it.
   Undefined behavior if LIST is empty before removal. */
struct list_elem *
list_pop_back (struct list *list)
{
  struct list_elem *back = list_back (list);
  list_remove (back);
  return back;
}

/* Returns the front element in LIST.
   Undefined behavior if LIST is empty. */
struct list_elem *
list_front (struct list *list)
{
  ASSERT (!list_empty (list));
  return list->head.next;
}

/* Returns the back element in LIST.
   Undefined behavior if LIST is empty. */
struct list_elem *
list_back (struct list *list)
{
  ASSERT (!list_empty (list));
  return list->tail.prev;// 테일의 이전 요소를 반환
}

/* Returns the number of elements in LIST.
   Runs in O(n) in the number of elements. */
size_t
list_size (struct list *list)
{
  struct list_elem *e;
  size_t cnt = 0;

  for (e = list_begin (list); e != list_end (list); e = list_next (e))
    cnt++;
  return cnt;// 리스트 내부의 실제 노드의 개수를 반환한다
}

/* Returns true if LIST is empty, false otherwise. */
bool
list_empty (struct list *list)
{
  return list_begin (list) == list_end (list);
}

/* Swaps the `struct list_elem *'s that A and B point to. */
static void
swap (struct list_elem **a, struct list_elem **b) 
{
  struct list_elem *t = *a;
  *a = *b;
  *b = t;
}

/* Reverses the order of LIST. */
void 
list_reverse (struct list *list)// 리스트 자체의 주소값을 인자로 받는다.
{
  if (!list_empty (list)) 
    {
      struct list_elem *e;

      for (e = list_begin (list); e != list_end (list); e = e->prev)
        swap (&e->prev, &e->next);
      swap (&list->head.next, &list->tail.prev);
      swap (&list->head.next->prev, &list->tail.prev->next);
    }
}

/* Returns true only if the list elements A through B (exclusive)
   are in order according to LESS given auxiliary data AUX. */
static bool
is_sorted (struct list_elem *a, struct list_elem *b,
           list_less_func *less, void *aux)
{
  if (a != b)
    while ((a = list_next (a)) != b) 
      if (less (a, list_prev (a), aux))
        return false;
  return true;
}

/* Finds a run, starting at A and ending not after B, of list
   elements that are in nondecreasing order according to LESS
   given auxiliary data AUX.  Returns the (exclusive) end of the
   run.
   A through B (exclusive) must form a non-empty range. */
static struct list_elem *
find_end_of_run (struct list_elem *a, struct list_elem *b,
                 list_less_func *less, void *aux)
{
  ASSERT (a != NULL);
  ASSERT (b != NULL);
  ASSERT (less != NULL);
  ASSERT (a != b);
  
  do 
    {
      a = list_next (a);
    }
  while (a != b && !less (a, list_prev (a), aux));
  return a;
}

/* Merges A0 through A1B0 (exclusive) with A1B0 through B1
   (exclusive) to form a combined range also ending at B1
   (exclusive).  Both input ranges must be nonempty and sorted in
   nondecreasing order according to LESS given auxiliary data
   AUX.  The output range will be sorted the same way. */
static void
inplace_merge (struct list_elem *a0, struct list_elem *a1b0,
               struct list_elem *b1,
               list_less_func *less, void *aux)
{
  ASSERT (a0 != NULL);
  ASSERT (a1b0 != NULL);
  ASSERT (b1 != NULL);
  ASSERT (less != NULL);
  ASSERT (is_sorted (a0, a1b0, less, aux));
  ASSERT (is_sorted (a1b0, b1, less, aux));

  while (a0 != a1b0 && a1b0 != b1)
    if (!less (a1b0, a0, aux)) 
      a0 = list_next (a0);
    else 
      {
        a1b0 = list_next (a1b0);
        list_splice (a0, list_prev (a1b0), a1b0);
      }
}

/* Sorts LIST according to LESS given auxiliary data AUX, using a
   natural iterative merge sort that runs in O(n lg n) time and
   O(1) space in the number of elements in LIST. */
void 
list_sort (struct list *list, list_less_func *less, void *aux)// 리스트를 merge sort로 정렬
{
  size_t output_run_cnt;        /* Number of runs output in current pass. */

  ASSERT (list != NULL);
  ASSERT (less != NULL);

  /* Pass over the list repeatedly, merging adjacent runs of
     nondecreasing elements, until only one run is left. */
  do
    {
      struct list_elem *a0;     /* Start of first run. */
      struct list_elem *a1b0;   /* End of first run, start of second. */
      struct list_elem *b1;     /* End of second run. */

      output_run_cnt = 0;
      for (a0 = list_begin (list); a0 != list_end (list); a0 = b1)
        {
          /* Each iteration produces one output run. */
          output_run_cnt++;

          /* Locate two adjacent runs of nondecreasing elements
             A0...A1B0 and A1B0...B1. */
          a1b0 = find_end_of_run (a0, list_end (list), less, aux);
          if (a1b0 == list_end (list))
            break;
          b1 = find_end_of_run (a1b0, list_end (list), less, aux);

          /* Merge the runs. */
          inplace_merge (a0, a1b0, b1, less, aux);
        }
    }
  while (output_run_cnt > 1);

  ASSERT (is_sorted (list_begin (list), list_end (list), less, aux));
}

/* Inserts ELEM in the proper position in LIST, which must be
   sorted according to LESS given auxiliary data AUX.
   Runs in O(n) average case in the number of elements in LIST. */
void 
list_insert_ordered (struct list *list, struct list_elem *elem,
                     list_less_func *less, void *aux)
{
  struct list_elem *e;

  ASSERT (list != NULL);
  ASSERT (elem != NULL);
  ASSERT (less != NULL);

  for (e = list_begin (list); e != list_end (list); e = list_next (e))
    if (less (elem, e, aux))
      break;
  return list_insert (e, elem);
}

/* Iterates through LIST and removes all but the first in each
   set of adjacent elements that are equal according to LESS
   given auxiliary data AUX.  If DUPLICATES is non-null, then the
   elements from LIST are appended to DUPLICATES. */
void 
list_unique (struct list *list, struct list *duplicates,
             list_less_func *less, void *aux)
{
  struct list_elem *elem, *next;

  ASSERT (list != NULL);
  ASSERT (less != NULL);
  if (list_empty (list))
    return;

  elem = list_begin (list);
  while ((next = list_next (elem)) != list_end (list))
    if (!less (elem, next, aux) && !less (next, elem, aux)) 
      {
        list_remove (next);
        if (duplicates != NULL)// 중복 저장할 리스트가 있다면
          list_push_back (duplicates, next);// 거기에 저장한다
      }
    else
      elem = next;
}

/* Returns the element in LIST with the largest value according
   to LESS given auxiliary data AUX.  If there is more than one
   maximum, returns the one that appears earlier in the list.  If
   the list is empty, returns its tail. */
struct list_elem *
list_max (struct list *list, list_less_func *less, void *aux)
{
  struct list_elem *max = list_begin (list);
  if (max != list_end (list)) 
    {
      struct list_elem *e;
      
      for (e = list_next (max); e != list_end (list); e = list_next (e))
        if (less (max, e, aux))
          max = e; 
    }
  return max;
}

/* Returns the element in LIST with the smallest value according
   to LESS given auxiliary data AUX.  If there is more than one
   minimum, returns the one that appears earlier in the list.  If
   the list is empty, returns its tail. */
struct list_elem *
list_min (struct list *list, list_less_func *less, void *aux)
{
  struct list_elem *min = list_begin (list);
  if (min != list_end (list)) 
    {
      struct list_elem *e;
      
      for (e = list_next (min); e != list_end (list); e = list_next (e))
        if (less (e, min, aux))
          min = e; 
    }
  return min;
}

// list_less: 두 list_elem의 value를 비교하여 a < b이면 true 반환
// list_sort, list_insert_ordered, list_unique에서 비교 함수로 사용됨
bool list_less (const struct list_elem *a, const struct list_elem *b, void *aux)
{
  list_item *la = list_entry (a, list_item, elem); // a의 list_item 주소 획득
  list_item *lb = list_entry (b, list_item, elem); // b의 list_item 주소 획득
  return la->value < lb->value;                    // 오름차순 비교
}


// list_swap 인접 노드 교환과 비인접 노드 교환을 구분하여 처리
void list_swap (struct list_elem *a, struct list_elem *b)
{
  if (a == b) return; // 같은 노드면 교환 불필요

  // 각 노드의 이전/다음 포인터를 임시 변수에 저장
  struct list_elem *pa = a->prev; // a의 이전 노드
  struct list_elem *na = a->next; // a의 다음 노드
  struct list_elem *pb = b->prev; // b의 이전 노드
  struct list_elem *nb = b->next; // b의 다음 노드

  //  a 바로 뒤에 b가 있는 경우 (a-b 인접)
  if (na == b)
    {
      // a를 b 뒤로, b를 a 앞으로 이동
      a->prev = b;      // a의 prev가 b를 가리킴
      a->next = nb;     // a의 next가 b의 원래 다음을 가리킴
      b->prev = pa;     // b의 prev가 a의 원래 이전을 가리킴
      b->next = a;      // b의 next가 a를 가리킴
      pa->next = b;     // a의 원래 이전 노드의 next를 b로 갱신
      nb->prev = a;     // b의 원래 다음 노드의 prev를 a로 갱신
    }
  //  b 바로 뒤에 a가 있는 경우 (b-a 인접)
  else if (nb == a) // 위 케이스와 대칭적으로 처리함
    {
      b->prev = a;      
      b->next = na;
      a->prev = pb;
      a->next = b;
      pb->next = a;
      na->prev = b;
    }
  // a와 b가 인접하지 않는 경우
  else
    {
      // a와 b의 위치를 서로 교환
      a->prev = pb;     // a가 b의 원래 이전/다음을 물려받음
      a->next = nb;
      b->prev = pa;     // b가 a의 원래 이전/다음을 물려받음
      b->next = na;

      // 주변 노드들이 새 위치를 가리키도록 갱신
      pa->next = b;     // a의 원래 이전 → 이제 b를 가리키도록 갱신
      na->prev = b;     // a의 원래 다음 → 이제 b를 가리키도록 갱신
      pb->next = a;     // b의 원래 이전 → 이제 a를 가리키도록 갱신
      nb->prev = a;     // b의 원래 다음 → 이제 a를 가리키도록 갱신
    }
}



/* list_shuffle: 랜덤 추출 방식으로 리스트 원소를 무작위 섞기.
   임시 리스트를 만들어, 원본에서 랜덤 위치의 원소를 하나씩 뽑아 옮긴 뒤
   다시 원본으로 되돌린다. */
void list_shuffle (struct list *lst)
{
  size_t n = list_size (lst);
  if (n < 2) return;

  srand ((unsigned) time (NULL)); 

  struct list tmp;//임시 리스트 선언
  list_init (&tmp);// 임시 리스트 초기화

  // 원본에서 랜덤 원소를 하나씩 뽑아 tmp 뒤에 추가
  while (!list_empty (lst))//리스트가 빌 때까지
    {
      size_t pick = rand () % list_size (lst);//렌덤으로 인덱스를 택함
      size_t steps = pick; // pick만큼 전진
      struct list_elem *e = list_begin (lst); // 첫 원소부터 시작
      while (steps-- > 0 && e != list_end (lst)) e = list_next (e); // pick 번째 원소까지 이동
      list_remove (e); //원본 리스트에서 그 원소 제거,리스트에서 제거할 뿐 포인터 e는 존재
      list_push_back (&tmp, e);//임시리스트에 뒤에서부터 삽입 
    }
   
  // 임시리스트 tmp의 모든 원소를 순서에 따라 현재 비어있는 원본 리스트로 한번에 이동
  list_splice (list_end(lst), list_begin (&tmp), list_end (&tmp));
}