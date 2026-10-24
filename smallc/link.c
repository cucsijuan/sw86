/* link.c - putting a program together
 *
 * There are no object files: a module is assembler source with lines that
 * say what it defines and needs, as the compiler writes them:
 *
 *   ;#module NAME
 *   ;#def _f _g        names it defines
 *   ;#ref _printf      names it needs
 *   ;#bss _buf 512     uninitialized data: placed by the link
 *   ;#weak __flsall    a function that may be missing: then it is a RET
 *
 * A library is modules one after the other. The program is one source:
 * the start-up module, the modules given, the library modules they need
 * (and the ones those need), and an end that places the .bss. Then ASM
 * makes it into the .COM or the .EXE.
 */
#include "smallc.h"

#define MAXLMODS    80
#define MAXLNAMES   600
#define MAXBSS      250

static int lm_name[MAXLMODS], lm_lib[MAXLMODS], lm_first[MAXLMODS], lm_ndef[MAXLMODS], lm_nref[MAXLMODS];
static int lm_sel[MAXLMODS];
static int nlmods;
static int ln_pool[MAXLNAMES], nln;

static int bss_name[MAXBSS], bss_size[MAXBSS], nbss;

static char line[LINESIZE];
static int user_module;         /* the names noted belong to a module given */
static int start_module = -1;

/* Reads a line without its end: its length, or -1 at the end of the file */
static int get_line(FILE *f)
{
    int c, n;
    n = 0;
    c = getc(f);
    if (c == EOF)
        return -1;
    while (c != EOF && c != '\n') {
        if (c != '\r' && n < LINESIZE - 1)
            line[n++] = c;
        c = getc(f);
    }
    line[n] = 0;
    return n;
}

/* The next word of s at *pos: its name, or -1 */
static int word(int *pos)
{
    int p, s;
    p = *pos;
    while (line[p] == ' ' || line[p] == '\t')
        p++;
    if (line[p] == 0) {
        *pos = p;
        return -1;
    }
    s = p;
    while (line[p] && line[p] != ' ' && line[p] != '\t')
        p++;
    *pos = p;
    return intern_n(line + s, p - s);
}

static int number_at(int *pos)
{
    int p, v;
    p = *pos;
    while (line[p] == ' ')
        p++;
    v = 0;
    while (line[p] >= '0' && line[p] <= '9')
        v = w16(v * 10 + line[p++] - '0');
    *pos = p;
    return v;
}

static void def_name(int id)
{
    if (user_module && (nm_link[id] & LK_USER))
        error_s("%s is defined in two modules", name_of(id));
    nm_link[id] = nm_link[id] | LK_DEF;
    if (user_module)
        nm_link[id] = nm_link[id] | LK_USER;
}

void note_def(char *name)
{
    int id;
    id = intern(name);
    def_name(id);
    fprintf(out, ";#def %s\n", name);
}

void note_ref(char *name)
{
    int id;
    id = intern(name);
    nm_link[id] = nm_link[id] | LK_REF;
    fprintf(out, ";#ref %s\n", name);
}

static void add_bss(int id, int size)
{
    int i;
    for (i = 0; i < nbss; i++)
        if (bss_name[i] == id) {        /* int x; in two modules: one x */
            if (size > bss_size[i])
                bss_size[i] = size;
            return;
        }
    if (nbss >= MAXBSS)
        fatal("too many variables in .bss");
    bss_name[nbss] = id;
    bss_size[nbss] = size;
    nbss++;
    nm_link[id] = nm_link[id] | LK_DEF;
}

void note_bss(char *name, int size)
{
    add_bss(intern(name), size);
    fprintf(out, ";#bss %s %d\n", name, size);
}

/* The ;# line in line: what it says goes to the link */
static void link_line(void)
{
    int pos, id;
    pos = 2;
    if (!strncmp(line + 2, "def", 3) && (line[5] == ' ' || line[5] == 0)) {
        pos = 5;
        while ((id = word(&pos)) >= 0)
            def_name(id);
    } else if (!strncmp(line + 2, "ref", 3)) {
        pos = 5;
        while ((id = word(&pos)) >= 0)
            nm_link[id] = nm_link[id] | LK_REF;
    } else if (!strncmp(line + 2, "bss", 3)) {
        pos = 5;
        id = word(&pos);
        if (id >= 0)
            add_bss(id, number_at(&pos));
    } else if (!strncmp(line + 2, "weak", 4)) {
        pos = 6;
        while ((id = word(&pos)) >= 0)
            nm_link[id] = nm_link[id] | LK_WEAK;
    }
}

/* Copies an assembler module (or several) given on the command line */
void copy_module(char *name)
{
    FILE *f;
    f = fopen(name, "r");
    if (!f) {
        error_s("cannot open %s", name);
        return;
    }
    user_module = 1;
    section = -1;
    emit("section .text\n");
    while (get_line(f) >= 0) {
        if (line[0] == ';' && line[1] == '#')
            link_line();
        emit(line);
        emit("\n");
    }
    fclose(f);
    section = -1;
}

/* A #asm block: written, and its ;# lines go to the link */
void asm_block(char *text)
{
    int n;
    user_module = 1;
    while (*text) {
        n = 0;
        while (text[n] && text[n] != '\n' && n < LINESIZE - 1) {
            line[n] = text[n];
            n++;
        }
        line[n] = 0;
        text = text + n;
        if (*text == '\n')
            text++;
        if (line[0] == ';' && line[1] == '#')
            link_line();
        emit(line);
        emit("\n");
    }
}

/* Copies an assembler module into a library, without its comments
 * (except the ;# lines) and empty lines: ASM has less to read */
void copy_text(char *name)
{
    FILE *f;
    int i, q, n;
    f = fopen(name, "r");
    if (!f) {
        error_s("cannot open %s", name);
        return;
    }
    while (get_line(f) >= 0) {
        if (line[0] != ';' || line[1] != '#') {
            q = 0;
            for (i = 0; line[i]; i++) {
                if (q) {
                    if (line[i] == q)
                        q = 0;
                } else if (line[i] == '\'' || line[i] == '"')
                    q = line[i];
                else if (line[i] == ';')
                    break;
            }
            n = i;
            while (n > 0 && (line[n - 1] == ' ' || line[n - 1] == '\t'))
                n--;
            line[n] = 0;
            if (n == 0)
                continue;
        }
        emit(line);
        emit("\n");
    }
    fclose(f);
}

/* The modules of a library, with what each defines and needs. The
 * start-up module is copied on the way: it comes first in the program. */
void index_library(char *name, int lib)
{
    FILE *f;
    int m, pos, id, isdef, start, copying;
    f = fopen(name, "r");
    if (!f) {
        error_s("cannot open the library %s", name);
        return;
    }
    start = intern(exe_mode ? "C0EXE" : "C0COM");
    m = -1;
    copying = 0;
    while (get_line(f) >= 0) {
        if (line[0] != ';' || line[1] != '#') {
            if (copying) {
                emit(line);
                emit("\n");
            }
            continue;
        }
        if (!strncmp(line + 2, "module", 6)) {
            if (nlmods >= MAXLMODS)
                fatal("too many library modules");
            m = nlmods++;
            pos = 8;
            lm_name[m] = word(&pos);
            lm_lib[m] = lib;
            lm_first[m] = nln;
            lm_ndef[m] = 0;
            lm_nref[m] = 0;
            lm_sel[m] = 0;
            copying = lm_name[m] == start && start_module < 0;
            if (copying) {
                start_module = m;
                emit("section .text\n");
            }
            continue;
        }
        if (copying && (!strncmp(line + 2, "bss", 3) || !strncmp(line + 2, "weak", 4))) {
            user_module = 0;
            link_line();
        }
        isdef = !strncmp(line + 2, "def ", 4) || !strncmp(line + 2, "bss ", 4);
        if (m < 0 || (!isdef && strncmp(line + 2, "ref ", 4)))
            continue;
        if (line[2] == 'b') {                   /* ;#bss name size defines name */
            for (pos = 5; line[pos] == ' '; pos++)
                ;
            while (line[pos] && line[pos] != ' ')
                pos++;
            line[pos] = 0;
        }
        if (isdef && lm_nref[m])
            fatal("a library module has ;#def after ;#ref");
        pos = 5;
        while ((id = word(&pos)) >= 0) {
            if (nln >= MAXLNAMES)
                fatal("library too big");
            ln_pool[nln++] = id;
            if (isdef)
                lm_ndef[m]++;
            else
                lm_nref[m]++;
        }
    }
    fclose(f);
    section = -1;
}

static void select_module(int m)
{
    int i, id;
    lm_sel[m] = 1;
    for (i = 0; i < lm_ndef[m] + lm_nref[m]; i++) {
        id = ln_pool[lm_first[m] + i];
        if (i < lm_ndef[m])
            nm_link[id] = nm_link[id] | LK_DEF;
        else
            nm_link[id] = nm_link[id] | LK_REF;
    }
}

/* Copies the library modules chosen */
static void copy_library(char *name, int lib)
{
    FILE *f;
    int m, on, pos, id;
    f = fopen(name, "r");
    if (!f)
        return;
    on = 0;
    while (get_line(f) >= 0) {
        if (line[0] == ';' && line[1] == '#' && !strncmp(line + 2, "module", 6)) {
            pos = 8;
            id = word(&pos);
            on = 0;
            for (m = 0; m < nlmods; m++)
                if (lm_name[m] == id && lm_lib[m] == lib)
                    break;
            if (m < nlmods) {
                on = lm_sel[m] == 1;
                if (on) {
                    lm_sel[m] = 2;
                    section = -1;
                    emit("section .text\n");
                }
            }
        }
        if (!on)
            continue;
        if (line[0] == ';' && line[1] == '#') {
            if (!strncmp(line + 2, "bss", 3) || !strncmp(line + 2, "weak", 4))
                link_line();
            continue;
        }
        emit(line);
        emit("\n");
    }
    fclose(f);
    section = -1;
}

/* The start-up module, copied while indexing: what it needs */
void start_program(void)
{
    if (start_module < 0) {
        error_s("no %s start-up module in the libraries", exe_mode ? "C0EXE" : "C0COM");
        return;
    }
    user_module = 0;
    select_module(start_module);
    lm_sel[start_module] = 2;
    user_module = 1;
}

/* The library modules the program needs, the .bss and the end */
int link_program(char **libs, int nlibs)
{
    int m, i, id, changed, size, missing;
    unsigned off;
    char buf[PATHSIZE + 40];
    user_module = 0;
    do {
        changed = 0;
        for (m = 0; m < nlmods; m++) {
            if (lm_sel[m])
                continue;
            for (i = 0; i < lm_ndef[m]; i++) {
                id = ln_pool[lm_first[m] + i];
                if ((nm_link[id] & (LK_REF | LK_DEF)) == LK_REF)
                    break;
            }
            if (i < lm_ndef[m]) {
                select_module(m);
                changed = 1;
            }
        }
    } while (changed);
    for (i = 0; i < nlibs; i++)
        copy_library(libs[i], i);
    missing = 0;
    for (id = 0; id < nnames; id++)
        if ((nm_link[id] & (LK_REF | LK_DEF)) == LK_REF) {
            if (name_of(id)[0] == '_')
                printf("SMALLC: '%s' is not defined anywhere\n", name_of(id) + 1);
            else
                printf("SMALLC: %s is not defined anywhere\n", name_of(id));
            missing++;
        }
    if (missing)
        return 0;
    emit("section .text\n");
    for (id = 0; id < nnames; id++)
        if ((nm_link[id] & (LK_WEAK | LK_DEF)) == LK_WEAK) {
            emit(name_of(id));
            emit(":\n    ret\n");
        }
    if (exe_mode)
        emit("    times (16 - ($ - __image) % 16) % 16 db 0\n");
    emit("section .data\n    times ($ - $$) & 1 db 0\n__dend:\n");
    off = 0;
    for (i = 0; i < nbss; i++) {
        size = bss_size[i];
        if (nm_link[bss_name[i]] & LK_USER)
            continue;                           /* int x; and int x = 1; elsewhere */
        if ((size & 1) == 0 && (off & 1))
            off++;
        if (off > 0xFFFFu - (unsigned)size) {
            error("the variables do not fit in 64 KB");
            return 0;
        }
        sprintf(buf, "%s equ __dend+%u\n", name_of(bss_name[i]), off);
        emit(buf);
        off = off + size;
    }
    sprintf(buf, "__bend equ __dend+%u\n", off);
    emit(buf);
    return 1;
}
