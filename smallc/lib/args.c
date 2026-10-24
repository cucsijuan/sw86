/* args.c - argc and argv from the command tail
 *
 * argv[0] is the program's path, from the end of its environment; the
 * words of the tail follow, a word in "quotes" may hold spaces.
 */
#include <dos.h>

#define MAXARGS 24

int _argc;
char **_argv;
static char *args[MAXARGS + 1];
static char tail[130];
static char path[80];

void _setargv(void)
{
    unsigned env;
    int i, n, len, q;
    char *p;
    env = peek(_psp, 0x2C);
    i = 0;
    if (env) {
        while (peekb(env, i) || peekb(env, i + 1))
            i++;
        i = i + 4;
        for (n = 0; n < 79 && peekb(env, i + n); n++)
            path[n] = peekb(env, i + n);
        path[n] = 0;
    }
    args[0] = path;
    _argc = 1;
    len = peekb(_psp, 0x80);
    for (i = 0; i < len && i < 127; i++)
        tail[i] = peekb(_psp, 0x81 + i);
    tail[i] = 0;
    p = tail;
    for (;;) {
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == 0 || *p == 13 || _argc >= MAXARGS)
            break;
        q = *p == '"';
        if (q)
            p++;
        args[_argc++] = p;
        while (*p && *p != 13 && (q ? *p != '"' : *p != ' ' && *p != '\t'))
            p++;
        if (*p == 0)
            break;
        *p++ = 0;
    }
    args[_argc] = 0;
    _argv = args;
}

/* The value of a variable of the environment, or 0 */
char *getenv(char *name)
{
    static char value[128];
    unsigned env;
    int i, k, n;
    env = peek(_psp, 0x2C);
    if (!env)
        return 0;
    i = 0;
    while (peekb(env, i)) {
        for (k = 0; name[k] && peekb(env, i + k) == name[k]; k++)
            ;
        if (name[k] == 0 && peekb(env, i + k) == '=') {
            i = i + k + 1;
            for (n = 0; n < 127 && peekb(env, i + n); n++)
                value[n] = peekb(env, i + n);
            value[n] = 0;
            return value;
        }
        while (peekb(env, i))
            i++;
        i++;
    }
    return 0;
}
