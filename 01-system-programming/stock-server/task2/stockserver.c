#include "csapp.h"                                       
#include <errno.h>                                       
#include <pthread.h>                                     

#define STOCKFILE "stock.txt"                            
#define NTHREADS  20                             // worker thread 수
#define SBUFSIZE  64                            // producer-consumer 큐 크기


// 주식 노드 (BST)
typedef struct item {                                    // BST 노드 구조체
    int ID;                                              // 주식 ID (BST key)
    int left_stock;                                      // 잔여 수량 (writer 락으로 보호)
    int price;                                           // 주식 단가
    pthread_rwlock_t rwlock;                             // 노드별 readers-writers 락
    struct item *left, *right;                           // BST 자식 포인터 
} stock_t;

static stock_t *root = NULL;                             // 트리 루트

// 새 노드 생성
static stock_t *new_stock(int id, int stock, int price) {
    stock_t *n = (stock_t *)Malloc(sizeof(stock_t));     
    n->ID = id;                                          // ID 초기화
    n->left_stock = stock;                               // 잔여 초기화
    n->price = price;                                    // 단가 초기화
    pthread_rwlock_init(&n->rwlock, NULL);               // rwlock 초기화 
    n->left = n->right = NULL;                          
    return n;
}

// BST 삽입  
static stock_t *tree_insert(stock_t *r, stock_t *n) {
    if (!r) return n;                                  
    if (n->ID < r->ID)      r->left  = tree_insert(r->left,  n);  // 작으면 왼쪽 재귀
    else if (n->ID > r->ID) r->right = tree_insert(r->right, n);  // 크면 오른쪽 재귀
    return r;
}

// BST 검색  
static stock_t *tree_find(stock_t *r, int id) {
    if (!r) return NULL;                                 
    if (id == r->ID) return r;                           
    return (id < r->ID) ? tree_find(r->left, id)         // 작으면 왼쪽 재귀
                        : tree_find(r->right, id);       // 크면 오른쪽 재귀
}

// BST 해제, 락 자원도 같이 정리
static void tree_destroy(stock_t *r) {
    if (!r) return;
    tree_destroy(r->left);                               // 왼쪽 서브트리 먼저
    tree_destroy(r->right);                              // 오른쪽 서브트리 다음
    pthread_rwlock_destroy(&r->rwlock);                  // 락 자원 정리
    Free(r);                                            
}


// stock.txt 입출력 (file_lock로 동시 호출 방지)

static sem_t file_lock;           // write_stockfile 직렬화용 binary semaphore

// 서버 시작 시 1회 호출 bst tree를 만듦
static void read_stockfile(void) {
    FILE *fp = fopen(STOCKFILE, "r"); 
    if (!fp) { fprintf(stderr, "cannot open %s\n", STOCKFILE); exit(1); }
    int id, stock, price;
    while (fscanf(fp, "%d %d %d", &id, &stock, &price) == 3)  
        root = tree_insert(root, new_stock(id, stock, price));
    fclose(fp);
}

// write_stockfile 헬퍼함수,  in-order 재귀로 출력 + 노드별 reader 락
static void write_inorder(FILE *fp, stock_t *n) {
    if (!n) return;
    write_inorder(fp, n->left);       // 왼쪽 서브트리 먼저 
    pthread_rwlock_rdlock(&n->rwlock);      // reader 락을 설정해서 다른 쓰레드가 그 노드 주식에 대해 buy sell 불가
    fprintf(fp, "%d %d %d\n", n->ID, n->left_stock, n->price);
    pthread_rwlock_unlock(&n->rwlock);       // 락 해제
    write_inorder(fp, n->right);              // 오른쪽 서브트리 다음 
}

// BST에서 stock.txt 저장함수, 마지막 client 끊김 + SIGINT 시점에만 호출
static void write_stockfile(void) {
    P(&file_lock);                                       // file_lock 잡음 (main의 SIGINT save와 worker의 마지막-disconnect save 직렬화)
    FILE *fp = fopen(STOCKFILE, "w");                    // 쓰기 모드 
    if (fp) { write_inorder(fp, root); fclose(fp); }     // 열기 성공 시만 출력
    V(&file_lock);                                       // file_lock 해제
}


// 명령 처리 (thread-safe)

// show 보조 함수 in-order 재귀 + 노드별 reader 락 
static void gather_inorder(stock_t *n, char *buf, int *off) {
    if (!n) return;
    gather_inorder(n->left, buf, off);                   // 왼쪽 서브트리먼저
    pthread_rwlock_rdlock(&n->rwlock);                   // reader 락으로 각 쓰레드 동시 진입 가능
    *off += sprintf(buf + *off, "%d %d %d\n",
                    n->ID, n->left_stock, n->price);
    pthread_rwlock_unlock(&n->rwlock);                   // 락 해제
    gather_inorder(n->right, buf, off);                  // 오른쪽 서브트리 다음
}

// show 진입점
static void handle_show(char *response) {
    response[0] = '\0';
    int off = 0;
    gather_inorder(root, response, &off);             
}

// buy 잔여 충분 시 차감 + success, 부족 시 not enough
static void handle_buy(int id, int amount, char *response) {
    stock_t *n = tree_find(root, id);                    // 락 없이 검색 
    if (!n) { strcpy(response, "no such stock\n"); return; }

    pthread_rwlock_wrlock(&n->rwlock);                   // writer 락. 노드 독점
    if (n->left_stock < amount) {                        // 잔여 부족시에 
        pthread_rwlock_unlock(&n->rwlock);               // 락 풀고
        strcpy(response, "Not enough left stocks\n");    // 부족 문구 출력
        return;
    }
    n->left_stock -= amount;                             // 주식 수량 차감
    pthread_rwlock_unlock(&n->rwlock);                   // 락 해제
    strcpy(response, "[buy] success\n");                 
}

// sell
static void handle_sell(int id, int amount, char *response) {
    stock_t *n = tree_find(root, id);                    // 락 없이 검색
    if (!n) { strcpy(response, "no such stock\n"); return; }

    pthread_rwlock_wrlock(&n->rwlock);               // writer 락,  노드 독점
    n->left_stock += amount;                         // 잔여 주식 증가처리
    pthread_rwlock_unlock(&n->rwlock);               // 락 해제
    strcpy(response, "[sell] success\n");                
}

// 명령 디스패처
static void dispatch_command(char *cmd, char *response) {
    memset(response, 0, MAXLINE);        // 응답 버퍼 0 패딩
    if (strncmp(cmd, "show", 4) == 0) {                 
        handle_show(response);
    } else if (strncmp(cmd, "buy", 3) == 0) {           
        int id, amount;                             
        sscanf(cmd, "buy %d %d", &id, &amount);        
        handle_buy(id, amount, response);
    } else if (strncmp(cmd, "sell", 4) == 0) {           
        int id, amount;
        sscanf(cmd, "sell %d %d", &id, &amount);
        handle_sell(id, amount, response);
    }
                                                          
}

/*  
    sbuf, producer-consumer 큐   master(producer)가 connfd를 insert 한 후에
    worker(consumer)들이 remove로 꺼내감.
*/
typedef struct {                                         // sbuf_t 구조체
    int *buf;                                            // 원형 큐 배열 (connfd 저장)
    int n;                                               // 큐 크기
    int front;                                           // pop 위치
    int rear;                                            // push 위치
    sem_t mutex;                                         // 큐 자료구조 보호 (binary, init 1)
    sem_t slots;                                         // 빈 슬롯 수 (counting, init n)
    sem_t items;                                         // 채워진 슬롯 수 (counting, init 0)
} sbuf_t;

static sbuf_t sbuf;                                     

// 큐 초기화
static void sbuf_init(sbuf_t *sp, int n) {
    sp->buf   = Calloc(n, sizeof(int));                  
    sp->n     = n;                                       
    sp->front = sp->rear = 0;                            // 비어있음 
    Sem_init(&sp->mutex, 0, 1);                          // binary 세마포어
    Sem_init(&sp->slots, 0, n);                          // 처음 n칸 다 비어있음
    Sem_init(&sp->items, 0, 0);                          //처음엔 큐에 들어온 연결 없음
}

// master가 connfd 푸시. 큐가 꽉 차면 slots에서 대기
static void sbuf_insert(sbuf_t *sp, int item) {
    P(&sp->slots);                                       // 빈 슬롯 1개 점유, 없으면 대기함
    P(&sp->mutex);                                       // 큐 보호 락
    sp->buf[(++sp->rear) % sp->n] = item;                // rear 증가 후 그 위치에 push
    V(&sp->mutex);                                       // 큐 보호 해제
    V(&sp->items);                                       // 채워진 슬롯 +1 알림 
}

// worker가 connfd 꺼냄. 큐가 비면 items에서 대기
static int sbuf_remove(sbuf_t *sp) {
    int item;
    P(&sp->items);                                       // 채워진 슬롯 1개 점유 ,없으면 대기함
    P(&sp->mutex);                                       // 큐 보호 락
    item = sp->buf[(++sp->front) % sp->n];               // front 증가 후 그 위치에서 pop
    V(&sp->mutex);                                       // 큐 보호 해제
    V(&sp->slots);                                       // 빈 슬롯 +1 알림 
    return item;
}


// 접속 client 카운터 마지막 disconnect시 자동 save함수를 트리거함

static int   active_clients = 0;                         // 현재 접속자 수
static sem_t active_lock;                                // active_clients 보호 락

// 새 접속 시 master가 호출
static void client_enter(void) {
    P(&active_lock); 
    active_clients++; 
    V(&active_lock);  // mutex 안에서 증가
}

// client 응대 끝나면 worker가 호출. 0이 되면 write_stockfile
static void client_exit(void) {
    P(&active_lock);                                     // mutex 잡음
    int now = --active_clients;                          
    V(&active_lock);                                     // mutex 품
    if (now == 0) write_stockfile();                     // 마지막 client였으면 저장 , file_lock로 별도 보호함
}


// Worker thread

static void worker_serve(int connfd) { // 하나의 쓰레드는 한 사용자와의 연락이 끊길때까지 그 사용자만을 담당해서 일 처리
    rio_t rio;                                           // 이 worker,client 전용 RIO 버퍼
    char buf[MAXLINE], response[MAXLINE];                // 수신/송신 버퍼 
    Rio_readinitb(&rio, connfd);                         // connfd로 RIO 버퍼 초기화

    ssize_t n;
    while ((n = Rio_readlineb(&rio, buf, MAXLINE)) > 0) {  // 한 줄씩 읽기 
        
        printf("server received %zu bytes\n%s", strlen(buf), buf);

        if (strncmp(buf, "exit", 4) == 0) break;         // exit이면 응대 종료
        dispatch_command(buf, response);                 // 명령 처리
        Rio_writen(connfd, response, MAXLINE);           // response 보냄
    }
}

// worker thread로 계속 큐에서 connfd 꺼내 응대
static void *worker_thread(void *vargp) {
    Pthread_detach(pthread_self());                      // 종료 시 자원 자동 회수
    while (1) {                                          
        int connfd = sbuf_remove(&sbuf);                 // 큐에서 할 일을 받음 ,없으면 대기
        worker_serve(connfd);                            // client가 연결 종료까지 응대
        Close(connfd);                                   // 소켓 닫음
        client_exit();                                   // 카운터 감소, 마지막이면 stock.txt save함 이후 다음 클라이언트 응대처리
    }
    return NULL;                                         
}


// 시그널 핸들러 

static volatile sig_atomic_t shutdown_requested = 0;     // SIGINT 플래그

static void on_sigint(int sig) {
    shutdown_requested = 1;                              // 플래그만 set 함
}


// main (master thread)

int main(int argc, char **argv) {
    if (argc != 2) {                                    
        fprintf(stderr, "usage: %s <port>\n", argv[0]);
        exit(0);
    }

    /*
      SIGINT 등록. SA_RESTART 끄기.
    */
    struct sigaction sa_int;
    sa_int.sa_handler = on_sigint;                       // 핸들러 등록
    sigemptyset(&sa_int.sa_mask);                        
    sa_int.sa_flags = 0;                                 
    if (sigaction(SIGINT, &sa_int, NULL) < 0)
        unix_error("sigaction error");

    Signal(SIGPIPE, SIG_IGN);              // SIGPIPE 무시

    Sem_init(&active_lock, 0, 1);        // active_clients 보호 락 초기화
    Sem_init(&file_lock,   0, 1);        // write_stockfile 직렬화 락 초기화
    sbuf_init(&sbuf, SBUFSIZE);          // 큐 ,세마포어 초기화

    read_stockfile();               // stock.txt 에서 BST 메모리 적재


    sigset_t mask, oldmask;
    sigemptyset(&mask);                                  
    sigaddset(&mask, SIGINT);                            // SIGINT 추가
    pthread_sigmask(SIG_BLOCK, &mask, &oldmask);         // main도 잠시 차단 이후 worker 생성

    pthread_t tid;
    for (int i = 0; i < NTHREADS; i++)                   
        Pthread_create(&tid, NULL, worker_thread, NULL); // NTHREADS개의 worker thread 생성 및 실행
                                                          // worker들은 SIGINT 차단 마스크를 상속

    pthread_sigmask(SIG_SETMASK, &oldmask, NULL);        // main만 다시 unblock

    int listenfd = Open_listenfd(argv[1]);               // listening 소켓 생성

    while (!shutdown_requested) {    // 메인 루프
        struct sockaddr_storage clientaddr;
        socklen_t clientlen = sizeof(clientaddr);
      
        int connfd = accept(listenfd, (SA *)&clientaddr, &clientlen);// 새 클라이언트 accept
        if (connfd < 0) {
            if (errno == EINTR) continue;                
            unix_error("accept error");
        }
        char host[MAXLINE], port[MAXLINE];
        Getnameinfo((SA *)&clientaddr, clientlen, host, MAXLINE, port, MAXLINE, 0);                  
        printf("Connected to (%s, %s)\n", host, port);   

        client_enter();                  // 접속자 카운터 +1
        sbuf_insert(&sbuf, connfd);      // 큐에 넣고 워커 쓰레드가 큐에서 pop한 후에 클라이언트 명령처리,메인쓰레드는 다시 accept하는 루프를 돔
    }

    write_stockfile();             // SIGINT 이후 최종 저장
    tree_destroy(root);            
    return 0;                                            
}