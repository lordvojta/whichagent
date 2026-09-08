#!/usr/bin/env python3
"""Resolve a notification image for a repo, and print its path.

Order of preference:
  1. A real project icon committed in the repo (favicon, app icon, logo).
  2. A generated identicon, so a repo with no artwork still gets a stable,
     recognisable image rather than nothing.

Results are cached per repo under $TMPDIR/agent-sound/icons and reused until the
source file changes, because this runs on every notification.

Usage: agent-icon.py <repo-root>   ->  prints a png path, or nothing on failure.
"""

import base64
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import zlib

# Ordered best first. Touch icons are the largest and cleanest, plain favicons
# are usually 16 or 32 px and look muddy when the banner scales them up.
CANDIDATES = [
    "public/apple-touch-icon.png",
    "public/apple-icon.png",
    "src/app/apple-icon.png",
    "app/apple-icon.png",
    "public/icon.png",
    "src/app/icon.png",
    "app/icon.png",
    "public/logo.png",
    "assets/logo.png",
    "docs/logo.png",
    ".github/logo.png",
    "logo.png",
    "public/favicon.png",
    "public/favicon.ico",
    "src/app/favicon.ico",
    "app/favicon.ico",
    "static/favicon.png",
    "static/favicon.ico",
    "favicon.ico",
    "public/icon.svg",
    "assets/icon.png",
    "resources/icon.png",
    "build/icon.png",
]

SIZE = 128

# Monorepos keep their icons one level down, so every root-relative candidate
# misses and the repo silently falls back to an identicon. It exits 0 and prints
# a path, so nothing looks broken, which is why this reads as "not recognising
# the favicon" rather than as a failure.
MONOREPO_ROOTS = ["apps", "packages", "services", "sites", "projects"]
MONOREPO_RELS = [
    "public/apple-touch-icon.png",
    "public/apple-icon.png",
    "public/icon.png",
    "public/logo.png",
    "public/favicon.png",
    "public/favicon.ico",
    "src/app/icon.png",
    "src/app/apple-icon.png",
    "src/app/favicon.ico",
    "app/icon.png",
    "app/favicon.ico",
    "static/favicon.png",
    "static/favicon.ico",
]
# Generated output, not artwork. A coverage report ships its own favicon and
# would otherwise win purely by sorting earlier than the real one.
EXCLUDE_PARTS = ("/coverage/", "/node_modules/", "/dist/", "/build/",
                 "/.next/", "/out/", "/.turbo/", "/.cache/")


def cache_dir():
    """Deliberately not $TMPDIR.

    The per-user darwin temp dir is mode 700 and gets swept, and the
    notification service has to be able to read whatever we hand it as an
    attachment. A stable directory under ~/.claude also means an icon is
    converted once ever rather than once per reboot.
    """
    d = os.path.join(os.path.expanduser("~"), ".claude", "cache", "agent-icons")
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o755)
    except OSError:
        pass
    return d


def write_png(path, pixels, w, h):
    """Minimal truecolour PNG writer, so no image library is needed."""
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def identicon(repo_root, out):
    """A 5x5 mirrored grid keyed off the repo path.

    Same repo always gets the same mark, different repos reliably differ, and it
    reads at banner size where a wall of text does not.
    """
    h = hashlib.sha256(repo_root.encode()).digest()
    # Pick a saturated colour: fixed lightness keeps every icon legible on both
    # the light and the dark banner backgrounds.
    hue = h[0] / 255.0
    i = int(hue * 6) % 6
    f = hue * 6 - int(hue * 6)
    v, p, q, t = 220, 60, int(220 - 160 * f), int(60 + 160 * f)
    fg = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    bg = (28, 28, 32)

    cells = 5
    grid = [[False] * cells for _ in range(cells)]
    for x in range((cells + 1) // 2):
        for y in range(cells):
            on = h[(x * cells + y) % len(h)] & 1
            grid[y][x] = bool(on)
            grid[y][cells - 1 - x] = bool(on)

    pad = SIZE // 10
    inner = SIZE - 2 * pad
    step = inner / cells
    rows = []
    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            gx, gy = int((px - pad) / step), int((py - pad) / step)
            on = (0 <= gx < cells and 0 <= gy < cells and grid[gy][gx])
            row += bytes(fg if on else bg)
        rows.append(row)
    write_png(out, rows, SIZE, SIZE)
    return out


def svg_to_png(src, out):
    """Rasterise an svg via Quick Look, the only svg renderer guaranteed present.

    sips cannot read svg at all: it reports success and writes nothing usable.
    qlmanage writes <basename>.png into the -o directory, so the result has to
    be moved into place rather than named directly.
    """
    try:
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run(["qlmanage", "-t", "-s", str(SIZE), "-o", td, src],
                               capture_output=True, timeout=15)
            if r.returncode != 0:
                return None
            made = os.path.join(td, os.path.basename(src) + ".png")
            if not os.path.exists(made) or os.path.getsize(made) == 0:
                return None
            shutil.copyfile(made, out)
            return out
    except Exception:
        return None


def convert(src, out):
    """Normalise anything sips can read (ico, png, jpg, icns, tiff) to a png."""
    if src.lower().endswith(".svg"):
        return svg_to_png(src, out)
    try:
        r = subprocess.run(
            ["sips", "-s", "format", "png", "-Z", str(SIZE), src, "--out", out],
            capture_output=True, timeout=10)
        return out if r.returncode == 0 and os.path.exists(out) else None
    except Exception:
        return None


def _usable(path):
    return (os.path.isfile(path) and os.path.getsize(path) > 0
            and not any(x in path for x in EXCLUDE_PARTS))


def find_monorepo_source(repo_root):
    """Second pass: apps/<pkg>/public/favicon.ico and friends.

    Ranked by the same preference order as the root list, so a touch icon in one
    package still beats a bare favicon in another.
    """
    best = None
    for group in MONOREPO_ROOTS:
        base = os.path.join(repo_root, group)
        if not os.path.isdir(base):
            continue
        try:
            pkgs = sorted(os.listdir(base))
        except OSError:
            continue
        for pkg in pkgs:
            d = os.path.join(base, pkg)
            if not os.path.isdir(d):
                continue
            for rank, rel in enumerate(MONOREPO_RELS):
                p = os.path.join(d, rel)
                if _usable(p) and (best is None or rank < best[0]):
                    best = (rank, p)
    return best[1] if best else None


# Vite and friends routinely declare the favicon inline in index.html as a
# data: URI, so there is no icon file anywhere on disk to find. Path-based
# search cannot see those at all: a monorepo ships its real brand mark this way
# while its only favicon.ico is a 0-byte placeholder.
HTML_RELS = ["index.html", "public/index.html", "src/index.html"]

_ICON_LINK = re.compile(
    r"""<link\b[^>]*?\brel\s*=\s*["'](?:shortcut\s+)?(?:icon|apple-touch-icon)["']"""
    r"""[^>]*?\bhref\s*=\s*(["'])(.*?)\1""",
    re.I | re.S,
)


def _html_files(repo_root):
    for rel in HTML_RELS:
        yield os.path.join(repo_root, rel)
    for group in MONOREPO_ROOTS:
        base = os.path.join(repo_root, group)
        if not os.path.isdir(base):
            continue
        try:
            pkgs = sorted(os.listdir(base))
        except OSError:
            continue
        for pkg in pkgs:
            for rel in HTML_RELS:
                yield os.path.join(base, pkg, rel)


def find_html_icon(repo_root):
    """Third pass: the icon a page declares, whether inline or by path.

    Returns (path, stamp) or None. For a data: URI the svg is materialised into
    the cache, and the stamp keys off the html file rather than that temp file,
    whose mtime would otherwise change on every run and defeat the cache.
    """
    for html in _html_files(repo_root):
        if not _usable(html):
            continue
        try:
            with open(html, encoding="utf-8", errors="replace") as f:
                text = f.read(65536)
        except OSError:
            continue
        m = _ICON_LINK.search(text)
        if not m:
            continue
        # Only the opening quote character terminates the value. A data: URI
        # normally contains the other quote type (xmlns='...'), so excluding
        # both truncates it to a few useless bytes.
        href = m.group(2).strip()
        stamp = f"{html}:{os.path.getmtime(html)}"

        if href.startswith("data:"):
            head, _, payload = href.partition(",")
            if not payload:
                continue
            try:
                if ";base64" in head:
                    blob = base64.b64decode(payload)
                else:
                    blob = urllib.parse.unquote(payload).encode("utf-8")
            except Exception:
                continue
            if len(blob) < 32:
                continue
            ext = ".svg" if "svg" in head else ".png"
            key = hashlib.sha1(repo_root.encode()).hexdigest()[:16]
            tmp = os.path.join(cache_dir(), f"{key}.inline{ext}")
            try:
                if not os.path.exists(tmp) or open(tmp, "rb").read() != blob:
                    with open(tmp, "wb") as f:
                        f.write(blob)
            except OSError:
                continue
            return tmp, stamp

        if href.startswith(("http://", "https://", "//")):
            continue  # never fetch over the network from a notification hook
        p = os.path.normpath(os.path.join(os.path.dirname(html), href.split("?")[0]))
        if _usable(p):
            return p, stamp
    return None


def find_source(repo_root):
    """Returns (path, stamp) or None. Stamp decides whether the cache is stale."""
    for rel in CANDIDATES:
        p = os.path.join(repo_root, rel)
        if _usable(p):
            return p, f"{p}:{os.path.getmtime(p)}"
    p = find_monorepo_source(repo_root)
    if p:
        return p, f"{p}:{os.path.getmtime(p)}"
    return find_html_icon(repo_root)


def main():
    if len(sys.argv) < 2:
        return 2
    repo = os.path.realpath(sys.argv[1])
    key = hashlib.sha1(repo.encode()).hexdigest()[:16]
    out = os.path.join(cache_dir(), f"{key}.png")

    found = find_source(repo)
    src, want = found if found else (None, "identicon")
    stamp = os.path.join(cache_dir(), f"{key}.src")

    # Reuse the cached png unless the source changed.
    if os.path.exists(out):
        try:
            with open(stamp) as f:
                if f.read() == want:
                    print(out)
                    return 0
        except OSError:
            pass

    result = None
    if src:
        result = convert(src, out)
    if not result:
        result = identicon(repo, out)

    try:
        with open(stamp, "w") as f:
            f.write(want)
    except OSError:
        pass

    if result:
        try:
            os.chmod(result, 0o644)   # readable by the notification service
        except OSError:
            pass
        print(result)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
