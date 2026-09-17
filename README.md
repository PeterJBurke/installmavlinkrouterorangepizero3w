# MAVLink Router for Orange Pi Zero 3W

Automated install of [MAVLink Router](https://github.com/mavlink-router/mavlink-router)
on an **Orange Pi Zero 3W**, taking a *fresh, bare Ubuntu image* to a running
`mavlink-routerd` that talks to a flight controller over UART and serves the
MAVLink stream over TCP to a ground station.

This is the Orange Pi counterpart to
[installmavlinkrouter2024](https://github.com/PeterJBurke/installmavlinkrouter2024)
(Raspberry Pi Zero 2 W). **It is not a drop-in port** — the serial hardware on
this board is arranged very differently, and a naive port of the Pi script
silently does nothing useful. See [Why this is not just the Pi script](#why-this-is-not-just-the-pi-script).

---

## Target hardware

| | |
|---|---|
| Board | Orange Pi Zero 3W |
| SoC | Allwinner **A733** (`sun60iw2`), 6× Cortex-A55 + 2× Cortex-A76 |
| RAM | 6 GB (tested); 1/2/4 GB should work |
| OS | Ubuntu 26.04 "Resolute" aarch64 (Orange Pi 1.0.2 image), kernel 6.6.98 |
| Flight controller | Matek or similar, telemetry port at 57600 baud (ArduPilot/PX4) |
| Wiring | 3 jumpers, FC telemetry → 40-pin header |

> **Check your board first.** Run `cat /proc/device-tree/model`.
> This repo is built and tested for **`sun60iw2`**. Many boards sold as
> "Zero 3W" are Allwinner **H618** (`sun50i-h616`) instead. The installer warns
> and continues if the model differs, but the UART pin mapping may not match.

---

## Wiring

```
   Orange Pi Zero 3W 40-pin header          Flight controller
   ┌──────────────────────────────┐          (TELEM port)
   │  1  ● ●  2                   │
   │  3  ● ●  4                   │
   │  5  ● ●  6                   │
   │  7  ● ●  8                   │
   │  9  ● ● 10                   │
   │ 11  ● ● 12   UART2-TX ───────┼────────► RX
   │ 13  ● ● 14   UART2-RX ◄──────┼───────── TX
   │              GND (pin 14) ───┼────────► GND
   └──────────────────────────────┘
```

| Header pin | Signal | Connect to |
|---:|---|---|
| **11** | `UART2-TX` (PB0) | flight controller **RX** |
| **13** | `UART2-RX` (PB1) | flight controller **TX** |
| **14** | `GND` | flight controller **GND** |

(Pin 6, 9, 20, 25, 30, 34 or 39 work equally well for GND.)

> ⚠️ **TX goes to RX and RX goes to TX.** Straight-through TX→TX is the single
> most common reason nothing appears.
>
> ⚠️ **Do not power the flight controller from the Pi's 5V pin**, and do not
> connect the FC's 5V to the Pi. Power each separately and share only **GND**.
> The Orange Pi's GPIO is **3.3 V**; most FC telemetry ports are 3.3 V-safe, but
> confirm yours before connecting.

### Which UART, and why not pins 8/10

Per the vendor manual (§3.16.5) this board exposes three general-purpose UARTs.
Each needs its device-tree overlay enabled; `install.sh` does that for you:

| UART | TX pin | RX pin | device | overlay |
|---|---:|---:|---|---|
| **UART2** (default) | **11** | **13** | `/dev/ttyS2` | `uart2` |
| UART6 | 24 | 23 | `/dev/ttyS6` | `uart6` |
| UART7 | 16 | 18 | `/dev/ttyS7` | `uart7` |

**Pins 8/10 look like the obvious choice and are best avoided.** They are
labelled `TXD.0`/`RXD.0` and are indeed UART0 — but the schematic (p.18,
`EXT I/O`) shows them carrying PB9/PB10 as nets `CPU-TX`/`CPU-RX`, tied through
1 kΩ resistors R82/R83 to the `CPU DEBUG` net that feeds the separate 3-pin debug
header. Two consequences:

- **U-Boot prints to UART0 at 115200 on every boot.** `console=` in
  `orangepiEnv.txt` only controls the *kernel*, so it cannot silence the
  bootloader — your flight controller would receive a burst of boot text at each
  power-up. ArduPilot's parser discards non-frame bytes, so it is very likely
  harmless, but it is not clean.
- Using UART0 means **giving up the serial console**, which is the only way to
  debug a board that will not boot.

If you want it anyway (for example to reuse a Raspberry Pi harness, since pins
8/10 are the same physical pins as the Pi's UART):

```bash
sudo MLR_DEVICE=/dev/ttyS0 ./install.sh
```

`install.sh` will free the console, mask the getty, and warn you about the
bootloader noise.

## Install

Boot the Orange Pi Zero 3W with a fresh Ubuntu image and SSH in. Then:

```bash
wget -O install.sh https://raw.githubusercontent.com/PeterJBurke/installmavlinkrouterorangepizero3w/main/install.sh
chmod +x install.sh
sudo ./install.sh 2>&1 | tee MavlinkRouterBuildlog.txt
```

Then **reboot** — this is required, because the serial console has to be
released from UART0 before the flight controller can use it:

```bash
sudo reboot
```

After the reboot, verify:

```bash
wget -O test_serial.sh https://raw.githubusercontent.com/PeterJBurke/installmavlinkrouterorangepizero3w/main/test_serial.sh
chmod +x test_serial.sh
./test_serial.sh
```

**Runtime:** about 30–60 seconds, most of it `apt`. If it has to compile from
source instead of using the prebuilt binary, add ~25 seconds. (The Raspberry Pi
Zero 2 W version of this project takes 10–15 minutes — the A733 is dramatically
faster.)

### What the installer does

1. Verifies the board is `aarch64` and warns if it is not `sun60iw2`.
2. Installs `mavlink-routerd`:
   - uses the prebuilt binary in `bin/orangepizero3w-aarch64/` when the host
     glibc is new enough, **and only after proving the binary actually runs**;
   - otherwise compiles from source (meson + ninja), which takes ~25 s.
3. **Enables the UART** for your chosen device by adding e.g. `overlays=uart2`
   to `/boot/orangepiEnv.txt`, and installs a udev rule giving the port to the
   `dialout` group. If you chose UART0 instead, it frees the console and masks
   `serial-getty@ttyS0`; otherwise it *restores* `console=both`/`earlycon=on`
   and re-enables the getty, so the serial console keeps working.
4. Adds your user to `dialout`.
5. Writes `/etc/mavlink-router/main.conf` (backing up any existing one).
6. Installs and enables a `mavlink-router.service` systemd unit.
7. Refuses to start the service while the kernel still owns the port, and tells
   you to reboot.

It is **idempotent** — safe to re-run.

### Installer options

Set as environment variables:

```bash
sudo MLR_BAUD=115200 ./install.sh          # different FC telemetry baud
sudo MLR_TCP_PORT=14550 ./install.sh       # different TCP port
sudo MLR_FORCE_SOURCE=1 ./install.sh       # always compile, ignore prebuilt binary
sudo MLR_DEVICE=/dev/ttyS0 ./install.sh       # use UART0 on pins 8/10 instead
```

| Variable | Default | Meaning |
|---|---|---|
| `MLR_DEVICE` | `/dev/ttyS2` | serial device for the flight controller |
| `MLR_BAUD` | `57600` | FC telemetry baud |
| `MLR_TCP_PORT` | `5678` | TCP port for the ground station |
| `MLR_FORCE_SOURCE` | `0` | `1` = always build from source |
| `MLR_KEEP_CONSOLE` | `0` | `1` = keep the serial console on UART0 |
| `MLR_UART_OVERLAY` | *derived from device* | overlay to enable (`uart2`/`uart6`/`uart7`/`uart8`) |

---

## Connecting a ground station

MAVLink Router serves the stream on **TCP port 5678**:

```
Mission Planner / QGroundControl  ->  TCP  ->  <orange-pi-ip>:5678
```

Find the Pi's address with `hostname -I`.

To also push UDP to a fixed ground station, uncomment the `[UdpEndpoint gcs]`
block in `/etc/mavlink-router/main.conf` and `sudo systemctl restart mavlink-router`.

---

## Testing

`test_serial.sh` checks every failure mode we actually hit while building this:

```bash
./test_serial.sh              # all non-destructive checks
./test_serial.sh --loopback   # jumper pin 11 to pin 13 and prove TX/RX work
./test_serial.sh --listen 15  # sniff the FC for 15s and decode MAVLink frames
```

`--loopback` is the fastest way to separate "the Pi's UART is broken" from
"the wiring to the FC is wrong": with a jumper between pins 11 and 13 and no FC
attached, it should report `loopback OK`.

`--listen` stops the service, reads the raw port, and decodes MAVLink v1/v2
frames, printing which system IDs and message IDs arrived. It distinguishes:

- **nothing received** → FC unpowered, TX/RX swapped, or GND not shared;
- **bytes but no frames** → wrong baud rate;
- **HEARTBEAT present** → the link is good.

Manual checks:

```bash
systemctl status mavlink-router
journalctl -u mavlink-router -f
ss -ltn | grep 5678
```

---

## Why this is not just the Pi script

Porting `installmavlinkrouter2024` verbatim produces a system that looks
installed but cannot talk to a flight controller. The differences:

| | Raspberry Pi Zero 2 W | Orange Pi Zero 3W (A733) |
|---|---|---|
| Boot config | `/boot/firmware/config.txt`, `cmdline.txt` | `/boot/orangepiEnv.txt` — **the Pi files do not exist** |
| Enable the UART | on by default | `overlays=uart2` in `orangepiEnv.txt` |
| FC device | `/dev/serial0` | `/dev/ttyS2` (UART2, pins 11/13) |
| `/dev/ttyS1` | n/a | **onboard Bluetooth HCI — a trap, see below** |
| Upstream source | `github.com/intel/mavlink-router` | moved to `github.com/mavlink-router/mavlink-router` |
| Build time | 10–15 min | ~25 s |

### The three traps

1. **`/dev/ttyS1` is Bluetooth, not a spare UART.** It is `root:dialout` and
   writable, so it looks free — but `hciattach_opi -n -s 1500000 /dev/ttyS1 aic`
   owns it, its line discipline is `15` (`N_HCI`), and **writes to it block
   forever**. It is also wired to the onboard AIC8800 chip, not to the header,
   so killing Bluetooth does not help.

2. **`/dev/ttyS0` is the boot console and runs a login getty.** On a fresh
   image, therefore, **there is no usable free UART at all** — something must be
   reconfigured before an FC can be attached.

3. **The prebuilt binary needs glibc ≥ 2.42.** It is built against Ubuntu
   26.04's glibc 2.43 and will not run on Ubuntu 24.04 (2.39), Debian 12 /
   Raspberry Pi OS (2.36), or Ubuntu 22.04 (2.35). The installer checks this and
   falls back to compiling.

The full investigation — including the commands used to prove each of these — is
in **[docs/BUILD_JOURNAL.md](docs/BUILD_JOURNAL.md)**. Current project state and
the next step are in **[docs/HANDOFF.md](docs/HANDOFF.md)**.

---

## What is in this repo

```
install.sh                                 fresh image -> working install
uninstall.sh                               remove it, restore the serial console
test_serial.sh                             diagnostics, loopback, MAVLink sniffer
main.conf                                  reference mavlink-router config
bin/orangepizero3w-aarch64/mavlink-routerd prebuilt binary (glibc >= 2.42)
bin/orangepizero3w-aarch64/SHA256SUMS      checksum
docs/BUILD_JOURNAL.md                      how this was built, and every gotcha
docs/HANDOFF.md                            current state, what is verified, what is next
```

### Prebuilt binary provenance

| | |
|---|---|
| Source | `https://github.com/mavlink-router/mavlink-router.git` |
| Commit | `2362c620f483cef1edd574fb962a373a288e4b9e` (2026-03-30) |
| Submodule | `mavlink_c_library_v2` @ `052b8579f8aeb941f34cc9896af22cf1f38939b9` |
| Built on | Orange Pi Zero 3W, Ubuntu 26.04, gcc 15.2.0, meson 1.10.1, ninja 1.13.2 |
| Flags | `--buildtype=release -Dsystemdsystemunitdir=/usr/lib/systemd/system` |
| glibc floor | **2.42** |

Verify before trusting it:

```bash
cd bin/orangepizero3w-aarch64 && sha256sum -c SHA256SUMS
```

If you would rather not run someone else's binary at all:

```bash
sudo MLR_FORCE_SOURCE=1 ./install.sh
```

---

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

This removes the service, binary and config, and **restores the serial console**
on pins 8/10 — worth doing if you ever need console access to debug a board that
will not boot.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/dev/ttyS2` does not exist | overlay not applied yet | check `overlays=uart2` in `/boot/orangepiEnv.txt`, then `sudo reboot` |
| Pins 11/13 show `OFF`, not `ALT2` | overlay not loaded | same as above |
| Service restarts every 5 s | config or device error | `journalctl -u mavlink-router -n 50` |
| `--listen` shows 0 bytes | FC unpowered, TX/RX swapped, no shared GND | recheck wiring table |
| `--listen` shows bytes but no frames | wrong baud | match the FC's `SERIALn_BAUD` |
| Writes hang forever | you used `/dev/ttyS1` | use `/dev/ttyS2` |
| GCS cannot connect | firewall or wrong IP | `ss -ltn \| grep 5678`, `hostname -I` |
| Garbage on the FC at boot | you are on UART0; U-Boot prints there | switch to UART2 (pins 11/13) |

---

## References

- Orange Pi Zero 3W **user manual** v1.0 (A733) — §2.11 debugging serial port,
  §3.14 40-pin pinout, §3.16.5 40-pin UART test
- **OPi_ZERO_3W_V1_2 schematic** — p.9 SoC pin functions, p.18 `EXT I/O`
  (40-pin header net names, R82/R83)

Both are vendor-copyright and are not redistributed here. `docs/BUILD_JOURNAL.md`
quotes the specific tables and net names relied on.

## License

The installer scripts in this repo are provided as-is.
MAVLink Router itself is licensed under the Apache License 2.0 by its authors.
