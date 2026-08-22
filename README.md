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

```bash
sudo systemctl list-timers irl-player-update.timer   # when is the next check?
journalctl -u irl-player-update -e                   # update logs
sudo irl-update                                      # force a check right now
```

> Devices installed before auto-update existed just need the one-line
> installer re-run once by hand; from then on they self-update.

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
4. A hardware watchdog (`RuntimeWatchdogSec=15` — the Pi's built-in watchdog
   chip) force-reboots the device if the whole OS ever locks up.

If the screen can't be captured (no `grim`, no Wayland socket), the watchdog
does nothing — it never acts on a guess. When the kiosk is intentionally
stopped (Ctrl+Alt+P, manual stop) it stands down. Every action it takes is
logged: `journalctl -u irl-player-watchdog`.

A second watchdog covers a stuck **connection** (`irl-player-netwatch`):
10 minutes with no internet → restart networking (NetworkManager, dhcpcd,
or a raw Wi-Fi interface bounce); 30 minutes → reboot the device (only while
the kiosk is running, at most once every 2 hours). Logs:
`journalctl -u irl-player-netwatch`.

The OS underneath stays patched too: `unattended-upgrades` applies security
updates via the standard apt-daily timers (no automatic reboots), with
`irl-player` blacklisted so app versions are controlled exclusively by
`irl-update`.

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
fetches the config over HTTPS from the Cloudflare Worker below
(identifying the device by its hardware serial) and writes
`/opt/irl-gateway/mqtt.json` (root-only, mode 600). The device keeps the
last good copy, so an offline boot or a config-service outage never stops
a previously-configured gateway; a device that has never been served (not
approved yet, or offline on first start) retries gently until it is. The
unit's `RuntimeMaxSec=1d` restarts the gateway daily, so a rotated config
or fresh approval takes effect within a day on its own (or instantly with
`sudo systemctl restart irl-gateway`).

### Cloudflare Worker config service

A Worker at `https://config.theirlnetwork.com/mqtt-config` serves the
config over HTTPS, with an optional per-device allowlist. Setup, done
once in the Cloudflare dashboard:

1. **Workers & Pages → Create → Create Worker** ("Start with Hello
   World!"), name it `irl-config`, deploy, then **Edit code**, replace
   everything with the handler below, and **Deploy**:

   ```js
   export default {
     async fetch(request, env) {
       const url = new URL(request.url);
       if (url.pathname !== "/mqtt-config")
         return new Response("not found", { status: 404 });

       const serial = (url.searchParams.get("serial") || "").trim();
       const allow = String(env.ALLOWLIST || "")
         .split(",").map(s => s.trim()).filter(Boolean);
       const approved = !allow.length || allow.includes(serial);
       // shows up in Observability → Logs: which device asked, and the verdict
       console.log(`serial=${serial || "(none)"} ${approved ? "served" : "refused"}`);
       if (!approved)
         return new Response("not approved", { status: 403 });

       const cfg = typeof env.MQTT_JSON === "string"
         ? env.MQTT_JSON
         : JSON.stringify(env.MQTT_JSON);
       return new Response(cfg, { headers: { "content-type": "application/json" } });
     }
   };
   ```
2. **Settings → Variables and Secrets**. ⚠️ **After changing ANY variable
   (`MQTT_JSON`, `ALLOWLIST`, ...), the change is only staged — it does
   NOT reach the running Worker until a new version is deployed.** The
   reliable way: open **Edit code** (top right), change nothing, and
   click **Deploy**. Verify on the **Bindings** tab (must list the
   variables) or just test the URL from step 4 — until you deploy, the
   Worker keeps serving with the old values.
   - `MQTT_JSON` — the full contents of `mqtt.json`. Type **JSON** works
     (Cloudflare then hands the code a parsed object — hence the
     stringify above); **Secret** keeps the value hidden in the
     dashboard; plain **Text** also works.
   - `ALLOWLIST` — type **Text** (comma-separated serials, e.g.
     `0aa6bd2679151255,10000000abc123`). Empty = open to all; non-empty =
     only listed devices are served. A device's serial:
     `grep Serial /proc/cpuinfo`.
3. **Settings → Domains & Routes → Add → Custom domain** →
   `config.theirlnetwork.com` (DNS + HTTPS are automatic).
4. Test: `curl "https://config.theirlnetwork.com/mqtt-config?serial=test"`
   must return the JSON.

With the Worker in place: **rotation** = edit `MQTT_JSON` in the
dashboard (then Edit code → Deploy; no repo change, no device touched);
**security switch** = fill `ALLOWLIST` — unapproved devices get 403
immediately, approved ones never notice.

**How fast a rotation reaches the fleet:** devices re-fetch at every
gateway start and auto-restart daily (`RuntimeMaxSec=1d`), so every
approved device has the new credential **within 24 hours** (instant per
device with `sudo systemctl restart irl-gateway`). For a zero-downtime
broker rotation, overlap: add the new credential on the broker while the
old one still works → update `MQTT_JSON` in Cloudflare → wait a day →
remove the old credential from the broker. No device ever loses its
connection.

**Approving a device** (once `ALLOWLIST` is in use): open the Worker's
**Observability → Logs** — every request logs a message like
`serial=0aa6bd2679151255 served` (or `... refused`), so a new device
announces its own serial by asking. Copy that serial, append it to
`ALLOWLIST` (comma-separated), Deploy. The device picks the config up on
its next try (it retries about once a minute until served); nothing is
done on the device itself.

With a large fleet the log stream gets busy — don't scroll it, **filter
it**. A bare word typed in the search bar does NOT match; query the
`message` field explicitly: **Query Builder → Filters → + Add → field
`message` → contains → `refused`** (or type `message` in the search bar
and follow the autocomplete to Message → contains → refused). Save it
via **Saved Queries** as "awaiting approval". Mind the **time-range
picker** — a correct query still shows nothing if the events are older
than the selected window — and searched logs can lag the live stream by
a minute or two. The filtered view shows exactly the devices waiting for
approval (an unapproved device without a cached config retries every
minute, so it stays near the top). Approved devices fetch only at
gateway start and then daily, so `served` lines stay rare. Workers Logs
keeps a few days of history — approve devices as they appear rather than
mining old logs.

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
  installer: the cursor is hidden with a transparent cursor theme, and the
  app runs on the X11 backend where it draws no title bar.
- **Locked out with no keyboard** — SSH in and
  `sudo systemctl stop irl-player-kiosk`, or power-cycle; it recovers cleanly.
