
#pragma once // 헤더 파일이 중복 포함되지 않도록 방지

#include "ofMain.h" // openFrameworks의 기본 헤더 파일 
#include "ofxWinMenu.h" // 메뉴 애드온 헤더파일


class Enemy {  // 적의 위치와 이동 기능을 포함하는 Enemy 클래스
public:
    int row, col; // 적의 현재 위치를 저장하는 변수

  
    Enemy(int startRow = -2, int startCol = -2) : row(startRow), col(startCol) {}   // Enemy 클래스의 생성자: 초기 위치를 미로 밖으로 설정(-2,-2)

    
    void move(int newRow, int newCol) // 적의 위치를 업데이트하는 멤버함수
    {
        row = newRow; //새로운 행으로 적의 행 이동
        col = newCol; //새로운 열으로 적의 열 이동
    }
};


class ofApp : public ofBaseApp // openFrameworks 애플리케이션을 정의하는 ofApp 클래스
{

public: // public으로 선언

    void setup(); // 애플리케이션 초기 설정을 수행하는 함수

    void update(); // 애플리케이션 상태를 업데이트하는 함수

    void draw(); // 애플리케이션 화면을 그리는 함수

    void keyPressed(int key); // 키가 눌렸을 때 호출되는 함수
   

    bool readFile(); // 파일을 읽는 함수

    void freeMemory(); // 할당된 메모리를 해제하는 함수
    bool DFS(); // DFS 알고리즘을 수행하는 함수
    void dfsdraw(); // DFS 경로를 그리는 함수
    void createGraph(char** input, int maze_row, int maze_col); // 미로의 그래프를 생성하는 함수
    

    bool over; // 게임 종료전 마지막 종료 메시지를 전달하기 위한 플래그
    int HEIGHT; // 미로의 높이를 나타내는 변수
    int WIDTH; // 미로의 너비를 나타내는 변수

    char** input; // 텍스트 파일의 모든 정보를 담는 이차원 배열
    bool* visited; // DFS 탐색 시 방문 여부를 저장하는 배열

    vector<int> final_path; // 최종 dfs 경로를 저장하는 동적 배열
   
    int maze_col; // 실제 char형 미로의 열 수를 나타내는 변수
    int maze_row; //실제 char형 미로의 행 수를 나타내는 변수


    int isOpen; // 파일이 열렸는지를 판단하는 변수. 0이면 파일이 열리지 않았고, 1이면 열림
    int isDFS; // DFS 함수가 실행되었는지 판단하는 변수. 0이면 실행되지 않았고, 1이면 실행됨

    bool fims; // 마지막 종료메시지 표시 완료됨 및 5초뒤 프로그램 종료시키는 플래그 
   
    bool lose; // 플레이어의 패배 상태를 나타내는 플래그
    bool isSuccess; // 게임 성공 여부를 저장하고 성공 메시지를 표시하기 위한 플래그

    int playerLives; // 플레이어의 목숨 수를 나타내는 변수

    ofxWinMenu* menu; // 메뉴 객체, 메뉴를 관리하는 데 사용
    void appMenuFunction(string title, bool bChecked); // 메뉴 항목이 선택되었을 때 호출되는 함수

    
    ofTrueTypeFont myFont; //폰트 객체, 텍스트를 그리기 위해 사용
 
    float windowWidth, windowHeight; // 창의 너비와 높이를 나타내는 변수

    HWND hWnd; // 애플리케이션 윈도우 핸들
    HWND hWndForeground; // 현재 포그라운드 윈도우 핸들

    
    bool bShowInfo;// 화면에 정보를 표시할지 여부를 나타내는 플래그

    unsigned long lastMoveTime;  // 마지막으로 적이 이동한 시간을 저장하는 변수

    int** adjMatrix; // 인접 행렬 선언( 셀들의 연결 여부 파악)

    int playerRow; // 플레이어의 현재 위치를 나타내는 변수 (행)
    int playerCol; // 플레이어의 현재 위치를 나타내는 변수 (열)
    

    Enemy enemy1; // 첫 번째 적 객체
    Enemy enemy2; // 두 번째 적 객체

    ofColor playerColor; // 플레이어의 색상 변수

    bool isValidMove(int newRow, int newCol, int currentRow, int currentCol); // 플레이어나 적의 이동이 유효한지 확인하는 함수

 
    void placeEnemies();   // 적을 렌덤하게 배치하는 함수
   
    void drawEnemies();  // 적을 그리는 함수
    
    void moveEnemies(); // 적을 이동시키는 함수

    vector<pair<int, int>> getValidMoves(int row, int col);// 적의 유효한 이동 경로들을 저장한 동적배열을 반환하는 함수
  
    void checkPlayerEnemyCollision(); // 플레이어와 적의 충돌을 체크하는 함수
};
