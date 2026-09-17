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

---

## 8. First real end-to-end run (and the bug it exposed)

`sudo ./install.sh` ran in **8 seconds**, used the prebuilt binary (host glibc
2.43 >= required 2.42), wrote the config and unit, correctly refused to start the
service while the kernel still owned ttyS0, and asked for a reboot. After the
reboot the console was off ttyS0 and `mavlink-router.service` was active and
listening on TCP 5678.

But `./test_serial.sh` still reported one failure:

```
  FAIL  serial-getty@ttyS0.service is active/enabled — a login prompt is fighting for the port
```

The install log showed the getty block had never executed — it jumped straight
from the console warning to the dialout check, with no
"Disabled and masked serial-getty@ttyS0.service" line.

### Gotcha #13 — `set -o pipefail` + `grep -q` silently inverts a guard

The guard was:

```bash
if systemctl list-unit-files 2>/dev/null | grep -q '^serial-getty@'; then
```

Tested interactively, this is TRUE. Inside the script it is FALSE:

```
$ bash -c 'if systemctl list-unit-files | grep -q "^serial-getty@"; then echo TRUE; else echo FALSE; fi'
TRUE

$ bash -c 'set -euo pipefail; if systemctl list-unit-files | grep -q "^serial-getty@"; then echo TRUE; else echo FALSE; fi'
FALSE

$ bash -c 'set -o pipefail; systemctl list-unit-files | grep -q "^serial-getty@"; echo $?'
141
```

**141 = 128 + 13 = SIGPIPE.** `grep -q` exits the moment it finds a match. The
upstream `systemctl`, still writing its (long) output, gets SIGPIPE and dies with
141. `set -o pipefail` makes the pipeline take the *worst* status in the pipe, so
the whole condition fails — and the entire block is skipped **silently**, because
a false `if` is not an error.

This is insidious for three reasons:

1. It cannot be reproduced by typing the same command at an interactive prompt,
   because your shell does not have `pipefail` set.
2. `bash -n` cannot catch it; the syntax is perfect.
3. Whether it bites **depends on how much data the writer produces**. The same
   pattern on line 267:
   ```bash
   if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx dialout; then
   ```
   *worked*, because `id -nG`'s output is tiny and `tr` finishes writing into the
   64K pipe buffer before `grep -q` exits — so no SIGPIPE. It is a race that
   happens to be won. The `systemctl` version produces far more output and loses
   the race deterministically.

**Fix:** use plain `grep ... >/dev/null` instead of `grep -q`. Plain grep keeps
reading to the end of input looking for further matches, so the writer never gets
SIGPIPE:

```bash
if systemctl list-unit-files --no-legend --plain 2>/dev/null | grep '^serial-getty@' >/dev/null; then
```

All occurrences were fixed in `install.sh` (2), `test_serial.sh` (3) and
`uninstall.sh` (1). The one in `uninstall.sh` guarded the service-removal block,
so uninstall would have silently failed to remove the unit.

> **Rule for this repo: never use `grep -q` on the right-hand side of a pipe in a
> script that sets `pipefail`.** Prefer `grep pattern >/dev/null`, or capture the
> output into a variable first and match against that.

---

## 9. Two more bugs found by re-running

Re-running `install.sh` after the pipefail fix disabled and masked the getty
correctly, but exposed two further problems.

### Gotcha #14 — masking the getty makes /dev/ttyS0 root-only

Before the fix, `/dev/ttyS0` showed as `orangepi:tty 0600`. That ownership was
not a property of the device — it was the *login session* on the getty, which
chowns its tty to the logged-in user. With the getty masked, it reverts:

```
$ ls -l /dev/ttyS0
crw------- 1 root tty 241, 0 /dev/ttyS0
```

Console devices are given the **`tty`** group, not `dialout` (compare `/dev/ttyS1`,
which is `root:dialout 0660`). So being in `dialout` does not help, and any
non-root tool gets EACCES:

```
  FAIL  not read/write for orangepi — are you in 'dialout'? (groups: ... dialout ...)
```

Note how misleading the symptom is: the user *is* in `dialout`, so the obvious
diagnosis is wrong. `mavlink-router.service` was unaffected the whole time
because it runs as root — the failure only hits interactive tools.

**Fix** — install a udev rule (`install.sh` §3ab):

```
# /etc/udev/rules.d/99-mavlink-router-uart.rules
KERNEL=="ttyS0", GROUP="dialout", MODE="0660"
```

then `udevadm control --reload-rules && udevadm trigger --subsystem-match=tty`.
Result:

```
crw-rw---- 1 root dialout 241, 0 /dev/ttyS0
```

### Gotcha #15 — `systemctl is-enabled` on a masked unit exits non-zero

`test_serial.sh` printed a stray `not-found` line under an otherwise-passing
check. Cause:

```bash
GSTATE="$(systemctl is-enabled "$GETTY" 2>/dev/null || echo 'not-found')"
```

For a **masked** unit, `systemctl is-enabled` writes `masked` to stdout **and
exits 1**. So the `||` branch also ran, and the variable became two lines:
`masked\nnot-found`. Same class of mistake as gotcha #13 — assuming a non-zero
exit means "no output". Fixed with `|| true` plus an explicit empty check.

### Final state — all checks passing

```
1. Board            PASS  Orange Pi Zero 3W (A733 / sun60iw2)
2. Serial device    PASS  /dev/ttyS0 (root:dialout 660), rw, line discipline 0
3. Console          PASS  console off ttyS0; serial-getty@ttyS0 masked
4. Header           PASS  pins 8/10 muxed ALT2 as TXD.0/RXD.0
5. mavlink-router   PASS  2362c62 running, listening on TCP 5678
```

`install.sh` was run three times in total with no ill effects, which is the
idempotency check. Timings: 8 s, 12 s, 11 s.

**Remaining work:** connect a flight controller to pins 8/10/6 and confirm
HEARTBEAT with `./test_serial.sh --listen 15`. Until that is done, the serial
path has been proven only up to the port, not end to end.

---

## 10. Vendor documentation arrives — and changes the answer

The Orange Pi Zero 3W user manual (281 pp.) and the V1.2 schematic (18 pp.) were
obtained after the UART0 implementation was already working. They changed the
right answer. Both are in `docs/vendor/` locally but are **not committed**
(vendor copyright, 17 MB combined).

Extraction note: both PDFs use CID-encoded fonts, so pulling literal strings out
of the content streams yields glyph indices, not text. `poppler-utils`
(`pdftotext -layout`) was required.

### 10.1 What the manual says

Section 3.16.5, *40 pin UART test*:

> the Orange Pi Zero 3w can use three UART buses: UART2, UART6, and UART7.

| UART BUS | RX = 40-pin | TX = 40-pin | dtbo |
|---|---|---|---|
| UART2 | PIN 13 | PIN 11 | `uart2` |
| UART6 | PIN 23 | PIN 24 | `uart6` |
| UART7 | PIN 18 | PIN 16 | `uart7` |

**UART0 is not listed.** Section 2.11 documents it separately as the *debugging
serial port*, on a dedicated "3Pin debugging serial port" connector.

### 10.2 What the schematic says

Page 18, `EXT I/O` — the 40-pin header:

```
 7 GPCLK        UART_TX   8      CPU-TX  --R82 1K--> CPUX-TX
 9 GND          UART_RX  10      CPU-RX  --R83 1K--> CPUX-RX      CPU DEBUG
11 GPIO      PWM/PCM_CLK 12      PB0
13 GPIO          GND     14      PB1
```

and page 9, the SoC pin list:

```
PB9/UART0-TX/...    net: CPUX-TX
PB10/UART0-RX/...   net: CPUX-RX
PB0/UART2-TX/UART0-TX/SPI2-CS0/...
PB1/UART2-RX/UART0-RX/SPI2-CLK/...
```

So the earlier empirical mapping was **correct**: header pins 8/10 are PB9/PB10 =
UART0, which is why `gpio readall` labels them `TXD.0`/`RXD.0` at ALT2. But two
facts were invisible from the board alone:

1. **Pins 8/10 are the CPU DEBUG net**, joined to the separate 3-pin debug
   header through 1 kΩ series resistors R82/R83. The port is shared.
2. **U-Boot also prints to UART0 at 115200 on every boot.** `console=` in
   `orangepiEnv.txt` only builds the *kernel* cmdline; it cannot silence the
   bootloader. A flight controller on pins 8/10 therefore receives a burst of
   boot text at every power-up. (Reasoned from the design — proving it needs a
   USB-TTL adapter on the other end, which was not available.)

Also note `PB0`/`PB1` carry **both** UART2 and UART0 alternate functions, which
is why they idled high in `ALT14` before any overlay was applied.

### 10.3 Decision: UART2 becomes the default

UART2 (pins 11/13) avoids the bootloader noise and the shared debug net, and
**keeps the serial console** — the only way to debug a board that will not boot,
which matters once you start editing boot configuration. The cost is that the
harness moves from pins 8/10 to 11/13.

UART0 remains fully supported via `MLR_DEVICE=/dev/ttyS0`, and `install.sh` warns
about the U-Boot noise when it is selected.

`install.sh` was also taught to migrate *between* modes: selecting a non-UART0
device now actively restores `console=both` / `earlycon=on` and unmasks the
getty, instead of silently leaving the console disabled from a previous install.

### 10.4 Gotcha #16 — a block-replacing edit silently dropped a step

While restructuring section 3a, the replacement spanned from the `3a` marker to
the `3b` marker — which **deleted the `3ab` udev block that lived between them**.
The result: the udev rule stayed pinned to `ttyS0` while everything else moved to
`ttyS2`, so the new port would have been root-only.

It was caught only because the expected `udev rule installed:` line was missing
from the run log. Same signature as gotcha #13: the script reported success while
skipping a step, and the exit code was 0 both times. **On this project, the log
has caught two bugs the exit status did not.**

### 10.5 Verification after the switch

```
$ ls -l /dev/ttyS2
crw-rw---- 1 root dialout 241, 2 /dev/ttyS2          # udev rule applied

$ tr -d '\0' < /proc/device-tree/soc@3000000/uart@2502000/status
okay                                                  # overlay applied

$ journalctl -k | grep ttyS2
uart-ng2: ttyS2 at MMIO 0x2502000 (irq = 111, base_baud = 1500000) is a SUNXI

$ gpio readall | grep -E ' 11 | 13 '
| 32 | 5 | PB0 | ALT2 | 0 | 11 |     # was ALT14 before the overlay
| 33 | 7 | PB1 | ALT2 | 0 | 13 |     # ALT2 == the mux used by known-good UART0
```

Transmit test (the same one that exposed ttyS1 as Bluetooth):

```
$ stty -F /dev/ttyS2 300 ...; time printf '<16 bytes>' > /dev/ttyS2
exit=0  elapsed=0.62s
```

16 bytes × 10 bits ÷ 300 baud = 0.53 s theoretical. The measured 0.62 s matches,
confirming real transmission at the configured rate rather than writes vanishing
into a buffer. Compare `/dev/ttyS1`, which blocked for the full 10 s timeout.

`./test_serial.sh` reports **all checks passed**.

**Still outstanding:** no flight controller has been attached. Everything is
proven up to and including the port transmitting, but not end to end.

---

## 11. Loopback test — the Pi-side signal path is proven

With a jumper between header **pin 11 and pin 13** and nothing else connected:

```
6. Loopback test
        Jumper header pin 11 to pin 13 (UART2 TX to RX), then press Enter.
        stopping mavlink-router for the test...
  PASS  loopback OK — sent and received 'MAVLINK-ROUTER-LOOPBACK-2774'

Summary
  All checks passed.
```

This closes the last gap on the Pi side: bytes physically left pin 11, crossed the
jumper, and were read back on pin 13. Previously we had only shown that writes
*drained* at the expected rate; now the receive path and the physical pins are
confirmed too.

It is also an independent confirmation of the header numbering. The jumper was
placed on the **6th and 7th pins down the odd row**. Had the odd column been
numbered 1..20 sequentially (making those pins 6 and 7), the test would have
failed — pin 6 is GND.

### Note on reading the page-13 pinout diagram

The diagram on manual page 13 does **not** print pin numbers; it shows two columns
of dots and you must know the numbering scheme. On this 2x20 header the rows
interleave, so going down one column steps by **2**:

```
left column:  pin = 2 * row - 1     ->  row 6 = pin 11, row 7 = pin 13
right column: pin = 2 * row
```

The manual proves its own scheme: on page 13 `UART6_RX` sits in the left column
and `UART6_TX` in the right column **at the same height**, and §3.16.5 gives them
as PIN 23 and PIN 24 — consecutive numbers across the two columns at one row,
which is only possible with interleaved numbering.

Counting each column 1..20 instead is an easy mistake and puts UART2 on "pins 6
and 7", which cannot be right: 6 and 7 are in *different* rows (6 is GND, 7 is
PWM0-0), so no signal pair lands there.

### Locating a pin physically without counting

The Zero 3W has no header pads on the underside (the bottom carries the MicroSD
slot, MIPI LCD, two camera FPC sockets, PCIe and UFS), so the usual "pin 1 is the
square pad on the back" trick does not apply.

Instead, drive a known pin and find it with a meter. Pin 12 is unused, and it sits
directly opposite pin 11:

```
gpio mode 6 out && gpio write 6 1    # wPi 6 == physical pin 12 -> 3.3V
# probe the EVEN row: the only pin reading 3.3V is pin 12
gpio mode 6 in                       # release when done
```

This is unambiguous because the even row otherwise holds 5V (pins 2, 4), GND
(6, 14, 20, ...) and UART0 (8, 10) — no other steady 3.3V. The header's other
3.3V pins (1 and 17) are in the odd row.
