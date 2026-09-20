# IRL Player — Linux kiosk installer

Turns a device into a dedicated fullscreen IRL Player screen. The app boots
straight into fullscreen on the top layer with no desktop, no taskbar, no
screensaver, no notifications — nothing can appear over it. If the app
crashes, systemd restarts it within 3 seconds.

**Website / help guide:** https://linux-player.theirlnetwork.com/

## Install (one line, run on the device)

```bash
curl -fsSL https://linux-player.theirlnetwork.com/install.sh | sudo bash
```

The installer detects the platform (hardware + OS) and picks that platform's
player package from `packages/`. Anything it cannot map to a supported
platform is refused **before the system is touched**, with a message that
says what was detected and what is supported (the website lists the same
platforms, read live from the installer). Currently supported:

| Platform id | Devices | Operating system | Package |
|---|---|---|---|
| `rpi-arm64` | Raspberry Pi CM5, Pi 5, 4, 3, Zero 2 W | Raspberry Pi OS 64-bit (Lite or Desktop) | `packages/irl-player_1.2.8_arm64.deb` |

Every platform has its own player package — two platforms never share one.
The list is the `SUPPORTED_PLATFORMS` block at the top of `install.sh`; see
[Adding a platform](#adding-a-platform).

## Repository layout

```
├── index.html                        website: install / uninstall / help guide
├── install.sh                        one-line installer (platform-aware)
├── uninstall.sh                      one-line uninstaller
├── packages/                         one .deb per platform & version
│   └── irl-player_1.2.8_arm64.deb
└── .github/workflows/deploy-pages.yml   auto-deploys the website to GitHub Pages
```

## Serving from GitHub (no server needed)

The deploy workflow publishes the repo to **GitHub Pages** on every push to
`main`. The Pages site serves everything users need:

```
https://linux-player.theirlnetwork.com/            ← website / guide
https://linux-player.theirlnetwork.com/install.sh  ← installer
https://linux-player.theirlnetwork.com/uninstall.sh
https://linux-player.theirlnetwork.com/packages/…  ← .deb packages
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

## Custom domain

The site is served on **`linux-player.theirlnetwork.com`** — a free GitHub
Pages custom domain (GitHub also issues the HTTPS certificate for free).
This is how it is configured:

1. DNS (at the `theirlnetwork.com` DNS provider): a `CNAME` record
   `linux-player` → `mazyargholami.github.io`
2. On GitHub: **Settings → Pages → Custom domain** → enter
   `linux-player.theirlnetwork.com` and save. Wait for the DNS check to
   pass, then tick **Enforce HTTPS** (appears once the certificate is
   issued, usually within minutes).

All URLs in `install.sh`, `index.html` and this README use the custom
domain. The old `mazyargholami.github.io/irl-player-installer-linux/...`
URLs keep working — GitHub redirects them to the custom domain — so
devices installed before the switch are unaffected.

## Releasing a new version

1. Drop the new package into `packages/` — the file name must be
   `irl-player_<version>_<arch>.deb`
2. In `install.sh`, bump `VERSION="..."` (and `INSTALLER_REV`)
3. Commit and push

**That's it — devices update themselves.** Every installed device checks the
published `install.sh` on boot and every hour (see
[Auto-update](#auto-update) below) and reinstalls when it changes.
Re-running the one-line installer by hand also still upgrades in place.

The website footer reads `INSTALLER_REV` and `VERSION` live from the
published `install.sh` (and verifies the matching `.deb` exists in
`packages/`, showing "package missing!" if it doesn't), so it always shows
what's actually deployed — nothing to update by hand there.

## Auto-update

The installer sets up a systemd timer (`irl-player-update.timer`) on every
device that:

1. Fetches `https://linux-player.theirlnetwork.com/install.sh` on boot and
   then hourly (with a random 0–10 min delay so devices don't all hit the
   server at once)
2. Compares its SHA-256 hash to the hash of the script the device was last
   installed with (`/etc/irl-player/installer.sha256`)
3. If **anything** in the script changed — new app version, service config
   fix, new hotkey, whatever — it re-runs the fresh script, which upgrades
   the device in place and briefly restarts the player

This also covers **removals**: the installer keeps a manifest of every file
it created (`/etc/irl-player/manifest`). On each run, anything the previous
install created that the current script no longer lists in `MANAGED_FILES`
is disabled and deleted. So adding a service rolls it out everywhere, and
deleting one from `install.sh` (remember to drop it from `MANAGED_FILES`
too) removes it from every device on its next update.

If nothing changed, the check exits without touching anything, so playback
is never interrupted by a no-op check. If the device is offline the check
just retries next hour.

What a reinstall does on the device (rev ≥ 34): refreshes packages
(installing any dependency the new script added — apt is the first step, so
an offline or apt-broken device aborts before a single file is touched and
keeps running the old revision), rewrites every helper script and unit,
restarts the freeze and network watchdogs so their new code runs
immediately instead of at the weekly reboot (their state is on disk, so
nothing is lost), and restarts the player once — a few seconds of black
screen. No reboot. The helper scripts are replaced **atomically** (temp
file + rename): the updater is itself one of those scripts and is running
while it is replaced, and an in-place rewrite once made the old copy
execute the tail of the new file (rev 32). Never write a managed script
with `cat >` — the e2e suite checks for it.

**Failed updates are reported, not hidden.** If a reinstall aborts, the
failing line is recorded in `/var/lib/irl-player/last-update-error`, the
stored hash is left alone (so the device retries every hour), and the
device posts to the fleet panel right away — the panel shows
`last_update_error` (e.g. `rev 34 line 131: apt-get update -qq`) until a
later run succeeds, which stamps `/var/lib/irl-player/last-update-ok`
instead (reported as `last_update_ok_at`). A successful update posts
immediately too, so the panel shows the new revision within seconds.

**Degraded updates are reported too (rev 35).** Some steps are allowed to
fail without aborting the run — an optional package (grim, wlr-randr,
unclutter, unattended-upgrades), the gateway's Python venv, a timer that
would not enable. Each such failure is logged *and* recorded as a line in
`/var/lib/irl-player/last-update-warnings`, which the device sends as
`last_update_warnings` (a list, `[]` after a clean run). The update still
counts as applied, so the panel can show the device as degraded rather than
green or red. Only steps whose failure actually costs something are
warnings: the `xcursor-transparent-theme` package no longer exists on
current Raspberry Pi OS, so its absence is a plain log line (rev 36) —
unclutter hides the cursor on its own. And if a reinstall never returns at
all (a reboot or power loss mid-run), the updater notices its own leftover
marker on the next hourly check and records `rev ? reinstall interrupted`
as the update error.

```bash
sudo systemctl list-timers irl-player-update.timer   # when is the next check?
journalctl -u irl-player-update -e                   # update logs
sudo irl-update                                      # force a check right now
```

> Devices installed before auto-update existed just need the one-line
> installer re-run once by hand; from then on they self-update.

### Adding a platform

`install.sh` is one script for every platform (rev 37): a platform layer at
the top maps the device to an id and holds the per-platform differences;
everything else is shared. To add one:

1. Build its player package and add it as `packages/irl-player_<version>_<tag>.deb`
   — a file of its own, never shared with another platform.
2. Add one line to the `SUPPORTED_PLATFORMS` block:
   `<id>|<dpkg arch>|irl-player_<version>_<tag>.deb|<devices>|<operating system>`.
   The website lists the devices and OS from this line and checks the
   package exists, so keep the format.
3. Add a case to `detect_platform()` that recognises it (arch, OS id and
   device model / DMI product name are available).
4. Override only the hooks it needs, as `platform_<id>_<step>()` functions
   (with `-` in the id written `_`): `console_blanking`, `apt_origins`,
   `hardware_watchdog`. A platform with no override gets the default hook
   (or nothing, for `console_blanking`).
5. If the platform has no Raspberry Pi serial, extend `irl-device-serial`
   (the one helper every fetcher uses) — and agree the format with the
   config panel first, since it keys every device on that value.
6. Extend the e2e suite with a fixture for the platform, mark one device of
   it as a canary, and bump `INSTALLER_REV`.

The e2e suite asserts every registry line has five fields, a unique id, a
unique package that exists for the current `VERSION`, and that an unknown
platform is refused with nothing written.

## Hosting on your own server instead (optional)

Upload the repo contents (scripts + `packages/`) to any static web folder and
either edit `BASE_URL` at the top of `install.sh` or pass it at install time:

```bash
curl -fsSL https://YOUR_SERVER/irl-player/install.sh | sudo IRL_BASE_URL=https://YOUR_SERVER/irl-player bash
```

## How it works

1. **Platform detection** — maps the device (dpkg architecture, device-tree
   model or DMI product name, OS id) to an id in `SUPPORTED_PLATFORMS`, and
   refuses anything else before touching the system: it prints a
   `Detected: arch=… model=… os=…` line plus the supported list. A 32-bit
   OS on a Pi gets a "reinstall 64-bit" hint. On an already-installed device
   the refusal is recorded as an update error so the panel shows it.
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
   - `irl-player-update.timer` checks the published `install.sh` hourly and
     reinstalls when it changes (see [Auto-update](#auto-update)).
   - `irl-player-watchdog.service` self-heals freezes and
     `irl-player-netwatch.service` self-heals a dead connection (see
     [Self-healing](#self-healing)).

## Self-healing

Crashes were always covered (`Restart=always` brings the app back in 3
seconds). The watchdog adds coverage for **freezes** — process alive, picture
stuck:

1. Every 30 s it grabs a tiny screenshot (`grim`, as the kiosk user) and
   hashes it. Playing video always changes pixels, so a screen that is
   pixel-identical for **5 minutes** means the player is frozen.
2. First response: restart `irl-player-kiosk` (up to 3 times). The restart
   counter only clears after the screen has been changing again for a full
   5 minutes, so a brief flicker between re-freezes doesn't reset the ladder.
3. If 3 restarts didn't help: **reboot the device** — at most once every
   2 hours (timestamp in `/var/lib/irl-player/last-watchdog-reboot`).
4. **Static-page brake**: the hash the watchdog rebooted for is remembered
   (`/var/lib/irl-player/last-reboot-hash`). If the screen after the reboot
   is pixel-identical, the picture is a static page a reboot can't cure
   (e.g. the "Pair this screen" QR) — reboots slow to **once a day** so an
   unpaired device doesn't grind itself down; restarts continue, and a real
   freeze (different picture) keeps the normal 2-hour ladder.
5. A hardware watchdog (`RuntimeWatchdogSec=15` — the Pi's built-in watchdog
   chip) force-reboots the device if the whole OS ever locks up.

If the screen can't be captured (no `grim`, no Wayland socket), the watchdog
does nothing — it never acts on a guess. When the kiosk is intentionally
stopped (Ctrl+Alt+P, manual stop) it stands down. Every action it takes is
logged: `journalctl -u irl-player-watchdog`.

A second watchdog covers a stuck **connection** (`irl-player-netwatch`):
10 minutes with no internet → restart networking (NetworkManager, dhcpcd,
or a raw Wi-Fi interface bounce), then again every 30 minutes until the
connection returns. It **never reboots** (since rev 29): a screen that lost
its internet keeps looping the ads it already has, and a reboot would only
interrupt that. Whether an offline screen gets rebooted is the community
manager's decision, made from the config panel (see
[Fleet panel: telemetry and commands](#fleet-panel-telemetry-and-commands)).
The watchdog records the outage for the panel instead:
`/var/lib/irl-player/offline-since` while offline,
`/var/lib/irl-player/last-offline` (`<start> <end>`) once back. Logs:
`journalctl -u irl-player-netwatch`.

A **weekly scheduled reboot** (`irl-player-reboot.timer`, Sunday 04:00 local,
30 min jitter) applies downloaded OS updates and re-arms any timer that
got stuck. It is skipped while the device is offline (`ExecCondition=
irl-netwatch --online`) for the same reason — an offline venue is never
reset automatically; the reboot simply happens the next Sunday it is online.

The OS underneath stays patched too: `unattended-upgrades` applies security
updates via the standard apt-daily timers (no automatic reboots), with
`irl-player` blacklisted so app versions are controlled exclusively by
`irl-update`. To keep a small eMMC healthy over years, downloaded update
archives are pruned weekly (`AutocleanInterval`) and the systemd journal is
**persistent and capped**: 100 MB on disk in 16 MB files, oldest dropped
first (`/etc/systemd/journald.conf.d/irl-player.conf`, `Storage=persistent`,
`/var/log/journal` created by the installer). Logs survive reboots and power
cuts, so an outage or a failed update can be read afterwards with
`journalctl -b -1` — a Lite image otherwise logs to RAM and loses everything
at every boot.

## Fleet panel: telemetry and commands

Every device posts a small health snapshot (`irl-telemetry`,
`irl-player-telemetry.timer`) to the self-hosted config panel on boot and
**every 5 minutes**: identity (serial, `platform` id, model, OS), versions,
CPU temperature, throttling, disk,
memory, Wi-Fi, `uptime_s` / `boot_time`, the last outage window recorded
by the network watchdog (`last_offline_start` / `last_offline_end`), the
attached **display(s)** (`displays`: connector, the resolution and refresh
the compositor is driving, the panel's native mode, physical size and
diagonal, and the make / model from the EDID; plus a flat
`screen_resolution` such as `1024x600` — re-read every post, so a swapped
monitor shows up within 5 minutes), and the **outcome of the last update**
(`last_update_ok_at`, `last_update_error` / `last_update_error_at`, and
the tolerated failures of that run in `last_update_warnings`, see
[Auto-update](#auto-update)). The panel calls a screen **down** after 15
silent minutes and shows how long it has been down, so the community
manager can call the venue instead of the device guessing.
`sudo irl-telemetry --print` shows the exact payload a device would send.

The panel's reply is the fleet's **command channel**: it may carry
`{"commands": [{"id": "...", "type": "reboot" | "restart-kiosk"}]}` queued
by the community manager's *Reboot device* / *Restart player* buttons. The
device runs each id exactly once (executed ids in
`/var/lib/irl-player/commands-done`), reports it back as `acked_commands` in
its next post, and the panel keeps re-sending an id until it is acked or
expires (24 h). A click lands within about 5 minutes on an online device; a
screen with no internet cannot receive it — that is the point. Only those
two verbs exist; nothing in the reply is ever executed as-is.

## Canary rollout

New releases don't hit the whole fleet at once:

- A device marked with `sudo touch /etc/irl-player/canary` (e.g. the one on
  your desk) applies every new `install.sh` **immediately** on its next
  hourly check.
- Every other device notes the new version and waits `FLEET_DELAY_HOURS`
  (default 24, set at the top of `install.sh`) before applying it. If the
  published script changes again during the wait — e.g. you pushed a fix —
  the clock restarts on the new version.
- **Urgent fix for everyone right now:** publish the fix with
  `FLEET_DELAY_HOURS=0`. Devices read the value from the *new* script, so
  the whole fleet applies it on the next check. (Set it back to 24 in the
  release after.)

## IRL Gateway (ESP32 bridge)

Every player also ships `irl-gateway` (`/opt/irl-gateway/`): plug an IRL
master board (ESP32) into the device's USB port and the gateway bridges the
whole ESP32 fleet to the MQTT broker — see
https://powercast.theirlnetwork.com/ for preparing boards. The service is
installed everywhere, needs no configuration on the device, and idles
harmlessly when no board is attached.

The broker credentials (`mqtt.json`) are **not stored in this repo at
all**. The service's `ExecStartPre` runs `irl-gateway-config`, which
fetches the config over HTTPS from the fleet config panel (identifying
the device by its hardware serial) and writes
`/opt/irl-gateway/mqtt.json` (root-only, mode 600). The device keeps the
last good copy, so an offline boot or a config-service outage never stops
a previously-configured gateway; a device that has never been served (not
approved yet, or offline on first start) retries gently until it is. The
unit's `RuntimeMaxSec=1d` restarts the gateway daily, so a rotated config
or fresh approval takes effect within a day on its own (or instantly with
`sudo systemctl restart irl-gateway`).

### The fleet config panel

Devices fetch from the self-hosted config panel:

```
https://iot-config.theirlnetwork.com/mqtt-config?serial=<device-serial>
```

Approved device → HTTP 200 with the config JSON; pending/rejected →
`403 not approved`; any other path → 404. **The source and its own docs
live in the `irl-microcontroller` repo (`config-panel/`)** — Django +
Docker Compose, running behind Cloudflare's proxy.

Day-to-day operation happens in the panel's web UI at
https://iot-config.theirlnetwork.com/ :

- **Approving a device:** an unknown serial auto-registers as *pending*
  the first time it asks (unapproved devices retry about once a minute,
  so a new device appears within a minute of powering on). Open the
  panel, find it in the pending list, click **Approve** — it gets served
  on its next retry. Nothing is ever done on the device itself. A
  device's serial: `sudo irl-device-serial` (the one helper telemetry and
  the gateway config fetch both use; on a Pi it is the `Serial` line of
  `/proc/cpuinfo`).
- **Rejecting** keeps stray/unknown serials out of the pending list.
- **Rotation:** edit the config JSON in the panel. Devices re-fetch at
  every gateway start and auto-restart daily, so every approved device
  has the new credential **within 24 hours** (instant per device with
  `sudo systemctl restart irl-gateway`). For a zero-downtime broker
  rotation, overlap: add the new credential on the broker while the old
  one still works → update the panel → wait a day → remove the old
  credential from the broker. No device ever loses its connection.
- **Revoking a device:** set it to rejected **and** rotate the
  credential — the device keeps its cached copy until the rotation makes
  it worthless.

(History: the config service was previously a Cloudflare Worker at
`config.theirlnetwork.com` — retired after the fleet converged on the
panel; see git history of this section for its setup if ever needed
again.)

## Continuous integration

`.github/workflows/tests.yml` runs the full e2e suite on every PR and every
push to `main` — a change that breaks the installer can't be merged without
a red ❌ first.

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
sudo irl-telemetry --print                # what the device reports to the panel
journalctl -b -1 -u irl-player-update     # update log from the previous boot (journal is persistent)
```

## Uninstall

```bash
curl -fsSL https://linux-player.theirlnetwork.com/uninstall.sh | sudo bash
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
- **Mouse cursor or app title bar visible** — fixed by re-running the
  installer: the cursor is hidden by unclutter (plus a transparent cursor
  theme where the OS still ships one), and the app runs on the X11 backend
  where it draws no title bar.
- **Locked out with no keyboard** — SSH in and
  `sudo systemctl stop irl-player-kiosk`, or power-cycle; it recovers cleanly.
