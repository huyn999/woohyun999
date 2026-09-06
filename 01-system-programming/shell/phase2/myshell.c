#include "myshell.h"


// 전역변수들 선언
job_t job_list[MAXJOBS];       // job 테이블 배열. 인덱스 0 ~ MAXJOBS-1, 빈 슬롯은 pid == 0으로 표시됨
int   next_jid = 1;            // jid 순차 할당용, 모든 job이 비면 1로 리셋
static int active_seq = 0;    // +/- 마커용 순서 카운터, job이 ST/BG가 될 때마다 증가
char  home_dir[PATH_MAX];      // 셸 시작 위치의 절대 경로, "cd ~" 또는 "cd"(인수 없음) 실행 시 이동할 디렉토리, main()에서 getcwd()로 초기화

/* 
   pid → pgid 매핑 테이블

   파이프라인 "ls | grep a"에서 ls(pid=100)와 grep(pid=101)은
   모두 pgid=100(첫 자식=그룹 리더)을 공유한다.
   sigchld_handler에서 waitpid()로 grep(pid=101)을 reap할 때,
   이 pid가 어떤 job에 속하는지 알려면 pgid가 필요하다.
   그런데 이미 프로세스가 사라진 후에는 getpgid(101)이
   -1을 반환한다(ESRCH 에러)
   따라서 fork() 직후에 (pid, pgid) 쌍을 이 테이블에 미리 저장하고,
   reap 후에도 pgid를 안전하게 조회할 수 있도록 한다.
 */

#define MAXPIDS 256  // 매핑 테이블의 최대 항목 수

// 테이블 구조: (pid, pgid) 쌍의 배열로 파이프라인에서 pid로 pgid 찾게함
static struct { pid_t pid; pid_t pgid; } proc_group_map[MAXPIDS];

static int proc_map_cnt = 0;   // 현재 매핑 테이블에 저장된 항목 수

/* 
   pgmap_insert: 새 (pid, pgid) 쌍을 테이블에 추가
   fork() 직후에 호출하여 자식의 pid와 소속 pgid를 기록
  */
static void pgmap_insert(pid_t pid, pid_t pgid) 
{
    if (proc_map_cnt < MAXPIDS) {        // 테이블에 공간이 남아 있으면
        proc_group_map[proc_map_cnt].pid  = pid;   // pid 저장
        proc_group_map[proc_map_cnt].pgid = pgid;  // 소속 pgid 저장
        proc_map_cnt++;                             // 항목 수 증가
    }
}

/* 
   pgmap_lookup: pid에 대응하는 pgid를 반환
   sigchld_handler에서 비-리더 자식의 pgid를 조회할 때 사용
    */
static pid_t pgmap_lookup(pid_t pid) {
    for (int i = 0; i < proc_map_cnt; i++)      
        if (proc_group_map[i].pid == pid)         // pid 일치 발견
            return proc_group_map[i].pgid;        // 대응하는 pgid 반환
    return -1;                                    
}

/* 
   pgmap_remove: pid 항목을 테이블에서 제거
   sigchld_handler에서 reap 완료 후 호출
    */
static void pgmap_remove(pid_t pid) {
    for (int i = 0; i < proc_map_cnt; i++) {
        if (proc_group_map[i].pid == pid) {
            proc_group_map[i] = proc_group_map[--proc_map_cnt];
            return;
        }
    }
}

 
//Job List 관리 함수
 

// clearjob - job 슬롯을 초기(UNDEF) 상태로 리셋, 모든 필드를 0/빈 문자열로 초기화
void clearjob(job_t *job)
{
    job->pid        = 0;          // pid=0 → 빈 슬롯 표시
    job->jid        = 0;
    job->state      = UNDEF;
    job->cmdline[0] = '\0';
    job->nprocs     = 0;
    job->nfin       = 0;
    job->last_active = 0;
    job->mark        = ' ';       
}

// initjobs - 셸 시작 시 job 테이블 전체 초기화
void initjobs(job_t *job_arr)
{
    for (int i = 0; i < MAXJOBS; i++)
        clearjob(&job_arr[i]);
}


/*  reassign_marks - 살아있는 ST/BG job에 '+'/'-' 마커 재배정
(호출시점)
   - 새 BG job 생성 (addjob)
   - FG→ST 전환 (sigchld_handler의 WIFSTOPPED)
   - bg 명령으로 BG 전환 (eval의 bg 블록)
   - job 정리 후 살아있는 job에 승계가 필요할 때 (deletejob / listjobs / main 루프 cleanup)

   
   (규칙)
   - 살아있는 ST가 있으면 가장 최근(last_active 최대)이 '+', 그 다음이 '-'
   - ST '+' 하나만 있으면 살아있는 BG 중 최근이 '-'
   - ST 없으면 살아있는 BG 중 1등 '+', 2등 '-'
   - TERM/DONE의 mark는 건드리지 않음 (죽기 전 값을 유지)
*/
static void reassign_marks(void)
{
    int plus_jid = 0, minus_jid = 0;                 // '+', '-'를 받을 jid
    int max_active, second_active;                   // 1등/2등 last_active 추적

    // 1단계: 살아있는 ST 중 last_active 최대값이 '+' 
    max_active = 0;
    for (int i = 0; i < MAXJOBS; i++) {
        if (job_list[i].pid == 0 || job_list[i].state == FG) continue;   // 빈 슬롯/FG 제외
        if (job_list[i].state != ST) continue;                            // ST만 후보
        int val = job_list[i].last_active;
        if (val > max_active) {
            max_active = val;
            plus_jid = job_list[i].jid;
        }
    }

    // 2단계: '+'가 ST로 결정된 경우 '-' 찾기 
    if (plus_jid != 0) {
        // 다른 ST에서 '-' 찾기 (ST끼리 우선 경쟁)
        max_active = 0;
        for (int i = 0; i < MAXJOBS; i++) {
            if (job_list[i].pid == 0 || job_list[i].state == FG) continue;
            if (job_list[i].jid == plus_jid) continue;                    // '+' 제외
            if (job_list[i].state != ST) continue;
            int val = job_list[i].last_active;
            if (val > max_active) {
                max_active = val;
                minus_jid = job_list[i].jid;
            }
        }
        // ST에서 '-'를 못 찾았으면 살아있는 BG에서 찾기 (TERM/DONE 제외)
        if (minus_jid == 0) {
            max_active = 0;
            for (int i = 0; i < MAXJOBS; i++) {
                if (job_list[i].pid == 0 || job_list[i].state == FG) continue;
                if (job_list[i].jid == plus_jid) continue;
                if (job_list[i].state != BG) continue;                    // 살아있는 BG만
                int val = job_list[i].last_active;
                if (val > max_active) {
                    max_active = val;
                    minus_jid = job_list[i].jid;
                }
            }
        }
    }

    //  3단계: ST 없으면 살아있는 BG 중 1등은 '+', 2등은  '-' 
    if (plus_jid == 0) {
        max_active = 0; second_active = 0;
        for (int i = 0; i < MAXJOBS; i++) {
            if (job_list[i].pid == 0 || job_list[i].state == FG) continue;
            if (job_list[i].state != BG) continue;                        // 살아있는 BG만
            int val = job_list[i].last_active;
            if (val > max_active) {
                // 새로운 1등 등장 , 기존 1등은 2등으로 강등
                second_active = max_active;
                minus_jid = plus_jid;
                max_active = val;
                plus_jid = job_list[i].jid;
            } else if (val > second_active) {
                // 1등은 아니지만 2등보다 크면 '-' 갱신
                second_active = val;
                minus_jid = job_list[i].jid;
            }
        }
    }

    // 살아있는 ST/BG job에만 mark 재설정 (TERM/DONE은 건드리지 않음)
    // TERM/DONE은 죽기 직전에 가졌던 mark를 그대로 유지해야 bash와 일치
    for (int i = 0; i < MAXJOBS; i++) {
        if (job_list[i].pid == 0 || job_list[i].state == FG) continue;
        if (job_list[i].state != ST && job_list[i].state != BG) continue; // TERM/DONE 스킵

        if (job_list[i].jid == plus_jid)       job_list[i].mark = '+';
        else if (job_list[i].jid == minus_jid) job_list[i].mark = '-';
        else                                    job_list[i].mark = ' ';
    }
}

/* 
   addjob - 새 job을 테이블에 추가

   <파라미터>
   pid     : 프로세스 그룹 ID (pgid)
   state   : FG 또는 BG
   cmdline : 사용자 입력 원본 문자열
   nprocs  : 이 job을 구성하는 자식 프로세스 수
   
 */
int addjob(job_t *job_arr, pid_t pid, int state, char *cmdline, int nprocs)
{
    if (pid < 1) return 0;   // 유효하지 않은 pid

    for (int i = 0; i < MAXJOBS; i++) {
        if (job_arr[i].pid == 0) {   // 빈 슬롯 발견

            // FG job은 jid를 할당하지 않고, BG job만 순차 할당 (bash 동작)
            int jid = (state == BG) ? next_jid++ : 0;

            // job 슬롯에 정보 저장
            job_arr[i].pid    = pid;
            job_arr[i].state  = state;
            job_arr[i].jid    = jid;
            job_arr[i].nprocs = nprocs;
            job_arr[i].nfin   = 0;        // 아직 종료된 자식 없음
            // BG job도 last_active를 설정하여 +/- 마커에서 최신 BG가 우선하도록 함
            job_arr[i].last_active = (state == BG) ? ++active_seq : 0;
            job_arr[i].mark        = ' ';  

            // cmdline 복사
            strncpy(job_arr[i].cmdline, cmdline, MAXLINE - 1);
            job_arr[i].cmdline[MAXLINE - 1] = '\0';

          
            int len = strlen(job_arr[i].cmdline);
            while (len > 0 && (job_arr[i].cmdline[len-1] == '\n' || 
                                job_arr[i].cmdline[len-1] == ' '))
                job_arr[i].cmdline[--len] = '\0';

            
            if (state == BG) {
                // trailing '&'와 공백 제거 후 ' &' 재추가
                while (len > 0 && (job_arr[i].cmdline[len-1] == '&' || 
                                    job_arr[i].cmdline[len-1] == ' '))
                    job_arr[i].cmdline[--len] = '\0';
                strcat(job_arr[i].cmdline, " &");
            }

            // 새 BG job 등록 후 마커 재배정
            // FG job은 마커 대상이 아니므로 BG일 때만 호출
            if (state == BG) reassign_marks();

            return 1;             
        }
    }
    fprintf(stderr, "Too many jobs\n");   
    return 0;
}

// deletejob - pid(pgid)에 해당하는 job을 테이블에서 제거, clearjob()으로 슬롯을 초기화하여 재사용 가능하게 만듦
int deletejob(job_t *job_arr, pid_t pid)
{
    if (pid < 1) return 0;
    for (int i = 0; i < MAXJOBS; i++) {
        if (job_arr[i].pid == pid) {
            clearjob(&job_arr[i]);   // 슬롯 초기화

            // 모든 job이 비었으면 jid를 1부터 다시 시작 
            int all_empty = 1;
            for (int k = 0; k < MAXJOBS; k++) {
                if (job_arr[k].pid != 0) { all_empty = 0; break; }
            }
            if (all_empty) next_jid = 1;

            reassign_marks();   // [수정] 삭제로 인해 비어버린 +/- 자리를 다른 살아있는 job에 승계
            return 1;
        }
    }
    return 0;   // 해당 pid의 job을 찾지 못함
}

// fgpid - 현재 포그라운드(FG) job의 pgid 반환, FG job이 없으면 0 반환
pid_t fgpid(job_t *job_arr)
{
    for (int i = 0; i < MAXJOBS; i++)
        if (job_arr[i].state == FG) return job_arr[i].pid;
    return 0;
}

// getjobpid - pgid로 job 검색, job 테이블에서 pid 필드가 일치하는 job 반환, 없으면 NULL
job_t *getjobpid(job_t *job_arr, pid_t pid)
{
    if (pid < 1) return NULL;
    for (int i = 0; i < MAXJOBS; i++)
        if (job_arr[i].pid == pid) return &job_arr[i];
    return NULL;
}

// getjobjid - jid로 job 검색, fg %1, bg %2, kill %3 등에서 사용, 없으면 NULL
job_t *getjobjid(job_t *job_arr, int jid)
{
    if (jid < 1) return NULL;
    for (int i = 0; i < MAXJOBS; i++)
        if (job_arr[i].jid == jid) return &job_arr[i];
    return NULL;
}


//  get_job_mark - 저장된 +/- 마커 반환
static char get_job_mark(int jid)
{
    job_t *j = getjobjid(job_list, jid);   // jid로 job 찾기
    return j ? j->mark : ' ';               // 저장된 mark 반환, 없으면 공백
}


// listjobs - jobs 명령어 구현
 
void listjobs(job_t *job_arr)
{
    // max jid 찾기 
    int max_jid = 0;
    for (int i = 0; i < MAXJOBS; i++)
        if (job_arr[i].jid > max_jid) max_jid = job_arr[i].jid;

    // jid 오름차순으로 출력
    for (int jid = 1; jid <= max_jid; jid++)
    {
        job_t *j = getjobjid(job_arr, jid);
        if (j == NULL) continue;
        if (j->state == FG) continue;

        printf("[%d]%c  ", j->jid, j->mark);   //  get_job_mark 호출 대신 저장된 mark 직접 사용
        switch (j->state) {
            case BG:   printf("%-24s", "Running"); break;
            case ST:   printf("%-24s", "Stopped"); break;
            case DONE: printf("%-24s", "Done"); break;
            case TERM: printf("%-24s", "Terminated"); break;
            default:   printf("Unknown\t\t"); break;
        }
        printf("%s\n", j->cmdline);
    }

    // 출력 완료 후 DONE/TERM job 일괄 정리 (출력 중간에 clear하면 마커 계산이 꼬여서 +가 중복될 수 있음)
    int cleared = 0;   
    for (int jid = 1; jid <= max_jid; jid++) {
        job_t *j = getjobjid(job_arr, jid);
        if (j != NULL && (j->state == TERM || j->state == DONE)) {
            clearjob(j);
            cleared = 1;   //  정리 필요 플래그
        }
    }
    if (cleared) reassign_marks();   // 정리됐으면 살아있는 job에 마커 승계
}

/* 
   parseline
   명령어 입력 한 줄(buf)을 토큰화하여 argv[]를 채운다.
*/
int parseline(char *buf, char **argv)
{
    
    int   argc = 0;      // 현재까지 파싱된 인수 개수
    int   bg   = 0;      // 백그라운드 플래그: 1=BG, 0=FG

    if (strlen(buf) == 0) {
        argv[0] = NULL;
        return 0;
    }

    /* 마지막 문자('\n')를 공백으로 교체
       모든 토큰이 공백으로 끝나는 일관된 구조가 됨 */
    buf[strlen(buf) - 1] = ' ';

    // 선행 공백 건너뜀
    while (*buf == ' ') buf++;

    // 토큰 분리 루프
    while (*buf && *buf != '\0') {
        if (*buf == '\"') {
            // 따옴표 토큰
            buf++;                         // 여는 따옴표(") 건너뜀
            argv[argc++] = buf;            // 토큰 시작 주소 저장
            char *closing = strchr(buf, '\"');   // 닫는 따옴표 찾기
            if (closing) {
                *closing = '\0';                 // 닫는 따옴표를 널로 교체 , 토큰 종료
                buf = closing + 1;               // 다음 위치로 이동
            }
            else {
                buf += strlen(buf);        // 닫는 따옴표 없으면 끝까지 토큰
            }
        } else {
            // 일반 토큰
            argv[argc++] = buf;            // 토큰 시작 주소 저장
            char *space = strchr(buf, ' ');   // 다음 공백(토큰 종료) 찾기
            if (!space) break;                // 공백 없으면 마지막 토큰
            *space = '\0';                    // 공백을 널로 교체,토큰 종료
            buf = space + 1;                  // 다음 토큰 시작 위치
        }
        while (*buf == ' ') buf++;         // 연속 공백 건너뜀
    }

    argv[argc] = NULL;   

    if (argc == 0) return 0;   // 토큰이 하나도 없으면 FG 반환

    // '&' 처리 1: 마지막 인수가 단독 '&'인 경우
    if (*argv[argc - 1] == '&' && strlen(argv[argc - 1]) == 1) {
        argv[--argc] = NULL;   // '&'를 argv에서 제거
        bg = 1;                // 백그라운드 플래그 설정
    }

    // '&' 처리 2: 토큰에 '&'가 붙어있는 경우 (예: sleep10&)
    for (int i = 0; i < argc; i++) {
        char *amp = strchr(argv[i], '&');  // 토큰 내부에서 '&' 검색
        if (amp) {
            *amp = '\0';                   // '&' 위치를 널로 교체,토큰 분리
            bg   = 1;                      // 백그라운드 플래그 설정
            // '&'만 있던 토큰이 빈 문자열이 된 경우 argv에서 제거
            if (strlen(argv[i]) == 0) {
                for (int k = i; k < argc - 1; k++)
                    argv[k] = argv[k + 1]; // 뒤 토큰들을 한 칸씩 앞으로
                argv[--argc] = NULL;       // 마지막 슬롯 NULL로
                i--;                       // 현재 위치 재검사
            }
        }
    }

    return bg;   // 백그라운드 여부 반환
}

/* 
   safe_parseline

   parseline()은 buf 내부의 문자 주소를 argv[]에 직접 저장한다.
   따라서 buf가 스택에서 사라지면 argv[]는 댕글링 포인터가 된다.
   파이프라인 처리에서는 각 세그먼트의 argv[]가 exec_pipe()까지
   살아있어야 하므로, 호출자가 제공하는 persistent_buf에 복사하여
   수명을 보장한다.

*/
static void safe_parseline(char *src, char *persistent_buf, char **argv)
{

    strncpy(persistent_buf, src, MAXLINE - 2);
    persistent_buf[MAXLINE - 2] = '\0';   

    
    int len = (int)strlen(persistent_buf);
    while (len > 0 && (persistent_buf[len-1] == '\n' ||
                       persistent_buf[len-1] == '\r' ||
                       persistent_buf[len-1] == ' '))
        persistent_buf[--len] = '\0';

    /* parseline()은 buf[strlen(buf)-1]을 ' '로 덮어씀
       '\n'을 추가해서 실제 내용이 지워지지 않도록 보호 */
    persistent_buf[len] = '\n';

    // 토큰화 수행
    parseline(persistent_buf, argv);
}

/* 
   builtin_command - 내장 명령어 판별

   argv[0]이 내장 명령어이면 1 반환, 아니면 0 반환.
   실제 명령 실행은 eval()에서 담당
   */
int builtin_command(char **argv)
{
    if (!strcmp(argv[0], "quit")) exit(0);   // quit: 즉시 종료
    if (!strcmp(argv[0], "&"))    return 1;  // 단독 &: 무시 (내장으로 처리)
    if (!strcmp(argv[0], "exit")) return 0;  // exit: eval()에서 직접 처리
    if (!strcmp(argv[0], "cd"))   return 1;  // cd: 디렉토리 이동
    if (!strcmp(argv[0], "jobs")) return 1;  // jobs: job 목록 출력
    if (!strcmp(argv[0], "fg"))   return 1;  // fg: 포그라운드 전환
    if (!strcmp(argv[0], "bg"))   return 1;  // bg: 백그라운드 재개
    if (!strcmp(argv[0], "kill")) return 1;  // kill: job 강제 종료
    return 0;   // 내장 명령어가 아님 → 외부 명령어로 처리
}

//시그널 핸들러들 처리 


/* 
  sigchld_handler - SIGCHLD 수신 시 호출
   자식 프로세스의 상태 변화(종료/정지)를 처리
 */
void sigchld_handler(int sig) // 크게 자식 상태가 종료되냐 정지되냐에 따라서 처리 
{   
    pid_t child_pid;
    int   wstatus;
    int   old_errno = errno;   // errno 보존: 핸들러 내 시스템 콜이 errno를 바꿀 수 있음

    //WNOHANG 루프: 종료/정지된 모든 자식을 한 번에 회수
    while ((child_pid = waitpid(-1, &wstatus, WNOHANG | WUNTRACED)) > 0) // 반복하면서 모든 자식에 대해 회수하면서 반복 회수할 자식이 없다면 0을 반환해서 반복문을 탈출
    {
        // 자식 종료 (정상 또는 시그널에 의한 종료)
        if (WIFEXITED(wstatus) || WIFSIGNALED(wstatus))
        {
            // child_pid로 job 검색 (그룹 리더인 경우 바로 찾아짐)
            job_t *j = getjobpid(job_list, child_pid);
            if (j == NULL) // 비리더 자식일 경우 
            {
                // 비-리더 자식은 매핑 테이블에서 pgid 조회 후 job 검색
                pid_t pg = pgmap_lookup(child_pid);
                if (pg > 0) j = getjobpid(job_list, pg); // 다시 job을 찾는다
            }
            pgmap_remove(child_pid);   // 사용 완료된 매핑 항목 삭제

            if (j)// 리더 자식이라면 
            {
                if (j->state == FG) // 포그라운드 작업에 대해 수행한거라면 
                {
                    /* FG job 종료 처리
                       nfin 카운터를 증가시키고, 모든 자식이 종료되면 job 삭제
                       파이프라인에서 자식 하나만 끝나도 바로 삭제하면
                       waitfg()가 조기 리턴하는 버그가 발생하므로 카운터 필요 */
                    j->nfin++;
                    if (j->nfin >= j->nprocs)  // 모든 자식 종료 완료시
                    {
                       
                        if (WIFSIGNALED(wstatus))
                            printf("\n");  
                        deletejob(job_list, j->pid);   // job 삭제 -> waitfg 깨어남 (내부에서 reassign_marks 호출됨)
                    }
                } else { // 백그라운드 작업에 대해 수행
                    // BG/ST job 종료 처리
                    j->nfin++;
                    if (j->nfin >= j->nprocs) { // 모든 자식 종료 완료
                        
                        if (WIFSIGNALED(wstatus)) // 시그널 종료(kill)
                            j->state = TERM;  // TERM 상태로 전환
                        else
                            j->state = DONE;   //정상 종료 이후 DONE 상태
                        
                    }
                }
            }

        }
        // 자식 정지 (Ctrl+Z, kill -STOP 등) 포그라운드 작업에 대해서만 수행
        else if (WIFSTOPPED(wstatus)) {
            // child_pid로 직접 job 검색 (그룹 리더인 경우)
            job_t *j = getjobpid(job_list, child_pid);
            if (j) { // 그룹 리더가 정지된 경우
                if (j->state == FG) 
                {
                    /* FG job이 정지 후 ST 상태로 전환
                       waitfg()의 루프 조건(j->state != FG)을 통해 깨어남 */
                    j->state = ST;
                    // FG job은 jid=0이므로, 정지될 때 jid 할당
                    if (j->jid == 0) j->jid = next_jid++;
                    j->last_active = ++active_seq; // 가장 최근 정지된 job은 + 마커
                    reassign_marks();              // ST 전환 후 마커 재배정 (새로 정지된 job이 + 차지)
                    printf("\n[%d]%c  %-24s%s\n", j->jid, j->mark, "Stopped", j->cmdline);   
                    fflush(stdout);
                }
            } else {
                // 비-리더 자식이 정지됨, pgid 조회 후 job 상태 변경
                pid_t pg = pgmap_lookup(child_pid); // 비리더 자식이므로 pid를 통해서 그룹 pid를 구한다
                if (pg < 0) pg = getpgid(child_pid);   // 매핑 없으면 시스템 콜 fallback
                if (pg > 0) {
                    job_t *jg = getjobpid(job_list, pg); // 그룹 pid로 job을 찾음 
                    if (jg && jg->state == FG) {
                        jg->state = ST;
                        if (jg->jid == 0) jg->jid = next_jid++;
                        jg->last_active = ++active_seq;
                        reassign_marks();                 //  ST 전환 후 마커 재배정
                        printf("\n[%d]%c  %-24s%s\n", jg->jid, jg->mark, "Stopped", jg->cmdline);   // [수정] 저장된 mark 사용
                        fflush(stdout);
                    }
                }
            }
        }
    }

    errno = old_errno;   // errno 복원: 핸들러가 변경한 errno를 원래 값으로 되돌림
}

/* 
   sigint_handler - Ctrl+C 처리

   터미널에서 Ctrl+C를 누르면 커널이 포그라운드 프로세스 그룹에
   SIGINT를 보내지만, setpgid()로 자식을 별도 그룹으로 분리했으므로
   셸이 직접 자식 그룹에 SIGINT를 전달해야 함 

   Kill(-pgid, SIGINT): 음수 pid -> pgid 그룹 전체에 시그널 전송
*/
void sigint_handler(int sig)
{
    pid_t fg_pgid = fgpid(job_list);   // 현재 FG job의 pgid 조회
    if (fg_pgid > 0) {
        Kill(-fg_pgid, SIGINT);    // 프로세스 그룹 전체에 SIGINT 전송
    }
}

/* 
   sigtstp_handler - Ctrl+Z 처리

   Ctrl+Z는 셸이 SIGTSTP를 FG job 프로세스 그룹에 전달.
   자식들이 SIGTSTP를 받으면 정지 ->SIGCHLD가 부모(셸)에게 전달됨
   ->sigchld_handler에서 job 상태를 ST로 변경
   -> 부모 셸의 waitfg()가 깨어남
*/
void sigtstp_handler(int sig)
{
    pid_t fg_pgid = fgpid(job_list);   // 현재 FG job의 pgid 조회
    if (fg_pgid > 0) {
        Kill(-fg_pgid, SIGTSTP);   // 프로세스 그룹 전체에 SIGTSTP 전송
    }
}

/*
   waitfg - 포그라운드 job 대기
   pgid로 식별되는 FG job이 완전히 종료되거나 정지(ST)될 때까지 대기.
*/
void waitfg(pid_t pgid)
{
    sigset_t blk_mask, susp_mask;

    // blk_mask: SIGCHLD만 블록하는 마스크
    sigemptyset(&blk_mask);
    sigaddset(&blk_mask, SIGCHLD);

    // susp_mask: sigsuspend에서 사용할 마스크
    
    sigfillset(&susp_mask);           // 모든 시그널 블록으로 초기화
    sigdelset(&susp_mask, SIGCHLD);   // SIGCHLD 허용
    sigdelset(&susp_mask, SIGINT);    // SIGINT 허용
    sigdelset(&susp_mask, SIGTSTP);   // SIGTSTP 허용

    // SIGCHLD 블록 후 루프 진입
    // while 루프에서 조건 체크하는 동안 SIGCHLD가 끼어들지 못하게 막음. 안 막으면 조건 체크와 sigsuspend 사이에 SIGCHLD가 도착해서 영원히 잠드는 race condition.
    sigprocmask(SIG_BLOCK, &blk_mask, NULL);
    // sigsuspend는 호출할 때 임시로 마스크를 바꾸고(SIGCHLD 허용), 반환할 때 원래 마스크로 자동 복원(SIGCHLD 블록).
    // 그래서 깨어난 후 while 조건 체크하는 동안에는 항상 SIGCHLD가 블록된 상태라서 틈이 없는 거

    while (1) { // 자식이 종료되거나 정지될때까지 suspend가 유지될 수 있게한다 조건 만족시에는 반복문을 탈출
        job_t *j = getjobpid(job_list, pgid);
        if (j == NULL) break;       // job이 삭제됨, 모든 자식 종료 완료
        if (j->state != FG) break;  // FG가 아님 ,Ctrl+Z로 ST가 됨

       
        sigsuspend(&susp_mask); // 이거 자체는 자식하나가 정지되거나 죽을때마다 깨어나는데 while 문에 의해서 조건 미충족지 다시 잠든다
    }

    // SIGCHLD 블록 해제 
    sigprocmask(SIG_UNBLOCK, &blk_mask, NULL);
}

/* 
   exec_pipe - 파이프라인 실행
   cmd[0] | cmd[1] | ... | cmd[n-1]

   1. n개의 자식을 fork()
   2. 모두 같은 프로세스 그룹(pgid = 첫 자식 pid)에 넣음
   3. 인접 명령어 사이에 pipe()로 연결
   4. 파이프라인 전체를 하나의 job으로 등록 (nprocs = n)

*/
void exec_pipe(char *cmdline, int n, char ***cmd, int bg)
{
    pid_t group_id = 0;    // 파이프라인 프로세스 그룹의 pgid, 첫 자식 fork 후 그 pid로 결정됨
    int   prev_fd  = -1;   // 이전 파이프의 읽기 끝 fd, -1이면 아직 파이프가 없음 (첫 명령어)
    int   pipefd[2];       // pipe()가 채울 [읽기fd, 쓰기fd]

    // SIGCHLD 블록: fork()~addjob() 구간 보호 (eval과 동일한 이유)
    sigset_t sig_mask, prev_mask;
    sigemptyset(&sig_mask);
    sigaddset(&sig_mask, SIGCHLD);
    sigprocmask(SIG_BLOCK, &sig_mask, &prev_mask);

    // n개의 명령어에 대해 각각 fork
    for (int i = 0; i < n; i++)
    {
        /* 마지막 명령이 아닌 경우: 다음 명령으로 연결할 파이프 생성
           pipefd[0]: 읽기 끝 (다음 자식의 stdin이 될 것)
           pipefd[1]: 쓰기 끝 (현재 자식의 stdout이 될 것) */
        if (i < n - 1) { // n-1개만 파이프를 만든다, 마지막에는 굳이 파이프를 만들 필요가 없다 바로 명령어의 결과를 출력
            if (pipe(pipefd) < 0) { perror("pipe"); exit(1); } // 새로운 파이프를 만듬 fd 배열 달라짐 
        }

        pid_t child = fork();
        if (child < 0) { perror("fork"); exit(1); }

        if (child == 0) {
            
            // 자식 프로세스 코드/
             

            // 시그널 마스크 복원 + 핸들러를 기본 동작으로
            sigprocmask(SIG_SETMASK, &prev_mask, NULL); // 자식은 독립적인 프로세스이므로
            Signal(SIGINT,  SIG_DFL);
            Signal(SIGTSTP, SIG_DFL);
            Signal(SIGCHLD, SIG_DFL);
            Signal(SIGTTIN, SIG_DFL);
            Signal(SIGTTOU, SIG_DFL);

            /* 프로세스 그룹 설정:
               i==0 (첫 자식): 자신이 새 그룹 리더 ->setpgid(0,0)
               i>0 (이후 자식): group_id 그룹에 합류 ->setpgid(0,group_id) */
            if (group_id == 0) setpgid(0, 0);          // 자기 pid = 새 pgid
            else               setpgid(0, group_id);   // 기존 pgid 그룹에 현재 pid가 합류

            //stdin 리다이렉션: 이전 파이프의 읽기 끝(prev_fd)을 표준 입력(fd 0)으로 복사 
            if (prev_fd != -1) 
            {
                dup2(prev_fd, STDIN_FILENO);   // prev_fd ->fd 0
                close(prev_fd);                // 원본 fd 닫기 (fd 누수 방지)
            }

            //stdout 리다이렉션: 마지막 명령이 아닌 경우, 파이프 쓰기 끝을 stdout으로 복사
            if (i < n - 1) {
                close(pipefd[0]);                    // 읽기 끝은 자식이 안 쓰므로 닫음
                dup2(pipefd[1], STDOUT_FILENO);      // pipefd[1] -> fd 1 (stdout)
                close(pipefd[1]);                    // 원본 fd 닫기
            }
            // 마지막 명령(i == n-1): stdout은 그대로 터미널

            // 파이프라인 내 내장 명령어 처리 (서브셸에서 실행, 부모 셸에 영향 없음)
       
            if (!strcmp(cmd[i][0], "fg")) {
                fprintf(stderr, "bash: fg: no job control\n");
                exit(1);
            }
            if (!strcmp(cmd[i][0], "bg")) {
                fprintf(stderr, "bash: bg: no job control\n");
                exit(1);
            }
            if (!strcmp(cmd[i][0], "cd") || !strcmp(cmd[i][0], "exit") ||
                !strcmp(cmd[i][0], "quit") || !strcmp(cmd[i][0], "kill") ||
                !strcmp(cmd[i][0], "&")) {
                exit(0);   // 서브셸에서 의미 없는 내장은 정상 종료
            }
            if (!strcmp(cmd[i][0], "jobs")) 
            {
                listjobs(job_list);   
                exit(0);
            }

            // 실제 명령 실행
            if (execvp(cmd[i][0], cmd[i]) < 0) { // execvp는 코드, 변수, 스택을 새 프로그램으로 교체하지만, fd 테이블은 그대로 유지
                fprintf(stderr, "%s: Command not found.\n", cmd[i][0]);
                exit(1); 
            }
        }

        
        //부모(셸) 프로세스 코드 (for 루프 내부)
          

        if (i == 0) {
            // 첫 번째 자식은 group_id 결정 및 그룹 리더 설정
            group_id = child;              // 이 pid가 전체 파이프라인의 pgid
            setpgid(child, child);         // race condition 방지
        } else {
            // 이후 자식들은 이미 결정된 group_id 그룹에 합류
            setpgid(child, group_id);
        } 

        // pid->pgid 매핑 저장, sigchld_handler에서 비-리더 자식 reap 시 pgid 조회용
        pgmap_insert(child, group_id);

        /* 이전 파이프 읽기 끝(prev_fd) 닫기
           자식에게 dup2로 넘겼으므로 부모에서는 불필요
           닫지 않으면 다음 fork 할때 자식이 불필요한 선들이 물려받아서 문제가 생길 수 있다 */
        if (prev_fd != -1) close(prev_fd);

        // 다음 반복을 위한 prev_fd 업데이트
        if (i < n - 1) 
        {
            close(pipefd[1]);       /* 쓰기 끝: 자식에게 넘겼으므로 부모에서 닫음
                                       안 닫으면 다음 자식이 EOF를 못 받음 */
            prev_fd = pipefd[0];    // 읽기 끝: 다음 자식의 stdin으로 사용
        }
         else {
            prev_fd = -1;          // 마지막 명령: 더 이상 파이프 불필요
        }
    }

    if (prev_fd != -1) close(prev_fd);

    // 파이프라인 전체를 하나의 job으로 등록, pid = group_id (그룹 리더), nprocs = n (자식 수)
    addjob(job_list, group_id, bg ? BG : FG, cmdline, n);

    // SIGCHLD 블록 해제
    sigprocmask(SIG_SETMASK, &prev_mask, NULL); // 부모에서 add 차일드 후에 차일드 블록을 풀어야 안꼬인다.

    if (!bg) 
    {
        // 포그라운드: 터미널 제어권을 파이프라인 그룹에 넘기고 대기
        tcsetpgrp(STDIN_FILENO, group_id); 
        waitfg(group_id); // 포그라운드에서 기다리는 명령어 실행
        tcsetpgrp(STDIN_FILENO, getpgrp());   // 터미널 제어권 셸로 복원
    } else 
    {
        // 백그라운드: [jid] group_id 출력 후 즉시 복귀
        job_t *j = getjobpid(job_list, group_id);
        if (j) printf("[%d] %d\n", j->jid, group_id);
    }
}

// eval - 입력 한 줄을 받아 적절한 처리 경로로 분기

void eval(char *cmdline)
{
    char  *argv[MAXARGS];   // 파싱된 인수 배열 (토큰 포인터들)
    char   buf[MAXLINE];    // parseline()이 수정할 작업 버퍼, cmdline 원본을 보존하기 위해 복사본 사용
    int    bg;              // parseline()의 반환값: 1=백그라운드, 0=포그라운드
    pid_t  child_pid;       // fork()가 반환하는 자식 프로세스 ID
    sigset_t sig_mask, prev_mask;    // 시그널 마스크 변수 (SIGCHLD 블록용)

    strcpy(buf, cmdline);          // cmdline -> buf로 복사 (parseline이 buf를 수정함)
    bg = parseline(buf, argv);     // 토큰화 + 백그라운드 여부 판별
    if (argv[0] == NULL) return;   

    // exit 명령: 셸 즉시 종료
    if (!strcmp(argv[0], "exit")) exit(0);

    /* 
       파이프라인 처리
       cmdline에 '|' 문자가 하나라도 있으면 파이프라인으로 처리
       예: "ls | grep a | sort" ->3개의 세그먼트로 분리 후 exec_pipe() 호출
       */
    if (strchr(cmdline, '|')) 
    {
        char pipe_buf[MAXLINE];
        strcpy(pipe_buf, cmdline);   // 파이프 분리용 작업 복사본

        /* seg_buffers[i]: i번째 파이프 세그먼트의 영구 버퍼
           safe_parseline()이 여기에 문자열을 복사하고,
           argv 포인터들이 이 버퍼를 가리킴
           exec_pipe()가 끝날 때까지 스택에 살아있어야 함 */
        char   seg_buffers[MAXARGS][MAXLINE];
        char **seg_argv[MAXARGS];         // seg_argv[i]: i번째 세그먼트의 argv[] 배열
        char  *start = pipe_buf;          // 현재 세그먼트 시작 위치
        char  *end;                       // '|' 위치
        int    i = 0;                     // 세그먼트 인덱스

        // '|'를 구분자로 세그먼트 분리
        while ((end = strchr(start, '|')) != NULL)
        {
            *end = '\0';   // '|'를 널 문자로 → 현재 세그먼트 종료
            seg_argv[i] = malloc(MAXARGS * sizeof(char *));   // argv 배열 동적 할당
            safe_parseline(start, seg_buffers[i], seg_argv[i]);  // 세그먼트 파싱
            start = end + 1;   // 다음 세그먼트 시작 위치
            i++;
        }
        // 마지막 세그먼트 처리 (뒤에 '|'가 없음)
        seg_argv[i] = malloc(MAXARGS * sizeof(char *));
        safe_parseline(start, seg_buffers[i], seg_argv[i]);

        // 파이프라인 실행: i+1개의 명령어
        exec_pipe(cmdline, i + 1, seg_argv, bg);

        // 동적 할당한 argv 배열들 해제 
        for (int j = 0; j <= i; j++) free(seg_argv[j]);
        return;
    }

      /* 
       내장 명령어 처리: eval() 내에서 직접 처리 (fork 불필요)
       */
    if (builtin_command(argv)) 
    {
        // cd: 디렉토리 이동
        if (!strcmp(argv[0], "cd")) {
            if (argv[1] == NULL || !strcmp(argv[1], "~")) {
                // 인수 없거나 "~": 셸 시작 디렉토리로 이동
                if (chdir(home_dir) != 0)
                    fprintf(stderr, "bash: cd: %s: No such file or directory\n", home_dir);
            } else {
                /* 지정된 경로로 이동
                   chdir(): 커널에 현재 작업 디렉토리 변경 요청
                   실패 시 errno가 설정됨 */
                if (chdir(argv[1]) != 0)
                    fprintf(stderr, "bash: cd: %s: No such file or directory\n", argv[1]);
            }
        }

        // jobs: 백그라운드/정지된 job 목록 출력
        else if (!strcmp(argv[0], "jobs")) {
            listjobs(job_list);
        }

        // fg %jid: 정지/백그라운드 job을 포그라운드로 전환
        else if (!strcmp(argv[0], "fg"))
        {
            
            if (argv[1] == NULL) { fprintf(stderr, "fg: requires job argument\n"); return; }

            // %N, [N], N 형식 모두 허용: 앞의 장식 문자 건너뜀
            char *job_arg = argv[1];
            while (*job_arg == '%' || *job_arg == '[' || *job_arg == ' ') job_arg++;
            
            int jid = atoi(job_arg);   
            job_t *j = getjobjid(job_list, jid);   // jid로 job 검색
            if (j == NULL) { fprintf(stderr, "bash: fg: %%%d: no such job\n", jid); return; }

            // 이미 종료된 job이면 에러 메시지 출력 후 정리
            if (j->state == TERM) {
                fprintf(stderr, "fg: job has terminated\n");
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Terminated", j->cmdline);  
                clearjob(j);
                reassign_marks();   //  job 정리 후 마커 승계
                return;
            }
            if (j->state == DONE) {
                fprintf(stderr, "fg: job has terminated\n");
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Done", j->cmdline);   
                clearjob(j);
                reassign_marks();    
                return;
            }
            
            // fg 전환 시 cmdline에서 trailing '&' 제거 
            {
                int len = strlen(j->cmdline);
                while (len > 0 && (j->cmdline[len-1] == '&' || j->cmdline[len-1] == ' '))
                    j->cmdline[--len] = '\0';
            }

            
            printf("%s\n", j->cmdline);
            fflush(stdout);   

            j->state = FG;    // job 상태를 FG로 변경
            reassign_marks(); // FG 전환 후 마커 재배정 (FG는 마커 대상 아니라 나머지 중에 재분배됨)
            
            // SIGCONT: 정지된 프로세스 그룹을 재개
            if (kill(-(j->pid), SIGCONT) < 0) {
                // 프로세스가 이미 사라진 경우
                deletejob(job_list, j->pid);
                tcsetpgrp(STDIN_FILENO, getpgrp());
                return;
            }

            /* tcsetpgrp: 터미널의 포그라운드 프로세스 그룹을 변경
               이래야 Ctrl+C/Z가 이 job에 전달됨 */
            tcsetpgrp(STDIN_FILENO, j->pid);

            // 셸이 job 완료/정지까지 대기
            waitfg(j->pid);

            // 터미널 포그라운드를 셸 자신의 프로세스 그룹으로 복원
            tcsetpgrp(STDIN_FILENO, getpgrp());
        }

        // bg %jid: 정지된 job을 백그라운드에서 재개
        else if (!strcmp(argv[0], "bg")) {
            if (argv[1] == NULL) { fprintf(stderr, "bg: requires job argument\n"); return; }
            char *job_arg = argv[1];
            while (*job_arg == '%' || *job_arg == '[' || *job_arg == ' ') job_arg++;
            int jid = atoi(job_arg);
            job_t *j = getjobjid(job_list, jid);
            if (j == NULL) { fprintf(stderr, "bash: bg: %%%d: no such job\n", jid); return; }

            if (j->state == TERM) {
                fprintf(stderr, "bg: job has terminated\n");
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Terminated", j->cmdline);   
                clearjob(j);
                reassign_marks();   // 정리 후 승계
                return;
            }
            if (j->state == DONE) {
                fprintf(stderr, "bg: job has terminated\n");
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Done", j->cmdline);   
                clearjob(j);
                reassign_marks();   
                return;
            }

            { 
                char _buf[MAXLINE];
                strncpy(_buf, j->cmdline, MAXLINE - 1);
                _buf[MAXLINE - 1] = '\0';
                int _len = strlen(_buf);
                
                while (_len > 0 && (_buf[_len-1] == '&' || _buf[_len-1] == ' '))
                    _buf[--_len] = '\0';
                printf("[%d]%c  %s &\n", j->jid, j->mark, _buf);   //  현재 저장된 mark로 출력 (bg 전환 전 시점)
            }
            fflush(stdout);

         
            {
                int len = strlen(j->cmdline);
                // 이미 &로 끝나는지 확인
                while (len > 0 && j->cmdline[len-1] == ' ') len--;
                if (len == 0 || j->cmdline[len-1] != '&') {
                    strcat(j->cmdline, " &");
                }
            }

            j->state = BG;            // 상태를 BG로 변경
            j->last_active = ++active_seq;  // bg 전환 시 last_active 갱신 
            reassign_marks();               // [수정] BG 전환 후 마커 재배정 (bg된 job이 상위로 올라갈 수 있음)
            if (kill(-(j->pid), SIGCONT) < 0) {
                deletejob(job_list, j->pid);
                return;
            }
        }

        // kill %jid: job 강제 종료
        else if (!strcmp(argv[0], "kill"))
        {
            if (argv[1] == NULL) { fprintf(stderr, "kill: requires job argument\n"); return; }
            char *job_arg = argv[1];
            while (*job_arg == '%' || *job_arg == '[' || *job_arg == ' ') job_arg++;
            int jid = atoi(job_arg);
            job_t *j = getjobjid(job_list, jid);
            if (j == NULL) { fprintf(stderr, "bash: kill: %%%d: no such job\n", jid); return; }

            //  kill 실행 전 pending된 완료 알림을 먼저 flush (대상 job 제외)
            int cleared = 0;   
            for (int i = 0; i < MAXJOBS; i++) {
                if (job_list[i].pid == 0 || job_list[i].pid == j->pid) continue;
                if (job_list[i].state == DONE) {
                    printf("[%d]%c  %-24s%s\n", job_list[i].jid, job_list[i].mark, "Done", job_list[i].cmdline);   // [수정] 저장된 mark
                    clearjob(&job_list[i]);
                    cleared = 1;   
                }
                if (job_list[i].state == TERM) {
                    printf("[%d]%c  %-24s%s\n", job_list[i].jid, job_list[i].mark, "Terminated", job_list[i].cmdline);   // [수정] 저장된 mark
                    clearjob(&job_list[i]);
                    cleared = 1;   
                }
            }
            if (cleared) reassign_marks();   //  pending flush로 정리됐으면 마커 승계

            // 이미 종료된 job이면 에러 출력 후 정리 
            if (j->state == TERM) {
                fprintf(stderr, "bash: kill: (%d) - No such process\n", j->pid);
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Terminated", j->cmdline);   
                clearjob(j);
                reassign_marks();   
                return;
            }
            if (j->state == DONE) {
                fprintf(stderr, "bash: kill: (%d) - No such process\n", j->pid);
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Done", j->cmdline);    
                clearjob(j);
                reassign_marks();   
                return;
            }

            //SIGTERM: 프로세스에게 종료를 요청하는 시그널 (bash의 kill 기본 동작) 
            // 정지된 프로세스는 SIGTERM을 바로 처리할 수 없으므로 먼저 SIGCONT로 깨운다
            if (j->state == ST) {
                printf("[%d]%c  %-24s%s\n", j->jid, j->mark, "Stopped", j->cmdline);   
                kill(-(j->pid), SIGCONT);
            }
            kill(-(j->pid), SIGTERM);  // 프로세스 그룹 전체에 SIGTERM
        }

        return;   // 내장 명령어 처리 완료 → eval() 종료
    }

    /*
    외부 명령어 실행 (파이프 없는 단일 명령)
    [SIGCHLD 블록이 필요한 이유]
    fork() 후 addjob() 전에 자식이 먼저 종료되면
    sigchld_handler가 deletejob()을 호출하여 아직 등록되지 않은
    job을 삭제하려 함 즉 race condition 발생
     따라서 SIGCHLD를 블록한 상태에서 fork()~addjob()을 수행 
     */
    sigemptyset(&sig_mask);                          // 빈 마스크 생성
    sigaddset(&sig_mask, SIGCHLD);                   // SIGCHLD만 추가
    sigprocmask(SIG_BLOCK, &sig_mask, &prev_mask);   // SIGCHLD 블록, 이전 마스크를 prev_mask에 저장

    if ((child_pid = fork()) == 0) 
    { // 자식 프로세스의 경우

        // 부모에서 블록한 SIGCHLD를 해제 (자식은 독립 프로세스)
        sigprocmask(SIG_SETMASK, &prev_mask, NULL); // 자식은 시그 차일드 블록을 할 이유가 없다

        /* 자식은 부모의 시그널 핸들러를 물려받으므로
           기본 동작(SIG_DFL)으로 복원해야 함
           그래야 Ctrl+C가 자식을 정상적으로 종료시킴 */
        Signal(SIGINT,  SIG_DFL);   // Ctrl+C → 프로세스 종료
        Signal(SIGTSTP, SIG_DFL);   // Ctrl+Z → 프로세스 정지
        Signal(SIGCHLD, SIG_DFL);   // 자식의 자식 관련 기본 동작

        Signal(SIGTTIN, SIG_DFL);   // 터미널 읽기 관련 기본 동작
        Signal(SIGTTOU, SIG_DFL);   // 터미널 쓰기 관련 기본 동작

        /* setpgid(0, 0): 자기 자신을 새 프로세스 그룹의 리더로 만듦
           셸과 자식이 서로 다른 프로세스 그룹에 속하게 됨
         즉 Ctrl+C/Z가 셸에는 안 가고 자식 그룹에만 전달 가능 */
        setpgid(0, 0); // 자기 pid를 pgid로 설정한다

        /* execvp: argv[0]을 PATH에서 검색하여 현재 프로세스를 교체
           성공 시 반환하지 않음 (새 프로그램으로 완전히 교체됨)*/
        if (execvp(argv[0], argv) < 0) {
            fprintf(stderr, "%s: Command not found.\n", argv[0]);
            exit(1);
        }
    }

    //  부모(셸) 프로세스 코드

    /* race condition 방지: 자식이 setpgid(0,0) 하기 전에
       부모가 먼저 setpgid(pid,pid) 호출  */
    setpgid(child_pid, child_pid); // 자식의 pgid 설정

    /* job 테이블에 등록
       bg ? BG : FG → 백그라운드면 BG, 아니면 FG 상태
       nprocs=1: 단일 명령어이므로 자식 1개 */
    addjob(job_list, child_pid, bg ? BG : FG, cmdline, 1);   // 내부에서 BG이면 reassign_marks 호출됨

    // 그전에는 addjob 부분을 위헤서 시그 차일드 시그널을 블락함

    sigprocmask(SIG_SETMASK, &prev_mask, NULL); // SIGCHLD 블록 해제 이제부터 sigchld_handler가 호출될 수 있음

    if (!bg)  // 포그라운드 실행
    {
       
        tcsetpgrp(STDIN_FILENO, child_pid);        // 터미널 FG 그룹 ->자식
        waitfg(child_pid);                         // 자식 종료/정지까지 대기
        tcsetpgrp(STDIN_FILENO, getpgrp());        // 터미널 제어권 셸로 복원
    } 
    else { //백그라운드 실행

        // [jid] pid 형식으로 출력하고 즉시 프롬프트 복귀
        job_t *j = getjobpid(job_list, child_pid);
        if (j) printf("[%d] %d\n", j->jid, child_pid);
    }

}


 //  main - 셸의 진입점

int main(void)
{
    char cmdline[MAXLINE];   // fgets()로 읽을 입력 버퍼 

    /* 셸 시작 시점의 현재 작업 디렉토리를 home_dir에 저장
       이후 "cd ~" 또는 "cd" 실행 시 이 경로로 복귀 */
    if (getcwd(home_dir, sizeof(home_dir)) == NULL) 
    {
        perror("getcwd");   
        exit(1);           
    }

    // job 테이블의 모든 슬롯을 UNDEF 상태로 초기화
    initjobs(job_list);

    /* 시그널 핸들러 등록 
       Signal()은 CS:APP 래퍼로, 내부적으로 sigaction()을 사용
       SA_RESTART 플래그를 설정하여 시그널에 의해 중단된 시스템 콜을 자동 재시작 */
    Signal(SIGINT,  sigint_handler);   // Ctrl+C ->포그라운드 job에 SIGINT 전달
    Signal(SIGTSTP, sigtstp_handler);  // Ctrl+Z ->포그라운드 job에 SIGTSTP 전달
    Signal(SIGCHLD, sigchld_handler);  // 자식 상태 변화(종료/정지) -> reap 처리

    /* 셸 자신이 터미널 I/O 시그널로 정지되지 않도록 무시
       SIGTTIN: 백그라운드에서 터미널 읽기 시도 시 발생
       SIGTTOU: 백그라운드에서 터미널 쓰기 시도 시 발생 */
    Signal(SIGTTIN, SIG_IGN);
    Signal(SIGTTOU, SIG_IGN);

    // 메인 루프
    while (1) 
    {

        // 프롬프트 출력
        printf("CSE4100-SP-P2> ");
        fflush(stdout);   

        if (fgets(cmdline, MAXLINE, stdin) == NULL) // 사용자 입력 읽기
        {
            printf("\n");   
            exit(0);        
        }

        // 읽은 명령어 평가/실행
        eval(cmdline);

        /* DONE/TERM 상태인 BG job들의 완료 메시지 출력 후 삭제
        */
        int cleared = 0; //정리 플래그
        for (int i = 0; i < MAXJOBS; i++) {
            if (job_list[i].state == DONE) {
                printf("[%d]%c  %-24s%s\n", job_list[i].jid, job_list[i].mark, "Done", job_list[i].cmdline);   // [수정] 저장된 mark
                clearjob(&job_list[i]);
                cleared = 1;   
            }
            if (job_list[i].state == TERM) {
                printf("[%d]%c  %-24s%s\n", job_list[i].jid, job_list[i].mark, "Terminated", job_list[i].cmdline);   // [수정] 저장된 mark
                clearjob(&job_list[i]);
                cleared = 1;   
            }
        }
        if (cleared) reassign_marks();   

        // 모든 job이 비었으면 jid를 1부터 다시 시작
        {
            int all_empty = 1;
            for (int i = 0; i < MAXJOBS; i++)
                if (job_list[i].pid != 0) { all_empty = 0; break; }
            if (all_empty) next_jid = 1;
        }
    }
    return 0;  
}