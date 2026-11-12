CC = clang-19
CFLAGS = -Wall -g

.PHONY: all clean

all: jc

jc: jc.o token.o asm_gen.o
	$(CC) $(CFLAGS) -o jc jc.o token.o asm_gen.o

jc.o: jc.c asm_gen.h
	$(CC) $(CFLAGS) -c jc.c

token.o: token.c token.h
	$(CC) $(CFLAGS) -c token.c

asm_gen.o: asm_gen.c asm_gen.h token.h
	$(CC) $(CFLAGS) -c asm_gen.c

clean:
	rm -f *.o jc
