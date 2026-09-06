#include "records.h"

void RECORDS::sort_records_insertion(int start_index, int end_index)  // 이미 구현된 것 
{
    // Insertion sort
    for (int i = start_index + 1; i <= end_index; i++)
    {
        RECORD tmp = records[i];
        int j = i;
        while ((j > start_index) && (compare_keys((const void*)&tmp, (const void*)(&records[j - 1])) < 0)) 
        {
            records[j] = records[j - 1];
            j--;
        }
        records[j] = tmp;
    }
}



void RECORDS::sort_records_heap(int start_index, int end_index)
{
    int n = end_index - start_index + 1; // 정렬할 원소 수

    RECORD* temp_arr = new RECORD[n + 1]; // 1 base 인덱스를 위해 임시 배열 생성

    for (int i = 0; i < n; ++i)
    {
        temp_arr[i + 1] = records[start_index + i]; // records[start_index]부터 복사
    }

    for (int i = n / 2; i >= 1; i--) // 자식을 가지고 있는 가장 큰 노드부터 수행해서 maxheap 구조를 만듦
    {
        int root = i;
        int child = 2 * root;

        RECORD temp = temp_arr[root];

        for (child = 2 * root; child <= n; child = 2 * root)
        {
            if (child < n&& temp_arr[child].key < temp_arr[child + 1].key)
            {
                child++;
            }

            if (temp.key > temp_arr[child].key)  // 자식보다 키값이 더 크다면 탈출
            {
                break;
            }

            temp_arr[root] = temp_arr[child];
            root = child;
        }

        temp_arr[root] = temp; // 알맞은 자리에 temp 할당
    }

    for (int i = n; i > 1; i--) {  // maxheap에서 원소를 하나씩 꺼내 정렬

        std::swap(temp_arr[1], temp_arr[i]); // 가장 큰 원소와 배열의 마지막 요소를 교환 

        int root = 1; // 이후 맨 마지막 요소를 하나 뺀 배열에 대해 다시 max heap 구조를 만족하도록 adjust

        RECORD temp = temp_arr[root];

        for (int child = 2 * root; child < i; child = 2 * root) 
        {
            if (child + 1 < i && temp_arr[child].key < temp_arr[child + 1].key)
            {
                child++;
            }

            if (temp.key > temp_arr[child].key) // 자식보다 키값이 더 크다면 탈출
            {
                break;
            }

            temp_arr[root] = temp_arr[child];
            root = child;
        }

        temp_arr[root] = temp; // 알맞은 자리에 temp 할당
    }

    for (int i = 0; i < n; ++i) // 다시 0 base로 만듦
    {
        records[start_index + i] = temp_arr[i + 1];
    }

    delete[] temp_arr;
}

void RECORDS::sort_records_weird(int start_index, int end_index)
{
    int n = end_index - start_index + 1; // 정렬할 원소 수

    RECORD* temp_arr = new RECORD[n + 1]; // minheap 구조에서 1-base 인덱스를 위해 임시 배열 생성

    for (int i = 0; i < n; ++i)
    {
        temp_arr[i + 1] = records[start_index + i]; // records[start_index]부터 복사
    }

    for (int i = n / 2; i >= 1; i--) { // 자식을 가지고 있는 가장 큰 노드부터 수행해서 minheap 구조를 만듦

        int root = i;
        RECORD temp = temp_arr[root];

        for (int child = 2 * root; child <= n; child = 2 * root) 
        {
            if (child < n && temp_arr[child].key > temp_arr[child + 1].key)
            {
                child++;
            }

            if (temp.key < temp_arr[child].key) // 자식보다 키값이 더 작다면 탈출
            {
                break;
            }

            temp_arr[root] = temp_arr[child];
            root = child;
        }

        temp_arr[root] = temp; // 알맞은 자리에 temp 할당
    }

    for (int i = 0; i < n; ++i) // 다시 0 base로 만듦
    {
        records[start_index + i] = temp_arr[i + 1];
    }

    delete[] temp_arr;

    sort_records_insertion(start_index, end_index); // minheap 결과에 insertion sort를 적용
}



void RECORDS::sort_records_quick_classic(int start_index, int end_index)
{
    if (start_index < end_index) // start_index가 end_index보다 작은 경우 같으면 실행 안해도 된다.
    {
        int pivot = records[end_index].key; // 정렬할 배열의 마지막 요소를 pivot으로 선택

        int i = (start_index - 1);
        int j = start_index;

        while (j < end_index) // partion 해주는 역할을 수행 pivot을 기준으로 작은 요소들은 pivot 인덱스 보다 왼쪽에 반대의 경우 오른쪽에 할당해주는 분할 역할을 수행
        {
            if (records[j].key < pivot)
            {
                i++;
                std::swap(records[i], records[j]);
            }
            j++;
        }

        std::swap(records[i + 1], records[end_index]);
        int pivotIndex = i + 1; // 피벗의 최종 인덱스 할당


        // 피벗을 기준으로 재귀적으로 함수 호출하여 남은 두 배열 정렬
        sort_records_quick_classic(start_index, pivotIndex - 1); // 피벗 앞 요소 정렬

        sort_records_quick_classic(pivotIndex + 1, end_index); // 피벗 뒤 요소 정렬
    }
}


void RECORDS::sort_records_intro(int start_index, int end_index)
{
    static int max_depth = 2 * log2(end_index - start_index + 1); // 재귀 함수의 최대 깊이를 설정, 최초 호출 시 max_depth를 설정 이후 재귀 함수에서는 이전의 max_depth 값이 쓰임

    if (start_index < end_index) // 정렬할 요소가 있는 경우에만 실행
    {
        int n = end_index - start_index + 1;

        if (n <= 20) {  // 원소 수가 20이하일 경우 insertion sort를 사용
            sort_records_insertion(start_index, end_index);
            return;
        }

        if (max_depth == 0) // max_depth가 0일 때 heap sort를 사용
        {
            sort_records_heap(start_index, end_index);
            return;
        }

        int mid_index = start_index + (end_index - start_index) / 2;

        RECORD& first = records[start_index];
        RECORD& mid = records[mid_index];
        RECORD& last = records[end_index];

        if (first.key > mid.key) std::swap(first, mid);
        if (first.key > last.key) std::swap(first, last);
        if (mid.key > last.key) std::swap(mid, last);

        int pivot = mid.key; // pivot을 배열의 첫 번째, 중간, 마지막 요소 중 중앙값으로 선택

        std::swap(records[mid_index], records[end_index]); // partion 수행하기 위해 records 배열의 중간 인덱스 부분과 마지막 부분을 swap

        int i = start_index - 1;
        int j = start_index;

        
        while (j < end_index)
        {
            if (records[j].key < pivot)  // partion 해주는 역할을 수행 pivot을 기준으로 작은 요소들은 pivot 인덱스 보다 왼쪽에 반대의 경우 오른쪽에 할당해주는 분할 역할을 수행
            {
                i++;
                std::swap(records[i], records[j]);

            }

            j++;
        }

        std::swap(records[i + 1], records[end_index]);

        int pivotIndex = i + 1; // 피벗의 최종 인덱스 할당

        int temp_depth = max_depth;  // 현재 재귀함수의 깊이를 임시 깊이에 저장
        max_depth--;  // 재귀 호출 시 max_depth 감소

        sort_records_intro(start_index, pivotIndex - 1);  // 첫 구간 정렬
        sort_records_intro(pivotIndex + 1, end_index);    // 두 번째 구간 정렬

        max_depth = temp_depth;  // 하위 재귀 함수 호출을 마치고 돌아올 때 호출한 재귀함수의 max_depth 복원

    }
}


void RECORDS::sort_records_merge_with_insertion(int start_index, int end_index)
{
    if (end_index - start_index <= 20) // 원소 수가 20 이하일 경우
    { 
        sort_records_insertion(start_index, end_index); // insertion sort 실행
        return; 
    }

    int mid = (start_index + end_index) / 2; // divide 하는 부분

    
    //conquer 하는 부분
    sort_records_merge_with_insertion(start_index, mid); // 왼쪽 반 정렬
    sort_records_merge_with_insertion(mid + 1, end_index); // 오른쪽 반 정렬


    // Merge 하는 부분
    int lsize= mid - start_index + 1; // 왼쪽 배열 크기
    int rsize = end_index - mid; // 오른쪽 배열 크기

    RECORD* lefttmp = new RECORD[lsize]; // 왼쪽 배열을 복사할 임시배열
    RECORD* righttmp = new RECORD[rsize]; // 오른쪽 배열을 복사할 임시배열

    for (int i = 0; i < lsize; i++)
    {
        lefttmp[i] = records[start_index + i]; // 왼쪽 배열의 원소 복사

    }
        
    for (int i = 0; i < rsize; i++)
    {
        righttmp[i] = records[mid + 1 + i]; // 오른쪽 배열의 원소 복사

    }


    // 반복문 쓰기 위해 원소들 초기화
    int i = 0, j = 0;
    int s = start_index;

    while (i < lsize && j < rsize)  // 두 배열을 비교하여 원소를 병합시킴
    { 
        if (lefttmp[i].key < righttmp[j].key) // 왼쪽 배열의 원소가 더 작을 때
        {
            records[s++] = lefttmp[i++]; 
        }
        else // 오른쪽 배열의 원소가 더 작을 때
        {
            records[s++] = righttmp[j++]; 
        }
    }

    
    while (i < lsize)  //왼쪽이나  오른쪽 배열의 남은 원소 추가
    { 
        records[s++] = lefttmp[i++];
    }
    while (j < rsize)
    { 
        records[s++] = righttmp[j++];
    }

    delete[] lefttmp; 
    delete[] righttmp; 
}
