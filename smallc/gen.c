/* gen.c - 8086 code for expressions
 *
 * Values are worked out in AX; CX holds the second operand of a binary
 * operator and BX the address of what a pointer points to. Operands that
 * need no code (numbers, variables, members of variables) are used where
 * they are, as in "add ax, [bp-4]"; the rest go through the stack.
 *
 * Every address of data is written as label-__dbase: in a .COM __dbase is
 * 0, in an .EXE it is where the data segment starts.
 */
#include "smallc.h"

FILE *out;
char modname[16];
int exe_mode;
int section;

/* Where an lvalue is, after gen_loc */
#define AT_BP       1           /* [bp+off] */
#define AT_GLOBAL   2           /* [global+off] */
#define AT_STATIC   3           /* [static of the function+off] */
#define AT_BX       4           /* [bx+off] */
#define AT_BXG      5           /* [bx+global+off] */
static int at, at_val, at_off;
static int pend_jmp;            /* a jmp not written yet: to .L<n>, -1 to .R */

static void gen_loc(int n);

static void flush_jmp(void)
{
    char buf[24];
    if (pend_jmp < 0)
        fputs("    jmp .R\n", out);
    else if (pend_jmp) {
        sprintf(buf, "    jmp .L%d\n", pend_jmp);
        fputs(buf, out);
    }
    pend_jmp = 0;
}

void emit(char *s)
{
    if (pend_jmp)
        flush_jmp();
    fputs(s, out);
}

void emit_d(int v)
{
    char buf[8];
    sprintf(buf, "%d", v);
    emit(buf);
}

void emit_s(char *s, int v)
{
    char buf[80];
    sprintf(buf, s, v);
    emit(buf);
}

/* jmp .L<n> (-1: .R). It is written when the next code comes, and not at
 * all if that is its label; a jump right after it is never reached. */
void emit_jump(int n)
{
    if (!pend_jmp)
        pend_jmp = n;
}

void emit_ret(void)
{
    if (pend_jmp == -1)
        pend_jmp = 0;
    emit(".R:\n");
}

void to_section(int s)
{
    if (s == section)
        return;
    section = s;
    emit(s ? "section .data\n" : "section .text\n");
}

/* The label of a global */
void put_glabel(int g)
{
    if (g_static[g]) {
        emit(modname);
        emit("@");
    } else
        emit("_");
    emit(name_of(g_name[g]));
}

static void put_static(int v)
{
    if (v < 0)
        emit_s(".V%d", -v);
    else {
        emit(modname);
        emit_s("@V%d", v);
    }
}

static void put_off(int off)
{
    if (off > 0)
        emit_s("+%d", off);
    else if (off < 0)
        emit_d(off);
}

/* The bytes of a string as db lines (after its label) */
void emit_string(char *s, int n, int with_zero)
{
    char buf[8];
    int i, c, inq, col;
    inq = 0;
    col = 0;
    for (i = 0; i < n; i++) {
        c = s[i] & 255;
        if (col == 0)
            emit("    db ");
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
            emit_d(c);
            col = col + 4;
        }
        if (col >= 60) {
            if (inq)
                emit("'");
            emit("\n");
            inq = 0;
            col = 0;
        }
    }
    if (inq)
        emit("'");
    if (with_zero)
        emit(col ? ", 0\n" : "    db 0\n");
    else if (col)
        emit("\n");
}

void emit_label(int n)
{
    if (pend_jmp == n)
        pend_jmp = 0;
    emit_s(".L%d:\n", n);
}

static void jump(int n)
{
    emit_jump(n);
}

/* ------------------------------------------------------------ locations */

static void put_loc(void)
{
    emit("[");
    if (at == AT_BP)
        emit("bp");
    else if (at == AT_GLOBAL || at == AT_STATIC) {
        if (at == AT_GLOBAL)
            put_glabel(at_val);
        else
            put_static(at_val);
        put_off(at_off);
        emit("-__dbase]");
        return;
    } else if (at == AT_BX)
        emit("bx");
    else {
        emit("bx+");
        put_glabel(at_val);
        put_off(at_off);
        emit("-__dbase]");
        return;
    }
    put_off(at_off);
    emit("]");
}

/* l found (BX), then the simple r in AX: r must not lose where l is */
static void loc_then(int l, int r)
{
    int a, v, o;
    gen_loc(l);
    a = at;
    v = at_val;
    o = at_off;
    gen(r);
    at = a;
    at_val = v;
    at_off = o;
}

static void put_size(int t)
{
    emit(tsize(t) == 1 ? "byte " : "word ");
}

/* A word seen as another word: the same node for the code */
static int uncast(int n)
{
    while (n_op[n] == N_CAST && n_x[n] == 1)
        n = n_l[n];
    return n;
}

/* An lvalue found without code: a variable, or a member of one */
static int is_var(int n)
{
    int op, a;
    n = uncast(n);
    op = n_op[n];
    if (op == N_LVAR)
        return 1;
    if (op == N_GVAR)
        return ty_kind[n_type[n]] != TY_FUNC;
    if (op != N_DEREF)
        return 0;
    a = uncast(n_l[n]);
    if (n_op[a] == N_ADD && n_op[n_r[a]] == N_NUM)
        a = uncast(n_l[a]);
    return n_op[a] == N_ADDR;
}

/* A word operand found without code: a number or a variable */
static int is_direct(int n)
{
    n = uncast(n);
    if (n_op[n] == N_NUM)
        return 1;
    return is_var(n) && is_scalar(n_type[n]) && tsize(n_type[n]) == 2;
}

/* Loaded into AX without touching BX, CX or DX */
static int is_simple(int n)
{
    int op;
    n = uncast(n);
    op = n_op[n];
    if (op == N_NUM || op == N_STR || op == N_ADDR)
        return 1;
    return is_var(n) && is_scalar(n_type[n]);
}

/* An lvalue whose address needs at most "mov bx, [pointer]" */
static int is_bxloc(int n)
{
    int a;
    if (is_var(n))
        return 1;
    n = uncast(n);
    if (n_op[n] != N_DEREF)
        return 0;
    a = uncast(n_l[n]);
    if (n_op[a] == N_ADD && n_op[n_r[a]] == N_NUM)
        a = uncast(n_l[a]);
    return is_direct(a) && n_op[a] != N_NUM;
}

/* Loaded into AX touching only BX */
static int is_easy(int n)
{
    return is_simple(n) || (is_bxloc(n) && is_scalar(n_type[n]));
}

/* A word operand: a number, or a word found with at most mov bx */
static int is_wdirect(int n)
{
    if (n_op[n] == N_NUM)
        return 1;
    return is_bxloc(n) && is_scalar(n_type[n]) && tsize(n_type[n]) == 2;
}

static void var_loc(int n)
{
    int l;
    if (n_op[n] == N_LVAR) {
        l = n_val[n];
        if (l_class[l] == L_STATIC) {
            at = AT_STATIC;
            at_val = l_val[l];
        } else {
            at = AT_BP;
            at_val = 0;
        }
        at_off = l_class[l] == L_STATIC ? 0 : l_val[l];
        return;
    }
    at = AT_GLOBAL;
    at_val = n_val[n];
    at_off = 0;
    g_used[at_val] = 1;
}

/* Finds the lvalue n, with code that puts its address in BX if needed */
static void gen_loc(int n)
{
    int a, off;
    n = uncast(n);
    if (n_op[n] == N_LVAR || n_op[n] == N_GVAR) {
        var_loc(n);
        return;
    }
    a = uncast(n_l[n]);
    off = 0;
    if (n_op[a] == N_ADD && n_op[n_r[a]] == N_NUM) {
        off = n_val[n_r[a]];
        a = uncast(n_l[a]);
    }
    if (n_op[a] == N_ADDR) {
        var_loc(n_l[a]);
        at_off = w16(at_off + off);
        return;
    }
    if (n_op[a] == N_ADD && n_op[uncast(n_l[a])] == N_ADDR && n_op[n_l[uncast(n_l[a])]] == N_GVAR) {
        gen(n_r[a]);                    /* global[i] */
        emit("    mov bx, ax\n");
        at = AT_BXG;
        at_val = n_val[n_l[uncast(n_l[a])]];
        g_used[at_val] = 1;
        at_off = off;
        return;
    }
    if (is_direct(a) && n_op[a] != N_NUM) {
        gen_loc(a);                     /* *p */
        emit("    mov bx, ");
        put_loc();
        emit("\n");
    } else {
        gen(a);
        emit("    mov bx, ax\n");
    }
    at = AT_BX;
    at_val = 0;
    at_off = off;
}

static void load(int t)
{
    int k;
    k = ty_kind[t];
    if (k == TY_ARRAY || k == TY_STRUCT) {
        emit("    lea ax, ");
        put_loc();
        emit("\n");
        return;
    }
    if (tsize(t) == 1) {
        emit("    mov al, ");
        put_loc();
        emit(t == T_UCHAR ? "\n    xor ah, ah\n" : "\n    cbw\n");
        return;
    }
    emit("    mov ax, ");
    put_loc();
    emit("\n");
}

static void store(int t)
{
    emit("    mov ");
    put_loc();
    emit(tsize(t) == 1 ? ", al\n" : ", ax\n");
}

/* AX as a value of type t (after an int was stored in a char) */
static void narrow(int t)
{
    if (t == T_CHAR)
        emit("    cbw\n");
    else if (t == T_UCHAR)
        emit("    xor ah, ah\n");
}

/* The code that finds an operand (mov bx), before its instruction */
static void prep_direct(int n)
{
    if (n_op[n] != N_NUM)
        gen_loc(n);
}

static void put_direct(int n)
{
    if (n_op[n] == N_NUM)
        emit_d(n_val[n]);
    else
        put_loc();
}

/* l in AX and r in CX */
static void gen_pair(int l, int r)
{
    if (is_easy(l)) {
        gen(r);
        emit("    mov cx, ax\n");
        gen(l);
    } else if (is_easy(r)) {
        gen(l);
        emit("    mov cx, ax\n");
        gen(r);
        emit("    xchg ax, cx\n");
    } else {
        gen(l);
        emit("    push ax\n");
        gen(r);
        emit("    mov cx, ax\n");
        emit("    pop ax\n");
    }
}

static int log_2(int v)
{
    int i;
    for (i = 0; i < 15; i++)
        if (v == (1 << i))
            return i;
    return -1;
}

static void shift_ax(char *ins, int count)
{
    if (count <= 3) {
        while (count-- > 0) {
            emit("    ");
            emit(ins);
            emit(" ax, 1\n");
        }
        return;
    }
    emit_s("    mov cl, %d\n", count);
    emit("    ");
    emit(ins);
    emit(" ax, cl\n");
}

/* AX = AX op CX (or op the number v when num) */
static void arith_op(int op, int uns, int num, int v)
{
    int k;
    if (op == N_MUL) {
        if (num) {
            k = log_2(v);
            if (k >= 0 && k <= 3) {
                shift_ax("shl", k);
                return;
            }
            emit_s("    mov cx, %d\n", v);
        }
        emit("    imul cx\n");
        return;
    }
    if (op == N_DIV || op == N_MOD) {
        if (num) {
            k = log_2(v);
            if (uns && k >= 0) {
                if (op == N_DIV)
                    shift_ax("shr", k);
                else
                    emit_s("    and ax, %d\n", v - 1);
                return;
            }
            emit_s("    mov cx, %d\n", v);
        }
        emit(uns ? "    xor dx, dx\n    div cx\n" : "    cwd\n    idiv cx\n");
        if (op == N_MOD)
            emit("    mov ax, dx\n");
        return;
    }
    if (op == N_SHL || op == N_SHR) {
        if (num) {
            shift_ax(op == N_SHL ? "shl" : uns ? "shr" : "sar", v & 15);
            return;
        }
        emit("    ");
        emit(op == N_SHL ? "shl" : uns ? "shr" : "sar");
        emit(" ax, cl\n");
        return;
    }
}

static char *op_ins(int op)
{
    if (op == N_ADD) return "add";
    if (op == N_SUB) return "sub";
    if (op == N_AND) return "and";
    if (op == N_OR) return "or";
    return "xor";
}

static void gen_binary(int n)
{
    int op, l, r, uns, v;
    op = n_op[n];
    l = n_l[n];
    r = n_r[n];
    uns = is_unsigned(n_type[n]);
    if (op == N_ADD || op == N_SUB || op == N_AND || op == N_OR || op == N_XOR) {
        if (n_op[r] == N_NUM) {
            gen(l);
            v = n_val[r];
            if (op == N_SUB) {
                op = N_ADD;
                v = w16(-v);
            }
            if (op == N_ADD && v >= -2 && v <= 2) {
                while (v > 0) {
                    emit("    inc ax\n");
                    v--;
                }
                while (v < 0) {
                    emit("    dec ax\n");
                    v++;
                }
                return;
            }
            emit("    ");
            emit(op_ins(op));
            emit_s(" ax, %d\n", v);
            return;
        }
        if (is_wdirect(r)) {
            gen(l);
            prep_direct(r);
            emit("    ");
            emit(op_ins(op));
            emit(" ax, ");
            put_direct(r);
            emit("\n");
            return;
        }
        gen_pair(l, r);
        emit("    ");
        emit(op_ins(op));
        emit(" ax, cx\n");
        return;
    }
    if (n_op[r] == N_NUM) {
        gen(l);
        arith_op(op, uns, 1, n_val[r]);
        return;
    }
    gen_pair(l, r);
    arith_op(op, uns, 0, 0);
}

/* ---------------------------------------------------------- conditions */

static char *jcc(int op, int uns, int sense)
{
    if (!sense) {
        if (op == N_EQ) op = N_NE;
        else if (op == N_NE) op = N_EQ;
        else if (op == N_LT) op = N_GE;
        else if (op == N_GE) op = N_LT;
        else if (op == N_GT) op = N_LE;
        else op = N_GT;
    }
    if (op == N_EQ) return "je";
    if (op == N_NE) return "jne";
    if (uns) {
        if (op == N_LT) return "jb";
        if (op == N_LE) return "jbe";
        if (op == N_GT) return "ja";
        return "jae";
    }
    if (op == N_LT) return "jl";
    if (op == N_LE) return "jle";
    if (op == N_GT) return "jg";
    return "jge";
}

/* A conditional jump to .Ln that reaches anywhere: with NEAR the
 * assembler makes it short when it can */
static void far_jcc(char *j, int lab)
{
    emit("    ");
    emit(j);
    emit_s(" near .L%d\n", lab);
}

/* Compares the operands of n, for the flags */
static int gen_cmp(int n)
{
    int l, r, t, v;
    l = n_l[n];
    r = n_r[n];
    t = n_type[l];
    v = n_val[r];
    if (n_op[r] == N_NUM && (n_op[l] == N_LVAR || n_op[l] == N_GVAR || n_op[l] == N_DEREF) && is_scalar(t) &&
        (tsize(t) == 2 || (t == T_CHAR && v >= -128 && v <= 127) || (t == T_UCHAR && v >= 0 && v <= 255))) {
        gen_loc(l);
        emit("    cmp ");
        put_size(t);
        put_loc();
        emit_s(", %d\n", v);
        if (tsize(t) == 1)
            return t == T_UCHAR;
        return is_unsigned(t) || is_unsigned(n_type[r]);
    }
    if (n_op[r] == N_NUM && n_val[r] == 0) {
        gen(l);
        emit("    or ax, ax\n");
    } else if (is_wdirect(r)) {
        gen(l);
        prep_direct(r);
        emit("    cmp ax, ");
        put_direct(r);
        emit("\n");
    } else {
        gen_pair(l, r);
        emit("    cmp ax, cx\n");
    }
    return is_unsigned(n_type[l]) || is_unsigned(n_type[r]);
}

/* Jumps to .Llab when n is true (sense 1) or false (sense 0) */
void gen_cond(int n, int lab, int sense)
{
    int op, skip, uns;
    op = n_op[n];
    if (op == N_NUM) {
        if ((n_val[n] != 0) == sense)
            jump(lab);
        return;
    }
    if (op == N_NOT) {
        gen_cond(n_l[n], lab, !sense);
        return;
    }
    if (op == N_LAND || op == N_LOR) {
        if ((op == N_LAND) != sense) {
            gen_cond(n_l[n], lab, sense);
            gen_cond(n_r[n], lab, sense);
        } else {
            skip = new_label();
            gen_cond(n_l[n], skip, !sense);
            gen_cond(n_r[n], lab, sense);
            emit_label(skip);
        }
        return;
    }
    if (op >= N_EQ) {
        uns = gen_cmp(n);
        far_jcc(jcc(op, uns, sense), lab);
        return;
    }
    if (op == N_AND && n_op[n_r[n]] == N_NUM) {
        gen(n_l[n]);
        emit_s("    test ax, %d\n", n_val[n_r[n]]);
    } else if ((op == N_LVAR || op == N_GVAR || op == N_DEREF) && is_scalar(n_type[n])) {
        gen_loc(n);
        emit("    cmp ");
        put_size(n_type[n]);
        put_loc();
        emit(", 0\n");
    } else {
        gen(n);
        emit("    or ax, ax\n");
    }
    far_jcc(sense ? "jne" : "je", lab);
}

/* -------------------------------------------------------- assignments */

static void gen_assign(int n, int want)
{
    int l, r, t, size;
    l = n_l[n];
    r = n_r[n];
    t = n_type[n];
    if (ty_kind[t] == TY_STRUCT) {
        size = tsize(t);
        emit("    push si\n    push di\n");
        gen(r);
        emit("    push ax\n");
        gen(l);
        emit("    mov di, ax\n    pop si\n");
        emit_s("    mov cx, %d\n    rep movsb\n", size);
        emit("    pop di\n    pop si\n");
        return;
    }
    if (n_op[r] == N_NUM && !want) {
        gen_loc(l);
        emit("    mov ");
        put_size(t);
        put_loc();
        emit_s(", %d\n", n_val[r]);
        return;
    }
    if (is_bxloc(l) || is_simple(r)) {
        if (is_bxloc(l)) {
            gen(r);
            gen_loc(l);
        } else
            loc_then(l, r);
    } else {
        gen(r);
        emit("    push ax\n");
        gen_loc(l);
        emit("    pop ax\n");
    }
    store(t);
    if (want && n_type[r] != t)
        narrow(t);
}

static void gen_asgop(int n, int want)
{
    int l, r, t, op, uns, v;
    l = n_l[n];
    r = n_r[n];
    t = n_type[n];
    op = n_val[n];
    if (op == N_ADD || op == N_SUB || op == N_AND || op == N_OR || op == N_XOR) {
        if (n_op[r] == N_NUM) {
            gen_loc(l);
            v = n_val[r];
            if ((op == N_ADD || op == N_SUB) && (v == 1 || v == -1)) {
                emit(((op == N_ADD) == (v == 1)) ? "    inc " : "    dec ");
                put_size(t);
                put_loc();
                emit("\n");
            } else {
                emit("    ");
                emit(op_ins(op));
                emit(" ");
                put_size(t);
                put_loc();
                emit_s(", %d\n", v);
            }
        } else {
            if (is_bxloc(l)) {
                gen(r);
                gen_loc(l);
            } else if (is_simple(r))
                loc_then(l, r);
            else {
                gen(r);
                emit("    push ax\n");
                gen_loc(l);
                emit("    pop ax\n");
            }
            emit("    ");
            emit(op_ins(op));
            emit(" ");
            put_loc();
            emit(tsize(t) == 1 ? ", al\n" : ", ax\n");
        }
        if (want)
            load(t);
        return;
    }
    uns = is_unsigned(t) || is_unsigned(n_type[r]);
    if (n_op[r] == N_NUM) {
        gen_loc(l);
        load(t);
        arith_op(op, uns, 1, n_val[r]);
    } else {
        if (is_var(l) && is_simple(r)) {
            gen(r);
            emit("    mov cx, ax\n");
            gen_loc(l);
        } else {
            gen(r);
            emit("    push ax\n");
            gen_loc(l);
            emit("    pop cx\n");
        }
        load(t);
        arith_op(op, uns, 0, 0);
    }
    store(t);
    if (want)
        narrow(t);
}

static void gen_inc(int n, int want, int post)
{
    int l, t, d;
    l = n_l[n];
    t = n_type[n];
    d = n_val[n];
    gen_loc(l);
    if (want && post)
        load(t);
    if (d == 1 || d == -1) {
        emit(d == 1 ? "    inc " : "    dec ");
        put_size(t);
        put_loc();
        emit("\n");
    } else {
        emit("    add ");
        put_size(t);
        put_loc();
        emit_s(", %d\n", d);
    }
    if (want && !post)
        load(t);
}

/* ---------------------------------------------------------------- calls */

static void push_args(int a)
{
    int e;
    if (a < 0)
        return;
    push_args(n_r[a]);
    e = n_l[a];
    if (is_direct(e) && n_op[e] != N_NUM) {
        gen_loc(e);
        emit("    push word ");
        put_loc();
        emit("\n");
        return;
    }
    gen(e);
    emit("    push ax\n");
}

static void gen_call(int n)
{
    int bytes;
    push_args(n_l[n]);
    emit("    call ");
    put_glabel(n_val[n]);
    emit("\n");
    bytes = n_x[n] * 2;
    if (bytes == 2)
        emit("    pop cx\n");
    else if (bytes == 4)
        emit("    pop cx\n    pop cx\n");
    else if (bytes)
        emit_s("    add sp, %d\n", bytes);
}

/* ---------------------------------------------------------- expressions */

/* The value of n in AX */
void gen(int n)
{
    int op, a, b, t, uns;
    op = n_op[n];
    t = n_type[n];
    if (op == N_NUM) {
        if (n_val[n] == 0)
            emit("    xor ax, ax\n");
        else
            emit_s("    mov ax, %d\n", n_val[n]);
        return;
    }
    if (op == N_STR) {
        emit_s("    mov ax, .S%d-__dbase\n", n_val[n]);
        return;
    }
    if (op == N_LVAR || op == N_GVAR || op == N_DEREF) {
        gen_loc(n);
        load(t);
        return;
    }
    if (op == N_ADDR) {
        var_loc(n_l[n]);
        if (at == AT_BP) {
            emit("    lea ax, ");
            put_loc();
        } else {
            emit("    mov ax, ");
            if (at == AT_GLOBAL)
                put_glabel(at_val);
            else
                put_static(at_val);
            emit("-__dbase");
        }
        emit("\n");
        return;
    }
    if (op == N_CALL) {
        gen_call(n);
        return;
    }
    if (op == N_ASSIGN) {
        gen_assign(n, 1);
        return;
    }
    if (op == N_ASGOP) {
        gen_asgop(n, 1);
        return;
    }
    if (op == N_PREINC || op == N_POSTINC) {
        gen_inc(n, 1, op == N_POSTINC);
        return;
    }
    if (op == N_COND) {
        a = new_label();
        b = new_label();
        gen_cond(n_l[n], a, 0);
        gen(n_r[n]);
        jump(b);
        emit_label(a);
        gen(n_x[n]);
        emit_label(b);
        return;
    }
    if (op == N_COMMA) {
        gen_void(n_l[n]);
        gen(n_r[n]);
        return;
    }
    if (op == N_CAST) {
        if (n_x[n] == 1) {
            gen(uncast(n));
            return;
        }
        gen(n_l[n]);
        if (n_type[n_l[n]] != t)
            narrow(t);
        return;
    }
    if (op == N_NEG || op == N_COM) {
        gen(n_l[n]);
        emit(op == N_NEG ? "    neg ax\n" : "    not ax\n");
        return;
    }
    if (op == N_NOT) {
        gen(n_l[n]);
        emit("    neg ax\n    sbb ax, ax\n    inc ax\n");
        return;
    }
    if (op == N_LAND || op == N_LOR) {
        a = new_label();
        gen_cond(n, a, 0);
        emit("    mov ax, 1\n    jmp short $+4\n");
        emit_label(a);
        emit("    xor ax, ax\n");
        return;
    }
    if (op >= N_EQ) {
        uns = gen_cmp(n);
        emit("    mov ax, 1\n    ");
        emit(jcc(op, uns, 1));
        emit(" short $+3\n    dec ax\n");
        return;
    }
    gen_binary(n);
}

/* n for what it does, not its value */
void gen_void(int n)
{
    int op, a, b;
    op = n_op[n];
    if (op == N_ASSIGN)
        gen_assign(n, 0);
    else if (op == N_ASGOP)
        gen_asgop(n, 0);
    else if (op == N_PREINC || op == N_POSTINC)
        gen_inc(n, 0, 0);
    else if (op == N_COMMA) {
        gen_void(n_l[n]);
        gen_void(n_r[n]);
    } else if (op == N_CAST && n_type[n] == T_VOID)
        gen_void(n_l[n]);
    else if (op == N_COND) {
        a = new_label();
        b = new_label();
        gen_cond(n_l[n], a, 0);
        gen_void(n_r[n]);
        jump(b);
        emit_label(a);
        gen_void(n_x[n]);
        emit_label(b);
    } else
        gen(n);
}
