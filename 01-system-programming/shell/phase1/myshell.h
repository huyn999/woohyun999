#ifndef MYSHELL_H   
#define MYSHELL_H
 

#include "csapp.h"   // 외부 라이브러리 헤더

// 상수 정의
#define MAXARGS  128   //argv[] 배열의 최대 원소 수
#define MAXJOBS  100   //job 테이블(jobs[])에 동시에 존재할 수 있는 최대 job 수
                      

// job_t 구조체의 state 필드에 저장되는 값들
#define UNDEF  0   // 미정의 / 빈 슬롯: 이 job 슬롯은 사용 중이 아님 (clearjob 초기값)
#define FG     1   // 포그라운드: 셸이 waitfg()로 대기 중인 job, 터미널 제어권 보유
#define BG     2   // 백그라운드: 셸이 기다리지 않는 job ('&'로 실행 또는 bg 명령)
#define ST     3   // 정지됨: SIGTSTP(Ctrl+Z) 또는 SIGSTOP을 받아 일시정지된 상태
#define DONE   4   // 종료 완료: BG job이 정상 종료됨, 다음 프롬프트에서 Done 메시지 출력 후 삭제
#define TERM   5   // 시그널 종료: BG job이 시그널로 종료됨, 다음 프롬프트에서 Terminated 메시지 출력 후 삭제

/* job_t 구조체
   셸이 관리하는 "job" 하나를 표현한다.
   단일 명령어 하나도, 파이프라인 전체(예: ls | grep a | sort)도 모두 하나의 job으로 관리됨
*/
typedef struct job_t {
    pid_t pid;              //프로세스 그룹 ID(pgid)
    int   jid;              // job id: [1..MAXJOBS] 범위의 사용자 표시용 번호             
    int   state;            //현재 상태: FG / BG / ST / DONE / TERM / UNDEF 
    char  cmdline[MAXLINE]; //사용자가 입력한 원본 명령어 문자열            
    int   nprocs;           // 이 job을 구성하는 자식 프로세스 총 수   
    int   nfin;             //현재까지 종료(exit/signal)된 자식 수
    int   last_active;      // +/- 마커용: 가장 최근에 정지/BG된 job이 + 표시
    char  mark;              // +/- 마커 저장용
} job_t;




// 셸 관련 함수 

void   eval(char *cmdline);               // 입력 한 줄을 받아 파이프/builtin/외부명령 분기 후 실행
int    parseline(char *buf, char **argv);  // buf를 토큰화하여 argv[] 생성, bg 여부 반환
int    builtin_command(char **argv);       // 내장 명령어이면 1, 아니면 0 반환 
void   exec_pipe(char *cmdline, int n, char ***cmds, int bg); // 파이프라인 n개 명령 실행
void   waitfg(pid_t pgid);                // FG job 종료/정지까지 sigsuspend 대기


// Job 관리 함수 프로토타입
void   clearjob(job_t *job);              // job 슬롯 초기화 (모든 필드 0)
void   initjobs(job_t *jobs);             // jobs[] 배열 전체 clearjob
int    addjob(job_t *jobs, pid_t pid, int state, char *cmdline, int nprocs); // 새 job 등록
int    deletejob(job_t *jobs, pid_t pid); // pid에 해당하는 job 제거
pid_t  fgpid(job_t *jobs);               // 현재 FG job의 pgid 반환 (없으면 0)
job_t *getjobpid(job_t *jobs, pid_t pid); // pgid로 job 검색 (없으면 NULL)
job_t *getjobjid(job_t *jobs, int jid);   // jid로 job 검색 (없으면 NULL)
void   listjobs(job_t *jobs);             // BG/ST 상태의 job 목록 출력


// main()에서 Signal()로 등록, 커널에 의해 비동기적으로 호출
void sigchld_handler(int sig);   // SIGCHLD: 자식 종료/정지 시 waitpid로 회수 + job 상태 갱신
void sigint_handler(int sig);    // SIGINT(Ctrl+C): FG job 그룹에 Kill(-pgid, SIGINT) 전달
void sigtstp_handler(int sig);   // SIGTSTP(Ctrl+Z): FG job 그룹에 Kill(-pgid, SIGTSTP) 전달

#endif