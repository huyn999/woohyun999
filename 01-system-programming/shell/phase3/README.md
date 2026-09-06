# MyShell

CSE4100 시스템 프로그래밍 프로젝트 2 - 리눅스 셸 구현


## 빌드 방법

make        # 빌드
./myshell   # 실행



## Phase 3 - 백그라운드 및 Job Control

### 사용 예시

백그라운드 실행 ('&' 붙이기):
CSE4100-SP-P2> sleep 100 &
[1] 12345
CSE4100-SP-P2> sleep 200 &
[2] 12346
CSE4100-SP-P2> echo hello | grep hello &
[3] 12347
hello


job 목록 확인:

CSE4100-SP-P2> jobs
[1] (12345) Running     sleep 100 &
[2] (12346) Running     sleep 200 &


BG job 종료 시 Done 메시지 (다음 프롬프트 직전에 표시):

CSE4100-SP-P2> sleep 1 &
[1] 12350
CSE4100-SP-P2>              (1초 후 엔터)
[1] Done		sleep 1 &


Ctrl+C (포그라운드 job 종료):

CSE4100-SP-P2> sleep 100
^C
CSE4100-SP-P2>              (자식만 종료, 셸은 살아있음)


Ctrl+Z (포그라운드 job 정지):

CSE4100-SP-P2> sleep 100
^Z
[1] Stopped		sleep 100
CSE4100-SP-P2>              (자식 정지, 프롬프트 복귀)


fg 명령 (정지/백그라운드 job을 포그라운드로 전환):

CSE4100-SP-P2> fg %1
[1] running sleep 100
                            (sleep이 포그라운드에서 재개)


bg 명령 (정지된 job을 백그라운드에서 재개):

CSE4100-SP-P2> bg %1
[1] running sleep 100
CSE4100-SP-P2>              (즉시 프롬프트 복귀)


kill 명령 (job 강제 종료): terminated라는 메시지가 출력된 후에 jobs 명령어로 보이는 테이블에서 정리됨
CSE4100-SP-P2> kill %1



### 구현 설명

parseline()에서 명령줄 끝의 '&'를 감지하여 bg 플래그를 반환한다. 단독 '&'와 토큰에 붙은 '&'(예: sleep10&) 모두 처리한다. bg가 1이면 addjob()에서 BG 상태로 등록하고, tcsetpgrp()로 터미널 제어권을 넘기지 않으며 waitfg()도 호출하지 않아 "[jid] pid"를 출력한 후 즉시 프롬프트로 복귀한다.

 sigchld_handler는 waitpid(-1, ..., WNOHANG|WUNTRACED)를 while 루프로 호출하여 종료/정지된 모든 자식을 회수한다. 

 sigint_handler는 fgpid()로 FG job의 pgid를 찾아 Kill(-pgid, SIGINT)로 그룹 전체에 전달한다. 
 
 sigtstp_handler도 같은 방식으로 SIGTSTP를 전달한다.


BG job이 정상 종료되면 sigchld_handler에서 state를 DONE으로 전환만 하고, main()의 while 루프에서 다음 프롬프트 출력 전에 Done 메시지를 출력한다. 시그널 핸들러에서 직접 printf()를 하면 메인 루프의 출력과 충돌할 수 있기 때문이다.

jobs 명령은 BG/ST 상태의 job을 출력한다. fg 명령은 job 상태를 FG로 바꾸고 SIGCONT를 보낸 뒤 tcsetpgrp()로 터미널 제어권을 넘기고 waitfg()로 대기한다. bg 명령은 BG로 바꾸고 SIGCONT만 보낸다. kill 명령은 SIGKILL로 프로세스 그룹을 강제 종료한다.
