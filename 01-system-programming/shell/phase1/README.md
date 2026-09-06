# MyShell

CSE4100 시스템 프로그래밍 프로젝트 2 - 리눅스 셸 구현


## 빌드 방법

make        # 빌드
./myshell   # 실행



## Phase 1 - 기본 셸

### 사용 예시


CSE4100-SP-P2> ls -al
total 856
drwxr-xr-x. 1 root root   4096 ...
-rw-r--r--. 1 root root    234 Makefile


CSE4100-SP-P2> echo "hello world"
hello world

CSE4100-SP-P2> mkdir testdir
CSE4100-SP-P2> cd testdir


### 구현 설명

셸의 기본 동작은 main()의 while 루프 안에서 반복된다. 매 반복마다 프롬프트를 출력하고, fgets()로 사용자 입력을 읽은 뒤 eval() 함수에서 파싱 및 실행을 수행한다.

외부 명령어(ls, cat, mkdir 등)는 fork()로 자식 프로세스를 만든 뒤, 자식에서 execvp()를 호출하여 실행한다. execvp()는 자식의 프로그램 이미지를 완전히 교체하므로 셸(부모)은 영향을 받지 않고 계속 동작한다. 부모는 waitfg() 함수에서 sigsuspend()로 자식이 종료되거나 정지될 때까지 대기한 뒤 다음 프롬프트를 출력한다.

내장 명령어(cd, exit, jobs, fg, bg, kill)는 fork() 없이 셸 프로세스에서 직접 처리한다.

자식 프로세스에서는 setpgid(0, 0)으로 별도 프로세스 그룹을 만든다. 이렇게 해야 Ctrl+C/Z를 눌렀을 때 셸이 죽거나 정지하지 않고, 셸의 시그널 핸들러가 자식 그룹에만 시그널을 전달할 수 있다. 포그라운드 실행 시에는 tcsetpgrp()로 터미널 제어권을 자식 그룹에 넘기고, 자식이 끝나면 다시 셸로 복원한다.

fork() 후 addjob() 전에 자식이 먼저 종료되는 race condition을 방지하기 위해, fork() 전에 sigprocmask()로 SIGCHLD를 블록하고 addjob() 완료 후 해제한다. 자식 프로세스에서는 부모의 시그널 핸들러를 물려받으므로, SIG_DFL로 복원하여 기본 동작이 되도록 한다.
