# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A GitHub Pages site (custom domain `https://linux-player.theirlnetwork.com`) that serves everything a fleet of Raspberry Pi kiosk devices needs: the guide website (`index.html`), the installer (`install.sh`), the uninstaller (`uninstall.sh`), and the `.deb` packages (`packages/`). The fleet is mostly CM5 devices with some Pi 5s — lead with CM5 in user-facing docs.

**Secrets policy — read before touching anything credential-shaped.** This repo is fully public (Pages serves every committed file). No credential, token, or password may ever be committed — not even "encrypted with the key nearby" (that was tried and rotated away; the old blob still sits in git history). The gateway's MQTT credentials live ONLY in a Cloudflare Worker (see "IRL Gateway" below).

**`main` is production.** Every push to `main` redeploys the website (`.github/workflows/deploy-pages.yml`), and — because deployed devices re-fetch `install.sh` hourly and reinstall on any change — **any edit to `install.sh` merged to `main` rolls out to every device in the field within the hour**. There is no staging environment. Do work on a branch and PR into `main`.

## Commands

```bash
bash -n install.sh uninstall.sh   # syntax check
sudo bash tests/run-e2e.sh        # full test suite (~90 checks), must run as root
```

The e2e suite runs the real scripts inside a fake root under `/tmp` (system paths are sed-redirected, `systemctl`/`apt-get`/`dpkg`/`useradd`/`userdel`/`loginctl`/`pkill` are PATH-stubbed, a local `python3 -m http.server` plays both GitHub Pages and the Cloudflare config service). It makes no changes to the host. It covers: fresh install, all `irl-update` paths (no-op, changed script, captive portal, flock, canary gating), deleted-service propagation, real-time freeze- and network-watchdog simulations (take ~40 s), the gateway config fetch (plus a no-credential-in-installer assertion), and uninstall. CI runs it on every PR. **Extend it whenever you add a service or change updater/watchdog/gateway logic.** The gateway config URL is sed-redirected to the local server — tests must never hit the real Worker.

To visually verify `index.html`, serve the repo (`python3 -m http.server`) and render with Playwright's Chromium at `/opt/pw-browsers/chromium` — the footer's dynamic version text only appears when the page is served over HTTP, not from `file://`.

## Architecture — how the fleet stays in sync

`install.sh` is the single source of truth for the entire device state. The chain:

1. **Auto-update**: `install.sh` installs `/usr/local/bin/irl-update` + `irl-player-update.timer` (hourly + on boot). `irl-update` fetches the published `install.sh`, compares its SHA-256 to the hash recorded at install time (`/etc/irl-player/installer.sha256`), and re-runs the script on any difference. Consequences:
   - Any change to `install.sh` = automatic fleet rollout (and a brief player restart per device).
   - `irl-update`'s body lives in `main()` **on purpose**: the reinstall overwrites the running script, and bash executes garbage if a running script's file changes under it. Keep that wrapper.
2. **Deletion propagation**: `MANAGED_FILES` (top of `install.sh`) lists every file the installer creates; the previous install's copy is stored in `/etc/irl-player/manifest`. On each run, files in the old manifest but not in the current `MANAGED_FILES` are `systemctl disable --now`-ed and deleted. **When adding or removing an installer-created file, update `MANAGED_FILES`, `uninstall.sh`, and the e2e suite together.**
3. **Canary rollout**: devices without `/etc/irl-player/canary` defer a new `install.sh` by `FLEET_DELAY_HOURS` (top of `install.sh`; `irl-update` parses the value out of the **newly fetched** script with `^FLEET_DELAY_HOURS=(\d+)$` — don't change that line's format). A canary-marked device applies immediately; publishing with `FLEET_DELAY_HOURS=0` makes the whole fleet apply immediately (urgent fixes). The pending wait is tracked in `/etc/irl-player/pending-update` (hash + first-seen epoch).
4. **Self-healing**: `irl-watchdog` hashes a `grim` screenshot every 30 s; a pixel-identical screen for 5 min = frozen → restart the kiosk service (max 3, counter clears only after 5 min of continuously changing screen) → reboot (max once per 2 h, timestamp in `/var/lib/irl-player/`). It deliberately does nothing when the screen can't be captured or the kiosk is intentionally stopped. `irl-netwatch` does the same for connectivity: 10 min offline → restart networking, 30 min → reboot (kiosk running only, 2 h backoff). `/etc/systemd/system.conf.d/irl-watchdog.conf` arms the Pi's hardware watchdog for full-OS hangs.
5. **OS updates**: `unattended-upgrades` (config in `/etc/apt/apt.conf.d/52irl-*` and `60irl-*`) applies security updates nightly with **`irl-player` blacklisted** — apt must never upgrade the app; only `irl-update` does.
6. **IRL Gateway** (`/opt/irl-gateway/`, service `irl-gateway`): bridges a USB-attached ESP32 master board (and its worker fleet) to MQTT. `gateway.py` is embedded in `install.sh` (source of truth: the `irl-microcontroller` repo) with a venv (`pyserial`, `paho-mqtt>=2.0` — newer than apt's). Its MQTT config is **fetched, never shipped**: `ExecStartPre` runs `irl-gateway-config`, which GETs `https://iot-config.theirlnetwork.com/mqtt-config?serial=<hw serial>` — the user's self-hosted config panel (Django + Docker Compose; source and docs in the `irl-microcontroller` repo, `config-panel/`; web UI for approve/reject/rotate). The endpoint contract is sacred: 200+JSON for approved, `403 not approved` for pending/rejected, 404 otherwise — devices know nothing else. Unknown serials auto-register as pending in the panel; unapproved/no-cache devices retry ~1/min (that retry IS the approval request). Approved devices keep the fetched `mqtt.json` (root-only) as an offline cache; `RuntimeMaxSec=1d` restarts the gateway daily so rotations/approvals propagate within a day. Devices without an ESP32 attached idle harmlessly. (A retired Cloudflare Worker at `config.theirlnetwork.com` preceded the panel — see git history.)

7. **Fleet screen switch**: `screen.txt` at the repo root (`1` = screens on, `0` = all displays off) is fetched every minute by `irl-screen` (`irl-player-screen.timer`) and applied with `wlr-randr` per output — flipping the file does NOT reinstall anything (only `install.sh`'s hash triggers that). Display-off is deliberate: the player keeps running (instant wake), and `grim` can't capture a disabled output, which the freeze watchdog treats as "do nothing" (verified on cage: grim exits "no wl_output"). Fail-safe: anything other than an explicit `0` (missing file, fetch error, offline) means screens ON. Don't replace display-off with a black overlay — a static black screen would trip the freeze watchdog into a restart loop.

Other invariants:

- **Bump `INSTALLER_REV` on every `install.sh` change** (it's the fleet-visible revision, logged by every device run and shown in the website footer).
- The website footer (`index.html`) fetches `install.sh` at runtime and regex-parses `^INSTALLER_REV=(\d+)` and `^VERSION="..."`, then HEAD-checks `packages/irl-player_<version>_<arch>.deb` (shows "package missing!" if absent). Don't change the format of those two lines. The "Guide version N" fallback text in the footer is hand-bumped when `index.html` changes.
- The whole repo is published as the website — anything committed is publicly served.
- `uninstall.sh` removes everything including `/opt/irl-gateway` (and its cached credential) and the `/etc/irl-player` state dir — which holds the canary marker, so **re-mark a test device with `sudo touch /etc/irl-player/canary` after any uninstall/reinstall** (this has been forgotten twice; the symptom is the canary deferring updates by 24 h).
- The rpi5 test device's serial is `0aa6bd2679151255` (approved in the Worker's ALLOWLIST).

## Releasing a new app version

1. Add `packages/irl-player_<newversion>_<arch>.deb` — **never reuse a version number** for different contents (devices key off `install.sh`'s hash, and apt skips same-version reinstalls).
2. In `install.sh`: bump `VERSION` and `INSTALLER_REV`.
3. Single commit, PR, merge to `main`. The canary device converges within the hour; the rest of the fleet follows `FLEET_DELAY_HOURS` later. The site footer confirms what's deployed. CI (`.github/workflows/tests.yml`) runs the e2e suite on every PR.

New architectures: add the `.deb` and extend `SUPPORTED_ARCHS`. The Raspberry-Pi model check applies to `arm64` only (CM5 passes — its device-tree model contains "Raspberry Pi").
