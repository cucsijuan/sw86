#!/usr/bin/env python3
"""
Tests the COS assembler (ASM.COM) and editor (EDIT.COM) on the pc86 machine.

ASM: assembles every source of sw86 inside COS (the kernel, COMMAND.COM, the
boot sector, the programs, the editor and the assembler itself) and checks
that the bytes are the ones asm86 makes; checks that programs with errors are
rejected with the right line; and, when pc86's random program generator
(vm86/tests/asm_vs_nasm.py) is found, compares random programs too.

EDIT: types keys into the editor and checks the file it saves.

Usage: python3 tests/tools_test.py [--asm ASM86] [--fdimage FDIMAGE] [--pcrun PCRUN]
                                   [--programs N]
"""
import argparse, glob, os, random, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PC86 = os.path.join(ROOT, "..", "pc86")
FAST = "40000000"                   # instructions per emulated second
PROMPT = "A:\\>"


def tool(path):
    for p in (path, path + ".exe"):
        if os.path.isfile(p):
            return p
    sys.exit(f"tool not found: {path} (build pc86 first)")


class Env:
    def __init__(self, args, tmp):
        self.asm, self.fdimage, self.pcrun, self.tmp = args.asm, args.fdimage, args.pcrun, tmp

    def path(self, name):
        return os.path.join(self.tmp, name)

    def run(self, *cmd, check=True):
        p = subprocess.run(cmd, capture_output=True, text=True)
        if check and p.returncode != 0:
            sys.exit(f"{' '.join(cmd)} failed:\n{p.stdout}{p.stderr}")
        return p

    def assemble(self, src, out):
        return self.run(self.asm, src, "-o", self.path(out), check=False).returncode == 0

    def system(self, name, files):
        """A COS system diskette with the given extra files (path, 8.3 name)."""
        img = self.path(name)
        if os.path.exists(img):
            os.remove(img)
        self.run(self.fdimage, "new", img, "--label", "COS")
        for f in ("COS.SYS", "COMMAND.COM", "ASM.COM", "EDIT.COM"):
            self.run(self.fdimage, "add", img, self.path(f))
        for path, name83 in files:
            self.run(self.fdimage, "add", img, path, name83)
        self.run(self.fdimage, "boot", img, self.path("boot.bin"))
        return img

    def boot(self, img, keys, seconds=600):
        p = self.run(self.pcrun, "--a", img, "--type", keys, "--until", PROMPT, "--seconds", str(seconds),
                     "--ips", FAST, "--text", "--save", "--out", self.path("screen"), check=False)
        return p.stdout + p.stderr

    def get(self, img, name):
        out = self.path("got.bin")
        if os.path.exists(out):
            os.remove(out)
        if self.run(self.fdimage, "get", img, name, out, check=False).returncode != 0:
            return None
        return open(out, "rb").read()


def name83(path):
    stem, ext = os.path.splitext(os.path.basename(path).upper())
    return stem[:8] + ext


# ---------------------------------------------------------------------------
# ASM

def asm_sources(env):
    """Every source of sw86, assembled inside COS: the same bytes as asm86."""
    srcs = sorted(glob.glob(os.path.join(ROOT, "programs", "*", "*.asm")))
    srcs += [os.path.join(ROOT, "dos", f) for f in ("boot.asm", "cos.asm", "command.asm", "edit.asm", "asm.asm")]
    srcs += sorted(glob.glob(os.path.join(ROOT, "dos", "tests", "*.asm")))
    files, keys, jobs = [], "", []
    for i, src in enumerate(srcs):
        n = name83(src)
        out = f"OUT{i:03d}.BIN"
        files.append((src, n))
        keys += f"ASM {n} {out}\\n"
        jobs.append((src, out))
    img = env.system("asm.img", files)
    screen = env.boot(img, keys)
    fails = 0
    for src, out in jobs:
        rel = os.path.relpath(src, ROOT).replace("\\", "/")
        if not env.assemble(src, "ref.bin"):
            print(f"FAIL ASM {rel}: asm86 rejects it")
            fails += 1
            continue
        want = open(env.path("ref.bin"), "rb").read()
        got = env.get(img, out)
        if got == want:
            print(f"ok   ASM {rel} ({len(got)} bytes, the same as asm86)")
        else:
            fails += 1
            print(f"FAIL ASM {rel}: " + ("no output" if got is None else f"{len(got)} bytes, asm86 {len(want)}"))
    if fails:
        print(screen)
    return fails, len(jobs)


# (source, line of the error, text in the message)
ERRORS = [
    ("org 100h\ndaa", 2, "not supported on this machine"),
    ("pusha", 1, "later CPU"),
    ("push 5", 1, "80186"),
    ("shl ax, 2", 1, "by 1 or by CL"),
    ("mov es, 5", 1, "immediate into a segment register"),
    ("mov ax, [bx+bp]", 1, "register combination"),
    ("mov [bx], 5", 1, "size not specified"),
    ("mov ax, bl", 1, "sizes do not match"),
    ("mov al, 300", 1, "does not fit in a byte"),
    ("nop\njmp nowhere", 2, "undefined symbol: 'nowhere'"),
    ("x: nop\nx: nop", 2, "already defined on line 1"),
    ("start:\n  jz far_away\n  times 200 nop\nfar_away:", 2, "conditional jump out of range"),
    ("db 'abc", 1, "unterminated string"),
    ("mov ax, 12z", 1, "invalid number"),
    ("mov ax, [bx", 1, "missing ']'"),
    ("frobnicate ax", 1, "unknown instruction: frobnicate"),
    ("mov ax, word ptr [bx]", 1, "PTR is MASM syntax"),
    ("dd 5", 1, "use db/dw"),
    ("times 70000 db 0", 1, "too large"),
    ("org 100h\nnop\norg 200h", 3, "ORG must come before any code"),
    ("mov ax, 1 +", 1, "missing value"),
    ("mov ax, eax", 1, "32-bit register"),
    ("lds si, bx", 1, "far pointer in memory"),
    ("jmp far 0:7C00h", 1, "already far"),
]


def asm_errors(env):
    """Programs with errors: ASM shows the line and the message, makes no file."""
    fails = 0
    for i in range(0, len(ERRORS), 4):           # four at a time fit on the screen
        batch = ERRORS[i:i + 4]
        files, keys = [], "cls\\n"
        for k, (src, line, text) in enumerate(batch):
            p = env.path(f"E{i + k:02d}.ASM")
            with open(p, "w", newline="\r\n") as f:
                f.write(src + "\n")
            files.append((p, f"E{i + k:02d}.ASM"))
            keys += f"ASM E{i + k:02d}\\n"
        img = env.system("err.img", files)
        screen = env.boot(img, keys)
        for k, (src, line, text) in enumerate(batch):
            n = f"E{i + k:02d}"
            want = f"{n}.ASM({line}): "
            row = next((l for l in screen.splitlines() if l.startswith(want)), None)
            made = env.get(img, n + ".COM") is not None
            if row and text in row and not made:
                print(f"ok   ASM error: {src.splitlines()[-1]!r} -> {row[len(want):]}")
            else:
                fails += 1
                print(f"FAIL ASM error: {src!r}: wanted {want}...{text}" + (" (and it made a file)" if made else ""))
                print(screen)
    return fails, len(ERRORS)


def asm_random(env, count):
    """Random programs (pc86's NASM comparison generator): ASM = asm86."""
    for d in (os.path.join(PC86, "vm86", "tests"), os.path.join(ROOT, "..", "vm86", "tests")):
        if os.path.isfile(os.path.join(d, "asm_vs_nasm.py")):
            sys.path.insert(0, os.path.abspath(d))
            break
    try:
        from asm_vs_nasm import Gen
    except ImportError:
        print("skip ASM random programs (pc86's vm86/tests/asm_vs_nasm.py not found)")
        return 0, 0
    gen = Gen(random.Random(7))
    files, keys, progs = [], "", []
    for i in range(count):
        p = env.path(f"R{i:03d}.ASM")
        with open(p, "w", encoding="utf-8", newline="\r\n" if i % 2 else "\n") as f:
            f.write(gen.program())
        files.append((p, f"R{i:03d}.ASM"))
        keys += f"ASM R{i:03d}\\n"
        progs.append(p)
    img = env.system("rnd.img", files)
    env.boot(img, keys, seconds=3000)
    same = rejected = 0
    fails = []
    for i, p in enumerate(progs):
        ok = env.assemble(p, "ref.bin")
        got = env.get(img, f"R{i:03d}.COM")
        if not ok:
            if got is None:
                rejected += 1
            else:
                fails.append(f"R{i:03d}: asm86 rejects it, ASM made a file")
        elif got != open(env.path("ref.bin"), "rb").read():
            fails.append(f"R{i:03d}: different bytes" if got is not None else f"R{i:03d}: ASM made no file")
        else:
            same += 1
    for f in fails[:5]:
        print("FAIL ASM random " + f)
    print(("ok   " if not fails else "FAIL ") + f"ASM random programs: {same} the same as asm86, {rejected} rejected by both, "
          f"{len(fails)} different")
    return (1 if fails else 0), 1


# ---------------------------------------------------------------------------
# EDIT

BASE = b"line one\r\n    indented two\r\nthree\r\n"


def lines(*ls):
    return b"".join(l.encode() + b"\r\n" for l in ls)


SAVE = "\\{F2}\\e"
CUT = "\x19"                         # Ctrl+Y
EDITS = [
    # (name, keys after "EDIT T.TXT", the file saved, options)
    ("Enter keeps the indentation", "\\{ArrowDown}\\{End}\\nX" + SAVE, lines("line one", "    indented two", "    X", "three"), {}),
    ("Enter in the middle of a line", "\\{ArrowDown}\\{End}\\{ArrowLeft}\\{ArrowLeft}\\{ArrowLeft}\\n" + SAVE,
     lines("line one", "    indented ", "    two", "three"), {}),
    ("Backspace joins lines", "\\{ArrowDown}\\b" + SAVE, lines("line one    indented two", "three"), {}),
    ("Del joins lines", "\\{End}\\{Delete}" + SAVE, lines("line one    indented two", "three"), {}),
    ("Backspace and Del", "\\{End}\\b\\b\\{Home}\\{Delete}" + SAVE, lines("ine o", "    indented two", "three"), {}),
    ("Ctrl+Y and F9", CUT + "\\{ArrowDown}\\{F9}\\{F9}" + SAVE, lines("    indented two", "line one", "line one", "three"), {}),
    ("cutting every line", CUT * 3 + SAVE, b"", {}),
    ("F3 finds, any case", "\\{F3}THREE\\n*" + SAVE, lines("line one", "    indented two", "*three"), {}),
    ("F4 finds again and wraps", "\\{F3}e\\n\\{F4}\\{F4}\\{F4}\\{F4}!" + SAVE, lines("line one", "    indented two", "thr!ee"), {}),
    ("F5 goes to a line", "\\{F5}2\\n#" + SAVE, lines("line one", "#    indented two", "three"), {}),
    ("Ins types over", "\\{Insert}AB" + SAVE, lines("ABne one", "    indented two", "three"), {}),
    ("Tab", "\\tX\\{Ctrl+End}\\{Home}a\\t" + SAVE, lines("    Xline one", "    indented two", "a   three"), {}),
    ("Ctrl+arrows by words", "\\{Ctrl+ArrowRight}X\\{Ctrl+End}\\{Ctrl+ArrowLeft}Y" + SAVE,
     lines("line Xone", "    indented two", "Ythree"), {}),
    ("PgDn, End, PgUp, Home", "\\{PageDown}\\{End}.\\{PageUp}\\{Home}," + SAVE, lines(",line one", "    indented two", "three."), {}),
    ("Esc, N: not saved", "zzz\\en", BASE, {}),
    ("Esc, Y: saved", "zzz\\ey", lines("zzzline one", "    indented two", "three"), {}),
    ("a new file", "Hi" + SAVE, lines("Hi"), {"content": None}),
    ("a new file left empty", SAVE, b"", {"content": None}),
    ("tabs and bare LFs read", SAVE, lines("a       b", "c"), {"content": b"a\tb\nc"}),
    ("Ctrl-Z ends the text", SAVE, lines("abc"), {"content": b"abc\r\n\x1aXYZ"}),
    ("long lines split", SAVE, lines("x" * 1000, "x" * 500), {"content": b"x" * 1500 + b"\r\n"}),
]


def edit_case(env, name, keys, want, content=BASE, fname="T.TXT"):
    files = []
    if content is not None:
        with open(env.path(fname), "wb") as f:
            f.write(content)
        files.append((env.path(fname), fname))
    img = env.system("edit.img", files)
    screen = env.boot(img, f"EDIT {fname}\\n" + keys)
    got = env.get(img, fname)
    if got == want:
        print(f"ok   EDIT {name}")
        return 0
    print(f"FAIL EDIT {name}\n     wanted {want[:200]!r}\n     got    {(got or b'')[:200]!r}\n{screen}")
    return 1


def edit_tests(env):
    fails = 0
    for name, keys, want, opt in EDITS:
        fails += edit_case(env, name, keys, want, **opt)
    # memory: a 400 KB file where 400 lines grow out of their place (the old
    # copies must be reclaimed), then the .BAK of the first version
    text = [(f"{i:04d}" + "abcdefghij" * 99)[:988] for i in range(400)]
    content = b"".join(l.encode() + b"\r\n" for l in text)
    want = b"".join((l + "x").encode() + b"\r\n" for l in text)
    fails += edit_case(env, "a 400 KB file, every line grown", "\\{End}x\\{ArrowDown}" * 400 + SAVE, want,
                       content=content, fname="BIG.TXT")
    bak = env.get(env.path("edit.img"), "BIG.BAK")
    if bak == content:
        print("ok   EDIT the old file kept as .BAK")
    else:
        fails += 1
        print("FAIL EDIT the old file kept as .BAK")
    # out of memory: a file that nearly fills it, every line grown; when the
    # memory runs out the cursor stays on its line, and F2 still saves it all
    # (the largest file that still loads, found by trying: Esc leaves EDIT,
    # or cancels the line if EDIT refused the file, and Enter brings the
    # prompt back; a few lines less leaves less free
    # memory than the growth needs)
    for n in range(480, 300, -3):
        text = [(f"{i:04d}" + "abcdefghij" * 99)[:988] for i in range(n)]
        with open(env.path("FULL.TXT"), "wb") as f:
            f.write(b"".join(l.encode() + b"\r\n" for l in text))
        img = env.system("edit.img", [(env.path("FULL.TXT"), "FULL.TXT")])
        if "too large" not in env.boot(img, "EDIT FULL.TXT\\n\\e\\n"):
            break
    screen = env.boot(img, "EDIT FULL.TXT\\n" + "\\{End}x\\{ArrowDown}" * n + SAVE)
    got = (env.get(img, "FULL.TXT") or b"").split(b"\r\n")
    grown = [g[len(t):] for g, t in zip(got, text) if g.startswith(t.encode())]
    lines_grown = sum(1 for x in grown if x)
    if len(got) == n + 1 and len(grown) == n and all(set(x) <= {ord("x")} for x in grown) and 0 < lines_grown < n:
        print(f"ok   EDIT out of memory: everything saved ({lines_grown} of {n} lines grown)")
    else:
        fails += 1
        print("FAIL EDIT out of memory: the file saved is not the text\n" + screen)
    return fails, len(EDITS) + 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asm", default=os.path.join(PC86, "vm86", "build", "asm86"))
    ap.add_argument("--fdimage", default=os.path.join(PC86, "fdc86", "build", "fdimage"))
    ap.add_argument("--pcrun", default=os.path.join(PC86, "pc86", "build", "pcrun"))
    ap.add_argument("--programs", type=int, default=60)
    args = ap.parse_args()
    args.asm, args.fdimage, args.pcrun = tool(args.asm), tool(args.fdimage), tool(args.pcrun)
    tmp = tempfile.mkdtemp()
    env = Env(args, tmp)
    for src, out in (("dos/boot.asm", "boot.bin"), ("dos/cos.asm", "COS.SYS"), ("dos/command.asm", "COMMAND.COM"),
                     ("dos/asm.asm", "ASM.COM"), ("dos/edit.asm", "EDIT.COM")):
        if not env.assemble(os.path.join(ROOT, src), out):
            sys.exit(f"asm86 cannot assemble {src}")
    fails = total = 0
    for test in (asm_sources, asm_errors, lambda e: asm_random(e, args.programs), edit_tests):
        f, n = test(env)
        fails += f
        total += n
    print(f"\nASM and EDIT: {total - fails}/{total} passed")
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
