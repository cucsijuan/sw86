# COS — CucsiCorp OS, a DOS for the pc86 machine

A subset of MS-DOS 3.30 that boots from a diskette: the real `INT 21h` function numbers, `.COM` and `.EXE` programs with a PSP and an environment, memory control blocks, file handles on FAT12 diskettes in drives A: and B:, and a `COMMAND.COM` with the usual built-in commands. Programs written for DOS that stay within this subset run unchanged.

Like the rest of the suite, what it implements behaves like DOS, and what it does not implement says so: a program that calls a missing `INT 21h` function is stopped with `COS: INT 21h function AH=xxh is not supported`, instead of getting something different.

## Status

| Check | Result |
|---|---|
| `tests/dostest.asm` on the machine: files across clusters and tracks, seek, truncate, find with wildcards, rename, attributes, duplicate handles, memory blocks, EXEC of a `.COM` (tail, return code) and of an `.EXE` (relocation, its own stack), IOCTL, FCB parsing, drive B:, directories (make, change, 40 files so one grows, move a file between them, remove: not when full or current), free space | 25/25, on 1.44 MB and on 720 KB diskettes |
| `tests/dos_test.py`: boot, commands, programs, Ctrl-C, a changed diskette, no diskette, write protection, a full diskette, the date and time, what the diskettes hold afterwards (read back on the host); MD, CD, RD, the prompt, DIR, COPY, REN, DEL, TYPE and programs with paths, and a diskette after a session in directories checked on the host like CHKDSK (chains, cross-links, lost clusters, `.` and `..`) | 37/37 |
| `boot.asm`, `cos.asm`, `command.asm` assembled with NASM 2.16 | identical bytes to asm86 |
| `tests/tools_test.py`: ASM on the machine assembles every sw86 source (itself included) and random programs, rejects programs with errors on the right line; EDIT edits, cuts and pastes, finds, saves 400 KB files and survives running out of memory | the same bytes as asm86; all pass |

## Writing programs on COS: EDIT and ASM

The system diskette has a full-screen editor and an assembler, so programs are written, assembled and run on the machine itself:

```
A:\>edit hello.asm             write or change the source (F2 saves, Esc leaves)
A:\>asm hello                  HELLO.ASM -> HELLO.COM
HELLO.COM: 31 bytes
A:\>hello
Hello from the 8086!
```

- **ASM** (`asm.asm`): `ASM source[.ASM] [output]`. The asm86 dialect (a NASM subset for the 8086: labels and .local labels, EQU, DB/DW/RESB/RESW, TIMES, ORG, `$`/`$$`, 32-bit expressions, BYTE/WORD/SHORT/NEAR/FAR, segment overrides, REP), with the same passes and choices as asm86, so the bytes are identical; errors are shown as `NAME.ASM(line): message`, with asm86's messages. It reads the source a piece at a time and keeps it as tokens in memory, so sources larger than 64 KB work; it assembles COS, COMMAND.COM, EDIT and itself. At the machine's 4.77 MHz, HELLO takes about a second and COS.SYS under a minute.
- **EDIT** (`edit.asm`): `EDIT file`. Arrows, Home/End, PgUp/PgDn, Ctrl+Home/End, Ctrl+arrows; Enter keeps the indentation; Ins; Tab (columns of 4); Ctrl+Y cuts lines, F9 pastes them; F3/F4 find (any case), F5 goes to a line; F2 saves through NAME.$$$ and keeps NAME.BAK; Esc leaves. Lines live one by one in memory above the program (up to 16000 lines of 1000 characters, about 450 KB), and are compacted when memory fills; F2 always works, even out of memory.

## Making a system diskette

```
make dos                        # build/cos.img: COS.SYS, COMMAND.COM, ASM, EDIT and HELLO.ASM, bootable
```

By hand, with the pc86 tools:

```
asm86 dos/boot.asm -o boot.bin
asm86 dos/cos.asm -o COS.SYS
asm86 dos/command.asm -o COMMAND.COM
asm86 dos/asm.asm -o ASM.COM
asm86 dos/edit.asm -o EDIT.COM
fdimage new cos.img --label COS         # or --720k
fdimage add cos.img COS.SYS
fdimage add cos.img COMMAND.COM
fdimage add cos.img ASM.COM
fdimage add cos.img EDIT.COM
fdimage boot cos.img boot.bin             # keeps the diskette's BPB
fdimage add cos.img GAME.COM              # and any programs
```

Then put the image in drive A: and power on: `pcrun --a cos.img`, Open image… in the workbench, or `fdd_insert()` in an engine. The [workbench](https://cucsijuan.github.io/pc86/) also makes one by itself: the "COS system diskette" button assembles these sources in the page and boots. The BIOS loads the boot sector, the boot sector loads `COS.SYS`, and the kernel starts `COMMAND.COM`:

```
CucsiCorp COS Version 1.00
(C) Copyright CucsiCorp 1981
A:\>dir

 Volume in drive A is COS
 Directory of  A:\

COS      SYS    12902   1-01-80  12:00a
COMMAND  COM     7035   1-01-80  12:00a
ASM      COM    17184   1-01-80  12:00a
EDIT     COM     5410   1-01-80  12:00a
HELLO    ASM      299   1-01-80  12:00a
        5 File(s)   1396736 bytes free
```

The manual, [doc/COS-Manual.pdf](../doc/COS-Manual.pdf), tells users how to work with COS and programmers how to write for it (every command and message, the INT 21h reference, the PSP, memory, the diskette format). Its source is [doc/manual.html](../doc/manual.html); `python3 doc/build.py` prints it again with Edge, Chrome or Chromium.

## What is supported

### INT 21h

| AH | Function |
|---|---|
| `00h`, `4Ch`, `31h` | terminate (return code, Ctrl-C and critical-error types for `4Dh`), terminate and stay resident |
| `01h`, `02h`, `06h`, `07h`, `08h`, `09h`, `0Ah`, `0Bh`, `0Ch` | console: keys (extended keys as 0 + scan code), characters, `$` strings, line input with Backspace and Esc, Ctrl-C |
| `0Dh`, `0Eh`, `19h` | disk reset (writes everything pending), select drive, current drive |
| `1Ah`, `2Fh` | set / get the DTA |
| `25h`, `35h` | set / get an interrupt vector |
| `29h` | parse a file name into an FCB |
| `2Ah`–`2Dh` | date and time (day of the week included) |
| `2Eh`, `54h` | verify flag |
| `30h` | version: 3.30 |
| `33h` | Ctrl-Break flag (`00h`, `01h`), boot drive (`05h`) |
| `34h` | InDOS flag address |
| `36h` | free space |
| `37h` | switch character (`00h`: `/`) |
| `38h` | country information (`00h`: United States) |
| `39h`, `3Ah`, `3Bh`, `47h` | make, remove, change and get the current directory (one per drive) |
| `3Ch`, `5Bh`, `3Dh`, `3Eh`, `3Fh`, `40h`, `42h`, `68h` | create, create new, open, close, read, write (0 bytes truncates), seek, commit |
| `41h`, `43h`, `56h`, `57h` | delete, attributes, rename, date and time of a file |
| `44h` | IOCTL: `00h`/`01h` device information (raw mode for CON), `06h`/`07h` status, `08h` removable, `09h` remote, `0Eh` drive map |
| `45h`, `46h` | duplicate a handle |
| `48h`, `49h`, `4Ah`, `58h` | memory blocks (first fit) |
| `4Bh` | load and run (`00h`): `.COM` and `.EXE` |
| `4Dh` | return code of the last program |
| `4Eh`, `4Fh` | find first / next, with `*` and `?` |
| `50h`, `51h`, `62h` | set / get the current PSP |
| `59h` | extended error |

Devices: `CON` (cooked or raw) and `NUL`. Handles 0, 1 and 2 are the console; programs inherit their parent's handles.

### Other interrupts

| INT | |
|---|---|
| `20h`, `27h` | terminate, terminate and stay resident |
| `22h` | where the parent continues (from the PSP) |
| `23h` | Ctrl-C: ends the program; a program can install its own |
| `24h` | critical errors: "Not ready reading drive B" / "Abort, Retry, Fail?"; a program can install its own |
| `28h`, `2Ah`, `2Fh` | `IRET` (nothing installed) |
| `29h` | fast console output |

### COMMAND.COM

`CD` `CHDIR` `CLS` `COPY` `DATE` `DEL` `DIR` (`/W`) `ECHO` `ERASE` `EXIT` `MD` `MKDIR` `PAUSE` `RD` `REM` `REN` `RENAME` `RMDIR` `SET` `TIME` `TYPE` `VER` `VOL`, `B:` to change drive, and programs: `NAME` runs `NAME.COM`, then `NAME.EXE`, from the current directory or the path given (`B:\GAMES\SPACE`), and a bare name not found there from the root directory. Every name can have a path (`..\NOTES.TXT`, `B:\DATA\*.*`); the prompt shows the current directory (`A:\GAMES>`); `DIR`, `COPY` and `DEL` take a directory as "every file in it". `COPY`, `DEL` and `REN` take wildcards (`COPY *.COM B:`, `REN *.TXT *.BAK`). The command tail reaches the program as typed, with the first two arguments in the PSP's FCBs.

## How it works

- **Boot.** The boot sector (`boot.asm`) reads the first FAT, finds `COS.SYS` in the root directory and follows its cluster chain to `0070:0000`. The kernel sets its vectors, builds the memory chain up to the top that `INT 12h` reports, and runs `COMMAND.COM` with `4B00h`; if it ever ends, it runs it again.
- **INT 21h.** The caller's registers are saved on its own stack and the kernel switches to its own. On EXEC the parent's stack goes into its PSP (`2Eh`); when the child ends, its handles are closed, its memory is freed, `INT 22h`–`24h` are put back and the parent continues after its `INT 21h` with its registers as they were.
- **Directories.** A directory is known by its first cluster (0 is the root, fixed sectors after the FATs; any other is a chain of clusters starting with `.` and `..`). Every path goes through one routine that follows its names from the root or from the drive's current directory (a cluster and its text, per drive), so every function takes paths; open files remember the directory of their entry. A full subdirectory gets a new, zeroed cluster. Changing the diskette puts the drive back at its root.
- **Diskettes.** Sectors are read a whole track at a time (one `INT 13h`, one turn of the diskette) into a track buffer. Writes change the buffer and are written back, one `INT 13h` for the changed sectors, before another track is read, when a file is closed or committed, at disk reset and when a program ends; a new directory entry is written at once, so a write-protected diskette fails on the create, as on DOS. The FAT of each drive is kept in memory and written to every copy. Before each access the change line (`INT 13h AH=16h`) says whether the diskette was changed; if so its BPB and FAT are read again.
- **Errors.** `INT 13h` is tried three times; then `INT 24h` decides: Retry, Fail (the function returns error 83), or Abort (the program ends).

### Memory

```
0000:0000  interrupt vectors, BIOS data
0070:0000  COS.SYS: code and data (about 11 KB)
           the kernel's PSP, the track buffer (9 KB), the FATs (2 x 4.5 KB), stacks
           free memory, MCB chain: the master environment, COMMAND.COM, programs
A000:0000  top of memory (640 KB)
```

## Not supported

- A search path (`PATH`): programs are looked for in the current directory, then in the root.
- FCB file functions (`0Fh`–`28h`), absolute disk access (`INT 25h`/`26h`), `CALL 5`, `4B01h`/`4B03h`, and the other functions not listed: they stop the program with a message.
- Batch files, redirection and pipes in COMMAND.COM; environment changes with `SET`.
- `AUX`, `PRN`, `COMx`, `LPTx` and `CLOCK$`: the machine has no such hardware; opening them gives "access denied".
- `INT 21h` is not reentrant: an `INT 24h` handler or a hardware interrupt cannot call it.
- Ctrl-C is checked on console input only (`BREAK OFF`). A program's `INT 23h` handler must return with `IRET` (the function is retried) or not return.
- An `.EXE` asking to be loaded high (minimum and maximum allocation 0) is loaded low.
- A diskette changed while it has open files gets their data, as on DOS without the "Invalid disk change" check.
- There is no real-time clock: the date starts at 1 January 1980 and the time at midnight; `DATE` and `TIME` set them.

## Files

```
boot.asm             boot sector
cos.asm            kernel (COS.SYS)
command.asm          command interpreter (COMMAND.COM)
asm.asm              assembler (ASM.COM)
edit.asm             text editor (EDIT.COM)
tests/dostest.asm    the kernel through INT 21h
tests/child.asm      run by dostest: prints its tail, ends with code 42
tests/testexe.asm    an .EXE written by hand, with a relocation
tests/readline.asm   reads a line from standard input
tests/diskfull.asm   writes until the diskette is full
tests/unsup.asm      calls a function that is not supported
../tests/dos_test.py builds diskettes and runs everything on the machine
../tests/tools_test.py ASM and EDIT on the machine
```
