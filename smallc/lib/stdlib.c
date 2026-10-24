/* stdlib.c - numbers */
#include <stdlib.h>

static unsigned seed = 1;

int abs(int v)
{
    return v < 0 ? -v : v;
}

int atoi(char *s)
{
    int v, neg;
    while (*s == ' ' || *s == '\t')
        s++;
    neg = *s == '-';
    if (*s == '-' || *s == '+')
        s++;
    v = 0;
    while (*s >= '0' && *s <= '9')
        v = v * 10 + *s++ - '0';
    return neg ? -v : v;
}

char *itoa(int v, char *s, int radix)
{
    char buf[18];
    unsigned u;
    int n, k;
    char *p;
    p = s;
    u = v;
    if (radix == 10 && v < 0) {
        *p++ = '-';
        u = -v;
    }
    n = 0;
    do {
        k = u % radix;
        buf[n++] = k < 10 ? '0' + k : 'a' + k - 10;
        u = u / radix;
    } while (u);
    while (n > 0)
        *p++ = buf[--n];
    *p = 0;
    return s;
}

int rand(void)
{
    seed = seed * 25173 + 13849;
    return seed & 0x7FFF;
}

void srand(unsigned s)
{
    seed = s;
}
