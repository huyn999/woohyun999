#include "csapp.h"                                       
#include <errno.h>                                       

#define STOCKFILE "stock.txt"                            


// 주식 노드 구조체 (BST, key = ID)
typedef struct item {                                    // BST 노드 구조체
    int ID;                                              // 주식 종목 ID (BST key)
    int left_stock;                                      // 잔여 수량
    int price;                                           // 주식 단가
    struct item *left, *right;                           // BST 자식 포인터
} stock_t;

static stock_t *root = NULL;                             // 트리의 루트

// 새 노드 1개 생성
static stock_t *new_stock(int id, int stock, int price) {
    stock_t *n = (stock_t *)Malloc(sizeof(stock_t));     // 동적 할당
    n->ID = id;                                          // ID 초기화
    n->left_stock = stock;                               // 잔여 초기화
    n->price = price;                                    // 단가 초기화
    n->left = n->right = NULL;                           
    return n;
}

// BST에 노드 삽입 (재귀)
static stock_t *tree_insert(stock_t *r, stock_t *n) {
    if (!r) return n;                                    // 빈 자리면 새 노드를 그 자리로
    if (n->ID < r->ID)      r->left  = tree_insert(r->left,  n);  // 작으면 왼쪽 재귀
    else if (n->ID > r->ID) r->right = tree_insert(r->right, n);  // 크면 오른쪽 재귀
    return r;                                            // 자기 자신 반환
}

// BST 검색
static stock_t *tree_find(stock_t *r, int id) {
    if (!r) return NULL;                                 
    if (id == r->ID) return r;                          
    return (id < r->ID) ? tree_find(r->left, id)         // 작으면 왼쪽 재귀
                        : tree_find(r->right, id);       // 크면 오른쪽 재귀
}

// BST 해제 
static void tree_destroy(stock_t *r) {
    if (!r) return;                                     
    tree_destroy(r->left);                               // 왼쪽 서브트리 먼저
    tree_destroy(r->right);                              // 오른쪽 서브트리 다음
    Free(r);                                             // 자기 자신 마지막 해제
}


// stock.txt 입출력

// 서버 시작 시 1회 호출
static void read_stockfile(void) {
    FILE *fp = fopen(STOCKFILE, "r");                    
    if (!fp) { fprintf(stderr, "cannot open %s\n", STOCKFILE); exit(1); }
    int id, stock, price;
    while (fscanf(fp, "%d %d %d", &id, &stock, &price) == 3)
        root = tree_insert(root, new_stock(id, stock, price));
    fclose(fp);
}

// write_stockfile 헬퍼함수 in-order로 출력 
static void write_inorder(FILE *fp, stock_t *n) {
    if (!n) return;                                      
    write_inorder(fp, n->left);                          // 왼쪽 먼저
    fprintf(fp, "%d %d %d\n", n->ID, n->left_stock, n->price);
    write_inorder(fp, n->right);                         // 오른쪽 다음
}

// BST에서 stock.txt에 저장. 마지막 client 끊김 또눈 SIGINT 시점에만 호출
static void write_stockfile(void) {
    FILE *fp = fopen(STOCKFILE, "w");                    
    if (!fp) return;                                  
    write_inorder(fp, root);    // 트리 전체 in-order 출력
    fclose(fp);
}



// show 헬퍼 함수, in-order로 buf에 누적 
static void gather_inorder(stock_t *n, char *buf, int *off) {
    if (!n) return;                                     
    gather_inorder(n->left, buf, off);                   // 왼쪽 먼저
    *off += sprintf(buf + *off, "%d %d %d\n",
                    n->ID, n->left_stock, n->price);
    gather_inorder(n->right, buf, off);                  // 오른쪽 다음
}

// show 진입점
static void handle_show(char *response) {
    response[0] = '\0';                                  // 응답 문자열을 빈 문자열로 초기화
    int off = 0;
    gather_inorder(root, response, &off);
}

// buy 잔여 주식이 충분 시 차감 + success, 부족 시 Not enough
static void handle_buy(int id, int amount, char *response) {
    stock_t *n = tree_find(root, id);                    // ID로 노드 검색

    if (!n) { strcpy(response, "no such stock\n"); return; }

    if (n->left_stock < amount) {                        // 잔여 부족시
        strcpy(response, "Not enough left stocks\n");    
        return;
    }
    n->left_stock -= amount;                             // 주식 개수 차감
    strcpy(response, "[buy] success\n");                
}

// sell
static void handle_sell(int id, int amount, char *response) {
    stock_t *n = tree_find(root, id);                    // ID로 노드 검색
    if (!n) { strcpy(response, "no such stock\n"); return; }

    n->left_stock += amount;                             // 잔여 주식 증가시킴
    strcpy(response, "[sell] success\n");                
}

// 명령 디스패처
static void dispatch_command(char *cmd, char *response) {
    memset(response, 0, MAXLINE);                        // 응답 버퍼 0 패딩
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

 // select용 client pool

typedef struct {                                         // client_pool_t 구조체
    int    maxfd;                                        // 감시 fd 중 최대값 (select 인자)
    fd_set read_set;                                     // 유지되는 감시 비트맵
    fd_set ready_set;                                    // select가 매번 결과 덮어쓰는 비트맵
    int    nready;                                       // select 반환값 ready fd 수 반환
    int    maxi;                                         // clientfd 배열 사용 최대 인덱스
    int    clientfd[FD_SETSIZE];                         // 슬롯별 fd, -1이면 빈슬롯임을 의미한다
    rio_t  clientrio[FD_SETSIZE];                        // 슬롯별 RIO 버퍼
} client_pool_t;

static int active_clients = 0;                           // 현재 접속 client 수

// pool 초기화
static void pool_init(int listenfd, client_pool_t *p) {
    p->maxi = -1;                                        // 아직 슬롯 사용 안했음 표시
    for (int i = 0; i < FD_SETSIZE; i++) p->clientfd[i] = -1;
    p->maxfd = listenfd;                                 // 처음엔 listenfd만 감시
    FD_ZERO(&p->read_set);                               // read_set 전부 0
    FD_SET(listenfd, &p->read_set);                      // listenfd 비트만 1로 설정
}

// 새 client를 pool에 등록
static void pool_add(int connfd, client_pool_t *p) {
    p->nready--;                                         // listenfd 처리했으니 카운터 감소
    for (int i = 0; i < FD_SETSIZE; i++) {               // 빈 슬롯 찾기
        if (p->clientfd[i] < 0) {                        // -1이면 빈 슬롯
            p->clientfd[i] = connfd;                     // 새로 연결된 fd 저장
            Rio_readinitb(&p->clientrio[i], connfd);     // 그 fd 전용 RIO 버퍼 초기화
            FD_SET(connfd, &p->read_set);                // read_set에 추가
            if (connfd > p->maxfd) p->maxfd = connfd;    // maxfd 갱신
            if (i > p->maxi)       p->maxi  = i;         // maxi 갱신
            active_clients++;                            // 접속자 카운터 증가
            return;
        }
    }
    app_error("pool_add error: too many clients");       // 슬롯 다 차면 에러
}

// client 연결 종료. 마지막 client면 자동 save
static void pool_remove(int i, client_pool_t *p) {
    Close(p->clientfd[i]);                               // 소켓 닫음
    FD_CLR(p->clientfd[i], &p->read_set);                // read_set에서 제거
    p->clientfd[i] = -1;                                 // 슬롯 비움
    active_clients--;                                    // 접속자 카운터 감소
    if (active_clients == 0) write_stockfile();          // 마지막 client였으면 stock.txt에 결과 저장
}

// ready된 client들 처리 (한 번에 한 줄씩 클라이언트들 처리)
static void process_pool(client_pool_t *p) {
    char buf[MAXLINE], response[MAXLINE];

    for (int i = 0; (i <= p->maxi) && (p->nready > 0); i++)
     {
        int connfd = p->clientfd[i];
        if (connfd < 0) continue;                        // 빈 슬롯이면 skip
        if (!FD_ISSET(connfd, &p->ready_set)) continue;  // ready 아닌 fd면 skip

        p->nready--;

        // 한 줄 읽고 처리. 다음 명령은 다음 select 구간에서 처리함.
        ssize_t n = Rio_readlineb(&p->clientrio[i], buf, MAXLINE);
        if (n <= 0) 
        {                                    
            pool_remove(i, p);
            continue;
        }
        
        printf("server received %zu bytes\n%s", strlen(buf), buf);

        if (strncmp(buf, "exit", 4) == 0) {      // exit 명령
            pool_remove(i, p);
            continue;
        }
        dispatch_command(buf, response);       //요청된 각 명령 처리
        Rio_writen(connfd, response, MAXLINE);    
    }
}

// sigint 핸들러 처리
static volatile sig_atomic_t shutdown_requested = 0;     // SIGINT 플래그

static void on_sigint(int sig) {// sigint 핸들러
    shutdown_requested = 1;                              // 플래그만 set
}

// main 루프
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <port>\n", argv[0]);
        exit(0);
    }

    // SIGINT 등록
    struct sigaction sa_int;
    sa_int.sa_handler = on_sigint;
    sigemptyset(&sa_int.sa_mask);
    sa_int.sa_flags = 0;
    if (sigaction(SIGINT, &sa_int, NULL) < 0)
        unix_error("sigaction error");

    Signal(SIGPIPE, SIG_IGN);          // SIGPIPE 무시

    read_stockfile();                                    

    int listenfd = Open_listenfd(argv[1]);      // listening 소켓 생성
    static client_pool_t pool;                           
    pool_init(listenfd, &pool); //클라이언트 풀 초기화      

    while (!shutdown_requested) {          // 메인 루프
        pool.ready_set = pool.read_set;          // select가 ready_set 덮어쓰니 매번 복사
        pool.nready = select(pool.maxfd + 1, &pool.ready_set, NULL, NULL, NULL); // 새로운 클라이언트 접속 또는 기존 클라이언트 요청시 깨어남
        if (pool.nready < 0) {
            if (errno == EINTR) continue;                
            unix_error("select error");
        }

        if (FD_ISSET(listenfd, &pool.ready_set)) {       // 새 접속 요청시
            struct sockaddr_storage clientaddr;
            socklen_t clientlen = sizeof(clientaddr);
            int connfd = accept(listenfd, (SA *)&clientaddr, &clientlen);// 새로운 클라이언트 accept
            if (connfd < 0) {
                if (errno == EINTR) continue;
                unix_error("accept error");
            }
 
            char host[MAXLINE], port[MAXLINE];
            Getnameinfo((SA *)&clientaddr, clientlen, host, MAXLINE,
                        port, MAXLINE, 0);
            printf("Connected to (%s, %s)\n", host, port);  

            pool_add(connfd, &pool);                     // pool에 등록
        }

        process_pool(&pool);                             // 기존 client들 명령 처리
    }

    write_stockfile();                                   // 종료후 최종 저장
    tree_destroy(root);                                
    return 0;
}