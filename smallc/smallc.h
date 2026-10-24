/* smallc.h - Small-C: what the parts of the compiler share
 *
 * The compiler is written in the C it compiles: no typedef, no long, no
 * pointers to functions, declarations at the start of blocks. Numbers are
 * kept as the 8086 sees them (w16), so the compiler gives the same output
 * wherever it runs.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* Sizes of the tables */
#define MAXNAMES    1250        /* different names (identifiers, macros, link names) */
#define NAMEPOOL    10000       /* their characters */
#define HASHSIZE    256
#define MAXGLOBALS  320
#define MAXLOCALS   100
#define MAXTYPES    200
#define MAXSTRUCTS  80
#define MAXMEMBERS  200
#define MAXMACROS   250
#define MACROPOOL   3000
#define MAXNODES    250
#define MAXCASES    150
#define MAXINCLUDE  6
#define LINESIZE    512
#define XLINESIZE   768        /* a line after its macros */
#define STRSIZE     300         /* the longest string literal */
#define ASMSIZE     768        /* a #asm block */
#define MAXIDIRS    5
#ifdef __COS__
#define PATHSIZE    80
#else
#define PATHSIZE    400         /* paths are longer on other systems */
#endif

/* Tokens: characters for one-character punctuation, these for the rest */
#define T_EOF       0
#define T_ID        1
#define T_NUM       2
#define T_STR       3
#define T_ASM       4
#define P_INC       130
#define P_DEC       131
#define P_ARROW     132
#define P_SHL       133
#define P_SHR       134
#define P_LE        135
#define P_GE        136
#define P_EQ        137
#define P_NE        138
#define P_LAND      139
#define P_LOR       140
#define P_ADDA      141
#define P_SUBA      142
#define P_MULA      143
#define P_DIVA      144
#define P_MODA      145
#define P_SHLA      146
#define P_SHRA      147
#define P_ANDA      148
#define P_XORA      149
#define P_ORA       150
#define P_DOTS      151

/* Keywords: the first names interned, in this order (see lex.c) */
#define K_FIRST     160
#define K_AUTO      160
#define K_BREAK     161
#define K_CASE      162
#define K_CHAR      163
#define K_CONST     164
#define K_CONTINUE  165
#define K_DEFAULT   166
#define K_DO        167
#define K_ELSE      168
#define K_ENUM      169
#define K_EXTERN    170
#define K_FOR       171
#define K_GOTO      172
#define K_IF        173
#define K_INT       174
#define K_LONG      175
#define K_REGISTER  176
#define K_RETURN    177
#define K_SHORT     178
#define K_SIGNED    179
#define K_SIZEOF    180
#define K_STATIC    181
#define K_STRUCT    182
#define K_SWITCH    183
#define K_TYPEDEF   184
#define K_UNION     185
#define K_UNSIGNED  186
#define K_VOID      187
#define K_VOLATILE  188
#define K_WHILE     189
#define K_FLOAT     190
#define K_DOUBLE    191
#define NKEYWORDS   32

/* Types: kinds, and the first entries of the table */
#define TY_VOID     0
#define TY_CHAR     1
#define TY_UCHAR    2
#define TY_INT      3
#define TY_UINT     4
#define TY_PTR      5
#define TY_ARRAY    6
#define TY_STRUCT   7
#define TY_FUNC     8

#define T_VOID      0
#define T_CHAR      1
#define T_UCHAR     2
#define T_INT       3
#define T_UINT      4

/* Classes of globals */
#define G_EXTERN    1           /* declared, defined elsewhere */
#define G_TENT      2           /* int x; : in .bss unless initialized later */
#define G_DEF       3           /* defined here: data or a function body */
#define G_ENUM      4           /* an enumeration constant: g_val */
#define G_PROTO     5           /* a function declared, not defined (yet) */

/* Classes of locals */
#define L_AUTO      1           /* [bp+l_val] */
#define L_STATIC    2           /* a static of the function: label l_val */
#define L_ENUM      3
#define L_EXTERN    4           /* extern inside a function: the global l_val */

/* Expression nodes */
#define N_NUM       1           /* n_val */
#define N_STR       2           /* n_val: the string's label number */
#define N_GVAR      3           /* n_val: global */
#define N_LVAR      4           /* n_val: local */
#define N_DEREF     5           /* *l */
#define N_ADDR      6           /* &l */
#define N_CALL      7           /* n_val: global function, l: arguments (N_ARG list) */
#define N_ARG       8           /* l: the argument, r: the next N_ARG */
#define N_ASSIGN    9           /* l = r */
#define N_ASGOP     10          /* l op= r; n_val = the operator node */
#define N_PREINC    11          /* n_val: what is added */
#define N_POSTINC   12
#define N_COND      13          /* l ? r : n_x */
#define N_COMMA     14
#define N_CAST      15          /* l to n_type */
#define N_NEG       16
#define N_COM       17          /* ~ */
#define N_NOT       18
#define N_LAND      19
#define N_LOR       20
#define N_ADD       21          /* the binary operators, in this order */
#define N_SUB       22
#define N_MUL       23
#define N_DIV       24
#define N_MOD       25
#define N_SHL       26
#define N_SHR       27
#define N_AND       28
#define N_OR        29
#define N_XOR       30
#define N_EQ        31
#define N_NE        32
#define N_LT        33
#define N_LE        34
#define N_GT        35
#define N_GE        36

/* Link flags of a name (nm_link) */
#define LK_DEF      1
#define LK_REF      2
#define LK_WEAK     4
#define LK_USER     8           /* defined by a module given on the command line */

/* lex.c */
extern int tok, tokval, tokuns, toklen;
extern char tokstr[];
extern char asmbuf[];
extern char npool[];
extern int nm_str[], nm_sym[], nnames;
extern char nm_link[];
extern char *srcname;
extern int srcline;
extern int nerrors;
extern char *idirs[];
extern int nidirs;
int w16(int v);
int intern(char *s);
int intern_n(char *s, int n);
char *name_of(int id);
void lex_init(void);
void lex_reset(void);
int lex_open(char *name);
void lex_close(void);
void next(void);
int peek_tok(void);
void define_macro(char *p);
void error(char *msg);
void error_s(char *msg, char *s);
void fatal(char *msg);
void expect(int t);
int accept(int t);
int ident(void);

/* decl.c */
extern int ty_kind[], ty_base[], ty_n[];
extern int g_name[], g_type[], g_val[], nglobals;
extern char g_class[], g_static[], g_used[];
extern int l_name[], l_type[], l_class[], l_val[], nlocals;
extern int st_size[], st_first[];
extern int m_name[], m_type[], m_off[], m_next[];
extern int frame, frame_max;
extern int cur_func;
void decl_reset(void);
int tsize(int t);
int is_int(int t);
int is_ptr(int t);
int is_scalar(int t);
int is_unsigned(int t);
int ptr_to(int t);
int array_of(int t, int n);
int base_spec(int *sc);
int declarator(int t, int *name);
int type_name(void);
int is_type_start(void);
void top_decl(void);
void local_decl(void);
void pop_locals(int to);
int find_member(int s, int name);
int implicit_func(int name);
void end_module(void);
int new_label(void);

/* expr.c */
extern int n_op[], n_type[], n_l[], n_r[], n_x[], n_val[], nnodes;
int node(int op, int type, int l, int r, int val);
int num_node(int v);
int expr(void);
int assign_expr(void);
int const_expr(void);
int rvalue(int n);
int convert(int n, int t);

/* gen.c */
extern FILE *out;
extern char modname[];
extern int exe_mode;
extern int section;
void emit(char *s);
void emit_d(int v);
void emit_s(char *s, int v);
void emit_label(int n);
void emit_jump(int n);
void emit_ret(void);
void emit_string(char *s, int n, int with_zero);
void gen(int n);
void gen_void(int n);
void gen_cond(int n, int lab, int sense);
void to_section(int s);
void put_glabel(int g);

/* stmt.c */
void func_body(int g);
void statement(void);

/* link.c */
void note_ref(char *name);
void note_def(char *name);
void note_bss(char *name, int size);
void copy_module(char *name);
void copy_text(char *name);
void asm_block(char *text);
void index_library(char *name, int lib);
void start_program(void);
int link_program(char **libs, int nlibs);
