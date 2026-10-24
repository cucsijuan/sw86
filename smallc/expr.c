/* expr.c - expressions, parsed into trees of nodes
 *
 * Each expression becomes a tree (the nodes of a statement are dropped
 * when it has been compiled). Types are worked out while parsing, so the
 * trees already say what is a pointer, what is unsigned and how far a
 * pointer moves; constants are folded here.
 */
#include "smallc.h"

int n_op[MAXNODES], n_type[MAXNODES], n_l[MAXNODES], n_r[MAXNODES], n_x[MAXNODES], n_val[MAXNODES];
int nnodes;

static int unary(void);
static int cond_expr(void);

int node(int op, int type, int l, int r, int val)
{
    int n;
    if (nnodes >= MAXNODES)
        fatal("expression too complex");
    n = nnodes++;
    n_op[n] = op;
    n_type[n] = type;
    n_l[n] = l;
    n_r[n] = r;
    n_x[n] = -1;
    n_val[n] = val;
    return n;
}

int num_node(int v)
{
    return node(N_NUM, T_INT, -1, -1, w16(v));
}

static int is_lvalue(int n)
{
    int op;
    op = n_op[n];
    return op == N_LVAR || op == N_GVAR || op == N_DEREF;
}

/* The address of an lvalue */
static int addr_of(int n)
{
    if (n_op[n] == N_DEREF) {
        n_type[n_l[n]] = ptr_to(n_type[n]);
        return n_l[n];
    }
    if (n_op[n] == N_LVAR || n_op[n] == N_GVAR) {
        if (ty_kind[n_type[n]] == TY_FUNC)
            error("pointers to functions are not supported");
        return node(N_ADDR, ptr_to(n_type[n]), n, -1, 0);
    }
    error("an lvalue is needed for &");
    return n;
}

/* The value of n: arrays become pointers to their first element */
int rvalue(int n)
{
    int t;
    t = n_type[n];
    if (n_op[n] == N_STR) {
        n_type[n] = ptr_to(ty_base[t]);
        return n;
    }
    if (ty_kind[t] == TY_ARRAY) {
        n = addr_of(n);
        n_type[n] = ptr_to(ty_base[t]);
    }
    return n;
}

static int deref(int n)
{
    int t;
    t = n_type[n];
    if (!is_ptr(t)) {
        error("* of something that is not a pointer");
        return node(N_DEREF, T_INT, n, -1, 0);
    }
    t = ty_base[t];
    if (t == T_VOID)
        error("* of a void pointer");
    if (n_op[n] == N_ADDR && n_type[n_l[n]] == t)
        return n_l[n];
    return node(N_DEREF, t, n, -1, 0);
}

/* The type of arithmetic on a and b */
static int arith(int a, int b)
{
    if (a == T_UINT || b == T_UINT)
        return T_UINT;
    return T_INT;
}

static int fold(int op, int a, int b, int uns)
{
    unsigned ua, ub;
    ua = a & 0xFFFF;
    ub = b & 0xFFFF;
    if (op == N_ADD) return w16(a + b);
    if (op == N_SUB) return w16(a - b);
    if (op == N_MUL) return w16(a * b);
    if (op == N_DIV || op == N_MOD) {
        if (b == 0) {
            error("division by zero");
            return 0;
        }
        if (uns)
            return w16(op == N_DIV ? ua / ub : ua % ub);
        return w16(op == N_DIV ? a / b : a % b);
    }
    if (op == N_SHL) return w16(a << (b & 15));
    if (op == N_SHR) {
        if (uns)
            return w16(ua >> (b & 15));
        return w16(a >> (b & 15));
    }
    if (op == N_AND) return a & b;
    if (op == N_OR) return a | b;
    if (op == N_XOR) return a ^ b;
    if (op == N_EQ) return a == b;
    if (op == N_NE) return a != b;
    if (uns) {
        if (op == N_LT) return ua < ub;
        if (op == N_LE) return ua <= ub;
        if (op == N_GT) return ua > ub;
        return ua >= ub;
    }
    if (op == N_LT) return a < b;
    if (op == N_LE) return a <= b;
    if (op == N_GT) return a > b;
    return a >= b;
}

/* A binary node, folded when it can be */
static int binop(int op, int type, int l, int r)
{
    int t, uns;
    if (n_op[l] == N_NUM && n_op[r] == N_NUM) {
        uns = is_unsigned(type);
        if (op >= N_EQ)
            uns = is_unsigned(n_type[l]) || is_unsigned(n_type[r]);
        return node(N_NUM, type, -1, -1, fold(op, n_val[l], n_val[r], uns));
    }
    if ((op == N_ADD || op == N_MUL || op == N_AND || op == N_OR || op == N_XOR) && n_op[l] == N_NUM) {
        t = l;
        l = r;
        r = t;
    }
    if (n_op[r] == N_NUM) {
        if ((op == N_ADD || op == N_SUB) && n_val[r] == 0 && n_type[l] == type)
            return l;
        if (op == N_MUL && n_val[r] == 1 && n_type[l] == type)
            return l;
        if ((op == N_ADD || op == N_SUB) && (n_op[l] == N_ADD || n_op[l] == N_SUB) && n_op[n_r[l]] == N_NUM) {
            t = n_op[l] == N_ADD ? n_val[n_r[l]] : -n_val[n_r[l]];
            t = op == N_ADD ? t + n_val[r] : t - n_val[r];
            n_val[n_r[l]] = w16(t);
            n_op[l] = N_ADD;
            n_type[l] = type;
            return l;
        }
    }
    return node(op, type, l, r, 0);
}

/* i scaled to the size of what pointer type t points to */
static int scale(int i, int t)
{
    int size;
    size = tsize(ty_base[t]);
    if (ty_kind[ty_base[t]] == TY_FUNC || size == 0)
        error("arithmetic on a pointer to something without a size");
    if (size == 1)
        return i;
    return binop(N_MUL, n_type[i], i, num_node(size));
}

static void need_int(int n)
{
    if (!is_int(n_type[n]))
        error("an integer is needed here");
}

static void need_scalar(int n)
{
    if (!is_scalar(n_type[n]))
        error("a number or a pointer is needed here");
}

/* l op r with the types of C */
static int binary(int op, int l, int r)
{
    int tl, tr, n;
    l = rvalue(l);
    r = rvalue(r);
    tl = n_type[l];
    tr = n_type[r];
    if (op == N_ADD) {
        if (is_ptr(tl) && is_int(tr))
            return binop(N_ADD, tl, l, scale(r, tl));
        if (is_int(tl) && is_ptr(tr))
            return binop(N_ADD, tr, r, scale(l, tr));
    }
    if (op == N_SUB) {
        if (is_ptr(tl) && is_int(tr))
            return binop(N_SUB, tl, l, scale(r, tl));
        if (is_ptr(tl) && is_ptr(tr)) {
            n = binop(N_SUB, T_INT, l, r);
            if (tsize(ty_base[tl]) > 1)
                n = binop(N_DIV, T_INT, n, num_node(tsize(ty_base[tl])));
            return n;
        }
    }
    if (op >= N_EQ) {
        need_scalar(l);
        need_scalar(r);
        return binop(op, T_INT, l, r);
    }
    if (op == N_LAND || op == N_LOR) {
        need_scalar(l);
        need_scalar(r);
        if (n_op[l] == N_NUM && n_op[r] == N_NUM)
            return num_node(op == N_LAND ? n_val[l] && n_val[r] : n_val[l] || n_val[r]);
        return node(op, T_INT, l, r, 0);
    }
    need_int(l);
    need_int(r);
    if (op == N_SHL || op == N_SHR)
        return binop(op, arith(tl, tl), l, r);
    return binop(op, arith(tl, tr), l, r);
}

/* n checked for a value of type t (assignment, argument, return) */
int convert(int n, int t)
{
    int tn;
    tn = n_type[n];
    if (ty_kind[t] == TY_STRUCT || ty_kind[tn] == TY_STRUCT) {
        if (tn != t)
            error("structures of different types");
        return n;
    }
    if (t == T_VOID)
        return n;
    if (tn == T_VOID)
        error("a void value used");
    else if (!is_scalar(tn))
        error("a value of the wrong type");
    if ((t == T_CHAR || t == T_UCHAR) && tn != t) {
        if (n_op[n] == N_NUM)
            return node(N_NUM, t, -1, -1, t == T_CHAR ? ((n_val[n] & 255) ^ 128) - 128 : n_val[n] & 255);
        return node(N_CAST, t, n, -1, 0);
    }
    return n;
}

/* --------------------------------------------------------------- parsing */

static int string_literal(void)
{
    int n, lab, len;
    char buf[16];
    lab = new_label();
    len = 0;
    if (cur_func >= 0) {
        to_section(1);
        sprintf(buf, ".S%d:\n", lab);
        emit(buf);
    }
    for (;;) {
        if (cur_func >= 0)
            emit_string(tokstr, toklen, peek_tok() != T_STR);
        len = len + toklen;
        next();
        if (tok != T_STR)
            break;
    }
    if (cur_func >= 0)
        to_section(0);
    n = node(N_STR, array_of(T_CHAR, len + 1), -1, -1, lab);
    return n;
}

static int args(int *count)
{
    int a, first, last, n;
    first = -1;
    last = -1;
    *count = 0;
    if (accept(')'))
        return -1;
    for (;;) {
        a = rvalue(assign_expr());
        if (ty_kind[n_type[a]] == TY_STRUCT)
            error("structures are passed by pointer, not by value");
        else if (n_type[a] == T_VOID)
            error("a void value used");
        n = node(N_ARG, n_type[a], a, -1, 0);
        if (last < 0)
            first = n;
        else
            n_r[last] = n;
        last = n;
        (*count)++;
        if (!accept(','))
            break;
    }
    expect(')');
    return first;
}

static int primary(void)
{
    int n, id, s, t, g;
    if (tok == T_NUM) {
        n = node(N_NUM, tokuns ? T_UINT : T_INT, -1, -1, tokval);
        next();
        return n;
    }
    if (tok == T_STR)
        return string_literal();
    if (accept('(')) {
        n = expr();
        expect(')');
        return n;
    }
    if (tok == T_ID) {
        id = tokval;
        next();
        s = nm_sym[id];
        if (s < 0) {
            s = -s - 1;
            if (l_class[s] == L_ENUM)
                return num_node(l_val[s]);
            if (l_class[s] == L_EXTERN) {
                g = l_val[s];
                return node(N_GVAR, g_type[g], -1, -1, g);
            }
            return node(N_LVAR, l_type[s], -1, -1, s);
        }
        if (s == 0) {
            if (tok != '(') {
                error_s("'%s' is not declared", name_of(id));
                return num_node(0);
            }
            s = implicit_func(id) + 1;
        }
        g = s - 1;
        if (g_class[g] == G_ENUM)
            return num_node(g_val[g]);
        t = g_type[g];
        return node(N_GVAR, t, -1, -1, g);
    }
    error("an expression expected");
    if (tok != ';' && tok != ')' && tok != '}' && tok != T_EOF)
        next();
    return num_node(0);
}

static int member(int base, int arrow)
{
    int t, name, m, s;
    name = ident();
    t = n_type[base];
    if (arrow) {
        base = rvalue(base);
        t = n_type[base];
        if (!is_ptr(t) || ty_kind[ty_base[t]] != TY_STRUCT) {
            error("-> on something that is not a pointer to a structure");
            return base;
        }
        t = ty_base[t];
    } else {
        if (ty_kind[t] != TY_STRUCT) {
            error(". on something that is not a structure");
            return base;
        }
        base = addr_of(base);
    }
    s = ty_n[t];
    m = name >= 0 ? find_member(s, name) : -1;
    if (m < 0) {
        if (name >= 0)
            error_s("no member '%s'", name_of(name));
        return node(N_DEREF, T_INT, base, -1, 0);
    }
    n_type[base] = ptr_to(m_type[m]);
    base = binop(N_ADD, ptr_to(m_type[m]), base, num_node(m_off[m]));
    return node(N_DEREF, m_type[m], base, -1, 0);
}

static int incdec(int op, int n, int up)
{
    int t, d;
    if (!is_lvalue(n) || !is_scalar(n_type[n]))
        error("++ or -- needs a variable");
    t = n_type[n];
    d = is_ptr(t) ? tsize(ty_base[t]) : 1;
    return node(op, t, n, -1, up ? d : -d);
}

static int postfix(void)
{
    int n, a, count, i;
    n = primary();
    for (;;) {
        if (accept('[')) {
            i = expr();
            expect(']');
            n = binary(N_ADD, n, i);
            n = deref(n);
        } else if (accept('(')) {
            a = args(&count);
            if (n_op[n] != N_GVAR || ty_kind[n_type[n]] != TY_FUNC) {
                error("only functions can be called");
                continue;
            }
            g_used[n_val[n]] = 1;
            i = node(N_CALL, ty_base[n_type[n]], a, -1, n_val[n]);
            n_x[i] = count;
            n = i;
        } else if (accept('.'))
            n = member(n, 0);
        else if (accept(P_ARROW))
            n = member(n, 1);
        else if (accept(P_INC))
            n = incdec(N_POSTINC, n, 1);
        else if (accept(P_DEC))
            n = incdec(N_POSTINC, n, 0);
        else
            return n;
    }
}

static int is_type_tok(int t)
{
    return t == K_CHAR || t == K_INT || t == K_VOID || t == K_UNSIGNED || t == K_SIGNED ||
           t == K_SHORT || t == K_LONG || t == K_STRUCT || t == K_UNION || t == K_ENUM ||
           t == K_CONST || t == K_VOLATILE || t == K_FLOAT || t == K_DOUBLE;
}

static int unary(void)
{
    int n, t, save;
    if (accept(P_INC))
        return incdec(N_PREINC, unary(), 1);
    if (accept(P_DEC))
        return incdec(N_PREINC, unary(), 0);
    if (accept('*'))
        return deref(rvalue(unary()));
    if (accept('&'))
        return addr_of(unary());
    if (accept('-')) {
        n = rvalue(unary());
        need_int(n);
        if (n_op[n] == N_NUM)
            return node(N_NUM, n_type[n], -1, -1, w16(-n_val[n]));
        return node(N_NEG, arith(n_type[n], n_type[n]), n, -1, 0);
    }
    if (accept('+')) {
        n = rvalue(unary());
        need_int(n);
        return n;
    }
    if (accept('~')) {
        n = rvalue(unary());
        need_int(n);
        if (n_op[n] == N_NUM)
            return node(N_NUM, n_type[n], -1, -1, w16(~n_val[n]));
        return node(N_COM, arith(n_type[n], n_type[n]), n, -1, 0);
    }
    if (accept('!')) {
        n = rvalue(unary());
        need_scalar(n);
        if (n_op[n] == N_NUM)
            return num_node(!n_val[n]);
        return node(N_NOT, T_INT, n, -1, 0);
    }
    if (accept(K_SIZEOF)) {
        if (tok == '(' && is_type_tok(peek_tok())) {
            next();
            t = type_name();
            expect(')');
        } else {
            save = nnodes;
            t = n_type[unary()];
            nnodes = save;
        }
        if (ty_kind[t] == TY_FUNC || tsize(t) == 0)
            error("sizeof of something without a size");
        return node(N_NUM, T_UINT, -1, -1, tsize(t));
    }
    if (tok == '(' && is_type_tok(peek_tok())) {
        next();
        t = type_name();
        expect(')');
        n = rvalue(unary());
        if (t == T_VOID)
            return node(N_CAST, T_VOID, n, -1, 0);
        if (!is_scalar(t) || !is_scalar(n_type[n])) {
            error("casts are between numbers and pointers");
            return n;
        }
        if (n_op[n] == N_NUM) {
            if (t == T_CHAR)
                return node(N_NUM, t, -1, -1, ((n_val[n] & 255) ^ 128) - 128);
            if (t == T_UCHAR)
                return node(N_NUM, t, -1, -1, n_val[n] & 255);
            return node(N_NUM, t, -1, -1, n_val[n]);
        }
        if (tsize(t) == 2 && tsize(n_type[n]) == 2 && (n_op[n] == N_LVAR || n_op[n] == N_GVAR ||
            n_op[n] == N_DEREF || n_op[n] == N_CALL || n_op[n] == N_ADDR || n_op[n] == N_STR)) {
            n = node(N_CAST, t, n, -1, 0);      /* a word as another word: no code */
            n_x[n] = 1;
            return n;
        }
        return node(N_CAST, t, n, -1, 0);
    }
    return postfix();
}

/* The binary operator of the token and its precedence */
static int bin_prec(int t, int *op)
{
    if (t == P_LOR) { *op = N_LOR; return 1; }
    if (t == P_LAND) { *op = N_LAND; return 2; }
    if (t == '|') { *op = N_OR; return 3; }
    if (t == '^') { *op = N_XOR; return 4; }
    if (t == '&') { *op = N_AND; return 5; }
    if (t == P_EQ) { *op = N_EQ; return 6; }
    if (t == P_NE) { *op = N_NE; return 6; }
    if (t == '<') { *op = N_LT; return 7; }
    if (t == '>') { *op = N_GT; return 7; }
    if (t == P_LE) { *op = N_LE; return 7; }
    if (t == P_GE) { *op = N_GE; return 7; }
    if (t == P_SHL) { *op = N_SHL; return 8; }
    if (t == P_SHR) { *op = N_SHR; return 8; }
    if (t == '+') { *op = N_ADD; return 9; }
    if (t == '-') { *op = N_SUB; return 9; }
    if (t == '*') { *op = N_MUL; return 10; }
    if (t == '/') { *op = N_DIV; return 10; }
    if (t == '%') { *op = N_MOD; return 10; }
    return 0;
}

static int bin_expr(int prec)
{
    int l, r, p, op;
    l = unary();
    for (;;) {
        p = bin_prec(tok, &op);
        if (p == 0 || p < prec)
            return l;
        next();
        r = bin_expr(p + 1);
        l = binary(op, l, r);
    }
}

static int cond_expr(void)
{
    int c, a, b, t, ta, tb;
    c = bin_expr(1);
    if (!accept('?'))
        return c;
    c = rvalue(c);
    need_scalar(c);
    a = rvalue(expr());
    expect(':');
    b = rvalue(cond_expr());
    ta = n_type[a];
    tb = n_type[b];
    if (is_ptr(ta))
        t = ta;
    else if (is_ptr(tb))
        t = tb;
    else if (ta == T_VOID || tb == T_VOID)
        t = T_VOID;
    else
        t = arith(ta, tb);
    if (n_op[c] == N_NUM)
        return n_val[c] ? a : b;
    t = node(N_COND, t, c, a, 0);
    n_x[t] = b;
    return t;
}

/* Two nodes that are the same variable (no code to find it) */
static int same_var(int a, int b)
{
    if (n_op[a] == N_CAST && n_x[a] == 1)
        a = n_l[a];
    if (n_op[b] == N_CAST && n_x[b] == 1)
        b = n_l[b];
    return (n_op[a] == N_LVAR || n_op[a] == N_GVAR) && n_op[a] == n_op[b] && n_val[a] == n_val[b];
}

static int asg_op(int t)
{
    if (t == P_ADDA) return N_ADD;
    if (t == P_SUBA) return N_SUB;
    if (t == P_MULA) return N_MUL;
    if (t == P_DIVA) return N_DIV;
    if (t == P_MODA) return N_MOD;
    if (t == P_SHLA) return N_SHL;
    if (t == P_SHRA) return N_SHR;
    if (t == P_ANDA) return N_AND;
    if (t == P_XORA) return N_XOR;
    if (t == P_ORA) return N_OR;
    return 0;
}

int assign_expr(void)
{
    int l, r, op, t;
    l = cond_expr();
    if (tok == '=') {
        next();
        r = rvalue(assign_expr());
        t = n_type[l];
        if (!is_lvalue(l) || ty_kind[t] == TY_ARRAY || ty_kind[t] == TY_FUNC) {
            error("an lvalue is needed for =");
            return r;
        }
        convert(r, t);
        op = n_op[r];
        if ((op == N_ADD || op == N_SUB || op == N_AND || op == N_OR || op == N_XOR) &&
            same_var(l, n_l[r]) && is_scalar(t) && tsize(n_type[r]) == tsize(t))
            return node(N_ASGOP, t, l, n_r[r], op);     /* x = x + n: x += n */
        return node(N_ASSIGN, t, l, r, 0);
    }
    op = asg_op(tok);
    if (!op)
        return l;
    next();
    r = rvalue(assign_expr());
    t = n_type[l];
    if (!is_lvalue(l) || !is_scalar(t)) {
        error("an lvalue is needed for an assignment");
        return r;
    }
    need_int(r);
    if (is_ptr(t)) {
        if (op != N_ADD && op != N_SUB)
            error("only += and -= on pointers");
        r = scale(r, t);
    } else
        need_int(l);
    return node(N_ASGOP, t, l, r, op);
}

int expr(void)
{
    int l, r;
    l = assign_expr();
    while (accept(',')) {
        r = assign_expr();
        l = node(N_COMMA, n_type[r], l, rvalue(r), 0);
    }
    return l;
}

/* A constant expression: its value */
int const_expr(void)
{
    int n, save, v;
    save = nnodes;
    n = cond_expr();
    v = 0;
    if (n_op[n] == N_NUM)
        v = n_val[n];
    else
        error("a constant is needed");
    nnodes = save;
    return v;
}
