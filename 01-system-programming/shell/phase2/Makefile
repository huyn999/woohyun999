CC = gcc
CFLAGS = -Og
LDLIBS = -lpthread

PROGS = myshell

all: $(PROGS)

myshell: myshell.c csapp.c csapp.h myshell.h
	$(CC) $(CFLAGS) -o myshell myshell.c csapp.c $(LDLIBS)

clean:
	rm -rf *~ $(PROGS)