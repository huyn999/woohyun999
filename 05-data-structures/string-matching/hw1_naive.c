#define _CRT_SECURE_NO_WARNINGS
#define MAX_STRING_SIZE 10000000
#define MAX_PATTERN_SIZE 3000
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void naive(char*, char*);
char string[MAX_STRING_SIZE];
char pat[MAX_PATTERN_SIZE];
int display[MAX_STRING_SIZE] = { 0, }; // 발견된 위치를 저장할 배열을 global로 선언
int count=0;


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
    naive(pat, string);
    return 0;

}


void naive(char* pt, char* st)
{
    int i ,q,k;
    int lenp = strlen(pt) - 1;
    int lens = strlen(st) - 1;
    FILE* rfi = fopen("result_naive.txt", "w");
    
    for (i = 0; i <= lens; i++)
    {   
        if(i>(lens-lenp))
        {
            break;
        }
        for (k = 0; k <= lenp; k++)
        {
            if ( pt[k] != st[i + k])
            break;
        }
        
        if (k == lenp+1)
        {
          display[count++] = i;
        }

    }

    fprintf(rfi, "%d", count);

    fprintf(rfi, "\n");

    for (q = 0; q < count; q++)
    {
    fprintf(rfi, "%d ", display[q]);
    }
    fprintf(rfi, "\n");
    fclose(rfi);

    printf("Program complete. Result saved to result_naive.txt\n");
}




