/* stdlib.h - memory, numbers, the end of a program */
#ifndef _STDLIB_H
#define _STDLIB_H

#define NULL        0
#define RAND_MAX    32767
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void *malloc(unsigned n);
void *calloc(unsigned n, unsigned size);
void *realloc(void *p, unsigned n);
void free(void *p);
void exit(int code);
void _exit(int code);
int abs(int v);
int atoi(char *s);
char *itoa(int v, char *s, int radix);
int rand(void);
void srand(unsigned seed);
char *getenv(char *name);

#endif
