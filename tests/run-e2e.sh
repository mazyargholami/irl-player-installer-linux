#!/usr/bin/env bash
# End-to-end test of the IRL Player installer / auto-updater / uninstaller.
# Runs the real scripts inside a fake root: absolute system paths are
# redirected into $ROOT, system tools (systemctl, apt-get, dpkg, useradd,
# usermod) are PATH-stubbed, and a local http.server plays GitHub Pages.
set -uo pipefail

WORK="$(mktemp -d)"
SERVER=""
trap 'kill $SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
E2E="$WORK"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$E2E/root"
SITE="$E2E/site"
PORT=8896
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

rm -rf "$ROOT" "$SITE"
mkdir -p "$ROOT"/{etc/systemd/system,usr/local/bin,usr/share/icons/transparent/cursors,var/lock,proc,boot,opt,bin} "$SITE"

# --- fake device state --------------------------------------------------------
printf 'Raspberry Pi 4 Model B Rev 1.4' > "$ROOT/proc/model"
echo "console=serial0,115200 console=tty1 root=PARTUUID=x rootfstype=ext4" > "$ROOT/boot/cmdline.txt"
printf '#!/bin/sh\ntrue\n' > "$ROOT/opt/IRLPlayer" && chmod +x "$ROOT/opt/IRLPlayer"

# --- system tool stubs --------------------------------------------------------
cat > "$ROOT/bin/systemctl" <<STUB
#!/bin/sh
echo "\$@" >> "$ROOT/systemctl.log"
[ "\$1" = "is-enabled" ] && exit 1
exit 0
STUB
cat > "$ROOT/bin/dpkg" <<'STUB'
#!/bin/sh
[ "$1" = "--print-architecture" ] && { echo arm64; exit 0; }
exit 0
STUB
for t in apt-get useradd usermod; do
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/$t"
done
chmod +x "$ROOT/bin/"*
export PATH="$ROOT/bin:$PATH"

# --- build the path-redirected test copy of install.sh + serve it ------------
redirect() {  # rewrite absolute system paths into $ROOT
  sed -e "s|/etc/irl-player|$ROOT/etc/irl-player|g" \
      -e "s|/etc/systemd/system|$ROOT/etc/systemd/system|g" \
      -e "s|/usr/local/bin|$ROOT/usr/local/bin|g" \
      -e "s|/var/lock|$ROOT/var/lock|g" \
      -e "s|/proc/device-tree/model|$ROOT/proc/model|g" \
      -e "s|/var/lib/irl-player|$ROOT/var/lib/irl-player|g" \
      -e "s|/run/user|$ROOT/run/user|g" \
      -e "s|/boot/firmware/cmdline.txt|$ROOT/boot/none|g" \
      -e "s|/boot/cmdline.txt|$ROOT/boot/cmdline.txt|g" \
      -e "s|/opt/irl-player/IRLPlayer|$ROOT/opt/IRLPlayer|g" \
      -e "s|/usr/share/icons|$ROOT/usr/share/icons|g" \
      "$1"
}
redirect "$REPO/install.sh"   > "$SITE/install.sh"
redirect "$REPO/uninstall.sh" > "$SITE/uninstall.sh"
ln -s "$REPO/packages" "$SITE/packages"
python3 -m http.server "$PORT" --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!
until curl -sf -o /dev/null "http://localhost:$PORT/install.sh"; do :; done
export IRL_BASE_URL="http://localhost:$PORT"

echo "== 1. Fresh install (curl | bash, like a real device) =="
curl -fsSL "http://localhost:$PORT/install.sh" | bash > "$E2E/install1.log" 2>&1
check "[ \$? -eq 0 ] || grep -q Done '$E2E/install1.log'" "install.sh runs end-to-end without error"
grep -q "Installer revision 9 (app 1.2.5)" "$E2E/install1.log" && ok "logs revision 9 / app 1.2.5" || bad "revision banner missing"
for f in usr/local/bin/irl-kiosk-run usr/local/bin/irl-kiosk-toggle usr/local/bin/irl-hotkeyd \
         usr/local/bin/irl-update usr/local/bin/irl-watchdog \
         etc/systemd/system/irl-player-kiosk.service \
         etc/systemd/system/irl-player-hotkey.service etc/systemd/system/irl-player-update.service \
         etc/systemd/system/irl-player-update.timer etc/systemd/system/irl-player-watchdog.service \
         etc/systemd/system.conf.d/irl-watchdog.conf \
         etc/irl-player/manifest etc/irl-player/installer.sha256; do
  check "[ -e '$ROOT/$f' ]" "created $f"
done
check "grep -q 'enable --now irl-player-update.timer' '$ROOT/systemctl.log'" "update timer enabled"
check "grep -q 'restart irl-player-kiosk' '$ROOT/systemctl.log'" "kiosk (re)started"
check "[ -L '$ROOT/etc/irl-player/icons/default/cursors' ]" "transparent-cursor symlink created"
grep -q 'consoleblank=0' "$ROOT/boot/cmdline.txt" && ok "console blanking disabled in cmdline.txt" || bad "cmdline.txt not updated"
c=$(grep -c 'consoleblank=0' "$ROOT/boot/cmdline.txt"); [ "$c" = 1 ] && ok "consoleblank added exactly once" || bad "consoleblank duplicated"

echo "== 2. Generated scripts are valid =="
for s in irl-kiosk-run irl-kiosk-toggle irl-update irl-watchdog; do
  check "bash -n '$ROOT/usr/local/bin/$s'" "bash -n $s"
done
check "PYTHONPYCACHEPREFIX='$E2E/pycache' python3 -m py_compile '$ROOT/usr/local/bin/irl-hotkeyd'" "python syntax irl-hotkeyd"
check "grep -q 'BASE_URL=\"http://localhost:$PORT\"' '$ROOT/usr/local/bin/irl-update'" "BASE_URL baked into irl-update"
check "grep -q 'ExecStart=/usr/bin/cage' '$ROOT/etc/systemd/system/irl-player-kiosk.service'" "kiosk unit ExecStart"
check "grep -q 'OnUnitActiveSec=1h' '$ROOT/etc/systemd/system/irl-player-update.timer'" "timer runs hourly"

echo "== 3. Auto-update: no change -> silent no-op =="
H1=$(cat "$ROOT/etc/irl-player/installer.sha256")
out=$("$ROOT/usr/local/bin/irl-update"); rc=$?
check "[ $rc -eq 0 ] && [ -z '$out' ]" "unchanged script: exit 0, no output"
check "[ \"\$(cat '$ROOT/etc/irl-player/installer.sha256')\" = '$H1' ]" "stored hash untouched"

echo "== 4. Auto-update: captive portal / junk response is rejected =="
mv "$SITE/install.sh" "$SITE/install.sh.real"
printf '<html>hotel wifi login</html>\n' > "$SITE/install.sh"
out=$("$ROOT/usr/local/bin/irl-update"); rc=$?
check "[ $rc -eq 0 ] && [ -z '$out' ]" "non-script response: quiet exit"
check "[ -f '$ROOT/etc/systemd/system/irl-player-kiosk.service' ]" "nothing was executed/removed"
mv "$SITE/install.sh.real" "$SITE/install.sh"

echo "== 5. Auto-update: script changed WITH a deleted service =="
# v2 drops the whole hotkey feature (section 8 + its MANAGED_FILES lines + enable line)
awk '/^# --- 8\. /{skip=1} /^# --- 9\. /{skip=0} !skip' "$SITE/install.sh" \
  | sed -e '/irl-player-hotkey/d' -e '/irl-hotkeyd/d' -e 's/^INSTALLER_REV=9/INSTALLER_REV=10/' > "$SITE/install.v2"
mv "$SITE/install.v2" "$SITE/install.sh"
bash -n "$SITE/install.sh" && ok "v2 script valid" || bad "v2 script broken"
"$ROOT/usr/local/bin/irl-update" > "$E2E/update.log" 2>&1
check "grep -q 'install.sh changed' '$E2E/update.log'" "change detected"
check "grep -q 'Installer revision 10' '$E2E/update.log'" "new script executed"
check "grep -q 'update applied' '$E2E/update.log'" "update reported applied"
check "[ ! -e '$ROOT/etc/systemd/system/irl-player-hotkey.service' ]" "deleted service unit removed from device"
check "[ ! -e '$ROOT/usr/local/bin/irl-hotkeyd' ]" "deleted helper removed from device"
check "grep -q 'disable --now irl-player-hotkey.service' '$ROOT/systemctl.log'" "deleted service was stopped+disabled"
check "[ -e '$ROOT/etc/systemd/system/irl-player-kiosk.service' ]" "kept service untouched"
check "[ -e '$ROOT/usr/local/bin/irl-update' ]" "updater survived overwriting itself mid-run"
check "! grep -q irl-hotkeyd '$ROOT/etc/irl-player/manifest'" "manifest no longer lists deleted files"
H2=$(cat "$ROOT/etc/irl-player/installer.sha256")
check "[ '$H2' != '$H1' ]" "stored hash advanced to v2"
out=$("$ROOT/usr/local/bin/irl-update")
check "[ -z '$out' ]" "second check after update: no-op (converged)"

echo "== 6. Concurrency: second updater can't run while one holds the lock =="
( exec 9>"$ROOT/var/lock/irl-update.lock"; flock 9; "$ROOT/usr/local/bin/irl-update"; echo "rc=$?" > "$E2E/lock.rc" )
check "grep -q 'rc=0' '$E2E/lock.rc'" "locked: quiet exit 0, no double-run"

echo "== 7. Freeze watchdog: full story (healthy -> freeze -> restarts -> reboot) =="
# Speed up the timings on a copy of the installed (already path-redirected)
# watchdog: check every 1s, frozen after 3s, 2s grace.
sed -e 's/^INTERVAL=30 /INTERVAL=1 /' -e 's/^FREEZE_AFTER=300 /FREEZE_AFTER=3 /' \
    -e 's/^GRACE=120 /GRACE=2 /' "$ROOT/usr/local/bin/irl-watchdog" > "$E2E/wd-fast"
grep -q '^INTERVAL=1 ' "$E2E/wd-fast" && ok "sim timings applied" || bad "sim timing sed failed"
mkdir -p "$ROOT/simbin" "$ROOT/run/user/1000"
: > "$ROOT/run/user/1000/wayland-0"
echo frame-0 > "$ROOT/frame.dat"
cat > "$ROOT/simbin/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { echo 1000; exit 0; }
exit 0
STUB
cat > "$ROOT/simbin/runuser" <<'STUB'
#!/bin/sh
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
STUB
cat > "$ROOT/simbin/grim" <<STUB
#!/bin/sh
cat "$ROOT/frame.dat"
STUB
cat > "$ROOT/simbin/systemctl" <<STUB
#!/bin/sh
[ "\$1" = "is-active" ] && exit 0
echo "\$@" >> "$ROOT/simlog"
exit 0
STUB
cat > "$ROOT/simbin/reboot" <<STUB
#!/bin/sh
echo REBOOT >> "$ROOT/simlog"
exit 0
STUB
chmod +x "$ROOT/simbin/"*
: > "$ROOT/simlog"
PATH="$ROOT/simbin:$PATH" timeout 40 bash "$E2E/wd-fast" > "$E2E/wd.out" 2>&1 &
WD=$!
for i in 1 2 3 4 5; do sleep 1; echo "frame-$i" > "$ROOT/frame.dat"; done   # healthy: moving picture
grep -q restart "$ROOT/simlog" && bad "restarted while screen was changing" || ok "no action while screen is changing"
# now freeze the screen and let the ladder play out
until grep -q REBOOT "$ROOT/simlog" 2>/dev/null; do sleep 1; kill -0 $WD 2>/dev/null || break; done
kill $WD 2>/dev/null; wait $WD 2>/dev/null
R=$(grep -c 'restart irl-player-kiosk' "$ROOT/simlog")
check "[ '$R' = 3 ]" "frozen screen: exactly 3 player restarts before escalating"
check "grep -q REBOOT '$ROOT/simlog'" "still frozen: device reboot triggered"
check "grep -q 'attempt 1/3' '$E2E/wd.out' && grep -q 'attempt 3/3' '$E2E/wd.out'" "attempts logged 1/3..3/3"
check "grep -q 'rebooting device' '$E2E/wd.out'" "reboot decision logged"
check "[ -s '$ROOT/var/lib/irl-player/last-watchdog-reboot' ]" "reboot timestamp persisted (2h backoff)"

echo "== 8. Uninstall removes everything =="
bash "$SITE/uninstall.sh" > "$E2E/uninstall.log" 2>&1 && ok "uninstall.sh runs clean" || bad "uninstall.sh errored"
LEFT=$(find "$ROOT/etc/systemd/system" "$ROOT/etc/systemd/system.conf.d" "$ROOT/usr/local/bin" "$ROOT/etc/irl-player" "$ROOT/var/lib/irl-player" -type f 2>/dev/null | wc -l)
check "[ '$LEFT' = 0 ]" "no installed files left behind"
check "grep -q 'disable --now irl-player-update.timer' '$ROOT/systemctl.log'" "update timer disabled on uninstall"
check "grep -q 'disable --now irl-player-watchdog' '$ROOT/systemctl.log'" "watchdog disabled on uninstall"

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
