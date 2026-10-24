/* stmt.c - statements and function bodies
 *
 * A function keeps BP as its frame: the parameters are at [bp+4] and up,
 * the locals below BP. Its frame size is only known at its end, so the
 * prologue subtracts .F, an EQU written after the body. Labels of a
 * function are local to it (.L1, .R, .Uname).
 */
#include "smallc.h"

static int brk_lab[32], cont_lab[32], nloops;
static int case_val[MAXCASES], case_lab[MAXCASES], ncases;
static int sw_active, sw_default, sw_base;
static int ret_type;
static int ul_name[64], ul_def[64], nulabels;

static void compound(void);

static int cond(void)
{
    int c;
    expect('(');
    nnodes = 0;
    c = rvalue(expr());
    if (!is_scalar(n_type[c]))
        error("a condition must be a number or a pointer");
    expect(')');
    return c;
}

static void push_loop(int b, int c)
{
    if (nloops >= 32)
        fatal("loops nested too deep");
    brk_lab[nloops] = b;
    cont_lab[nloops] = c;
    nloops++;
}

static void user_label(int name, int def)
{
    int i;
    for (i = 0; i < nulabels; i++)
        if (ul_name[i] == name)
            break;
    if (i == nulabels) {
        if (nulabels >= 64)
            fatal("too many labels");
        ul_name[i] = name;
        ul_def[i] = 0;
        nulabels++;
    }
    if (def) {
        if (ul_def[i])
            error_s("label '%s' twice", name_of(name));
        ul_def[i] = 1;
        emit(".U");
        emit(name_of(name));
        emit(":\n");
    } else {
        emit("    jmp .U");
        emit(name_of(name));
        emit("\n");
    }
}

static void jump_to(int lab)
{
    emit_jump(lab);
}

static void switch_stmt(void)
{
    int e, ld, lb, base, saved_active, saved_default, saved_base, i;
    expect('(');
    nnodes = 0;
    e = rvalue(expr());
    if (!is_int(n_type[e]))
        error("switch needs an integer");
    expect(')');
    gen(e);
    ld = new_label();
    lb = new_label();
    jump_to(ld);
    base = ncases;
    saved_active = sw_active;
    saved_default = sw_default;
    saved_base = sw_base;
    sw_base = base;
    sw_active = 1;
    sw_default = 0;
    push_loop(lb, -1);
    statement();
    nloops--;
    jump_to(lb);
    emit_label(ld);
    for (i = base; i < ncases; i++) {
        emit_s("    cmp ax, %d\n", case_val[i]);
        emit_s("    je near .L%d\n", case_lab[i]);
    }
    jump_to(sw_default ? sw_default : lb);
    emit_label(lb);
    ncases = base;
    sw_active = saved_active;
    sw_default = saved_default;
    sw_base = saved_base;
}

void statement(void)
{
    int c, la, lb, lc, li, name, i, e;
    if (tok == '{') {
        compound();
        return;
    }
    if (accept(';'))
        return;
    if (tok == T_ASM) {
        to_section(0);
        asm_block(asmbuf);
        section = -1;
        next();
        return;
    }
    if (is_type_start()) {
        error("declarations go at the start of a block");
        local_decl();
        return;
    }
    if (accept(K_IF)) {
        c = cond();
        la = new_label();
        gen_cond(c, la, 0);
        statement();
        if (accept(K_ELSE)) {
            lb = new_label();
            jump_to(lb);
            emit_label(la);
            statement();
            emit_label(lb);
        } else
            emit_label(la);
        return;
    }
    if (accept(K_WHILE)) {
        lc = new_label();
        lb = new_label();
        emit_label(lc);
        c = cond();
        gen_cond(c, lb, 0);
        push_loop(lb, lc);
        statement();
        nloops--;
        jump_to(lc);
        emit_label(lb);
        return;
    }
    if (accept(K_DO)) {
        la = new_label();
        lc = new_label();
        lb = new_label();
        emit_label(la);
        push_loop(lb, lc);
        statement();
        nloops--;
        expect(K_WHILE);
        emit_label(lc);
        c = cond();
        gen_cond(c, la, 1);
        expect(';');
        emit_label(lb);
        return;
    }
    if (accept(K_FOR)) {
        expect('(');
        nnodes = 0;
        if (tok != ';')
            gen_void(expr());
        expect(';');
        nnodes = 0;
        c = -1;
        if (tok != ';') {
            c = rvalue(expr());
            if (!is_scalar(n_type[c]))
                error("a condition must be a number or a pointer");
        }
        expect(';');
        e = -1;
        if (tok != ')')
            e = expr();
        expect(')');
        lc = new_label();
        lb = new_label();
        li = lc;
        if (e >= 0) {
            li = new_label();
            jump_to(lc);
            emit_label(li);
            gen_void(e);
        }
        emit_label(lc);
        if (c >= 0)
            gen_cond(c, lb, 0);
        push_loop(lb, li);
        statement();
        nloops--;
        jump_to(li);
        emit_label(lb);
        return;
    }
    if (accept(K_SWITCH)) {
        switch_stmt();
        return;
    }
    if (accept(K_CASE)) {
        c = const_expr();
        expect(':');
        if (!sw_active)
            error("case outside a switch");
        else {
            for (i = sw_base; i < ncases; i++)
                if (case_val[i] == c)
                    error("the same case twice");
            if (ncases >= MAXCASES)
                fatal("too many cases");
            la = new_label();
            case_val[ncases] = c;
            case_lab[ncases] = la;
            ncases++;
            emit_label(la);
        }
        statement();
        return;
    }
    if (accept(K_DEFAULT)) {
        expect(':');
        if (!sw_active)
            error("default outside a switch");
        else if (sw_default)
            error("two defaults");
        else {
            sw_default = new_label();
            emit_label(sw_default);
        }
        statement();
        return;
    }
    if (accept(K_BREAK)) {
        if (nloops == 0)
            error("break outside a loop or a switch");
        else
            jump_to(brk_lab[nloops - 1]);
        expect(';');
        return;
    }
    if (accept(K_CONTINUE)) {
        for (i = nloops - 1; i >= 0; i--)
            if (cont_lab[i] >= 0)
                break;
        if (i < 0)
            error("continue outside a loop");
        else
            jump_to(cont_lab[i]);
        expect(';');
        return;
    }
    if (accept(K_RETURN)) {
        if (tok != ';') {
            nnodes = 0;
            e = rvalue(expr());
            if (ret_type == T_VOID)
                error("a void function returns no value");
            else
                gen(convert(e, ret_type));
        }
        emit_jump(-1);
        expect(';');
        return;
    }
    if (accept(K_GOTO)) {
        name = ident();
        if (name >= 0)
            user_label(name, 0);
        expect(';');
        return;
    }
    if (tok == T_ID && peek_tok() == ':') {
        name = tokval;
        next();
        next();
        user_label(name, 1);
        statement();
        return;
    }
    nnodes = 0;
    gen_void(expr());
    expect(';');
}

static void compound(void)
{
    int saved_locals, saved_frame;
    expect('{');
    saved_locals = nlocals;
    saved_frame = frame;
    while (is_type_start())
        local_decl();
    while (tok != '}' && tok != T_EOF)
        statement();
    expect('}');
    pop_locals(saved_locals);
    frame = saved_frame;
}

void func_body(int g)
{
    int i;
    to_section(0);
    put_glabel(g);
    emit(":\n    push bp\n    mov bp, sp\n    times !!.F sub sp, .F\n");
    ret_type = ty_base[g_type[g]];
    nloops = 0;
    ncases = 0;
    sw_active = 0;
    nulabels = 0;
    compound();
    emit_ret();
    emit("    times !!.F mov sp, bp\n    pop bp\n    ret\n");
    emit_s(".F equ %d\n", frame_max);
    for (i = 0; i < nulabels; i++)
        if (!ul_def[i])
            error_s("label '%s' is not defined", name_of(ul_name[i]));
}
