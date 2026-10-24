/* printf.c - formatted output: %d %i %u %x %X %o %c %s %p %%, with the
 * flags - 0 + and space, a width and a precision (or *) */
#include <stdio.h>

static FILE *pf;
static char *ps;
static int pn;

static void out(int c)
{
    if (ps)
        *ps++ = c;
    else
        putc(c, pf);
    pn++;
}

static void pad(int c, int n)
{
    while (n-- > 0)
        out(c);
}

static int doprnt(char *fmt, char *ap)
{
    char buf[8], *s;
    int c, left, zero, sign, width, prec, len, neg, base, k, digits;
    unsigned u;
    pn = 0;
    while ((c = *fmt++) != 0) {
        if (c != '%') {
            out(c);
            continue;
        }
        left = 0;
        zero = 0;
        sign = 0;
        for (;;) {
            c = *fmt;
            if (c == '-') left = 1;
            else if (c == '0') zero = 1;
            else if (c == '+') sign = '+';
            else if (c == ' ') { if (!sign) sign = ' '; }
            else break;
            fmt++;
        }
        width = 0;
        if (*fmt == '*') {
            width = *(int *)ap;
            ap = ap + 2;
            fmt++;
            if (width < 0) {
                left = 1;
                width = -width;
            }
        } else
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + *fmt++ - '0';
        prec = -1;
        if (*fmt == '.') {
            fmt++;
            prec = 0;
            if (*fmt == '*') {
                prec = *(int *)ap;
                ap = ap + 2;
                fmt++;
            } else
                while (*fmt >= '0' && *fmt <= '9')
                    prec = prec * 10 + *fmt++ - '0';
        }
        while (*fmt == 'l' || *fmt == 'h')
            fmt++;
        c = *fmt++;
        if (c == 0)
            break;
        if (c == 's') {
            s = *(char **)ap;
            ap = ap + 2;
            if (!s)
                s = "(null)";
            for (len = 0; s[len] && (prec < 0 || len < prec); len++)
                ;
            if (!left)
                pad(' ', width - len);
            for (k = 0; k < len; k++)
                out(s[k]);
            if (left)
                pad(' ', width - len);
            continue;
        }
        if (c == 'c') {
            if (!left)
                pad(' ', width - 1);
            out(*(int *)ap);
            ap = ap + 2;
            if (left)
                pad(' ', width - 1);
            continue;
        }
        if (c != 'd' && c != 'i' && c != 'u' && c != 'x' && c != 'X' && c != 'o' && c != 'p') {
            out(c);
            continue;
        }
        u = *(unsigned *)ap;
        ap = ap + 2;
        neg = 0;
        if ((c == 'd' || c == 'i') && (int)u < 0) {
            neg = 1;
            u = -u;
        }
        base = c == 'o' ? 8 : (c == 'x' || c == 'X' || c == 'p') ? 16 : 10;
        len = 0;
        do {
            k = u % base;
            buf[len++] = k < 10 ? '0' + k : (c == 'X' ? 'A' : 'a') + k - 10;
            u = u / base;
        } while (u);
        if (c == 'p')
            while (len < 4)
                buf[len++] = '0';
        while (len < prec && len < 8)
            buf[len++] = '0';
        k = neg || ((c == 'd' || c == 'i') && sign);
        if (!left && !zero)
            pad(' ', width - len - k);
        if (neg)
            out('-');
        else if (k)
            out(sign);
        if (!left && zero)
            pad('0', width - len - k);
        digits = len;
        while (len > 0)
            out(buf[--len]);
        if (left)
            pad(' ', width - digits - k);
    }
    return pn;
}

int vfprintf(FILE *f, char *fmt, char *ap)
{
    pf = f;
    ps = 0;
    return doprnt(fmt, ap);
}

int vprintf(char *fmt, char *ap)
{
    return vfprintf(stdout, fmt, ap);
}

int vsprintf(char *s, char *fmt, char *ap)
{
    int n;
    ps = s;
    n = doprnt(fmt, ap);
    *ps = 0;
    ps = 0;
    return n;
}

int printf(char *fmt, ...)
{
    return vfprintf(stdout, fmt, (char *)&fmt + 2);
}

int fprintf(FILE *f, char *fmt, ...)
{
    return vfprintf(f, fmt, (char *)&fmt + 2);
}

int sprintf(char *s, char *fmt, ...)
{
    return vsprintf(s, fmt, (char *)&fmt + 2);
}
