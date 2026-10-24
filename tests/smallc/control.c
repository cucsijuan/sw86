/* control.c - statements */
#include <stdio.h>

int fib(int n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

int counter(void)
{
    static int n = 10;
    static int calls;
    calls++;
    return n++ + calls * 100;
}

char *kind(int c)
{
    switch (c) {
    case 'a': case 'e': case 'i': case 'o': case 'u':
        return "vowel";
    case ' ':
        return "space";
    default:
        if (c >= '0' && c <= '9')
            return "digit";
        return "other";
    }
}

int main(void)
{
    int i, j, n, s;
    for (i = 0, s = 0; i < 10; i++) {
        if (i == 3)
            continue;
        if (i == 8)
            break;
        s += i;
    }
    printf("%d\n", s);
    n = 0;
    do {
        n++;
    } while (n < 5);
    i = 0;
    while (1) {
        if (++i > 100)
            break;
    }
    printf("%d %d\n", n, i);
    for (i = 0; i < 3; i++)
        for (j = 0; j < 3; j++) {
            if (j == i)
                continue;
            if (i == 2)
                goto out;
            printf("%d%d ", i, j);
        }
out:
    printf("\n%d %d %d\n", fib(10), fib(15), fib(1));
    i = counter();
    j = counter();
    n = counter();
    printf("%d %d %d\n", i, j, n);
    printf("%s %s %s %s\n", kind('e'), kind('7'), kind(' '), kind('z'));
    s = 0;
    for (i = 0; i < 20; i++)
        switch (i % 4) {
        case 0: s += 1;
        case 1: s += 10; break;
        case 2: break;
        default: s += 100;
        }
    printf("%d\n", s);
    if (s > 0)
        if (s > 1000) printf("big\n");
        else printf("small\n");
    return 0;
}
