/* io.h - files by handle, as COS gives them */
#ifndef _IO_H
#define _IO_H

#define O_RDONLY    0
#define O_WRONLY    1
#define O_RDWR      2

#define SEEK_SET    0
#define SEEK_CUR    1
#define SEEK_END    2

extern int errno;

int open(char *name, int mode);
int creat(char *name, int attrib);
int close(int fd);
int read(int fd, void *buf, unsigned n);
int write(int fd, void *buf, unsigned n);
int unlink(char *name);
int rename(char *old, char *new);
unsigned lseek(int fd, unsigned lo, unsigned hi, int whence);
int isatty(int fd);

#endif
