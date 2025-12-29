#!/usr/bin/env python3
"""
StarHop overlays today's NASA APOD image + explanation (or video thumbnail when needed).

Usage examples:
  NASA_APOD_KEY=YOURKEY python3 apodgrab_api.py
  python3 apodgrab_api.py --api-key YOURKEY

This preserves your captioning + macOS wallpaper behavior from the old script.
"""
from __future__ import annotations

# stdlib
import argparse
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from typing import Dict, Optional

# third‑party
from PIL import Image, ImageFont, ImageDraw  # pip install pillow

if sys.version_info < (3, 9):
    sys.exit("This app needs Python 3.9 or newer. Please install Python 3 from python.org.")

API_BASE = "https://api.nasa.gov/planetary/apod"
KEY_FILE = os.path.expanduser("~/Library/Application Support/StarHop/nasa_apod_key")

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

def text_wrap(text, font, writing, max_width, max_height):
    def _dims(s):
        l, t, r, b = writing.multiline_textbbox((0, 0), s, font=font)
        return (r - l, b - t)

    def _composed():
        return '\n'.join(' '.join(line) for line in lines if line)

    lines = [[]]
    words = text.split()
    for word in words:
        # try putting this word in last line then measure
        lines[-1].append(word)
        w, h = _dims(_composed())
        if w > max_width:
            moved = lines[-1].pop()
            lines.append([moved])
            w, h = _dims(_composed())
            if h > max_height:
                lines.pop()
                lines[-1][-1] += '...'
                while True:
                    w, h = _dims(_composed())
                    if w <= max_width or len(lines[-1]) == 1:
                        break
                    lines[-1].pop()
                    lines[-1][-1] += '...'
                break
    return '\n'.join([' '.join(line) for line in lines])


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
def build_apod_url(api_key: str) -> str:
    # thumbs=true provides a thumbnail when media_type is "video".
    qs = urllib.parse.urlencode({
        "api_key": api_key,
        "thumbs": "true",
        # date param omitted => today's APOD
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


# ----------------------------- Main flow -----------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Get today's APOD via NASA API and set as macOS wallpaper with caption."
    )
    parser.add_argument(
        "--api-key",
        dest="api_key",
        default=None,  # no default → must resolve via env/file/flag
        help="NASA API key (overrides env/file)"
    )
    parser.add_argument("--no-wallpaper", action="store_true",
                        help="Skip setting macOS wallpaper; just save the captioned image")
    args = parser.parse_args()

    api_key = resolve_api_key(args.api_key)

    if api_key.upper() == "DEMO_KEY":
        sys.exit("DEMO_KEY is not allowed. Please supply your personal NASA API key.")

    # Redact the key in logs
    def _mask(k: str) -> str:
        return f"{k[:4]}…{k[-4:]}" if len(k) >= 8 else "****"

    url = build_apod_url(api_key)
    print(f"Fetching: {API_BASE}?api_key={_mask(api_key)}&thumbs=true")
    apod = fetch_json(url)

    # Basic fields per API
    title = apod.get("title", "Astronomy Picture of the Day")
    explanation = apod.get("explanation", "")
    media_type = apod.get("media_type")
    apod_date = apod.get("date")

    image_url = pick_image_url(apod)
    if not image_url:
        raise SystemExit(f"No downloadable image URL found for media_type={media_type!r} on {apod_date}.")

    # Download image to temp file
    with urllib.request.urlopen(image_url) as response:
        with tempfile.NamedTemporaryFile(delete=False) as tmp_file:
            shutil.copyfileobj(response, tmp_file)
            tmp_path = tmp_file.name

    # Compose caption on image
    bg = Image.open(tmp_path)
    writing = ImageDraw.Draw(bg)

    # Smaller factor = smaller text.
    title_font_size_factor = 0.020
    desc_font_size_factor = 0.015
    title_font_size = int(bg.width * title_font_size_factor)
    desc_font_size = int(bg.width * desc_font_size_factor)

    # Swap to a safe default font if missing
    def _load_font(name: str, size: int, fallback: str = "Arial.ttf"):
        try:
            return ImageFont.truetype(name, size=size)
        except Exception:
            try:
                return ImageFont.truetype(fallback, size=size)
            except Exception:
                return ImageFont.load_default()

    title_font = _load_font("Arial Black.ttf", title_font_size)
    desc_font = _load_font("Arial Narrow Italic.ttf", desc_font_size)

    # The dimensions of the text box are a factor of the source image
    explanation_wrapped = text_wrap(
        explanation,
        desc_font,
        writing,
        int(bg.width * 0.25),
        int(bg.height * 0.7),
    )

    # write title and explanation
    writing.text((int(bg.width * 0.02), int(bg.height * 0.05)), title, font=title_font)

    # The offset of the text box from the upper left corner is a factor of the source image dimensions
    writing.text((int(bg.width * 0.05), int(bg.height * 0.11)), explanation_wrapped, font=desc_font)

    # Save to ~/Pictures/apod/<today>.png
    os.makedirs(os.path.expanduser('~/Pictures/apod'), exist_ok=True)
    today = date.today()
    out_path = os.path.expanduser(f"~/Pictures/apod/{today}.png")
    bg.save(out_path)

    print('Saved captioned image to:', out_path)

    if not args.no_wallpaper and sys.platform == "darwin":
        print('Setting the new desktop picture:', out_path)
        set_wallpaper_macos_all(out_path)  # apply scaling/bg to current Space
    elif not args.no_wallpaper:
        print("Non-macOS platform detected; skipping wallpaper step.")


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
