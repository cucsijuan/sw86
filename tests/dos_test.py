#!/usr/bin/env python3
"""
Tests COS on the pc86 machine: assembles the boot sector, the kernel,
COMMAND.COM and the test programs, makes diskettes with fdimage, boots them
with pcrun, types commands and checks what is on the screen and, after
--save, what is on the diskettes.

Usage: python3 tests/dos_test.py [--asm ASM86] [--fdimage FDIMAGE] [--pcrun PCRUN]
The tools default to the pc86 builds next to sw86.
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PC86 = os.path.join(ROOT, "..", "pc86")


def tool(path):
    for p in (path, path + ".exe"):
        if os.path.isfile(p):
            return p
    sys.exit(f"tool not found: {path} (build pc86 first)")


class Env:
    def __init__(self, args, tmp):
        self.asm, self.fdimage, self.pcrun, self.tmp = args.asm, args.fdimage, args.pcrun, tmp

    def run(self, *cmd):
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"{' '.join(cmd)} failed:\n{p.stdout}{p.stderr}")
        return p.stdout

    def assemble(self, src, out):
        self.run(self.asm, os.path.join(ROOT, src), "-o", os.path.join(self.tmp, out))
        return os.path.join(self.tmp, out)

    def path(self, name):
        return os.path.join(self.tmp, name)

    def image(self, name, label=None, files=(), boot=None, small=False):
        img = self.path(name)
        if os.path.exists(img):
            os.remove(img)
        self.run(self.fdimage, "new", img, *(["--label", label] if label else []), *(["--720k"] if small else []))
        for f in files:
            self.run(self.fdimage, "add", img, self.path(f))
        if boot:
            self.run(self.fdimage, "boot", img, self.path(boot))
        return img

    def boot(self, keys, a="a.img", b=None, extra=(), until="A:\\>", seconds=60):
        cmd = [self.pcrun, "--a", self.path(a), "--type", keys, "--until", until,
               "--seconds", str(seconds), "--text", "--out", self.path("screen")]
        if b:
            cmd += ["--b", self.path(b)]
        cmd += list(extra)
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.stdout + p.stderr


def build(env):
    env.assemble("dos/boot.asm", "boot.bin")
    env.assemble("dos/cos.asm", "COS.SYS")
    env.assemble("dos/command.asm", "COMMAND.COM")
    env.assemble("programs/hello/hello.asm", "HELLO.COM")
    for t in ("dostest", "child", "unsup", "readline", "diskfull"):
        env.assemble(f"dos/tests/{t}.asm", t.upper() + ".COM")
    env.assemble("dos/tests/testexe.asm", "TESTEXE.EXE")
    with open(env.path("README.TXT"), "wb") as f:
        f.write(b"Hello, diskette!\r\nSecond line.\r\n")
    with open(env.path("FILLER.BIN"), "wb") as f:     # leaves about 30 KB free
        f.write(bytes(1457664 - 30000))
    system = ["COS.SYS", "COMMAND.COM", "HELLO.COM", "README.TXT", "DOSTEST.COM", "CHILD.COM",
              "UNSUP.COM", "READLINE.COM", "DISKFULL.COM", "TESTEXE.EXE"]
    env.image("a.img", "COS", system, boot="boot.bin")
    env.image("a720.img", "COS", system, boot="boot.bin", small=True)


def fresh(env):
    """The diskettes each scenario starts from."""
    env.image("b.img", "DATA")
    env.image("b2.img", "OTHER", ["README.TXT"])
    env.image("bfull.img", None, ["FILLER.BIN"])
    env.image("b720.img", "SMALL", small=True)


# (name, keys, expected texts, options)
SCENARIOS = [
    ("boots to the prompt", "", ["CucsiCorp COS Version 1.00", "(C) Copyright CucsiCorp 1981", "A:\\>"], {}),
    ("VER", "ver\n", ["CucsiCorp COS Version 1.00"], {}),
    ("DIR", "dir\n", [" Volume in drive A is COS", " Directory of  A:\\", "COMMAND  COM", "HELLO    COM       31",
                      "TESTEXE  EXE", "File(s)", "bytes free"], {}),
    ("DIR /W and a pattern", "cls\ndir /w *.com\n", ["COMMAND  COM    HELLO    COM", "File(s)"], {}),
    ("TYPE", "type readme.txt\n", ["Hello, diskette!", "Second line."], {}),
    ("a .COM program", "hello\n", ["Hello from the 8086!"], {}),
    ("an .EXE program", "testexe\n", ["Hello from an .EXE"], {}),
    ("command tail as typed", "child One two\n", ["child got: One two"], {}),
    ("unknown command", "nothing\n", ["Bad command or file name"], {}),
    ("unsupported INT 21h function", "unsup\n", ["COS: INT 21h function AH=0Fh is not supported"], {"absent": ["still running"]}),
    ("the kernel through INT 21h", "dostest\n", ["DOSTEST: 0 failure(s)"], {"b": "b.img", "absent": ["FAIL"]}),
    ("720 KB diskettes", "dostest\n", ["DOSTEST: 0 failure(s)"], {"a": "a720.img", "b": "b720.img", "absent": ["FAIL"]}),
    ("standard input, line editing", "readline\nabX\bc\n", ["got 5: abc"], {}),
    ("Ctrl-C at the prompt", "dir\\c", ["A:\\>dir^C"], {}),
    ("Ctrl-C in a program", "readline\nxy\\c", ["type a line: xy^C"], {}),
    ("drive B: and running from it", "copy hello.com b:\nb:\nhello\ndir\n",
     ["1 File(s) copied", "B:\\>hello", "Hello from the 8086!", " Volume in drive B is DATA", "HELLO    COM"],
     {"b": "b.img", "until": "B:\\>"}),
    ("COPY with wildcards, REN, DEL", "copy *.com b:\nb:\nren hello.com hi.com\ndel child.com\ndir\n",
     ["HI       COM", "COMMAND  COM"], {"b": "b.img", "until": "B:\\>", "absent": ["CHILD    COM"], "save": True}),
    ("a changed diskette is noticed", "dir b:\n\\2dir b:\n", ["Volume in drive B is OTHER", "README   TXT"],
     {"b": "b.img", "b2": "b2.img"}),
    ("no diskette: Abort, Retry, Fail", "dir b:\nf", ["Not ready reading drive B", "Abort, Retry, Fail?F"], {}),
    ("write-protected diskette", "copy hello.com b:\nf",
     ["Write protect error writing drive B", "File creation error", "0 File(s) copied"],
     {"b": "b.img", "protect": "b"}),
    ("full diskette", "diskfull\n", ["disk full: short write, no space left, all back after delete"], {"b": "bfull.img"}),
    ("DATE and TIME", "date 12-31-1999\ndate\n\ntime 23:59:30\ntime\n\n",
     ["Current date is Fri 12-31-1999", "Current time is 23:59:3"], {}),
    ("invalid date", "date 2-30-1999\n", ["Invalid date"], {}),
    ("batch files", "copy readme.txt run.bat\nrun\n", ["Batch files are not supported by COS"], {}),
    ("the environment", "set\n", ["COMSPEC=A:\\COMMAND.COM"], {}),
    ("ECHO keeps the case", "echo Hello, World\n", ["Hello, World"], {}),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asm", default=os.path.join(PC86, "vm86", "build", "asm86"))
    ap.add_argument("--fdimage", default=os.path.join(PC86, "fdc86", "build", "fdimage"))
    ap.add_argument("--pcrun", default=os.path.join(PC86, "pc86", "build", "pcrun"))
    args = ap.parse_args()
    args.asm, args.fdimage, args.pcrun = tool(args.asm), tool(args.fdimage), tool(args.pcrun)

    tmp = tempfile.mkdtemp()
    env = Env(args, tmp)
    build(env)
    fails = 0
    for name, keys, want, opt in SCENARIOS:
        fresh(env)
        shutil.copy(env.path(opt.get("a", "a.img")), env.path("a_run.img"))
        extra = []
        if "b2" in opt:
            extra += ["--b2", env.path(opt["b2"])]
        if "protect" in opt:
            extra += ["--protect", opt["protect"]]
        if opt.get("save"):
            extra += ["--save"]
        out = env.boot(keys, a="a_run.img", b=opt.get("b"), extra=extra, until=opt.get("until", "A:\\>"))
        missing = [w for w in want if w not in out]
        present = [w for w in opt.get("absent", []) if w in out]
        if "timeout" in out:
            missing.append("(the prompt did not come back)")
        if missing or present:
            fails += 1
            print(f"FAIL {name}")
            for w in missing:
                print(f"     missing: {w!r}")
            for w in present:
                print(f"     unexpected: {w!r}")
            print("     screen:\n" + "\n".join("       | " + l for l in out.splitlines()))
        else:
            print(f"ok   {name}")

    # what COPY, REN and DEL left on B: (the scenario ran with --save)
    fresh(env)
    shutil.copy(env.path("a.img"), env.path("a_run.img"))
    env.boot("copy *.com b:\nb:\nren hello.com hi.com\ndel child.com\n", a="a_run.img", b="b.img",
             extra=["--save"], until="B:\\>")
    listing = env.run(env.fdimage, "ls", env.path("b.img"))
    env.run(env.fdimage, "get", env.path("b.img"), "HI.COM", env.path("hi.out"))
    same = open(env.path("hi.out"), "rb").read() == open(env.path("HELLO.COM"), "rb").read()
    if "HI.COM" in listing and "COMMAND.COM" in listing and "CHILD.COM" not in listing and same:
        print("ok   the diskette read back on the host")
    else:
        fails += 1
        print("FAIL the diskette read back on the host\n" + listing)

    total = len(SCENARIOS) + 1
    print(f"\nCOS scenarios: {total - fails}/{total} passed")
    shutil.rmtree(tmp, ignore_errors=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
