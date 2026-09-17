#!/usr/bin/env bash
#
# test_serial.sh — diagnose the MAVLink Router / UART setup on an Orange Pi Zero 3W
#
#   ./test_serial.sh              run all non-destructive checks
#   ./test_serial.sh --loopback   also run a TX->RX loopback test
#                                 (jumper the UART's TX and RX pins first --
#                                  pins 11 and 13 for the default UART2)
#   ./test_serial.sh --listen 15  stop the service and sniff the FC for 15s
#
# Safe to run as a normal user (some checks need sudo and will say so).

set -uo pipefail

DEVICE="${MLR_DEVICE:-/dev/ttyS2}"
BAUD="${MLR_BAUD:-57600}"
TCP_PORT="${MLR_TCP_PORT:-5678}"
CONF="/etc/mavlink-router/main.conf"

MODE="checks"; LISTEN_SECS=15
while [ $# -gt 0 ]; do
    case "$1" in
        --loopback) MODE="loopback" ;;
        --listen)   MODE="listen"; [ -n "${2:-}" ] && [[ "${2:-}" =~ ^[0-9]+$ ]] && { LISTEN_SECS="$2"; shift; } ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Header pin map per UART -- schematic p.18 "EXT I/O" + manual s.3.16.5
pins_for_device() { # -> "TXpin RXpin GNDpin label"
    case "$1" in
        /dev/ttyS0) echo "8 10 6 UART0" ;;
        /dev/ttyS2) echo "11 13 14 UART2" ;;
        /dev/ttyS6) echo "24 23 20 UART6" ;;
        /dev/ttyS7) echo "16 18 20 UART7" ;;
        *)          echo "? ? ? unknown" ;;
    esac
}

c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
pass() { echo "${c_grn}  PASS${c_off}  $*"; }
fail() { echo "${c_red}  FAIL${c_off}  $*"; FAILURES=$((FAILURES+1)); }
warn() { echo "${c_yel}  WARN${c_off}  $*"; }
note() { echo "        $*"; }
hdr()  { echo; echo "${c_blu}${c_bld}$*${c_off}"; }
FAILURES=0

# Read main.conf if present so we test what is actually configured
if [ -r "$CONF" ]; then
    d=$(grep -iE '^\s*Device\s*=' "$CONF" | head -1 | cut -d= -f2- | tr -d ' ')
    b=$(grep -iE '^\s*Baud\s*=' "$CONF" | head -1 | cut -d= -f2- | tr -d ' ' | cut -d, -f1)
    p=$(grep -iE '^\s*TcpServerPort\s*=' "$CONF" | head -1 | cut -d= -f2- | tr -d ' ')
    [ -n "${d:-}" ] && DEVICE="$d"
    [ -n "${b:-}" ] && BAUD="$b"
    [ -n "${p:-}" ] && TCP_PORT="$p"
fi

echo "${c_bld}MAVLink Router serial diagnostics${c_off}"
echo "device=$DEVICE baud=$BAUD tcp=$TCP_PORT"

# ---------------------------------------------------------------- 1. hardware
hdr "1. Board"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
if [ "$MODEL" = "sun60iw2" ]; then
    pass "Orange Pi Zero 3W (A733 / sun60iw2)"
else
    warn "Unexpected model '$MODEL' — pin numbers below may differ"
fi

# ---------------------------------------------------------------- 2. the port
hdr "2. Serial device"
if [ -c "$DEVICE" ]; then
    pass "$DEVICE exists  ($(stat -c '%U:%G %a' "$DEVICE"))"
else
    fail "$DEVICE does not exist"
fi

if [ -r "$DEVICE" ] && [ -w "$DEVICE" ]; then
    pass "readable and writable by $(whoami)"
else
    fail "not read/write for $(whoami) — are you in 'dialout'? (groups: $(groups))"
    note "fix: sudo usermod -aG dialout $(whoami)   then log out and back in"
fi

# The Bluetooth trap: line discipline 15 = N_HCI
LDISC="$(stty -F "$DEVICE" -a 2>/dev/null | grep -oE 'line = [0-9]+' | grep -oE '[0-9]+' || echo '?')"
if [ "$LDISC" = "15" ]; then
    fail "line discipline is 15 (N_HCI) — $DEVICE is bound to Bluetooth, writes will hang"
    note "This is /dev/ttyS1's normal state on this board. Use /dev/ttyS2 instead."
elif [ "$LDISC" = "0" ]; then
    pass "line discipline 0 (N_TTY) — normal serial"
else
    warn "line discipline $LDISC (expected 0)"
fi

if ps aux 2>/dev/null | grep "[h]ciattach.*$DEVICE" >/dev/null; then
    fail "hciattach is holding $DEVICE (Bluetooth). Pick a different UART."
fi

# ------------------------------------------------------------- 3. console/getty
hdr "3. Console contention"
if grep -q "console=${DEVICE#/dev/}" /proc/cmdline; then
    fail "kernel console is still on $DEVICE — it will inject boot text into your FC"
    note "fix: add 'console=display' and 'earlycon=off' to /boot/orangepiEnv.txt, then reboot"
    note "current cmdline: $(cat /proc/cmdline)"
else
    pass "kernel console is not on $DEVICE"
fi

GETTY="serial-getty@${DEVICE#/dev/}.service"
# NOTE: `systemctl is-enabled` prints "masked" but EXITS NON-ZERO for a masked
# unit, so `|| echo not-found` would append a second line to the value.
GSTATE="$(systemctl is-enabled "$GETTY" 2>/dev/null || true)"
[ -z "$GSTATE" ] && GSTATE="not-found"
if [ "$GSTATE" = "enabled" ] || systemctl is-active --quiet "$GETTY" 2>/dev/null; then
    fail "$GETTY is active/enabled — a login prompt is fighting for the port"
    note "fix: sudo systemctl disable --now $GETTY && sudo systemctl mask $GETTY"
else
    pass "$GETTY is $GSTATE"
fi

# ---------------------------------------------------------------- 4. pin state
hdr "4. 40-pin header"
read -r PIN_TX PIN_RX PIN_GND PIN_LABEL <<<"$(pins_for_device "$DEVICE")"

if [ "$PIN_LABEL" = "unknown" ]; then
    warn "No known header pin map for $DEVICE"
else
    if command -v gpio >/dev/null 2>&1; then
        echo "        pins $PIN_TX / $PIN_RX should be muxed to $PIN_LABEL (ALT mode, not OFF):"
        gpio readall 2>/dev/null | awk -v a="$PIN_TX" -v b="$PIN_RX" \
            -F'|' '{gsub(/ /,"",$7); gsub(/ /,"",$8); if ($7==a || $8==a || $7==b || $8==b) print "        "$0}'
        if gpio readall 2>/dev/null | awk -v a="$PIN_TX" -F'|' \
             '{gsub(/ /,"",$7); gsub(/ /,"",$8); if ($7==a || $8==a) print $0}' | grep 'ALT' >/dev/null; then
            pass "pin $PIN_TX is muxed to an alternate (peripheral) function"
        else
            fail "pin $PIN_TX is NOT in ALT mode — is the '$PIN_LABEL' overlay enabled?"
            note "fix: add 'overlays=${PIN_LABEL,,}' to /boot/orangepiEnv.txt and reboot"
        fi
    else
        warn "wiringOP 'gpio' not installed — skipping pin check"
    fi
    echo
    echo "        ${c_bld}Wiring:${c_off}  pin $PIN_TX (TX) -> FC RX  |  pin $PIN_RX (RX) -> FC TX  |  pin $PIN_GND GND -> FC GND"
fi

# The overlay is what makes ttyS2/6/7/8 exist at all.
case "$DEVICE" in
    /dev/ttyS[2678])
        OV="uart${DEVICE#/dev/ttyS}"
        if grep -qE "^overlays=.*\b${OV}\b" /boot/orangepiEnv.txt 2>/dev/null; then
            pass "overlay '$OV' is enabled in /boot/orangepiEnv.txt"
        else
            fail "overlay '$OV' is NOT in /boot/orangepiEnv.txt — $DEVICE will not exist"
        fi
        ;;
esac

# ---------------------------------------------------------------- 5. software
hdr "5. mavlink-router"
if command -v mavlink-routerd >/dev/null 2>&1; then
    pass "mavlink-routerd installed: $(mavlink-routerd --version 2>/dev/null)"
else
    fail "mavlink-routerd not found on PATH"
fi

[ -r "$CONF" ] && pass "config present: $CONF" || fail "missing $CONF"

if systemctl is-active --quiet mavlink-router.service 2>/dev/null; then
    pass "mavlink-router.service is running"
else
    fail "mavlink-router.service is not running"
    note "check: journalctl -u mavlink-router -n 40 --no-pager"
fi

if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep ":$TCP_PORT" >/dev/null; then
        pass "listening on TCP $TCP_PORT"
        IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
        note "connect a GCS to:  tcp:${IP:-<pi-ip>}:$TCP_PORT"
    else
        fail "nothing listening on TCP $TCP_PORT"
    fi
fi

# ---------------------------------------------------------------- 6. loopback
if [ "$MODE" = "loopback" ]; then
    hdr "6. Loopback test"
    read -r PIN_TX PIN_RX PIN_GND PIN_LABEL <<<"$(pins_for_device "$DEVICE")"
    echo "        Jumper header ${c_bld}pin $PIN_TX${c_off} to ${c_bld}pin $PIN_RX${c_off} ($PIN_LABEL TX to RX), then press Enter."
    read -r _
    if systemctl is-active --quiet mavlink-router.service 2>/dev/null; then
        echo "        stopping mavlink-router for the test..."
        sudo systemctl stop mavlink-router.service
        RESTART=1
    fi
    stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb -crtscts raw -echo
    MSG="MAVLINK-ROUTER-LOOPBACK-$$"
    exec 3<> "$DEVICE" || { fail "cannot open $DEVICE"; exit 1; }
    ( printf '%s\n' "$MSG" >&3 ) &
    GOT=""
    if read -r -t 3 GOT <&3; then :; fi
    exec 3<&-; exec 3>&-
    if [ "${GOT:-}" = "$MSG" ]; then
        pass "loopback OK — sent and received '$MSG'"
        note "$PIN_LABEL TX (pin $PIN_TX) and RX (pin $PIN_RX) both work. Remove the jumper and wire the FC."
    else
        fail "loopback failed — sent '$MSG', got '${GOT:-<nothing>}'"
        note "Check the jumper is between pin $PIN_TX and pin $PIN_RX, and that the checks above all passed."
    fi
    [ "${RESTART:-0}" = "1" ] && sudo systemctl start mavlink-router.service
fi

# ------------------------------------------------------- 7. listen for the FC
if [ "$MODE" = "listen" ]; then
    hdr "7. Listening for MAVLink from the flight controller (${LISTEN_SECS}s)"
    if systemctl is-active --quiet mavlink-router.service 2>/dev/null; then
        echo "        stopping mavlink-router so we can read the port directly..."
        sudo systemctl stop mavlink-router.service
        RESTART=1
    fi
    stty -F "$DEVICE" "$BAUD" cs8 -cstopb -parenb -crtscts raw -echo
    echo "        reading $DEVICE at $BAUD baud..."
    python3 - "$DEVICE" "$LISTEN_SECS" <<'PY'
import os, sys, time

dev, secs = sys.argv[1], int(sys.argv[2])

# A frame counts as MAVLink only if its X.25 CRC checks out. Without this, any
# stray 0xFE/0xFD in line noise looks like a frame and the tool lies to you --
# which it did, reporting "MAVLink detected!" on an unconnected pin.
CRC_EXTRA = {0:50, 1:124, 2:137, 4:237, 22:220, 24:24, 27:144, 29:115, 30:39,
             32:185, 33:104, 35:244, 36:222, 42:28, 62:183, 65:118, 74:20,
             77:143, 111:34, 116:127, 125:203, 147:154, 165:47, 193:71,
             241:90, 253:83}
NAMES = {0:"HEARTBEAT", 1:"SYS_STATUS", 2:"SYSTEM_TIME", 24:"GPS_RAW_INT",
         27:"RAW_IMU", 30:"ATTITUDE", 33:"GLOBAL_POSITION_INT",
         36:"SERVO_OUTPUT_RAW", 42:"MISSION_CURRENT", 62:"NAV_CONTROLLER_OUTPUT",
         65:"RC_CHANNELS", 74:"VFR_HUD", 147:"BATTERY_STATUS", 241:"VIBRATION",
         253:"STATUSTEXT"}

def x25(data, extra):
    crc = 0xFFFF
    for b in tuple(data) + (extra,):
        t = (b ^ (crc & 0xFF)) & 0xFF
        t = (t ^ (t << 4)) & 0xFF
        crc = ((crc >> 8) ^ (t << 8) ^ (t << 3) ^ (t >> 4)) & 0xFFFF
    return crc

# Capture first, parse afterwards. Parsing a growing stream means one bogus
# length byte from noise can stall the scan; over a fixed buffer we can simply
# skip an unusable candidate and resync.
fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
end_at = time.time() + secs
data = bytearray()
while time.time() < end_at:
    try:
        chunk = os.read(fd, 4096)
    except (BlockingIOError, OSError):
        time.sleep(0.02); continue
    if chunk:
        data += chunk
    else:
        time.sleep(0.02)
os.close(fd)

buf = bytes(data); n = len(buf)
good = {}; bad = 0; unknown = 0; magic = 0; i = 0
while i < n:
    m = buf[i]
    if m not in (0xFD, 0xFE):
        i += 1; continue
    magic += 1
    if m == 0xFE:
        if n - i < 8: i += 1; continue
        plen = buf[i+1]; flen = 8 + plen
        if n - i < flen: i += 1; continue
        msgid = buf[i+5]; sysid = buf[i+3]; body = buf[i+1:i+6+plen]
    else:
        if n - i < 12: i += 1; continue
        plen = buf[i+1]; flen = 12 + plen
        if n - i < flen: i += 1; continue
        msgid = buf[i+7] | (buf[i+8] << 8) | (buf[i+9] << 16)
        sysid = buf[i+5]; body = buf[i+1:i+10+plen]
    ck = buf[i+flen-2] | (buf[i+flen-1] << 8)
    ex = CRC_EXTRA.get(msgid)
    if ex is None:
        unknown += 1; i += 1; continue
    if x25(body, ex) == ck:
        good[(sysid, msgid)] = good.get((sysid, msgid), 0) + 1
        i += flen
    else:
        bad += 1; i += 1

rate = n / float(secs) if secs else 0.0
nframes = sum(good.values())
print("        bytes read: %d  (%.1f bytes/sec)" % (n, rate))
print("        CRC-valid MAVLink frames: %d" % nframes)
print("        (magic bytes seen: %d, rejected by CRC: %d, unknown msgid: %d)"
      % (magic, bad, unknown))
print("")

if n == 0:
    print("        \033[0;31mNothing received at all.\033[0m")
    print("        -> FC unpowered, TX/RX not crossed, or GND not shared.")
elif nframes == 0 and rate < 50:
    print("        \033[0;31mNo valid MAVLink. This looks like LINE NOISE, not data.\033[0m")
    print("        Only %.1f bytes/sec, none of it correctly framed. An undriven" % rate)
    print("        UART pin produces exactly this: a byte count that rises with baud.")
    print("        -> The FC's TX is probably not reaching this pin.")
    print("        -> A connected, idle UART TX holds the line at ~3.3V. Measure it:")
    print("           floating or 0V means it is not connected.")
    print("        -> Also confirm GND is shared and the FC is powered and booted.")
elif nframes == 0:
    print("        \033[0;31mNo valid MAVLink frames, but %.0f bytes/sec is a real stream.\033[0m" % rate)
    print("        -> Wiring is good; the BAUD RATE is wrong.")
    print("        -> Try: ./test_serial.sh --scan   to sweep common rates.")
else:
    print("        \033[0;32mReal MAVLink confirmed (CRC verified).\033[0m")
    for (sid, mid), c in sorted(good.items(), key=lambda kv: -kv[1])[:12]:
        print("          sys %3d  msg %5d %-22s x%d" % (sid, mid, NAMES.get(mid, ""), c))
    if any(mid == 0 for (_, mid) in good):
        print("        \033[0;32mHEARTBEAT present - the flight controller is talking.\033[0m")
    else:
        print("        \033[0;33mNo HEARTBEAT yet - the FC may still be booting.\033[0m")

sys.exit(0 if nframes else 1)
PY
    if [ $? -eq 0 ]; then
        pass "MAVLink received from the flight controller"
    else
        fail "no valid MAVLink received on $DEVICE"
    fi
    [ "${RESTART:-0}" = "1" ] && sudo systemctl start mavlink-router.service
fi

# ------------------------------------------------------------------- verdict
hdr "Summary"
if [ "$FAILURES" -eq 0 ]; then
    echo "${c_grn}${c_bld}  All checks passed.${c_off}"
else
    echo "${c_red}${c_bld}  $FAILURES check(s) failed.${c_off} See the fix hints above."
fi
echo
exit $(( FAILURES > 0 ? 1 : 0 ))
