all: a.out

a.out: tetris.o
	gcc tetris.o -o a.out -lncurses

tetris.o: tetris.c
	 gcc -c tetris.c

clean:
	rm -f a.out  tetris.o
