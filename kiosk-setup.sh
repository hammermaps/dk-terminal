#!/bin/sh
set -eu

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.23}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
KIOSK_HOME="/home/$KIOSK_USER"

# LAN decision
LAN_IP="${LAN_IP:-10.10.12.4}"
LAN_URL="${LAN_URL:-http://ui.internal.dk/}"
FALLBACK_URL="${FALLBACK_URL:-https://rmi.dk-automation.de/}"

# Touch device – stable symlink created by link-touchscreen.sh
TOUCH_EVENT="${TOUCH_EVENT:-/dev/input/touchscreen}"

# Display setup (your working config)
PRIMARY_OUTPUT="${PRIMARY_OUTPUT:-VGA-1}"
DISABLE_OUTPUT="${DISABLE_OUTPUT:-LVDS-1}"

# Chromium DevTools port (local only)
DEBUG_PORT="${DEBUG_PORT:-9222}"

e
"==> Ensure repositories (main+community) are enabled"
if [ -f /etc/apk/repositories ]; then
  sed -i \
    -e "s|^#\\(.*alpine/${ALPINE_BRANCH}/main\\)$|\\1|g" \
    -e "s|^#\\(.*alpine/${ALPINE_BRANCH}/community\\)$|\\1|g" \
    /etc/apk/repositories || true

  grep -q "/${ALPINE_BRANCH}/main" /etc/apk/repositories || \
    echo "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/main" >> /etc/apk/repositories
  grep -q "/${ALPINE_BRANCH}/community" /etc/apk/repositories || \
    echo "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/community" >> /etc/apk/repositories
fi

apk update

e
"==> Install services and packages"
apk add \
  eudev udev-init-scripts \
  elogind seatd \
  xorg-server xinit \
  openbox \
  chromium \
  xinput xrandr \
  mesa-dri-gallium \
  xf86-input-evdev \
  util-linux \
  nano \
  evtest \
  busybox-extras \
  cronie \
  curl \
  jq \
  iputils \
  python3 \
  py3-websockets

e
"==> Enable services"
rc-update add udev default || true
rc-update add udev-settle default || true
rc-update add elogind default || true
rc-update add seatd default || true
rc-update add crond default || true

rc-service udev restart || true
rc-service elogind restart || true
rc-service seatd restart || true
rc-service crond start || true

e
"==> Create kiosk user if missing"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  adduser -D -h "$KIOSK_HOME" "$KIOSK_USER"
fi

e
"==> Add kiosk user to groups (if they exist)"
for g in input video render seat; do
  if getent group "$g" >/dev/null 2>&1; then
    addgroup "$KIOSK_USER" "$g" || true
  fi
done

e
"==> Install link-touchscreen.sh (stable /dev/input/touchscreen symlink)"
mkdir -p /usr/local/sbin

cat > /usr/local/sbin/link-touchscreen.sh <<'SH'
#!/bin/sh
set -eu

LINK="/dev/input/touchscreen"
TARGET=""

for ev in /sys/class/input/event*; do
  [ -r "$ev/device/name" ] || continue
  name="$(cat "$ev/device/name" 2>/dev/null || true)"

  # Need an eGalax device …
  echo "$name" | grep -qi "egalax" || continue
  # … but NOT the high-level "… Touchscreen" node; we want the raw one
  echo "$name" | grep -qi "touchscreen" && continue

  base="$(basename "$ev")"   # e.g. event3
  TARGET="/dev/input/$base"
  break
done

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
  echo "link-touchscreen: no suitable eGalax RAW event found" >&2
  exit 1
fi

mkdir -p /dev/input
ln -sf "$TARGET" "$LINK"
echo "link-touchscreen: $LINK -> $TARGET" >&2
SH
chmod +x /usr/local/sbin/link-touchscreen.sh

e
"==> Install udev rule so the symlink is re-created on every (re-)plug"
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/99-touchscreen.rules <<'RULES'
# Re-run link-touchscreen.sh whenever any eGalax input event node appears
# so /dev/input/touchscreen always points to the correct raw device.
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="*[Ee][Gg]alax*", \
    RUN+="/usr/local/sbin/link-touchscreen.sh"
RULES

# Apply rule immediately if udev is running; fail silently otherwise
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=input 2>/dev/null || true

# Also run once right now so the symlink is ready before X starts
echo "==> Creating /dev/input/touchscreen symlink (may fail if device is absent)"
/usr/local/sbin/link-touchscreen.sh || true
ls -l /dev/input/touchscreen 2>/dev/null || true

e
"==> Ensure Xorg config dir exists"
mkdir -p /etc/X11/xorg.conf.d


e
"==> Force Xorg to use fixed touch event device (no udev hotplug)"
cat > /etc/X11/xorg.conf.d/10-serverflags-no-udev.conf <<'CONF'
Section "ServerFlags"
    Option "AutoAddDevices" "false"
    Option "AutoEnableDevices" "false"
EndSection
CONF

cat > /etc/X11/xorg.conf.d/20-touch-event.conf <<CONF
Section "InputDevice"
    Identifier  "TouchscreenEvent"
    Driver      "evdev"
    Option      "Device" "${TOUCH_EVENT}"
    Option      "EmulateThirdButton" "false"
    Option      "EmulateThirdButtonTimeout" "50"
EndSection

Section "ServerLayout"
    Identifier "Layout0"
    InputDevice "TouchscreenEvent" "CorePointer"
EndSection
CONF


e
"==> URL selector (ping + HTTP verify)"
cat > /usr/local/bin/select-start-url.sh <<SH
#!/bin/sh
set -eu
LAN_IP="${LAN_IP}"
LAN_URL="${LAN_URL}"
FALLBACK_URL="${FALLBACK_URL}"

if ping -c 1 -W 1 "\$LAN_IP" >/dev/null 2>&1; then
  if curl -fsS --max-time 2 "\$LAN_URL" >/dev/null 2>&1; then
    echo "\$LAN_URL"
    exit 0
  fi
fi
echo "\$FALLBACK_URL"
SH
chmod +x /usr/local/bin/select-start-url.sh

e
"==> DevTools navigate tool (Python websockets)"
cat > /usr/local/bin/chromium-navigate.py <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
import asyncio
import websockets

PORT = int(os.environ.get("DEBUG_PORT", "9222"))

def get_ws_url():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/list", timeout=2) as r:
        data = json.loads(r.read().decode("utf-8"))
    for t in data:
        if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    for t in data:
        if t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    return None

async def main(url: str):
    ws = get_ws_url()
    if not ws:
        print("No webSocketDebuggerUrl found", file=sys.stderr)
        return 2

    async with websockets.connect(ws, ping_interval=None) as websocket:
        await websocket.send(json.dumps({"id": 1, "method": "Page.enable"}))
        await websocket.send(json.dumps({"id": 2, "method": "Page.navigate", "params": {"url": url}}))

        for _ in range(10):
            try:
                msg = await asyncio.wait_for(websocket.recv(), timeout=1)
            except asyncio.TimeoutError:
                break
            try:
                obj = json.loads(msg)
            except Exception:
                continue
            if obj.get("id") == 2:
                return 0
    return 0

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: chromium-navigate.py <url>", file=sys.stderr)
        sys.exit(2)
    sys.exit(asyncio.run(main(sys.argv[1])))
PY
chmod +x /usr/local/bin/chromium-navigate.py

e
"==> Watchdog (debounced ping+HTTP; navigates via DevTools)"
cat > /usr/local/bin/chromium-devtools-watchdog.sh <<SH
#!/bin/sh
set -eu
LAN_IP="${LAN_IP}"
LAN_URL="${LAN_URL}"
FALLBACK_URL="${FALLBACK_URL}"
DEBUG_PORT="${DEBUG_PORT}"

INTERVAL="\$INTERVAL:-10}"
NEEDED_OK="\$NEEDED_OK:-3}"
NEEDED_FAIL="\$NEEDED_FAIL:-3}"

ok=0
fail=0
last=""

sleep 3

lan_ok() {
  ping -c 1 -W 1 "\$LAN_IP" >/dev/null 2>&1 || return 1
  curl -fsS --max-time 2 "\$LAN_URL" >/dev/null 2>&1
}

while true; do
  if lan_ok; then
    ok=\$((ok+1)); fail=0
  else
    fail=\$((fail+1)); ok=0
  fi

  if [ "\$ok" -ge "\$NEEDED_OK" ]; then
    target="\$LAN_URL"
  elif [ "\$fail" -ge "\$NEEDED_FAIL" ]; then
    target="\$FALLBACK_URL"
  else
    target="\$last"
  fi

  if [ -n "\$target" ] && [ "\$target" != "\$last" ]; then
    DEBUG_PORT="\$DEBUG_PORT" /usr/local/bin/chromium-navigate.py "\$target" >>"/home/${KIOSK_USER}/chromium.log" 2>&1 || true
    last="\$target"
  fi

  sleep "\$INTERVAL"
done
SH
chmod +x /usr/local/bin/chromium-devtools-watchdog.sh

e
"==> Write kiosk .xinitrc (chromium + devtools watchdog)"
install -d -m 0755 -o "$KIOSK_USER" -g "$KIOSK_USER" "$KIOSK_HOME"

cat > "$KIOSK_HOME/.xinitrc" <<XINIT
#!/bin/sh

xset s off
xset -dpms
xset s noblank

xrandr --output ${DISABLE_OUTPUT} --off --output ${PRIMARY_OUTPUT} --auto --primary || true

openbox-session &
sleep 0.5

TARGET_URL="\$(/usr/local/bin/select-start-url.sh || echo '${FALLBACK_URL}')"

# Uncomment --kiosk once the Chromium extension (OSK) is confirmed working
# CHROMIUM_EXTRA_FLAGS="--kiosk --disable-infobars --disable-session-crashed-bubble"
CHROMIUM_EXTRA_FLAGS=""

while true; do
  chromium \
    --no-first-run \
    --disable-features=TranslateUI \
    --no-sandbox \
    --disable-gpu \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port=${DEBUG_PORT} \
    \
    "\$TARGET_URL" \
    >>"\$HOME/chromium.log" 2>&1
  sleep 2
done &

# Watchdog switches URL without restart
INTERVAL=10 NEEDED_OK=3 NEEDED_FAIL=3 /usr/local/bin/chromium-devtools-watchdog.sh &

wait
XINIT

chmod +x "$KIOSK_HOME/.xinitrc"
chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.xinitrc"

e
"==> Write kiosk .profile (autostart X on tty1 with emergency exit)"
cat > "$KIOSK_HOME/.profile" <<'PROFILE'
if [ -z "${DISPLAY:-}" ] && [ "
$(tty)" = "/dev/tty1" ]; then
  if [ -f "$HOME/.no-kiosk" ]; then
    echo "KIOSK disabled (found $HOME/.no-kiosk). Staying on console."
  else
    exec startx
  fi
fi
PROFILE

chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.profile"
chmod 0644 "$KIOSK_HOME/.profile"

e
"==> Configure autologin on tty1 via /etc/inittab (OpenRC)"
AGETTY_PATH="
$(command -v agetty || true)"
if [ -z "$AGETTY_PATH" ]; then
  echo "ERROR: agetty not found even after installing util-linux."
  exit 1
fi

if [ -f /etc/inittab ]; then
  cp -a /etc/inittab /etc/inittab.bak.$(date +%Y%m%d%H%M%S)
  sed -i '/^[^#].*tty1/d' /etc/inittab
  cat >> /etc/inittab <<INITTAB

# Kiosk autologin on tty1
tty1::respawn:${AGETTY_PATH} --autologin ${KIOSK_USER} --noclear 38400 tty1 linux
INITTAB
else
  echo "WARN: /etc/inittab not found. Autologin not configured."
fi

e
"==> Install weekly (Sunday) auto-upgrade cron job"
mkdir -p /usr/local/sbin

cat > /usr/local/sbin/kiosk-upgrade.sh <<'SH'
#!/bin/sh
set -eu

LOG="/var/log/kiosk-upgrade.log"
STAMP="$(date -Iseconds)"

# Prevent log from growing unbounded
tail -n 200 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG" || true

echo "[$STAMP] starting apk update/upgrade" >> "$LOG"
apk update >>"$LOG" 2>&1 || true

OUT="$(apk upgrade 2>&1 | tee -a "$LOG" || true)"

if ! echo "$OUT" | grep -Eq 'Upgrading |Installing '; then
  echo "[$STAMP] no upgrades" >> "$LOG"
  exit 0
fi

if echo "$OUT" | grep -Eiq 'Upgrading (linux-|linux-lts|linux-virt|linux-firmware|musl)\b'; then
  echo "[$STAMP] reboot required (kernel/musl upgraded)" >> "$LOG"
  /sbin/reboot
else
  echo "[$STAMP] upgrade done, no reboot triggered" >> "$LOG"
fi
SH
chmod +x /usr/local/sbin/kiosk-upgrade.sh

touch /etc/crontabs/root
grep -qF "/usr/local/sbin/kiosk-upgrade.sh" /etc/crontabs/root || \
  echo "17 3 * * 0 /usr/local/sbin/kiosk-upgrade.sh" >> /etc/crontabs/root

rc-service crond restart || true

echo ""
echo "DONE."
echo "LAN decision:"
echo "  - Ping IP: ${LAN_IP}"
echo "  - LAN URL (DNS must work): ${LAN_URL}"
echo "  - Fallback: ${FALLBACK_URL}"
echo ""
echo "Reboot recommended: reboot"