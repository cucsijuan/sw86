/* pointer.c - arrays, pointers and strings */
#include <stdio.h>
#include <string.h>

int grid[3][4];
char *names[] = { "zero", "one", "two", "three" };
int primes[] = { 2, 3, 5, 7, 11, 13 };

void swap(int *a, int *b)
{
    int t;
    t = *a;
    *a = *b;
    *b = t;
}

int sum(int *p, int n)
{
    int s;
    s = 0;
    while (n--)
        s += *p++;
    return s;
}

void reverse(char *s)
{
    char *e, t;
    e = s + strlen(s) - 1;
    while (s < e) {
        t = *s;
        *s++ = *e;
        *e-- = t;
    }
}

int main(void)
{
    int i, j, x, y, *p, **pp;
    char buf[32], *q;
    for (i = 0; i < 3; i++)
        for (j = 0; j < 4; j++)
            grid[i][j] = i * 10 + j;
    printf("%d %d %d\n", grid[2][3], *grid[1], *(*(grid + 2) + 1));
    printf("%d %d\n", sizeof(grid), sizeof(grid[0]));
    x = 1; y = 2;
    swap(&x, &y);
    printf("%d %d\n", x, y);
    printf("%d %d\n", sum(primes, 6), sizeof(primes) / sizeof(primes[0]));
    p = &primes[4];
    printf("%d %d %d\n", p[-1], *(p + 1), p - primes);
    pp = &p;
    **pp = 99;
    printf("%d %s %c\n", primes[4], names[3], names[2][1]);
    strcpy(buf, "Hello");
    strcat(buf, ", world");
    reverse(buf);
    printf("%s %d\n", buf, strlen(buf));
    q = strchr("abcdef", 'd');
    printf("%s %d %d\n", q, strcmp("abc", "abd") < 0, strncmp("abcx", "abcy", 3));
    for (q = names[1]; *q; q++)
        putchar(*q - 32);
    putchar('\n');
    memset(buf, 'x', 5);
    buf[5] = 0;
    printf("%s %d\n", buf, memcmp("ab", "ab", 2));
    return 0;
}
