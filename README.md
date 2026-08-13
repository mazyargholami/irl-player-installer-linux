# IRL Player — Linux kiosk installer

Turns a device into a dedicated fullscreen IRL Player screen. The app boots
straight into fullscreen on the top layer with no desktop, no taskbar, no
screensaver, no notifications — nothing can appear over it. If the app
crashes, systemd restarts it within 3 seconds.

**Website / help guide:** https://mazyargholami.github.io/irl-player-installer-linux/

## Install (one line, run on the device)

```bash
curl -fsSL https://mazyargholami.github.io/irl-player-installer-linux/install.sh | sudo bash
```

The installer detects the device and architecture and picks the right package
from `packages/`. Currently supported:

| Architecture | Device | Package |
|---|---|---|
| `arm64` | Raspberry Pi 3 / 4 / 5 / Zero 2 W (Raspberry Pi OS 64-bit, Lite or Desktop) | `packages/irl-player_1.2.5_arm64.deb` |

## Repository layout

```
├── index.html                        website: install / uninstall / help guide
├── install.sh                        one-line installer (arch-aware)
├── uninstall.sh                      one-line uninstaller
├── packages/                         one .deb per architecture & version
│   └── irl-player_1.2.5_arm64.deb
└── .github/workflows/deploy-pages.yml   auto-deploys the website to GitHub Pages
```

## Serving from GitHub (no server needed)

The deploy workflow publishes the repo to **GitHub Pages** on every push to
`main`. The Pages site serves everything users need:

```
https://mazyargholami.github.io/irl-player-installer-linux/            ← website / guide
https://mazyargholami.github.io/irl-player-installer-linux/install.sh  ← installer
https://mazyargholami.github.io/irl-player-installer-linux/uninstall.sh
https://mazyargholami.github.io/irl-player-installer-linux/packages/…  ← .deb packages
```

One-time setup after pushing to GitHub:

1. Open the repo on GitHub → **Settings → Pages**
2. Under **Build and deployment → Source**, choose **GitHub Actions**
3. Push to `main` (or run the *Deploy website to GitHub Pages* workflow
   manually) — the site goes live at the URL above

Every later push to `main` redeploys the website automatically. Users open
the website, copy the install command, and run it — nothing else to host.

> **Note:** Pages on a free GitHub account requires the repo to be
> **public**. (Private repo + Pages needs GitHub Pro / Team.)

## Releasing a new version

1. Drop the new package into `packages/` — the file name must be
   `irl-player_<version>_<arch>.deb`
2. In `install.sh`, bump `VERSION="..."`
3. Commit and push

Re-running the one-line installer on a device upgrades it in place.

### Adding a new architecture (e.g. x86)

1. Add the build, e.g. `packages/irl-player_1.2.5_amd64.deb`
2. In `install.sh`, extend `SUPPORTED_ARCHS="arm64 amd64"`
3. Commit and push — the installer picks the right package automatically.
   (The Raspberry Pi hardware check only applies to `arm64`; other
   architectures just need a Debian-based 64-bit OS.)

## Hosting on your own server instead (optional)

Upload the repo contents (scripts + `packages/`) to any static web folder and
either edit `BASE_URL` at the top of `install.sh` or pass it at install time:

```bash
curl -fsSL https://YOUR_SERVER/irl-player/install.sh | sudo IRL_BASE_URL=https://YOUR_SERVER/irl-player bash
```

## How it works

1. **Device detection** — refuses to run on unsupported hardware:
   architecture must have a build in `packages/`, and `arm64` additionally
   requires `/proc/device-tree/model` to identify a Raspberry Pi.
2. **Package install** — installs the `.deb` with `apt`, which pulls in its
   dependencies (`libgtk-3-0`, `libmpv`, etc.).
3. **Kiosk compositor** — installs [cage](https://github.com/cage-kiosk/cage),
   a Wayland compositor that runs exactly one application, maximized,
   permanently on top. There is no desktop underneath and no way for another
   window to cover it.
4. **systemd services** —
   - `irl-player-kiosk.service` runs cage + IRLPlayer as a dedicated
     unprivileged `irlplayer` user directly on tty1 (replacing the console
     login). `Restart=always` keeps it alive; console blanking is disabled so
     the screen stays on 24/7.
   - `irl-player-hotkey.service` watches raw keyboard input for the
     layer-toggle hotkey.

## Hotkey: on top ↔ normal

The player is **on top by default** (on boot and after install). With a
keyboard plugged into the device:

- **Ctrl+Alt+P** — toggle between kiosk mode (fullscreen, on top) and the
  normal layer (regular console login, or the desktop if one is installed).
  Press it again to put the player back on top.

The hotkey is global — it works from raw input events, so it responds no
matter what is currently on screen. Without a keyboard attached, nothing can
interrupt the player.

## Managing the player

```bash
sudo systemctl status irl-player-kiosk    # is it running?
journalctl -u irl-player-kiosk -f         # live logs
sudo systemctl restart irl-player-kiosk   # restart the app
sudo systemctl stop irl-player-kiosk      # stop (frees tty1 until reboot)
sudo irl-kiosk-toggle                     # same as pressing Ctrl+Alt+P
```

## Uninstall

```bash
curl -fsSL https://mazyargholami.github.io/irl-player-installer-linux/uninstall.sh | sudo bash
```

Removes the services, the hotkey, the package and the kiosk user. If the
device originally booted to a desktop, re-enable it with
`sudo systemctl enable --now lightdm`.

## Troubleshooting

- **Black screen after install** — check `journalctl -u irl-player-kiosk -e`.
  Most common cause is a 32-bit OS image; the app requires a 64-bit OS.
- **No audio** — the service runs outside a desktop session, so audio goes
  through ALSA directly. On a Pi, pick the output via `sudo raspi-config` →
  System Options → Audio.
- **Mouse cursor visible** — the cursor only renders when a pointer device is
  attached and moved; unplug the mouse on deployed screens.
- **Locked out with no keyboard** — SSH in and
  `sudo systemctl stop irl-player-kiosk`, or power-cycle; it recovers cleanly.
