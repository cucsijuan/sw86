/* stdio.h - streams */
#ifndef _STDIO_H
#define _STDIO_H

struct _iobuf {
    int fd;
    int flags;
    char *ptr;              /* the next character */
    int cnt;                /* characters left to read, or room left to write */
    char *base;             /* the buffer */
    int size;
    int unget;              /* a character given back, or -1 */
};

#define FILE        struct _iobuf
#define EOF         (-1)
#define BUFSIZ      512
#define FOPEN_MAX   10
#define NULL        0

#define _F_READ     1
#define _F_WRITE    2
#define _F_TEXT     4
#define _F_EOF      8
#define _F_ERR      16
#define _F_MALLOC   32
#define _F_LINE     64

extern FILE _iob[];
#define stdin       (&_iob[0])
#define stdout      (&_iob[1])
#define stderr      (&_iob[2])

FILE *fopen(char *name, char *mode);
int fclose(FILE *f);
int fflush(FILE *f);
int getc(FILE *f);
int fgetc(FILE *f);
int ungetc(int c, FILE *f);
int putc(int c, FILE *f);
int fputc(int c, FILE *f);
int getchar(void);
int putchar(int c);
char *fgets(char *s, int n, FILE *f);
char *gets(char *s);
int fputs(char *s, FILE *f);
int puts(char *s);
int fread(void *buf, int size, int n, FILE *f);
int fwrite(void *buf, int size, int n, FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
int remove(char *name);
int rename(char *old, char *new);
int printf(char *fmt, ...);
int fprintf(FILE *f, char *fmt, ...);
int sprintf(char *s, char *fmt, ...);
int vprintf(char *fmt, char *ap);
int vfprintf(FILE *f, char *fmt, char *ap);
int vsprintf(char *s, char *fmt, char *ap);

#endif
