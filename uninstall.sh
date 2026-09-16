#!/usr/bin/env bash
#
# uninstall.sh — remove MAVLink Router and undo the serial-console changes
#
#   sudo ./uninstall.sh              remove service + binary, restore serial console
#   sudo ./uninstall.sh --keep-conf  leave /etc/mavlink-router alone
#
# Restoring the serial console is the important part: if you ever need to debug
# a board that will not boot, you want console output on header pins 8/10 again.

set -euo pipefail

KEEP_CONF=0
[ "${1:-}" = "--keep-conf" ] && KEEP_CONF=1

ENVFILE="/boot/orangepiEnv.txt"
c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
ok()   { echo "${c_grn}  [ok]${c_off} $*"; }
warn() { echo "${c_yel}  [warn]${c_off} $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Must run as root: sudo $0"; exit 1; }

echo "${c_bld}Removing MAVLink Router${c_off}"

# 1. service
# Plain grep, not grep -q: grep -q exits early, systemctl gets SIGPIPE, and
# `set -o pipefail` would make this guard falsely fail. See BUILD_JOURNAL.md.
if systemctl list-unit-files --no-legend --plain 2>/dev/null | grep '^mavlink-router.service' >/dev/null; then
    systemctl disable --now mavlink-router.service >/dev/null 2>&1 || true
    ok "Stopped and disabled mavlink-router.service"
fi
rm -f /etc/systemd/system/mavlink-router.service
systemctl daemon-reload
ok "Removed systemd unit"

# 2. binary
for p in /usr/bin/mavlink-routerd /usr/local/bin/mavlink-routerd; do
    [ -e "$p" ] && rm -f "$p" && ok "Removed $p"
done

# 3. config
if [ "$KEEP_CONF" -eq 0 ]; then
    if [ -d /etc/mavlink-router ]; then
        rm -rf /etc/mavlink-router
        ok "Removed /etc/mavlink-router"
    fi
else
    ok "Kept /etc/mavlink-router (--keep-conf)"
fi

# 3b. udev rule
if [ -f /etc/udev/rules.d/99-mavlink-router-uart.rules ]; then
    rm -f /etc/udev/rules.d/99-mavlink-router-uart.rules
    udevadm control --reload-rules >/dev/null 2>&1 || true
    ok "Removed udev rule"
fi

# 4. restore the serial console
if [ -f "$ENVFILE" ]; then
    changed=0
    if grep -qE '^console=display' "$ENVFILE"; then
        sed -i 's|^console=display|console=both|' "$ENVFILE"; changed=1
    fi
    if grep -qE '^earlycon=off' "$ENVFILE"; then
        sed -i 's|^earlycon=off|earlycon=on|' "$ENVFILE"; changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        ok "Restored serial console settings in $ENVFILE (console=both, earlycon=on)"
        warn "Reboot required for the serial console to come back"
    else
        ok "$ENVFILE already had console settings at defaults"
    fi
    ls -1 "${ENVFILE}".bak.* 2>/dev/null | tail -3 | while read -r b; do
        echo "        backup available: $b"
    done
fi

systemctl unmask serial-getty@ttyS0.service >/dev/null 2>&1 || true
systemctl enable serial-getty@ttyS0.service  >/dev/null 2>&1 || true
ok "Re-enabled serial-getty@ttyS0.service"

echo
echo "  Done. ${c_bld}sudo reboot${c_off} to fully restore the serial console."
echo "  (The 'dialout' group membership was left in place — harmless.)"
