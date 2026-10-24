# Small-C — the C compiler for COS

Small-C: a compiler for COS that makes `.COM` and `.EXE` programs, written in the C it compiles. The same sources build Small-C for this computer (any C99 compiler) and SMALLC.EXE for the machine, and both give the same output byte for byte: SMALLC.EXE compiling its own sources inside COS writes the same assembler source as the Small-C that built it (`tests/smallc_test.py --self`).

```
SMALLC [options] file...
  file.C    compiled            file.ASM  taken whole
  file.LIB  modules taken as the program needs them
  -o name   the program (NAME.COM after the first file)
  -e        an .EXE: 64 KB of code and 64 KB of data
  -c        each .C to an .ASM module; with -o all in one library
  -S        only the program's .ASM, without ASM
  -Dname[=value]  -Idirectory  -Llibrary  -n (no CLIB.LIB)
```

In COS, `SMALLC HELLO.C` writes `CCTEMP.ASM` and runs `ASM CCTEMP.ASM HELLO.COM` (ASM.COM next to SMALLC.EXE, or `\ASM.COM`). Elsewhere Small-C is used with `-S` and the program is assembled with asm86, which gives the same bytes.

## The language

C as in the first edition of the book, plus ANSI prototypes, with what a 16-bit machine without floating point needs:

- `char` (signed), `unsigned char`, `int` and `short` (16 bits), `unsigned`, pointers (16 bits), arrays of any number of dimensions, `struct` and `union` (packed, no padding), `enum`, `void`. `static`, `extern`, `auto`, `register`; `const` and `volatile` are accepted and ignored.
- Every operator on integers and pointers, casts, `sizeof` (unsigned), structure assignment. Numbers above 32767 are unsigned. Arithmetic, shifts and comparisons are unsigned when an operand is `unsigned` or a pointer.
- Every statement. Declarations go at the start of a block. Old-style definitions (`f(a, b) int a; char *b; {`) and `...` work; a function called before it is declared returns `int`.
- Global initializers: numbers, strings, addresses (`&x`, an array, `"text"`, plus or minus a constant), braces as in C (they may be left out). A local can be initialized only when it is a number or a pointer.
- The preprocessor: `#include "file"` (next to the file, then `-I`, then `INCLUDE\` and the directory of SMALLC.EXE) and `<file>`, `#define` with parameters (the arguments on one line), `#undef`, `#if`/`#elif`/`#else`/`#endif` with `defined`, `#ifdef`, `#ifndef`, `#error`, `#pragma` (ignored), `//` comments. `__COS__` and `__SMALLC__` are defined.
- `#asm` ... `#endasm`: the lines go to the program unchanged, inside a function (the parameters at `[bp+4]`, `[bp+6]`..., the value in AX) or between functions (`section .text`, `_name:`, and `;#def _name` so the link knows it).

Not supported, each with an error: `long`, `float` and `double`, `typedef`, pointers to functions, bit fields, structures passed or returned by value, initializers of local arrays and structures, the `#` and `##` operators.

## How it works

`lex.c` reads a line at a time: comments out, directives done, macros replaced in the line itself (the replacement is read again), then tokens. A name is interned once: its number in the name table says what it means now (`nm_sym`), whether it is a macro and what the link knows of it. `decl.c` keeps the types (a type is a number: kind, base, count; made once, so equal types have equal numbers), globals and locals (a local remembers what its name meant before it, so leaving a block gives names back), structures and the data of initializers. `expr.c` parses each expression into a tree with its types worked out (pointer arithmetic already scaled, constants folded); `gen.c` turns trees into code; `stmt.c` does statements and functions.

The code: values in AX, the second operand in CX, addresses in BX; operands that need no code (numbers, variables, members of variables, what a pointer variable points to) are used where they are (`add ax, [bp-4]`, `cmp byte [bx+2], 48`); the rest go through the stack. Conditions jump directly (`cmp` and a conditional jump, `&&` and `||` without values). Conditional jumps are written `je near .L5`: the assembler makes them short when the target is close, otherwise the opposite condition over a near JMP. A jump is written only when the next line is not its label; one right after another is dropped.

Functions keep BP as the frame: `push bp` / `mov bp, sp` / `times !!.F sub sp, .F`, where `.F` is an EQU written after the body with the size of the locals. Arguments are pushed as words from the last one, the caller removes them, the value comes back in AX; BP, SI and DI are kept. Labels: `_name` for C names, `MODULE@name` for statics, `.L1`, `.S1` (strings), `.V1` (statics of a function), `.R` (the return) inside a function.

### Programs, modules and libraries

There are no object files. A module is assembler source with lines for the link:

```
;#module NAME
;#def _f _g        names it defines
;#ref _printf      names it needs
;#bss _buf 512     uninitialized data, placed at the end
;#weak __flsall    a function that may be missing: then it is a RET
```

`SMALLC -c FILE.C` writes `FILE.ASM`; `SMALLC -c -o MY.LIB A.C B.C X.ASM` writes a library (modules one after the other; comments of `.ASM` files are left out). A program is one source: the start-up module (`C0COM` or `C0EXE` from the library), the modules given, the library modules they need and the ones those need, and an end that places the `.bss`: each variable is an EQU after the end of `.data`, so the 64 KB limit of the assembler covers only code and initialized data. `int x;` in two modules is one `x`; a name defined by two modules given is an error, as is a name nobody defines.

Every address of data is written `label-__dbase`. In a `.COM`, `__dbase` is 0 and everything is one 64 KB segment. In an `.EXE` the start-up module writes the header itself (one relocation: the segment of the data, in its first instruction); `.data` starts on a paragraph after the code, and DS = SS = ES is that segment, up to 64 KB of data, `.bss`, heap and stack. Both keep their memory and give the rest back to COS, so a program can run another (`spawn`): Small-C runs ASM that way.

### The library

`lib/`: `c0com.asm`, `c0exe.asm` (start-up, `exit`, `_exit`), `dosio.asm` (files by handle), `conio.asm`, `machine.asm` (ports, `peek`/`poke` anywhere, `getds`, interrupts on and off), `int86.asm`, `spawn.asm`, `memory.asm` (`memcpy`, `memmove`, `memset`), `stdioa.asm` (the fast path of `getc` and `putc`), and in C `args.c` (argc, argv, `getenv`), `stdio.c` and `fopen.c` (buffered streams, text with CR LF and Ctrl-Z), `printf.c`, `string.c`, `ctype.c`, `stdlib.c`, `malloc.c` (first fit, blocks joined as they are looked at). The headers are in `include/`.

### Memory

SMALLC.EXE is an `.EXE` so its tables have a data segment of their own (`cc.h`): 1250 names in one compilation (10000 characters), 320 globals and 100 locals in a file, 200 types, 80 structures with 200 members, 250 macros (3000 characters), 250 nodes in an expression, 150 cases, 6 nested includes, lines of 512 characters (768 after macros), strings of 300. SMALLC.EXE is about 57 KB, CLIB.LIB about 58 KB.

## Building and testing

```
make smallc     # build/smallc, build/dos/CLIB.LIB, build/dos/SMALLC.EXE
make dos        # the system diskette, with SMALLC.EXE, CLIB.LIB, the headers and HELLO.C
python3 tests/smallc_test.py [--self]
```

`tests/smallc/`: each `.c` is compiled, run in COS and its output compared with the `.out` beside it; an `.args` file has more files and options for SMALLC. At 4.77 MHz, `SMALLC HELLO.C` takes about 50 seconds ((20 for Small-C, 30 for ASM)).
