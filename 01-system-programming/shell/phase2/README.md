# MyShell

CSE4100 시스템 프로그래밍 프로젝트 2 - 리눅스 셸 구현


## 빌드 방법

make        # 빌드
./myshell   # 실행



## Phase 2 - 파이프라인

### 사용 예시


CSE4100-SP-P2> echo hello | grep hello
hello

CSE4100-SP-P2> ls -al | head -3
total 856
drwxr-xr-x. 1 root root   4096 ...
-rw-r--r--. 1 root root    234 Makefile


### 구현 설명

파이프라인은 앞 명령의 stdout을 뒤 명령의 stdin으로 연결하는 구조이다. pipe() 시스템 콜이 읽기 끝과 쓰기 끝 두 개의 fd를 만들고, 자식 프로세스에서 dup2()로 stdin/stdout을 파이프 fd로 교체하여 데이터를 전달한다.

eval() 함수에서 입력에 '|' 문자가 있으면 파이프라인으로 분기한다. '|'를 기준으로 문자열을 분리하고 각 세그먼트를 safe_parseline()으로 파싱한다. parseline()은 buf를 직접 수정하면서 argv에 buf 내부 주소를 저장하므로, 같은 buf에 다음 세그먼트를 넣으면 이전 argv가 가리키는 데이터가 덮어씌워진다. safe_parseline()은 세그먼트마다 별도의 버퍼(seg_buffers[i])에 복사한 뒤 parseline()을 호출하여 이 문제를 해결한다.

exec_pipe() 함수에서 n개의 자식을 for 루프로 fork한다. 마지막 명령을 제외한 매 반복마다 pipe()를 호출하여 새 파이프를 만든다. 자식에서는 이전 파이프의 읽기 끝을 dup2()로 stdin에 연결하고, 마지막 명령이 아니면 현재 파이프의 쓰기 끝을 stdout에 연결한다. 마지막 명령은 stdout을 터미널 그대로 두어 최종 결과가 화면에 출력된다. prev_fd 변수가 이전 파이프의 읽기 끝을 다음 반복으로 전달하는 체인 역할을 한다.

모든 자식은 첫 번째 자식의 pid를 pgid로 공유하여 하나의 프로세스 그룹으로 묶인다. 파이프라인 전체가 하나의 job으로 등록되며, nprocs 필드에 자식 수를 기록한다.



