# Mini2 / WN2 Thermal Camera Driver for Raspberry Pi 5

Linux kernel driver for the Mini2 (aka WN2) thermal camera module on Raspberry Pi 5. Outputs YUYV422 video over CSI-2 for live viewing with standard V4L2 tools.

## Hardware Requirements

- Raspberry Pi 5 (4GB+ recommended)
- Mini2 / WN2 thermal camera module (384x288, 256x192, or 640x512)
- 22-to-15 pin CSI ribbon cable
- 5V/3A+ power supply

## Install from packages

Two Debian packages install everything, including `rpicam-apps` support:

```bash
sudo apt install ./rs300-dkms_*_all.deb ./libcamera-rs300_*_arm64.deb
sudo reboot
rpicam-hello --list-cameras
```

- **`rs300-dkms`**: the DKMS kernel module, the device tree overlay (the
  package adds `dtoverlay=rs300` to `/boot/firmware/config.txt`),
  `rs300-stream`, the udev rule and `rs300-media-setup.service`. The module
  settings are in `/etc/modprobe.d/rs300.conf`; the default is `mode=2 fps=60`
  (384x288). Edit that file for a 640x512 or 256x192 module and reboot.
- **`libcamera-rs300`**: libcamera with rs300 support, in `/opt/libcamera-rs300`.
  See [libcamera and rpicam-apps](#libcamera-and-rpicam-apps).

`libcamera-rs300` depends on the exact system `libcamera0.5` version it was
built for (0.5.2+rpt20250903-1~bpo12+1). If an upgrade brings a newer
libcamera, apt holds it back or offers to remove `libcamera-rs300`; build a
new package for the new version (below).

To remove: `sudo apt remove rs300-dkms libcamera-rs300` and reboot. This also
removes the `dtoverlay=rs300` line. If you installed with `install.sh` before,
first follow [Uninstall](#uninstall).

To build the packages, run on a Raspberry Pi 5 (Raspberry Pi OS bookworm,
arm64). The libcamera build takes about 2 minutes:

```bash
packaging/build-debs.sh          # writes packaging/dist/*.deb
```

## Install from source

```bash
git clone https://github.com/Kodrea/mini2-thermal-driver.git
cd mini2-thermal-driver/platforms/raspberry-pi/rpi5
sudo ./install.sh
sudo reboot
```

The installer will ask which module you have and your preferred frame rate.
384x288 and 640x512 modules support 30 or 60 fps; 256x192 modules support 25 or
50 fps. Pick the higher rate unless you are short on bandwidth or CPU.

Run this at an interactive terminal. It prompts for input, so driving it through
a non-interactive SSH command exits at the first prompt without an error. For
that case use the scripted form below.

### Scripted Install

For CI or headless setups, `--auto` skips dependency prompts and accepts resolution/fps as arguments:

```bash
sudo ./install.sh --auto 384 30 y   # 384x288 @ 30fps, auto-confirm
sudo ./install.sh --auto 640 60 y   # 640x512 @ 60fps
sudo ./install.sh --auto 256 25 y   # 256x192 @ 25fps
```

### What Gets Installed

- **DKMS kernel module** (`rs300.ko`) rebuilt automatically on kernel updates
- **Device tree overlay** (`rs300.dtbo`) and `config.txt` entry
- **`rs300-stream`** live viewer (GTK + GStreamer) in `/usr/local/bin`
- **Module config** for resolution and FPS stored in `/etc/modprobe.d/rs300.conf`
- **`rs300-media-setup.service`** which enables the CSI-2 capture link on every boot

For `rpicam-apps`, Picamera2 and other libcamera applications, also install
the `libcamera-rs300` package. See [libcamera and rpicam-apps](#libcamera-and-rpicam-apps).

## After Reboot

Verify the module loaded and the camera enumerated:

```bash
dmesg | grep rs300              # module probe messages
systemctl status rs300-media-setup   # capture link enabled
v4l2-ctl --list-devices         # expect /dev/video0 under the rp1-cfe group
v4l2-ctl -d /dev/v4l-subdev2 --get-subdev-fmt pad=0   # sensor resolution
```

`dmesg` prints several `Fixed dependency cycle(s)` lines before the probe
messages. Those are normal and come from the device tree linking the sensor and
the CSI receiver to each other. The lines that indicate success are:

```
rs300 10-003c: Starting rs300_probe
rp1-cfe 1f00110000.csi: Using sensor rs300 10-003c for capture
rs300 10-003c: Propagated 384x288 code=0x2011 to downstream pad 0
```

`rs300-media-setup` is a oneshot service, so a healthy install reports
`active (exited)` rather than `active (running)`:

```
Active: active (exited) since ...
Process: 622 ExecStart=/usr/lib/rs300/rs300-media-setup.sh (code=exited, status=0/SUCCESS)
rs300-media-setup.sh[622]: rs300-media-setup: bypass capture link enabled on /dev/media2
```

The media device number changes between boots, so yours may not be `/dev/media2`.
The service detects the right one by looking for the sensor rather than assuming
a number.

The RP1 CFE creates the link that carries frames to the capture node in a
disabled state, so it has to be enabled after every boot.
`rs300-media-setup.service` does that. If capture fails with
`VIDIOC_STREAMON returned -1 (Invalid argument)` and `dmesg` shows
`csi2_ch0 node link is not enabled`, run it by hand:

```bash
sudo /usr/lib/rs300/rs300-media-setup.sh
```

The CSI-2 receiver can route either to the ISP front end or to the bypass
capture node, but not to both. The YUYV tools on this page use the bypass path.
libcamera uses the ISP path and sets up its own links each time it starts, so
the two do not need the service disabled. After a libcamera application, run
the service script once before you use the YUYV tools again (`rs300-stream`
does this itself):

```bash
/usr/lib/rs300/rs300-media-setup.sh
```

### Confirm frames without a display

`rs300-stream` needs a desktop session. On a headless Pi, capture straight from
the video node instead. Substitute your module's resolution:

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=384,height=288,pixelformat=YUYV \
  --stream-mmap --stream-count=600 --stream-to=/tmp/capture.yuv
ls -l /tmp/capture.yuv
```

Write the capture to RAM, not to the SD card. On Raspberry Pi OS `/tmp` is on
the SD card, and a slow card cannot write 13 MB/s at 60 fps. The capture then
reports about 40 to 55 fps although the sensor sends 60. If you see that, use
`/dev/shm/capture.yuv` in place of `/tmp/capture.yuv` in these examples.

A 384x288 YUYV frame is 221184 bytes, so 600 frames is exactly 132710400 bytes.
Any other size means frames were dropped.

`v4l2-ctl` prints a frame rate as it captures. The figure is measured over each
reporting interval, not over the run as a whole, and the stream takes about
1.2 seconds to deliver live frames. The first values therefore climb from near
zero while the stream starts, after which every value reads the configured
rate:

```
1.51 fps  8.64 fps  21.44 fps  29.14 fps  34.27 fps  60.00 fps  60.00 fps ...
```

Only the settled values mean anything. 600 frames is used here because it runs
well past the startup climb; a shorter capture can end while the figure is still
rising and look like a rate problem when there is none.

Some modules send the same frame again and again after the stream starts,
until they get an FFC while they stream. The driver sends one at each stream
start, and the stream-on call returns when it is done. Frames that arrived
before that are still delivered: the first 4 to 6 frames of a V4L2 capture can
be blank (an almost flat image) or a leftover frame from the previous stream.
Skip them, or skip frames whose timestamp is before the stream-on call
returned. libcamera applications are not affected.

A static scene changes very little from frame to frame. To prove that frames
are live, send another FFC while the capture runs:

```bash
( sleep 5; v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl ffc_trigger=1 ) &
v4l2-ctl -d /dev/video0 --set-fmt-video=width=384,height=288,pixelformat=YUYV \
  --stream-mmap --stream-count=600 --stream-to=/tmp/capture.yuv
```

To confirm the frames actually differ, hash each one and count the distinct
values. Substitute your module's resolution in the frame size:

```bash
python3 - <<'PY'
import hashlib
frame = 384 * 288 * 2
data = open('/tmp/capture.yuv', 'rb').read()
h = [hashlib.md5(data[i:i + frame]).hexdigest()
     for i in range(0, len(data), frame)]
print(len(h), 'frames,', len(set(h)), 'distinct')
PY
```

With a mid-capture FFC, expect most frames to be distinct. Around 424 distinct
out of 600 is typical on a static scene. A result of 1 distinct frame means the
same buffer is being delivered repeatedly.

Live thermal preview, on a Pi with a display:

```bash
rs300-stream
```

The viewer auto-detects the sensor resolution (256x192, 384x288, or 640x512) at startup and opens fullscreen. Controls work from the video window or the launching terminal.

### rs300-stream Controls

| Key | Action |
|-|-|
| `f` | Trigger FFC (flat-field correction) |
| `c` | Cycle colormap (0..11) |
| `m` | Cycle scene mode (0..5) |
| `a` | Toggle auto shutter |
<!-- Disabled. Toggling the sensor to Y16 desyncs it from the viewer, whose
     pipeline is fixed at YUYV. For Y16, use a libcamera application.
| `y` | Toggle output mode (YUV / Y16) |
-->
| `+` / `-` | Brightness +10 / -10 |
| `]` / `[` | Contrast +5 / -5 |
| `}` / `{` | Digital detail enhancement +5 / -5 |
| `q` / ESC | Quit |
| `Ctrl+C` | Quit (from launching terminal) |

## libcamera and rpicam-apps

The libcamera package in Raspberry Pi OS cannot use this camera: `rpicam-hello
--list-cameras` and `cam --list` show no cameras. To make `rpicam-apps`, `cam`,
Picamera2 and GStreamer `libcamerasrc` work, install the `libcamera-rs300`
package (see [Install from packages](#install-from-packages)), then:

```bash
rpicam-hello --list-cameras
```

Expected output:

```
0 : rs300 [384x288 MONO] (/base/axi/pcie@1000120000/rp1/i2c@88000/rs300@3c)
    Modes: 'R16' : 384x288 [60.00 fps - (0, 0)/384x288 crop]
```

The package holds the Raspberry Pi libcamera tree that matches the Raspberry
Pi OS package (0.5.2+rpt20250903), built with `helpers/libcamera-rs300.patch`
and installed to `/opt/libcamera-rs300`. Its file
`/etc/ld.so.conf.d/00-libcamera-rs300.conf` makes the dynamic linker find this
build before the system one, so every libcamera application loads it. The
system package is not changed. For a different system libcamera version, build
the package with a matching `LIBCAMERA_REF` and edit `LIBCAMERA_PKG_VERSION` in
`packaging/build-debs.sh`.

libcamera uses the module's raw 16-bit output (Y16) and the Pi 5 ISP. The
module's own image processing (colour palettes, detail enhancement, noise
reduction) applies only to its YUYV output, so libcamera gives a grey image.
The tuning file stretches each frame between the 1st and 95th percentile of its
histogram. The module sets its own exposure; libcamera's exposure and gain
settings have no effect.

- A stream takes about 1.2 seconds to deliver live frames (the module
  starts, then the driver sends an FFC). After a frame rate change or a switch
  from the YUYV tools it takes about 1.8 seconds, because the driver then also
  sends the frame rate command. Give short commands time, for example
  `rpicam-raw -t 3000`.
- For a single still, use `rpicam-still --immediate` (about 1.4 s in total)
  or `--zsl` (about 1.4 s, JPEG only). Without either option, rpicam-still
  stops the preview stream and starts the camera again for the still, so it
  pays the start-up time twice (about 2.5 s with `-t 1000`).
- `rpicam-raw` and the raw stream give the module's 16-bit values, least
  significant byte first.
- `rpicam-still -r` cannot write a DNG file: the rpicam-apps DNG writer
  stops with `unsupported Bayer format` for 16-bit mono.
- The module sets the frame rate: `fps` in `/etc/modprobe.d/rs300.conf`, then
  reboot. `rpicam-vid --framerate` does not change it; give the same value so
  that the file header matches.

### Recording video

Lossless H.264 in an MP4 file (software encoder; the Pi 5 has no hardware
H.264 encoder):

```bash
rpicam-vid -n -t 13000 --framerate 60 --width 384 --height 288 \
  --codec libav --libav-video-codec libx264 \
  --libav-video-codec-opts "qp=0;preset=ultrafast" \
  -o thermal.mp4
```

`-t` includes the start-up time, so `-t 13000` gives about 11.5 s of video.
Measured with the earlier, slower start-up (10 s of video): at 60 fps 581
frames 16.67 ms apart, about 8 MB; with the module at `fps=30` and
`--framerate 30`, 302 frames 33.3 ms apart, about 6.8 MB.

- `qp=0` is lossless. The file uses the H.264 High 4:4:4 Predictive profile,
  which VLC, ffmpeg and mpv play, but browsers and many hardware players do not.
- The MP4 holds the 8-bit image after the ISP. For the 16-bit module values,
  use `rpicam-raw`.
- `--save-pts` does not work with MP4 output.

The patch does these things:

- Adds a camera helper and a tuning file (`rs300.json`) for the rs300.
- Ignores sensor formats that are not raw, so a sensor that also offers YUYV
  can use the ISP.
- Does not byte-swap 16-bit frames from the rs300. The module sends the least
  significant byte first, which is already the order the ISP needs.
- Adds a `ce_keep_median` option to `rpi.contrast`. With `0`, the contrast
  stretch is linear between the two histogram points.

The driver changes that libcamera needs are in `src/rs300.c`: a frame
descriptor, so that the receiver accepts the module's Y16 lines; Y16 selected
through the format; writable blanking and gain controls; a pixel rate that
gives the real frame rate.

## Configuration

```bash
# View current config
cat /etc/modprobe.d/rs300.conf

# Change mode (0=640x512, 1=256x192, 2=384x288)
echo "options rs300 mode=2 fps=60" | sudo tee /etc/modprobe.d/rs300.conf
sudo reboot
```

## Troubleshooting

### Camera not detected

```bash
i2cdetect -y 10    # expect device at 0x3c
dtoverlay -l       # expect rs300 listed
grep rs300 /boot/firmware/config.txt
```

The camera gets power only while a sensor driver holds it, so `i2cdetect` shows
nothing when the rs300 driver did not probe. To scan with power on, set the
power enable line high (GPIO34 for cam0, GPIO46 for cam1), scan, and set it low
again:

```bash
sudo pinctrl set 34 op dh; sleep 1
i2cdetect -y 10    # expect device at 0x3c
sudo pinctrl set 34 op dl
```

Another sensor overlay on the same port stops the rs300 overlay from working.
If `dmesg` shows a different sensor (for example
`imx477 10-001a: failed to read chip id 477, with error -121`), comment out
that `dtoverlay=` line in `/boot/firmware/config.txt` and reboot.

The `dtoverlay=rs300` line must not be inside a conditional section such as
`[cm4]` or `[cm5]`, because then the board ignores it. The installer writes
`[all]` before the line to prevent this.

### Black or frozen image

Some modules freeze on the first frame until FFC is triggered while they stream. The driver sends an FFC at each stream start. To trigger one manually, send it while the stream runs. An FFC sent before the stream starts has no effect on this freeze:

```bash
v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl ffc_trigger=1
sleep 2
```

### Device numbers changed after reboot

Video device numbers can change between boots. List the current nodes and find the rs300 entry:

```bash
v4l2-ctl --list-devices
```

## Uninstall

For the packages: `sudo apt remove rs300-dkms libcamera-rs300`. For an
`install.sh` installation:

```bash
sudo dkms remove -m rs300 -v 0.0.1 --all
sudo rm -f /usr/local/bin/rs300-stream
sudo rm -f /boot/firmware/overlays/rs300.dtbo
sudo rm -f /etc/udev/rules.d/99-rs300.rules
sudo rm -f /etc/modprobe.d/rs300.conf
sudo systemctl disable --now rs300-media-setup.service
sudo rm -f /etc/systemd/system/rs300-media-setup.service
sudo rm -rf /usr/lib/rs300
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

Then remove the overlay line from the boot config and reboot:

```bash
sudo sed -i '/^dtoverlay=rs300$/d' /boot/firmware/config.txt
grep -c rs300 /boot/firmware/config.txt   # expect 0
sudo reboot
```

## Files

| File | Role |
|-|-|
| `install.sh` | Automated installer |
| `src/rs300.c` | Kernel driver source |
| `src/rs300-overlay.dts` | Device tree overlay |
| `Makefile` | DKMS build |
| `dkms.conf` | DKMS config |
| `helpers/rs300-stream.py` | Live viewer (GTK + GStreamer) |
| `helpers/rs300-media-setup.sh` | Enables the CSI-2 capture link |
| `helpers/rs300-media-setup.service` | Runs the capture link setup at boot |
| `packaging/build-debs.sh` | Builds the `rs300-dkms` and `libcamera-rs300` packages |
| `packaging/rs300-dkms/` | Install and remove scripts of `rs300-dkms` |
| `helpers/libcamera-rs300.patch` | libcamera changes for rs300 (helper, tuning, pipeline) |
