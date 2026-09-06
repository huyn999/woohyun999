#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>


typedef struct { // edge 정보를 가지는 구조체 선언
    int start, end;  // edge의 시작점과 끝점
    int cost;  // edge의 비용
} GraphEdge;

//Disjoint Set 구조체 선언
typedef struct {
    int rank;  // 트리의 깊이 (랭크)
    int parent;  // 부모 노드 가르킴
    int numVertices;  // 해당 집합에 속하는 정점 수
    long long totalCost;  // 집합의 mst 비용
} DisjointSet;

// 최종 커넥티드 컴포넌트들의 결과를 저장하는 구조체 선언
typedef struct {
    int root;  // 컴포넌트의 루트 정점
    long long totalCost;  // 컴포넌트의 총 비용
    int mstVertices;  // 현재 커넥티드 컴포넌트에 속하는 정점 수
} ComponentResult;

// 글로벌 변수 선언

GraphEdge* edges;  // 그래프의 edge 배열
DisjointSet* sets;  //  유니온 find 하기 위한 disjoint set 배열
ComponentResult* components;  // 컴포넌트 결과 배열
int* isolation_check;  // 고립된 정점 체크 배열
int scannedEdges = 0;  // 스캔된 edge의 수
int numVertices = 0;  // graph의정점의 수
int numEdges = 0;  // graph의 edge의 수
int numComponents = 0;  // 최종 connected component의 수



// 함수 선언
DisjointSet* initializeSets(DisjointSet* sets);
void make_minheap(GraphEdge* heap, int n);
void adjustHeap(GraphEdge* heap, int n, int i);
int findRoot(DisjointSet* sets, int i);
void unionSets(DisjointSet* sets, int i, int j, long long edgeCost);
void kruskal(GraphEdge* edges);
void makeresult();
void quickSortComponents(ComponentResult* components, int left, int right);
int compareComponents(const void* a, const void* b);
GraphEdge extractMin(GraphEdge* heap, int* n);

#define MAX_PATH 256

int main() {
    clock_t start, end;
    double runningTime;

    FILE* file;
    file = fopen("commands.txt", "r");
    if (!file) {
        fprintf(stderr, "Failed to open 'commands.txt'.\n");
        exit(1);
    }

    char directory[256];  // 파일 절대 경로
    char inputFileName[256];  // 입력 파일 
    char outputFileName[256];  // 출력 파일 

    // fgets로 데이터 읽기
    fgets(directory, sizeof(directory), file);
    directory[strlen(directory) - 1] = '\0';  // 개행문자 제거

    fgets(inputFileName, sizeof(inputFileName), file);
    inputFileName[strlen(inputFileName) - 1] = '\0';  // 개행문자 제거

    fgets(outputFileName, sizeof(outputFileName), file);


    // 출력 파일 경로 생성
    char outputFilePath[256] = "";
    strcat(outputFilePath, outputFileName);

    FILE* outFile = fopen(outputFilePath, "w");
    if (!outFile) {
        fprintf(stderr, "Failed to open output file.\n");
        exit(1);
    }

    // 입력 파일 경로 생성
    char inputFilePath[256] = "";
    strcat(inputFilePath, directory);  // 절대 경로 디렉토리 경로 추가 
    strcat(inputFilePath, "\\");  // 경로 구분자 추가 Windows 전용
    strcat(inputFilePath, inputFileName);  // 입력 파일 이름을 경로에 더해준다

    FILE* inFile = fopen(inputFilePath, "r");
    if (!inFile) {
        fprintf(stderr, "Failed to open input file.\n");
        printf("잘못된 복사 붙이기가 발생한것일 것입니다. utf 인코딩 문제등등을 확인하세요\n");
        printf("현재 해석되는 이름 나열\n");
        printf("Input Directory: %s\n", directory);
        printf("Input File Name: %s\n", inputFileName);
        printf("Output File Name: %s\n", outputFileName);
        exit(1);
    }
    long long maxEdgeCost;  // 간선의 최대 비용 

    fscanf(inFile, "%d %d %lld", &numVertices, &numEdges, &maxEdgeCost);  // 첫 번째 줄에서 정점 수, 간선 수, 최대 비용 읽기

    edges = (GraphEdge*)malloc(sizeof(GraphEdge) * numEdges);


    sets = initializeSets(sets);  // disjoint set을 만들고 각 disjoint set을 초기화 한다.





    isolation_check = (int*)malloc(sizeof(int) * numVertices);  // 격리된 정점 체크 배열 동적 할당
    // 고립된 정점 체크 배열 초기화, 이후 최종적으로 몇개의 connected component가 있는지 검사하기 위해 사용
    for (int i = 0; i < numVertices; i++)
    {
        isolation_check[i] = -1;  // 모든 정점은 처음에 격리되어 있음(-1 이면 격리됨을 표시)
    }


    int startVertex, endVertex, edgeCost;
    GraphEdge edge;
    int index = 0;// edge의 수

    //input file에서 edge 정보 읽기
    while (fscanf(inFile, "%d %d %d", &startVertex, &endVertex, &edgeCost) == 3)
    {
        if (edgeCost < 0 || edgeCost > maxEdgeCost) {  // edgecost가 범위를 벗어나면 에러처리
            fprintf(stderr, "Edge cost out of range.\n");
            exit(1);
        }
        if (endVertex < 0 || endVertex >= numVertices || startVertex < 0 || startVertex >= numVertices) {  // 정점 index가 범위를 벗어나면 에러처리
            fprintf(stderr, "Vertex ID out of range.\n");
            exit(1);
        }
        edge.start = startVertex; //시작점 저장
        edge.end = endVertex; // 끝점 저장
        edge.cost = edgeCost;  // edge 비용 할당
        edges[index++] = edge;  // 그래프 배열에 edge 추가
    }


    components = (ComponentResult*)malloc(sizeof(ComponentResult) * numVertices);  // 컴포넌트 결과 배열 동적 할당

    start = clock();  // 실행 시작 시간 측정

    kruskal(edges);  // 크루스칼 알고리즘 실행

    end = clock();  // 실행 종료 시간 측정

    makeresult();//출력파일에 connected component들 별로 쓸 준비 만약 connected graph라면 1개만 쓰면 된다.


    quickSortComponents(components, 0, numComponents - 1); //  컴포넌트 정렬을 quick sort로 수행


    // 터미널 창에 정보 출력 

    printf("number of connected components:%d\n", numComponents);
    for (int i = 0; i < numComponents; i++) {
        printf("mst_vertices_count: %d, mst_cost:%lld\n", components[i].mstVertices, components[i].totalCost);  // 각 컴포넌트 내의 정점 수와 총 비용 출력
    }

    printf("number of k scanned time: %d\n", scannedEdges);  // 스캔된 edge 수 출력
    runningTime = ((double)(end - start)) / CLOCKS_PER_SEC;
    printf("Running time for kruskal: %lf seconds\n", runningTime);  // 실행 시간 출력

    // 결과를 출력 파일에 출력
    fprintf(outFile, "%d\n", numComponents);
    for (int i = 0; i < numComponents; i++)
    {
        fprintf(outFile, "%d %lld\n", components[i].mstVertices, components[i].totalCost);  // 컴포넌트의 정점 수와 총 비용 출력
    }

    // 파일 닫기
    fclose(file);
    fclose(inFile);
    fclose(outFile);

    // 동적 할당된 메모리 해제
    free(components);
    free(edges);
    free(sets);
    free(isolation_check);

    return 0;  // 프로그램 종료

}




DisjointSet* initializeSets(DisjointSet* sets)
{
    // disjoint set배열을 동적 할당하고 초기화
    sets = (DisjointSet*)malloc(sizeof(DisjointSet) * numVertices);

    for (int i = 0; i < numVertices; i++)
    {
        sets[i].parent = i;  // 각 정점은 자기 자신을 부모로 가르킨다
        sets[i].rank = 0;  // 랭크 0으로 설정, 아직 트리구조를 만족하는 것이 아니므로
        sets[i].totalCost = 0;  //  초기 각 disjoint 집합에 속하는 정점들은 아직 연결된 edge가 없으므로 0
        sets[i].numVertices = 1;  //  초기 각 disjoint 집합에 속하는 정점의 수는 1개이다
    }
    return sets;
}


int findRoot(DisjointSet* sets, int i)
{
    if (isolation_check[i] == -1)// 만약 그 점이 원래 고립되어 있었다면 
    {
        return i;// 자기 자신 인덱스가 루트이므로 바로 반환
    }
    if (sets[i].parent != i) // 부모가 자기 자신 인덱스를 가르키지 않는다면
    {
        sets[i].parent = findRoot(sets, sets[i].parent);  //  경로 압축을 하며 재귀적으로 루트를 찾고
    }
    return sets[i].parent;//  그 점이 속한 트리의 루트값을 반환
}


void unionSets(DisjointSet* sets, int iRoot, int jRoot, long long edgeCost) {// union bty rank에 의해 트리를 합친다.
    if (sets[iRoot].rank > sets[jRoot].rank)
    {   // 한쪽 랭크가 더 작으면 작은쪽을  위로 합쳐준다.
        sets[jRoot].parent = iRoot;   // 아래 트리 부모를 위에 트리 루트로 설정


        sets[iRoot].totalCost += sets[jRoot].totalCost + edgeCost;
        // mst가 만들어 지고 있는것 이므로 두 트리를 합칠 때 현재 연결되는 edge비용과 기존 트리의 edge 비용들을 합쳐준다
        sets[iRoot].numVertices += sets[jRoot].numVertices;

        // 마찬가지로 mst가 만들어지고 있으므로 그때 한쪽 트리의 기존 정점수를 큰 트리의 정점수에 더 해주면 현재 mst의 총 정점수를 나타낼 수 있다


    }
    else if (sets[iRoot].rank < sets[jRoot].rank) // 위와 같은 로직으로 구현한 것이다.
    {
        sets[iRoot].parent = jRoot;
        sets[jRoot].totalCost += sets[iRoot].totalCost + edgeCost;
        sets[jRoot].numVertices += sets[iRoot].numVertices;

    }
    else {  //  두 트리가 같은 랭크일 경우에는  랭크 하나 증가 시키면서 하나의 트리로 합친다
        sets[jRoot].parent = iRoot;

        sets[iRoot].totalCost += sets[jRoot].totalCost + edgeCost;
        // mst가 만들어 지고 있는것 이므로 두 트리를 합칠 때 현재 연결되는 edge비용과 기존 트리의 edge 비용들을 합쳐준다
        sets[iRoot].rank++;
        // 랭크 증가는 같은 트리 랭크 두개를 합칠때만 일어난다. 이것이 union by rank의 핵심

        sets[iRoot].numVertices += sets[jRoot].numVertices;
        // mst가 만들어지고 있으므로 그때 한쪽 트리의 기존 정점수를 큰 트리의 정점수에 더 해주면 현재 mst의 총 정점수를 나타낼 수 있다
    }
}



void make_minheap(GraphEdge* heap, int n) // o(n)으로 minheap 만들어주기, 배열 인덱스가 0부터 시작하는 걸 곧바로 적용시킨 minheap이다
{
    for (int i = n / 2 - 1; i >= 0; i--)  // 마지막 자식을 갖는 부모부터 시작하여 minheap을 구성한다.
    {
        adjustHeap(heap, n, i);// min heap 성질을 갖도록 해주는 adjust 기능 수행
    }
}

void adjustHeap(GraphEdge* heap, int n, int i)
{
    int tempCost = heap[i].cost;  // 현재 부모 노드의 비용을 임시 저장
    GraphEdge tempEdge = heap[i]; // 현재 부모 노드의 원소를 저장


    int parent = i;// 부모 노드의 인덱스

    for (int child = 2 * parent + 1; child < n; child = 2 * parent + 1)
    {
        // 오른쪽 자식이 존재하고 더 작은 경우 오른쪽 자식을 선택
        if (child + 1 < n && heap[child].cost > heap[child + 1].cost)
        {
            child++;
        }

        // 자식 노드가 부모 노드보다 크거나 같으면 반복 종료
        if (heap[child].cost >= tempCost)
        {
            break;
        }

        // 그렇지 않다면 부모 자리에 자식 노드 값을 올림
        heap[parent] = heap[child];

        // 부모를 현재 자식 노드로 이동
        parent = child;
    }

    // 최종적으로 부모 자리에 임시 저장된 원소를 넣어준다
    heap[parent] = tempEdge;
}




GraphEdge extractMin(GraphEdge* heap, int* n)
{
    if (*n == 0)
    {  // 힙이 비어있으면 에러 처리
        fprintf(stderr, "Heap is empty.\n");
        exit(1);
    }

    GraphEdge minEdge = heap[0];  // 루트에 있는 최소값을 저장하고
    heap[0] = heap[--(*n)];  // 마지막  인덱스 원소를 루트로 이동
    adjustHeap(heap, *n, 0);  // 다시 minheap 성질을 유지하도록 adjust

    return minEdge;// 추출한 edge를 반환
}


void kruskal(GraphEdge* edges) // 크루스칼 알고리즘 구현 o(elogv)
{
    GraphEdge currentEdge;// 현재 조사하는 edge

    int edgeCount = 0;// 조사한 edge 개수
    int remainingEdges = numEdges;// 조사하는 남은 edge 개수

    make_minheap(edges, numEdges);  // edges 배열이 cost를 기준으로 minheap을 만족하게 만든다



    while (remainingEdges > 0) // graph에 존재하는 edge들의 개수만큼 반복
    {
        if (edgeCount == numVertices - 1)
        {
            break; // edge수가 numVertices - 1개가 될 때까지 반복 n-1개이면 모든 vertex가 연결된 mst가 만들어진 것이기 때문에 반복문 탈출
        }
        currentEdge = extractMin(edges, &remainingEdges);  // 최소 비용을 갖는 edge를 추출
        scannedEdges++;  // 스캔된 간선 수 증가

        int root1 = findRoot(sets, currentEdge.start);  // 시작 정점의 루트 찾기
        int root2 = findRoot(sets, currentEdge.end);    // 끝 정점의 루트 찾기

        if (root1 != root2) {  // 두 정점이 다른 집합에 속해있다면  union 해준다

            unionSets(sets, root1, root2, currentEdge.cost);  // 두 트리를 합치고

            isolation_check[currentEdge.start] = 1;//  시작 vertex는 고립되지 않음을 표시한다
            isolation_check[currentEdge.end] = 1;//  끝 vertex는 고립되지 않음을 표시한다

            edgeCount++;  // edge 수를 늘려준다
        }
    }


}

void makeresult()// 결과 배열 components를 만들어주는 함수 
{
    int disconnect = 0;// 최종 몇개의 connected component가 몇개 있는지 추적하기 위한 변수 

    for (int i = 0; i < numVertices; i++) {  // 그래프가 connected가 아닐 수 있으므로 최종적인 connected component 출력


        if (isolation_check[i] == -1)// 만약 고립된 정점이라면
        {
            int root = i;
            components[disconnect].root = root;   // 루트는 자기 자신
            components[disconnect].totalCost = 0;  // 비용 0으로 설정
            components[disconnect].mstVertices = 1;  // 정점 1개로 설정(고립된 정점 1개 존재하는 connected component 이므로)
            disconnect++; // connected component 개수 1개 증가 시켜준다
        }
        else if (isolation_check[i] != -1 && findRoot(sets, i) == i)// 최악의 경우 o(logv) 시간 복잡도
        {  // 고립된 정점이 아니고 만약 그 정점의 루트가 자기 자신이어야 어떤 connected  component에서 루트를 나타내는 정점이다
            int root = i;
            components[disconnect].root = root;// 루트는 자기 자신
            components[disconnect].totalCost = sets[root].totalCost;  // connected component를 구성하는 총 비용 넣어주기
            components[disconnect].mstVertices = sets[root].numVertices;  // connected component의 총 정점수 넣어주기
            disconnect++;// connected component 개수 1개 증가 시켜준다
        }
    }

    numComponents = disconnect;  // connected component 수 저장
}

void quickSortComponents(ComponentResult* components, int left, int right)
{
    // left가 right보다 작을 때만 정렬을 수행한다.
    if (left < right) {
        // pivot으로 사용할 인덱스를 중앙값으로 설정
        int pivotIndex = (left + right) / 2;
        ComponentResult pivot = components[pivotIndex];  // 중앙값을 피벗으로 선택
        int i = left, j = right;

        // 바깥 while 문을 사용하여 i와 j가 교차할 때까지 반복
        while (i <= j)
        {
            // i가 pivot보다 작은 값일 경우, 계속해서 오른쪽으로 이동
            for (; compareComponents(&components[i], &pivot) < 0; i++) {}

            // j가 pivot보다 큰 값일 경우, 계속해서 왼쪽으로 이동
            for (; compareComponents(&components[j], &pivot) > 0; j--) {}


            if (i <= j) // i가 j보다 작거나 같으면 두 원소를 교환해준다.
            {
                ComponentResult temp = components[i];
                components[i] = components[j];
                components[j] = temp;

                i++;
                j--;
            }
        }

        // 왼쪽 부분 배열에 대해 재귀적으로 quickSort 함수 호출
        if (left < j)
        {
            quickSortComponents(components, left, j);
        }


        // 오른쪽 부분 배열에 대해 재귀적으로 quickSort 함수 호출
        if (i < right)
        {
            quickSortComponents(components, i, right);
        }
    }
}



int compareComponents(const void* a, const void* b)//number of vertices로 오름차순으로 정렬한 후, 같은 것들은 total weight로 정렬
{
    ComponentResult* compA = (ComponentResult*)a;
    ComponentResult* compB = (ComponentResult*)b;


    if (compA->mstVertices != compB->mstVertices) // 1차 기준으로  mstVertices(정점 수) 기준으로 비교
    {
        return compA->mstVertices - compB->mstVertices;
    }


    return compA->totalCost - compB->totalCost;// 2차 기준으로 totalCost(총 비용) 기준으로 비교
}