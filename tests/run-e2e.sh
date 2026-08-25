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
printf 'processor\t: 0\nSerial\t\t: 10000000abcd1234\nModel\t\t: Raspberry Pi 4 Model B Rev 1.4\n' > "$ROOT/proc/cpuinfo"
echo "console=serial0,115200 console=tty1 root=PARTUUID=x rootfstype=ext4" > "$ROOT/boot/cmdline.txt"
printf '#!/bin/sh\ntrue\n' > "$ROOT/opt/IRLPlayer" && chmod +x "$ROOT/opt/IRLPlayer"
# player state: pairing UUID + cached screen name (shared_preferences), and the
# bundled .env whose API_URL points telemetry at the ad server for the token.
mkdir -p "$ROOT/home/irlplayer" "$ROOT/opt/player-assets"
printf '{"flutter.device_id":"test-device-uuid-0001","flutter.is_registered":true,"flutter.screen_identity":"E2E Venue Screen 1"}\n' > "$ROOT/home/irlplayer/shared_preferences.json"
printf 'API_URL=http://localhost:%s\nBACKEND_URL=http://localhost:%s\n' "$PORT" "$PORT" > "$ROOT/opt/player-assets/.env"

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
# userdel/loginctl/pkill are stubbed so uninstall.sh can never touch the real
# irlplayer user or its processes when the suite runs on a provisioned device
for t in apt-get useradd usermod userdel loginctl pkill; do
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
      -e "s|/etc/apt/apt.conf.d|$ROOT/etc/apt/apt.conf.d|g" \
      -e "s|/boot/firmware/cmdline.txt|$ROOT/boot/none|g" \
      -e "s|/boot/cmdline.txt|$ROOT/boot/cmdline.txt|g" \
      -e "s|/opt/irl-player/data/flutter_assets|$ROOT/opt/player-assets|g" \
      -e "s|/opt/irl-player/IRLPlayer|$ROOT/opt/IRLPlayer|g" \
      -e "s|/opt/irl-gateway|$ROOT/opt/irl-gateway|g" \
      -e "s|/home/irlplayer/.local/share/IRLPlayer|$ROOT/home/irlplayer|g" \
      -e "s|/proc/cpuinfo|$ROOT/proc/cpuinfo|g" \
      -e "s|https://iot-config.theirlnetwork.com/mqtt-config|http://localhost:$PORT/mqtt-config|g" \
      -e "s|https://iot-config.theirlnetwork.com/telemetry|http://localhost:$PORT/telemetry|g" \
      -e "s|/usr/share/icons|$ROOT/usr/share/icons|g" \
      "$1"
}
redirect "$REPO/install.sh"   > "$SITE/install.sh"
redirect "$REPO/uninstall.sh" > "$SITE/uninstall.sh"
ln -s "$REPO/packages" "$SITE/packages"
# stands in for the config panel (query strings are ignored). tls_ca_pem is
# the panel's optional inline broker CA: the fetch pipeline must carry it
# through verbatim (unknown-key tolerance) and the gateway must pin it
# (section 2b). tls_ca is also set to prove tls_ca_pem beats it. base_topic
# is deliberately NOT the default "irl": section 2b asserts every topic the
# gateway uses is derived from the config (per-fleet topic isolation).
cat > "$SITE/mqtt-config" <<'FIXTURE'
{"host": "test-broker", "port": 8883, "username": "e2e-user", "password": "e2e-pass", "tls": true, "tls_ca": "broker-ca.pem", "tls_insecure": false, "base_topic": "isotest", "tls_ca_pem": "-----BEGIN CERTIFICATE-----\nE2E-FAKE-INLINE-CA\n-----END CERTIFICATE-----"}
FIXTURE
# stands in for the player's ad server: GET /api/v1/status/<device_id> -> token
mkdir -p "$SITE/api/v1/status"
printf '{"session_code":"test-device-uuid-0001","external_id":"tok-e2e-abcdef","status":"approved"}\n' > "$SITE/api/v1/status/test-device-uuid-0001"
cp "$REPO/screen.txt" "$SITE/screen.txt"
python3 -m http.server "$PORT" --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!
until curl -sf -o /dev/null "http://localhost:$PORT/install.sh"; do :; done
export IRL_BASE_URL="http://localhost:$PORT"

echo "== 1. Fresh install (curl | bash, like a real device) =="
curl -fsSL "http://localhost:$PORT/install.sh" | bash > "$E2E/install1.log" 2>&1
check "[ \$? -eq 0 ] || grep -q Done '$E2E/install1.log'" "install.sh runs end-to-end without error"
REV="$(sed -n 's/^INSTALLER_REV=\([0-9]*\)$/\1/p' "$REPO/install.sh")"
VER="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$REPO/install.sh")"
grep -q "Installer revision $REV (app $VER)" "$E2E/install1.log" && ok "logs revision $REV / app $VER" || bad "revision banner missing"
for f in usr/local/bin/irl-kiosk-run usr/local/bin/irl-kiosk-toggle usr/local/bin/irl-hotkeyd \
         usr/local/bin/irl-update usr/local/bin/irl-watchdog usr/local/bin/irl-netwatch \
         etc/systemd/system/irl-player-kiosk.service \
         etc/systemd/system/irl-player-hotkey.service etc/systemd/system/irl-player-update.service \
         etc/systemd/system/irl-player-update.timer etc/systemd/system/irl-player-watchdog.service \
         etc/systemd/system/irl-player-netwatch.service \
         etc/systemd/system.conf.d/irl-watchdog.conf \
         etc/systemd/system/irl-gateway.service \
         opt/irl-gateway/gateway.py opt/irl-gateway/broker-ca.pem \
         usr/local/bin/irl-gateway-config \
         usr/local/bin/irl-telemetry \
         etc/systemd/system/irl-player-telemetry.service \
         etc/systemd/system/irl-player-telemetry.timer \
         usr/local/bin/irl-screen \
         etc/systemd/system/irl-player-screen.service \
         etc/systemd/system/irl-player-screen.timer \
         etc/systemd/system/irl-player-reboot.service \
         etc/systemd/system/irl-player-reboot.timer \
         etc/apt/apt.conf.d/52irl-unattended-upgrades etc/apt/apt.conf.d/60irl-auto-upgrades \
         etc/irl-player/manifest etc/irl-player/installer.sha256; do
  check "[ -e '$ROOT/$f' ]" "created $f"
done
check "! [ -e '$ROOT/opt/irl-gateway/mqtt.json' ]" "installer itself writes no config file (helper's job)"
check "! grep -q 'MQTT_JSON_ENC\|GWK=' '$SITE/install.sh'" "no credential blob or passphrase left in the installer"
check "'$ROOT/usr/local/bin/irl-gateway-config'" "config helper fetches the MQTT config"
check "python3 -c \"import json; c=json.load(open('$ROOT/opt/irl-gateway/mqtt.json')); assert c['host']\"" "fetched config is valid JSON with a broker host"
check "python3 -c \"import json; c=json.load(open('$ROOT/opt/irl-gateway/mqtt.json')); assert c['tls_ca_pem'].startswith('-----BEGIN')\"" "unknown config keys (tls_ca_pem) pass through the fetch verbatim"
check "'$ROOT/usr/local/bin/irl-telemetry'" "telemetry reporter runs clean (fire-and-forget)"
TOUT=$("$ROOT/usr/local/bin/irl-telemetry" --print 2>/dev/null || true)
check "[ -z '$TOUT' ] || printf '%s' \"\$TOUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"serial\"]'" "telemetry --print yields valid JSON (or nothing without a serial)"
check "grep -q \"T_REV=.$REV.\" '$ROOT/usr/local/bin/irl-telemetry'" "installer revision baked into the telemetry payload"
check "printf '%s' \"\$TOUT\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"device_id\"]==\"test-device-uuid-0001\", d.get(\"device_id\"); assert d[\"screen_identity\"]==\"E2E Venue Screen 1\", d.get(\"screen_identity\"); assert d[\"device_token\"]==\"tok-e2e-abcdef\", d.get(\"device_token\")'" "telemetry resolves player device_id, screen_identity, and CMS device_token"
check "grep -q 'enable --now irl-player-update.timer' '$ROOT/systemctl.log'" "update timer enabled"
check "grep -q 'restart irl-player-kiosk' '$ROOT/systemctl.log'" "kiosk (re)started"
check "[ -L '$ROOT/etc/irl-player/icons/default/cursors' ]" "transparent-cursor symlink created"
grep -q 'consoleblank=0' "$ROOT/boot/cmdline.txt" && ok "console blanking disabled in cmdline.txt" || bad "cmdline.txt not updated"
c=$(grep -c 'consoleblank=0' "$ROOT/boot/cmdline.txt"); [ "$c" = 1 ] && ok "consoleblank added exactly once" || bad "consoleblank duplicated"

echo "== 2. Generated scripts are valid =="
for s in irl-kiosk-run irl-kiosk-toggle irl-update irl-watchdog irl-netwatch irl-gateway-config irl-telemetry irl-screen; do
  check "bash -n '$ROOT/usr/local/bin/$s'" "bash -n $s"
done
check "PYTHONPYCACHEPREFIX='$E2E/pycache' python3 -m py_compile '$ROOT/usr/local/bin/irl-hotkeyd'" "python syntax irl-hotkeyd"
check "PYTHONPYCACHEPREFIX='$E2E/pycache' python3 -m py_compile '$ROOT/opt/irl-gateway/gateway.py'" "python syntax gateway.py"
check "grep -q 'BASE_URL=\"http://localhost:$PORT\"' '$ROOT/usr/local/bin/irl-update'" "BASE_URL baked into irl-update"
check "grep -q 'ExecStart=/usr/bin/cage' '$ROOT/etc/systemd/system/irl-player-kiosk.service'" "kiosk unit ExecStart"
check "grep -q 'OnUnitActiveSec=1h' '$ROOT/etc/systemd/system/irl-player-update.timer'" "timer runs hourly"
# Persistent= breaks a monotonic-only timer's hourly re-arm on systemd 257 (it
# collapses the next elapse to infinity once a stamp exists). Must stay absent.
check "! grep -q '^Persistent=' '$ROOT/etc/systemd/system/irl-player-update.timer'" "update timer has no Persistent= (would kill the hourly re-check)"
check "grep -q \"SCREEN_URL=.*http://localhost:$PORT/screen.txt\" '$ROOT/usr/local/bin/irl-screen'" "screen.txt URL baked into irl-screen"
check "grep -q 'OnUnitActiveSec=1min' '$ROOT/etc/systemd/system/irl-player-screen.timer'" "screen switch checks every minute"
check "grep -q 'enable --now irl-player-screen.timer' '$ROOT/systemctl.log'" "screen switch timer enabled"
# weekly reboot: OnCalendar timer (immune to the monotonic trap), no Persistent=
check "grep -q 'OnCalendar=Sun .* 04:00:00' '$ROOT/etc/systemd/system/irl-player-reboot.timer'" "weekly reboot scheduled Sun 04:00 local"
check "! grep -q '^Persistent=' '$ROOT/etc/systemd/system/irl-player-reboot.timer'" "reboot timer has no Persistent= (no catch-up reboot after downtime)"
check "grep -q 'systemctl reboot' '$ROOT/etc/systemd/system/irl-player-reboot.service'" "reboot service calls systemctl reboot"
check "grep -q 'enable --now irl-player-reboot.timer' '$ROOT/systemctl.log'" "weekly reboot timer enabled"

echo "== 2b. Gateway pins the panel-delivered CA (tls_ca_pem -> config-ca.pem) =="
check "! [ -e '$ROOT/opt/irl-gateway/config-ca.pem' ]" "no config-ca.pem before the gateway first connects"
# Drive the installed gateway.py directly: stub pyserial + paho, start an
# MqttLink from the fetched mqtt.json, and verify the inline CA is written
# to config-ca.pem (exact content) and pinned for TLS ahead of tls_ca.
cat > "$E2E/tls-ca-pem-test.py" <<'PYEOF'
import importlib.util, json, os, sys, types

gwdir = sys.argv[1]

serial_mod = types.ModuleType("serial")
serial_mod.SerialException = type("SerialException", (Exception,), {})
tools_mod = types.ModuleType("serial.tools")
lp_mod = types.ModuleType("serial.tools.list_ports")
lp_mod.comports = lambda: []
serial_mod.tools = tools_mod
tools_mod.list_ports = lp_mod
sys.modules.update({"serial": serial_mod, "serial.tools": tools_mod,
                    "serial.tools.list_ports": lp_mod})

calls = {}
class FakeClient:
    def __init__(self, *a, **k): pass
    def username_pw_set(self, u, p): calls["auth"] = (u, p)
    def tls_set(self, ca_certs=None): calls["ca_certs"] = ca_certs
    def tls_insecure_set(self, v): calls["insecure"] = v
    def will_set(self, topic, *a, **k): calls["will"] = topic
    def reconnect_delay_set(self, *a, **k): pass
    def connect_async(self, host, port=1883, keepalive=60): calls["connect"] = (host, port)
    def loop_start(self): pass
    def subscribe(self, topic, qos=0): calls["subscribe"] = topic
    def publish(self, topic, payload=None, retain=False): calls.setdefault("published", []).append(topic)
paho_mod = types.ModuleType("paho")
mqtt_mod = types.ModuleType("paho.mqtt")
client_mod = types.ModuleType("paho.mqtt.client")
client_mod.Client = FakeClient
client_mod.CallbackAPIVersion = types.SimpleNamespace(VERSION2=2)
paho_mod.mqtt = mqtt_mod
mqtt_mod.client = client_mod
sys.modules.update({"paho": paho_mod, "paho.mqtt": mqtt_mod,
                    "paho.mqtt.client": client_mod})

spec = importlib.util.spec_from_file_location("gw", os.path.join(gwdir, "gateway.py"))
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

with open(os.path.join(gwdir, "mqtt.json")) as f:
    cfg = json.load(f)
assert cfg.get("tls_ca_pem"), "fetched config lost tls_ca_pem"

link = gw.MqttLink(cfg)
link.start("e2e-master")

# topic isolation: every topic must come from the config's base_topic
# (the fixture uses "isotest", NOT the default "irl")
assert link.topic == "isotest/e2e-master", link.topic
assert calls.get("will") == "isotest/e2e-master/status", calls.get("will")
link._on_connect(link.client, None, None, 0)  # simulate CONNACK rc=0
assert calls.get("subscribe") == "isotest/e2e-master/cmd", calls.get("subscribe")
assert "isotest/e2e-master/status" in calls.get("published", []), calls.get("published")

ca_path = os.path.join(gwdir, "config-ca.pem")
assert os.path.exists(ca_path), "config-ca.pem not written"
with open(ca_path) as f:
    content = f.read()
assert content == cfg["tls_ca_pem"].strip() + "\n", \
    "config-ca.pem content mismatch: %r" % content
assert calls.get("ca_certs") == ca_path, \
    "TLS pinned to %r, not the inline CA (tls_ca must lose)" % calls.get("ca_certs")
assert calls.get("connect") == (cfg["host"], cfg["port"]), calls.get("connect")
assert gw.materialize_inline_ca(cfg) == ca_path, "re-materialize not idempotent"
PYEOF
check "PYTHONPYCACHEPREFIX='$E2E/pycache' python3 '$E2E/tls-ca-pem-test.py' '$ROOT/opt/irl-gateway'" "gateway pins tls_ca_pem for TLS (beats tls_ca) and derives all topics from base_topic (isotest/...)"

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

echo "== 5. Canary rollout: fleet devices wait, canary goes first =="
# v2 drops the whole hotkey feature (section 8 + its MANAGED_FILES lines + enable line)
awk '/^# --- 8\. /{skip=1} /^# --- 9\. /{skip=0} !skip' "$SITE/install.sh" \
  | sed -e '/irl-player-hotkey/d' -e '/irl-hotkeyd/d' -e "s/^INSTALLER_REV=$REV/INSTALLER_REV=$((REV+1))/" > "$SITE/install.v2"
mv "$SITE/install.v2" "$SITE/install.sh"
bash -n "$SITE/install.sh" && ok "v2 script valid" || bad "v2 script broken"
"$ROOT/usr/local/bin/irl-update" > "$E2E/gate.log" 2>&1
check "grep -q 'applies it in 24h' '$E2E/gate.log'" "non-canary device: update deferred 24h"
check "[ -f '$ROOT/etc/irl-player/pending-update' ]" "pending marker recorded"
check "[ -e '$ROOT/etc/systemd/system/irl-player-hotkey.service' ]" "nothing applied during the wait"
out=$("$ROOT/usr/local/bin/irl-update")
check "[ -z '$out' ]" "repeat check during wait: silent"
# fast-forward: pretend this update was first seen long ago
PH="$(awk '{print $1}' "$ROOT/etc/irl-player/pending-update")"
echo "$PH 0" > "$ROOT/etc/irl-player/pending-update"

echo "== 6. Auto-update applies after the delay: deleted service propagates =="
"$ROOT/usr/local/bin/irl-update" > "$E2E/update.log" 2>&1
check "grep -q 'install.sh changed' '$E2E/update.log'" "change detected"
check "grep -q \"Installer revision $((REV+1))\" '$E2E/update.log'" "new script executed"
check "grep -q 'update applied' '$E2E/update.log'" "update reported applied"
check "[ ! -e '$ROOT/etc/systemd/system/irl-player-hotkey.service' ]" "deleted service unit removed from device"
check "[ ! -e '$ROOT/usr/local/bin/irl-hotkeyd' ]" "deleted helper removed from device"
check "grep -q 'disable --now irl-player-hotkey.service' '$ROOT/systemctl.log'" "deleted service was stopped+disabled"
check "[ -e '$ROOT/etc/systemd/system/irl-player-kiosk.service' ]" "kept service untouched"
check "[ -e '$ROOT/usr/local/bin/irl-update' ]" "updater survived overwriting itself mid-run"
check "! grep -q irl-hotkeyd '$ROOT/etc/irl-player/manifest'" "manifest no longer lists deleted files"
H2=$(cat "$ROOT/etc/irl-player/installer.sha256")
check "[ '$H2' != '$H1' ]" "stored hash advanced to v2"
check "[ ! -f '$ROOT/etc/irl-player/pending-update' ]" "pending marker cleared after apply"
out=$("$ROOT/usr/local/bin/irl-update")
check "[ -z '$out' ]" "second check after update: no-op (converged)"

echo "== 7. Canary device applies a new release immediately =="
touch "$ROOT/etc/irl-player/canary"
printf '# canary-test marker\n' >> "$SITE/install.sh"
"$ROOT/usr/local/bin/irl-update" > "$E2E/canary.log" 2>&1
check "grep -q 'update applied' '$E2E/canary.log'" "canary device applies with no delay"
check "! grep -q 'applies it in' '$E2E/canary.log'" "no wait message on canary"
# two full reinstalls have run since section 2b wrote the gateway's CA state
check "grep -q 'E2E-FAKE-INLINE-CA' '$ROOT/opt/irl-gateway/config-ca.pem'" "reinstalls leave config-ca.pem alone (like mqtt.json)"

echo "== 8. Concurrency: second updater can't run while one holds the lock =="
( exec 9>"$ROOT/var/lock/irl-update.lock"; flock 9; "$ROOT/usr/local/bin/irl-update"; echo "rc=$?" > "$E2E/lock.rc" )
check "grep -q 'rc=0' '$E2E/lock.rc'" "locked: quiet exit 0, no double-run"

echo "== 9. Freeze watchdog: full story (healthy -> freeze -> restarts -> reboot) =="
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
cat > "$ROOT/simbin/setpriv" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --reuid|--regid) shift 2 ;;
    --init-groups) shift ;;
    *) break ;;
  esac
done
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

echo "== 10. Network watchdog: offline -> restart networking -> reboot =="
sed -e 's/^INTERVAL=60 /INTERVAL=1 /' -e 's/^RESTART_NET_AFTER=600 /RESTART_NET_AFTER=3 /' \
    -e 's/^REBOOT_AFTER=1800 /REBOOT_AFTER=6 /' "$ROOT/usr/local/bin/irl-netwatch" > "$E2E/nw-fast"
grep -q '^INTERVAL=1 ' "$E2E/nw-fast" && ok "netwatch sim timings applied" || bad "netwatch timing sed failed"
mkdir -p "$ROOT/simbin2"
for t in ping curl; do printf '#!/bin/sh\nexit 1\n' > "$ROOT/simbin2/$t"; done
cat > "$ROOT/simbin2/systemctl" <<STUB
#!/bin/sh
[ "\$1" = "is-active" ] && exit 0
echo "\$@" >> "$ROOT/simlog2"
exit 0
STUB
cat > "$ROOT/simbin2/reboot" <<STUB
#!/bin/sh
echo REBOOT >> "$ROOT/simlog2"
exit 0
STUB
chmod +x "$ROOT/simbin2/"*
: > "$ROOT/simlog2"
PATH="$ROOT/simbin2:$PATH" timeout 30 bash "$E2E/nw-fast" > "$E2E/nw.out" 2>&1 &
NW=$!
until grep -q REBOOT "$ROOT/simlog2" 2>/dev/null; do sleep 1; kill -0 $NW 2>/dev/null || break; done
kill $NW 2>/dev/null; wait $NW 2>/dev/null
check "grep -q 'restarting networking' '$E2E/nw.out'" "offline 3 ticks: networking restarted"
check "grep -q 'restart NetworkManager' '$ROOT/simlog2'" "NetworkManager restart issued"
check "grep -q REBOOT '$ROOT/simlog2'" "still offline: device reboot triggered"
check "[ -s '$ROOT/var/lib/irl-player/last-netwatch-reboot' ]" "reboot timestamp persisted (2h backoff)"

echo "== 10b. Fleet screen switch: screen.txt drives displays off/on =="
# Reuses section 9's simbin stubs (id -> uid 1000, setpriv -> exec) and its
# fake wayland socket in run/user/1000. wlr-randr is stubbed to report two
# HDMI outputs, so multi-display handling is covered too.
check "[ \"\$(tr -d '[:space:]' < '$REPO/screen.txt')\" = 1 ]" "repo screen.txt defaults to screens ON"
cat > "$ROOT/simbin/wlr-randr" <<STUB
#!/bin/sh
if [ \$# -eq 0 ]; then
  printf 'HDMI-A-1 "x"\n  Enabled: yes\nHDMI-A-2 "y"\n  Enabled: yes\n'
else
  echo "\$@" >> "$ROOT/simlog-screen"
fi
STUB
chmod +x "$ROOT/simbin/wlr-randr"
: > "$ROOT/simlog-screen"
echo 0 > "$SITE/screen.txt"
PATH="$ROOT/simbin:$PATH" "$ROOT/usr/local/bin/irl-screen" > "$E2E/screen.out" 2>&1
check "grep -q -- '--output HDMI-A-1 --off' '$ROOT/simlog-screen'" "screen.txt=0: first display off"
check "grep -q -- '--output HDMI-A-2 --off' '$ROOT/simlog-screen'" "screen.txt=0: second display off too"
check "[ \"\$(cat '$ROOT/var/lib/irl-player/screen-state')\" = off ]" "state recorded: off"
check "grep -q 'displays off' '$E2E/screen.out'" "state change logged"
: > "$ROOT/simlog-screen"
echo 1 > "$SITE/screen.txt"
PATH="$ROOT/simbin:$PATH" "$ROOT/usr/local/bin/irl-screen" > /dev/null 2>&1
check "grep -q -- '--output HDMI-A-1 --on' '$ROOT/simlog-screen'" "screen.txt=1: displays back on"
check "[ \"\$(cat '$ROOT/var/lib/irl-player/screen-state')\" = on ]" "state recorded: on"
: > "$ROOT/simlog-screen"
rm "$SITE/screen.txt"
PATH="$ROOT/simbin:$PATH" "$ROOT/usr/local/bin/irl-screen" > /dev/null 2>&1
check "grep -q -- '--on' '$ROOT/simlog-screen'" "missing screen.txt: fail-safe ON"
check "! grep -q -- '--off' '$ROOT/simlog-screen'" "missing screen.txt: never blanks"
cp "$REPO/screen.txt" "$SITE/screen.txt"

echo "== 11. Uninstall removes everything =="
bash "$SITE/uninstall.sh" > "$E2E/uninstall.log" 2>&1 && ok "uninstall.sh runs clean" || bad "uninstall.sh errored"
check "! grep -q WARNING '$E2E/uninstall.log'" "uninstall reported no warnings"
LEFT=$(find "$ROOT/etc/systemd/system" "$ROOT/etc/systemd/system.conf.d" "$ROOT/etc/apt/apt.conf.d" "$ROOT/usr/local/bin" "$ROOT/etc/irl-player" "$ROOT/var/lib/irl-player" "$ROOT/opt/irl-gateway" -type f 2>/dev/null | wc -l)
check "[ '$LEFT' = 0 ]" "no installed files left behind"
check "grep -q 'disable --now irl-player-update.timer' '$ROOT/systemctl.log'" "update timer disabled on uninstall"
check "grep -q 'disable --now irl-player-watchdog' '$ROOT/systemctl.log'" "watchdog disabled on uninstall"
check "grep -q 'disable --now irl-player-netwatch' '$ROOT/systemctl.log'" "netwatch disabled on uninstall"
check "grep -q 'disable --now irl-gateway' '$ROOT/systemctl.log'" "gateway disabled on uninstall"
check "! [ -e '$ROOT/opt/irl-gateway/config-ca.pem' ]" "panel-delivered CA removed on uninstall (with mqtt.json)"
check "grep -q 'disable --now irl-player-telemetry.timer' '$ROOT/systemctl.log'" "telemetry timer disabled on uninstall"
check "grep -q 'disable --now irl-player-screen.timer' '$ROOT/systemctl.log'" "screen switch timer disabled on uninstall"
check "grep -q 'disable --now irl-player-reboot.timer' '$ROOT/systemctl.log'" "weekly reboot timer disabled on uninstall"

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
