/* decl.c - types, names and declarations
 *
 * A type is a number in the type table: its kind, the type it is built on
 * (what a pointer points to, the elements of an array, what a function
 * returns) and a count (the elements of an array, the structure). Types
 * are made once and found again, so two types are the same type when
 * their numbers are equal.
 *
 * Globals and locals live in two tables; nm_sym of a name says which entry
 * it means now (+g+1 a global, -(l+1) a local). A local remembers what its
 * name meant before it, so leaving a block gives the names back.
 */
#include "smallc.h"

int ty_kind[MAXTYPES], ty_base[MAXTYPES], ty_n[MAXTYPES];
static int ntypes;

int st_size[MAXSTRUCTS], st_first[MAXSTRUCTS];
static int st_name[MAXSTRUCTS], st_done[MAXSTRUCTS], st_union[MAXSTRUCTS];
static int nstructs;
int m_name[MAXMEMBERS], m_type[MAXMEMBERS], m_off[MAXMEMBERS], m_next[MAXMEMBERS];
static int nmembers;

int g_name[MAXGLOBALS], g_type[MAXGLOBALS], g_val[MAXGLOBALS];
char g_class[MAXGLOBALS], g_static[MAXGLOBALS], g_used[MAXGLOBALS];
int nglobals;

int l_name[MAXLOCALS], l_type[MAXLOCALS], l_class[MAXLOCALS], l_val[MAXLOCALS];
static int l_prev[MAXLOCALS];
int nlocals;

int frame, frame_max;           /* bytes of locals now, and the most */
int cur_func;                   /* the function being compiled, or -1 */
static int labels;

/* The parameters of the last function declarator */
static int p_name[32], p_type[32], nparams, p_knr;

/* Strings of an initializer, written after its data */
#define PENDSIZE 600
static char pend[PENDSIZE];
static int pend_len, pend_lab[40], pend_n[40], npend;

/* A line of data being written: 'b' bytes, 'w' words */
static int dl_kind, dl_count;

int new_label(void)
{
    return ++labels;
}

static int make_type(int kind, int base, int n)
{
    int i;
    for (i = 0; i < ntypes; i++)
        if (ty_kind[i] == kind && ty_base[i] == base && ty_n[i] == n)
            return i;
    if (ntypes >= MAXTYPES)
        fatal("too many types");
    ty_kind[ntypes] = kind;
    ty_base[ntypes] = base;
    ty_n[ntypes] = n;
    return ntypes++;
}

void decl_reset(void)
{
    int i;
    ntypes = 0;
    make_type(TY_VOID, 0, 0);
    make_type(TY_CHAR, 0, 0);
    make_type(TY_UCHAR, 0, 0);
    make_type(TY_INT, 0, 0);
    make_type(TY_UINT, 0, 0);
    nstructs = 0;
    nmembers = 0;
    nglobals = 0;
    nlocals = 0;
    cur_func = -1;
    labels = 0;
    for (i = 0; i < nnames; i++)
        nm_sym[i] = 0;
}

int ptr_to(int t)
{
    return make_type(TY_PTR, t, 0);
}

int array_of(int t, int n)
{
    return make_type(TY_ARRAY, t, n);
}

int tsize(int t)
{
    int k;
    k = ty_kind[t];
    if (k == TY_CHAR || k == TY_UCHAR || k == TY_VOID)
        return 1;
    if (k == TY_ARRAY)
        return ty_n[t] > 0 ? w16(ty_n[t] * tsize(ty_base[t])) : 0;
    if (k == TY_STRUCT)
        return st_size[ty_n[t]];
    return 2;
}

int is_int(int t)
{
    return t >= T_CHAR && t <= T_UINT;
}

int is_ptr(int t)
{
    return ty_kind[t] == TY_PTR;
}

int is_scalar(int t)
{
    return is_int(t) || is_ptr(t);
}

/* Unsigned for arithmetic and comparisons (char promotes to int) */
int is_unsigned(int t)
{
    return t == T_UINT || is_ptr(t);
}

/* ------------------------------------------------------------- the names */

static void add_local(int name, int type, int cls, int val)
{
    int n;
    if (nlocals >= MAXLOCALS)
        fatal("too many locals");
    n = nlocals++;
    l_name[n] = name;
    l_type[n] = type;
    l_class[n] = cls;
    l_val[n] = val;
    l_prev[n] = nm_sym[name];
    nm_sym[name] = -(n + 1);
}

void pop_locals(int to)
{
    while (nlocals > to) {
        nlocals--;
        nm_sym[l_name[nlocals]] = l_prev[nlocals];
    }
}

/* A global for name: found again, or made */
static int declare_global(int name, int type, int sc)
{
    int g, k;
    g = nm_sym[name] > 0 ? nm_sym[name] - 1 : -1;
    k = ty_kind[type];
    if (g >= 0) {
        if (g_class[g] == G_ENUM || ty_kind[g_type[g]] != k) {
            error_s("'%s' declared again as something else", name_of(name));
            return g;
        }
        if (k == TY_ARRAY && ty_n[g_type[g]] <= 0)
            g_type[g] = type;
        if (k == TY_FUNC)
            g_type[g] = type;
        if (sc == K_STATIC)
            g_static[g] = 1;
        if (g_class[g] == G_EXTERN && sc != K_EXTERN && k != TY_FUNC)
            g_class[g] = G_TENT;
        return g;
    }
    if (nglobals >= MAXGLOBALS)
        fatal("too many globals");
    g = nglobals++;
    g_name[g] = name;
    g_type[g] = type;
    if (k == TY_FUNC)
        g_class[g] = G_PROTO;
    else if (sc == K_EXTERN)
        g_class[g] = G_EXTERN;
    else
        g_class[g] = G_TENT;
    g_static[g] = sc == K_STATIC;
    g_used[g] = 0;
    g_val[g] = 0;
    nm_sym[name] = g + 1;
    return g;
}

/* A function called before it was declared: int f() */
int implicit_func(int name)
{
    int g;
    g = declare_global(name, make_type(TY_FUNC, T_INT, 0), K_EXTERN);
    return g;
}

/* ----------------------------------------------------------- structures */

static int find_tag(int name)
{
    int i;
    for (i = 0; i < nstructs; i++)
        if (st_name[i] == name)
            return i;
    return -1;
}

int find_member(int s, int name)
{
    int m;
    for (m = st_first[s]; m >= 0; m = m_next[m])
        if (m_name[m] == name)
            return m;
    return -1;
}

static int struct_spec(void)
{
    int is_union, name, s, base, t, mname, m, last, size, sc;
    is_union = tok == K_UNION;
    next();
    name = -1;
    if (tok == T_ID) {
        name = tokval;
        next();
    }
    s = name >= 0 ? find_tag(name) : -1;
    if (s < 0 || (tok == '{' && st_done[s])) {
        if (s >= 0 && tok == '{')
            error_s("struct '%s' defined twice", name_of(name));
        if (nstructs >= MAXSTRUCTS)
            fatal("too many structures");
        s = nstructs++;
        st_name[s] = name;
        st_size[s] = 0;
        st_first[s] = -1;
        st_done[s] = 0;
        st_union[s] = is_union;
    }
    if (accept('{')) {
        last = -1;
        size = 0;
        while (tok != '}' && tok != T_EOF) {
            base = base_spec(&sc);
            if (base < 0) {
                error("a member type expected");
                base = T_INT;
            }
            for (;;) {
                t = declarator(base, &mname);
                if (accept(':')) {
                    error("bit fields are not supported");
                    const_expr();
                }
                if (mname >= 0) {
                    if (find_member(s, mname) >= 0)
                        error_s("member '%s' twice", name_of(mname));
                    if (nmembers >= MAXMEMBERS)
                        fatal("too many members");
                    if (ty_kind[t] == TY_STRUCT && !st_done[ty_n[t]])
                        error("a member of a structure not yet defined");
                    m = nmembers++;
                    m_name[m] = mname;
                    m_type[m] = t;
                    m_next[m] = -1;
                    if (is_union) {
                        m_off[m] = 0;
                        if (tsize(t) > size)
                            size = tsize(t);
                    } else {
                        m_off[m] = size;
                        size = size + tsize(t);
                    }
                    if (last < 0)
                        st_first[s] = m;
                    else
                        m_next[last] = m;
                    last = m;
                }
                if (!accept(','))
                    break;
            }
            expect(';');
        }
        expect('}');
        st_size[s] = size;
        st_done[s] = 1;
    } else if (name < 0)
        error("a structure needs a name or its members");
    return make_type(TY_STRUCT, 0, s);
}

static void enum_spec(void)
{
    int name, v;
    next();
    if (tok == T_ID)
        next();
    if (!accept('{'))
        return;
    v = 0;
    while (tok == T_ID) {
        name = tokval;
        next();
        if (accept('='))
            v = const_expr();
        if (cur_func >= 0)
            add_local(name, T_INT, L_ENUM, v);
        else {
            if (nm_sym[name] > 0)
                error_s("'%s' declared again", name_of(name));
            if (nglobals >= MAXGLOBALS)
                fatal("too many globals");
            g_name[nglobals] = name;
            g_type[nglobals] = T_INT;
            g_class[nglobals] = G_ENUM;
            g_val[nglobals] = v;
            g_static[nglobals] = 0;
            g_used[nglobals] = 0;
            nm_sym[name] = ++nglobals;
        }
        v = w16(v + 1);
        if (!accept(','))
            break;
    }
    expect('}');
}

/* ---------------------------------------------------------- declarations */

int is_type_start(void)
{
    if (tok == T_ID)
        return 0;
    return tok == K_CHAR || tok == K_INT || tok == K_VOID || tok == K_UNSIGNED || tok == K_SIGNED ||
           tok == K_SHORT || tok == K_LONG || tok == K_STRUCT || tok == K_UNION || tok == K_ENUM ||
           tok == K_CONST || tok == K_VOLATILE || tok == K_STATIC || tok == K_EXTERN ||
           tok == K_AUTO || tok == K_REGISTER || tok == K_TYPEDEF || tok == K_FLOAT || tok == K_DOUBLE;
}

/* The specifiers of a declaration: its type, or -1 when there are none.
 * *sc gets the storage class keyword, or 0. */
int base_spec(int *sc)
{
    int t, uns, any, got;
    t = -1;
    uns = 0;
    any = 0;
    *sc = 0;
    for (;;) {
        got = 1;
        if (tok == K_STATIC || tok == K_EXTERN || tok == K_AUTO || tok == K_REGISTER) {
            if (*sc)
                error("two storage classes");
            *sc = tok;
            next();
        } else if (tok == K_TYPEDEF) {
            error("typedef is not supported");
            next();
        } else if (tok == K_CONST || tok == K_VOLATILE)
            next();
        else if (tok == K_UNSIGNED) {
            uns = 1;
            next();
        } else if (tok == K_SIGNED)
            next();
        else if (tok == K_SHORT) {
            next();
            if (t < 0)
                t = T_INT;
        } else if (tok == K_LONG || tok == K_FLOAT || tok == K_DOUBLE) {
            error(tok == K_LONG ? "long is not supported" : "floating point is not supported");
            next();
            t = T_INT;
        } else if (tok == K_INT) {
            next();
            if (t < 0 || t == T_INT)
                t = T_INT;
            else
                error("two types");
        } else if (tok == K_CHAR) {
            next();
            if (t >= 0)
                error("two types");
            t = T_CHAR;
        } else if (tok == K_VOID) {
            next();
            if (t >= 0)
                error("two types");
            t = T_VOID;
        } else if (tok == K_STRUCT || tok == K_UNION) {
            if (t >= 0)
                error("two types");
            t = struct_spec();
        } else if (tok == K_ENUM) {
            if (t >= 0)
                error("two types");
            enum_spec();
            t = T_INT;
        } else
            got = 0;
        if (!got)
            break;
        any = 1;
    }
    if (!any)
        return -1;
    if (t < 0)
        t = T_INT;
    if (uns) {
        if (t == T_CHAR)
            t = T_UCHAR;
        else if (t == T_INT)
            t = T_UINT;
        else
            error("unsigned with a type that has no sign");
    }
    return t;
}

static void params(void)
{
    int sc, t, name;
    nparams = 0;
    p_knr = 0;
    if (accept(')'))
        return;
    if (tok == K_VOID && peek_tok() == ')') {
        next();
        next();
        return;
    }
    if (tok == T_ID) {                  /* f(a, b) int a; char *b; { */
        p_knr = 1;
        for (;;) {
            name = ident();
            if (nparams < 32) {
                p_name[nparams] = name;
                p_type[nparams] = T_INT;
                nparams++;
            }
            if (!accept(','))
                break;
        }
        expect(')');
        return;
    }
    for (;;) {
        if (accept(P_DOTS))
            break;
        t = base_spec(&sc);
        if (t < 0) {
            error("a parameter type expected");
            t = T_INT;
        }
        t = declarator(t, &name);
        if (ty_kind[t] == TY_ARRAY)
            t = ptr_to(ty_base[t]);
        if (ty_kind[t] == TY_STRUCT)
            error("structures are passed by pointer, not by value");
        if (nparams >= 32)
            error("too many parameters");
        else {
            p_name[nparams] = name;
            p_type[nparams] = t;
            nparams++;
        }
        if (!accept(','))
            break;
    }
    expect(')');
}

/* The type made by a declarator on t; *name gets its name or -1 */
int declarator(int t, int *name)
{
    int dims[8], nd, i;
    while (accept('*')) {
        t = ptr_to(t);
        while (tok == K_CONST || tok == K_VOLATILE)
            next();
    }
    *name = -1;
    if (tok == '(' && (peek_tok() == '*' || peek_tok() == '(')) {
        error("pointers to functions are not supported");
        while (tok != ')' && tok != T_EOF && tok != ';')
            next();
        accept(')');
    }
    if (tok == T_ID) {
        *name = tokval;
        next();
    }
    nd = 0;
    for (;;) {
        if (accept('[')) {
            if (nd >= 8)
                fatal("too many dimensions");
            if (tok == ']')
                dims[nd++] = -1;
            else {
                dims[nd] = const_expr();
                if (dims[nd] <= 0) {
                    error("an array has from 1 to 32767 elements");
                    dims[nd] = 1;
                }
                nd++;
            }
            expect(']');
        } else if (tok == '(' && nd == 0) {
            next();
            params();
            if (ty_kind[t] == TY_ARRAY)
                error("a function cannot return an array");
            if (ty_kind[t] == TY_STRUCT)
                error("functions return structures by pointer, not by value");
            t = make_type(TY_FUNC, t, 0);
            break;
        } else
            break;
    }
    for (i = nd - 1; i >= 0; i--) {
        if (i > 0 && dims[i] < 0)
            error("only the first dimension can be left out");
        t = array_of(t, dims[i]);
    }
    return t;
}

/* A type name, as in casts and sizeof: -1 if there is none */
int type_name(void)
{
    int t, sc, name;
    t = base_spec(&sc);
    if (t < 0)
        return -1;
    if (sc)
        error("a storage class in a type name");
    t = declarator(t, &name);
    if (name >= 0)
        error("a name in a type name");
    return t;
}

/* --------------------------------------------------------- initializers */

static void dl_flush(void)
{
    if (dl_count)
        emit("\n");
    dl_count = 0;
}

static void dl_item(int kind, char *text)
{
    if (dl_count && (dl_kind != kind || dl_count >= 12))
        dl_flush();
    if (dl_count == 0)
        emit(kind == 'b' ? "    db " : "    dw ");
    else
        emit(", ");
    emit(text);
    dl_kind = kind;
    dl_count++;
}

static void zeros(int n)
{
    char buf[32];
    if (n <= 0)
        return;
    dl_flush();
    if (n <= 4) {
        while (n-- > 0)
            dl_item('b', "0");
        return;
    }
    sprintf(buf, "    times %d db 0\n", n);
    emit(buf);
}

/* The bytes of a string literal, as db lines, with its zero */
static void string_data(char *s, int n, int with_zero)
{
    char buf[8];
    int i, c, inq, col;
    dl_flush();
    emit("    db ");
    inq = 0;
    col = 0;
    for (i = 0; i < n; i++) {
        c = s[i] & 255;
        if (col >= 60) {
            if (inq)
                emit("'");
            emit("\n    db ");
            inq = 0;
            col = 0;
        }
        if (c >= 32 && c < 127 && c != '\'') {
            if (!inq) {
                if (col)
                    emit(", ");
                emit("'");
                inq = 1;
            }
            buf[0] = c;
            buf[1] = 0;
            emit(buf);
            col++;
        } else {
            if (inq)
                emit("'");
            inq = 0;
            if (col)
                emit(", ");
            sprintf(buf, "%d", c);
            emit(buf);
            col = col + 4;
        }
    }
    if (inq)
        emit("'");
    if (with_zero)
        emit(col ? ", 0\n" : "0\n");
    else
        emit("\n");
}

/* A string of an initializer: its label, its bytes written later */
static int pend_string(void)
{
    int n;
    if (npend >= 40 || pend_len + toklen > PENDSIZE)
        fatal("too many strings in one initializer");
    n = new_label();
    pend_lab[npend] = n;
    pend_n[npend] = toklen;
    memcpy(pend + pend_len, tokstr, toklen);
    pend_len = pend_len + toklen;
    npend++;
    return n;
}

static void flush_pending(void)
{
    int i, p;
    char buf[16];
    dl_flush();
    p = 0;
    for (i = 0; i < npend; i++) {
        sprintf(buf, ".S%d:\n", pend_lab[i]);
        emit(buf);
        string_data(pend + p, pend_n[i], 1);
        p = p + pend_n[i];
    }
    npend = 0;
    pend_len = 0;
}

/* One scalar of an initializer: a constant, or an address and a constant */
static void init_scalar(int t)
{
    int n, k, off, lab;
    char buf[80];
    if (tok == T_STR && is_ptr(t)) {
        lab = pend_string();
        next();
        while (tok == T_STR) {
            error("one string per pointer");
            next();
        }
        sprintf(buf, ".S%d-__dbase", lab);
        dl_item('w', buf);
        return;
    }
    nnodes = 0;
    n = rvalue(assign_expr());
    off = 0;
    for (;;) {                          /* &x + c, (char *)&x... */
        k = n_op[n];
        if (k == N_CAST)
            n = n_l[n];
        else if (k == N_ADD && n_op[n_r[n]] == N_NUM) {
            off = off + n_val[n_r[n]];
            n = n_l[n];
        } else if (k == N_SUB && n_op[n_r[n]] == N_NUM) {
            off = off - n_val[n_r[n]];
            n = n_l[n];
        } else
            break;
    }
    if (n_op[n] == N_NUM) {
        sprintf(buf, "%d", w16(n_val[n] + off));
        dl_item(tsize(t) == 1 ? 'b' : 'w', buf);
        return;
    }
    if (n_op[n] == N_ADDR && n_op[n_l[n]] == N_GVAR && tsize(t) == 2) {
        k = n_val[n_l[n]];
        g_used[k] = 1;
        if (ty_kind[g_type[k]] == TY_FUNC)
            error("pointers to functions are not supported");
        dl_flush();
        emit("    dw ");
        put_glabel(k);
        sprintf(buf, "%s%d-__dbase\n", off < 0 ? "" : "+", off);
        emit(off ? buf : "-__dbase\n");
        return;
    }
    error("an initializer must be a constant");
    dl_item('w', "0");
}

static int init_item(int t);

/* The elements of an aggregate; with braced 0 its braces were left out */
static int init_aggregate(int t, int braced)
{
    int n, count, s, m, done, size, et;
    if (ty_kind[t] == TY_ARRAY) {
        n = ty_n[t];
        et = ty_base[t];
        count = 0;
        while (tok != '}' && tok != T_EOF) {
            if (n > 0 && count >= n) {
                if (braced)
                    error("too many initializers");
                break;
            }
            init_item(et);
            count++;
            if (!braced && n > 0 && count >= n)
                break;
            if (!accept(','))
                break;
        }
        if (n > 0)
            zeros((n - count) * tsize(et));
        return count;
    }
    s = ty_n[t];
    done = 0;
    for (m = st_first[s]; m >= 0 && tok != '}' && tok != T_EOF; m = m_next[m]) {
        init_item(m_type[m]);
        done = done + tsize(m_type[m]);
        if (st_union[s] || m_next[m] < 0)
            break;
        if (!accept(','))
            break;
        if (!braced && tok == '}')
            break;
    }
    if (st_union[s] && braced && tok == ',' && peek_tok() != '}')
        error("a union takes one initializer");
    size = st_size[s];
    zeros(size - done);
    return 1;
}

/* Writes the data of one initializer for t: the count of elements for an
 * array whose size was left out */
static int init_item(int t)
{
    int k, n, size;
    k = ty_kind[t];
    if (k == TY_ARRAY && (ty_base[t] == T_CHAR || ty_base[t] == T_UCHAR) &&
        (tok == T_STR || (tok == '{' && peek_tok() == T_STR))) {
        k = accept('{');
        size = ty_n[t];
        n = toklen;
        string_data(tokstr, n, size < 0 || n < size);
        next();
        if (tok == T_STR)
            error("one string per array");
        if (size > 0 && n > size)
            error("the string is longer than the array");
        if (size > n)
            zeros(size - n - 1);
        if (k) {
            accept(',');
            expect('}');
        }
        return n + 1;
    }
    if (k == TY_ARRAY || k == TY_STRUCT) {
        if (accept('{')) {
            n = init_aggregate(t, 1);
            accept(',');
            expect('}');
        } else
            n = init_aggregate(t, 0);
        return n;
    }
    if (accept('{')) {
        init_scalar(t);
        accept(',');
        expect('}');
        return 1;
    }
    init_scalar(t);
    return 1;
}

/* The data of an initialized variable labeled with what was written */
static int init_data(int t)
{
    int n;
    dl_count = 0;
    npend = 0;
    pend_len = 0;
    n = init_item(t);
    dl_flush();
    flush_pending();
    if (ty_kind[t] == TY_ARRAY && ty_n[t] < 0)
        t = array_of(ty_base[t], n);
    return t;
}

/* ------------------------------------------------------------ top level */

static void knr_params(void)
{
    int sc, base, t, name, i;
    while (tok != '{' && tok != T_EOF) {
        base = base_spec(&sc);
        if (base < 0) {
            error("a parameter declaration expected");
            next();
            continue;
        }
        for (;;) {
            t = declarator(base, &name);
            if (ty_kind[t] == TY_ARRAY)
                t = ptr_to(ty_base[t]);
            for (i = 0; i < nparams; i++)
                if (p_name[i] == name)
                    break;
            if (i < nparams)
                p_type[i] = t;
            else
                error("not a parameter");
            if (!accept(','))
                break;
        }
        expect(';');
    }
}

static void function(int g)
{
    int i, off, n;
    if (g_class[g] == G_DEF)
        error_s("function '%s' defined twice", name_of(g_name[g]));
    g_class[g] = G_DEF;
    if (p_knr)
        knr_params();
    cur_func = g;
    nlocals = 0;
    off = 4;
    n = nparams;
    for (i = 0; i < n; i++) {
        if (p_name[i] < 0)
            error("a parameter without a name");
        else
            add_local(p_name[i], p_type[i], L_AUTO, off);
        off = off + 2;
    }
    frame = 0;
    frame_max = 0;
    func_body(g);
    pop_locals(0);
    cur_func = -1;
}

void top_decl(void)
{
    int base, sc, t, name, g, implicit;
    if (tok == T_ASM) {
        to_section(0);
        asm_block(asmbuf);
        section = -1;
        next();
        return;
    }
    if (accept(';'))
        return;
    base = base_spec(&sc);
    implicit = base < 0;
    if (implicit)
        base = T_INT;
    if (sc == K_AUTO || sc == K_REGISTER)
        error("auto or register outside a function");
    if (!implicit && accept(';'))
        return;
    for (;;) {
        t = declarator(base, &name);
        if (name < 0) {
            error("a name expected");
            next();
            return;
        }
        g = declare_global(name, t, sc);
        if (ty_kind[t] == TY_FUNC) {
            if (tok == '{' || (p_knr && tok != ';' && tok != ',')) {
                function(g);
                return;
            }
        } else if (accept('=')) {
            if (g_class[g] == G_DEF)
                error_s("'%s' defined twice", name_of(name));
            if (sc == K_EXTERN)
                error("extern with an initializer");
            g_class[g] = G_DEF;
            to_section(1);
            put_glabel(g);
            emit(":\n");
            g_type[g] = init_data(g_type[g]);
        } else if (implicit && g_class[g] != G_DEF)
            error("a type expected");
        if (!accept(','))
            break;
    }
    expect(';');
}

/* Skips an initializer that cannot be compiled */
static void skip_init(void)
{
    int depth;
    depth = 0;
    while (tok != T_EOF) {
        if (tok == '{')
            depth++;
        else if (tok == '}') {
            if (depth == 0)
                return;
            depth--;
        } else if ((tok == ',' || tok == ';') && depth == 0)
            return;
        next();
    }
}

/* A declaration at the start of a block */
void local_decl(void)
{
    int base, sc, t, name, g, n, size, lab, cls;
    char buf[40];
    base = base_spec(&sc);
    if (base < 0)
        base = T_INT;
    if (accept(';'))
        return;
    for (;;) {
        t = declarator(base, &name);
        if (name < 0) {
            error("a name expected");
            break;
        }
        if (ty_kind[t] == TY_FUNC || sc == K_EXTERN) {
            g = declare_global(name, t, K_EXTERN);
            add_local(name, t, L_EXTERN, g);
        } else if (sc == K_STATIC) {
            lab = new_label();
            if (accept('=')) {
                to_section(1);
                sprintf(buf, ".V%d:\n", lab);
                emit(buf);
                t = init_data(t);
                to_section(0);
                cls = -lab;
            } else {
                if (tsize(t) == 0)
                    error("the size of a static is not known");
                sprintf(buf, "%s@V%d", modname, lab);
                note_bss(buf, tsize(t));
                cls = lab;
            }
            add_local(name, t, L_STATIC, cls);
        } else {
            size = tsize(t);
            if (size == 0)
                error("the size of a local is not known");
            if (ty_kind[t] == TY_STRUCT && !st_done[ty_n[t]])
                error("a structure not yet defined");
            frame = frame + ((size + 1) & ~1);
            if (frame > frame_max)
                frame_max = frame;
            add_local(name, t, L_AUTO, -frame);
            if (accept('=')) {
                if (!is_scalar(t)) {
                    error("only simple locals can be initialized here; make it static");
                    skip_init();
                    if (!accept(','))
                        break;
                    continue;
                }
                nnodes = 0;
                n = node(N_LVAR, t, -1, -1, nlocals - 1);
                n = node(N_ASSIGN, t, n, convert(rvalue(assign_expr()), t), 0);
                gen_void(n);
            }
        }
        if (!accept(','))
            break;
    }
    expect(';');
}

/* What is left of a module: the tentative definitions go to .bss; what it
 * defines and needs goes to the link */
void end_module(void)
{
    int g, cls, pass;
    char buf[PATHSIZE];
    for (g = 0; g < nglobals; g++)
        if (g_class[g] == G_TENT) {
            if (tsize(g_type[g]) == 0)
                error_s("the size of '%s' is not known", name_of(g_name[g]));
            if (g_static[g])
                sprintf(buf, "%s@%s", modname, name_of(g_name[g]));
            else
                sprintf(buf, "_%s", name_of(g_name[g]));
            note_bss(buf, tsize(g_type[g]));
            g_class[g] = G_TENT;
        }
    for (pass = 0; pass < 2; pass++)            /* what it defines, then what it needs */
        for (g = 0; g < nglobals; g++) {
            cls = g_class[g];
            if (g_static[g] && cls == G_PROTO && g_used[g] && pass == 0)
                error_s("static function '%s' is not defined", name_of(g_name[g]));
            if (cls == G_ENUM || g_static[g])
                continue;
            sprintf(buf, "_%s", name_of(g_name[g]));
            if (cls == G_DEF && pass == 0)
                note_def(buf);
            else if (cls != G_DEF && cls != G_TENT && g_used[g] && pass == 1)
                note_ref(buf);
        }
}
