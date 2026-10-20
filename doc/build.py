#!/usr/bin/env python3
"""
Prints the COS manual (manual.html) to COS-Manual.pdf with a Chromium-based
browser in headless mode: Microsoft Edge, Google Chrome or Chromium.

Usage: python3 build.py [--browser PATH] [--out COS-Manual.pdf]
"""
import argparse, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "google-chrome", "chromium", "chromium-browser", "microsoft-edge",
]


def find_browser():
    for c in CANDIDATES:
        p = c if os.path.isabs(c) else shutil.which(c)
        if p and os.path.exists(p):
            return p
    sys.exit("no Chromium-based browser found: use --browser")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser")
    ap.add_argument("--out", default=str(HERE / "COS-Manual.pdf"))
    args = ap.parse_args()
    browser = args.browser or find_browser()
    out = Path(args.out).resolve()
    if out.exists():
        out.unlink()
    profile = tempfile.mkdtemp(prefix="cosman-")
    cmd = [browser, "--headless=new", "--disable-gpu", "--no-first-run", "--user-data-dir=" + profile,
           "--no-pdf-header-footer", "--virtual-time-budget=20000", "--print-to-pdf=" + str(out),
           (HERE / "manual.html").as_uri()]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    for _ in range(60):                     # some builds return before the file is written
        if out.exists() and out.stat().st_size > 0:
            break
        time.sleep(1)
    shutil.rmtree(profile, ignore_errors=True)
    if not out.exists():
        sys.exit("the browser did not write " + str(out))
    print(f"{out.name}: {out.stat().st_size} bytes")


if __name__ == "__main__":
    main()
