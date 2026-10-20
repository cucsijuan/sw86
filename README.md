# sw86

Software for the [pc86](../pc86) virtual PC that is not part of any hardware
(BIOS and drivers stay in pc86). One folder per program in `programs/`.

Build: `make -C ../pc86/vm86` once to get `asm86`, then `make`.
Programs copied from the pc86 examples; some may need pc86 devices (e.g. VGA, PIT).
