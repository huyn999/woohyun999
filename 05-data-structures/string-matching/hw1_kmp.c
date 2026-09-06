
#define _CRT_SECURE_NO_WARNINGS
#define MAX_STRING_SIZE 10000000
#define MAX_PATTERN_SIZE 3000
#include<stdio.h> 
#include<stdlib.h> 
#include<string.h>

int failure[MAX_PATTERN_SIZE];
char string[MAX_STRING_SIZE];
char pat[MAX_PATTERN_SIZE];
int display[MAX_STRING_SIZE] = { 0, };// 발견된 위치를 저장할 배열을 global로 선언
int count=0;


void fail(char* pat) 
{
    int pl = strlen(pat);
    failure[0] = 0; // 초기값 설정
    int i = 0;
    
    for (int j = 1; j < pl; j++) 
	{
        while (i > 0 && pat[j] != pat[i]) 
		{
            i = failure[i - 1];
        }

        if (pat[i] ==pat[j])
		{
            i++;
        }
        failure[j] = i;
    }

}

void kmp(char* string, char* pat) //o(len(s))
{

	int i = 0, p = 0;
	int lens = strlen(string);
	int lenp = strlen(pat);
	FILE* rfi = fopen("result_kmp.txt","w");

    while(i<lens) // o(lens)
	{
    	if (string[i] == pat[p])// 알맞게 매치되는 경우
		{
       		 i++;
        	 p++;
        
        	if (p == lenp) 
			{
            	display[count++] = i - lenp;
           		p = failure[p - 1]; //매치된 이후 다음 p값 조정
            	continue;
        	}
    	} 
		else // 메치가 안되는 경우
		{
        	p = (p == 0) ? 0 : failure[p - 1];
        	if (p == 0) i++;//p가 패턴의 처음 원소라면 스트링의 인덱스만 이동 시켜주기
    	}
    }
    fprintf( rfi,"%d", count);

	fprintf(rfi,"\n");

	for (int k = 0; k < count; k++)
	{
	  fprintf(rfi,"%d ", display[k]);
		
	}
	fprintf(rfi, "\n");
	fclose(rfi);
}
int main()
{

	
	FILE* sfi = fopen("string.txt", "r");
	
	if (sfi == NULL)
	{
		printf("The string file does not exist.");
		return 1;
	}
	fgets(string, sizeof(string), sfi);
	fclose(sfi);

	FILE* pfi = fopen("pattern.txt", "r");

	if (pfi == NULL)
	{
		printf("The pattern file does not exist.");
		return 1;
	}
	fgets(pat, sizeof(pat), pfi);
	fclose(pfi);
	fail(pat);
	kmp(string, pat);

    printf("Program complete. Result saved to result_kmp.txt\n");
	return 0;


}
