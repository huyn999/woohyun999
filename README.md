# 전공 프로젝트 모음

서강대학교 컴퓨터공학과 전공 수업에서 진행한 프로젝트를 과목별로 정리했습니다.
시스템 소프트웨어와 네트워크 프로토콜을 중심으로, 자원이 제한된 환경에서의 설계 판단과
측정 기반 검증에 초점을 두고 작업했습니다.

## 관심 분야

임베디드 리눅스, 운영체제, 시스템 소프트웨어

## 프로젝트 목록

| 과목 | 프로젝트 | 언어 | 핵심 내용 |
|---|---|---|---|
| 시스템프로그래밍 | [동적 메모리 할당기](01-system-programming/malloc) | C | 분리 가용 리스트, 소형 요청 전용 영역 분리로 이용률 97.42% |
| 시스템프로그래밍 | [커널 자료구조](01-system-programming/pintos-data-structures) | C | 리스트·해시테이블·비트맵 구현, 명령 기반 검증 도구 |
| 시스템프로그래밍 | [유닉스 쉘](01-system-programming/shell) | C | 파이프라인, 시그널 처리, 잡 컨트롤 |
| 시스템프로그래밍 | [동시성 서버](01-system-programming/stock-server) | C | 이벤트 기반 vs 스레드 풀 처리율 비교 |
| 컴퓨터네트워크 | [적응형 전송기](02-computer-networks/adaptive-sender) | C++ | 비용 모델 유도, 베이지안 오류율 추정 |
| 컴퓨터네트워크 | [링크 스테이트 라우터](02-computer-networks/link-state-router) | C++ | 최단 경로 산출, 제어 메시지 비트 단위 압축 |
| 기초인공지능 | [이미지 분류 CNN](03-machine-learning/pokemon-cnn) | Python | CNN 설계, K-Fold 교차검증, 정확도 96.53% |
| 기초인공지능 | [분류·회귀 모델](03-machine-learning/tabular-models) | Python | 결측 처리, 상호작용 항, 스태킹 앙상블 |
| 알고리즘설계와분석 | [최대 부분 배열](04-algorithms/max-subarray) | C | 세 알고리즘 구현 및 실행시간 비교 |
| 알고리즘설계와분석 | [동적 계획법](04-algorithms/dp-problems) | C++ | 다각형 삼각분할, 회문 복원 |
| 알고리즘설계와분석 | [정렬 비교](04-algorithms/sorting) | C | 힙 정렬 구현, 대입 연산 최적화 |
| 알고리즘설계와분석 | [연결 요소별 MST](04-algorithms/mst-components) | C | 크루스칼 확장, 서로소 집합 |
| 자료구조 | [문자열 검색](05-data-structures/string-matching) | C | KMP vs 단순 비교 성능 측정 |
| 자료구조 | [힙 정렬](05-data-structures/heap-sort) | C | 최소·최대 힙 배열 구현 |
| 자료구조 | [크루스칼 MST](05-data-structures/kruskal-mst) | C | 최소 힙 + 서로소 집합 |
| JAVA언어 | [동시성 서버·객체지향 설계](06-java) | Java | 스레드 풀, 공유 자원 동기화, 상속과 예외 |
| SW개발도구및환경실습 | [미로 게임](07-sw-tools-lab) | C++ | openFrameworks, BFS 경로 탐색 |

## 사용 기술

**언어** C, C++, Python, Java
**환경** Linux, Docker, Git, VS Code
**라이브러리** PyTorch, scikit-learn, pandas, NumPy, openFrameworks

## 안내

학부 수업 과제로 진행한 코드입니다. 학습 참고용으로만 열람해 주시고,
동일 과목 수강생의 과제 제출 목적으로는 사용하지 말아 주십시오.
