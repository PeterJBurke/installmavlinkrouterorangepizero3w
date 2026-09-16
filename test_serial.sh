#!/usr/bin/env bash
#
# test_serial.sh — diagnose the MAVLink Router / UART setup on an Orange Pi Zero 3W
#
#   ./test_serial.sh              run all non-destructive checks
#   ./test_serial.sh --loopback   also run a TX->RX loopback test
#                                 (jumper header pin 8 to pin 10 first!)
#   ./test_serial.sh --listen 15  stop the service and sniff the FC for 15s
#
# Safe to run as a normal user (some checks need sudo and will say so).

set -uo pipefail

DEVICE="${MLR_DEVICE:-/dev/ttyS0}"
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
    note "This is /dev/ttyS1's normal state on this board. Use /dev/ttyS0 instead."
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
if command -v gpio >/dev/null 2>&1; then
    echo "        pin 8 / pin 10 should read ALT2 as TXD.0 / RXD.0:"
    gpio readall 2>/dev/null | grep -E 'TXD\.0|RXD\.0' | sed 's/^/        /'
    if gpio readall 2>/dev/null | grep -E 'TXD\.0' | grep 'ALT' >/dev/null; then
        pass "UART0 pins are muxed to their serial function"
    else
        warn "UART0 pins are not in ALT mode"
    fi
else
    warn "wiringOP 'gpio' not installed — skipping pin check"
fi
echo
echo "        ${c_bld}Wiring:${c_off}  pin 8 (TX) -> FC RX  |  pin 10 (RX) -> FC TX  |  pin 6 GND -> FC GND"

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
    echo "        Jumper header ${c_bld}pin 8${c_off} to ${c_bld}pin 10${c_off} (TX to RX), then press Enter."
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
        note "UART0 TX and RX both work. Remove the jumper and wire the FC."
    else
        fail "loopback failed — sent '$MSG', got '${GOT:-<nothing>}'"
        note "Check the jumper is between pin 8 and pin 10, and that the checks above all passed."
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
fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
end, total, v1, v2, seen = time.time() + secs, 0, 0, 0, {}
buf = b""
while time.time() < end:
    try:
        chunk = os.read(fd, 4096)
    except BlockingIOError:
        time.sleep(0.05); continue
    if not chunk:
        time.sleep(0.05); continue
    total += len(chunk); buf += chunk
    while buf:
        i2, i1 = buf.find(b'\xfd'), buf.find(b'\xfe')
        idx = min([x for x in (i2, i1) if x >= 0], default=-1)
        if idx < 0 or len(buf) - idx < 12:
            buf = buf[-280:]; break
        magic = buf[idx]
        if magic == 0xFD:
            plen = buf[idx+1]; total_len = 12 + plen
            if len(buf) - idx < total_len: buf = buf[idx:]; break
            msgid = buf[idx+7] | (buf[idx+8] << 8) | (buf[idx+9] << 16)
            sysid = buf[idx+5]; v2 += 1
        else:
            plen = buf[idx+1]; total_len = 8 + plen
            if len(buf) - idx < total_len: buf = buf[idx:]; break
            msgid = buf[idx+5]; sysid = buf[idx+3]; v1 += 1
        seen.setdefault((sysid, msgid), 0)
        seen[(sysid, msgid)] += 1
        buf = buf[idx+total_len:]
os.close(fd)
print(f"        bytes read: {total}")
print(f"        MAVLink v1 frames: {v1}   v2 frames: {v2}")
if total == 0:
    print("        \033[0;31mNothing received.\033[0m Check: FC powered? TX/RX swapped? baud wrong? GND connected?")
elif v1 + v2 == 0:
    print("        \033[0;33mBytes arrived but no MAVLink frames\033[0m — almost certainly the wrong baud rate.")
else:
    names = {0: "HEARTBEAT", 1: "SYS_STATUS", 24: "GPS_RAW_INT", 30: "ATTITUDE",
             33: "GLOBAL_POSITION_INT", 253: "STATUSTEXT"}
    print("        \033[0;32mMAVLink detected!\033[0m messages by (sysid, msgid):")
    for (s, m), n in sorted(seen.items(), key=lambda kv: -kv[1])[:12]:
        print(f"          sys {s:3d}  msg {m:5d} {names.get(m,''):20s} x{n}")
    if any(m == 0 for (_, m) in seen):
        print("        \033[0;32mHEARTBEAT present — the flight controller is talking.\033[0m")
PY
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
