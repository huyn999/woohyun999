#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>

#define MAX_VERTICES 201

int vertex_count = 0; // 다각형 꼭짓점 수
typedef struct Point
{
    double x;
    double y;
} Point; // 다각형을 구성하는 점의 x,y좌표를 나타내는 구조체 선언

Point vertices[MAX_VERTICES]; // 꼭짓점 좌표를 저장하는 배열

typedef struct EdgePair
{
    int vertex1;
    int vertex2;
} EdgePair; // 대각선을 이루는 점들의 다각형 내 인덱스 쌍을 나타내는 구조체 선언


// malloc 사용시 메모리 오류가 나올 가능성이 있다고 생각하여  전역변수로 배열및 변수들을 선언하였다.

EdgePair chords[MAX_VERTICES]; // 각 대각선의 쌍들을 저장할 배열 chords
int chord_count = 0; // chords 개수 

int partition_table[MAX_VERTICES][MAX_VERTICES]; // 최소 비용 삼각화를 위해 분할 지점을 저장하는 테이블
double cost_table[MAX_VERTICES][MAX_VERTICES]; // 최소 비용 삼각화를 저장하는 테이블


double calculate_triangulation(); // 삼각화 계산 함수
double compute_distance(int vertex1, int vertex2); // 두 꼭짓점 간의 거리 계산 함수
void find_chords(int start, int size); // 최소 삼각화 비용을 만들어 내는 쌍들을 찾아 chords 배열에 저장해주는 함수 
void reset_data(); // 전역 변수 및 데이터 초기화 함수


// 대각선을 이루는 점들의 쌍을 명세서에서 요구하는대로 정렬하기 위해 퀵소트를 사용하였다.
void swap_chords(EdgePair* a, EdgePair* b);
int partition(EdgePair arr[], int low, int high);
void quick_sort_chords(EdgePair arr[], int low, int high);

double compute_distance(int vertex1, int vertex2)
{
    int difference = abs(vertex1 - vertex2); // 점 사이의 index 차이를 절대값으로 구해준다.

    if (difference == 1 || difference == vertex_count - 1)// 두 점이 인접하거나 또는 다각형의 첫번째 점과 마지막 점도 인접하므로 이 경우를 고려해서 
    {
        return 0.0;// 대각선이 아니므로 0을 반환 
    }
    else  // 이외의 경우는 피타고라스 방식으로 점 사이의 거리를 구함 ( 유효한 대각선의 길이 비용 산출)
    {
        double dx = vertices[vertex1].x - vertices[vertex2].x;
        double dy = vertices[vertex1].y - vertices[vertex2].y;
        return sqrt(dx * dx + dy * dy);
    }
}

double calculate_triangulation()
{
    double min_cost, current_cost;

    for (int size = 0; size <= 3; size++)   // size가 0에서 3이하 일때는 삼각화 자체가 불가 하므로  cost_table의 값을 0으로 초기화 해주었다.
    {
        for (int i = 0; i <= vertex_count - size; i++)
        {
            cost_table[size][i] = 0.0;
        }
    }

    for (int gap = 0; gap < vertex_count - 3; gap++)  // 동적프로그래밍의 원리에 따라 오른쪽 아래 부터 왼쪽 위 방향의 대각선으로 아래에서 부터 위까지 채워나가는 방식을 선택해 작성하였다.
    {
        for (int size = 4; size <= 4 + gap; size++) // size가 4이상 부터 삼각화가 가능하므로 4이상부터 작성하였다 나머지는 위에서 이미 0으로 초기화 완료
        {
            int start = gap + 4 - size; //gap을 이용해 대각선 방향으로 cost table을 채워 나가는 방식을 사용할 수 있게 하였다.
            if (start <= vertex_count - size) // 삼각화가 가능한지를 check
            {
                min_cost = INFINITY;// 삼각화 최소비용을 무한대로 일단 큰 값을 설정

                for (int split = 1; split <= size - 2; split++) // start인덱스로부터의 상대적 분할 지점 split(1~size-2)을 for문을 통해 옮겨가면서 그때의 대각선 비용 current_cost가  min_cost 보다 적은지를 확인해 준다
                {
                    current_cost = cost_table[split + 1][start] + cost_table[size - split][start + split] + compute_distance(start, start + split) + compute_distance(start + split, start + size - 1);// optimal structure 이용

                    if (current_cost < min_cost)// 새로 더 작은 비용을 발견했다면
                    {
                        min_cost = current_cost; // min_cost 값을 새로 갱신
                        partition_table[size][start] = split;// 그때의 분할 지점 index인 split을  partition_table[size][start]에 저장
                    }
                }

                cost_table[size][start] = min_cost;// 최종적으로 최소값을  cost_table[size][start]에 저장해준다
            }
        }
    }

    return cost_table[vertex_count][0];// 우리가 구하고자 하는 최소 대각선 비용 반환 
}

void find_chords(int start, int size)
{
    int split = partition_table[size][start]; // 기존에 최소 삼각화 비용 테이블 계산에서 작성한 partition_table으로부터 start 점으로부터의 상대적 분할 지점 가져오기

    if (split > 1) // start점으로부터 분할지점의 상대적 위치가 2이상이여야 대각선을 만들 수 있다. 인접할경우는 대각선이 아니기 때문
    {
        chords[chord_count].vertex1 = start; // 시작점
        chords[chord_count].vertex2 = start + split; // 분할 지점의 실제 인덱스
        chord_count++;
    }

    if (size - 1 > split + 1) // 마찬가지로 다각형의 끝나는 점으로부터 분할 지점의상대적 위치가 2이상이여야 대각선을 만들 수 있다. 인접할경우는 대각선이 아니기 때문
    {
        chords[chord_count].vertex1 = start + split; // 분할 지점의 실제 인덱스
        chords[chord_count].vertex2 = start + size - 1; // 끝점 
        chord_count++;
    }

    int left_size = split + 1; // 분할 지점과 왼쪽 대각선으로부터 생성되는 다각형의 사이즈
    int right_start = start + split; // 분할 지점과 오른쪽 대각선으로부터 생성되는 다각형의 시작 인덱스 할당
    int right_size = size - split; // 분할 지점과 오른쪽 대각선으로부터 생성되는 다각형의 사이즈

    if (left_size >= 4) // 사이즈가 최소 4이상이어야 삼각화를 위해 분할 할 수 있다.
    {
        find_chords(start, left_size); // 재귀적으로 왼쪽 다각형 처리
    }
    if (right_size >= 4)
    {
        find_chords(right_start, right_size); // 재귀적으로 오른쪽 다각형 처리
    }
    return;
}

void swap_chords(EdgePair* a, EdgePair* b)  //두 대각선 쌍의 순서를 swap 해주는 역할 
{
    EdgePair temp = *a;
    *a = *b;
    *b = temp;
}

int partition(EdgePair arr[], int low, int high) // 퀵소트를 위해 partion 해주는 함수  명세서 요청에 따르는 순서애 맞게 partion 해준다.
{
    EdgePair pivot = arr[high];
    int i = low - 1;

    for (int j = low; j < high; j++)
    {
        if (arr[j].vertex1 < pivot.vertex1 || (arr[j].vertex1 == pivot.vertex1 && arr[j].vertex2 < pivot.vertex2))
        {
            i++;
            swap_chords(&arr[i], &arr[j]);
        }
    }
    swap_chords(&arr[i + 1], &arr[high]);
    return i + 1;
}

void quick_sort_chords(EdgePair arr[], int low, int high)// pivot을 기준으로 재귀적으로 대각선 쌍들의 순서를 정렬한다.
{
    if (low < high)
    {
        int pivot_index = partition(arr, low, high);
        quick_sort_chords(arr, low, pivot_index - 1);
        quick_sort_chords(arr, pivot_index + 1, high);
    }
}

void reset_data() // 기존의 작성한 전역변수에 저장한 데이터들을 초기화 해주는 역할을 수행
{
    chord_count = 0;
    vertex_count = 0;
    for (int i = 0; i < MAX_VERTICES; i++)
    {
        chords[i].vertex1 = 0;
        chords[i].vertex2 = 0;
        for (int j = 0; j < MAX_VERTICES; j++)
        {
            partition_table[i][j] = 0;
            cost_table[i][j] = 0.0;
        }
    }
}

int main()
{
    FILE* command_file;
    int test_case_count = 0;
    char input_filename[100];
    char output_filename[100];
    double triangulation_cost = 0;

    // 명령 파일을 열기
    command_file = fopen("MT_command.txt", "r");
    if (!command_file)
    {
        fprintf(stderr, "Error opening command file!\n");
        exit(1);
    }
    fscanf(command_file, "%d\n", &test_case_count);

    for (int i = 0; i < test_case_count; i++)
    {
        fscanf(command_file, "%s %s\n", input_filename, output_filename);

        // 파일 초기화
        chord_count = 0;
        vertex_count = 0;

        for (int i = 0; i < MAX_VERTICES; i++)
        {
            chords[i].vertex1 = 0;
            chords[i].vertex2 = 0;
            for (int j = 0; j < MAX_VERTICES; j++)
            {
                partition_table[i][j] = 0;
                cost_table[i][j] = 0.0;
            }
        }

        // 입력 파일 열기
        FILE* input_file = fopen(input_filename, "r");
        if (!input_file)
        {
            fprintf(stderr, "Error opening input file!\n", input_filename);
            fclose(command_file);
            exit(1);
        }

        fscanf(input_file, "%d\n", &vertex_count);
        if (vertex_count >= MAX_VERTICES)
        {
            fprintf(stderr, "There are too many vertices!\n");
            fclose(input_file);
            fclose(command_file);
            exit(1);
        }

        for (int i = 0; i < vertex_count; i++)
        {
            fscanf(input_file, "%lf %lf\n", &vertices[i].x, &vertices[i].y);
        }
        fclose(input_file);

        // 최소 삼각화 비용 계산
        triangulation_cost = calculate_triangulation();
        find_chords(0, vertex_count); // 대각선 쌍 찾기
        quick_sort_chords(chords, 0, chord_count - 1); // 대각선 정렬

        // 출력 파일 열기
        FILE* output_file = fopen(output_filename, "w");
        if (!output_file)
        {
            fprintf(stderr, "Error opening output file!\n", output_filename);
            fclose(command_file);
            exit(1);
        }
        fprintf(output_file, "%.3lf\n", triangulation_cost);

        for (int i = 0; i < chord_count; i++)
        {
            fprintf(output_file, "%d %d\n", chords[i].vertex1, chords[i].vertex2);
        }
        fclose(output_file);
    }

    fclose(command_file);

    printf("Work is completed! Check the output file.\n");

    return 0;
}
