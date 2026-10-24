/* main.c - Small-C, the C compiler for COS
 *
 *   SMALLC [options] file...
 *
 * .C files are compiled, .ASM files are taken whole and .LIB files give
 * the modules the program needs. The program is written as one assembler
 * source and ASM makes the .COM (or, with -e, the .EXE) from it.
 */
#include "smallc.h"

#ifdef __COS__
int spawn(char *path, char *args);
#define SLASH_OPTIONS 1
#else
#define SLASH_OPTIONS 0                 /* /path is a file there */
#endif

#define MAXFILES    24
#define MAXLIBS     4

static char *files[MAXFILES];
static int nfiles;
static char *libs[MAXLIBS];
static int nlibs;
static char *outname;
static int opt_c, opt_s, opt_nolib;
static char home[PATHSIZE];             /* where SMALLC is: its INCLUDE and CLIB.LIB */
static char home_inc[PATHSIZE], home_lib[PATHSIZE], home_dir[PATHSIZE];
static char *defines[16];
static char idir_buf[MAXIDIRS][PATHSIZE];
static int ndefines;

static void usage(void)
{
    printf("Small-C for COS Version 1.00\n");
    printf("usage: SMALLC [options] file...\n");
    printf("  file.C    compiled       file.ASM  taken whole\n");
    printf("  file.LIB  modules taken as the program needs them\n");
    printf("  -o name   the program (NAME.COM after the first file)\n");
    printf("  -e        an .EXE: 64 KB of code and 64 KB of data\n");
    printf("  -c        each .C to an .ASM module; with -o all in one library\n");
    printf("  -S        only the program's .ASM, without ASM\n");
    printf("  -Dname[=value]  -Idirectory  -Llibrary  -n (no CLIB.LIB)\n");
    exit(1);
}

/* The extension of a file name (after the dot), or "" */
static char *ext_of(char *name)
{
    char *p, *dot;
    dot = 0;
    for (p = name; *p; p++) {
        if (*p == '.')
            dot = p;
        else if (*p == '/' || *p == '\\' || *p == ':')
            dot = 0;
    }
    return dot ? dot + 1 : p;
}

static int ext_is(char *name, char *ext)
{
    char *e;
    int a, b;
    e = ext_of(name);
    for (;;) {
        a = *e++;
        b = *ext++;
        if (a >= 'a' && a <= 'z')
            a = a - 32;
        if (a != b)
            return 0;
        if (a == 0)
            return 1;
    }
}

/* name with its extension changed (to ext, without the dot) */
static void with_ext(char *dst, char *name, char *ext)
{
    char *e;
    int lower;
    strcpy(dst, name);
    lower = 0;
    for (e = dst; *e; e++)
        if (*e >= 'a' && *e <= 'z')
            lower = 1;
        else if (*e == '/' || *e == '\\' || *e == ':')
            lower = 0;
    e = ext_of(dst);
    if (*e == 0 && (e == dst || e[-1] != '.'))
        strcat(dst, ".");
    else
        *e = 0;
    e = dst + strlen(dst);
    strcat(dst, ext);
    if (lower)
        for (; *e; e++)
            if (*e >= 'A' && *e <= 'Z')
                *e = *e + 32;
}

/* The module name of a source: its name in capitals, letters and digits */
static void module_name(char *dst, char *path)
{
    char *p, *base;
    int n, c;
    base = path;
    for (p = path; *p; p++)
        if (*p == '/' || *p == '\\' || *p == ':')
            base = p + 1;
    n = 0;
    while (*base && *base != '.' && n < 8) {
        c = *base++;
        if (c >= 'a' && c <= 'z')
            c = c - 32;
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
            c = '_';
        dst[n++] = c;
    }
    if (n == 0)
        dst[n++] = 'M';
    dst[n] = 0;
}

/* NAME without an extension is NAME.C */
static char *with_c(char *name)
{
    char *p;
    p = malloc(strlen(name) + 3);
    if (!p)
        return name;
    strcpy(p, name);
    strcat(p, ".C");
    return p;
}

static void begin_module(char *src)
{
    char buf[PATHSIZE];
    int i, k;
    lex_reset();
    decl_reset();
    for (i = 0; i < ndefines; i++) {
        strcpy(buf, defines[i]);
        for (k = 0; buf[k] && buf[k] != '='; k++)
            ;
        if (buf[k] == '=')
            buf[k] = ' ';
        else
            strcat(buf, " 1");
        define_macro(buf);
    }
    define_macro("__COS__ 1");
    define_macro("__SMALLC__ 1");
    module_name(modname, src);
    section = -1;
    fprintf(out, ";#module %s\n", modname);
}

/* Compiles a .C file into out */
static void compile(char *src)
{
    if (!lex_open(src)) {
        error_s("cannot open %s", src);
        return;
    }
    begin_module(src);
    next();
    while (tok != T_EOF)
        top_decl();
    lex_close();
    end_module();
}

static FILE *create(char *name)
{
    FILE *f;
    f = fopen(name, "w");
    if (!f) {
        printf("SMALLC: cannot create %s\n", name);
        exit(1);
    }
    return f;
}

/* -c: modules, each to its .ASM, or all to the -o file: a library */
static void modules_only(void)
{
    char name[PATHSIZE];
    int i;
    if (outname)
        out = create(outname);
    for (i = 0; i < nfiles; i++) {
        if (ext_is(files[i], "ASM") && outname) {
            copy_text(files[i]);
            continue;
        }
        if (!ext_is(files[i], "C")) {
            printf("SMALLC: -c takes .C files, and .ASM files with -o: %s\n", files[i]);
            nerrors++;
            continue;
        }
        if (!outname) {
            with_ext(name, files[i], "ASM");
            out = create(name);
        }
        compile(files[i]);
        if (!outname)
            fclose(out);
    }
    if (outname)
        fclose(out);
}

static int assemble(char *src, char *dst)
{
    char cmd[PATHSIZE * 3];
    int r;
#ifdef __COS__
    char path[PATHSIZE];
    FILE *f;
    strcpy(path, home);
    strcat(path, "ASM.COM");
    f = fopen(path, "r");
    if (f)
        fclose(f);
    else
        strcpy(path, "\\ASM.COM");
    sprintf(cmd, "%s %s", src, dst);
    r = spawn(path, cmd);
    if (r < 0)
        printf("SMALLC: cannot run %s\n", path);
#else
    sprintf(cmd, "asm86 %s -o %s", src, dst);
    r = system(cmd);
#endif
    return r;
}

static void program(void)
{
    char asmname[PATHSIZE], prog[PATHSIZE];
    int i, ok;
    if (outname)
        strcpy(prog, outname);
    else
        with_ext(prog, files[0], exe_mode ? "EXE" : "COM");
    if (ext_is(prog, "EXE"))
        exe_mode = 1;
    if (opt_s)
        with_ext(asmname, prog, "ASM");
    else
        strcpy(asmname, "CCTEMP.ASM");
    for (i = 0; i < nfiles; i++)
        if (!strcmp(files[i], asmname)) {
            printf("SMALLC: %s would be written over\n", asmname);
            exit(1);
        }
    if (!opt_nolib)
        libs[nlibs++] = home_lib;
    out = create(asmname);
    for (i = 0; i < nlibs; i++)
        index_library(libs[i], i);
    if (nerrors) {
        fclose(out);
        remove(asmname);
        exit(1);
    }
    start_program();
    for (i = 0; i < nfiles; i++) {
        if (ext_is(files[i], "C"))
            compile(files[i]);
        else
            copy_module(files[i]);
    }
    ok = nerrors == 0 && link_program(libs, nlibs);
    fclose(out);
    if (!ok) {
        remove(asmname);
        exit(1);
    }
    if (opt_s)
        return;
    i = assemble(asmname, prog);
    remove(asmname);
    if (i != 0)
        exit(1);
}

int main(int argc, char **argv)
{
    int i, n;
    char *a;
    lex_init();
    home[0] = 0;
    if (argc > 0 && strlen(argv[0]) < PATHSIZE - 12)
        strcpy(home, argv[0]);
    n = strlen(home);
    while (n > 0 && home[n - 1] != '/' && home[n - 1] != '\\' && home[n - 1] != ':')
        n--;
    home[n] = 0;
    strcpy(home_inc, home);
    strcat(home_inc, "INCLUDE\\");
    strcpy(home_lib, home);
    strcat(home_lib, "CLIB.LIB");
    for (i = 1; i < argc; i++) {
        a = argv[i];
        if (a[0] == '-' || (a[0] == '/' && SLASH_OPTIONS)) {
            if (a[1] == 'c' || a[1] == 'C')
                opt_c = 1;
            else if (a[1] == 'S' || a[1] == 's')
                opt_s = 1;
            else if (a[1] == 'e' || a[1] == 'E')
                exe_mode = 1;
            else if (a[1] == 'n' || a[1] == 'N')
                opt_nolib = 1;
            else if (a[1] == 'o' || a[1] == 'O') {
                if (a[2])
                    outname = a + 2;
                else if (i + 1 < argc)
                    outname = argv[++i];
                else
                    usage();
            } else if ((a[1] == 'D' || a[1] == 'd') && a[2] && ndefines < 16)
                defines[ndefines++] = a + 2;
            else if ((a[1] == 'I' || a[1] == 'i') && a[2] && nidirs < MAXIDIRS - 2 && strlen(a) < PATHSIZE - 2) {
                strcpy(idir_buf[nidirs], a + 2);
                n = strlen(a + 2);
                if (a[n + 1] != '/' && a[n + 1] != '\\' && a[n + 1] != ':')
                    strcat(idir_buf[nidirs], strchr(a, '/') ? "/" : "\\");
                idirs[nidirs] = idir_buf[nidirs];
                nidirs++;
            }
            else if ((a[1] == 'L' || a[1] == 'l') && a[2] && nlibs < MAXLIBS - 1)
                libs[nlibs++] = a + 2;
            else
                usage();
        } else if (nfiles < MAXFILES)
            files[nfiles++] = ext_of(a)[0] ? a : with_c(a);
        else {
            printf("SMALLC: too many files\n");
            exit(1);
        }
    }
    if (nfiles == 0)
        usage();
    idirs[nidirs++] = home_inc;
    strcpy(home_dir, home);
    idirs[nidirs++] = home_dir;
    if (opt_c)
        modules_only();
    else
        program();
    return nerrors ? 1 : 0;
}
