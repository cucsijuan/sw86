/* misc.c - tables of structures and strings, chars with and without sign */
#include <stdio.h>
#include <string.h>

struct item { char tag; int value; char name[3]; };
struct item items[] = { { 'a', 1, "x" }, { 'b', -2, "yz" }, { 'c', 300, "" } };
char *words[] = { "alpha", "beta", 0 };
struct pair { char *key; int n; } table[] = { { "one", 1 }, { "two", 2 } };
char signs[] = { -1, 127, -128 };
unsigned char bytes[] = { 255, 128, 0 };

char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? c + 32 : c;
}

int count(char *s, int c)
{
    int n;
    n = 0;
    while (*s)
        if (*s++ == c)
            n++;
    return n;
}

int depth(int n)
{
    int local[4];
    local[n & 3] = n;
    return n == 0 ? 0 : 1 + depth(n - 1) + local[n & 3] - n;
}

int main(void)
{
    int i, j, total;
    unsigned char uc;
    char *p, *q;
    struct item *it;
    total = 0;
    for (i = 0; i < 3; i++)
        total += items[i].value * (items[i].tag - 'a' + 1);
    printf("%d %s %d\n", total, items[1].name, strlen(items[2].name));
    it = &items[2];
    printf("%c %d\n", it->tag, it - items);
    for (i = 0; words[i]; i++)
        printf("%s ", words[i]);
    printf("\n");
    printf("%s=%d %s=%d\n", table[0].key, table[0].n, table[1].key, table[1].n);
    printf("%d %d %d %d %d %d\n", signs[0], signs[1], signs[2], bytes[0], bytes[1], bytes[2]);
    uc = 200;
    printf("%d %d %d\n", uc > 100, uc == 200, (char)uc < 0);
    printf("%c%c %d\n", lower('Q'), lower('q'), count("banana", 'a'));
    p = "abc";
    q = p + 2;
    printf("%d %d %d\n", q > p, q - p, *q);
    printf("%d\n", depth(10));
    j = 0;
    for (i = 0; i < 3; i++) {
        switch (i) {
        case 0:
            j = 10;
            break;
        case 1:
            switch (j) {
            case 10: j = 20; break;
            default: j = 0;
            }
            break;
        default:
            j = j + 1;
        }
    }
    printf("%d\n", j);
    i = 0;
    do {
        i++;
        if (i < 5)
            continue;
        break;
    } while (1);
    printf("%d\n", i);
    return 0;
}
