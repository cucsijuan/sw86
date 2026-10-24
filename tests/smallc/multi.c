/* multi.c - a program in two files (with multi2.c) */
#include <stdio.h>

int shared;                     /* also in multi2.c: the same variable */
int twice(int x);
int other_helper(void);
static int hidden = 1;

static int helper(void)
{
    return hidden * 10;
}

int main(void)
{
    shared = 21;
    printf("%d %d %d\n", twice(shared), helper(), other_helper());
    return 0;
}
