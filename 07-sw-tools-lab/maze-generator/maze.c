#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <time.h>


void makeMaze(int width, int height, char** maze); // 완전 미로 그리는 함수 선언

int count = 1; // 각 부분이 속한 집합의 정보를 나타낼 전역변수 count 선언



int main()
{
    int width, height;// 미로 너비, 높이 선언


    printf("type width of the maze: "); // 너비 입력
    scanf("%d", &width);


    printf("type height of the maze: "); //높이 입력
    scanf("%d", &height);




    char** maze = (char**)malloc((2 * height + 1) * sizeof(char*)); // 미로 배열 선언

    for (int i = 0; i < 2 * height + 1; i++)
    {
        maze[i] = (char*)malloc((2 * width + 1) * sizeof(char));
    }


    for (int i = 0; i < 2 * height + 1; i++)  // 초기 미로 틀 그리기 작업 수행
    {
        for (int j = 0; j < 2 * width + 1; j++)
        {
            if (i % 2 == 0)
            {

                if (j % 2 == 0)
                {
                    maze[i][j] = '+';
                }
                else
                {
                    maze[i][j] = '-';
                }
            }
            else
            {

                if (j % 2 == 0)
                {
                    maze[i][j] = '|';
                }
                else
                {
                    maze[i][j] = ' ';
                }
            }

        }
    }

    makeMaze(width, height, maze);  // 완전 미로 생성 by 엘러 알고리즘

    for (int p = 0; p < 2 * height + 1; p++)    // 생성한 미로 출력
    {
        for (int q = 0; q < 2 * width + 1; q++)
        {

            printf("%c", maze[p][q]);
        }
        printf("\n");
    }


    FILE* file = fopen("maze.maz", "w"); // 파일에 미로 그리는 작업 수행
    if (file != NULL)
    {

        for (int i = 0; i < 2 * height + 1; i++)
        {
            for (int j = 0; j < 2 * width + 1; j++)
            {
                fprintf(file, "%c", maze[i][j]);
            }
            fprintf(file, "\n");
        }
        fclose(file);

        printf("maze is drawn at maze.maz\n");
    }
    else
    {
        printf("fail to make maze.maz\n");
    }


    for (int i = 0; i < 2 * height + 1; i++)
    {
        free(maze[i]);
    }
    free(maze);


    return 0;
}



// 미로 생성 함수
void makeMaze(int width, int height, char** maze)
{
    int** sets = (int**)malloc(height * sizeof(int*));

    for (int p = 0; p < height; p++)
    {
        sets[p] = (int*)malloc(width * sizeof(int)); // 각 부분을 초기 다른 집합에 속하도록 초기화 작업 실행

        for (int q = 0; q < width; q++)
        {
            sets[p][q] = count++;
        }
    }


    int* checkConnect = (int*)malloc((width * height + 1) * sizeof(int)); //세로 연결이 다른 집합일 경우 적어도 집합별로 하나씩 아래로 연결되게 하기 위해 각 집합이 아래와 연결됨을 나타내는 배열선언


    srand(time(NULL));// random 설정 위해 선언


    for (int y = 0; y < height - 1; y++) // 엘러 알고리즘에 따라 한 행씩 처리 즉 마지막 줄을 제외하고 반복, 이후 마지막 줄은 따로 처리
    {
        
        int x = 0; 
        while (x < width - 1) // 인접한 가로 부분들끼리 비교하기 때문에 x < width - 1 까지 반복
        {
            if ((rand() % 2 == 0) && (sets[y][x] != sets[y][x + 1])) // 가로 벽을 사이에 두고 같은 집합에 속하지 않는 경우 랜덤으로 벽 삭제
            {
                
                maze[2 * y + 1][2 * x + 2] = ' ';

                int beforecount = sets[y][x + 1];
                int newcount = sets[y][x];

                for (int i = 0; i < height; i++)
                {
                    for (int j = 0; j < width; j++)
                    {

                        if (sets[i][j] == beforecount)
                        {
                            sets[i][j] = newcount;
                        }


                    }

                }
            }
            x++; 
        }


        for (int r = 0; r <= (width * height); r++)
        {
            checkConnect[r] = 0; // 배열 값이 0이면 그 집합은 아래와 내려가는 경로가 하나도 아직 없는 것을 의미
        }


        for (int x = 0; x < width; x++)
        {
            if (rand() % 2 == 0) // 초기에는 렌덤으로 세로 연결을 시행
            {
                maze[2 * y + 2][2 * x + 1] = ' ';
                sets[y + 1][x] = sets[y][x];
                checkConnect[sets[y][x]] = 1; // 현재 집합은 아래 부분과 연결 되면 1로 설정
            }
        }


        for (int x = 0; x < width; x++) // 반복해서 연결됬는지를 검사
        {
            if (checkConnect[sets[y][x]] == 0)// 현재 집합이 아래와 연결되지 않았다면 세로벽을 삭제해서 연결 시켜준다
            {
                maze[2 * y + 2][2 * x + 1] = ' ';

                sets[y + 1][x] = sets[y][x];
                checkConnect[sets[y][x]] = 1;
            }
        }
    }

    free(checkConnect);



    int x = 0;

    while (x < width - 1) // 마지막 가로벽들 처리
    {

        if (sets[height - 1][x] != sets[height - 1][x + 1]) // 마지막에 두 인접한 부분의 집합이 다르다면 무조건 수행한다
        {
            maze[2 * height - 1][2 * x + 2] = ' ';

            int beforecount = sets[height - 1][x + 1];
            int newcount = sets[height - 1][x];

            for (int p = 0; p < height; p++) // 결국 마지막에는 set배열의 모든 값들이 하나로 통일된다
            {
                for (int q = 0; q < width; q++)
                {
                    if (sets[p][q] == beforecount)
                    {
                        sets[p][q] = newcount;
                    }
                }
            }
        }
        x++; 
    }


    for (int s = 0; s < height; s++)
    {
        free(sets[s]);
    }
    free(sets);
}


