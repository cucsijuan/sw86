# sw86

Software for the [pc86](../pc86) virtual PC that is not part of any hardware
(BIOS and drivers stay in pc86).

- `dos/`: DOS86, a DOS that boots from a diskette (MS-DOS 3.30 subset, FAT12
  on drives A: and B:, COMMAND.COM). See [dos/README.md](dos/README.md).
- `programs/`: one folder per program. Copied from the pc86 examples; some
  may need pc86 devices (e.g. VGA, PIT).

Build: `make -C ../pc86/vm86`, `make -C ../pc86/fdc86` and `make -C ../pc86/pc86`
once for `asm86`, `fdimage` and `pcrun`, then:

```
make            # programs/*/*.asm into build/
make dos        # build/dos86.img, the DOS86 system diskette
make test       # DOS86 on the machine (Python 3)
```
