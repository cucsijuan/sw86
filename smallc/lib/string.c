/* string.c - strings and memory */
#include <string.h>

int strlen(char *s)
{
    char *p;
    p = s;
    while (*p)
        p++;
    return p - s;
}

char *strcpy(char *d, char *s)
{
    char *r;
    r = d;
    while ((*d++ = *s++) != 0)
        ;
    return r;
}

char *strncpy(char *d, char *s, int n)
{
    char *r;
    r = d;
    while (n > 0 && *s) {
        *d++ = *s++;
        n--;
    }
    while (n-- > 0)
        *d++ = 0;
    return r;
}

char *strcat(char *d, char *s)
{
    strcpy(d + strlen(d), s);
    return d;
}

char *strncat(char *d, char *s, int n)
{
    char *p;
    p = d + strlen(d);
    while (n-- > 0 && *s)
        *p++ = *s++;
    *p = 0;
    return d;
}

int strcmp(char *a, char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (*a & 255) - (*b & 255);
}

int strncmp(char *a, char *b, int n)
{
    while (n > 0 && *a && *a == *b) {
        a++;
        b++;
        n--;
    }
    if (n == 0)
        return 0;
    return (*a & 255) - (*b & 255);
}

static int lower(int c)
{
    return c >= 'A' && c <= 'Z' ? c + 32 : c;
}

int stricmp(char *a, char *b)
{
    while (*a && lower(*a) == lower(*b)) {
        a++;
        b++;
    }
    return lower(*a & 255) - lower(*b & 255);
}

char *strchr(char *s, int c)
{
    c = c & 255;
    for (;;) {
        if ((*s & 255) == c)
            return s;
        if (!*s)
            return 0;
        s++;
    }
}

char *strrchr(char *s, int c)
{
    char *r;
    r = 0;
    c = c & 255;
    for (;;) {
        if ((*s & 255) == c)
            r = s;
        if (!*s)
            return r;
        s++;
    }
}

char *strstr(char *s, char *t)
{
    int n;
    n = strlen(t);
    while (*s) {
        if (!strncmp(s, t, n))
            return s;
        s++;
    }
    return n ? 0 : s;
}

char *strupr(char *s)
{
    char *p;
    for (p = s; *p; p++)
        if (*p >= 'a' && *p <= 'z')
            *p = *p - 32;
    return s;
}

char *strlwr(char *s)
{
    char *p;
    for (p = s; *p; p++)
        if (*p >= 'A' && *p <= 'Z')
            *p = *p + 32;
    return s;
}

int memcmp(void *a, void *b, int n)
{
    char *p, *q;
    p = a;
    q = b;
    while (n-- > 0) {
        if (*p != *q)
            return (*p & 255) - (*q & 255);
        p++;
        q++;
    }
    return 0;
}
