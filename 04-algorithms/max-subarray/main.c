
#define _CRT_SECURE_NO_WARNINGS
#define CHECK_TIME_START(start,freq) QueryPerformanceFrequency((LARGE_INTEGER*)&freq); QueryPerformanceCounter((LARGE_INTEGER*)&start)  // 시간 측정 
#define CHECK_TIME_END(start,end,freq,time) QueryPerformanceCounter((LARGE_INTEGER*)&end); time = (float)((float)(end - start) / (freq * 1.0e-3f))// 시간 측정
#define CMAX 1000000000 
#define MIN INT_MIN
#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>

static __int64 _start, _freq, _end;
static float _compute_time;


void worktestcase(int algoIndex, const char* pgmFile, const char* averageFile, const char* outputFile);

int DivideAndConquer(int* arr, int left, int right, int* start, int* end);
int kadane(int* ary, int n, int* first, int* final);

int algorithm03(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol);
int algorithm04(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol);
int algorithm05(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol);


int main()
{
    char configFilePath[100];

    FILE* configFile = fopen("Data/HW1_config.txt", "r"); 

    if (!configFile)
    {
        printf("Error 발생! config file을 열 수 없습니다.\n");
        return 1;
    }

    int testCaseCount;
    fscanf(configFile, "%d", &testCaseCount);

    for (int i = 0; i < testCaseCount; ++i)
    {
        int algoIndex;
        char pgmFile[100];         
        char averageFile[100];
        char outputFile[100];

        fscanf(configFile, "%d %s %s %s", &algoIndex, pgmFile, averageFile, outputFile);

        // 각 테스트 케이스에 대해 처리
        worktestcase(algoIndex, pgmFile, averageFile, outputFile);
    }

    printf("\n");
    printf("Work is completed!\n");
    fclose(configFile);

    return 0;
}

void worktestcase(int algoIndex, const char* pgmFile, const char* averageFile, const char* outputFile)
{
    char pgmFilePath[100], averageFilePath[100], outputFilePath[100];

    strcpy(pgmFilePath, "Data/");
    strcat(pgmFilePath, pgmFile);

    strcpy(averageFilePath, "Data/");
    strcat(averageFilePath, averageFile);

    strcpy(outputFilePath, "Data/");
    strcat(outputFilePath, outputFile);

    FILE* file = fopen(pgmFilePath, "r");
    if (!file)
    {
        printf("Error 발생! PGM file을 열 수 없습니다.\n");
        exit(1);
    }

    fscanf(file, "P2\n");

    int cols, rows;
    fscanf(file, "%d %d\n", &cols, &rows);

    int maxVal;
    fscanf(file, "%d\n", &maxVal);


    int** matrix = (int**)malloc(rows * sizeof(int*)); // 2D 배열(matrix) 동적 할당
    for (int i = 0; i < rows; i++) {
        matrix[i] = (int*)malloc(cols * sizeof(int));
    }


    for (int i = 0; i < rows; i++)   // PGM 파일에서 원소값들을 읽어 matrix에 저장
    {
        for (int j = 0; j < cols; j++)
        {
            fscanf(file, "%d", &matrix[i][j]);
        }
    }

    fclose(file);

    file = fopen(averageFilePath, "r");
    if (!file)
    {
        printf("Error 발생! average file %s을 열 수 없습니다.\n", averageFile);
        exit(1);
    }

    int average;
    fscanf(file, "%d", &average);
    fclose(file);

    for (int i = 0; i < rows; i++)
    {
        for (int j = 0; j < cols; j++)
        {
            matrix[i][j] -= average;
        }
    }

    int maxSum = 0;
    int startX, startY, endX, endY; 

    if (algoIndex == 3)  //각 알고리즘 별 처리
    {
        CHECK_TIME_START(_start, _freq);
        maxSum = algorithm03(matrix, rows, cols, &startX, &startY, &endX, &endY);
        CHECK_TIME_END(_start, _end, _freq, _compute_time);
        fprintf(stdout, "%s, algorithm num: %d, run time = %.3fms \n", pgmFile, algoIndex, _compute_time); 
    }
    else if (algoIndex == 4)
    {
        CHECK_TIME_START(_start, _freq);
        maxSum = algorithm04(matrix, rows, cols, &startX, &startY, &endX, &endY);
        CHECK_TIME_END(_start, _end, _freq, _compute_time);
        fprintf(stdout, "%s, algorithm num: %d, run time = %.3fms \n", pgmFile, algoIndex, _compute_time); 
    }
    else if (algoIndex == 5)
    {
        CHECK_TIME_START(_start, _freq);
        maxSum = algorithm05(matrix, rows, cols, &startX, &startY, &endX, &endY);
        CHECK_TIME_END(_start, _end, _freq, _compute_time);
        fprintf(stdout, "%s, algorithm num: %d, run time = %.3fms \n", pgmFile, algoIndex, _compute_time); 
    }
    else
    {
        printf("Error 발생! 올바른 알고리즘 번호를 삽입하세요.\n");
        for (int i = 0; i < rows; i++)
        {
            free(matrix[i]);
        }
        free(matrix);
        return;
    }

    FILE* outFile = fopen(outputFilePath, "w");
    if (!outFile)
    {
        printf("Error 발생! 파일을 열 수 없습니다.\n");
        for (int i = 0; i < rows; i++)
        {
            free(matrix[i]);
        }
        free(matrix);
        return;
    }

    fprintf(outFile, "%d ", maxSum);
    fprintf(outFile, "%d %d %d %d\n", startX, startY, endX, endY);
    fclose(outFile);

    for (int i = 0; i < rows; i++)  // 메모리 free
    {
        free(matrix[i]);
    }
    free(matrix);
}


int algorithm03(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol)
{
    int finalSum = MIN;

    int** summedTable = (int**)malloc(rows * sizeof(int*)); // summed table 만들어 주기
    for (int i = 0; i < rows; i++)
    {
        summedTable[i] = (int*)malloc(cols * sizeof(int));
    }

    summedTable[0][0] = matrix[0][0];
    for (int i = 1; i < rows; i++)
        summedTable[i][0] = summedTable[i - 1][0] + matrix[i][0];
    for (int j = 1; j < cols; j++)
        summedTable[0][j] = summedTable[0][j - 1] + matrix[0][j];

    for (int i = 1; i < rows; i++)
    {
        for (int j = 1; j < cols; j++)
        {
            summedTable[i][j] = matrix[i][j] + summedTable[i - 1][j] + summedTable[i][j - 1] - summedTable[i - 1][j - 1];
        }
    }

    // Find the maximum sum rectangle using the summed table
    for (int row1 = 0; row1 < rows; row1++) // 시작 행 설정
    {
        for (int row2 = row1; row2 < rows; row2++) // 끝나는 행 설정
        {
            for (int col1 = 0; col1 < cols; col1++) // 시작 열 설정
            {
                for (int col2 = col1; col2 < cols; col2++) // 끝나는 열 설정
                {
                    int Sum = summedTable[row2][col2]; //  상수 시간 소요됨

                    if (row1 > 0) Sum -= summedTable[row1 - 1][col2];
                    if (col1 > 0) Sum -= summedTable[row2][col1 - 1];

                    if (row1 > 0 && col1 > 0) Sum += summedTable[row1 - 1][col1 - 1];

                    if (Sum > finalSum)
                    {
                        finalSum = Sum;
                        *startRow = row1;
                        *startCol = col1;
                        *endRow = row2;
                        *endCol = col2;
                    }
                }
            }
        }
    }

    for (int i = 0; i < rows; i++)
    {
        free(summedTable[i]);
    }
    free(summedTable);

    return finalSum;
}




int algorithm04(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol)
{
    int finalSum = MIN;
    for (int Colleft = 0; Colleft < cols; Colleft++)// 시작 열 선택
    {

        int* temp = (int*)calloc(rows, sizeof(int));  // 고정된 열 범위 (left, right)에 대해 각 행 별로 그 행에 해당하는 범위의 열들의 합을 저장하는 temp 배열

        for (int Colright = Colleft; Colright < cols; Colright++) // 마지막 열 선택
        {

            for (int i = 0; i < rows; i++)
            {
                temp[i] += matrix[i][Colright];
            }


            int start, end;
            int Sum = DivideAndConquer(temp, 0, rows - 1, &start, &end); //nlogn

            if (Sum > finalSum)
            {
                finalSum = Sum;
                *startRow = start;  // 시작 행 
                *endRow = end;    // 종료 행 
                *startCol = Colleft; // 시작 열 
                *endCol = Colright; // 종료 열 
            }
        }
        free(temp);
    }

    return finalSum;
}

int DivideAndConquer(int* ary, int leftIndex, int rightIndex, int* startIndex, int* endIndex)
{
    if (leftIndex == rightIndex)  // base case 처리
    {
        *startIndex = *endIndex = leftIndex;
        return ary[leftIndex];
    }

    // divide 작업 수행
    int middle = (leftIndex + rightIndex) / 2;

    int leftStart, leftEnd, rightStart, rightEnd;

    // conquer 작업 수행

    int leftMaxSum = DivideAndConquer(ary, leftIndex, middle, &leftStart, &leftEnd);

    int rightMaxSum = DivideAndConquer(ary, middle + 1, rightIndex, &rightStart, &rightEnd);

    // combine 작업 수행 ( left와 right를 가로지르는 부분합에 대해 조사)

    int maxLeftCross = MIN, maxRightCross = MIN, tempSum = 0;

    int crossStart = middle, crossEnd = middle + 1;

    int i = middle;

    while (i >= leftIndex)
    {
        tempSum += ary[i];
        if (tempSum > maxLeftCross)
        {    

            crossStart = i;
            maxLeftCross = tempSum;
            
        }
        i--;
    }

    tempSum = 0;
    i = middle + 1;
    while (i <= rightIndex)
    {
        tempSum += ary[i];
        if (tempSum > maxRightCross)
        {   
            crossEnd = i;
            maxRightCross = tempSum;
            
        }
        i++;
    }
   
    int totalCrossSum = maxLeftCross + maxRightCross;

    // 3가지 값들 중 큰 값을 return 
    if (leftMaxSum >= rightMaxSum && leftMaxSum >= totalCrossSum)
    {
        *startIndex = leftStart;
        *endIndex = leftEnd;
        return leftMaxSum;
    }
    else if (rightMaxSum >= leftMaxSum && rightMaxSum >= totalCrossSum)
    {
        *startIndex = rightStart;
        *endIndex = rightEnd;
        return rightMaxSum;
    }
    else
    {
        *startIndex = crossStart;
        *endIndex = crossEnd;
        return totalCrossSum;
    }
}



int kadane(int* ary, int n, int* first, int* final)  // 동적 프로그래밍  1차원 배열에서 최대 부분 배열을 찾아주는 역할을 수행, 음수만 있는 배열에서도 사용가능하도록 변형
{
    int maxSum = ary[0];  //  ary[]첫 번째 원소로 초기화
    int tempsum = ary[0];  // tempsum도 ary[] 첫 번째 원소로 초기화
    int sumstart = 0; // 부분 배열의 초기 시작첨을 0으로 초기화

    *first = 0;
    *final = 0;

    for (int i = 1; i < n; i++)
    {

        if (tempsum > 0)
        {
            tempsum += ary[i];
        }
        else // tempsum이 음수나 0 이라면 tempsum을 ary[i]로 새로 할당해주기 (ary  배열의 원소가 모두 음수더라도 최대로 큰 음수를 후에 return 할 수 있게 해준다.)
        {
            tempsum = ary[i];
            sumstart = i;  // 부분배열이 시작하는 새로운 점으로 갱신해주기 
        }


        if (tempsum > maxSum) // 최대 합 갱신 여부 확인
        {
            maxSum = tempsum;
            *first = sumstart;
            *final = i;
        }
    }

    return maxSum;
}



int algorithm05(int** matrix, int rows, int cols, int* startRow, int* startCol, int* endRow, int* endCol)
{
    int finalSum = MIN;
    int start, end;

    for (int Colleft = 0; Colleft < cols; Colleft++)// 시작 열 선택
    {

        int* temp = (int*)calloc(rows, sizeof(int));  // 고정된 열 범위 (left, right)에 대해 각 행 별로 그 행에 해당하는 범위의 열들의 합을 저장하는 temp 배열

        for (int Colright = Colleft; Colright < cols; Colright++) // 마지막 열 선택
        {

            for (int i = 0; i < rows; i++)
            {
                temp[i] += matrix[i][Colright];
            }


            int Sum = kadane(temp, rows, &start, &end);  // Kadane 알고리즘 적용해서  현재 열 범위에서 최대합 찾기

            if (Sum > finalSum)  // Sum > finalSum 할 때 값 갱신해주기 
            {
                finalSum = Sum;

                *startRow = start;  // 시작 행 
                *endRow = end;    // 종료 행 
                *startCol = Colleft; // 시작 열 
                *endCol = Colright;  // 종료 열 

            }
        }


        free(temp);
    }

    return finalSum;
}


