# sw86

Software for the [pc86](../pc86) virtual PC that is not part of any hardware
(BIOS and drivers stay in pc86).

- `dos/`: COS, a DOS that boots from a diskette (MS-DOS 3.30 subset, FAT12
  with subdirectories on drives A: and B:, COMMAND.COM), with its own full-screen editor (EDIT),
  assembler (ASM), BASIC (CucsiCorp CBasic, in the style of QBasic, with
  graphics and sound) and a C compiler (Small-C), so programs can be written and
  run on the machine itself. See [dos/README.md](dos/README.md).
- `smallc/`: Small-C, the C compiler for COS: C with structures (no long, float,
  typedef or pointers to functions), `.COM` and `.EXE` programs, programs
  of several files and libraries; written in that C, it compiles itself.
  See [smallc/README.md](smallc/README.md).
- `doc/`: the COS manual, [COS-Manual.pdf](doc/COS-Manual.pdf) (User's Guide and
  Technical Reference), built from `manual.html` with `python3 doc/build.py`,
  the CBasic manual, [CBasic-Manual.pdf](doc/CBasic-Manual.pdf), built from
  `cbasic.html` the same way, and the Small-C manual,
  [Small-C-Manual.pdf](doc/Small-C-Manual.pdf), from `smallc.html`.
- `programs/`: one folder per program. Copied from the pc86 examples; some
  may need pc86 devices (e.g. VGA, PIT).

## Roadmap

- An object format and a linker for COS (as NASM's `-f obj` with LINK).
  Small-C already builds programs of several files, libraries and `.EXE`
  programs with a data segment of their own, putting the modules together
  as assembler source; object files would spare assembling everything each
  time, and allow more than 64 KB of code.

Build: `make -C ../pc86/vm86`, `make -C ../pc86/fdc86` and `make -C ../pc86/pc86`
once for `asm86`, `fdimage` and `pcrun`, then (Small-C needs a C compiler on this
computer, `HOSTCC=cc` by default):

```
make            # programs/*/*.asm into build/
make smallc     # build/smallc (Small-C for this computer), build/dos/CLIB.LIB and SMALLC.EXE
make dos        # build/cos.img, the COS system diskette (with Small-C)
make test       # COS, ASM, EDIT, CBasic and Small-C on the machine (Python 3)
```
