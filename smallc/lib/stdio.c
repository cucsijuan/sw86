/* stdio.c - streams: the buffers, characters in and out, lines
 *
 * Text streams turn '\n' into CR LF when writing, and drop CR and stop at
 * Ctrl-Z when reading. stdout and stderr are written at each '\n' and
 * before stdin is read; every stream is written when the program ends.
 */
#include <stdio.h>
#include <io.h>

static char inbuf[128], outbuf[128], errbuf[64];

FILE _iob[FOPEN_MAX] = {
    { 0, _F_READ | _F_TEXT, inbuf, 0, inbuf, 128, -1 },
    { 1, _F_WRITE | _F_TEXT | _F_LINE, outbuf, 128, outbuf, 128, -1 },
    { 2, _F_WRITE | _F_TEXT | _F_LINE, errbuf, 64, errbuf, 64, -1 }
};

int fflush(FILE *f)
{
    int n;
    if (!(f->flags & _F_WRITE))
        return 0;
    n = f->ptr - f->base;
    f->ptr = f->base;
    f->cnt = f->size;
    if (n > 0 && write(f->fd, f->base, n) != n) {
        f->flags = f->flags | _F_ERR;
        return EOF;
    }
    return 0;
}

void _flsall(void)
{
    int i;
    for (i = 0; i < FOPEN_MAX; i++)
        if (_iob[i].flags & _F_WRITE)
            fflush(&_iob[i]);
}

static int fill(FILE *f)
{
    if (f->flags & (_F_EOF | _F_ERR))
        return 0;
    if (f == stdin)
        fflush(stdout);
    f->cnt = read(f->fd, f->base, f->size);
    f->ptr = f->base;
    if (f->cnt <= 0) {
        f->flags = f->flags | (f->cnt < 0 ? _F_ERR : _F_EOF);
        f->cnt = 0;
        return 0;
    }
    return 1;
}

/* getc and putc start in stdioa.asm, and come here for what is not a
 * plain character in the buffer */
int _getc(FILE *f)
{
    int c;
    if (f->unget >= 0) {
        c = f->unget;
        f->unget = -1;
        return c;
    }
    if (!(f->flags & _F_READ))
        return EOF;
    for (;;) {
        if (f->cnt <= 0 && !fill(f))
            return EOF;
        f->cnt--;
        c = *f->ptr++ & 255;
        if (!(f->flags & _F_TEXT))
            return c;
        if (c == 13)
            continue;
        if (c == 26) {
            f->flags = f->flags | _F_EOF;
            f->cnt = 0;
            return EOF;
        }
        return c;
    }
}

int ungetc(int c, FILE *f)
{
    if (c == EOF)
        return EOF;
    f->unget = c & 255;
    f->flags = f->flags & ~_F_EOF;
    return c;
}

static int put(int c, FILE *f)
{
    if (f->cnt <= 0 && fflush(f))
        return EOF;
    *f->ptr++ = c;
    f->cnt--;
    return c & 255;
}

int _putc(int c, FILE *f)
{
    if (!(f->flags & _F_WRITE))
        return EOF;
    if (c == '\n' && (f->flags & _F_TEXT))
        put(13, f);
    if (put(c, f) == EOF)
        return EOF;
    if (c == '\n' && (f->flags & _F_LINE))
        fflush(f);
    return c & 255;
}

int getchar(void)
{
    return getc(stdin);
}

int putchar(int c)
{
    return putc(c, stdout);
}

char *fgets(char *s, int n, FILE *f)
{
    int c, i;
    i = 0;
    while (i < n - 1) {
        c = getc(f);
        if (c == EOF)
            break;
        s[i++] = c;
        if (c == '\n')
            break;
    }
    if (i == 0)
        return 0;
    s[i] = 0;
    return s;
}

char *gets(char *s)
{
    int c, i;
    i = 0;
    for (;;) {
        c = getc(stdin);
        if (c == EOF) {
            if (i == 0)
                return 0;
            break;
        }
        if (c == '\n')
            break;
        s[i++] = c;
    }
    s[i] = 0;
    return s;
}

int fputs(char *s, FILE *f)
{
    while (*s)
        if (putc(*s++, f) == EOF)
            return EOF;
    return 0;
}

int puts(char *s)
{
    if (fputs(s, stdout) == EOF)
        return EOF;
    return putc('\n', stdout);
}

int fread(void *buf, int size, int n, FILE *f)
{
    char *p;
    int i, k, c;
    p = buf;
    for (i = 0; i < n; i++)
        for (k = 0; k < size; k++) {
            c = getc(f);
            if (c == EOF)
                return i;
            *p++ = c;
        }
    return n;
}

int fwrite(void *buf, int size, int n, FILE *f)
{
    char *p;
    int i, k;
    p = buf;
    for (i = 0; i < n; i++)
        for (k = 0; k < size; k++)
            if (putc(*p++, f) == EOF)
                return i;
    return n;
}

int feof(FILE *f)
{
    return (f->flags & _F_EOF) != 0;
}

int ferror(FILE *f)
{
    return (f->flags & _F_ERR) != 0;
}

void clearerr(FILE *f)
{
    f->flags = f->flags & ~(_F_EOF | _F_ERR);
}
