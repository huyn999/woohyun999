#define CRT_SECURE_NO_WARNINGS
#define MAX_HEAP_SIZE 1000000

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>


int minHeap[MAX_HEAP_SIZE];
int maxHeap[MAX_HEAP_SIZE];
int minHeapnum = 0;
int maxHeapnum = 0;

void insert(int item);
void ascend();
void descend();

int main(int argc, char* argv[])
{
    clock_t start, end;
    double runningtime;
    start = clock(); //시작 시간 체크

    if (argc < 2) 
    {
        printf("usage: %s input_filename\n", argv[0]);
        return 1;
    }

    char* input = argv[1];

    FILE* file = fopen(input, "r");
    if (file == NULL) 
    {
        printf("The input file does not exist.\n");
        return 1;
    }

    FILE* initialize_file = fopen("hw2_result.txt", "w"); // 이전 hw2_result.txt 파일 초기화
    fclose(initialize_file);
    
    char command[20];
    int item;

    while (fscanf(file, "%s", command) != EOF)
    {
        switch (command[0])
        {
            case 'I': //insert
                fscanf(file, "%d", &item);
                insert(item);
                break;
            case 'A': //ascend
                ascend();
                break;
            case 'D': //descend
                descend();
                break;
            default: // 이외 명령 처리
                printf("This is wrong command: %s\n", command);
                return 1;
        }

    }
    fclose(file);
    printf("output written to hw2_result.txt.\n");

    end = clock(); // 끝나는 시간 체크

    runningtime =((double)(end - start)) / CLOCKS_PER_SEC;

    printf("running time: %f seconds\n", runningtime);

    return 0;
}


void insert(int item) // item 삽입
{
    if (minHeapnum == MAX_HEAP_SIZE|| maxHeapnum == MAX_HEAP_SIZE) // 더이상 item 삽입 불가시 eror처리
    {
        fprintf(stderr, " Heap is full of items.\n");
        exit(1);
    }
     
    int i,j;


    i = ++minHeapnum; // minHeap에 item  삽입
    while (item < minHeap[i / 2] && i > 1)
    {
        minHeap[i] = minHeap[i / 2];
        i /= 2;
    }
    minHeap[i] = item;

    
    j = ++maxHeapnum; // maxHeap에 item  삽입
    while (item > maxHeap[j/ 2] && j > 1 )
    {
        maxHeap[j] = maxHeap[j / 2];
        j /= 2;
    }
    maxHeap[j] = item;
}


void ascend()  // minHeap 이용
{
    int *copy = (int *)malloc((minHeapnum + 1) * sizeof(int));
    memcpy(copy, minHeap, (minHeapnum + 1) * sizeof(int));

    FILE* file = fopen("hw2_result.txt", "a");
    

    
    for (int copy_num = minHeapnum; copy_num> 0; copy_num--) 
    {
        int parent = 1;
        int child = 2;
        int temp;

        fprintf(file, "%d ", copy[1]);

        temp = copy[copy_num];

        for (; child <copy_num+1; child *= 2) 
        {
            if ((child < copy_num) && (copy[child] > copy[child + 1])) 
            {
                child++;
            }

            if (temp <= copy[child]) 
            {
                break;
            }

            copy[parent] = copy[child];
            parent = child;
        }

        copy[parent] = temp;
    }

    free(copy);
    fprintf(file, "\n");
    fclose(file);
}


void descend() // maxHeap 이용
 {
    int *copy = (int *)malloc((maxHeapnum + 1) * sizeof(int));
    memcpy(copy, maxHeap, (maxHeapnum + 1) * sizeof(int));

    FILE* file = fopen("hw2_result.txt", "a");
    

    
    for (int copy_num = maxHeapnum; copy_num > 0; copy_num--)
     {
        int parent = 1;
        int child = 2;
        int temp;

        fprintf(file, "%d ", copy[1]);

        temp = copy[copy_num];

        for (; child <copy_num+1; child *= 2) 
        {
            if ((child < copy_num) && (copy[child] < copy[child + 1])) 
            {
                child++;
            }

            if (temp >= copy[child]) 
            {
                break;
            }

            copy[parent] = copy[child];
            parent = child;
        }

        copy[parent] = temp;
    }

    free(copy);
    fprintf(file, "\n");
    fclose(file);
}
