# Handoff — state of play

Last updated: 2026-09-17. Written so a fresh session (or a future you) can pick up
without re-deriving anything.

---

## One-line status (updated 2026-09-25)

**WORKING END TO END.** A flight controller is attached and HEARTBEAT flows
FC -> UART2 -> mavlink-router -> TCP 5678, CRC-verified at both ends.

Also on this board: the Wi-Fi hotspot failsafe from
[OrangePiHotspotIfNoWifi](https://github.com/PeterJBurke/OrangePiHotspotIfNoWifi)
is installed and enabled at boot, and AP mode is proven on this radio.

Late fix (gotcha #20): Wi-Fi power save had been silently re-enabled by the
stock `default-wifi-powersave-on.conf`, which sorts after a `99-` prefix in
NetworkManager's conf.d. Now `zz-`-prefixed and verified across a reconnect.

**2026-09-25: the aircraft has flown under command from this board, and a
hardware fault was found. Read "Flight testing" and "KNOWN AIRCRAFT FAULT"
below before commanding any takeoff.**

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
| **Receive + physical pins work** | loopback: jumper pin 11↔13, token sent and received |
| **FC link works** | **15 CRC-valid HEARTBEATs in 15 s, sys 1, 0 rejected** |
| **TCP output works** | **client on :5678 saw 13 HEARTBEATs in 12 s** |
| Installer is idempotent | run 5+ times, no ill effects |

`./test_serial.sh` reports **all checks passed**.

---

## The FC is connected and working

Wiring in use: Pi pin **11 -> FC RX**, pin **13 -> FC TX**, pin **14 -> FC GND**.
FC telemetry port at **57600** (it was found set to 468000, which produced pure
noise — see journal gotcha #18).

Connect a ground station to **`tcp:192.168.1.146:5678`**.

Expect only ~23 bytes/sec when idle: ArduPilot sends just HEARTBEAT and TIMESYNC
until a GCS requests data streams. That is normal, not a fault.

### Original wiring instructions (kept for reference)

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

## Flight testing, 2026-09-25

Commanded flight works end to end from this board. `~/dronetest/takeoff.py`
(local to this SD card, **not yet committed to any repo**) drives the aircraft
over mavlink-router on TCP 5678:

```bash
python3 ~/dronetest/takeoff.py --status      # read-only
python3 ~/dronetest/takeoff.py --alt 2.0     # GUIDED takeoff
python3 ~/dronetest/takeoff.py --yaw -30     # yaw left 30 deg (CONDITION_YAW)
python3 ~/dronetest/takeoff.py --land
```

Verified in flight: GUIDED takeoff to 2.0 m held steadily for 20 s; a 30° left
yaw executed exactly (heading 61° → 31°) with altitude held to ±0.02 m; LAND
commanded and the aircraft auto-disarmed on touchdown.

Two bugs found and fixed in that script, both worth not re-introducing:

* **The MAVLink v2 header is six bytes** — `len, incompat, compat, seq, sysid,
  compid`. It was written with five, so every field after it shifted by one and
  the flight controller silently discarded the frame. The symptom was no
  COMMAND_ACK; the script aborted before arming, which is the correct behaviour.
* `SET_MODE` packs its fields by descending size (`custom_mode` uint32 first).
  Use `DO_SET_MODE` via `COMMAND_LONG` instead — it returns an ACK, so the mode
  change can be verified rather than assumed.

The script refuses altitudes outside 0.5–5.0 m, refuses to arm if already armed,
aborts if any step is unacknowledged, auto-disarms if a takeoff is refused after
arming, and (added after the incident below) **lands automatically if the
reported altitude exceeds the target by more than 1.5 m**. That guard has fired
in anger and worked.

## KNOWN AIRCRAFT FAULT — barometer

**Do not command a GUIDED or AUTO takeoff from the ground until this is fixed.**

The SPL06-001 barometer on the MatekF405-TE is unshielded and produces
multi-metre errors. Two mechanisms, both measured from the flight logs:

1. **Aerodynamic transient at throttle-up** — pressure moves up to 33 Pa in
   400 ms (≈2.7 m of apparent altitude), repeatable across all six throttle-up
   events in one log, with temperature changing less than 0.13 °C. This is what
   causes the runaway climb.
2. **Thermal drift of the zero point** — the board self-heats to ~48 °C, prop
   wash cools it, and the reported ground altitude drifts **+0.109 m per °C**
   (r² = 0.724, 824 samples). Over one session that is more than a metre. It is
   why the aircraft reported 4.02–4.29 m while motionless on the floor.

It is the **only** altitude source: `RNGFND1_TYPE = 0`, `BARO2/3_DEVID = 0`, and
`EK3_SRC1/2/3_POSZ` all `= 1`. Nothing can out-vote it.

Consequence: two commanded takeoffs climbed into the roof of a 20 ft cage.
STABILIZE is unaffected (no altitude feedback), and **LOITER entered while
already airborne is demonstrably safe** — logged at a steady 34% throttle with
the barometer swinging 4 m beneath it, because it captures its reference from a
settled hover. The failure is specific to capturing an altitude reference on the
ground, mid-glitch, with full throttle authority.

Fix: open-cell foam over the sensor (addresses both mechanisms), and ideally a
downward rangefinder for work at 1–2 m indoors.

Full analysis, with the log evidence: `~/inbox/CRASH_ANALYSIS_2026-09-25.md`.
The DataFlash parser written for it is `~/loganalysis/dflog.py` (~90 lines, no
dependencies — `pymavlink` is not installable on this machine). Neither is
committed to a repo yet.

## Open item (back burner) — Tailscale is userspace-only on this Pi

**Not urgent. Nothing is broken that blocks the drone work.** Parked 2026-09-25.

Tailscale on this board runs with no TUN device:

```
/etc/default/tailscaled:  FLAGS="--tun=userspace-networking"
tailscale status:         TUN : False
interfaces:               lo, wlan0        <- no tailscale0
/dev/net/tun:             missing; tun kernel module not loaded
```

**Consequence:** ordinary programs cannot reach tailnet addresses from this Pi.
`ssh`, `scp`, `curl` to a `100.x` address get routed to the Wi-Fi default gateway
and time out. Verified against three peers, all of which fail identically.
`tailscale status` and `tailscale ping` still work, because those are tailscaled
talking to itself — which makes the fault look like a remote problem when it is
local.

**Workaround that does work:** `tailscale ssh user@host`, and `tailscale nc`.
These proxy through userspace and sidestep the missing interface. Files were
moved to `llmuavdev` this way:

```bash
tar czf - logfiles | tailscale ssh root@llmuavdev 'cd ~ && tar xzf -'
```

**Possible fix, untested:**

```bash
sudo modprobe tun && ls -l /dev/net/tun      # does the kernel have it?
# if yes:
sudo sed -i 's/^FLAGS=.*/FLAGS=""/' /etc/default/tailscaled
sudo systemctl restart tailscaled
```

If `modprobe tun` fails, this Orange Pi kernel lacks the driver and userspace
mode is the only option — in which case `tailscale ssh` is the permanent answer,
not a workaround.

**A diagnostic trap worth remembering:** llmuavdev's ufw *is* restrictive
(`default deny (incoming)`, only `tailscale0` allowed), and that was initially
blamed for the failure. It was not the cause — the packets never left this Pi.
A plausible cause on the far end masked the real one on the near end. Check
`ip route get <tailnet-ip>` first: if it resolves via the LAN gateway rather than
`tailscale0`, the problem is local.

## Log analysis artifacts moved off this board

The barometer analysis and all flight logs were copied to
`llmuavdev:~/logfiles` on 2026-09-25 — 23 files, 42 MB, **checksum-verified**,
owned root:root. That machine is where further analysis will happen.

Contents: `CRASH_ANALYSIS_2026-09-25.md`, `README.md`, `analyzelogfiles.md`,
`25Sept2026LogFiles/` (9 incident logs), `16Sept2026/` (6 comparison logs), and
`tools/` with the dependency-free DataFlash parser.

The originals are **still on this Pi** in `~/inbox` and `~/loganalysis` — copied,
not moved, pending confirmation. They are the only other copy, and this board is
a reflash candidate.

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
