# Handoff — state of play

Last updated: 2026-09-17. Written so a fresh session (or a future you) can pick up
without re-deriving anything.

---

## Session end — 2026-09-26

Stopped here deliberately; the barometer work is finished and verified. Nothing
is broken, nothing is half-done, and nothing is left only on this SD card except
the three tools noted below.

### Suggested next steps, in no particular order

**Order a downward rangefinder.** VL53L1X or TFmini-S, roughly $20. Set
`RNGFND1_TYPE`, then `EK3_SRC1_POSZ = 2` and `WPNAV_RFND_USE = 1`. This is now
the only real hardware gap: relative climb is trustworthy, but absolute altitude
is not, so fences, terrain following, AUTO at fixed altitudes and precision
landing all remain unreliable. It is a capability upgrade, not a bug fix.

**Commit the flight tools to this repo.** `~/dronetest/takeoff.py`,
`barotest.py` and `logdl.py` exist only on this SD card. They are reusable and a
reflash loses them. (Copies are on `llmuavdev:~/logfiles/tools/`, but they are
not version-controlled.)

**Pin down the `LOG_REQUEST_END` CRC_EXTRA.** The value 203 currently in
`logdl.py` is wrong. A log download leaves ArduPilot refusing to arm with
"Disarm for log download", and the release message is discarded. It was cleared
by brute-forcing all 256 candidates, which works but is ugly and will recur on
the next download. Determining the right value is a ten-minute job.

**Fly a pattern rather than a hover.** Takeoff, yaw and land are all proven.
`MAV_CMD_NAV_WAYPOINT` or `SET_POSITION_TARGET_LOCAL_NED` would fly a square in
the cage. GPS is at 29 satellites, so horizontal position is in good shape.

### Housekeeping

Revoke the passwordless sudo when the work is done:

```bash
sudo rm /etc/sudoers.d/010-mavlink-claude
```

### Still parked (unchanged, not urgent)

Tailscale on this Pi runs `--tun=userspace-networking` with no TUN device, so
ordinary programs cannot reach tailnet addresses. `tailscale ssh` works and is
how files reach `llmuavdev`. See the section below.

## Status: barometer fix COMPLETE and fully verified (2026-09-26)

Four consecutive successful GUIDED takeoffs, including the 1 m case that
previously failed outright. **No open test items.**

| date | commanded | result | |
|---|---|---|---|
| 25 Sept | 1.0 m | auto-disarmed mid-hover at 0.85 m | FAILED |
| 25 Sept | 1.5 m | ran to 5.44 m, into the cage roof | FAILED |
| 26 Sept | 2.0 m | +0.35 m overshoot, ±0.1 m hold, 25 s | PASS |
| 26 Sept | 2.0 m | +0.13 m overshoot, ±0.1 m hold, 25 s | PASS |
| 26 Sept | 2.0 m | +0.21 m overshoot, ±0.1 m hold, 25 s | PASS |
| 26 Sept | **1.0 m** | **+0.08 m overshoot, ±0.01 m hold, 25 s** | **PASS** |

The 1 m flight is the tightest of them all, which is the strongest possible
result: low hover is the hardest case for a barometer — deepest in ground
effect, largest error relative to target — and it is the exact command that
failed on 25 Sept.

### Two operational notes for future sessions

**After a battery swap or FC reboot, telemetry stops at heartbeats only.** The
other streams must be requested or the tooling sees nothing useful:

```bash
# SET_MESSAGE_INTERVAL (511) per message, or legacy REQUEST_DATA_STREAM (66)
```

Symptom: `takeoff.py --status` shows the FC as present but reports no battery,
GPS or altitude.

**The EKF takes ~1–2 minutes to converge after a reboot and flaps while doing
it.** Observed sequence: `horiz_abs=ok`, then `NO`, then `ok`, then `NO`, with
`const_pos` toggling, before settling. Wait for a sample with
`horiz_abs=ok, horiz_rel=ok, const_pos=no` before arming, rather than trusting
the first good reading.

**The ground reference varies wildly between sessions** — −0.94 m this session
against +4.23 m at the end of the last. That ~5 m swing is why the runaway guard
measures climb relative to the resting altitude rather than against a fixed
ceiling. Do not reintroduce an absolute comparison.

### Remaining hardware gap (not blocking)

The absolute altitude reference is still unreliable. Relative climb is
trustworthy, so GUIDED takeoff and altitude hold are cleared for use; fences,
terrain following and AUTO at fixed altitudes are not. A downward rangefinder
(VL53L1X or TFmini-S, with `EK3_SRC1_POSZ = 2`) is the fix, and is now the
natural next hardware step rather than a workaround for a fault.

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

## Barometer, 26 Sept: foam fixed the thermal term, not the airflow term

Peter added foam **on the sensor** and moved the GPS 1 inch higher. A short
STABILIZE + LOITER flight (log 10, 86 s, max 0.93 m) was pulled over MAVLink and
compared against 25 Sept.

**Thermal drift — improved 61%:**

| | slope | r² |
|---|---|---|
| 25 Sept, no foam | +0.109 m/°C | 0.724 |
| 26 Sept, foam | **+0.043 m/°C** | 0.779 |

Reported ground level moved only 0.20 m across a 4.2 °C swing, against 1.09 m
before. The foam is genuinely insulating.

**Aerodynamic transient — NOT improved.** Spin-up #1 at 10 Hz:

```
     t     ThO    BAlt     Press     Temp
 367.1   0.00   -1.83   100686.5   41.60    steady
 367.8   0.24   -4.27   100713.9   41.63    <- +27.4 Pa in 0.7 s = 2.28 m
 368.6   0.33   -0.95   100676.5   41.65    <- then -37 Pa the other way
```

27.4 Pa sits squarely inside the pre-foam range of 10.8–32.9 Pa. Temperature
*rises* 0.11 °C through the spike, confirming it is aerodynamic, not thermal.

Note this flight only reached 0.93 m and 37% throttle. The spike scales with
throttle, so **treat 27 Pa as a floor, not a worst case** for a real takeoff.

**Since the foam is reportedly already over the sensor**, the remaining
candidates are: wrong foam type (must be open-cell, not closed-cell — closed-cell
seals the port and makes transients worse), foam not sealed at its edges so air
tracks around it, or the whole FC cavity pressurising under prop wash, which foam
over one 2 mm sensor cannot fix.

**Target for "fixed":** spin-up spike under ~5 Pa (0.4 m). That is the number
that decides whether GUIDED takeoff is safe. Until then GUIDED/AUTO takeoff from
the ground remains unsafe; STABILIZE and LOITER are fine and today adds more
evidence for that.

**GPS move was a clear win:** 23 satellites, up from 8–17.

## Pulling logs over MAVLink — and the arming trap it causes

`~/dronetest/logdl.py` downloads FC logs over the telemetry link:

```bash
python3 ~/dronetest/logdl.py --list
python3 ~/dronetest/logdl.py --get 10 --out ~/inbox/26Sept2026
```

Measured throughput: **2.06 KB/s**. A 1.6 MB log took 13 minutes; a 6 MB log
would take ~50. Pulling the SD card is seconds — use MAVLink only when the
aircraft is in the cage and you do not want to disassemble it.

### Three mistakes worth not repeating

1. **`LOG_ENTRY` arrives as 13 bytes, not 14.** MAVLink v2 truncates trailing
   zero bytes, so a `len(pay) >= 14` check rejects every valid frame and the
   tool reports "no logs". Pad payloads before unpacking.
2. **A log download blocks arming.** ArduPilot refuses with
   `"Disarm for log download"` until it receives `LOG_REQUEST_END`. The
   `CRC_EXTRA` of 203 used for that message is **wrong** — the FC silently
   discarded it and the aircraft could not be armed. Cleared by sending
   `LOG_REQUEST_END` with all 256 candidate `CRC_EXTRA` values; bad ones are
   dropped harmlessly. **Determine the correct value before downloading again.**
3. Do not pipe a long download through `tail` — it buffers, so no progress is
   visible until it exits. And do not set the timeout barely above the expected
   duration; the tool writes the file only at the end, so a timeout loses
   everything.

Today's log is at `~/inbox/26Sept2026/log_010.bin` (1,596,462 bytes, verified
`a3 95` header, zero missing bytes). **Not yet copied to llmuavdev.**

## RESOLVED 26 Sept — barometer fixed, GUIDED takeoff verified

**The barometer fault below is fixed.** Open-cell foam placed directly **on the
sensor** (it had previously been under the SD card) plus a GPS moved 1 inch
higher. Both error terms improved and the failure mechanism is gone.

| | before | after |
|---|---|---|
| airflow transient @75% throttle | 27.4 Pa (2.28 m) | **7.6 Pa (0.63 m)** |
| thermal drift | +0.109 m/°C | **+0.043 m/°C** |
| error direction | reads **LOW** → commands climb | reads **HIGH** → levels off early |
| character | coherent 400 ms step | oscillation (the EKF filters it) |
| GPS | 8–17 satellites | **28** |

The direction change matters more than the magnitude: reading low is what drove
full throttle into the cage roof. Sensor noise floor with motors off is 0.8 Pa.

**Three consecutive GUIDED takeoffs to 2.0 m:**

| | overshoot | settled | held |
|---|---|---|---|
| 1 | +0.35 m | 1.95–2.07 m | 25 s |
| 2 | +0.13 m | 1.93–2.12 m | 25 s |
| 3 | +0.21 m | 1.93–2.03 m | 25 s |

Against 25 Sept, where 1.52 m commanded reached 5.44 m and 1.0 m reached 4.31 m,
both with throttle saturated. **GUIDED takeoff is now cleared for use.**

### Guard change that mattered

The runaway guard originally compared *absolute* altitude against a fixed
ceiling. The absolute reference drifts metres between sessions — it read 3.94 m
while sitting on the ground — so the guard would have fired instantly on every
takeoff. It now measures **climb relative to the resting altitude**, captured at
arm time. Default margin is target + 0.75 m (`MLR_CEILING` to override).

### Still outstanding

* **The absolute altitude reference is unreliable.** −1.6 m in the morning,
  +3.9 to +4.2 m in the afternoon, creeping 3.91 → 4.02 → 4.23 m across three
  flights. Relative climb is trustworthy, so GUIDED takeoff and altitude hold
  are fine; fences, terrain following and AUTO at fixed altitudes are not.
  A downward rangefinder is the real fix for a 10 ft cage.
* **The 1 m takeoff has not been retested** — that case previously auto-disarmed
  mid-hover at 0.85 m. Skipped because the pack reached 3.68 V/cell. **First
  thing to try next session.**

### New tool

`~/dronetest/barotest.py` measures the pressure transient at throttle-up and
prints a pass/borderline/fail verdict. It reads throttle from **RC channel 3**,
because this FC reports 0 for `VFR_HUD.throttle` and `SERVO_OUTPUT_RAW` even
while armed and flying — an earlier version trusted those and silently measured
nothing, producing two meaningless "passes".

Results and today's log are on `llmuavdev:~/logfiles/26Sept2026/`
(`RESULTS.md`, `log_010.bin`, `barotests.jsonl`), tools in `~/logfiles/tools/`.

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
