
#define _CRT_SECURE_NO_WARNINGS  
#include <stdio.h> 
#include <stdlib.h> 
#include <string.h> 


typedef enum { BOTH, LEFT, UP } Direction; // BOTH, LEFT, UP은 lps를 찾을때 사용한 기존 테이블로부터 온 방향을 표시해준다. 


void write_lps(char* str, Direction** path, int start, int end, int* l_idx, int* r_idx, char* lps_result) // 실제 구하는 회문을 lps_result 배열에 저장해주는 함수
{
    if (start > end) return;  // start가 end보다 커지면 더 이상 계산할 필요가 없다


    if (path[start][end] == BOTH) // path[start][end]가 BOTH이면, 현재 start와 end 문자가 LPS에 포함되므로 해당 문자를 lps_result 배열의 양끝에 넣어준다. 문자가 하나일 경우에도 BOTH로 처리해 후에 회문 출력에 이용
    {
        lps_result[(*l_idx)++] = str[start];
        lps_result[(*r_idx)--] = str[end];
        write_lps(str, path, start + 1, end - 1, l_idx, r_idx, lps_result); // 재귀 호출로 앞뒤 하나씩을 제외한 나머지 범위에 대한 회문을 찾아 lps_result에 저장할 수 있게한다.
    }
    else if (path[start][end] == UP)  // path[start][end]가 UP이면 상단 방향에서 온것이고, start를 하나 늘린 범위에 대해 다시 재귀적 호출해 회문을 찾아 lps_result에 저장할 수 있게한다
    {
        write_lps(str, path, start + 1, end, l_idx, r_idx, lps_result);
    }
    else if (path[start][end] == LEFT)  // path[start][end]가 LEFT이면 왼쪽 방향에서 온것이고, end를 하나 줄인 범위에 대해 다시 재귀적 호출해 회문을 찾아 lps_result에 저장할 수 있게한다
    {
        write_lps(str, path, start, end - 1, l_idx, r_idx, lps_result);
    }

}


void record_lps(char* str, int len, FILE* output_file) // 최장 lps길이를 계산하고 lps 문자열을 출력하는 함수
{
    
    int** lpscost_table = (int**)malloc(len * sizeof(int*));  // lpscost_table:  현재 범위에 대한 LPS의 길이를 저장하는 배열

    Direction** path = (Direction**)malloc(len * sizeof(Direction*));//path : 사용한 경로를 저장하는 배열

  
    for (int i = 0; i < len; i++)
    {
        lpscost_table[i] = (int*)calloc(len, sizeof(int));  
        path[i] = (Direction*)calloc(len, sizeof(Direction));  
    }

    
    for (int i = 0; i < len; i++)// base case 처리
    {
        lpscost_table[i][i] = 1;  // 길이가 1인 부분 문자열은 모두 회문이기 때문에 lpscost_table[i][i]는 1로 설정해 준다  
        path[i][i] = BOTH;  // path[i][i]는 BOTH로 설정 (자기 자신은 회문이므로)
    }

   
    for (int gap = 1; gap < len; gap++) // 동적 프로그래밍을 위해 테이블을 대각선 방향으로 채워나가기 위해 gap 변수로 basecase로 부터 순차적으로 테이블 작성
    {
        for (int start = 0; start < len - gap; start++)  
        {
            int end = start + gap; 

            if (str[start] == str[end])  // start와 end 부분의 문자가 같으면 그 문자들이 LPS에 포함된다
            {
                lpscost_table[start][end] = lpscost_table[start + 1][end - 1] + 2;  // 양쪽 범위를 1개씩 줄인것의 lps 길이에 대해 2를 더해주면 된다
                path[start][end] = BOTH;  // BOTH 방향에서 왔음을 기록한다.
            }
            else if (lpscost_table[start + 1][end] > lpscost_table[start][end - 1])  //start와 end 부분의 문자가 같지 않고, LPS 길이가 위에서 온게 더 길 경우
            {
                lpscost_table[start][end] = lpscost_table[start + 1][end];//위에 온 범위의lps_cost 할당
                path[start][end] = UP;  // UP 방향에서 왔음을 기록
            }
            else  // start와 end 부분의 문자가 같지 않고, LPS 길이가 왼쪽 에서 온게 더 길 경우
            {
                lpscost_table[start][end] = lpscost_table[start][end - 1];// 왼쪽에서 온 범위의 lps_cost 할당
                path[start][end] = LEFT;  // LEFT 방향에서 왔음을 기록
            }
        }
    }

   

    int lps_length = lpscost_table[0][len - 1];  // 우리가 구하는 촤종 LPS 길이는 lpscost_table[0][len-1]이다

    fprintf(output_file, "%d\n", lps_length);  // 출력 파일에 LPS 길이 기록

   
    char* lps_result = (char*)malloc((lps_length + 1) * sizeof(char));  // 후에 lps 문자열을 출력하기 위한 배열선언

    lps_result[lps_length] = '\0';  // 널 문자 삽입하여 문자열 끝 표시

   
    int left_idx = 0, right_idx = lps_length - 1;


    write_lps(str, path, 0, len - 1, &left_idx, &right_idx, lps_result); // 재귀적으로 기존에 기록해 놓은 방향을 이용해 실제 lps 문자열을 저장하는 함수 호출

    fprintf(output_file, "%s\n", lps_result);
    

    // 사용한 동적할당 메모리 해제
  
    free(lps_result);

    for (int i = 0; i < len; i++)
    {
        free(lpscost_table[i]);  
        free(path[i]); 
    }
    free(lpscost_table);
    free(path);  
}




int main()
{

    FILE* command_file = fopen("LPS_command.txt", "r");
    if (!command_file)
    {
        fprintf(stderr, "Error: Could not open LPS_command.txt! \n"); 
        exit(1);
    }

    int num_cases;
    fscanf(command_file, "%d", &num_cases);  // 명령 파일에서 처리할 테스트 케이스 수 읽기

   
    while (num_cases--)  // 각 테스트 케이스 수만큼 반복해서 수행
    {
        char input_filename[100];
        char output_filename[100];
        fscanf(command_file, "%s %s", input_filename, output_filename);

        // 입력 파일 열기
        FILE* input_file = fopen(input_filename, "r");
        if (!input_file)
        {
            fprintf(stderr, "Error: Could not open input file! \n", input_filename);  
            fclose(command_file);
            exit(1);
        }

        // 출력 파일 열기
        FILE* output_file = fopen(output_filename, "w");
        if (!output_file)
        {
            fprintf(stderr, "Error: Could not open output file!\n", output_filename);  
            fclose(command_file);
            fclose(input_file); 
            exit(1);
            
        }

        int num_strings;

        fscanf(input_file, "%d", &num_strings);  // 입력 파일에서 처리할 문자열의 개수 

        fprintf(output_file, "%d\n", num_strings); 

        
        for (int i = 0; i < num_strings; i++)
        {
            int str_len;
            fscanf(input_file, "%d", &str_len);  

            char* str = (char*)malloc((str_len + 1) * sizeof(char));  

            fscanf(input_file, "%s", str);  

            
            record_lps(str, str_len, output_file);

            free(str);  
        }

        fclose(input_file);  
        fclose(output_file);  
    }

    fclose(command_file);  

    printf("Work is completed! Check the output file.\n");  

    return 0;
}
