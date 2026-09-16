# Build Journal — mavlink-router on Orange Pi Zero 3W

A literal record of every step taken to go from a **fresh, bare Ubuntu install**
on an Orange Pi Zero 3W to a working `mavlink-routerd`. Every finding here that
affects reproducibility is folded into `install.sh`.

Date of session: 2026-09-16

---

## 0. Baseline: what a fresh image actually looks like

Captured on an untouched Orange Pi Zero 3W image before installing anything.

### Board / OS

```
$ uname -a
Linux orangepi 6.6.98-sun60iw2 #1.0.2 SMP PREEMPT Fri Jul 31 16:44:03 UTC 2026 aarch64 GNU/Linux

$ cat /etc/os-release
PRETTY_NAME="Orange Pi 1.0.2 Resolute"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION="26.04 (Resolute Raccoon)"
VERSION_CODENAME=resolute

$ cat /proc/device-tree/model
sun60iw2
```

> **Gotcha #1 — this is NOT the H618 board most "Zero 3W" docs describe.**
> This unit is an Allwinner **A733 (`sun60iw2`)**. `/boot/orangepiEnv.txt` has
> `overlay_prefix=sun60i-a733` and `fdtfile=allwinner/sun60i-a733-orangepi-zero3w.dtb`.
> Any guide that tells you to use `sun50i-h616-*` overlays does not apply here.

### CPU / memory / disk

```
$ lscpu
Architecture:   aarch64
CPU(s):         8          # big.LITTLE: 6x Cortex-A55 + 2x Cortex-A76
CPU max MHz:    1794.0000

$ free -h
Mem:   5.7Gi total, 4.8Gi free      # 6GB model
Swap:  2.9Gi

$ df -h /
/dev/mmcblk1p1  58G  3.5G  54G  6% /
```

Plenty of RAM and cores — a native build is comfortable, no need to cross-compile
or limit `ninja` job count (contrast with the Pi Zero 2 W in the 2024 repo, which
needed 10–15 min; see timings in §3).

### What is already present on a bare image

| Tool | Status on fresh image | Version |
|---|---|---|
| `git` | present | 2.53.0 |
| `gcc` | present | 15.2.0 (Ubuntu 15.2.0-16ubuntu1) |
| `g++` | present | 15.2.0 |
| `pkg-config` | present | 2.5.1 |
| `python3` | present | 3.14.4 |
| `meson` | **MISSING** | apt candidate 1.10.1-1ubuntu2 |
| `ninja` | **MISSING** | apt candidate (ninja-build) 1.13.2 |
| `cmake` | **MISSING** | not needed |
| `gh` | **MISSING** | apt candidate 2.46.0-4 |
| `mavlink-routerd` | not installed | — |

### Serial ports on a fresh image

```
$ ls -l /dev/ttyS*
crw-------  1 orangepi tty      241, 0  /dev/ttyS0     # debug/console UART
crw-rw----  1 root     dialout  241, 1  /dev/ttyS1     # free for the FC

$ cat /proc/cmdline
... console=ttyS0,115200 console=tty1 ...

$ systemctl is-enabled serial-getty@ttyS0.service
enabled
```

> **Gotcha #2 — `/dev/ttyS0` is the serial console and cannot be used for the
> flight controller as shipped.** The kernel logs to it (`console=ttyS0,115200`)
> and `serial-getty@ttyS0` runs a login prompt on it. Feeding MAVLink into a
> getty produces garbage in both directions. `install.sh` must either free
> `ttyS0` (drop the console + mask the getty) or use `/dev/ttyS1`.
> We default to **`/dev/ttyS1`**, which is already `dialout`-owned and idle.

Available UART device-tree overlays for this SoC:

```
$ ls /boot/dtb/allwinner/overlay/ | grep -i uart
sun60i-a733-uart2.dtbo
sun60i-a733-uart6.dtbo
sun60i-a733-uart7.dtbo
sun60i-a733-uart8.dtbo
```

Enabled via `overlays=` in `/boot/orangepiEnv.txt` (NOT `/boot/firmware/config.txt`
— that is a Raspberry Pi path and does not exist on this board).

> **Gotcha #3 — the 2024 Raspberry Pi script edits `/boot/firmware/config.txt`
> and `/boot/firmware/cmdline.txt`.** Neither file exists here. Orange Pi uses
> `/boot/orangepiEnv.txt`. Porting the old script verbatim silently does nothing.

---

## 1. Failed approach: meson/ninja via pip (do not do this)

First attempt was to avoid `sudo` by building inside a Python venv:

```
$ python3 -m venv .buildvenv
The virtual environment was not created successfully because ensurepip is not
available.  On Debian/Ubuntu systems, you need to install the python3-venv
package using the following command.
    apt install python3.14-venv

$ python3 -m pip --version
/usr/bin/python3: No module named pip
```

> **Gotcha #4 — the fresh image ships Python 3.14 with neither `pip` nor
> `ensurepip`/`venv`.** `python3-venv` and `python3-pip` are both uninstalled.
> So there is no sudo-free path to meson. Since apt already carries meson 1.10.1
> (mavlink-router needs `>= 0.55`) and ninja 1.13.2, **use apt**. This is simpler
> and avoids pulling a second Python toolchain onto the board.

---

## 2. Installing build dependencies

```
sudo apt-get update
sudo apt-get install -y git meson ninja-build pkg-config gcc g++ gh
```

> **Gotcha #5 — do not prefix this with `!` in a normal bash shell.**
> In bash, leading `!` is the logical-NOT operator, so
> `! sudo apt-get update && sudo apt-get install ...` evaluates as
> "NOT(update succeeded) AND install" and the install is silently skipped
> because the update succeeded. This bit us once; the symptom is `apt-get update`
> output followed by `gh: command not found`.

`gh` (GitHub CLI) is only needed to publish this repo, not to run mavlink-router.
It is excluded from the runtime dependency list in `install.sh`.

---

## 3. Fetching mavlink-router source

```
git clone --depth 1 https://github.com/mavlink-router/mavlink-router.git
cd mavlink-router
git submodule update --init --recursive
```

Pinned state used for the shipped binary:

```
commit  2362c620f483cef1edd574fb962a373a288e4b9e   (2026-03-30)  "fix missing cstdint in dedup.h"
submodule modules/mavlink_c_library_v2 @ 052b8579f8aeb941f34cc9896af22cf1f38939b9
meson_version required: >= 0.55
```

> **Gotcha #6 — the upstream repo moved.** The 2024 Raspberry Pi script clones
> `https://github.com/intel/mavlink-router.git`. The maintained home is now
> `https://github.com/mavlink-router/mavlink-router.git`. Use the latter.

> **Gotcha #7 — `--depth 1` alone is not enough.** The MAVLink C headers live in
> the `modules/mavlink_c_library_v2` submodule; without
> `git submodule update --init --recursive` the meson configure step fails.

(Build steps and timings recorded in the next section once meson/ninja land.)

---

## 4. Configuring the build (meson)

First attempt, using the same invocation as the 2024 Raspberry Pi script:

```
$ meson setup build .
...
Run-time dependency systemd found: NO (tried pkgconfig)
meson.build:33:16: ERROR: Dependency "systemd" not found, tried pkgconfig
```

> **Gotcha #8 — the Pi script's dependency list is incomplete on bare Ubuntu.**
> `git meson ninja-build pkg-config gcc g++` is not sufficient; meson also wants
> a `systemd` pkg-config file, which comes from `libsystemd-dev` (not installed
> on a fresh image).

Reading `meson.build:31-35`, the `systemd` dependency is used **only** to look up
the unit directory — mavlink-routerd does not link against libsystemd:

```meson
systemd_system_unit_dir = get_option('systemdsystemunitdir')
if systemd_system_unit_dir == 'auto'
        dep_systemd = dependency('systemd')
        systemd_system_unit_dir = dep_systemd.get_variable(pkgconfig: 'systemdsystemunitdir')
endif
```

So rather than pull in `libsystemd-dev`, supply the path directly. This keeps the
dependency list minimal, which matters for a bare-image installer:

```
meson setup build . -Dsystemdsystemunitdir=/usr/lib/systemd/system --buildtype=release
```

(`/lib` is a symlink to `/usr/lib` on this merged-usr image; both paths exist.)

Result:

```
Build targets in project: 6
  User defined options
    buildtype           : release
    systemdsystemunitdir: /usr/lib/systemd/system
configure_seconds=4
```

## 5. Compiling

```
$ ninja -C build
[25/25] Linking target src/mavlink-routerd
build_seconds=23
```

> **23 seconds.** For comparison the 2024 Raspberry Pi Zero 2 W repo documents
> 10–15 minutes for the same build. The 6GB / 8-core A733 does not need any
> `ninja -j` throttling or swap tuning.

## 6. Verifying the binary

```
$ file build/src/mavlink-routerd
ELF 64-bit LSB pie executable, ARM aarch64, version 1 (GNU/Linux),
dynamically linked, interpreter /lib/ld-linux-aarch64.so.1, for GNU/Linux 3.7.0

$ ./build/src/mavlink-routerd --version
mavlink-router version 2362c62

$ ldd build/src/mavlink-routerd
        libstdc++.so.6, libgcc_s.so.1, libc.so.6, libm.so.6
```

Only base-system libraries — no extra runtime packages needed.

### Portability floor of the prebuilt binary

```
$ objdump -T build/src/mavlink-routerd | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
GLIBC_2.42

$ ldd --version
ldd (Ubuntu GLIBC 2.43-2ubuntu2) 2.43
```

> **Gotcha #9 — the shipped binary requires glibc >= 2.42.** It was built against
> Ubuntu 26.04's glibc 2.43. It will **not** run on:
> Ubuntu 24.04 (2.39), Debian 12 bookworm / Raspberry Pi OS (2.36), Ubuntu 22.04 (2.35).
> Symptom would be:
> `/lib/ld-linux-aarch64.so.1: version 'GLIBC_2.42' not found`.
>
> Therefore `install.sh` **must** probe the running glibc version before using the
> prebuilt binary, and fall back to compiling from source when it is too old.
> Since the source build is only ~25 s on this board, the fallback is cheap.

### Shipped artifact

```
$ strip mavlink-routerd
$ ls -lh mavlink-routerd        # 388K (473K unstripped)
$ sha256sum mavlink-routerd
88373c92d0f5d765fd7f6dcc477d71f5e99ada1515744746db9b6a9a1c62d51f  mavlink-routerd
```

Committed to `bin/orangepizero3w-aarch64/` with a `SHA256SUMS` file.

### Upstream's own systemd unit

meson generates `build/mavlink-router.service`:

```ini
[Unit]
Description=MAVLink Router
[Service]
Type=simple
ExecStart=/usr/bin/mavlink-routerd --syslog
Restart=on-failure
[Install]
WantedBy=multi-user.target
```

We ship our own unit instead: it pins `-c /etc/mavlink-router/main.conf`, uses
`Restart=always` with `RestartSec=5`, and adds `After=network.target` plus a
dependency on the serial device so it does not spin before the UART exists.

---

## 7. UART investigation — the important part

This board's serial situation is **completely different from the Raspberry Pi**,
and the naive port of the 2024 script would produce a non-working system.

### 7.1 Which ttys exist and what they are

```
$ cat /proc/device-tree/aliases/serial*
serial0 -> /soc@3000000/uart@2500000
serial1 -> /soc@3000000/uart@2501000
... serial8

$ readlink -f /sys/class/tty/ttyS0/device   -> .../2500000.uart
$ readlink -f /sys/class/tty/ttyS1/device   -> .../2501000.uart
```

Only `uart@2500000` (ttyS0) and `uart@2501000` (ttyS1) have `status = "okay"`
in the base DTB. `uart@2502000` (uart2) and the rest are `disabled`.

### 7.2 Gotcha #10 — ttyS1 is the Bluetooth HCI port, NOT a free UART

`/dev/ttyS1` looks perfect at first glance: it is `root:dialout`, `crw-rw----`,
and the user is in `dialout`, so it is writable. **It is a trap.**

A write to it blocks forever:

```
$ stty -F /dev/ttyS1 300 cs8 -cstopb -parenb -crtscts raw -echo
$ timeout 10 bash -c 'printf "\000...\000" > /dev/ttyS1'
exit=124   elapsed=10.03s      # never drained; 16 bytes @300baud should take 0.5s
```

The tell is in `stty -a`:

```
speed 300 baud; rows 0; columns 0; line = 15;
                                   ^^^^^^^^
```

Line discipline **15 = N_HCI (Bluetooth HCI UART)**. Confirmed:

```
$ ps aux | grep hciattach
root  1011  /usr/bin/hciattach_opi -n -s 1500000 /dev/ttyS1 aic

$ hciconfig -a
hci0:  Type: Primary  Bus: UART
       UP RUNNING
```

The onboard AIC8800 Wi-Fi/BT combo is attached to UART1 at 1.5 Mbaud at boot.
Furthermore UART1 is wired **internally to the BT chip**, not to the 40-pin
header — so killing Bluetooth to free it does not give you a usable pin header
either. Do not use ttyS1 for the flight controller.

### 7.3 Gotcha #11 — ttyS0 is the boot console + a login getty

```
$ cat /proc/cmdline
... earlyprintk=sunxi-uart,0x02500000 ... console=ttyS0,115200 console=tty1 ...

$ systemctl is-enabled serial-getty@ttyS0.service
enabled
```

So on a **fresh image there is no usable free UART at all.** Something must be
reconfigured before a flight controller can be attached.

### 7.4 The 40-pin header

`gpio readall` (wiringOP, preinstalled, correctly identifies the board as ZERO3W):

```
 | GPIO | wPi |   Name   |  Mode  | V | Physical | V |  Mode  | Name     | wPi | GPIO |
 |   36 |   2 |   PWM0-0 |    OFF | 0 |  7 || 8  | 0 | ALT2   | TXD.0    | 3   | 41   |
 |      |     |      GND |        |   |  9 || 10 | 0 | ALT2   | RXD.0    | 4   | 42   |
 |   32 |   5 |      PB0 |  ALT14 | 1 | 11 || 12 | 0 | OFF    | PB5      | 6   | 37   |
 |   33 |   7 |      PB1 |  ALT14 | 1 | 13 || 14 |   |        | GND      |     |      |
```

**Physical pin 8 = UART0 TX, physical pin 10 = UART0 RX**, already muxed to ALT2.
Conveniently these are the *same physical pins* as the Raspberry Pi's UART, so an
existing FC harness plugs in unchanged.

(PB0/PB1 on pins 11/13 sit at ALT14 and idle high; they did not toggle when we
transmitted, and they are not UART0. Their function was not needed and was not
pursued further.)

### 7.5 How to reconfigure boot on this board

`/boot/boot.cmd` sets defaults and **then** imports `/boot/orangepiEnv.txt`, so
values in `orangepiEnv.txt` win:

```
setenv console "both"          # default
setenv earlycon "on"           # default
...
if test -e ... orangepiEnv.txt; then
        load ... ${prefix}orangepiEnv.txt
        env import -t ${load_addr} ${filesize}
fi
...
if test "${console}" = "serial" || test "${console}" = "both"; then
        setenv consoleargs "console=ttyS0,115200 ${consoleargs}"; fi
if test "${earlycon}" = "on"; then
        setenv consoleargs "earlyprintk=sunxi-uart,0x02500000 ... ${consoleargs}"; fi
```

> **Therefore, to free ttyS0 you do NOT edit boot.cmd or regenerate boot.scr.**
> You add to `/boot/orangepiEnv.txt`:
> ```
> console=display
> earlycon=off
> ```
> and disable the getty: `systemctl disable --now serial-getty@ttyS0.service`

Overlay loading, same file:

```
for overlay_file in ${overlays}; do
    load ... ${prefix}dtb/allwinner/overlay/${overlay_prefix}-${overlay_file}.dtbo
```

so `overlays=uart2` in `orangepiEnv.txt` loads `sun60i-a733-uart2.dtbo`.
Those overlays are 224-byte stubs that only set `status = "okay"`; the pinmux is
already in the base DTB.

> **Gotcha #12 — `/boot/firmware/config.txt` and `cmdline.txt` do not exist.**
> The 2024 Pi script's entire `installstuff()` serial-config block is a silent
> no-op on this hardware. It must be replaced with the `orangepiEnv.txt` logic above.
