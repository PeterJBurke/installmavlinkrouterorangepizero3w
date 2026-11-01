# Handoff — state of play

Last updated: 2026-11-01 (very late; video at 720p30, latency=100, 2.0 Mbit/s). Written so a fresh session (or a future you) can pick up
without re-deriving anything.

---

## Session — 2026-11-01, late evening — UDP telemetry live, RTSP video, tailnet bug confirmed, Thursday audit

Long session. Everything below is the delta on top of the earlier 2026-11-01
sections. Mission Planner laptop is **`win11rogasus` (100.123.80.42)** — NOT the
Surface (100.109.85.83) I had assumed all evening; the Surface is offline.

### State when stopped

| item | state |
|---|---|
| Tailscale | **1.104.4** (upgraded from 1.102.4; the restart dropped the SSH session, as expected). Health OK |
| `tcp_retries2` | **= 8, applied and persistent** (`/etc/sysctl.d/90-tcp-retries.conf`, user ran it) |
| mavlink-router | TCP :5678 **and** `[UdpEndpoint gcs] Mode=Server :14550` (pull). Full file in `~/inbox/main.conf`, installed by the user |
| Mission Planner telemetry | **connected via UDPCl → 100.92.72.14:14550, healthy**: ~77 pkt/s each way, flat for 2 min, 0 drops, 0 router errors. Path relayed via DERP lax, 14 ms |
| Camera | **`camstream-rtsp` is the boot default**: mediamtx + ffmpeg, H.264 640x480@30 ~600 kbit/s, pull from `rtsp://100.92.72.14:8554/cam`. Three modes via `~/camstream/mode.sh mjpeg|h264|rtsp|status` (mutual `Conflicts=`) |
| Video in VLC | **works** (1 s lag = VLC's default 1000 ms network cache; `--network-caching=200`) |
| Video in Mission Planner | **WORKING** (confirmed ~23:30). Final pipeline in `~/inbox/mp_pipeline.txt`; see the RTSP section for what changed |
| `netaudit.service` | running, logs to `~/netaudit/journal.log` + 30 s `health.csv`, now tracking the right laptop |
| Baud | still 57600 both ends, **on the back burner**; see the UART finding — do NOT pick 460800 or 921600 |

### Tailnet "disconnected" — CONFIRMED a Tailscale bug, with fixes pending upstream

User pushed back ("tailscale should dynamically reconfigure… ZeroTier didn't do
this") and was right to. Research found the exact mechanism acknowledged:

* [PR #21834 — drop Noise client when map watchdog fires](https://github.com/tailscale/tailscale/pull/21834):
  *upstream NAT change blackholes the control TCP connection; the map watchdog
  fires but the ts2021 transport keeps reusing the dead connection.* That is our
  20:34–20:50 log line for line.
* [PR #20618 — reset control transport on new STUN IP](https://github.com/tailscale/tailscale/pull/20618):
  WAN changed, local interface did not.
* Underlying issue #12021, open since 2024. Both PRs were still open as of
  mid-Oct 2026; **not in 1.104.4**. Estimate: 1–3 months if merged soon;
  realistically longer. **Do not plan around it.**
* Why ZeroTier never showed it: its control traffic is UDP to root servers — no
  long-lived TCP session to strand. Tailscale's data plane is also UDP (SSH
  survived the whole stall); only its control channel is TCP.
* Why exactly ~15 min: tailscaled kept *sending* on the dead socket, so TCP's
  retransmission budget (`tcp_retries2=15`) governed, not keepalive (keepalive
  only runs when idle). `tcp_retries2=8` → ~100 s. Applied.
* Cell-tower handoff keeps the phone's IP → does NOT trigger this. Wi-Fi↔cellular
  flips on the phone do.

Correction recorded: the control-plane stall explains the admin-console
"disconnected", **not** the MP drops during that window — peer pings were 0%
loss then. MP drops over TCP had their own cause (jitter + TCP); UDP is the
mitigation and is now in place.

### Thursday 2026-10-29 demo disconnects — what could and could not be audited

* **No Pi logs survive**: journald is `Storage=volatile` (wiped at reboot);
  `/var/log/syslog` exists but is root-only. User can recover with:
  `sudo zcat -f /var/log/syslog* | grep "^2026-10-29" | grep -iE "tailscaled|NetworkManager|wpa_supplicant" > ~/inbox/thursday.log`
  Also: Tailscale admin console machine page keeps "last seen" history.
* **Most likely chain**: phone Wi-Fi was on with campus networks saved; walking
  away from the lecture hall the phone joined/left eduroam/UCI Wi-Fi at coverage
  edges → each crossing flipped the hotspot's upstream → (a) Tailscale control
  stranded 15 min, or (b) One UI 6.1/7 drops the hotspot outright when the
  phone's Wi-Fi connects (community reports). Both fit "twice, both when carried
  far away".
* **Demo rules derived**: phone Wi-Fi OFF for the whole demo (removes the
  trigger; also kills Samsung Auto Hotspot behaviour); `tcp_retries2=8` (done);
  UDP telemetry (done); RTSP video. `netaudit` makes the next incident
  auditable to the half-minute.
* Phone setting (One UI): Settings → Connections → Mobile Hotspot and
  Tethering → Mobile Hotspot → Configure → **Wi-Fi sharing off**. Verified
  working tonight via public IP changing from googlefiber.net to AT&T.

### UART baud — IMPORTANT finding, corrects earlier advice

The class param file (`~/inbox/Params08Aug2026_CRSF.param`) sets
`SERIAL2_BAUD = 460` (460800). **That rate cannot be generated by this Pi.**
`/dev/ttyS2` has a 24 MHz clock, 16x sampling, integer divisor → only
1,500,000 / N:

| requested | actual | error | |
|---|---|---|---|
| 57600 | 57692 | +0.2% | OK (current) |
| 115200 | 115385 | +0.2% | OK |
| 230400 | 214286 | −7.0% | bad |
| **460800** | 500000 | **+8.5%** | **bad — almost certainly why September's 460800 attempt failed** |
| **500000** | 500000 | 0.0% | **OK, exact — the recommended fast rate (ArduPilot code 500)** |
| 921600 | 750000 | −18.6% | bad — I had recommended this earlier; retracted |
| 1500000 | 1500000 | 0.0% | OK but FIFO-overrun risk under load |

Suggest the Canvas instructions change 460 → 500 for Orange Pi students. The
commented-out `Baud = 500000` line is in `~/inbox/main.conf` with this note.

Live FC also deviates from the class file: `SERIAL6_PROTOCOL` 2 (file: 23 CRSF
RC), `RSSI_TYPE` 5 (file: 3). RC works, so input comes from elsewhere. Full
param diff offered, not run.

### RTSP video in Mission Planner — corruption, diagnosis, RESOLVED

**Outcome: working.** Three changes landed between broken and working, and I
cannot say which one did it: (1) encoder switched to one slice per frame
(`sliced-threads=0:threads=N:aud=1` — zerolatency had been cutting each frame
into ~8 slices, and missing slices look exactly like the bands seen);
(2) RTCP-free MP pipeline (`do-rtcp=false buffer-mode=none`); (3) the user had
mistyped the pipeline on the previous attempt — a wrapped paste into MP's
single-line box is a real failure mode, hence `~/inbox/mp_pipeline.txt` as a
one-line file to copy from Notepad. All three are kept.

**Resolution raised to 1280x720@30, 1.5 Mbit/s** after benchmarking (720p30 =
115% of one core; 800x600@30 = 67%; 720p15 = 63%). Presets with cost are
commented in `mediamtx.yml`. Measured on air ≈ 1.7 Mbit/s incl. telemetry ⇒
~770 MB/h on cellular; drop to 640x480@30 (~330 MB/h) if data matters.

**Latency knob**: **`latency=100` confirmed working** by the user at 720p30
(was 200). It is the jitter buffer; with `buffer-mode=none` it is the only
deliberate delay left; the rest is encode (~2 frames with frame-threading) +
14 ms RTT. 50 untried. `~/inbox/mp_pipeline.txt` still says 200 — edit to 100.

**Bandwidth measured at 720p30, MP connected, 30 s flat**: **~2.0 Mbit/s out**
(1.5 video + ~0.15 telemetry + ~0.3 RTP/TCP/WireGuard encapsulation — I had
under-counted encapsulation at 1.7), 0.2 in. **≈ 900 MB/h on cellular.**
800x600 ≈ 1.4 Mbit/s (~630 MB/h); 640x480 ≈ 0.9 (~400 MB/h). Encoder 112% of
one core, load 1.8/8 — the uplink, not the Pi, is the limit.

Original diagnosis notes follow.

Symptom: HUD shows the picture under horizontal grey/green bands; VLC clean.
MP's GStreamer log: `<avdec_h264-1> decreasing timestamp (0:00:57 < 0:03:20)`,
repeating. Server verified clean: ffmpeg decoded the live stream with 0
complaints; GStreamer on the Pi decoded 600 frames with 0 warnings; encoder
never restarted.

Mechanism (GStreamer Discourse): rtspsrc rebases timestamps when **RTCP sender
reports** arrive; MP's bundled GStreamer handles the rebase badly, VLC ignores
RTCP timing. Fixes:
1. **Server (applied)**: ffmpeg `-use_wallclock_as_timestamps 1 -fps_mode cfr -r 30`
   so RTP and NTP agree. Verified: 240 frames at exactly 33.3 ms, 0 backward.
2. **MP pipeline (handed over, unconfirmed)**:
   `rtspsrc location=rtsp://100.92.72.14:8554/cam latency=200 protocols=tcp do-rtcp=false buffer-mode=none ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=outsink sync=false`
   (`latency=0` in my first pipeline was also wrong — jitter buffer drops late
   packets → slice loss.) Restart MP before setting it; MP may keep an old
   pipeline alive (`-1` decoder instance). If still corrupt: try `decodebin` in
   place of depay/parse/decoder; the remaining suspect is MP's GStreamer version.

Fallback that is known-good with MP's *default* pipeline: `mode.sh h264` (RTP
push to UDP 5600) — but `h264.env` DEST_IP still points at the Surface; change to
100.123.80.42 if ever used. User prefers pull.

### Decision: camera modes stay EXCLUSIVE (user, 2026-11-01)

Only one of `camstream` (MJPEG page :8080), `camstream-h264` (push :5600),
`camstream-rtsp` (pull :8554) runs at a time, enforced by `Conflicts=`. The
user considered and **declined** running the MJPEG overlay page alongside RTSP.
Reasons recorded so nobody rebuilds it: MJPEG is 15 Mbit/s (LAN-only, useless
on cellular); splitting one camera needs `v4l2loopback` built against the vendor
`6.6.98-sun60iw2` kernel (headers uncertain, a bad module can take the camera
down at boot); extra encode + a frame of latency; and the overlay would then
measure a loopback copy, not what Mission Planner receives. If a browser view
during demos is ever wanted, the right path is mediamtx WebRTC of the same
H.264 stream with the overlay rewritten to read WebRTC stats — new work, not a
toggle.

### Files added/changed tonight

```
/etc/sysctl.d/90-tcp-retries.conf          (user installed; copy in ~/netaudit/)
/etc/mavlink-router/main.conf              (user installed from ~/inbox/main.conf; +UdpEndpoint gcs Server :14550)
~/camstream/mediamtx, mediamtx.yml         RTSP server; runOnInit ffmpeg; moq/hls/webrtc/api off
~/camstream/camstream-rtsp.service         linked + enabled (boot default)
~/camstream/camstream.service, -h264       re-linked (systemctl disable on a linked unit DELETES the link — had to re-link)
~/camstream/mode.sh                        mjpeg|h264|rtsp|status
~/netaudit/netaudit.service, sampler.sh    persistent logging; LAPTOP=100.123.80.42
~/inbox/Params08Aug2026_CRSF.param         class FC config (from Canvas)
~/inbox/Screenshot 2026-11-01 14{56,59}*.png   MP corruption evidence
```

### Gotchas tonight

* `systemctl disable` on a `systemctl link`ed unit removes the link → unit
  "not-found". Re-`link` afterwards.
* Inbound connections via userspace-mode Tailscale show as **127.0.0.1** on the
  Pi (netstack), so `ss` cannot show the real client — use mediamtx's log.
* `tailscale ping` exits at the first direct pong; `--until-direct=false` for
  sustained samples. MagicDNS does not resolve via the hotspot's DNS.
* Tailscale control uses **port 80** (ts2021) first, 443 fallback.
* Carrier CGNAT (AT&T tethering) drops idle IPv4 TCP at ~60–75 s; 15 s TCP
  keepalives hold it; IPv6 (no NAT) survives ≥240 s. **Do not disable IPv6 on
  the Pi** — it is the healthier path on cellular. Students' IPv6 grief is
  half-configured networks elsewhere.
* The upgrade/restart of tailscaled kills a Claude session running over the
  tailnet — do it last, or from the LAN.

### Next actions

1. User: confirm MP video with the `do-rtcp=false buffer-mode=none` pipeline after an MP restart.
2. Rehearse the bug fix: Pi on hotspot, phone Wi-Fi ON at a known time; expect
   control recovery ≈100 s (was 16 min). `netaudit` records it.
3. Recover Thursday's syslog with the sudo one-liner; I analyse.
4. Optional: full FC param diff vs the class file; Canvas baud note 460→500.
5. Tutorial docx does not yet mention UDPCl telemetry, RTSP video, or the baud
   finding — update when the MP pipeline is confirmed.

---

## Session — 2026-11-01 late — tailnet stability audit + two-network demo path

Started as "Mission Planner is unstable", became a network audit. Two distinct
problems were found and both are explained with evidence below. Also built the
H.264 push path for the planned in-class demo (drone in cage, laptop in lecture
hall, no shared network).

### State when stopped

| item | state |
|---|---|
| Pi network | phone hotspot `Burkephone` (2.4 GHz, 10.204.231.25), phone Wi-Fi OFF → upstream is **cellular** (AT&T, public 70.243.190.71) |
| Tailscale | healthy since 20:50; control connection over IPv6; direct (no relay) to the laptop |
| Camera | **`camstream-h264` mode active**: ffmpeg H.264 RTP push → laptop `100.109.85.83:5600`, ~0.7 Mbit/s, 63% of one core. MJPEG page is OFF (modes are exclusive) |
| Mission Planner | NOT yet tested with either the H.264 video or UDP telemetry |
| Telemetry | still TCP :5678 only; UDP endpoint lines handed to the user, not yet added to `/etc/mavlink-router/main.conf` (needs their sudo) |
| sysctl fix | recommended, NOT applied (needs sudo): `net.ipv4.tcp_retries2 = 8` |

Laptop: `win11surfacepro` / `DESKTOP-352M4P7`, Tailscale `100.109.85.83`, home LAN `192.168.1.193`.
Phone: Galaxy S24 Ultra, Tailscale `100.96.100.123`.

### Problem 1 — "Orange Pi disconnected from tailnet" (the one the user has "often")

**Cause: when the phone's upstream changes, TCP flows through the phone's NAT
die silently, and tailscaled kept using its dead control connection until Linux
TCP gave up — 16 minutes.** The Pi's hotspot IP does not change, so nothing
looked wrong locally.

```
20:34:11  LinkChange: major, rebinding        (phone Wi-Fi turned off → cellular)
20:34:14  magicsock DERP re-homed             (UDP data plane rebound fine)
20:35:24  control: map response long-poll timed out!   … every 2 min, 15 times
20:43:36  health: Unable to connect to the coordination server
20:50:07  read tcp 10.204.231.25:37318->192.200.0.107:80: error   (TCP gave up)
20:50:08  controlhttp: forcing port 443 dial  → re-dialed over IPv6
20:50:09  health: ok                           (stable since)
```

`tcp_retries2 = 15` (default) ≈ 13–30 min to error a black-holed connection; the
16 min matches. Data plane (WireGuard/UDP) kept working throughout — which is
why SSH over the tailnet survived while the admin console showed "disconnected".
Peer reachability degrades over time in that state → Mission Planner drops.

Is it a Tailscale bug? A robustness gap: it detected a *major* link change and
rebound UDP but did not re-dial control. tailscale 1.102.4. Not checked upstream
(no web access from the Pi). Worth reporting with the log above.

**Fixes, ranked:**
1. `/etc/sysctl.d/90-tcp-retries.conf`: `net.ipv4.tcp_retries2 = 8` (dead
   connections error in ~100 s) then `sudo sysctl --system`. Helps tailscaled,
   mavlink-router clients, SSH. **Not applied — needs sudo.**
2. Do not flip the phone's upstream while the drone is connected: Wi-Fi sharing
   off (or phone Wi-Fi off) *before* the drone joins. Or a travel router.
3. Manual recovery: `sudo systemctl restart tailscaled` (seconds instead of 16
   min). I have NOPASSWD for systemctl but did not run it — it drops the tailnet
   briefly.

### Problem 2 — Mission Planner drops while the phone shared home Wi-Fi

Different mechanism, earlier in the evening: the phone's single Wi-Fi radio was
client of the home router AND access point for the Pi. Measured Pi→laptop
through it: median 15 ms, **p90 78, max 119**, zero loss. TCP MAVLink stalls on
that jitter; MP sessions lasted 3m48s and 37s. Went away when the hotspot moved
to cellular (median 39, p90 88, max 133 but no radio time-slicing bursts).

### What was ruled out (all measured)

Wi-Fi link (no disconnects, stable DHCP), DNS (15/15, 7 ms), path MTU (~1428
both families, PMTUD works), large transfers (1 MB fine on v4 and v6), cellular
latency (p90 48 ms), video push contention (median 48 vs 42 ms on/off), FC
serial (no errors), mavlink-router (clean). Carrier NAT drops idle IPv4 TCP at
~60–75 s, but 15 s TCP keepalives hold it (tested) and IPv6 has no NAT (240 s
idle survived).

### IPv6 — user asked whether to disable it everywhere

**Advised against on the Pi.** On this hotspot IPv6 is the healthier path (no
CGNAT; the stable control connection is IPv6). Students' IPv6 trouble is almost
certainly half-configured networks elsewhere; disable it *there* if needed.

### Two-network demo architecture (built, partly tested)

| | before | demo |
|---|---|---|
| addressing | LAN IP | Tailscale (relay 19 ms to LA if ever needed) |
| telemetry | MP pulls TCP :5678 | **mavlink-router pushes UDP → laptop :14550** (not yet configured) |
| video | MJPEG pull, 15 Mbit/s | **ffmpeg H.264 RTP push → laptop :5600, ~0.7 Mbit/s** (running) |

Encode cost measured: 640x480@30 600 kbit/s = 56–63% of one core; @15 fps
400 kbit/s = 30%. The RTP format was validated on the Pi against Mission
Planner's **default** pipeline (`udpsrc port=5600 ! application/x-rtp !
rtph264depay ! avdec_h264 …`): 90 frames decoded. Cellular data: ~330 MB/h.

Files in `~/camstream/`: `camstream-h264.service` (linked), `h264.env`
(DEST_IP/PORT/RES/FPS/BITRATE), `mode.sh mjpeg|h264|status`. The two camera
services carry mutual `Conflicts=`; only one can hold the camera.

Telemetry lines for the user to add (then `sudo systemctl restart mavlink-router`,
MP → UDP 14550):
```
[UdpEndpoint laptop]
Mode = Normal
Address = 100.109.85.83
Port = 14550
```
MP video: Flight Data → right-click HUD → Video → Set GStreamer Source →
`udpsrc port=5600 buffer-size=60000 ! application/x-rtp ! rtph264depay ! avdec_h264 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=outsink sync=false`.
Windows Firewall must allow MP inbound UDP (5600, 14550).

### Phone setting (done by user: Wi-Fi off; the lasting version)

Galaxy S24 Ultra: Settings → Connections → Mobile Hotspot and Tethering →
Mobile Hotspot → Configure → **Wi-Fi sharing off**. Verified from the Pi: public
IP left `googlefiber.net`, home LAN unreachable, path to laptop direct.

### Small things learned

* `gstreamer1.0-libav` was installed for local validation (avdec_h264).
* `tailscale ping` stops at the first direct pong; use `--until-direct=false`
  for a sustained sample. MagicDNS names do not resolve through the hotspot's
  DNS; ping by 100.x IP.
* The journal is persistent (`/var/log/journal`) but only 2 boots deep here.
* Tailscale control uses **port 80** (ts2021) first, 443 as fallback — filter on
  both when looking for the socket.

---

## Session — 2026-11-01 — USB camera streaming: DONE, tutorial delivered

Student tutorial for streaming the drone's USB camera to Windows/Linux laptops
and into Mission Planner. Flight controller unpowered throughout.

### Where it stopped (late 2026-11-01)

User asked for the Tailscale stream URL (`http://100.92.72.14:8080/`, raw
`/stream`) — **still untested from a laptop**, which is the only place it can be
tested. Then asked whether `land_now.py` was ready: the script is unchanged
since it worked on 19 Oct, mavlink-router is active, but **no heartbeat on
:5678** — the flight controller was still unpowered. Next action when the FC is
on: confirm a heartbeat, then
`~/ardupilot_land/venv/bin/python ~/autoland/land_now.py`.

### Final state

| item | state |
|---|---|
| Camera | Arducam B0630 "1080P Low Light", USB-C **data** port. Works. |
| Service | `camstream.service` active + enabled, survives reboot (1 start, 0 retries). ustreamer MJPEG passthrough, **640x480@30, `--tcp-nodelay`, `--static` overlay page**, port 8080 |
| `http://<pi>:8080/` | overlay page: live video + browser-measured resolution / received fps / bitrate / latency |
| `http://<pi>:8080/stream` | raw MJPEG, for Mission Planner and scripts |
| Lag | **Fixed.** User: "fps is a solid 30 unflinching." Cause was bandwidth, see below |
| Tutorial | `~/inbox/HelloWorldOrangePiUSBcamFall2026.{docx,pdf}` — 15 pages, copies in `~/camstream/` |
| Overlay page | `~/camstream/www/index.html`, copy at `~/inbox/camera_overlay_index.html` |
| NOT verified from a laptop | Tailscale URL `100.92.72.14:8080/stream`; Mission Planner (either route) |

Addresses: LAN `192.168.1.146`, Tailscale `100.92.72.14`, MagicDNS `orangepi`.
The Pi cannot dial its own Tailscale IP (userspace mode), so only a laptop can
test that URL.

### Files in `~/camstream/`

```
camstream.service        linked into /etc/systemd/system (systemctl link)
www/index.html           overlay page served by --static
build_tutorial.py        python-docx: opens the course template, empties it, writes the tutorial in its styles
logo_clean.png           UCI seal from the template
camera_photo.png         Arducam render, datasheet cover, composited onto white (pdfimages colour + mask)
board_topview.png        Orange Pi annotated top view, cropped from the vendor manual p.12
frame_clean.png          real test frame from this camera
HelloWorldOrangePiUSBcamFall2026.docx / .pdf
```

Rebuild + PDF:
```bash
python3 ~/camstream/build_tutorial.py ~/inbox/HelloWorldOrangePiUSBcamFall2026.docx
cd /tmp && cp ~/inbox/HelloWorldOrangePiUSBcamFall2026.docx . && soffice --headless --convert-to pdf HelloWorldOrangePiUSBcamFall2026.docx
```
LibreOffice (`libreoffice-writer`, `fonts-roboto`, `fonts-liberation`) was
installed for this; Roboto Mono embeds, Arial maps to Liberation Sans.

### Tutorial structure (user's decisions baked in)

Page 1 front matter in the template's format (Purpose / Safety / Code — **no
Grading, no Canvas submission: "there is no assignment"**). Page 2 hardware
pictures only; **directions start on page 3**. Then Prerequisites → Phase I
verify camera → Phase II browser (Windows/Linux, Tailscale, ffplay/VLC optional)
→ **Phase III start at boot (service + overlay page)** → **Phase IV Mission
Planner** (user swapped III/IV) → Adjusting video quality → Troubleshooting →
Appendix on its own page.

Pagination rules in the generator, after the user asked for "no hanging chads":
headings keep-with-next; code blocks kept whole and glued to the prose that
explains them (a code line = every run mono, so inline code in prose does not
count); tables unsplittable and glued to their intro; bullet lists whole; widow
control. Forced page-break-per-Phase was tried and **rejected** — it produced a
six-line page. Audit after each build: no page ends on a heading or a colon.

### The lag, and the bandwidth numbers

The camera's internal JPEG quality is high and **cannot be changed** (no UVC
control; ustreamer `--quality` does not re-encode MJPEG). Measured, lit scene:

| resolution | bitrate | KB/frame |
|---|---|---|
| 1920x1080 | 44.9 Mbit/s | 186 |
| 1280x720 | 35.9 Mbit/s | 149 |
| 800x600 | 16.7 Mbit/s | 69 |
| 640x480 | 15.3 Mbit/s | 63 |
| 640x480 @15 | 12.1 Mbit/s | — |

720p was the original default and lagged badly on LAN; Wi-Fi path is Pi → AP →
laptop so airtime is double. 640x480 + `--tcp-nodelay` + a network restart
(gateway ping went 15/49 ms avg/max → 2/3.8 ms) fixed it. Pi-side cost is
~2.4% of one core at any resolution. **Next lever if ever needed:** capture
`--format=YUYV` and let ustreamer `--encoder=CPU --quality=50` make smaller
JPEGs. Untried. H.264/RTSP via ffmpeg+mediamtx was attempted (404 from
`rtspsrc` twice) and abandoned.

### Overlay page — how it works

Fetches `/stream`, splits on each part's `Content-Length`, displays each JPEG via
an object URL, counts frames/bytes per second. Latency = laptop clock − the
Pi's `X-Timestamp` per frame (meaningful only with NTP on both ends; in the cage
with no internet it shows clock skew — the page says so). Parsing validated by
running the same algorithm in Python against 3 s of live stream: 89/89 frames at
33.3 ms spacing. The camera appends 0–7 bytes of padding after each JPEG's EOI
marker — harmless, but a strict "ends with FFD9" check fails on most frames.

### Gotchas (all in the tutorial's Troubleshooting)

* `lsusb` names this camera **"Microdia MaxTrack Wireless Mouse"** (0c45:0520).
  Sonix UVC bridge; usb.ids is wrong. It is the camera.
* `kill -9` on a process streaming from the camera **wedges the UVC device**
  (`select() error: Inappropriate ioctl`, gray 640x480 "no signal"). Only a
  physical replug fixes it; `USBDEVFS_RESET` needs root on `/dev/bus/usb`.
* `After=dev-video0.device` in a unit **hangs `systemctl start` forever** here:
  udev tags the node `uaccess:seat`, not `systemd`, so the device unit is
  `inactive dead`. `Restart=always` handles the boot race instead.
* ustreamer `/` is a text index unless `--static` is given; video is `/stream`.
* `pkill -f <word>` from a script containing that word kills the script (exit
  144). Use `pkill -x`.
* A raw UVC JPEG has no JFIF marker; python-docx `add_picture` rejects it
  (`UnrecognizedImageError`). Convert to PNG.
* The reboot wiped `/tmp`, taking the Claude scratchpad with it. Anything worth
  keeping goes in `~/camstream/`.

### Mission Planner (untested on a laptop)

A) `Video → Set MJPEG source` → `http://<pi>:8080/stream`.
B) `Video → Set GStreamer Source` →
`souphttpsrc location=http://<pi>:8080/stream ! multipartdemux ! jpegdec !
videoconvert ! video/x-raw,format=BGRA ! appsink name=outsink sync=false`.
B was run on the Pi against the live stream with `fakesink`: 30 frames, exit 0.

### Root on this board

`sudo -n` only for `apt-get systemctl udevadm usermod reboot` + the two install
scripts. Hence `systemctl link` from `~/camstream/`, and the human replug.

---

## Session end — 2026-10-28 — docs only

### GND moved to pin 9 in the README wiring diagram

User's request: *"i want the ground to be pin 9 not 14 since it is easier."*
Correct, and for a specific reason — pins **9, 11, 13** are three consecutive
positions down the *same* odd column, so all three jumpers sit side by side
with nothing to count across the header. Pin 14 is in the even column opposite
pin 13, which is the arrangement that caused the original pin-finding
confusion back in September.

```
   │  9  ● ● 10   GND ────────────┼────────► GND
   │ 11  ● ● 12   UART2-TX ───────┼────────► RX
   │ 13  ● ● 14   UART2-RX ◄──────┼───────── TX
```

Electrically identical — both are header grounds. Nothing in `test_serial.sh`
or the troubleshooting tables needed changing; they only ever say "shared GND"
without naming a pin. The wiring table in this file was corrected to match, and
pin 14 moved into the alternative-grounds list (6, 14, 20, 25, 30, 34, 39).

Commit `278a37c`.

### Still no pinout image

Asked and answered this session: there is **no** `.png`/`.svg`/`.jpg` anywhere
in either repo or the home directory. The only wiring graphic is the ASCII
diagram in `README.md`.

Its weakness is unchanged: it shows the logical numbering but not how to find
pin 1 on the physical board, which is the part that actually cost time. The
board-orientation reasoning and the probe-pin-12-for-3.3 V trick live further
down in this file but never made it into the README. An offer to draw a proper
image was made and not taken up — still open if wanted.

---

## Session end — 2026-10-19 — student autoland scripts (no flying)

No flights this session, but the FC was powered and connected, and
`dronefly.py` was run against it repeatedly on the bench. Props never spun and
the airframe was not moved; the barometer fix from 26 Sept still stands.

Two findings here are more important than the script work: the current sensor
is uncalibrated, and the battery failsafe on the aircraft is switched off. Both
are below.

### The script to use: `~/autoland/dronefly.py`

This is the student assignment ("Phase III: LLM decides whether to land").
Reviewed and rewritten this session. Ignore the `.bak` and the scratchpad
copies; `dronefly.py` is the live one.

**Design decision that drove everything else: there is deliberately no voltage
threshold anywhere in the script.** Earlier in the session it had `V_LAND` and
`V_OK` constants, and the prompt quoted them to the model. Those are gone.
The reasoning, in the user's words: *"the whole point of the exercise is to
have the LLM make a decision that is not entirely predictable and uses its own
discretion. if there is a hard rule like a cutoff voltage explicit, there is no
point to use the llm, it could just be one line of code."*

Do not reintroduce a threshold into the prompt. If a future session wants a
deterministic floor, it belongs in the flight controller's own failsafe
parameters, not in the prompt text.

The prompt is now two messages, facts only:

```
system: You are a drone safety pilot. Use your own judgement about battery
        chemistry and risk. Reply with one word: LAND or HOLD.

user:   The drone is hovering in a test cage, a few metres up. Its 2S LiPo
        reads 7.60 V under hover load, which is 3.80 V per cell. This LiPo is
        reused across many flights and must not be deep-discharged. Should it
        land now, or keep hovering?
```

The percentage is NOT in the prompt — the current sensor is uncalibrated, see
below. The closing sentence states the objective with no number in it; see the
measured boundary table further down for what it is worth.

Consequence: the boundary is the model's, not ours. It has since been measured
rather than guessed — 50% at ~3.76 V/cell with the current wording. See the
boundary section below.

### RESOLVED — dronefly.py now runs end to end on the live aircraft

Four bugs, all found and fixed by actually running it. Verified output:

```
Heartbeat OK
Battery 7.61 V (3.81 V/cell)  armed=False  mode=STABILIZE
DECISION:  HOLD     (model said 'HOLD')
Holding. Nothing sent.
```

**1. Environment.** The venv with both `pymavlink` 2.4.50 and `portkey_ai` is
`~/ardupilot_land/venv` — not `~/portkey-env`, which has only portkey_ai. An
earlier note in this section claimed pymavlink was absent board-wide; that was
wrong. Run with `~/ardupilot_land/venv/bin/python`.

**2. `SYS_STATUS` was never arriving.** Symptom: `No SYS_STATUS within 10s`
while `land_now.py` worked fine. Cause: HEARTBEAT streams unprompted, but
`SYS_STATUS` has a stream rate of 0 on this link until something asks. The
script now sends `SET_MESSAGE_INTERVAL` (511) **and** legacy
`REQUEST_DATA_STREAM` (66) before reading, with one retry. Measured: arrives in
0.5 s, 6/6 follow-up frames. The old error message blamed boot timing, which
was a red herring — waiting longer would never have helped.

**3. `max_tokens` is rejected by this model.** `azure-openai error: Unsupported
parameter: 'max_tokens' is not supported with this model. Use
'max_completion_tokens' instead.` Renaming alone is **not** enough: the budget
covers internal reasoning, which runs before any visible text. Measured on
`@zotgpt-api-azure/gpt-5.5`:

| budget | 4.14 V/cell | 3.85 | 3.70 | 3.60 | 3.50 |
|---|---|---|---|---|---|
| 5 | `''` finish_reason=`length` — no answer at all | | | | |
| 512 | HOLD / 74 tok | HOLD / 55 | HOLD / 159 | **LAND / 228** | LAND / 66 |

Note the spike at the boundary: 228 tokens at 3.60 V/cell against 55 at 3.85.
The ambiguous cases cost the most, which is why 256 was too tight (89%
consumed) and why 512 later proved too tight as well. Final value is **1024** —
see the token-budget section below.

**4. An empty reply used to parse as HOLD.** `decision = "LAND" if
re.search(...) else "HOLD"` turned a failed call into "keep flying" on a
decision that was never made. Now an empty `content` raises, `HOLD` wins ties,
and `"Do not land"` can no longer be read as a landing command.

### Where the decision boundary sits — measured, 5 calls per voltage

The prompt ends with one sentence stating the OBJECTIVE and no number:
*"This LiPo is reused across many flights and must not be deep-discharged."*
That sentence is load-bearing. Without it the model applies the cell-damage
floor (~3.0–3.3 V under load) and keeps flying well past the point a pilot
would land — it answered HOLD at 3.71 V/cell, which is about 10% on a resting
LiPo chart. With it:

| V/cell | pack | decisions | LAND rate |
|---|---|---|---|
| 4.00 | 8.00 V | `hhhhh` | 0% |
| 3.85 | 7.70 V | `hhhhh` | 0% |
| 3.80 | 7.60 V | `hhhhh` | 0% |
| **3.78** | 7.56 V | `LLhhh` | **40%** |
| **3.76** | 7.52 V | `hLLLh` | **60%** |
| **3.74** | 7.48 V | `hhLLL` | **60%** |
| 3.71 | 7.42 V | `LLLLL` | 100% |
| 3.68 | 7.36 V | `LLLLL` | 100% |
| 3.60 | 7.20 V | `LLLLL` | 100% |

Always HOLD at ≥3.80, genuinely undecided across **3.78–3.74**, always LAND at
≤3.71. 50% point ≈ **3.76 V/cell (7.52 V)**.

Measured boundary by prompt wording, same model, same day:

| added sentence | 50% LAND point |
|---|---|
| none (facts only) | ~3.65 V/cell |
| **"reused across many flights... must not be deep-discharged"** (in use) | **~3.76** |
| "a cut-short flight costs nothing; a damaged pack costs a lot" | ~3.82 (too eager) |

Why this matters pedagogically: the in-flight median on this airframe is
3.80 V/cell, right at the top edge of the transition. So one ordinary battery
walks a flight through solid HOLD → the stochastic band, where two teams at the
same voltage get different answers → solid LAND. With the bare prompt the band
sat at 3.66–3.62, which only 12% of logged in-flight samples ever reach, and
teams would have seen HOLD every time.

**Do not replace that sentence with a voltage.** Stating the objective keeps the
decision the model's and keeps it stochastic; stating a number makes it a
comparison, which is the thing the exercise exists to avoid.

Caveat: one model (`@zotgpt-api-azure/gpt-5.5`), one day. A model update will
move these numbers. Re-run the sweep before the class if it matters.

### Token budget: 1024, and not negotiable downward

`TOKEN_BUDGET = 1024`. `max_completion_tokens` covers invisible reasoning,
which runs before any visible text, and an exhausted budget returns
`content=""` with `finish_reason="length"` — no answer at all.

Measured for a ONE-WORD reply: 55–74 tokens at the confident ends, 201–221 near
the boundary with the bare prompt, and **109–523 once the prompt gives the model
something to weigh**. At 512, two of six calls returned empty. At 1024, zero
truncations in 55 calls. The ceiling is not billed, only tokens produced, so
there is no saving in trimming it.

### VOLTAGE ONLY — the current sensor is not calibrated

User instruction, emphatic: *"my current is not calibrated. do not use the
current, only the battery voltage!!"*

Measured at rest, props stopped: **−0.35 A**, giving `current_consumed` =
**−93 mAh**, so the coulomb integrator runs *backwards* and
`battery_remaining` climbs **above 100%** — observed 101 → 103% over a few
minutes at 3.82 V/cell. An older flight log shows the mirror of the same fault:
89% reported at 3.82 V/cell.

```
BATT_MONITOR 4   BATT_CAPACITY 3300   BATT_AMP_OFFSET 0.01328   BATT_AMP_PERVLT 43.65
```

Cause is either an offset error (zeroing needs ≈0.0053) or reversed shunt
polarity — **undetermined**. Distinguish by throttling up strapped down: more
negative means the shunt is backwards, swinging positive means it is just the
offset.

`dronefly.py` no longer reads, prints or logs the percentage at all. Do not add
it back.

### SAFETY GAP — battery failsafe is disabled on the aircraft

Read from the FC (this time with pymavlink, successfully — the earlier "unread"
note was my wrong `CRC_EXTRA` guess, not a vehicle problem):

```
BATT_LOW_VOLT    6.1     (3.05 V/cell)
BATT_CRT_VOLT    6.0     (3.00 V/cell)
BATT_FS_LOW_ACT  0       <-- no action
BATT_FS_CRT_ACT  0       <-- no action
BATT_LOW_TIMER   10
```

Both actions **disabled**, thresholds below anything worth reaching. Combined
with the deliberate absence of a threshold in `dronefly.py`, **nothing on this
aircraft will bring it down on a flat pack.** The single LLM check is the only
thing in the loop, and it is asked once, not continuously.

Suggested, in Mission Planner, user's call — voltage failsafe is unaffected by
the current-sensor fault, so it works today:
`BATT_LOW_VOLT 7.0` + `BATT_FS_LOW_ACT 2` (RTL), `BATT_CRT_VOLT 6.8` +
`BATT_FS_CRT_ACT 1` (Land). **Close this before any student flies it.**

### Terminal output

The script prints the exact prompt and the raw response, in colour: cyan prompt
block, yellow role labels, blue response block, green/red `finish_reason`, and
a green HOLD / red LAND decision badge. The prompt is built into `system_msg` /
`user_msg` and printed from those variables, so screen text cannot drift from
what was sent. Colour switches off when stdout is not a tty — verified zero
escape sequences when redirected to a file.

### Also in `~/autoland/`

`land_now.py` — forces LAND mode over `tcp:127.0.0.1:5678`, using
`MAV_CMD_DO_SET_MODE` (176) inside `COMMAND_LONG` (76) with param1 = 1
(`MAV_MODE_FLAG_CUSTOM_MODE_ENABLED`) and param2 = the mode id from
`mode_mapping()`. Confirms via HEARTBEAT, falls back to `SET_MODE` (11). It
sets LAND even when disarmed, which was requested explicitly. Derived from
`land_ardupilot_landmode.py`, which is untouched and still points at the
non-existent `/dev/serial0`.

Port 5678 accepts multiple simultaneous clients, so these scripts and Mission
Planner can be connected at the same time. mavlink-router handles the fan-out.

### Both branches now proven on the live aircraft

The LAND path was exercised for real at the end of the session: the bench pack
had drifted to **3.61 V/cell**, the model answered LAND unprompted, and the
command went through.

```
DECISION:  LAND    (model said 'LAND')
LAND command acknowledged: result=0 (0 = accepted)
... llm=LAND mode_before=STABILIZE mode_after=LAND
```

HOLD was proven repeatedly earlier at 3.80–3.85 V/cell. So connect → read
voltage → prompt → decide → command → log is verified end to end, both ways,
on the real FC. Props never spun; the aircraft was disarmed throughout.

Still unverified: whether the `.BIN` statustext stamp lands on the same
timeline as the mode change. That needs a log pull after a LAND run.

**And the stamp may be days wrong, which is new (2026-10-26).** This board has
no RTC — `timedatectl` says `RTC time: n/a`, there is no `/dev/rtc`, and time is
carried over reboots by `fake-hwclock`. On the boot observed on 26 Oct, chrony
found the clock **577,828 s wrong (6.7 days)** and stepped it only after the
network came up:

```
Oct 19 23:16:34 chronyd: System clock wrong by 577828.702179 seconds
Oct 26 15:47:03 chronyd: System clock was stepped by 577828.702179 seconds
```

`dronefly.py` stamps `datetime.now()` into the FC log via `statustext_send`, and
into its own log line, precisely so the LLM decision can be lined up against the
mode change afterwards. **In the drone cage there is no internet**, so NTP never
runs, and that stamp can carry the date of whenever the Pi last had a network —
days off. The relative ordering within one run is fine; the absolute date is not
trustworthy.

Fix, when someone wants it: take time from the flight controller instead of the
Pi. The FC has GPS and sends `SYSTEM_TIME` (msgid 2, `time_unix_usec`), which is
correct whenever there is a 3D fix — and GPS was at 29 satellites. Reading that
and stamping it, or at least logging both and the offset between them, removes
the dependency on the Pi's clock entirely. Not done.

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
claude --continue --model fable   # resume the most recent conversation, on Fable
# or: claude --resume --model fable   to pick from a list
```

If that fails, this file plus `BUILD_JOURNAL.md` contain everything needed.

> **Why `--model fable` is on the command.** `--continue` picks the model from
> the **last assistant turn in the transcript**, not from your default in
> `~/.claude/settings.json`. The September session had only ever run on Opus,
> and each `/model fable` was followed by an immediate `/exit` with no turn in
> between — so the transcript still ended on Opus and every resume brought Opus
> back. Three times (2026-11-01). The explicit flag makes the resumed model
> independent of transcript history. A brand-new `claude` with no flags was on
> Fable all along, so the default itself is fine.
>
> Already ruled out, so nobody re-checks: no project or local
> `.claude/settings.json` setting a model, no managed settings in
> `/etc/claude-code/`, no `ANTHROPIC_MODEL` in the environment, no per-session
> model stored in `~/.claude.json`, and `claude` is a plain symlink to the
> binary with no wrapper.

### Status line shows context usage (added 2026-11-01)

`~/.claude/statusline.sh`, wired up via `statusLine` in `~/.claude/settings.json`.
Prints model, a 10-cell bar, percent and tokens — green under 50%, yellow to
79%, red above:

```
Opus 5 (1M context)  [..........] 9.6%   95k/1.0M
Sonnet 5             [########..] 86.0%  172k/200k
```

Field names came from the documented schema inside the installed binary
(v2.1.316), not guesswork: `.context_window.total_input_tokens`,
`.context_window_size`, `.used_percentage`.

**The trap:** `used_percentage` is `null` until the session's first API
response, so a naive script prints nothing or `null%` on the first prompt every
time. The script computes the percentage itself in that case.

A new `statusLine` key needs a Claude Code restart to take effect — the
settings watcher only watches directories that already had a settings file when
the session started. `/context` is the built-in alternative and gives a fuller
breakdown; the status line's advantage is being always visible.

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
| **9** | 5th down the **odd** (left) row | — | **GND** |
| **11** | 6th down the odd row | → | **RX** |
| **13** | 7th down the odd row | ← | **TX** |

(GND moved from pin 14 to pin 9 on 2026-10-28 — see the note at the top of
this file. Pin 14 still works; it is just in the other column.)

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
