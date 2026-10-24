/* lex.c - the source files, the preprocessor and the tokens
 *
 * Lines are read one at a time: comments are removed, the directives are
 * done here, and the other lines have their macros replaced in place and
 * are cut into tokens. Names are interned once: a name is its number in the
 * table, which also says what it means (nm_sym), whether it is a macro
 * (nm_mac) and what the link knows of it (nm_link).
 */
#include "smallc.h"

int tok, tokval, tokuns, toklen;
char tokstr[STRSIZE];
char asmbuf[ASMSIZE];
static int pk_tok, pk_val, pk_uns, pk_len, has_peek;
static char pk_str[STRSIZE];

char npool[NAMEPOOL];
static int npool_len;
int nm_str[MAXNAMES], nm_next[MAXNAMES], nm_sym[MAXNAMES], nm_mac[MAXNAMES];
char nm_link[MAXNAMES];
int nnames;
static int nm_hash[HASHSIZE];

static char mpool[MACROPOOL];
static int mpool_len;
static int mac_body[MAXMACROS], mac_nparams[MAXMACROS];
static int nmacros;

/* The files being read: the source and its #includes */
static FILE *f_fp[MAXINCLUDE];
static char f_name[MAXINCLUDE][PATHSIZE];
static int f_line[MAXINCLUDE];
static int nfiles;
char *srcname;
int srcline;
int nerrors;
char *idirs[MAXIDIRS];
int nidirs;

static char raw[LINESIZE];
static char lbuf[XLINESIZE];
static char xt[XLINESIZE];
static char *lp;
static int in_comment;

#define IF_ACTIVE   0
#define IF_SEEK     1           /* no branch taken yet */
#define IF_DONE     2           /* a branch was taken, or the outer #if is off */
static int ifstk[16], nif;

static char *keywords[NKEYWORDS] = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "else", "enum", "extern", "for", "goto", "if", "int", "long",
    "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
    "typedef", "union", "unsigned", "void", "volatile", "while", "float", "double"
};

/* ---------------------------------------------------------------- errors */

void error(char *msg)
{
    if (nfiles)
        printf("%s(%d): %s\n", srcname, srcline, msg);
    else
        printf("SMALLC: %s\n", msg);
    if (++nerrors >= 20) {
        printf("SMALLC: too many errors\n");
        exit(1);
    }
}

void error_s(char *msg, char *s)
{
    char buf[120];
    sprintf(buf, msg, s);
    error(buf);
}

void fatal(char *msg)
{
    error(msg);
    exit(1);
}

/* ----------------------------------------------------------------- names */

/* v as a 16-bit int */
int w16(int v)
{
    v = v & 0xFFFF;
    if (v & 0x8000)
        v = v | ~0xFFFF;
    return v;
}

static int hash(char *s, int n)
{
    int h, i;
    h = 0;
    for (i = 0; i < n; i++)
        h = ((h << 3) + h + (s[i] & 255)) & 0x7FFF;
    return h & (HASHSIZE - 1);
}

static int find_name(char *s, int n)
{
    int id;
    char *p;
    for (id = nm_hash[hash(s, n)]; id >= 0; id = nm_next[id]) {
        p = npool + nm_str[id];
        if (!strncmp(p, s, n) && p[n] == 0)
            return id;
    }
    return -1;
}

int intern_n(char *s, int n)
{
    int id, h;
    id = find_name(s, n);
    if (id >= 0)
        return id;
    if (nnames >= MAXNAMES || npool_len + n + 1 > NAMEPOOL)
        fatal("too many names");
    h = hash(s, n);
    id = nnames++;
    nm_str[id] = npool_len;
    memcpy(npool + npool_len, s, n);
    npool[npool_len + n] = 0;
    npool_len = npool_len + n + 1;
    nm_next[id] = nm_hash[h];
    nm_hash[h] = id;
    nm_sym[id] = 0;
    nm_mac[id] = 0;
    nm_link[id] = 0;
    return id;
}

int intern(char *s)
{
    return intern_n(s, strlen(s));
}

char *name_of(int id)
{
    return npool + nm_str[id];
}

void lex_init(void)
{
    int i;
    for (i = 0; i < HASHSIZE; i++)
        nm_hash[i] = -1;
    for (i = 0; i < NKEYWORDS; i++)
        intern(keywords[i]);
}

/* Forgets the macros of the last source file */
void lex_reset(void)
{
    int i;
    for (i = 0; i < nnames; i++)
        nm_mac[i] = 0;
    nmacros = 0;
    mpool_len = 0;
    nif = 0;
    in_comment = 0;
    has_peek = 0;
}

/* --------------------------------------------------------------- the files */

static int is_id_start(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int is_digit(int c)
{
    return c >= '0' && c <= '9';
}

static int is_id_char(int c)
{
    return is_id_start(c) || is_digit(c);
}

static int push_file(char *name)
{
    FILE *fp;
    if (nfiles >= MAXINCLUDE) {
        error("#include nested too deep");
        return 1;
    }
    if (strlen(name) >= PATHSIZE)
        return 0;
    fp = fopen(name, "r");
    if (!fp)
        return 0;
    if (nfiles)
        f_line[nfiles - 1] = srcline;
    f_fp[nfiles] = fp;
    strcpy(f_name[nfiles], name);
    srcname = f_name[nfiles];
    srcline = 0;
    nfiles++;
    return 1;
}

static void pop_file(void)
{
    nfiles--;
    fclose(f_fp[nfiles]);
    if (nfiles) {
        srcname = f_name[nfiles - 1];
        srcline = f_line[nfiles - 1];
    }
}

/* Opens a source file: 0 if it cannot be read */
int lex_open(char *name)
{
    nfiles = 0;
    if (!push_file(name))
        return 0;
    lbuf[0] = 0;
    lp = lbuf;
    return 1;
}

void lex_close(void)
{
    while (nfiles)
        pop_file();
}

/* Reads a line of the current file into raw, joining lines that end with
 * a backslash. 0 at the end of the file. */
static int read_raw(void)
{
    FILE *fp;
    int c, n;
    fp = f_fp[nfiles - 1];
    n = 0;
    c = getc(fp);
    if (c == EOF)
        return 0;
    for (;;) {
        if (c == EOF || c == '\n') {
            srcline++;
            if (n > 0 && raw[n - 1] == '\\') {
                n--;
                if (c == EOF)
                    break;
                c = getc(fp);
                continue;
            }
            break;
        }
        if (c != '\r') {
            if (n >= LINESIZE - 1) {
                error("line too long");
                while (c != EOF && c != '\n')
                    c = getc(fp);
                continue;
            }
            raw[n++] = c;
        }
        c = getc(fp);
    }
    raw[n] = 0;
    return 1;
}

/* Copies raw to lbuf without its comments (a comment is a space) */
static void strip(void)
{
    char *s, *d;
    int q;
    s = raw;
    d = lbuf;
    while (*s) {
        if (in_comment) {
            if (s[0] == '*' && s[1] == '/') {
                in_comment = 0;
                s = s + 2;
                *d++ = ' ';
            } else
                s++;
            continue;
        }
        if (s[0] == '/' && s[1] == '*') {
            in_comment = 1;
            s = s + 2;
            continue;
        }
        if (s[0] == '/' && s[1] == '/')
            break;
        if (*s == '"' || *s == '\'') {
            q = *s;
            *d++ = *s++;
            while (*s && *s != q) {
                if (*s == '\\' && s[1])
                    *d++ = *s++;
                *d++ = *s++;
            }
            if (*s)
                *d++ = *s++;
            continue;
        }
        *d++ = *s++;
    }
    *d = 0;
}

/* ----------------------------------------------------------------- macros */

/* Skips a string or character constant at b[i] */
static int skip_quoted(char *b, int i)
{
    int q;
    q = b[i++];
    while (b[i] && b[i] != q) {
        if (b[i] == '\\' && b[i + 1])
            i++;
        i++;
    }
    if (b[i])
        i++;
    return i;
}

static char *skipsp(char *p)
{
    while (*p == ' ' || *p == '\t')
        p++;
    return p;
}

/* Replaces the macros of the line b (XLINESIZE bytes) in place. The text
 * that replaces a macro is read again, so macros can use macros. */
static void expand(char *b)
{
    int i, start, end, m, k, n, count, depth, nargs, c;
    int as[16], al[16];
    char *body, *d;
    i = 0;
    count = 0;
    while (b[i]) {
        c = b[i];
        if (c == '"' || c == '\'') {
            i = skip_quoted(b, i);
            continue;
        }
        if (is_digit(c)) {
            while (is_id_char(b[i]) || b[i] == '.')
                i++;
            continue;
        }
        if (!is_id_start(c)) {
            i++;
            continue;
        }
        start = i;
        while (is_id_char(b[i]))
            i++;
        m = find_name(b + start, i - start);
        if (m < 0 || !nm_mac[m])
            continue;
        m = nm_mac[m] - 1;
        end = i;
        nargs = 0;
        if (mac_nparams[m] >= 0) {
            k = i;
            while (b[k] == ' ' || b[k] == '\t')
                k++;
            if (b[k] != '(')
                continue;
            k++;
            depth = 0;
            as[0] = k;
            for (;;) {
                c = b[k];
                if (c == 0) {
                    error("the arguments of a macro must be on one line");
                    return;
                }
                if (c == '"' || c == '\'') {
                    k = skip_quoted(b, k);
                    continue;
                }
                if (c == '(')
                    depth++;
                else if (c == ')' && depth > 0)
                    depth--;
                else if ((c == ',' || c == ')') && depth == 0) {
                    if (nargs < 16) {
                        al[nargs] = k - as[nargs];
                        nargs++;
                    }
                    k++;
                    if (c == ')')
                        break;
                    if (nargs < 16)
                        as[nargs] = k;
                    continue;
                }
                k++;
            }
            end = k;
            for (k = 0; k < nargs; k++) {      /* without spaces around */
                while (al[k] > 0 && (b[as[k]] == ' ' || b[as[k]] == '\t')) {
                    as[k]++;
                    al[k]--;
                }
                while (al[k] > 0 && (b[as[k] + al[k] - 1] == ' ' || b[as[k] + al[k] - 1] == '\t'))
                    al[k]--;
            }
            if (nargs == 1 && al[0] == 0 && mac_nparams[m] == 0)
                nargs = 0;
            if (nargs != mac_nparams[m]) {
                error("wrong number of arguments for a macro");
                return;
            }
        }
        body = mpool + mac_body[m];
        d = xt;
        n = 0;
        while (*body) {
            if (*body < 32 && *body > 0) {
                k = *body - 1;
                if (n + al[k] >= XLINESIZE - 1)
                    break;
                memcpy(d + n, b + as[k], al[k]);
                n = n + al[k];
            } else if (n < XLINESIZE - 1)
                d[n++] = *body;
            body++;
        }
        k = strlen(b + end);
        if (start + n + k >= XLINESIZE - 1) {
            error("line too long after its macros");
            return;
        }
        memmove(b + start + n, b + end, k + 1);
        memcpy(b + start, xt, n);
        i = start;
        if (++count > 400) {
            error("a macro expands without end");
            return;
        }
    }
}

void define_macro(char *p)
{
    int id, m, n, k, np, len;
    int pn[16];
    char *s;
    p = skipsp(p);
    if (!is_id_start(*p)) {
        error("#define needs a name");
        return;
    }
    s = p;
    while (is_id_char(*p))
        p++;
    id = intern_n(s, p - s);
    np = -1;
    if (*p == '(') {
        np = 0;
        p = skipsp(p + 1);
        while (*p != ')') {
            if (!is_id_start(*p) || np >= 16) {
                error("bad macro parameters");
                return;
            }
            s = p;
            while (is_id_char(*p))
                p++;
            pn[np++] = intern_n(s, p - s);
            p = skipsp(p);
            if (*p == ',')
                p = skipsp(p + 1);
            else if (*p != ')') {
                error("bad macro parameters");
                return;
            }
        }
        p++;
    }
    p = skipsp(p);
    len = strlen(p);
    while (len > 0 && (p[len - 1] == ' ' || p[len - 1] == '\t'))
        len--;
    if (nmacros >= MAXMACROS || mpool_len + len + 1 > MACROPOOL)
        fatal("too many macros");
    m = nmacros++;
    mac_body[m] = mpool_len;
    mac_nparams[m] = np;
    n = 0;
    while (n < len) {
        if (p[n] == '"' || p[n] == '\'') {
            k = skip_quoted(p, n);
            if (k > len)
                k = len;
            memcpy(mpool + mpool_len, p + n, k - n);
            mpool_len = mpool_len + k - n;
            n = k;
            continue;
        }
        if (p[n] == '#') {
            error("the # and ## operators are not supported");
            return;
        }
        if (is_id_start(p[n]) && np > 0) {
            s = p + n;
            while (n < len && is_id_char(p[n]))
                n++;
            k = intern_n(s, p + n - s);
            for (m = 0; m < np; m++)
                if (pn[m] == k)
                    break;
            if (m < np)
                mpool[mpool_len++] = m + 1;
            else {
                memcpy(mpool + mpool_len, s, p + n - s);
                mpool_len = mpool_len + (p + n - s);
            }
            continue;
        }
        if (is_digit(p[n])) {
            while (n < len && (is_id_char(p[n]) || p[n] == '.'))
                mpool[mpool_len++] = p[n++];
            continue;
        }
        mpool[mpool_len++] = p[n++];
    }
    mpool[mpool_len++] = 0;
    nm_mac[id] = nmacros;
}

/* --------------------------------------------------------- #if expressions */

static char *ep;

static int e_cond(void);

static int e_primary(void)
{
    int v, base;
    ep = skipsp(ep);
    if (*ep == '(') {
        ep++;
        v = e_cond();
        ep = skipsp(ep);
        if (*ep == ')')
            ep++;
        else
            error("')' missing in #if");
        return v;
    }
    if (*ep == '!') { ep++; return !e_primary(); }
    if (*ep == '-') { ep++; return w16(-e_primary()); }
    if (*ep == '~') { ep++; return w16(~e_primary()); }
    if (*ep == '+') { ep++; return e_primary(); }
    if (is_digit(*ep)) {
        v = 0;
        base = 10;
        if (*ep == '0') {
            base = 8;
            ep++;
            if (*ep == 'x' || *ep == 'X') {
                base = 16;
                ep++;
            }
        }
        for (;;) {
            if (is_digit(*ep) && *ep - '0' < base)
                v = w16(v * base + *ep - '0');
            else if (base == 16 && *ep >= 'a' && *ep <= 'f')
                v = w16(v * 16 + *ep - 'a' + 10);
            else if (base == 16 && *ep >= 'A' && *ep <= 'F')
                v = w16(v * 16 + *ep - 'A' + 10);
            else
                break;
            ep++;
        }
        while (*ep == 'u' || *ep == 'U' || *ep == 'l' || *ep == 'L')
            ep++;
        return v;
    }
    if (*ep == '\'') {
        ep++;
        v = *ep++;
        if (v == '\\') {
            v = *ep++;
            if (v == 'n') v = 10;
            else if (v == 't') v = 9;
            else if (v == '0') v = 0;
        }
        if (*ep == '\'')
            ep++;
        return v;
    }
    if (is_id_start(*ep)) {             /* a name that is not a macro */
        while (is_id_char(*ep))
            ep++;
        return 0;
    }
    error("bad #if expression");
    return 0;
}

static int e_binary(int prec)
{
    int v, r, op, p;
    v = e_primary();
    for (;;) {
        ep = skipsp(ep);
        op = ep[0];
        p = 0;
        if (op == '*' || op == '/' || op == '%') p = 10;
        else if (op == '+' || op == '-') p = 9;
        else if ((op == '<' && ep[1] == '<') || (op == '>' && ep[1] == '>')) { p = 8; op = op == '<' ? 'L' : 'R'; }
        else if (op == '<' || op == '>') { p = 7; if (ep[1] == '=') op = op == '<' ? 'l' : 'g'; }
        else if ((op == '=' || op == '!') && ep[1] == '=') p = 6;
        else if (op == '&' && ep[1] == '&') { p = 2; op = 'A'; }
        else if (op == '|' && ep[1] == '|') { p = 1; op = 'O'; }
        else if (op == '&') p = 5;
        else if (op == '^') p = 4;
        else if (op == '|') p = 3;
        if (p == 0 || p < prec)
            return v;
        ep++;
        if (op == 'L' || op == 'R' || op == 'l' || op == 'g' || op == '=' || op == '!' || op == 'A' || op == 'O')
            ep++;
        r = e_binary(p + 1);
        if (op == '*') v = v * r;
        else if (op == '/') v = r ? v / r : 0;
        else if (op == '%') v = r ? v % r : 0;
        else if (op == '+') v = v + r;
        else if (op == '-') v = v - r;
        else if (op == 'L') v = v << r;
        else if (op == 'R') v = v >> r;
        else if (op == '<') v = v < r;
        else if (op == '>') v = v > r;
        else if (op == 'l') v = v <= r;
        else if (op == 'g') v = v >= r;
        else if (op == '=') v = v == r;
        else if (op == '!') v = v != r;
        else if (op == '&') v = v & r;
        else if (op == '^') v = v ^ r;
        else if (op == '|') v = v | r;
        else if (op == 'A') v = v && r;
        else if (op == 'O') v = v || r;
        v = w16(v);
    }
}

static int e_cond(void)
{
    int c, a, b;
    c = e_binary(1);
    ep = skipsp(ep);
    if (*ep != '?')
        return c;
    ep++;
    a = e_cond();
    ep = skipsp(ep);
    if (*ep == ':')
        ep++;
    b = e_cond();
    return c ? a : b;
}

/* The value of the #if expression at p: defined() first, then macros */
static int if_value(char *p)
{
    char *d, *s;
    int id, paren;
    d = xt;
    while (*p) {
        if (is_id_start(*p)) {
            s = p;
            while (is_id_char(*p))
                p++;
            if (p - s == 7 && !strncmp(s, "defined", 7)) {
                p = skipsp(p);
                paren = *p == '(';
                if (paren)
                    p = skipsp(p + 1);
                s = p;
                while (is_id_char(*p))
                    p++;
                id = find_name(s, p - s);
                *d++ = id >= 0 && nm_mac[id] ? '1' : '0';
                if (paren) {
                    p = skipsp(p);
                    if (*p == ')')
                        p++;
                }
                continue;
            }
            while (s < p)
                *d++ = *s++;
            continue;
        }
        *d++ = *p++;
    }
    *d = 0;
    strcpy(lbuf, xt);
    expand(lbuf);
    ep = lbuf;
    id = e_cond();
    ep = skipsp(ep);
    if (*ep)
        error("bad #if expression");
    return id;
}

/* ------------------------------------------------------------ directives */

static void include_file(char *p)
{
    char name[PATHSIZE], path[PATHSIZE];
    int n, i, close;
    p = skipsp(p);
    if (*p != '"' && *p != '<') {
        error("#include needs \"file\" or <file>");
        return;
    }
    close = *p == '"' ? '"' : '>';
    p++;
    n = 0;
    while (*p && *p != close && n < PATHSIZE - 1)
        name[n++] = *p++;
    name[n] = 0;
    if (close == '"') {
        strcpy(path, srcname);         /* first next to the file that includes it */
        n = strlen(path);
        while (n > 0 && path[n - 1] != '/' && path[n - 1] != '\\' && path[n - 1] != ':')
            n--;
        path[n] = 0;
        if (n + strlen(name) < PATHSIZE) {
            strcat(path, name);
            if (push_file(path))
                return;
        }
    }
    for (i = 0; i < nidirs; i++) {
        strcpy(path, idirs[i]);
        if (strlen(path) + strlen(name) < PATHSIZE) {
            strcat(path, name);
            if (push_file(path))
                return;
        }
    }
    error_s("cannot open the include file %s", name);
}

static int read_asm(void)
{
    int n, k;
    char *p;
    n = 0;
    for (;;) {
        if (!read_raw()) {
            error("#asm without #endasm");
            break;
        }
        p = skipsp(raw);
        if (*p == '#') {
            p = skipsp(p + 1);
            if (!strncmp(p, "endasm", 6))
                break;
        }
        k = strlen(raw);
        if (n + k + 2 >= ASMSIZE) {
            error("#asm block too long");
            continue;
        }
        strcpy(asmbuf + n, raw);
        n = n + k;
        asmbuf[n++] = '\n';
    }
    asmbuf[n] = 0;
    return 2;
}

/* Does the directive in lbuf. 2 when it was #asm. */
static int directive(char *p)
{
    char *s;
    int n, id, on, v;
    p = skipsp(p + 1);
    s = p;
    while (is_id_char(*p))
        p++;
    n = p - s;
    on = nif == 0 || ifstk[nif - 1] == IF_ACTIVE;
    if ((n == 2 && !strncmp(s, "if", 2)) || (n == 5 && !strncmp(s, "ifdef", 5)) || (n == 6 && !strncmp(s, "ifndef", 6))) {
        if (nif >= 16)
            fatal("#if nested too deep");
        if (!on) {
            ifstk[nif++] = IF_DONE;
            return 0;
        }
        if (n == 2)
            v = if_value(p);
        else {
            p = skipsp(p);
            s = p;
            while (is_id_char(*p))
                p++;
            id = find_name(s, p - s);
            v = id >= 0 && nm_mac[id];
            if (n == 6)
                v = !v;
        }
        ifstk[nif++] = v ? IF_ACTIVE : IF_SEEK;
        return 0;
    }
    if ((n == 4 && !strncmp(s, "elif", 4)) || (n == 4 && !strncmp(s, "else", 4))) {
        if (nif == 0) {
            error("#else without #if");
            return 0;
        }
        if (ifstk[nif - 1] == IF_ACTIVE)
            ifstk[nif - 1] = IF_DONE;
        else if (ifstk[nif - 1] == IF_SEEK) {
            if (s[2] == 's' || if_value(p))
                ifstk[nif - 1] = IF_ACTIVE;
        }
        return 0;
    }
    if (n == 5 && !strncmp(s, "endif", 5)) {
        if (nif == 0)
            error("#endif without #if");
        else
            nif--;
        return 0;
    }
    if (!on)
        return 0;
    if (n == 7 && !strncmp(s, "include", 7))
        include_file(p);
    else if (n == 6 && !strncmp(s, "define", 6))
        define_macro(p);
    else if (n == 5 && !strncmp(s, "undef", 5)) {
        p = skipsp(p);
        s = p;
        while (is_id_char(*p))
            p++;
        id = find_name(s, p - s);
        if (id >= 0)
            nm_mac[id] = 0;
    } else if (n == 5 && !strncmp(s, "error", 5))
        error_s("#error%s", p);
    else if (n == 3 && !strncmp(s, "asm", 3))
        return read_asm();
    else if ((n == 6 && !strncmp(s, "pragma", 6)) || (n == 4 && !strncmp(s, "line", 4)) || n == 0)
        ;
    else
        error("unknown directive");
    return 0;
}

/* The next line of program text into lbuf: 1, 2 for a #asm block in
 * asmbuf, 0 at the end of the source */
static int read_line(void)
{
    char *p;
    int was_comment;
    for (;;) {
        if (!read_raw()) {
            if (nfiles > 1) {
                pop_file();
                continue;
            }
            if (nif)
                error("#if without #endif");
            if (in_comment)
                error("comment without its end");
            nif = 0;
            return 0;
        }
        was_comment = in_comment;
        strip();
        p = skipsp(lbuf);
        if (*p == '#' && !was_comment) {
            if (directive(p) == 2)
                return 2;
            continue;
        }
        if (nif && ifstk[nif - 1] != IF_ACTIVE)
            continue;
        expand(lbuf);
        lp = lbuf;
        return 1;
    }
}

/* ---------------------------------------------------------------- tokens */

static int escape(void)
{
    int c, v, n;
    c = *lp++;
    if (c != '\\')
        return c & 255;
    c = *lp++;
    if (c == 'n') return 10;
    if (c == 't') return 9;
    if (c == 'r') return 13;
    if (c == 'a') return 7;
    if (c == 'b') return 8;
    if (c == 'f') return 12;
    if (c == 'v') return 11;
    if (c == 'x') {
        v = 0;
        for (;;) {
            c = *lp;
            if (is_digit(c)) v = v * 16 + c - '0';
            else if (c >= 'a' && c <= 'f') v = v * 16 + c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v = v * 16 + c - 'A' + 10;
            else break;
            lp++;
        }
        return v & 255;
    }
    if (c >= '0' && c <= '7') {
        v = c - '0';
        for (n = 1; n < 3 && *lp >= '0' && *lp <= '7'; n++)
            v = v * 8 + *lp++ - '0';
        return v & 255;
    }
    if (c == 0) {
        lp--;
        return '\\';
    }
    return c & 255;
}

static void number(void)
{
    int base, d, big, c;
    base = 10;
    tokval = 0;
    big = 0;
    if (*lp == '0') {
        base = 8;
        lp++;
        if (*lp == 'x' || *lp == 'X') {
            base = 16;
            lp++;
        }
    }
    for (;;) {
        c = *lp;
        if (is_digit(c)) d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        if (d >= base)
            break;
        if (!big && tokval > (32767 - d) / base)
            big = 1;
        tokval = w16(tokval * base + d);
        lp++;
    }
    tokuns = big;
    for (;;) {
        if (*lp == 'u' || *lp == 'U') {
            tokuns = 1;
            lp++;
        } else if (*lp == 'l' || *lp == 'L') {
            error("long constants are not supported");
            lp++;
        } else
            break;
    }
    if (is_id_char(*lp) || *lp == '.') {
        error("bad number");
        while (is_id_char(*lp) || *lp == '.')
            lp++;
    }
    tok = T_NUM;
}

static void scan(void)
{
    int c, r, id;
    char *s;
    for (;;) {
        while (*lp == ' ' || *lp == '\t' || *lp == '\f' || *lp == '\v')
            lp++;
        if (*lp)
            break;
        r = read_line();
        if (r == 0) {
            lbuf[0] = 0;
            lp = lbuf;
            tok = T_EOF;
            return;
        }
        if (r == 2) {
            lbuf[0] = 0;
            lp = lbuf;
            tok = T_ASM;
            return;
        }
    }
    c = *lp;
    if (is_id_start(c)) {
        s = lp;
        while (is_id_char(*lp))
            lp++;
        id = intern_n(s, lp - s);
        if (id < NKEYWORDS)
            tok = K_FIRST + id;
        else {
            tok = T_ID;
            tokval = id;
        }
        return;
    }
    if (is_digit(c)) {
        number();
        return;
    }
    if (c == '\'') {
        lp++;
        tokval = escape();
        if (tokval > 127)
            tokval = tokval - 256;      /* char is signed */
        if (*lp == '\'')
            lp++;
        else
            error("bad character constant");
        tok = T_NUM;
        tokuns = 0;
        return;
    }
    if (c == '"') {
        lp++;
        toklen = 0;
        while (*lp && *lp != '"') {
            r = escape();
            if (toklen < STRSIZE - 1)
                tokstr[toklen++] = r;
            else if (toklen == STRSIZE - 1) {
                error("string too long");
                toklen++;
            }
        }
        if (toklen >= STRSIZE)
            toklen = STRSIZE - 1;
        tokstr[toklen] = 0;
        if (*lp == '"')
            lp++;
        else
            error("string without its end");
        tok = T_STR;
        return;
    }
    lp++;
    tok = c;
    r = *lp;
    if (c == '+' && r == '+') tok = P_INC;
    else if (c == '-' && r == '-') tok = P_DEC;
    else if (c == '-' && r == '>') tok = P_ARROW;
    else if (c == '<' && r == '<') tok = lp[1] == '=' ? P_SHLA : P_SHL;
    else if (c == '>' && r == '>') tok = lp[1] == '=' ? P_SHRA : P_SHR;
    else if (c == '&' && r == '&') tok = P_LAND;
    else if (c == '|' && r == '|') tok = P_LOR;
    else if (c == '.' && r == '.' && lp[1] == '.') tok = P_DOTS;
    else if (r == '=') {
        if (c == '<') tok = P_LE;
        else if (c == '>') tok = P_GE;
        else if (c == '=') tok = P_EQ;
        else if (c == '!') tok = P_NE;
        else if (c == '+') tok = P_ADDA;
        else if (c == '-') tok = P_SUBA;
        else if (c == '*') tok = P_MULA;
        else if (c == '/') tok = P_DIVA;
        else if (c == '%') tok = P_MODA;
        else if (c == '&') tok = P_ANDA;
        else if (c == '^') tok = P_XORA;
        else if (c == '|') tok = P_ORA;
    }
    if (tok != c) {
        lp++;
        if (tok == P_SHLA || tok == P_SHRA || tok == P_DOTS)
            lp++;
    }
    if (!strchr("+-*/%<>=!&|^~?:;,.()[]{}", c)) {
        error("unexpected character");
        scan();
    }
}

void next(void)
{
    if (has_peek) {
        has_peek = 0;
        tok = pk_tok;
        tokval = pk_val;
        tokuns = pk_uns;
        toklen = pk_len;
        if (tok == T_STR)
            memcpy(tokstr, pk_str, toklen + 1);
        return;
    }
    scan();
}

/* The token after the current one */
int peek_tok(void)
{
    int t, v, u, n;
    if (!has_peek) {
        t = tok;
        v = tokval;
        u = tokuns;
        n = toklen;
        if (t == T_STR)
            memcpy(pk_str, tokstr, n + 1);
        scan();
        pk_tok = tok;
        pk_val = tokval;
        pk_uns = tokuns;
        pk_len = toklen;
        tok = t;
        tokval = v;
        tokuns = u;
        toklen = n;
        if (pk_tok == T_STR) {          /* swap the two strings */
            memcpy(xt, tokstr, pk_len + 1);
            if (t == T_STR)
                memcpy(tokstr, pk_str, n + 1);
            memcpy(pk_str, xt, pk_len + 1);
        } else if (t == T_STR)
            memcpy(tokstr, pk_str, n + 1);
        has_peek = 1;
    }
    return pk_tok;
}

int accept(int t)
{
    if (tok != t)
        return 0;
    next();
    return 1;
}

void expect(int t)
{
    char msg[24];
    if (tok == t) {
        next();
        return;
    }
    strcpy(msg, "'x' expected");
    msg[1] = t;
    error(msg);
}

/* The name of an identifier token, or -1 */
int ident(void)
{
    int id;
    if (tok != T_ID) {
        error("a name expected");
        return -1;
    }
    id = tokval;
    next();
    return id;
}
