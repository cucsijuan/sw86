# sw86

Software for the [pc86](../pc86) virtual PC that is not part of any hardware
(BIOS and drivers stay in pc86).

- `dos/`: COS, a DOS that boots from a diskette (MS-DOS 3.30 subset, FAT12
  with subdirectories on drives A: and B:, COMMAND.COM), with its own full-screen editor (EDIT),
  assembler (ASM) and BASIC (CucsiCorp CBasic, in the style of QBasic, with
  graphics and sound), so programs can be written and run on the machine
  itself. See [dos/README.md](dos/README.md).
- `doc/`: the COS manual, [COS-Manual.pdf](doc/COS-Manual.pdf) (User's Guide and
  Technical Reference), built from `manual.html` with `python3 doc/build.py`,
  and the CBasic manual, [CBasic-Manual.pdf](doc/CBasic-Manual.pdf), built from
  `cbasic.html` the same way.
- `programs/`: one folder per program. Copied from the pc86 examples; some
  may need pc86 devices (e.g. VGA, PIT).

## Roadmap

- An object format and a linker for COS (as NASM's `-f obj` with LINK):
  programs built from several source files, and `.EXE` programs larger
  than one 64 KB segment, with their relocations written by the linker.

Build: `make -C ../pc86/vm86`, `make -C ../pc86/fdc86` and `make -C ../pc86/pc86`
once for `asm86`, `fdimage` and `pcrun`, then:

```
make            # programs/*/*.asm into build/
make dos        # build/cos.img, the COS system diskette
make test       # COS, ASM, EDIT and CBasic on the machine (Python 3)
```
