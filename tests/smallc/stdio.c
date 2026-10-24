/* stdio.c - printf, files and the heap */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    FILE *f;
    char line[40], *p, *q;
    int i, n, c;
    printf("[%5d][%-5d][%05d][%x][%c][%.2s][%%]\n", 42, 42, 42, 255, 'Z', "abc");
    printf("[%s][%8s][%-4s][%u][%+d]\n", "x", "right", "l", 50000, 7);
    sprintf(line, "%d-%s", -12, "ok");
    printf("%s %d\n", line, strlen(line));
    f = fopen("TEST.TXT", "w");
    for (i = 1; i <= 3; i++)
        fprintf(f, "line %d\n", i);
    fputs("last", f);
    fclose(f);
    f = fopen("TEST.TXT", "r");
    n = 0;
    while (fgets(line, 40, f)) {
        n++;
        p = line;
    }
    fclose(f);
    printf("%d lines, last '%s'\n", n, p);
    f = fopen("TEST.TXT", "rb");
    n = 0;
    while ((c = getc(f)) != EOF)
        n++;
    fclose(f);
    printf("%d bytes\n", n);
    p = malloc(1000);
    q = malloc(2000);
    strcpy(p, "first");
    free(p);
    p = malloc(500);
    printf("%d %d\n", p != 0, q != 0);
    q = realloc(q, 3000);
    strcpy(q, "kept");
    p = strdup(q);
    printf("%s %s %d\n", p, itoa(-1234, line, 10), atoi("  56x"));
    remove("TEST.TXT");
    printf("%d\n", fopen("TEST.TXT", "r") == 0);
    return 0;
}
