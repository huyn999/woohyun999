CC = gcc
CFLAGS = -g -Wall

OBJS = main.o list.o hash.o bitmap.o debug.o  hex_dump.o 
TARGET = testlib

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o 
	rm -f $(TARGET)
