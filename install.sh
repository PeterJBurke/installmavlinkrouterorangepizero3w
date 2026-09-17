#!/usr/bin/env bash
#
# install.sh — MAVLink Router for Orange Pi Zero 3W (Allwinner A733 / sun60iw2)
#
# Takes a FRESH, BARE Ubuntu install on an Orange Pi Zero 3W all the way to a
# running mavlink-routerd talking to a flight controller over UART0.
#
# Usage:
#   wget -O install.sh https://raw.githubusercontent.com/PeterJBurke/installmavlinkrouterorangepizero3w/main/install.sh
#   chmod +x install.sh
#   sudo ./install.sh 2>&1 | tee MavlinkRouterBuildlog.txt
#
# Options (environment variables):
#   MLR_DEVICE=/dev/ttyS2     serial device given to the flight controller
#   MLR_BAUD=57600            flight controller telemetry baud
#   MLR_TCP_PORT=5678         TCP port mavlink-router serves on
#   MLR_FORCE_SOURCE=1        always compile from source, ignore the prebuilt binary
#   MLR_KEEP_CONSOLE=1        do NOT free the serial console (use with MLR_DEVICE=/dev/ttySN)
#   MLR_UART_OVERLAY=uart2    additionally enable a UART overlay (uart2|uart6|uart7|uart8)
#   MLR_WIFI_POWERSAVE_OFF=0  do NOT disable Wi-Fi power save (default is to disable it)
#
# Everything this script does, and why, is documented in docs/BUILD_JOURNAL.md.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/PeterJBurke/installmavlinkrouterorangepizero3w/main"
UPSTREAM_GIT="https://github.com/mavlink-router/mavlink-router.git"

MLR_DEVICE="${MLR_DEVICE:-/dev/ttyS2}"
MLR_BAUD="${MLR_BAUD:-57600}"
MLR_TCP_PORT="${MLR_TCP_PORT:-5678}"
MLR_FORCE_SOURCE="${MLR_FORCE_SOURCE:-0}"
MLR_KEEP_CONSOLE="${MLR_KEEP_CONSOLE:-0}"
MLR_UART_OVERLAY="${MLR_UART_OVERLAY:-}"
MLR_WIFI_POWERSAVE_OFF="${MLR_WIFI_POWERSAVE_OFF:-1}"

# UART2/6/7/8 are disabled in the base DTB and need a device-tree overlay.
# Derive the overlay from the chosen device unless the caller named one.
if [ -z "$MLR_UART_OVERLAY" ]; then
    case "$MLR_DEVICE" in
        /dev/ttyS2) MLR_UART_OVERLAY="uart2" ;;
        /dev/ttyS6) MLR_UART_OVERLAY="uart6" ;;
        /dev/ttyS7) MLR_UART_OVERLAY="uart7" ;;
        /dev/ttyS8) MLR_UART_OVERLAY="uart8" ;;
    esac
fi

# glibc floor of the prebuilt binary (see BUILD_JOURNAL.md gotcha #9)
PREBUILT_GLIBC_REQ="2.42"

# Header pin map per UART, from the OPi Zero 3W V1.2 schematic (page 18,
# "EXT I/O") and the vendor manual section 3.16.5.
#   UART0  PB9/PB10   pins 8 (TX) / 10 (RX)  - also the CPU DEBUG net, via 1K
#   UART2  PB0/PB1    pins 11 (TX) / 13 (RX)
#   UART6             pins 24 (TX) / 23 (RX)
#   UART7             pins 16 (TX) / 18 (RX)
pins_for_device() { # -> "TXpin RXpin GNDpin label"
    case "$1" in
        /dev/ttyS0) echo "8 10 6 UART0" ;;
        /dev/ttyS2) echo "11 13 14 UART2" ;;
        /dev/ttyS6) echo "24 23 20 UART6" ;;
        /dev/ttyS7) echo "16 18 20 UART7" ;;
        *)          echo "? ? ? unknown" ;;
    esac
}

BIN_DIR="/usr/bin"
CONF_DIR="/etc/mavlink-router"
UNIT="/etc/systemd/system/mavlink-router.service"
ENVFILE="/boot/orangepiEnv.txt"
REBOOT_REQUIRED=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- pretty output
c_red=$'\033[0;31m'; c_grn=$'\033[0;32m'; c_yel=$'\033[0;33m'
c_blu=$'\033[0;34m'; c_bld=$'\033[1m';    c_off=$'\033[0m'
step() { echo; echo "${c_blu}${c_bld}==> $*${c_off}"; }
ok()   { echo "${c_grn}  [ok]${c_off} $*"; }
warn() { echo "${c_yel}  [warn]${c_off} $*"; }
die()  { echo "${c_red}  [FAIL]${c_off} $*" >&2; exit 1; }
info() { echo "  $*"; }

START_TIME=$(date -u +%s)

# ------------------------------------------------------------------ preflight
step "Preflight checks"

[ "$(id -u)" -eq 0 ] || die "Must run as root. Try: sudo $0"

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || die "This installer is for aarch64. Detected: $ARCH"
ok "Architecture: $ARCH"

MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
info "Board model string: '$MODEL'"
if [ "$MODEL" = "sun60iw2" ]; then
    ok "Orange Pi Zero 3W (Allwinner A733 / sun60iw2) confirmed"
else
    warn "Expected 'sun60iw2' (A733 Zero 3W). Got '$MODEL'."
    warn "Continuing, but the UART configuration below may not match your board."
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
fi

# The real user, so we can put them in dialout even under sudo
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || echo orangepi)"
fi
info "Target (non-root) user: $TARGET_USER"

# ------------------------------------------------------- already installed?
ALREADY_INSTALLED=0
if command -v mavlink-routerd >/dev/null 2>&1; then
    ALREADY_INSTALLED=1
    info "Existing mavlink-routerd: $(command -v mavlink-routerd) ($(mavlink-routerd --version 2>/dev/null || echo 'version unknown'))"
fi

# ------------------------------------------------------------ helper functions
glibc_version() {
    ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | tail -1
}

version_ge() { # version_ge A B  -> true if A >= B
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

fetch() { # fetch <url> <dest>   (curl or wget, whichever exists)
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        return 1
    fi
}

# ------------------------------------------------------------ 1. dependencies
step "Installing base packages"

export DEBIAN_FRONTEND=noninteractive
# NOTE: a fresh image already has git/gcc/g++/pkg-config, but NOT meson/ninja,
# and NOT python3-pip/python3-venv (so a pip-based meson is not an option).
apt-get update -qq
apt-get install -y -qq curl ca-certificates systemd
ok "Base packages present"

# ----------------------------------------------- 2. obtain mavlink-routerd
install_prebuilt() {
    local tmp="/tmp/mavlink-routerd.$$"
    local src="$SCRIPT_DIR/bin/orangepizero3w-aarch64/mavlink-routerd"

    if [ -f "$src" ]; then
        info "Using binary shipped alongside this script"
        cp "$src" "$tmp"
    else
        info "Downloading prebuilt binary from GitHub"
        fetch "$REPO_RAW/bin/orangepizero3w-aarch64/mavlink-routerd" "$tmp" || return 1
    fi

    chmod +x "$tmp"
    # Prove it actually runs on THIS system before installing it.
    if ! "$tmp" --version >/dev/null 2>&1; then
        warn "Prebuilt binary did not execute on this system"
        rm -f "$tmp"; return 1
    fi
    install -m 755 "$tmp" "$BIN_DIR/mavlink-routerd"
    rm -f "$tmp"
    return 0
}

build_from_source() {
    step "Compiling mavlink-router from source"
    info "Installing build toolchain (meson, ninja, compilers)"
    apt-get install -y -qq git meson ninja-build pkg-config gcc g++

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    info "Cloning $UPSTREAM_GIT"
    # NOTE: upstream moved from intel/mavlink-router to mavlink-router/mavlink-router
    git clone --depth 1 "$UPSTREAM_GIT" "$tmp/mavlink-router"
    # The MAVLink C headers live in a submodule; meson fails without this.
    git -C "$tmp/mavlink-router" submodule update --init --recursive

    # -Dsystemdsystemunitdir avoids needing libsystemd-dev just to look up a path.
    meson setup "$tmp/mavlink-router/build" "$tmp/mavlink-router" \
        -Dsystemdsystemunitdir=/usr/lib/systemd/system \
        --buildtype=release
    ninja -C "$tmp/mavlink-router/build"
    install -m 755 "$tmp/mavlink-router/build/src/mavlink-routerd" "$BIN_DIR/mavlink-routerd"
    ok "Compiled and installed from source"
}

step "Installing mavlink-routerd"

if [ "$ALREADY_INSTALLED" -eq 1 ] && [ "$MLR_FORCE_SOURCE" != "1" ]; then
    ok "mavlink-routerd already installed — skipping (set MLR_FORCE_SOURCE=1 to rebuild)"
else
    HOST_GLIBC="$(glibc_version)"
    info "Host glibc: ${HOST_GLIBC:-unknown}; prebuilt binary needs >= $PREBUILT_GLIBC_REQ"

    USE_PREBUILT=1
    [ "$MLR_FORCE_SOURCE" = "1" ] && USE_PREBUILT=0 && info "MLR_FORCE_SOURCE=1 — skipping prebuilt"
    if [ "$USE_PREBUILT" = "1" ] && [ -n "$HOST_GLIBC" ] && ! version_ge "$HOST_GLIBC" "$PREBUILT_GLIBC_REQ"; then
        warn "glibc $HOST_GLIBC < $PREBUILT_GLIBC_REQ — prebuilt binary cannot run here"
        USE_PREBUILT=0
    fi

    if [ "$USE_PREBUILT" = "1" ] && install_prebuilt; then
        ok "Installed prebuilt mavlink-routerd"
    else
        [ "$USE_PREBUILT" = "1" ] && warn "Prebuilt install failed — falling back to source"
        build_from_source
    fi
fi

command -v mavlink-routerd >/dev/null 2>&1 || die "mavlink-routerd is still not on PATH"
ok "mavlink-routerd: $("$BIN_DIR/mavlink-routerd" --version 2>/dev/null || echo installed)"

# ------------------------------------------------------- 3. UART configuration
step "Configuring the serial port for the flight controller"

# --- 3a. serial console: free it for UART0, or restore it otherwise ---------
# Only UART0 (header pins 8/10) collides with the console. For any other UART
# we actively RESTORE the console, so that switching from a ttyS0 setup back to
# ttyS2 gives you console debugging again instead of silently leaving it off.

set_env_kv() {  # set_env_kv key value  -- idempotent edit of orangepiEnv.txt
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$ENVFILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENVFILE"
    else
        echo "${key}=${val}" >> "$ENVFILE"
    fi
}

if [ ! -f "$ENVFILE" ]; then
    warn "$ENVFILE not found — is this really an Orange Pi? Skipping console reconfig."
else
    cp -n "$ENVFILE" "${ENVFILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    if [ "$MLR_DEVICE" = "/dev/ttyS0" ] && [ "$MLR_KEEP_CONSOLE" != "1" ]; then
        # Give UART0 to the flight controller.
        # boot.cmd sets defaults THEN imports orangepiEnv.txt, so these win.
        set_env_kv console  display   # drops console=ttyS0,115200 from cmdline
        set_env_kv earlycon off       # drops earlyprintk=sunxi-uart,0x02500000
        ok "Freed UART0: console=display, earlycon=off in $ENVFILE"
        grep -q 'console=ttyS0' /proc/cmdline && REBOOT_REQUIRED=1

        systemctl disable --now serial-getty@ttyS0.service >/dev/null 2>&1 || true
        systemctl mask serial-getty@ttyS0.service >/dev/null 2>&1 || true
        ok "Disabled and masked serial-getty@ttyS0.service"

        warn "U-Boot still prints to UART0 at 115200 on every boot; console= only"
        warn "controls the kernel. Expect a burst of boot text at the flight controller."
    else
        # Not using UART0 -> the console is free to stay on, which is worth
        # having: it is the only way to debug a board that will not boot.
        set_env_kv console  both
        set_env_kv earlycon on
        ok "Serial console left enabled on UART0 (pins 8/10): console=both, earlycon=on"

        systemctl unmask serial-getty@ttyS0.service >/dev/null 2>&1 || true
        systemctl enable serial-getty@ttyS0.service  >/dev/null 2>&1 || true
        ok "Re-enabled serial-getty@ttyS0.service"
    fi
fi

# --- 3ab. let the dialout group open the port -------------------------------
# A console device is given the 'tty' group and mode 0600, so dialout membership
# alone does not grant access and non-root tools fail with EACCES. The service
# runs as root and is unaffected, but test_serial.sh would break. Fix with udev.
DEV_KERNEL="${MLR_DEVICE#/dev/}"
cat > /etc/udev/rules.d/99-mavlink-router-uart.rules <<UDEV
# Installed by installmavlinkrouterorangepizero3w
KERNEL=="$DEV_KERNEL", GROUP="dialout", MODE="0660"
UDEV
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=tty >/dev/null 2>&1 || true
    ok "udev rule installed: $MLR_DEVICE -> group dialout, mode 0660"
else
    warn "udevadm not found; $MLR_DEVICE may stay root-only until reboot"
fi

# --- 3b. optional extra UART via device-tree overlay ------------------------
if [ -n "$MLR_UART_OVERLAY" ]; then
    if [ -f "$ENVFILE" ]; then
        PREFIX="$(grep -E '^overlay_prefix=' "$ENVFILE" | cut -d= -f2)"
        PREFIX="${PREFIX:-sun60i-a733}"
        DTBO="/boot/dtb/allwinner/overlay/${PREFIX}-${MLR_UART_OVERLAY}.dtbo"
        if [ -f "$DTBO" ]; then
            if grep -qE '^overlays=' "$ENVFILE"; then
                grep -qE "^overlays=.*\b${MLR_UART_OVERLAY}\b" "$ENVFILE" \
                    || sed -i "s|^overlays=\(.*\)|overlays=\1 ${MLR_UART_OVERLAY}|" "$ENVFILE"
            else
                echo "overlays=${MLR_UART_OVERLAY}" >> "$ENVFILE"
            fi
            ok "Enabled device-tree overlay ${PREFIX}-${MLR_UART_OVERLAY}.dtbo"
            # The node only appears after the overlay is applied at boot.
            if [ ! -e "$MLR_DEVICE" ]; then
                REBOOT_REQUIRED=1
                warn "$MLR_DEVICE does not exist yet — it appears after reboot"
            fi
        else
            warn "Overlay not found: $DTBO — skipping"
        fi
    fi
fi

# --- 3c. warn loudly about the Bluetooth trap -------------------------------
if [ "$MLR_DEVICE" = "/dev/ttyS1" ]; then
    warn "/dev/ttyS1 is the onboard Bluetooth HCI port (hciattach_opi ... aic)."
    warn "Writes to it block forever and it is not wired to the 40-pin header."
    warn "This is almost certainly NOT what you want."
fi

# --- 3d. dialout group ------------------------------------------------------
# Same pipefail/SIGPIPE caveat as above: plain grep, not grep -q.
if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -x dialout >/dev/null; then
    ok "User '$TARGET_USER' already in dialout"
else
    usermod -aG dialout "$TARGET_USER" && ok "Added '$TARGET_USER' to dialout (effective next login)"
fi

# --- 3e. Wi-Fi power save ----------------------------------------------------
# The adapter sleeps between beacons to save power. Harmless when browsing, but
# on a telemetry link it adds latency spikes and brief inbound stalls, which
# present as the ground station freezing or dropping mid-flight. Classic
# "works on the bench, flaky in the air" cause.
if [ "$MLR_WIFI_POWERSAVE_OFF" = "1" ]; then
    NMCONF_DIR="/etc/NetworkManager/conf.d"
    if [ -d /etc/NetworkManager ]; then
        mkdir -p "$NMCONF_DIR"
        cat > "$NMCONF_DIR/99-mavlink-wifi-powersave-off.conf" <<'NMCONF'
# Installed by installmavlinkrouterorangepizero3w
# wifi.powersave = 2 means "disable". Applies to every Wi-Fi connection, so it
# still holds after joining a different network in the field.
[connection]
wifi.powersave = 2
NMCONF
        systemctl reload NetworkManager >/dev/null 2>&1 || \
            systemctl restart NetworkManager >/dev/null 2>&1 || true
        ok "Wi-Fi power save disabled persistently (NetworkManager drop-in)"
    else
        warn "NetworkManager not found; Wi-Fi power save left as-is"
    fi

    # Apply immediately too, rather than waiting for a reconnect.
    if command -v iw >/dev/null 2>&1; then
        for wdev in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
            iw dev "$wdev" set power_save off >/dev/null 2>&1 || true
        done
    fi
else
    info "Leaving Wi-Fi power save alone (MLR_WIFI_POWERSAVE_OFF=0)"
fi

# ------------------------------------------------------------- 4. main.conf
step "Writing $CONF_DIR/main.conf"

read -r PIN_TX PIN_RX PIN_GND PIN_LABEL <<<"$(pins_for_device "$MLR_DEVICE")"

mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/main.conf" ]; then
    cp "$CONF_DIR/main.conf" "$CONF_DIR/main.conf.bak.$(date +%Y%m%d%H%M%S)"
    info "Backed up existing main.conf"
fi

cat > "$CONF_DIR/main.conf" <<CONF
# /etc/mavlink-router/main.conf
# Generated by installmavlinkrouterorangepizero3w on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# Orange Pi Zero 3W (Allwinner A733) pin map for the flight controller:
#   header pin $PIN_TX = $PIN_LABEL TX  -> flight controller RX
#   header pin $PIN_RX = $PIN_LABEL RX  -> flight controller TX
#   header pin $PIN_GND = GND            -> flight controller GND
# Do NOT cross-connect TX->TX. Do NOT power the FC from the Pi's 5V.

[General]
TcpServerPort=$MLR_TCP_PORT
ReportStats=false
MavlinkDialect=auto

[UartEndpoint fc]
Device = $MLR_DEVICE
Baud = $MLR_BAUD
# If your FC's baud is uncertain, mavlink-router can probe a list instead:
# Baud = 57600,115200,921600

# --- Optional: stream to a ground station over the network -------------------
# [UdpEndpoint gcs]
# Mode = Normal
# Address = 192.168.1.50
# Port = 14550
CONF

chmod 644 "$CONF_DIR/main.conf"
ok "Config written (device=$MLR_DEVICE baud=$MLR_BAUD tcp=$MLR_TCP_PORT)"

# --------------------------------------------------------- 5. systemd service
step "Installing systemd service"

cat > "$UNIT" <<UNITEOF
[Unit]
Description=MAVLink Router
Documentation=https://github.com/PeterJBurke/installmavlinkrouterorangepizero3w
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$BIN_DIR/mavlink-routerd -c $CONF_DIR/main.conf
Restart=always
RestartSec=5
# The FC may not be powered when the Pi boots; keep retrying rather than give up.
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable mavlink-router.service >/dev/null 2>&1
ok "Service installed and enabled at boot"

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    warn "NOT starting the service yet — the kernel still owns $MLR_DEVICE until you reboot."
else
    systemctl restart mavlink-router.service || warn "Service failed to start; check: journalctl -u mavlink-router -n 50"
    sleep 2
    if systemctl is-active --quiet mavlink-router.service; then
        ok "mavlink-router.service is running"
    else
        warn "Service is not active. Check: journalctl -u mavlink-router -n 50"
    fi
fi

# ------------------------------------------------------------------- summary
ELAPSED=$(( $(date -u +%s) - START_TIME ))
step "Done in ${ELAPSED}s"

cat <<SUMMARY

  ${c_bld}Wiring (Orange Pi Zero 3W 40-pin header) — $PIN_LABEL${c_off}
    pin $PIN_TX  ${PIN_LABEL}-TX  ->  flight controller RX
    pin $PIN_RX  ${PIN_LABEL}-RX  ->  flight controller TX
    pin $PIN_GND  GND       ->  flight controller GND

  ${c_bld}Configuration${c_off}
    serial device : $MLR_DEVICE @ $MLR_BAUD baud
    TCP server    : port $MLR_TCP_PORT  (connect Mission Planner / QGC here)
    config file   : $CONF_DIR/main.conf
    service       : systemctl status mavlink-router
    logs          : journalctl -u mavlink-router -f

SUMMARY

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    if [ -e "$MLR_DEVICE" ]; then
        echo "  ${c_yel}${c_bld}A REBOOT IS REQUIRED${c_off} to release the serial console from $MLR_DEVICE."
    else
        echo "  ${c_yel}${c_bld}A REBOOT IS REQUIRED${c_off} — $MLR_DEVICE appears only once the"
        echo "  ${c_yel}device-tree overlay '${MLR_UART_OVERLAY}' is applied at boot.${c_off}"
    fi
    echo "  ${c_yel}Run: sudo reboot${c_off}"
    echo
    echo "  After rebooting, verify with:  ./test_serial.sh"
else
    echo "  Verify with:  ./test_serial.sh"
fi
echo
