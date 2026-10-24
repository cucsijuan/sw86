/* bigdata.c - an .EXE with more data than a .COM could hold */
#include <stdio.h>
#include <dos.h>

char big[30000];
int more[12000];

int main(void)
{
    int i, ok;
    unsigned cs;
    for (i = 0; i < 30000; i++)
        big[i] = i;
    for (i = 0; i < 12000; i++)
        more[i] = i * 3;
    ok = 1;
    for (i = 0; i < 30000; i++)
        if (big[i] != (char)i)
            ok = 0;
    for (i = 0; i < 12000; i++)
        if (more[i] != i * 3)
            ok = 0;
    printf("%d %u %d\n", ok, sizeof(big) + sizeof(more), big[29999]);
    printf("%d\n", getds() != _psp + 16);
    return 0;
}
