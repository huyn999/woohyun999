#include "tetris.h"

static struct sigaction act, oact;
nodepointer head = NULL;
int B, count;
int score_number = 0;


int main() {
	int exit = 0;

	initscr();

	noecho();

	keypad(stdscr, TRUE);

	srand((unsigned int)time(NULL));

	while (!exit)
	{
		clear();
		switch (menu())
		{
		case MENU_PLAY: play(); break;
		case MENU_RANK: rank(); break;
		case MENU_REC: recommendedPlay(); break;
		case MENU_EXIT: exit = 1; break;
		default: break;
		}
	}

	endwin();
	system("clear");
	return 0;
}

void InitTetris()
{
	int i, j;

	for (j = 0; j < HEIGHT; j++)
		for (i = 0; i < WIDTH; i++)
			field[j][i] = 0;


	for (int p = 0; p < VISIBLE_BLOCKS; p++)
	{
		nextBlock[p] = rand() % 7;
	}

	blockRotate = 0;
	blockY = -1;
	blockX = WIDTH / 2 - 2;
	score = 0;
	gameOver = 0;
	timed_out = 0;

	DrawOutline();
	DrawField();


	recommendY = 0;
	recommendX = 0;
	recommendR = 0;




	rcNode* root = (rcNode*)malloc(sizeof(rcNode));
	root->level = 0;
	root->childcount = 0;
	root->accumualtedScore = score;


	for (int p = 0; p < HEIGHT; p++)
	{
		for (int q = 0; q < WIDTH; q++)
		{
			root->recField[p][q] = field[p][q];
		}
	}


	recommend(root);

	DrawBlockWithFeatures(blockY, blockX, nextBlock[0], blockRotate);
	DrawNextBlock(nextBlock);
	PrintScore(score);


}

void DrawOutline() {
	int i, j;

	DrawBox(0, 0, HEIGHT, WIDTH);


	move(2, WIDTH + 10);
	printw("NEXT BLOCK1");
	DrawBox(3, WIDTH + 10, 4, 8);

	move(10, WIDTH + 10);
	printw("NEXT BLOCK2");
	DrawBox(11, WIDTH + 10, 4, 8);


	move(18, WIDTH + 10);
	printw("SCORE");
	DrawBox(19, WIDTH + 10, 1, 8);
}

int GetCommand() {
	int command;
	command = wgetch(stdscr);
	switch (command) {
	case KEY_UP:
		break;
	case KEY_DOWN:
		break;
	case KEY_LEFT:
		break;
	case KEY_RIGHT:
		break;
	case ' ':
		break;
	case 'q':
	case 'Q':
		command = QUIT;
		break;
	default:
		command = NOTHING;
		break;
	}
	return command;
}

int ProcessCommand(int command) {
	int ret = 1;
	int drawFlag = 0;
	switch (command) {
	case QUIT:
		ret = QUIT;
		break;
	case KEY_UP:
		if ((drawFlag = CheckToMove(field, nextBlock[0], (blockRotate + 1) % 4, blockY, blockX)))
			blockRotate = (blockRotate + 1) % 4;
		break;
	case KEY_DOWN:
		if ((drawFlag = CheckToMove(field, nextBlock[0], blockRotate, blockY + 1, blockX)))
			blockY++;
		break;
	case KEY_RIGHT:
		if ((drawFlag = CheckToMove(field, nextBlock[0], blockRotate, blockY, blockX + 1)))
			blockX++;
		break;
	case KEY_LEFT:
		if ((drawFlag = CheckToMove(field, nextBlock[0], blockRotate, blockY, blockX - 1)))
			blockX--;
		break;
	default:
		break;
	}
	if (drawFlag) DrawChange(field, command, nextBlock[0], blockRotate, blockY, blockX);
	return ret;
}

void DrawField() {
	int i, j;
	for (j = 0; j < HEIGHT; j++) {
		move(j + 1, 1);
		for (i = 0; i < WIDTH; i++) {
			if (field[j][i] == 1) {
				attron(A_REVERSE);
				printw(" ");
				attroff(A_REVERSE);
			}
			else printw(".");
		}
	}
}


void PrintScore(int score) {
	move(20, WIDTH + 11);
	printw("%8d", score);
}

void DrawNextBlock(int* nextBlock) {
	int i, j;
	for (i = 0; i < 4; i++) {
		move(4 + i, WIDTH + 13);
		for (j = 0; j < 4; j++) {
			if (block[nextBlock[1]][0][i][j] == 1) {
				attron(A_REVERSE);
				printw(" ");
				attroff(A_REVERSE);
			}
			else printw(" ");
		}
	}
	for (i = 0; i < 4; i++)
	{
		move(12 + i, WIDTH + 13);
		for (j = 0; j < 4; j++)
		{
			if (block[nextBlock[2]][0][i][j] == 1)
			{
				attron(A_REVERSE);
				printw(" ");
				attroff(A_REVERSE);
			}
			else printw(" ");
		}
	}

}

void DrawBlock(int y, int x, int blockID, int blockRotate, char tile) {
	int i, j;
	for (i = 0; i < 4; i++)
		for (j = 0; j < 4; j++) {
			if (block[blockID][blockRotate][i][j] == 1 && i + y >= 0) {
				move(i + y + 1, j + x + 1);
				attron(A_REVERSE);
				printw("%c", tile);
				attroff(A_REVERSE);
			}
		}

	move(HEIGHT, WIDTH + 10);
}

void DrawBox(int y, int x, int height, int width)
{
	int i, j;
	move(y, x);
	addch(ACS_ULCORNER);
	for (i = 0; i < width; i++)
		addch(ACS_HLINE);
	addch(ACS_URCORNER);
	for (j = 0; j < height; j++) {
		move(y + j + 1, x);
		addch(ACS_VLINE);
		move(y + j + 1, x + width + 1);
		addch(ACS_VLINE);
	}
	move(y + j + 1, x);
	addch(ACS_LLCORNER);
	for (i = 0; i < width; i++)
		addch(ACS_HLINE);
	addch(ACS_LRCORNER);
}

void play() {
	int command;
	clear();
	act.sa_handler = BlockDown;
	sigaction(SIGALRM, &act, &oact);
	InitTetris();
	do {
		if (timed_out == 0)
		{
			alarm(1);
			timed_out = 1;
		}

		command = GetCommand();
		if (ProcessCommand(command) == QUIT)
		{
			alarm(0);
			DrawBox(HEIGHT / 2 - 1, WIDTH / 2 - 5, 1, 10);
			move(HEIGHT / 2, WIDTH / 2 - 4);
			printw("Good-bye!!");
			refresh();
			getch();

			return;
		}
	} while (!gameOver);

	alarm(0);
	getch();
	DrawBox(HEIGHT / 2 - 1, WIDTH / 2 - 5, 1, 10);
	move(HEIGHT / 2, WIDTH / 2 - 4);
	printw("GameOver!!");
	refresh();
	getch();
	newRank(score);
}

char menu() {
	printw("1. play\n");
	printw("2. rank\n");
	printw("3. recommended play\n");
	printw("4. exit\n");
	return wgetch(stdscr);
}

/////////////////////////첫주차 실습에서 구현해야 할 함수/////////////////////////

int CheckToMove(char f[HEIGHT][WIDTH], int currentBlock, int blockRotate, int blockY, int blockX)
{
	for (int p = 0; p < 4; p++)
	{
		for (int q = 0; q < 4; q++)
		{

			if (block[currentBlock][blockRotate][p][q])// 새롭게 이동할 블록의 모양을 확인하여 필드 내 어떤 특정 위치에 블록이 채워지는지를 판단
			{
				int nY = blockY + p;
				int nX = blockX + q;

				if (nX < 0 || nX >= WIDTH || nY >= HEIGHT || nY < 0 || f[nY][nX]) //블록이 경계를 벗어나거나 다른 블록과 충돌하는지를 확인
				{
					return 0; // 움직일 수 없는 경우 0 반환 
				}
			}
		}
	}
	return 1; // 움직일 수 있는 경우 1반환
}

void DrawChange(char f[HEIGHT][WIDTH], int command, int currentBlock, int blockRotate, int blockY, int blockX) {

	int preBlockY = blockY; //이전 블록의 blockY좌표 선언 및 초기화
	int preBlockX = blockX;  //이전 블록의 blockX좌표 선언 및 초기화
	int preBlockRotate = blockRotate;// 이전 블록의 rotate 정보 선언 및 초기화


	switch (command)
	{ // command에 따라 이전 블록의 정보를 저장
	case KEY_UP:

		preBlockRotate = (blockRotate + 3) % 4;
		break;

	case KEY_RIGHT:

		preBlockX = blockX - 1;
		break;

	case KEY_LEFT:

		preBlockX = blockX + 1;
		break;

	case KEY_DOWN:

		preBlockY = blockY - 1;
		break;
	}

	int p = 0;
	while (p < 4)
	{
		int q = 0;

		while (q < 4)
		{ // 이전 블록의 위치에 있는 셀을 '.'으로 printw해서 삭제

			if (block[currentBlock][preBlockRotate][p][q])
			{
				move(preBlockY + p + 1, preBlockX + q + 1);
				printw("%c", '.');
			}
			q++;
		}
		p++;
	}

	for (; CheckToMove(field, currentBlock, preBlockRotate, preBlockY + 1, preBlockX); preBlockY++)
	{
		// 이전의 그림자를 지우기 위해 preblockY좌표를 이동할 수 있을 때까지 아래로 이동

	}

	int j = 0;
	while (j < 4)
	{
		int k = 0;
		while (k < 4)
		{
			if (block[currentBlock][preBlockRotate][j][k])
			{
				move(preBlockY + j + 1, preBlockX + k + 1);
				printw(".");
			}
			k++;
		}
		j++;
	}
	DrawBlockWithFeatures(blockY, blockX, currentBlock, blockRotate); // 새로운 블록과 그에 따른 그림자 그려주기
}



void BlockDown(int sig)
{


	if (CheckToMove(field, nextBlock[0], blockRotate, blockY + 1, blockX))
	{
		blockY++;
		DrawChange(field, KEY_DOWN, nextBlock[0], blockRotate, blockY, blockX);

	}
	else
	{
		if (blockY == -1)
		{
			gameOver = 1;
		}

		score += AddBlockToField(field, nextBlock[0], blockRotate, blockY, blockX); // 블록이 필드에 닿거나 블록에 닿은 경우

		score += DeleteLine(field); // 한 행이 지워질 수 있는지 체크

		DrawField();   // 필드 화면 갱신 , 이게 없으면 이전에 그려진 recommend 블럭의 잔상이 다음 블록다운에도 남아 있을 수 있다.

		for (int i = 0; i < VISIBLE_BLOCKS - 1; i++)
		{
			nextBlock[i] = nextBlock[i + 1];
		}
		nextBlock[VISIBLE_BLOCKS - 1] = rand() % 7;

		blockY = -1; // 다음에 내려올 블록 Y위치 초기화
		blockX = WIDTH / 2 - 2; // 다음에 내려올 블록 X위치 초기화
		blockRotate = 0; //블록 회전수 초기화

		DrawNextBlock(nextBlock);

		PrintScore(score);// 반환 받은 점수 출력



		rcNode* root = (rcNode*)malloc(sizeof(rcNode)); // 다음에 그려질 추천 블록을 위해 초기화
		root->level = 0;
		root->childcount = 0;
		root->accumualtedScore = score;
		for (int p = 0; p < HEIGHT; p++)
		{
			for (int q = 0; q < WIDTH; q++)
			{
				root->recField[p][q] = field[p][q];
			}
		}

		recommendX = 0;
		recommendY = 0;
		recommendR = 0;


		recommend(root);

		DrawBlockWithFeatures(blockY, blockX, nextBlock[0], blockRotate);
	}

	timed_out = 0;

}

int AddBlockToField(char f[HEIGHT][WIDTH], int currentBlock, int blockRotate, int blockY, int blockX)
{  //Block이 추가된 영역의 필드값을 바꾼다.

	int touched = 0;
	int p = 0;
	while (p < 4)
	{
		int q = 0;
		while (q < 4)
		{
			if (block[currentBlock][blockRotate][p][q]) //블록이 어떻게 채워져 있는지를 확인하고 그 부분이 채워져있다면
			{
				f[blockY + p][blockX + q] = 1;// 필드 정보 갱신
				if ((blockY + p + 1 == HEIGHT) || f[blockY + p + 1][blockX + q] == 1) // 필드와 맞닿는 부분이 생긴다면
				{

					touched++; // 맞닿은 면적 증가 체크
				}


			}
			q++;
		}
		p++;
	}
	return touched * 10;
}

int DeleteLine(char f[HEIGHT][WIDTH])
{
	int lcount = 0;

	int p = 0;
	while (p < HEIGHT)
	{
		int full = 1;
		int q = 0;
		while (q < WIDTH)
		{
			if (!f[p][q]) // 한 행에 안 채워진 필드부분이 있는지 검사 
			{
				full = 0;
				break;
			}
			q++;
		}
		if (full)
		{
			lcount++;

			int s = p;
			while (s > 0)
			{
				for (int i = 0; i < WIDTH; i++)  // 현재 행 위에 있는 블록들을 아래로 내려준다.
				{
					f[s][i] = f[s - 1][i];
				}
				s--;
			}
		}
		p++;
	}

	int getscore = lcount * lcount * 100;
	return getscore;
}

void DrawBlockWithFeatures(int y, int x, int blockID, int blockRotate)
{
	DrawRecommend(recommendY, recommendX, blockID, recommendR);// 추천 블록 그리기
	DrawShadow(y, x, blockID, blockRotate); // DrawShadow 함수 호출하여 그림자 그리기
	DrawBlock(y, x, blockID, blockRotate, ' '); // DrawBlock 함수 호출



}

///////////////////////////////////////////////////////////////////////////

void DrawShadow(int y, int x, int blockID, int blockRotate)
{
	int sdY = y;
	while (CheckToMove(field, blockID, blockRotate, sdY + 1, x))
	{
		sdY++;
	}
	DrawBlock(sdY, x, blockID, blockRotate, '/');
}

void createRankList()
{
	FILE* fp;
	char str[NAMELEN + 1];
	int i, j;
	int sc;


	fp = fopen("rank.txt", "r");

	fscanf(fp, "%d", &score_number);
	if (score_number == 0)
	{

		return; // rank.txt 파일이 비어있다면 return
	}

	for (i = 0; i < score_number; i++)
	{
		nodepointer temp;
		nodepointer curr;
		temp = (nodepointer)malloc(sizeof(struct raNode));
		fscanf(fp, "%s %d", str, &sc);
		strcpy(temp->name, str);
		temp->score = sc;
		temp->link = NULL;

		if (head == NULL)
		{
			head = temp;
		}
		else
		{
			curr = head;
			while (curr->link != NULL)
			{
				curr = curr->link;
			}

			curr->link = temp;

		}
	}


	fclose(fp);
}




void rank() {


	int X = 1, Y = score_number, ch, i, j;


	clear();

	printw("1. list ranks from X to Y\n");
	printw("2. list ranks by specific name\n");
	printw("3. delete a specific rank\n");

	ch = wgetch(stdscr);

	switch (ch)
	{
	case '1':  // 범위 입력받아 찾기
	{  nodepointer curr;

	printw("X: ");
	echo();
	scanw("%d", &X);
	noecho();

	printw("Y: ");
	echo();
	scanw("%d", &Y);
	noecho();

	printw("        name        |     score   \n ");
	printw("------------------------------\n");
	if (X <= Y && X >= 1 && Y <= score_number)
	{
		int gap = Y - X;
		curr = head;
		i = 1;
		while (i < X)
		{
			curr = curr->link;
			i++;
		}
		j = 0;
		while (j <= gap)
		{
			printw(" %-19s", curr->name);
			printw("| %-12d\n", curr->score);
			curr = curr->link;
			j++;
		}
	}

	else
	{
		printw("\n");
		printw("search failure: no rank in the list");
	}
	break;
	}
	case '2': // 이름 입력받아 찾기
	{
		nodepointer curr;
		int count = 0;
		char str[NAMELEN + 1];
		printw("input the name: ");

		echo();
		scanw("%s", str);
		noecho();

		printw("       name       |   score   ");
		printw("\n");
		printw("------------------------------\n");

		curr = head;
		while (curr != NULL)
		{
			if (strcmp(curr->name, str) == 0)
			{
				printw(" %-19s", curr->name);
				printw("| %-12d\n", curr->score);
				count++;
			}
			curr = curr->link;
		}
		if (!count)
		{
			printw("\n");
			printw("search failure: no name in the list");
		}

		break;
	}
	case '3':  // 랭킹 입력 받아 찾기
	{
		int ranking;
		printw("Input the rank: ");
		echo();
		scanw("%d", &ranking);
		noecho();
		if (ranking > score_number || ranking < 1)
		{
			printw("search failure: the rank not in the list");
		}
		else
		{
			nodepointer curr = head;
			nodepointer prev = NULL;

			int i = 1;
			while (i < ranking)
			{
				prev = curr;
				curr = curr->link;
				i++;
			}

			if (prev)
			{
				prev->link = curr->link;
			}
			else
			{
				head = curr->link;
			}
			free(curr);
			score_number--;

			printw("result: the rank deleted");
			writeRankFile();
		}
		break;
	}

	default:

		break;

	}

	getch();

}



void writeRankFile()
{
	int i;
	FILE* fp = fopen("rank.txt", "w");

	if (fp == NULL)
	{
		printf("Error! can not open the file.\n");
		return;
	}


	fprintf(fp, "%d\n", score_number);
	nodepointer curr = head;
	while (curr != NULL)
	{
		fprintf(fp, "%s %d\n", curr->name, curr->score);
		curr = curr->link;
	}

	fclose(fp);
}


void newRank(int new_score)
{
	char str[NAMELEN + 1];

	clear();

	printw("your name: ");

	echo();
	scanw("%s", str);
	noecho();

	nodepointer temp;
	temp = (nodepointer)malloc(sizeof(struct raNode));
	strcpy(temp->name, str);
	temp->score = new_score;



	if (score_number == 0)
	{
		head = temp;
		temp->link = NULL; // 안하면 segmetation fault 발생 초기화 필요
	}

	else
	{

		if (new_score > head->score)
		{
			temp->link = head;
			head = temp;
		}
		else
		{
			nodepointer curr = head;
			nodepointer prev = NULL;
			while (curr != NULL && new_score <= curr->score)
			{
				prev = curr;
				curr = curr->link;
			}

			prev->link = temp;
			temp->link = curr;
		}

	}
	score_number++;
	writeRankFile();
}


void DrawRecommend(int y, int x, int blockID, int blockRotate)
{
	DrawBlock(y, x, blockID, blockRotate, 'R');

}


int recommend(rcNode* root)
{
	int temp;
	int  ry;
	int rotate_range = 0;
	int finalscore = 0;

	if (root->curBlockID <= 3 && root->curBlockID > 0)
	{
		rotate_range = 4;
	}
	else if (root->curBlockID == 0 || root->curBlockID == 5 || root->curBlockID == 6)
	{
		rotate_range = 2;
	}
	else if (root->curBlockID == 4)
	{
		rotate_range = 1;
	}

	for (int r = 0; r < rotate_range; r++)
	{  // 회전 가능 수 만큼 조사 

		for (int rx = -2; rx <= WIDTH; rx++) // -2부터 조사해야 전체 블록의 모형이 쌓일 가능성을 고려할 수 있다. 일반적으로 0이라고 생각하기 쉽지만 이는 오류이다.
		{ // 가로 필드에 대해 조사
			if (!CheckToMove(root->recField, nextBlock[root->level], r, 0, rx))
			{
				continue;
			}

			ry = -1;

			while (CheckToMove(root->recField, nextBlock[root->level], r, ry + 1, rx))
			{ // 블록이 최대한 내려갈 수 있는 위치까지 이동시킨다.
				ry++;

			}


			root->child[root->childcount] = (rcNode*)malloc(sizeof(rcNode));  // child 배열의 한 원소를 동적 할당 후 이후 필요한 정보들을 각각 할당해준다.

			root->child[root->childcount]->accumualtedScore = root->accumualtedScore;
			root->child[root->childcount]->curBlockID = nextBlock[root->level];
			root->child[root->childcount]->level = root->level + 1;
			root->child[root->childcount]->parent = root;
			root->child[root->childcount]->childcount = 0;

			for (int p = 0; p < HEIGHT; p++)
			{
				for (int q = 0; q < WIDTH; q++)
				{
					root->child[root->childcount]->recField[p][q] = root->recField[p][q];
				}
			}

			temp = AddBlockToField(root->child[root->childcount]->recField, root->child[root->childcount]->curBlockID, r, ry, rx);
			temp += DeleteLine(root->child[root->childcount]->recField);

			root->child[root->childcount]->accumualtedScore += temp;

			if (root->child[root->childcount]->level < VISIBLE_BLOCKS)
			{
				temp += recommend(root->child[root->childcount]);
			}

			if (finalscore < temp) // 기존의 finalscore 보다 temp가 크다면 실행, 우리의 우선 1순위는 큰 점수를 만드는 블록의 위치를 찾는것
			{
				finalscore = temp;

				if (!(root->level))
				{
					recommendR = r;
					recommendX = rx;
					recommendY = ry;
				}
			}
			else if (finalscore == temp) // 기존의 finalscore와  temp가 같다면  실행, 2순위로서 블록이 같은 점수를 만들어내는 위치라도 더 내려올 수 있으면 이게 더 gameover 방지에 유리하다.
			{
				if (!(root->level) && (recommendY < ry))// level이 0이고 현재 좌표가  기존의 recommendY의 좌표보다 필드 아래로 더 내려올 수 있는 경우 갱신
				{
					recommendR = r;
					recommendX = rx;
					recommendY = ry;
				}
			}
			(root->childcount)++;
		}
	}
	return finalscore;
}



void modified_recommend(rcNode* root)
{
	int temp;
	int ry;
	int rotate_range = 0;
	int finalscore = 0;
	rcNode* Maxchild = NULL;  // 최대 점수 갖는 노드만 남기기 위해 선언

	if (root->curBlockID <= 3 && root->curBlockID > 0)
	{
		rotate_range = 4;
	}
	else if (root->curBlockID == 0 || root->curBlockID == 5 || root->curBlockID == 6)
	{
		rotate_range = 2;
	}
	else if (root->curBlockID == 4)
	{
		rotate_range = 1;
	}

	for (int r = 0; r < rotate_range; r++)
	{
		for (int rx = -2; rx < WIDTH; rx++)
		{
			if (!CheckToMove(root->recField, nextBlock[root->level], r, 0, rx))
			{
				continue;
			}

			ry = -1;

			while (CheckToMove(root->recField, nextBlock[root->level], r, ry + 1, rx))
			{
				ry++;
			}

			root->child[root->childcount] = (rcNode*)malloc(sizeof(rcNode));
			rcNode* Newchild = root->child[root->childcount];

			Newchild->accumualtedScore = root->accumualtedScore;
			Newchild->curBlockID = nextBlock[root->level];
			Newchild->level = root->level + 1;
			Newchild->parent = root;
			Newchild->childcount = 0;

			for (int p = 0; p < HEIGHT; p++)
			{
				for (int q = 0; q < WIDTH; q++)
				{
					Newchild->recField[p][q] = root->recField[p][q];
				}
			}

			temp = AddBlockToField(Newchild->recField, Newchild->curBlockID, r, ry, rx);
			temp += DeleteLine(Newchild->recField);
			Newchild->accumualtedScore += temp;

			if (finalscore < temp)
			{
				finalscore = temp;

				Maxchild = Newchild; // 기존의 Maxchild 대신 새로운 Newchild로 할당

				if (root->level == 0)
				{
					recommendR = r;
					recommendX = rx;
					recommendY = ry;
				}
			}
			else if ((finalscore == temp) && (recommendY < ry))
			{
				Maxchild = Newchild;

				if (root->level == 0) {
					recommendR = r;
					recommendX = rx;
					recommendY = ry;
				}
			}
			(root->childcount)++;
		}
	}

	if (Maxchild && Maxchild->level < VISIBLE_BLOCKS) // 각 레별별로 최대 블럭을 선택해 없어도 되지만 점수를 누적하며 최대 점수를 추천하는 트리 구조를 만들어 준다. 한 block 다운이 끝나면 초기화 후 새로운 트리구조 셍성
	{
		modified_recommend(Maxchild);
	}
}

void modifiedblockDown(int sig) 
{
	blockX = recommendX;
	blockRotate = recommendR;

	if (CheckToMove(field, nextBlock[0], blockRotate, blockY + 1, blockX))
	{
		blockY++;
		DrawChange(field, KEY_DOWN, nextBlock[0], blockRotate, blockY, blockX);

	}
	else
	{
		if (blockY == -1)
		{
			gameOver = 1;
		}

		score += AddBlockToField(field, nextBlock[0], recommendR, recommendY, recommendX); 

		score += DeleteLine(field); 

		DrawField();   // 필드 화면 갱신 , 이게 없으면 이전에 그려진 recommend 블럭의 잔상이 다음 블록다운에도 남아 있을 수 있다.

		for (int i = 0; i < VISIBLE_BLOCKS - 1; i++)
		{
			nextBlock[i] = nextBlock[i + 1];
		}
		nextBlock[VISIBLE_BLOCKS - 1] = rand() % 7;

		DrawNextBlock(nextBlock);

		blockY = -1; 
		blockX = WIDTH / 2 - 2; 
		blockRotate = 0;



		PrintScore(score);



		rcNode* root = (rcNode*)malloc(sizeof(rcNode)); // 다음에 그려질 추천 블록을 위해 초기화
		root->level = 0;
		root->childcount = 0;
		root->accumualtedScore = score;
		for (int p = 0; p < HEIGHT; p++)
		{
			for (int q = 0; q < WIDTH; q++)
			{
				root->recField[p][q] = field[p][q];
			}
		}

		recommendX = 0;
		recommendY = 0;
		recommendR = 0;


		modified_recommend(root);

		DrawBlock(recommendY, recommendX, nextBlock[0], recommendR, 'R');
		
	}
	timed_out = 0;
}






void recommendedPlay()  
{
	

	int command;
	clear();

	act.sa_handler = modifiedblockDown;
	sigaction(SIGALRM, &act, &oact);
	
	int i, j;

	for (j = 0; j < HEIGHT; j++)
		for (i = 0; i < WIDTH; i++)
			field[j][i] = 0;


	for (int p = 0; p < VISIBLE_BLOCKS; p++)
	{
		nextBlock[p] = rand() % 7;
	}

	blockRotate = 0;
	blockY = -1;
	blockX = WIDTH / 2 - 2;
	score = 0;
	gameOver = 0;
	timed_out = 0;

	DrawOutline();
	DrawField();


	recommendY = 0;
	recommendX = 0;
	recommendR = 0;




	rcNode* root = (rcNode*)malloc(sizeof(rcNode));
	root->level = 0;
	root->childcount = 0;
	root->accumualtedScore = score;


	for (int p = 0; p < HEIGHT; p++)
	{
		for (int q = 0; q < WIDTH; q++)
		{
			root->recField[p][q] = field[p][q];
		}
	}


	modified_recommend(root);


	DrawBlock(recommendY, recommendX, nextBlock[0], recommendR, 'R');
	DrawNextBlock(nextBlock);
	PrintScore(score);


	do {
		if (timed_out == 0)
		{
			alarm(1);
			timed_out = 1;
		}

		command = GetCommand();
		if (ProcessCommand(command) == QUIT) // 다른 커멘드 키 동작시 오류발생! 그러므로 pdf지시문 대로 오로지 q나Q 커맨드 외에는 다른 커멘드를 사용하면 안된다.
		{
			alarm(0);
			DrawBox(HEIGHT / 2 - 1, WIDTH / 2 - 5, 1, 10);
			move(HEIGHT / 2, WIDTH / 2 - 4);
			printw("Good-bye!!");
			refresh();
			getch();

			return;
		}
	} while (!gameOver);

	alarm(0);
	getch();

	DrawBox(HEIGHT / 2 - 1, WIDTH / 2 - 5, 1, 10);
	move(HEIGHT / 2, WIDTH / 2 - 4);
	printw("GameOver!!");
	refresh();
	getch();
	


}
