/* malloc.c - the heap
 *
 * The heap goes from the end of .bss to below the stack. Each block
 * starts with its size in bytes (header included); the lowest bit is set
 * while it is in use. Free blocks next to each other are joined when
 * looked at.
 */
#include <stdlib.h>
#include <string.h>

extern unsigned _brk, _brkend;
static unsigned *first, *end;

void *malloc(unsigned n)
{
    unsigned *p, *q, size;
    if (!first) {
        first = (unsigned *)((_brk + 1) & ~1);
        end = (unsigned *)(_brkend & ~1);
        *first = (char *)end - (char *)first;
    }
    if (n > 0xFFF0u)
        return 0;
    n = (n + 3) & ~1;
    for (p = first; p < end; p = (unsigned *)((char *)p + (*p & ~1))) {
        if (*p & 1)
            continue;
        size = *p;
        for (;;) {
            q = (unsigned *)((char *)p + size);
            if (q >= end || (*q & 1))
                break;
            size = size + *q;
        }
        *p = size;
        if (size < n)
            continue;
        if (size - n >= 4) {
            q = (unsigned *)((char *)p + n);
            *q = size - n;
            size = n;
        }
        *p = size | 1;
        return p + 1;
    }
    return 0;
}

void free(void *p)
{
    unsigned *b;
    if (p) {
        b = p;
        b[-1] = b[-1] & ~1;
    }
}

void *calloc(unsigned n, unsigned size)
{
    char *p;
    p = malloc(n * size);
    if (p)
        memset(p, 0, n * size);
    return p;
}

void *realloc(void *p, unsigned n)
{
    char *q;
    unsigned old;
    if (!p)
        return malloc(n);
    old = ((unsigned *)p)[-1] - 3;
    q = malloc(n);
    if (q) {
        memcpy(q, p, old < n ? old : n);
        free(p);
    }
    return q;
}

char *strdup(char *s)
{
    char *p;
    p = malloc(strlen(s) + 1);
    if (p)
        strcpy(p, s);
    return p;
}
