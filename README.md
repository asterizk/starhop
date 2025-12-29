![Example image created by StarHop](docs/2021-05-08.png)

# StarHop

Sets your Mac's desktop to the current [NASA Astronomy Photo of the Day](https://apod.nasa.gov/apod/), including explanation text overlaid onto the image.

---

## Requirements

- **Python 3.9+** (3.11+ recommended)
- **LaunchControl** (required to manage the LaunchAgent and use **fdautil** for permissions assistance; installation is 
free — registration/purchase is **not** required)

> Why LaunchControl? macOS privacy settings (Files & Folders / Full Disk Access / Automation) must be explicitly
> approved by the user. **LaunchControl** includes `fdautil`, which helps surface and guide those approvals for
> Python/Finder so the wallpaper updates can run unattended. You only need LaunchControl installed for this — 
> **you do not need to register or purchase it**. Note, to install `fdautil` application, click **LaunchControl** >
> **Settings...** > **Utilities** > **fdautil** > **Install**, then follow the on-screen prompts to do two things: (1) Allow
> LaunchControl to run in the background and (2) grant fdautil Full Disk Access. These two settings allow 
> StarHop set the wallpaper while the computer is unattended.

---

## Quick Start (macOS)

### 🖱️ Double-click install
1. Download or clone this project.
2. Double-click **StarHop Install.app**.
   - If Python 3 isn’t installed, a browser window will open to python.org.
   - If LaunchControl isn’t installed, you’ll be guided to install it.
   - On first run, a private Python environment (`.venv`) is created automatically and required packages are installed.
   - The LaunchAgent is auto-configured and loaded so the wallpaper updates run automatically.
   - A dialog will guide you to grant permissions via **LaunchControl → fdautil** (cannot be auto-granted).

---

## Uninstall

1. Double-click **StarHop Uninstall.app**.
   - Unloads and removes the LaunchAgent (if loaded).
   - Always removes the local `.venv` environment.
   - Leaves your project folder intact.

---

# Notes
 - Captioned APOD images can be found at `~/Pictures/StarHop/`
 - A work in progress! If something doesn't look right, please [browse the existing issues](https://github.com/asterizk/starhop/issues) or [file a new one](https://github.com/asterizk/starhop/issues/new)

# TODO
 - Create a lighter region under textbox to make it more readable in event of a busy background

# Feature ideas
 - Option to turn off captions

# Credits
 - Inspired by Harold Bakker's "Astronomy Picture Of the Day to Desktop" utility -- https://web.archive.org/web/20200221005113/http://www.haroldbakker.com/personal/apod.php
