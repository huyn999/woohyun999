
#include "ofApp.h" // ofApp 헤더 파일 포함
#include <iostream> // 입출력 스트림을 위한 표준 라이브러리
#include <random> // 랜덤 숫자 생성을 위한 표준 라이브러리
#include <ctime> // 시간 관련 함수 사용을 위한 표준 라이브러리
using namespace std; // c++에서 표준 네임스페이스 사용



void ofApp::placeEnemies() // 적들의 위치를 미로내에 렌덤으로 설정하는 함수
{
    vector<pair<int, int>> emptyCells;  // 빈 셀들을 저장할 동적 배열 선언
  
    emptyCells.clear();// 빈 셀들을 저장할 동적 배열 초기화

    
    for (int i = 1; i < maze_row; i += 2) // 미로의 빈 셀을 찾기 위한 반복문
    {
        for (int j = 1; j < maze_col; j += 2)
        {
            if (input[i][j] == ' ')
            {
                emptyCells.push_back(make_pair(i, j)); // 빈 셀의 (행,열) 정보를 동적배열에 추가
            }
        }
    }

    
    if (emptyCells.size() >= 2) // 두 개 이상의 빈 셀이 있을 때
    {
        srand(time(NULL)); // 난수 생성을 위한 시드 설정

        int randIndex1 = rand() % emptyCells.size();// 빈셀들 중 한 셀을 선택
        int randIndex2 = rand() % emptyCells.size(); // 빈셀들 중 한 셀을 선택

        
        while (randIndex2 == randIndex1) // 두 랜덤 인덱스가 동일하면 적2의 셀을 렌덤으로  재설정해서 둘의 위치가 겹치지 않게한다
        {
            randIndex2 = rand() % emptyCells.size();
        }

        
        enemy1.move(emptyCells[randIndex1].first, emptyCells[randIndex1].second); // 적들을 각각의 렌덤으로 선택된 빈 셀 위치로 이동시켜주는 move함수를 시행한다
        enemy2.move(emptyCells[randIndex2].first, emptyCells[randIndex2].second);
    }
}


bool ofApp::isValidMove(int newRow, int newCol, int currentRow, int currentCol) // 유효한 이동 경로를 확인하는 함수
{
    
    if (newRow < 0 || newRow >= maze_row || newCol < 0 || newCol >= maze_col) // 새로운 위치가 미로의 범위를 벗어나는지 확인히고 벗어나면 false 반환
    {
        return false;
    }
    // 현재 위치와 새로운 위치 사이에 벽이 있는지 확인한다(동서남북 방향에 대해)  벽이라면 false를 반환한다
    if (newRow < currentRow && input[currentRow - 1][currentCol] == '-') return false;
    if (newRow > currentRow && input[currentRow + 1][currentCol] == '-') return false;
    if (newCol < currentCol && input[currentRow][currentCol - 1] == '|') return false;
    if (newCol > currentCol && input[currentRow][currentCol + 1] == '|') return false;

    
    return (input[newRow][newCol] != '|') && (input[newRow][newCol] != '-'); // 위에 조건문들을 통과하고 새로운 위치가 셀이면 true를 반환한다
}

vector<pair<int, int>> ofApp::getValidMoves(int row, int col) // 적의 유효한 이동 경로들을 저장한 동적배열을 반환하는 함수
{
    vector<pair<int, int>> validMoves; //(행,열) 정보 갖는 동적 배열 선언

    
    // 적이 유효한 움직임이라면 그 움직임을 동적 배열에 추가해 준다.(동서남북에 대해 조사)
    if (isValidMove(row - 2, col, row, col)) validMoves.push_back(make_pair(row - 2, col)); 
    if (isValidMove(row + 2, col, row, col)) validMoves.push_back(make_pair(row + 2, col));
    if (isValidMove(row, col - 2, row, col)) validMoves.push_back(make_pair(row, col - 2));
    if (isValidMove(row, col + 2, row, col)) validMoves.push_back(make_pair(row, col + 2));

    return validMoves; // 동적 배열을 반환 해준다

}



void ofApp::moveEnemies() // 적들을 이동시키는 함수
{
    
    if (ofGetElapsedTimeMillis() - lastMoveTime > 1000) // 적들이 마지막 이동 후 1초가 지났다면 실행( 적들이 1초를 주기로 미로내에서 경로를 따라 움직이도록 하기 위해)
    {
        lastMoveTime = ofGetElapsedTimeMillis(); // 마지막 이동 시간 갱신

        vector<pair<int, int>> validMoves1 = getValidMoves(enemy1.row, enemy1.col);// 적1 에 대해 현재위치에서 가능한 움직임들을 저장하는 동적 배열을 함수 호출로 생성
        vector<pair<int, int>> validMoves2 = getValidMoves(enemy2.row, enemy2.col);// 적2 에 대해 현재위치에서 가능한 움직임들을 저장하는 동적 배열을 함수 호출로 생성

        
        if (!validMoves1.empty()) // 적1이 이동할 수 있는 유효한 경로가 있을 때
        {
            int randIndex = rand() % validMoves1.size(); // 가능한 경로들 중 한 경로를 택하기 위해 렌덤한 index를 택한다
            enemy1.move(validMoves1[randIndex].first, validMoves1[randIndex].second);// 택한 경로로 move함수를 이용해 적1을 이동
        }

       
        if (!validMoves2.empty())  // 적2가 이동할 수 있는 유효한 경로가 있을 때
        {
            int randIndex = rand() % validMoves2.size(); // 가능한 경로들 중 한 경로를 택하기 위해 렌덤한 index를 택한다
            enemy2.move(validMoves2[randIndex].first, validMoves2[randIndex].second);// 택한 경로로 move함수를 이용해 적2를 이동
        }

        
        checkPlayerEnemyCollision();// 플레이어와 움직인 적들의 충돌을 확인하기 위해  checkPlayerEnemyCollision() 호출

        
        if (enemy1.row == enemy2.row && enemy1.col == enemy2.col)// 이외에 플레이어와 적이 만나지 않았을 때라도 두 적이 같은 위치에 있으면
        {
            if (!lose)// 게임이 지지 않았다면
            {
                placeEnemies();// 다시 렌덤하게 적의 위치를 설정하기 위해 placeEnemies() 함수 호출
            }
        }
    }
}
   

void ofApp::checkPlayerEnemyCollision() // 플레이어와 적의 충돌을 확인하는 함수
{
    // 플레이어와 적이 같은 위치에 있는지 확인해서 같다면
    if ((playerRow == enemy1.row && playerCol == enemy1.col) || (playerRow == enemy2.row && playerCol == enemy2.col))
    {
        playerLives--; // 플레이어의 목숨 감소

        // 남은 목숨 수에 따라 플레이어의 색상 변경
        if (playerLives == 2)
        {
            playerColor = ofColor(255, 165, 0); // 주황색으로 설정
        }
        else if (playerLives == 1)
        {
            playerColor = ofColor(255, 0, 0); // 빨간색으로 설정
        }
        if (playerLives == 0)
        {
            playerColor = ofColor(0, 0, 0); // 검정색으로 설정

            lose = true; // 졌다는 플래그를 설정해 게임 종료를 준비한다
            
        }
        if (!lose)// 아직 플레이어의 목숨이 남아 있다면
        {
            placeEnemies(); //  적들을 다시 렌덤으로 미로 내에 배치하는 함수 호출
        }
    }
}


void ofApp::drawEnemies() // 적을 그리는 함수
{
    ofSetColor(128, 0, 128); // 적1의 색상 설정 (보라색)
    int weight = 15;
    ofDrawCircle(enemy1.col * weight + weight / 2 - weight / 4 + 1, enemy1.row * weight + weight / 2 - weight / 4 - 3, weight / 2, weight / 2);

    ofSetColor(255, 255, 0); // 적2의 색상 설정 (노란색)
    ofDrawCircle(enemy2.col * weight + weight / 2 - weight / 4 + 1, enemy2.row * weight + weight / 2 - weight / 4 - 3, weight / 2, weight / 2);
}




void ofApp::setup() // 설정 함수 - 게임의 초기 상태를 설정
{
    ofSetWindowTitle("woohyun's maze game"); // 창 제목 설정
    ofSetFrameRate(15); // 프레임 레이트 설정
    ofBackground(255, 255, 255); // 배경 색상 설정 (흰색)
    
    ofSetVerticalSync(true); // 수직 동기화 설정
    windowWidth = ofGetWidth(); // 창의 너비 가져오기
    windowHeight = ofGetHeight(); // 창의 높이 가져오기

    over = false;// 게임 내 플래그들을 초기에 false로 설정, 각 변수의 역할은 헤더파일에 주석으로 설명
    fims = false; 
    isSuccess = false;
    lose = false;

    isDFS = 0;
    isOpen = 0;

    playerRow = -3; // 플레이어의 초기 위치를 미로 밖으로 설정
    playerCol = -3;
    
    playerLives = 3; // 플레이어의 목숨 초기 3개로 설정
    
    playerColor = ofColor(0, 255, 0); // 플레이어 색상 초기화 (초록색)

    lastMoveTime = ofGetElapsedTimeMillis(); // 마지막 이동 시간 초기화
    

    
    ofSetWindowPosition((ofGetScreenWidth() - windowWidth) / 2, (ofGetScreenHeight() - windowHeight) / 2); // 창을 화면 중앙에 배치

   
    myFont.loadFont("verdana.ttf", 12, true, true);  // 폰트 로드

    
    hWnd = WindowFromDC(wglGetCurrentDC()); // 윈도우 핸들 가져오기

    
    ofSetEscapeQuitsApp(false); // ESC 키로 애플리케이션이 종료되지 않도록 설정


    // 메뉴 생성 및 설정
    menu = new ofxWinMenu(this, hWnd);
    menu->CreateMenuFunction(&ofApp::appMenuFunction);
    HMENU hMenu = menu->CreateWindowMenu();
    HMENU hPopup = menu->AddPopupMenu(hMenu, "File"); // 파일 메뉴 생성
    menu->AddPopupItem(hPopup, "Open", false, false); // 파일 메뉴 내 소메뉴 open 생성
    menu->AddPopupSeparator(hPopup);
    menu->AddPopupItem(hPopup, "Exit", false, false); // 파일 메뉴 내 소메뉴 exit 생성
    hPopup = menu->AddPopupMenu(hMenu, "View");// view 메뉴생성
    bShowInfo = true;
    menu->AddPopupItem(hPopup, "Hint!!", false, false);//view 메뉴 내 소메뉴 힌트메뉴 생성
    hPopup = menu->AddPopupMenu(hMenu, "Help");// help 메뉴 생성
    menu->AddPopupItem(hPopup, "About", false, false); // help 메뉴 내 about 소메뉴 생성
    menu->SetWindowMenu();

    cout << "Welcome! click File menu & Open menu to play game" << endl; // 파일 이름을 출력
    cout << "You have to choose map (.maz file)" << endl;

}


void ofApp::appMenuFunction(string title, bool bChecked) // 메뉴 항목이 선택되었을 때 호출되는 함수
{
    if (title == "Open") // open 메뉴 선택시 
    {
        readFile(); // 파일을 읽어옴
       
        placeEnemies(); // 적을 배치
    }
    if (title == "Exit") // exit 메뉴 선택시
    {
        ofExit(); // 프로그램 종료
    }
    if (title == "Hint!!") // 힌트 메뉴 선택시
    {
        if (isOpen) {
            DFS(); // DFS 실행
            bShowInfo = bChecked; // 정보 표시 여부 설정
        }
        else {
            cout << "You must open file first" << endl;
        }
    }
    if (title == "About")
    {
        ofSystemAlertDialog("ofxWinMenu\nbasic example\n\nhttp://spout.zeal.co"); // 정보 대화상자 표시
    }
}


void ofApp::update()  // 업데이트 함수로 게임 상태를 지속적으로 매 프레임 당 실행되어 갱신 해주고 moveEnemies 함수를 호출한다
{
    if (fims) // final message가 그려졌다면
    {  
        cout << "Good bye!" << endl;  // good bye 디버그 메시지 표시
        this_thread::sleep_for(std::chrono::seconds(5)); // 5초후에
        ofExit(); // 미로 게임 프로그램을 종료 시킨다
        return;
    }
    if (!lose) // 만약 아직 플레이어의 목숨이 남아 있다면
    {
        moveEnemies(); // 적 이동함수를 호출
    }
}

void ofApp::draw() // 게임 화면을 그리는 함수로 지속적으로 매번 프레임마다 실행되어 미로,플레이어, 적들, dfs경로등을 그리는 역할을 수행한다
{
    char str[256];
    ofSetColor(100);
    ofSetLineWidth(5);
    int weight = 15;

    
    for (int i = 0; i < maze_row; i++)  // 미로를 그리기 위한 반복문
    {
        for (int j = 0; j < maze_col; j++) 
        {
            if (input[i][j] == '|')
                ofDrawLine(j * weight, (i - 1) * weight, j * weight, (i + 1) * weight);
            else if (input[i][j] == '-')
                ofDrawLine((j - 1) * weight, i * weight, (j + 1) * weight, i * weight);
        }
    }

    if (isDFS)// DFS 경로를 그린다
    {
        ofSetColor(200);
        ofSetLineWidth(3);
        if (isOpen) dfsdraw();
        else cout << "You must open file first" << endl;
    }

    drawEnemies(); // 적을 그리는 함수 호출

    ofSetColor(playerColor); // 플레이어의 색상 설정

    ofDrawCircle(playerCol * weight + weight / 2 - weight / 4 + 1, playerRow * weight + weight / 2 - weight / 4 - 3, weight / 2, weight / 2); // 플레이어 그리기

    if (bShowInfo)
    { // 정보 표시 여부 확인
        ofSetColor(200); // 텍스트 색상 설정
        sprintf(str, "maze game");
        myFont.drawString(str, 15, ofGetHeight() - 20);
    }

    if (isSuccess) // 게임 성공 여부 확인하면
    {
        ofSetColor(0, 255, 0); // 초록색으로 성공메시지 표시
        myFont.drawString("you win!! press any key to end!", ofGetWidth() / 2 - 50, ofGetHeight() / 2);
    }


    if (lose) // 게임 패배 여부 확인하면
    {
        ofSetColor(0, 0, 255); // 파란색으로 졌다는 메시지 표시
        myFont.drawString(" you lose!! game will be end in 5 seconds.", ofGetWidth() / 2 - 100, ofGetHeight() / 2 - 100);
        fims = true;
    }


    if (over) // 게임 종료 메시지 출력을 위한 조건문
    {
        ofSetColor(0, 0, 255); // 파란색으로 5초내에 게임이 종료된다는 메시지 표시
        myFont.drawString(" See you next time! game will be end in 5 seconds.", ofGetWidth() / 2 - 100, ofGetHeight() / 2 - 100);
        fims = true;
    }
}




void ofApp::keyPressed(int key)// 키 입력 처리 함수
{
    if (isSuccess)// 만약 종점에 도달하는게 성공했다면 아무 키를 눌렀을 때
    {
        over = true; // 플래그가 true가 되서 종료메시지를 출력할 수 있게 하고 이후 update 함수내에서 5초후에 프로그램이 종료되게 한다
    }

    int newRow = playerRow;
    int newCol = playerCol;

    switch (key)
    {
    case OF_KEY_UP: newRow -= 2; break; // 위로 이동
    case OF_KEY_DOWN: newRow += 2; break; // 아래로 이동
    case OF_KEY_LEFT: newCol -= 2; break; // 왼쪽으로 이동
    case OF_KEY_RIGHT: newCol += 2; break; // 오른쪽으로 이동
    }

    // 유효한 이동인지 확인
    if (isValidMove(newRow, newCol, playerRow, playerCol))
    {
        playerRow = newRow; // 새로운 행 위치로 갱신
        playerCol = newCol; // 새로운 열 위치로 갱신

        int e = maze_row * maze_col - maze_col - 2;
        int endRow = e / maze_col;
        int endCol = e % maze_col;

        if (playerRow == endRow && playerCol == endCol) // 플레이어가 종점에 도달했다면
        {
            isSuccess = true; // 게임 성공 플래그 true로 설정 (게임 종료를 준비)
        }

        checkPlayerEnemyCollision(); // 플레이어와 적의 충돌 확인 함수 호출
    }
}



bool ofApp::readFile() // 파일 읽는 함수
{
    
    ofFileDialogResult openFileResult = ofSystemLoadDialog(); // 파일 다이얼로그 열기
    string filePath; // 선택된 파일의 경로를 저장할 변수
    size_t pos; // 파일 경로에서 확장자를 찾기 위한 변수
   

    if (openFileResult.bSuccess) // 사용자가 파일을 성공적으로 선택했다면
    {
        
        string fileName = openFileResult.getName(); // 선택된 파일의 이름을 가져옴
        cout << "game map name is " << fileName << endl; // 파일 이름을 출력
        filePath = openFileResult.getPath(); // 선택된 파일의 전체 경로를 가져옴

        
        pos = filePath.find_last_of(".");
        if (pos != string::npos && pos != 0 && filePath.substr(pos + 1) == "maz") // 파일 확장자가 .maz인지 확인
        {
            ofFile file(fileName);
            if (!file.exists()) // 파일이 존재하지 않으면
            {
                cout << "game map does not exists." << endl; // 파일이 존재하지 않는다는 메시지 표시
                return false; // 함수 종료
            }
            else // 존재한다면
            {
                cout << "We open the game map." << endl; // 파일이 존재해서 열었다는 메시지 표시
                isOpen = 1; // 파일이 열렸음을 표시

               
            }

            ofBuffer buffer(file); // 파일을 버퍼로 읽어들임

            maze_col = 0; // 실제 char형 미로의 열 수 초기화 (테두리와 벽까지 계산한것을 의미한다)
            maze_row = 0; //실제  char 미로의 행 수 초기화  (테두리와 벽까지 계산한것을 의미한다)

            
            ofBuffer::Line start = buffer.getLines().begin(); 
            ofBuffer::Line end = buffer.getLines().end(); 

            // 파일의 각 줄을 읽어들여 미로의 행 수와 열 수를 계산
            while (start != end)
            {
                string line = *start; // 현재 줄을 문자열로 읽는다

                
                if (start == buffer.getLines().begin())
                {
                    maze_col = line.size(); // 첫 번째 줄의 길이를 열 수로 설정
                }
                maze_row++; //행의 개수 늘려주면서 계산 
                ++start; // 다음 줄로 이동
            }

            WIDTH = maze_col / 2; // 미로의 너비 설정
            HEIGHT = maze_row / 2; // 미로의 높이 설정

            input = (char**)malloc(sizeof(char*) * (maze_row)); // 미로 배열을 동적 할당
            for (int i = 0; i < maze_row; i++)
            {
                input[i] = (char*)malloc(sizeof(char) * maze_col);
            }

            
            int p = 0;
            start = buffer.getLines().begin();
            end = buffer.getLines().end();
            while (start != end)  // 행별로 읽어온 데이터를 통해 실제 char 형 미로 배열을 만든다
            {
                string line = *start;
                int j = 0;
                while (j < line.size())
                {
                    input[p][j] = line[j]; // 행별로 읽어온 데이터를 input 배열에 저장
                    j++;
                }
                p++;
                ++start;
            }

            createGraph(input, maze_row, maze_col); // 미로의 인접행렬을 생성하는 함수 호출

            playerRow = 1; // 플레이어의 초기 위치를 미로 내 시작점 (1,1)로 설정해준다
            playerCol = 1;
        }
        else
        {
            printf("Needs a '.maz' extension\n"); // 잘못된 파일 확장자 경고
            return false; // 함수 종료
        }
    }
    return true; // 파일이 성공적으로 열렸음을 반환
}


void ofApp::createGraph(char** input, int maze_row, int maze_col)
{
   
    adjMatrix = (int**)malloc(sizeof(int*) * maze_row * maze_col);

    for (int i = 0; i < maze_row * maze_col; i++)  // 미로의 인접 행렬을 초기화
    {
        adjMatrix[i] = (int*)malloc(sizeof(int) * maze_row * maze_col);

        for (int j = 0; j < maze_row * maze_col; j++)
        {
            adjMatrix[i][j] = 0; // 인접 행렬을 0으로 초기화
        }
    }

    //  반복문으로 인접 행렬을 생성
    for (int i = 0; i < maze_row; i++)
    {
        for (int j = 0; j < maze_col; j++)
        {
            if ((j % 2 == 1) && (i % 2 == 1)) // 빈 셀들만을 고려
            {
                int vertex = i * maze_col + j;


                // 오른쪽 인접 정점을 확인하여 인접 행렬에 연결
                if (j < maze_col - 3 && input[i][j + 1] == ' ')
                {
                    int rightVertex = i * maze_col + (j + 2);
                    adjMatrix[vertex][rightVertex] = 1;
                    adjMatrix[rightVertex][vertex] = 1;
                }



                // 아래쪽 인접 정점을 확인하여 인접 행렬에 연결
                if (i < maze_row - 3 && input[i + 1][j] == ' ')
                {
                    int downVertex = (i + 2) * maze_col + j;
                    adjMatrix[vertex][downVertex] = 1;
                    adjMatrix[downVertex][vertex] = 1;
                }
            }
        }
    }
}

void ofApp::freeMemory() // 동적 할당된 메모리를 해제하는 함수
{
    
    
    for (int i = 0; i < maze_row * maze_col; ++i) // 인접 행렬 메모리 해제
    {
        delete[] adjMatrix[i];
    }
    delete[] adjMatrix;


    
    for (int j = 0; j < maze_row; j++) // char형 실제 미로 배열 메모리 해제
    {
        delete[] input[j];
    }
    delete[] input;

    
    free(visited); // 방문 배열 메모리 해제
}


bool ofApp::DFS() // 힌트 메뉴 선택시 dfs 함수가 시행되어 미로에 힌트 경로를 그려줄 수 있도록 최종경로를 저장하는 동적 배열을 만드는 함수
{
    stack<int> stack; // DFS를 위한 스택

    vector<int> path; // 경로를 저장할 벡터
    final_path.clear(); // 전체 경로 초기화

    int start = maze_col + 1; // 시작 정점
    int end = maze_row * maze_col - maze_col - 2; // 종료 정점

    
    visited = (bool*)malloc(sizeof(bool) * maze_row * maze_col);
    for (int i = 0; i < maze_row * maze_col; i++)
    {
        visited[i] = false;// 방문 배열 초기화
    }

    stack.push(start); // 시작점을 스택에 push
    visited[start] = true; // 방문 한 곳을 나타내는 배열에 시작점을 방문했다고 표시
    path.push_back(start); // 이동 경로에도 시작점을 넣어준다

    while (!stack.empty())// 스택이 빌때까지 반복한다
    {
        int currentv = stack.top(); // 현재 정점을 스택의 top에 있는 정점으로 설정한다
        path.push_back(currentv); // 현재 경로에 현재 정점 추가

        if (currentv == end) // 종료 정점에 도달했을 때
        {
            isDFS = true; // dfs가 완료됨을 표시
            final_path = path; // 최종 dfs 경로를 final_path에 할당
            return true;
        }

        int nextv = 0;// 다음정점을 0으로 초기화 다음 방문할 정점이 없다면 nextv는 0이므로 후에 스택이 pop하게 하는 플래그 역할을 한다
        
        for (int i = maze_col; i < maze_row * maze_col - maze_col - 1; i++)// 시작점부터 종점까지 중 가능한 다음 정점을 찾는 반복문
        {
            if (adjMatrix[currentv][i] == 1 && !visited[i])// 현재 정점과 인접해 있지만 방문하지 않은 정점이라면 
            {
                nextv = i;//다음 방문할 정점을 현재 반복문의 i 정점으로 할당하고
                break;// 반복문 탈출
            }
        }

        if (nextv != 0) // 인접하지만 방문하지 연결된 정점을 찾았다면
        {
            visited[nextv] = true;// 다음 방문 정점을 방문 처리하고
            stack.push(nextv);// 스택에 다음 이동할 정점을 push
        }
        else  // 더 이상 이동할 수 없을 때( nextv==0 이라면)
        {
            stack.pop(); // 스택에서 pop 해주기
            path.pop_back(); // 현재 경로에서 정점을 제거
            path.pop_back(); //  다음 반복문에서 경로에 정점을 넣어주기 때문에 두 번 제거해야 경로 오류가 생기지 않는다
        }
    }
    return false;
}


void ofApp::dfsdraw()  // DFS 경로를 그리는 함수
{
    int weight = 15;
    ofSetColor(255, 0, 0); // 최종 경로를 빨간색 선으로 표시
    for (int i = 1; i < final_path.size(); i++) // 저장된 최종경로의 배열을 따라 이전 좌표와 현재 좌표를 선으로 반복문을 따라 이어준다
    {
        int cur = final_path[i];// 현재경로의 좌표 index
        int pre = final_path[i - 1];//이전 경로의 좌표 index

        int currow = cur / maze_col;// 현재 경로 정점의 행좌표
        int curcol = cur % maze_col;// 현재 경로 정점의 열좌표

        int prerow = pre / maze_col;// 이전 경로 정점의 행좌표
        int precol = pre % maze_col;// 이전 경로 정점의 열좌표

        
        ofDrawLine(precol * weight + weight / 2 - 5, prerow * weight + weight / 2 - 5, curcol * weight + weight / 2 - 5, currow * weight + weight / 2 - 5);  // 두 정점 사이를 연결하는 선을 그림

    }
}




