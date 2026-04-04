#!/usr/bin/env python3
"""
StarHop overlays today's NASA APOD image + explanation (or video thumbnail when needed).

Usage examples:
  NASA_APOD_KEY=YOURKEY python3 starhop.py
  python3 starhop.py --api-key YOURKEY

This preserves your captioning + macOS wallpaper behavior from the old script.
"""
from __future__ import annotations
from pathlib import Path

# stdlib
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from typing import Dict, Optional

# --- font loader (with a clear search path + one-time debug print) ---
from functools import lru_cache

# third‑party
from PIL import Image, ImageFont, ImageDraw  # pip install pillow

if sys.version_info < (3, 9):
    sys.exit("This app needs Python 3.9 or newer. Please install Python 3 from python.org.")

API_BASE = "https://api.nasa.gov/planetary/apod"
KEY_FILE = os.path.expanduser("~/Library/Application Support/com.krishengreenwell.StarHop/nasa_apod_key")

def resolve_api_key(cli_value: Optional[str]) -> str:
    # 1) CLI flag wins if provided
    key = (cli_value or "").strip()
    if key:
        return key

    # 2) Environment
    key = os.environ.get("NASA_APOD_KEY", "").strip()
    if key:
        return key

    # 3) Key file from installer
    try:
        with open(KEY_FILE, "r", encoding="utf-8") as fh:
            key = fh.read().strip()
            if key:
                return key
    except FileNotFoundError:
        pass

    # No key found → fail fast with guidance
    sys.exit(
        "NASA API key is required. Re-run the installer to save your key, "
        "or pass --api-key/ NASA_APOD_KEY."
    )

# ----------------------------- Text wrapping -----------------------------
# Given a font, wrap text into a given set of dimensions
#   see https://stackoverflow.com/a/62418837

def wrap_to_box(draw: ImageDraw.ImageDraw, text: str, base_pt: int,
                box_w: int, box_h: int, font_candidates: list[str],
                line_gap_px: int = 4) -> tuple[str, "ImageFont.FreeTypeFont", bool]:
    """
    Returns (wrapped_text, font, fully_fit) that fits in (box_w x box_h). Uses
    draw.textlength for width and shrinks the font size if total height would overflow.
    """
    words = clean_text(text).split(" ")

    def layout(pt: int):
        f = load_font_chain(pt, font_candidates)
        asc, desc = f.getmetrics()
        line_h = asc + desc + line_gap_px
        lines, line, h = [], "", 0
        consumed_all_words = True
        for idx, w in enumerate(words):
            candidate = w if not line else f"{line} {w}"
            if draw.textlength(candidate, font=f) <= box_w:
                line = candidate
            else:
                if not line:  # a single “word” too long; hard-break with ellipsis
                    for i in range(len(w), 0, -1):
                        if draw.textlength(w[:i] + "…", font=f) <= box_w:
                            line = w[:i] + "…"
                            break
                lines.append(line)
                h += line_h
                line = w
                if h + line_h > box_h:
                    consumed_all_words = False
                    break
        if line and h + line_h <= box_h:
            lines.append(line)
            h += line_h
        elif line:
            consumed_all_words = False

        if consumed_all_words and line:
            consumed_all_words = idx == len(words) - 1

        return lines, h, f, consumed_all_words

    for pt in range(base_pt, max(9, base_pt - 40), -1):
        lines, total_h, f, fully_fit = layout(pt)
        if lines and total_h <= box_h:
            return "\n".join(lines), f, fully_fit

    lines, _, f, fully_fit = layout(max(9, base_pt - 40))
    return "\n".join(lines), f, fully_fit


# ----------------------------- macOS wallpaper -----------------------------
def set_wallpaper_macos_all(image_path: str):
    """
    1) Set the wallpaper on ALL desktops (all monitors/spaces) via System Events.
    2) Style the active Space via AppKit: Fit-to-Screen, no clipping, black background.
    """
    import subprocess  # local import so Linux/Windows users can still run

    path = os.path.abspath(image_path)
    safe_path = path.replace('"', '\\"')  # escape double-quotes for AppleScript

    # --- Step 1: AppleScript (all desktops / all displays) ---
    ascript = (
        'tell application "System Events"\n'
        f'  set p to "{safe_path}"\n'
        '  set ds to a reference to every desktop\n'
        '  repeat with d in ds\n'
        '    set picture of contents of d to p\n'
        '    delay 0.1\n'
        '  end repeat\n'
        'end tell'
    )
    try:
        subprocess.run([
            "/usr/bin/osascript", "-e", ascript
        ], check=True, text=True, capture_output=True)
        print("Wallpaper image applied to all desktops (AppleScript).")
    except subprocess.CalledProcessError as e:
        print("AppleScript step failed; continuing:", e.stderr or e.stdout or repr(e))

    # --- Step 2: PyObjC styling (current Space only) ---
    try:
        from AppKit import (
            NSWorkspace, NSScreen, NSColor,
            NSWorkspaceDesktopImageScalingKey,
            NSWorkspaceDesktopImageAllowClippingKey,
            NSWorkspaceDesktopImageFillColorKey,
            NSImageScaleProportionallyUpOrDown,
        )
        from Foundation import NSURL

        ws = NSWorkspace.sharedWorkspace()
        url = NSURL.fileURLWithPath_(path)
        options = {
            NSWorkspaceDesktopImageScalingKey: NSImageScaleProportionallyUpOrDown,  # "Fit to Screen"
            NSWorkspaceDesktopImageAllowClippingKey: False,                          # don't crop
            NSWorkspaceDesktopImageFillColorKey: NSColor.blackColor(),               # black bars
        }
        for screen in NSScreen.screens():
            ok, err = ws.setDesktopImageURL_forScreen_options_error_(url, screen, options, None)
            if not ok:
                raise RuntimeError(err)
        print("Applied Fit-to-Screen + black background (PyObjC).")
    except Exception as e:
        print("PyObjC styling step skipped/fell back:", repr(e))


# ----------------------------- APOD API helpers -----------------------------
def build_apod_url(api_key: str, date_override: Optional[str] = None) -> str:
    qs = urllib.parse.urlencode({
        "api_key": api_key,
        "thumbs": "true",
        **({"date": date_override} if date_override else {}),
    })
    return f"{API_BASE}?{qs}"



def fetch_json(url: str, retries: int = 3, backoff: float = 1.5) -> Dict:
    last_err: Optional[Exception] = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url) as resp:
                payload = resp.read()
            return json.loads(payload)
        except urllib.error.HTTPError as e:
            # Handle 429 rate-limit, 5xx transient issues with backoff
            if e.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                sleep_for = backoff ** attempt
                print(f"HTTP {e.code}; retrying in {sleep_for:.1f}s...")
                time.sleep(sleep_for)
                continue
            raise
        except Exception as e:
            last_err = e
            if attempt < retries - 1:
                sleep_for = backoff ** attempt
                print(f"Error '{e}'; retrying in {sleep_for:.1f}s...")
                time.sleep(sleep_for)
                continue
            raise last_err
    assert False, "unreachable"


def pick_image_url(apod: Dict) -> Optional[str]:
    # Prefer HD image, then standard image, then video thumbnail (if present)
    if apod.get("media_type") == "image":
        return apod.get("hdurl") or apod.get("url")
    # media_type might be "video" (e.g., YouTube/Vimeo). With thumbs=true we get thumbnail_url.
    return apod.get("thumbnail_url") or apod.get("url")

@lru_cache(maxsize=None)
def _font_debug(p):  # optional: prints once per resolved path
    print(f"[StarHop] Using font: {p}")
    return p

def _try_truetype(path: Path, size: int) -> ImageFont.FreeTypeFont | None:
    try:
        f = ImageFont.truetype(str(path), size)
        _font_debug(str(path))
        return f
    except Exception:
        return None

def load_font_chain(size_px: int, names: list[str]):
    """
    Try a list of font *file basenames* across common locations:
    - Bundled resources/fonts
    - App Support override
    Falls back to ImageFont.load_default().
    """
    here = Path(__file__).parent
    fonts_pkg = here / "resources" / "fonts"
    fonts_app = Path.home() / "Library/Application Support/com.krishengreenwell.StarHop/fonts"

    search_dirs = [
        fonts_pkg,
        fonts_app,
    ]
    for name in names:
        for d in search_dirs:
            f = _try_truetype(d / name, size_px)
            if f:
                return f
    from PIL import ImageFont
    return ImageFont.load_default()


def clean_text(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip())


TITLE_FONT_CANDIDATES = [
    "ArchivoBlack-Regular.ttf",
    "NimbusSans-Bold.ttf",
]

TITLE_SIZE_FACTOR = 0.020

BODY_FONT_CANDIDATES = [
    "NimbusSansNarrow-Oblique.ttf",
    "NimbusSansNarrow-Regular.ttf",
]

BODY_SIZE_FACTOR = 0.015
BODY_LINE_GAP_FACTOR = 0.3
LANDSCAPE_BODY_WIDTH_FACTORS = [0.25, 0.30, 0.35, 0.40]
PORTRAIT_BODY_WIDTH_FACTORS = [0.30, 0.36, 0.42, 0.48]


def choose_body_layout(draw: ImageDraw.ImageDraw, bg: Image.Image, text: str,
                       base_pt: int, line_gap_px: int,
                       font_candidates: list[str]) -> tuple[str, "ImageFont.FreeTypeFont"]:
    """
    Try a few text-box widths and keep the narrowest one that preserves a
    readable font size. This prevents long captions from collapsing into a thin
    single-word column even on landscape images.
    """
    box_h = int(bg.height * 0.70)
    aspect_ratio = bg.width / bg.height if bg.height else 1
    width_factors = LANDSCAPE_BODY_WIDTH_FACTORS if aspect_ratio >= 1 else PORTRAIT_BODY_WIDTH_FACTORS

    best_full_fit: tuple[str, "ImageFont.FreeTypeFont"] | None = None
    best_partial_fit: tuple[str, "ImageFont.FreeTypeFont"] | None = None
    for width_factor in width_factors:
        box_w = int(bg.width * width_factor)
        wrapped, font, fully_fit = wrap_to_box(
            draw, text, base_pt, box_w, box_h,
            line_gap_px=line_gap_px,
            font_candidates=font_candidates,
        )

        candidate = (wrapped, font)
        if fully_fit:
            if getattr(font, "size", 0) >= max(12, base_pt - 2):
                return candidate
            if best_full_fit is None or getattr(font, "size", 0) > getattr(best_full_fit[1], "size", 0):
                best_full_fit = candidate
            continue

        if best_partial_fit is None or getattr(font, "size", 0) > getattr(best_partial_fit[1], "size", 0):
            best_partial_fit = candidate

    if best_full_fit is not None:
        return best_full_fit
    assert best_partial_fit is not None
    return best_partial_fit

# ----------------------------- Main flow -----------------------------
def main():
    import os, time
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] StarHop run start (pid={os.getpid()})")

    parser = argparse.ArgumentParser(description="Get today's APOD …")
    parser.add_argument("--api-key", dest="api_key", default=None)
    parser.add_argument("--no-wallpaper", action="store_true")
    parser.add_argument("--date", help="APOD date (YYYY-MM-DD)")
    parser.add_argument("--image", help="Use a local image file instead of NASA API")
    parser.add_argument("--title", default="(Test image)")
    parser.add_argument("--text")
    args = parser.parse_args()

    tmp_path = None  # ensure defined for later cleanup

    if args.image:
        # --- Local test mode (no network) ---
        bg = Image.open(args.image).convert("RGB")
        writing = ImageDraw.Draw(bg)
        title = args.title or "(Test image)"
        explanation = args.text or "(no description provided)"
    else:
        # --- Online mode only here ---
        def _mask(k: str) -> str:
            return f"{k[:4]}…{k[-4:]}" if len(k) >= 8 else "****"

        api_key = resolve_api_key(args.api_key)
        if api_key.upper() == "DEMO_KEY":
            sys.exit("DEMO_KEY is not allowed. Please supply your personal NASA API key.")

        url = build_apod_url(api_key, args.date)
        print(f"Fetching: {API_BASE}?api_key={_mask(api_key)}&thumbs=true"
              f"{('&date=' + args.date) if args.date else ''}")
        apod = fetch_json(url)

        title = apod.get("title", "Astronomy Picture of the Day")
        explanation = apod.get("explanation", "")
        media_type = apod.get("media_type")
        apod_date = apod.get("date")

        image_url = pick_image_url(apod)
        if not image_url:
            raise SystemExit(f"No downloadable image URL found for media_type={media_type!r} on {apod_date}.")

        with urllib.request.urlopen(image_url) as response:
            with tempfile.NamedTemporaryFile(delete=False) as tmp_file:
                shutil.copyfileobj(response, tmp_file)
                tmp_path = tmp_file.name

        bg = Image.open(tmp_path).convert("RGB")
        writing = ImageDraw.Draw(bg)

    title_pt = int(bg.width * TITLE_SIZE_FACTOR)
    body_pt = int(bg.width * BODY_SIZE_FACTOR)
    body_line_gap_px = max(4, int(body_pt * BODY_LINE_GAP_FACTOR))

    # Title: Archivo Black with Nimbus Bold fallback
    title_font = load_font_chain(title_pt, TITLE_FONT_CANDIDATES)
    # Body wrapping: prefer Nimbus Narrow body faces
    wrapped, body_font = choose_body_layout(
        writing, bg, explanation, body_pt,
        line_gap_px=body_line_gap_px,
        font_candidates=BODY_FONT_CANDIDATES,
    )
    writing.text(
        (int(bg.width*0.02), int(bg.height*0.05)),
        title,
        font=title_font,
        fill=(255, 255, 255),
    )
    writing.multiline_text((int(bg.width*0.05), int(bg.height*0.11)), wrapped, font=body_font, spacing=body_line_gap_px)

    os.makedirs(os.path.expanduser('~/Pictures/StarHop'), exist_ok=True)
    out_path = os.path.expanduser(f"~/Pictures/StarHop/{date.today()}{'-test' if args.image else ''}.png")
    bg.save(out_path)
    print("Saved captioned image to:", out_path)

    if tmp_path:
        try: os.unlink(tmp_path)
        except Exception: pass

    if not args.no_wallpaper and sys.platform == "darwin":
        print('Setting the new desktop picture:', out_path)
        set_wallpaper_macos_all(out_path)



if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        # Friendlier errors for common API issues
        if e.code == 403:
            sys.exit("HTTP 403: Check your API key (quota or invalid key).")
        if e.code == 429:
            sys.exit("HTTP 429: Rate limited. Try again later or use your own API key.")
        raise
