#!/usr/bin/env python3
"""
Tests Small-C, the C compiler, on the pc86 machine.

The compiler is built for this computer with its C compiler, and builds
the library (CLIB.LIB) and itself (SMALLC.EXE). Every program in tests/smallc/ is
compiled with it, assembled with asm86 and run inside COS; what it prints
is compared with the .out file next to it. An .args file holds more files
and options for SMALLC (multi.args: multi2.c; bigdata.args: -e). Then, inside COS,
SMALLC.EXE compiles errors.c (its messages are compared) and compiles and runs
a program, calling ASM. With --self, SMALLC.EXE also compiles its own sources
inside COS, and the result must be the same as on this computer.

Usage: python3 tests/smallc_test.py [--asm ASM86] [--fdimage FDIMAGE] [--pcrun PCRUN]
                                [--hostcc CC] [--self] [NAME ...]
"""
import argparse, glob, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PC86 = os.path.join(ROOT, "..", "pc86")
SRC = os.path.join(ROOT, "smallc")
CASES = os.path.join(HERE, "smallc")
PROMPT = "A:\\>"
FAST = "40000000"
SC_SOURCES = ["main.c", "lex.c", "decl.c", "expr.c", "gen.c", "stmt.c", "link.c"]


def tool(path):
    for p in (path, path + ".exe"):
        if os.path.isfile(p):
            return p
    sys.exit(f"tool not found: {path} (build pc86 first)")


def run(*cmd, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if p.returncode != 0:
        sys.exit(f"{' '.join(cmd)} failed:\n{p.stdout}{p.stderr}")
    return p.stdout


def library_sources():
    lib = os.path.join(SRC, "lib")
    return sorted(glob.glob(os.path.join(lib, "*.asm"))) + sorted(glob.glob(os.path.join(lib, "*.c")))


class Env:
    def __init__(self, args, tmp):
        self.args, self.tmp = args, tmp

    def path(self, name):
        return os.path.join(self.tmp, name)

    def build(self):
        a = self.args
        self.cc = self.path("smallc")
        run(a.hostcc, "-std=c99", "-O1", "-o", self.cc, *[os.path.join(SRC, f) for f in SC_SOURCES])
        self.inc = "-I" + os.path.join(SRC, "include") + os.sep
        self.lib = self.path("CLIB.LIB")
        run(self.cc, self.inc, "-c", "-o", self.lib, *library_sources())
        self.compile([os.path.join(SRC, f) for f in SC_SOURCES], self.path("SMALLC.EXE"), ["-e"])
        for src, out in (("dos/boot.asm", "boot.bin"), ("dos/cos.asm", "COS.SYS"),
                         ("dos/command.asm", "COMMAND.COM"), ("dos/asm.asm", "ASM.COM")):
            run(a.asm, os.path.join(ROOT, src), "-o", self.path(out))

    def compile(self, sources, program, options=()):
        """Compiles with the cc of this computer and assembles: None, or the errors"""
        asm = os.path.splitext(program)[0] + ".ASM"
        p = subprocess.run([self.cc, "-n", "-L" + self.lib, self.inc, "-S", "-o", program, *options, *sources],
                           capture_output=True, text=True)
        if p.returncode != 0:
            return p.stdout + p.stderr
        p = subprocess.run([self.args.asm, asm, "-o", program], capture_output=True, text=True)
        if p.returncode != 0:
            return p.stdout + p.stderr
        return None

    def diskette(self, files):
        img = self.path("a.img")
        if os.path.exists(img):
            os.remove(img)
        fd = self.args.fdimage
        run(fd, "new", img, "--label", "COS")
        for f in ("COS.SYS", "COMMAND.COM", "ASM.COM"):
            run(fd, "add", img, self.path(f))
        for path, name in files:
            run(fd, "add", img, path, name)
        run(fd, "boot", img, self.path("boot.bin"))
        return img

    def screen(self, img, keys, seconds):
        p = subprocess.run([self.args.pcrun, "--a", img, "--type", keys, "--until", PROMPT, "--seconds",
                            str(seconds), "--ips", FAST, "--save", "--text"], capture_output=True, text=True)
        lines = [l.rstrip() for l in (p.stdout + p.stderr).replace("\r", "").split("\n")]
        return [l for l in lines if l.strip()]

    def get(self, img, name):
        out = self.path("got.bin")
        if os.path.exists(out):
            os.remove(out)
        p = subprocess.run([self.args.fdimage, "get", img, name, out], capture_output=True, text=True)
        if p.returncode != 0:
            return None
        return open(out, "rb").read()


def output_of(lines, command):
    """The lines printed after the prompt with the command"""
    starts = [i for i, l in enumerate(lines) if l.startswith(PROMPT + command)]
    got = []
    for l in lines[starts[-1] + 1 if starts else 0:]:
        if l.startswith(PROMPT) or l.startswith("emulated time") or l.startswith("timeout"):
            break
        got.append(l)
    return got


def compare(name, got, expected):
    if got == expected:
        print(f"ok    {name}")
        return True
    print(f"FAIL  {name}")
    for k in range(max(len(got), len(expected))):
        g = got[k] if k < len(got) else "<nothing>"
        e = expected[k] if k < len(expected) else "<nothing>"
        print(f"   {' ' if g == e else '*'} {g:<40} | {e}")
    return False


def helpers():
    """Files that are part of another test, not tests of their own"""
    names = set()
    for f in glob.glob(os.path.join(CASES, "*.args")):
        for w in open(f).read().split():
            if not w.startswith("-"):
                names.add(os.path.splitext(w)[0])
    return names


def check_case(env, name):
    base = os.path.join(CASES, name)
    options, sources = [], [base + ".c"]
    if os.path.exists(base + ".args"):
        for w in open(base + ".args").read().split():
            (options if w.startswith("-") else sources).append(w if w.startswith("-") else os.path.join(CASES, w))
    program = env.path(name.upper() + (".EXE" if "-e" in options else ".COM"))
    expected = open(base + ".out").read().rstrip("\n").split("\n")
    errors = env.compile(sources, program, options)
    if errors:
        print(f"FAIL  {name}: does not compile\n{errors}")
        return False
    img = env.diskette([(program, os.path.basename(program))])
    lines = env.screen(img, name.upper() + "\\n", 30)
    return compare(name, output_of(lines, name.upper()), expected)


def check_inside(env):
    """SMALLC.EXE inside COS: its error messages, then a program made with ASM"""
    inc = [(f, os.path.basename(f).upper()) for f in glob.glob(os.path.join(SRC, "include", "*.h"))]
    hello = env.path("hello.c")
    with open(hello, "w") as f:
        f.write('#include <stdio.h>\n\nint main(int argc, char **argv)\n{\n'
                '    printf("%s has %d arguments\\n", argv[1], argc - 1);\n    return 0;\n}\n')
    img = env.diskette([(env.path("SMALLC.EXE"), "SMALLC.EXE"), (env.lib, "CLIB.LIB"),
                        (os.path.join(CASES, "errors.c"), "ERRORS.C"), (hello, "HELLO.C"),
                        (os.path.join(CASES, "arith.c"), "ARITH.C")] + inc)
    lines = env.screen(img, "SMALLC -c ERRORS.C\\nSMALLC HELLO.C\\nHELLO one two\\nSMALLC -c ARITH\\n", 300)
    expected = open(os.path.join(CASES, "errors.out")).read().rstrip("\n").split("\n")
    ok = compare("errors (SMALLC.EXE in COS)", output_of(lines, "SMALLC -c ERRORS.C"), expected)
    got = output_of(lines, "SMALLC HELLO.C") + output_of(lines, "HELLO one two")
    ok = compare("SMALLC.EXE and ASM in COS", [l.split(":")[0] for l in got[:1]] + got[1:],
                 ["HELLO.COM", "one has 2 arguments"]) and ok
    mine = env.path("HELLO.COM")
    env.compile([hello], mine)
    same = env.get(img, "HELLO.COM") == open(mine, "rb").read()
    print(f"{'ok  ' if same else 'FAIL'}  HELLO.COM made in COS is the one made here")
    run(env.cc, env.inc, "-c", "-o", env.path("arith.asm"), os.path.join(CASES, "arith.c"))
    got = env.get(img, "ARITH.ASM")
    folded = got is not None and got.replace(b"\r", b"") == open(env.path("arith.asm"), "rb").read()
    print(f"{'ok  ' if folded else 'FAIL'}  SMALLC.EXE compiles arith.c (constants folded) as it is compiled here")
    return ok and same and folded


def check_self(env):
    """SMALLC.EXE compiles its own sources inside COS: the same SMALLC.ASM"""
    files = [(env.path("SMALLC.EXE"), "SMALLC.EXE"), (env.lib, "CLIB.LIB"), (os.path.join(SRC, "smallc.h"), "SMALLC.H")]
    files += [(os.path.join(SRC, f), f.upper()) for f in SC_SOURCES]
    files += [(f, os.path.basename(f).upper()) for f in glob.glob(os.path.join(SRC, "include", "*.h"))]
    img = env.diskette(files)
    cmd = "SMALLC -e -S -o SC2.EXE " + " ".join(f.upper() for f in SC_SOURCES)
    env.screen(img, cmd + "\\n", 1800)
    got = env.get(img, "SC2.ASM")
    mine = open(env.path("SMALLC.ASM"), "rb").read()
    ok = got is not None and got.replace(b"\r", b"") == mine.replace(b"\r", b"")
    print(f"{'ok  ' if ok else 'FAIL'}  SMALLC.EXE compiles itself in COS: the same {len(mine)} bytes")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asm", default=os.path.join(PC86, "vm86", "build", "asm86"))
    ap.add_argument("--fdimage", default=os.path.join(PC86, "fdc86", "build", "fdimage"))
    ap.add_argument("--pcrun", default=os.path.join(PC86, "pc86", "build", "pcrun"))
    ap.add_argument("--hostcc", default=os.environ.get("CC", "cc"))
    ap.add_argument("--self", action="store_true")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    args.asm, args.fdimage, args.pcrun = tool(args.asm), tool(args.fdimage), tool(args.pcrun)
    skip = helpers() | {"errors"}
    names = args.names or sorted(n for n in (os.path.splitext(os.path.basename(p))[0]
                                             for p in glob.glob(os.path.join(CASES, "*.c"))) if n not in skip)
    tmp = tempfile.mkdtemp(prefix="smallc_test_")
    try:
        env = Env(args, tmp)
        env.build()
        results = [check_case(env, n) for n in names]
        if not args.names:
            results.append(check_inside(env))
        if args.self:
            results.append(check_self(env))
        failed = results.count(False)
        print(f"{len(results) - failed}/{len(results)} passed")
        sys.exit(1 if failed else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
