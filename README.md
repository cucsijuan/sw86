# sw86

Software for the [pc86](../pc86) virtual PC that is not part of any hardware
(BIOS and drivers stay in pc86).

- `dos/`: COS, a DOS that boots from a diskette (MS-DOS 3.30 subset, FAT12
  on drives A: and B:, COMMAND.COM). See [dos/README.md](dos/README.md).
- `doc/`: the COS manual, [COS-Manual.pdf](doc/COS-Manual.pdf) (User's Guide and
  Technical Reference), built from `manual.html` with `python3 doc/build.py`.
- `programs/`: one folder per program. Copied from the pc86 examples; some
  may need pc86 devices (e.g. VGA, PIT).

Build: `make -C ../pc86/vm86`, `make -C ../pc86/fdc86` and `make -C ../pc86/pc86`
once for `asm86`, `fdimage` and `pcrun`, then:

```
make            # programs/*/*.asm into build/
make dos        # build/cos.img, the COS system diskette
make test       # COS on the machine (Python 3)
```
