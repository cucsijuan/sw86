/* preproc.c - the preprocessor and enumerations */
#include <stdio.h>
#include "preproc.h"

#define TWICE(x) (2 * (x))
#define QUAD(x) TWICE(TWICE(x))
#define GREETING "hello"
#define EMPTY
#define LONG_ONE 1 + \
    2

#if VERSION >= 3 && defined(SQUARE)
#define LEVEL "new"
#elif VERSION == 2
#define LEVEL "old"
#else
#define LEVEL "none"
#endif

#ifdef NOT_DEFINED
#error this is not compiled
#endif

#ifndef NOT_DEFINED
int flag = 1;
#endif

#if 0
this is not C at all
#endif

int main(void)
{
    enum color c;
    int x;
    x = 3;
    c = BLUE;
    printf("%d %d %d\n", SQUARE(x + 1), MAX(4, 9), QUAD(5));
    printf("%s %s %d %d\n", GREETING, LEVEL, LONG_ONE * 2, flag EMPTY);
    printf("%d %d %d\n", RED, GREEN, c);
#undef MAX
#define MAX 100
    printf("%d\n", MAX);
    printf("%d\n", 'A' + /* a comment */ 1);  // and this one
    return 0;
}
