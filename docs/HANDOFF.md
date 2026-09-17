# Handoff — state of play

Last updated: 2026-09-17. Written so a fresh session (or a future you) can pick up
without re-deriving anything.

---

## One-line status

Everything on the Orange Pi side is **built, installed, and verified end to end**.
The **only** untested link is the flight controller itself — no FC has ever been
attached.

---

## How to resume the Claude Code session

The conversation transcript lives on the SD card and survives reboots and power
cycles:

```bash
cd ~/mlinstall/installmavlinkrouterorangepizero3w
claude --continue      # resumes the most recent conversation for this directory
# or: claude --resume   to pick from a list
```

If that fails, this file plus `BUILD_JOURNAL.md` contain everything needed.

---

## The machine

| | |
|---|---|
| Board | Orange Pi Zero 3W, **Allwinner A733 (`sun60iw2`)** — *not* the H618 most docs describe |
| OS | Ubuntu 26.04 "Resolute" aarch64, kernel 6.6.98-sun60iw2 |
| User | `orangepi`, in `dialout` |
| LAN IP | 192.168.1.146 (also on Tailscale as `orangepi`, 100.92.72.14) |
| Repo | `~/mlinstall/installmavlinkrouterorangepizero3w` → github.com/PeterJBurke/installmavlinkrouterorangepizero3w (public) |
| Upstream source | `~/mlinstall/mavlink-router` (build tree, not committed) |
| Vendor PDFs | `docs/vendor/` — **not committed** (copyright, 17 MB) |

Passwordless sudo is granted by `/etc/sudoers.d/010-mavlink-claude`, scoped to
`apt-get, systemctl, udevadm, usermod, reboot` plus this repo's `install.sh` and
`uninstall.sh`. **Remove it when the project is done:**

```bash
sudo rm /etc/sudoers.d/010-mavlink-claude
```

---

## What is verified (with evidence, not assumption)

| Claim | How it was proven |
|---|---|
| Binary is correct | built natively from upstream `2362c62` in 23 s; `--version` runs |
| Prebuilt install path works | fresh-user simulation downloaded it from GitHub; SHA256 matches manifest |
| Service runs at boot | `systemctl is-enabled` = enabled, survived 3 reboots |
| Port permissions | `/dev/ttyS2` is `root:dialout 0660` via udev rule |
| UART2 is really on pins 11/13 | manual §3.16.5, schematic p.18, and `gpio readall` all agree |
| Overlay works | pins 11/13 moved `ALT14` → `ALT2` exactly when `overlays=uart2` was added |
| Transmit works | 16 bytes @300 baud took 0.62 s vs 0.53 s theoretical |
| **Receive + physical pins work** | **loopback: jumper pin 11↔13, token sent and received** |
| Installer is idempotent | run 5+ times, no ill effects |

`./test_serial.sh` reports **all checks passed**.

---

## THE NEXT STEP — flight controller

Power **both** devices off. Then three wires:

| Pi header pin | Which one physically | → | Flight controller |
|---:|---|---|---|
| **11** | 6th down the **odd** (left) row | → | **RX** |
| **13** | 7th down the odd row | ← | **TX** |
| **14** | directly opposite pin 13 | — | **GND** |

**Do not connect 5 V.** Separate supplies, shared ground only. GPIO is 3.3 V.

> Header numbering: the 2×20 rows **interleave**, so descending one column steps
> by 2. Left column: `pin = 2 × row − 1`. Manual page 13 prints no pin numbers.

To locate a pin physically without counting (there are no pads on the underside
of this board):

```bash
gpio mode 6 out && gpio write 6 1   # wPi 6 == physical pin 12 → 3.3V
# probe the EVEN row: the only 3.3V pin is pin 12. Pin 11 is directly opposite.
gpio mode 6 in                      # release afterwards
```

Then:

```bash
cd ~/mlinstall/installmavlinkrouterorangepizero3w
./test_serial.sh --listen 15
```

### Interpreting the result

Because the loopback already passed, the Pi is exonerated — any failure is the
harness, the FC, or the baud rate.

| Result | Cause | Action |
|---|---|---|
| **0 bytes** | TX/RX not crossed, FC unpowered, or GND not shared | swap pins 11↔13 at the FC end (harmless to try) |
| **bytes, no MAVLink frames** | wrong baud | check FC `SERIALn_BAUD`; or set `Baud = 57600,115200,921600` in `/etc/mavlink-router/main.conf` to probe |
| **HEARTBEAT present** | working | point a GCS at `tcp:192.168.1.146:5678` |

Flight controller side (ArduPilot): the telemetry port needs
`SERIALn_PROTOCOL = 2` (MAVLink2) and `SERIALn_BAUD = 57` (57600).

---

## Key facts that are easy to get wrong

1. **`/dev/ttyS1` is Bluetooth**, not a spare UART. Looks free (`root:dialout`,
   writable) but `hciattach_opi` owns it, line discipline is 15 (`N_HCI`), and
   writes **block forever**. It is wired to the BT chip, not the header.
2. **`/dev/ttyS0` is the debug console**, shared with the 3-pin debug header via
   1 kΩ resistors, and **U-Boot prints to it at 115200 every boot** — `console=`
   only controls the kernel, so a FC there gets boot garbage. This is why the
   default moved to UART2.
3. **`/boot/firmware/config.txt` does not exist.** Orange Pi uses
   `/boot/orangepiEnv.txt`, imported by `boot.cmd` *after* its defaults.
4. **Never `grep -q` on the right of a pipe** in a script with `pipefail` — grep
   exits early, the writer gets SIGPIPE (141), and the guard silently inverts.
   This bug skipped a whole block once. See journal gotcha #13.
5. **The prebuilt binary needs glibc ≥ 2.42.** `install.sh` probes and falls back
   to compiling (~25 s).
6. **Check downloaded PDFs with `file`.** A subagent once saved a Google Drive
   "Quota exceeded" HTML page named `.pdf`.
7. **Long pasted commands get real newlines inserted** in Peter's terminal. Keep
   pasted commands short and on one line; never send a heredoc.
8. **The run log has caught two bugs that the exit code did not.** Read it.

---

## Useful commands

```bash
./test_serial.sh                 # all checks
./test_serial.sh --loopback      # jumper pin 11↔13, prove the Pi's UART
./test_serial.sh --listen 15     # sniff the FC, decode MAVLink frames

sudo ./install.sh                # idempotent; re-run any time
sudo ./uninstall.sh              # removes everything, restores serial console

systemctl status mavlink-router
journalctl -u mavlink-router -f
ss -ltn | grep 5678
```

Change the UART: `sudo MLR_DEVICE=/dev/ttyS0 ./install.sh` (UART0, pins 8/10 —
same pins as a Raspberry Pi harness, but accepts U-Boot noise and loses the
console). Or `/dev/ttyS6` (24/23), `/dev/ttyS7` (16/18).
