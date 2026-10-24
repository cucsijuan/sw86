/* string.h - strings and memory */
#ifndef _STRING_H
#define _STRING_H

#define NULL        0

int strlen(char *s);
char *strcpy(char *d, char *s);
char *strncpy(char *d, char *s, int n);
char *strcat(char *d, char *s);
char *strncat(char *d, char *s, int n);
int strcmp(char *a, char *b);
int strncmp(char *a, char *b, int n);
int stricmp(char *a, char *b);
char *strchr(char *s, int c);
char *strrchr(char *s, int c);
char *strstr(char *s, char *t);
char *strupr(char *s);
char *strlwr(char *s);
char *strdup(char *s);
void *memcpy(void *d, void *s, int n);
void *memmove(void *d, void *s, int n);
void *memset(void *d, int c, int n);
int memcmp(void *a, void *b, int n);

#endif
