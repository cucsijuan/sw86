#!/usr/bin/env python3
"""
Tests CBasic (BASIC.COM) on the pc86 machine: runs every program in
tests/basic/ inside COS and compares what it prints with the .out file next
to it. A .keys file holds keys typed for the program (pcrun --type syntax)
and a .secs file a longer time limit. Then the demo game APES.BAS is started
to check that it compiles and reaches its title screen.

Usage: python3 tests/basic_test.py [--asm ASM86] [--fdimage FDIMAGE] [--pcrun PCRUN]
                                   [NAME ...]
"""
import argparse, glob, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PC86 = os.path.join(ROOT, "..", "pc86")
CASES = os.path.join(HERE, "basic")
PROMPT = "A:\\>"


def tool(path):
    for p in (path, path + ".exe"):
        if os.path.isfile(p):
            return p
    sys.exit(f"tool not found: {path} (build pc86 first)")


def run(*cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{' '.join(cmd)} failed:\n{p.stdout}{p.stderr}")
    return p.stdout


def diskette(args, tmp, files):
    img = os.path.join(tmp, "a.img")
    if os.path.exists(img):
        os.remove(img)
    run(args.fdimage, "new", img, "--label", "COS")
    for f in ("COS.SYS", "COMMAND.COM", "BASIC.COM"):
        run(args.fdimage, "add", img, os.path.join(tmp, f))
    for path, name in files:
        run(args.fdimage, "add", img, path, name)
    run(args.fdimage, "boot", img, os.path.join(tmp, "boot.bin"))
    return img


def screen(args, img, keys, until, seconds):
    cmd = [args.pcrun, "--a", img, "--type", keys, "--seconds", str(seconds), "--text"]
    if until:
        cmd += ["--until", until]
    p = subprocess.run(cmd, capture_output=True, text=True)
    lines = [l.rstrip() for l in (p.stdout + p.stderr).replace("\r", "").split("\n")]
    return [l for l in lines if l.strip()]


def check_case(args, tmp, name):
    base = os.path.join(CASES, name)
    keys = open(base + ".keys").read().strip("\n") if os.path.exists(base + ".keys") else ""
    secs = open(base + ".secs").read().strip() if os.path.exists(base + ".secs") else "30"
    expected = open(base + ".out").read().rstrip("\n").split("\n")
    img = diskette(args, tmp, [(base + ".bas", name.upper() + ".BAS")])
    lines = screen(args, img, "BASIC " + name.upper() + "\\n" + keys, PROMPT, secs)
    starts = [i for i, l in enumerate(lines) if l.startswith(PROMPT + "BASIC")]
    got = []
    for l in lines[starts[-1] + 1 if starts else 0:]:
        if l.startswith(PROMPT) or l.startswith("emulated time") or l.startswith("timeout"):
            break
        got.append(l)
    if not starts:                  # the screen scrolled: compare the end
        got = got[-len(expected):]
    if got == expected:
        print(f"ok    {name}")
        return True
    print(f"FAIL  {name}")
    for k in range(max(len(got), len(expected))):
        g = got[k] if k < len(got) else "<nothing>"
        e = expected[k] if k < len(expected) else "<nothing>"
        print(f"   {' ' if g == e else '*'} {g:<40} | {e}")
    return False


def check_demo(args, tmp):
    img = diskette(args, tmp, [(os.path.join(ROOT, "dos", "apes.bas"), "APES.BAS")])
    lines = screen(args, img, "BASIC APES\\n", None, 5)
    ok = any("A P E   D U E L" in l for l in lines) and not any("APES.BAS(" in l for l in lines)
    print(f"{'ok  ' if ok else 'FAIL'}  APES.BAS starts")
    if not ok:
        print("\n".join(lines))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--asm", default=os.path.join(PC86, "vm86", "build", "asm86"))
    ap.add_argument("--fdimage", default=os.path.join(PC86, "fdc86", "build", "fdimage"))
    ap.add_argument("--pcrun", default=os.path.join(PC86, "pc86", "build", "pcrun"))
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    args.asm, args.fdimage, args.pcrun = tool(args.asm), tool(args.fdimage), tool(args.pcrun)
    names = args.names or sorted(os.path.splitext(os.path.basename(p))[0]
                                 for p in glob.glob(os.path.join(CASES, "*.bas")))
    tmp = tempfile.mkdtemp(prefix="basic_test_")
    try:
        for src, out in (("dos/boot.asm", "boot.bin"), ("dos/cos.asm", "COS.SYS"),
                         ("dos/command.asm", "COMMAND.COM"), ("dos/basic.asm", "BASIC.COM")):
            run(args.asm, os.path.join(ROOT, src), "-o", os.path.join(tmp, out))
        results = [check_case(args, tmp, n) for n in names]
        if not args.names:
            results.append(check_demo(args, tmp))
        failed = results.count(False)
        print(f"{len(results) - failed}/{len(results)} passed")
        sys.exit(1 if failed else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
