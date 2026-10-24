/* fopen.c - opening and closing streams */
#include <stdio.h>
#include <stdlib.h>
#include <io.h>

FILE *fopen(char *name, char *mode)
{
    FILE *f;
    int i, fd, flags, plus;
    char *m;
    for (i = 3; i < FOPEN_MAX; i++)
        if (_iob[i].flags == 0)
            break;
    if (i == FOPEN_MAX)
        return 0;
    f = &_iob[i];
    flags = _F_TEXT;
    plus = 0;
    for (m = mode + 1; *m; m++) {
        if (*m == 'b')
            flags = 0;
        else if (*m == '+')
            plus = 1;
    }
    if (*mode == 'r') {
        fd = open(name, plus ? O_RDWR : O_RDONLY);
        flags = flags | _F_READ;
    } else if (*mode == 'w') {
        fd = creat(name, 0);
        flags = flags | _F_WRITE;
    } else if (*mode == 'a') {
        fd = open(name, O_WRONLY);
        if (fd < 0)
            fd = creat(name, 0);
        else
            lseek(fd, 0, 0, SEEK_END);
        flags = flags | _F_WRITE;
    } else
        return 0;
    if (fd < 0)
        return 0;
    if (plus)
        flags = flags | _F_READ | _F_WRITE;
    f->base = malloc(BUFSIZ);
    if (!f->base) {
        close(fd);
        return 0;
    }
    f->fd = fd;
    f->flags = flags | _F_MALLOC;
    f->size = BUFSIZ;
    f->ptr = f->base;
    f->cnt = (flags & _F_WRITE) ? BUFSIZ : 0;
    f->unget = -1;
    return f;
}

int fclose(FILE *f)
{
    int r;
    r = fflush(f);
    if (close(f->fd) < 0)
        r = EOF;
    if (f->flags & _F_MALLOC)
        free(f->base);
    f->flags = 0;
    return r;
}

int remove(char *name)
{
    return unlink(name);
}
