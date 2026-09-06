#define _CRT_SECURE_NO_WARNINGS
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_EDGES 50000000
#define MAX_VERTICES 10000

typedef struct 
{
   int start, finish, cost;
} Edge; // 간선의 시작점, 종점 및 비용을 저장하는 간선 구조체 선언


Edge minheap[MAX_EDGES +1]; // cost에 따른 minheap 배열 전역 변수로 선언

int disjointset[MAX_VERTICES]; // 전역 변수로 disjointset 선언

Edge result[MAX_EDGES]; // 최종 트리의 결과 배열 전역 변수로 선언

int heapnum = 0;
int s = 0; // 결과 배열의 인덱스 전역변수로 선언


void insertminheap(Edge item) // Edge 의 cost 값에 따라 minheap에 넣어주기
{
    int i = ++heapnum;

    for (; i > 1 && item.cost < minheap[i / 2].cost; i /= 2) 
    {
       minheap[i] = minheap[i / 2];

    }
    minheap[i] = item;
}

Edge deleteminheap() // minheap에서 가장 작은 cost를 갖는 루트 Edge 반환 및 정렬
{
    int parent = 1, child = 2;
    Edge minEdge = minheap[1];
    Edge lastEdge = minheap[heapnum--];

    for (; child <= heapnum; parent = child, child *= 2) 
    {
        if (child < heapnum && minheap[child].cost > minheap[child + 1].cost)
        {
            child++;
        }
        
        if (lastEdge.cost <= minheap[child].cost)
        {
            break;
        }
        
        minheap[parent] = minheap[child];
    }

    minheap[parent] = lastEdge;
    return minEdge;
}


int Find(int parent[], int i)  // 그 노드가 속한 트리의 루트 인덱스 반환
{
    while (parent[i] >= 0) 
    {
        i = parent[i];
    }
    return i;
}

void weightedUnion(int ri, int rj)  // weightedUnion 기법 사용
{
    
    int temp= disjointset[ri] + disjointset[rj];

    if (ri != rj) 
    {
        if (disjointset[ri] < disjointset[rj]) 
        {
            disjointset[ri] = temp;
            disjointset[rj] = ri;
        } 
        else 
        {
            disjointset[rj] = temp;
            disjointset[ri] = rj;
        }
    }
}



int Kruskal(Edge edges[], int V, int E) 
{
    
    int k=0;
    int finalcost = 0; 
    
    
    for (int j = 0; j < E; j++) 
    {
        insertminheap(edges[j]);
    }

    
    while (k < E) // edge 수 만큼 검사  
    {
        Edge curredge = deleteminheap();

        int rst = Find(disjointset, curredge.start);
        int rfi = Find(disjointset, curredge.finish);
        
        if (rst != rfi)  // 사이클이 발생하지 않는 경우에만 결과 배열에 추가
        {   
            result[s] = curredge;
            weightedUnion(rst, rfi);
            finalcost += curredge.cost; // 총 cost 업데이트
            s++;
        }
        k++;
    }

    return finalcost;
}

void writingfile(int V, int finalcost) 
{
    FILE* file = fopen("hw3_result.txt", "w");
   
    for (int i = 0; i < s; i++) 
    {
        fprintf(file, "%d %d %d\n", result[i].start, result[i].finish, result[i].cost);
    }

    fprintf(file, "%d\n", finalcost);

    if (s == V - 1) // 간선의 수가 v-1이라면 spanning tree 조건 만족하므로
    {
        fprintf(file, "CONNECTED\n");
    } 
    else 
    {
        fprintf(file, "DISCONNECTED\n");
    }

    fclose(file);
}

int main(int argc, char* argv[]) 
{
    clock_t Start = clock();
    if (argc != 2) 
    {
        printf("usage: ./hw3 input_filename\n");
        return 1;
    }

    FILE* file = fopen(argv[1], "r");

    if (file==NULL) 
    {
        printf("The input file does not exist.\n");
        return 1;
    }


    int V, E;

    fscanf(file, "%d", &V);// vertex 개수 읽어오기
    fscanf(file, "%d", &E);// edge 개수 읽어오기

 
    for (int i = 0; i < V; i++) 
    {
        disjointset[i] = -1;   // weighted union 위해 disjointset 배열 -1로 초기화
    }

    Edge* edges = (Edge*)malloc(E * sizeof(Edge));
   

    for (int j = 0; j < E; j++) 
    {
        fscanf(file, "%d %d %d", &edges[j].start, &edges[j].finish, &edges[j].cost);
    }


    int finalcost = Kruskal(edges, V, E); // 최종 비용 반환

    fclose(file);


    writingfile(V, finalcost);

    clock_t end = clock();

    double runningtime = ((double)(end - Start)) / CLOCKS_PER_SEC;

    printf("output written to hw3_result.txt.\n");

    printf("running time: %f seconds\n", runningtime);

    free(edges);
    return 0;


}
