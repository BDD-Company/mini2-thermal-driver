#!/bin/bash
# Build libcamera with the "simple" pipeline handler for rs300 on rp1-cfe.
#
# The Raspberry Pi libcamera package has only the rpi/pisp handler, which needs
# a raw Bayer/mono sensor and rejects rs300 (YUYV). This builds the same
# Raspberry Pi libcamera tree with the simple handler only, installs it to
# PREFIX, and installs a "cam" wrapper in /usr/local/bin that uses it.
# The system libcamera and rpicam-apps are not changed.
#
# Usage: ./build-libcamera-rs300.sh
# Env:   LIBCAMERA_REF (default bfd68f78 = Raspberry Pi OS 0.5.2+rpt20250903)
#        PREFIX (default /opt/libcamera-rs300), SRC (default ~/libcamera-rs300)
# Undo:  sudo rm -rf "$PREFIX" /usr/local/bin/cam; rm -rf "$SRC"
set -euo pipefail

REF=${LIBCAMERA_REF:-bfd68f78}
PREFIX=${PREFIX:-/opt/libcamera-rs300}
SRC=${SRC:-$HOME/libcamera-rs300}
PATCH=$(cd "$(dirname "$0")" && pwd)/libcamera-simple-rp1-cfe.patch

sudo apt-get install -y meson ninja-build pkg-config g++ libyaml-dev \
	python3-yaml python3-ply python3-jinja2 libudev-dev libevent-dev \
	libdrm-dev libssl-dev

[ -d "$SRC" ] || git clone https://github.com/raspberrypi/libcamera.git "$SRC"
cd "$SRC"
git checkout -q "$REF"
git apply --check "$PATCH" 2>/dev/null && git apply "$PATCH"
grep -q '"rp1-cfe"' src/libcamera/pipeline/simple/simple.cpp

[ -d build ] || meson setup build --prefix="$PREFIX" --buildtype=release \
	-Dpipelines=simple -Dipas=[] -Dcam=enabled -Dqcam=disabled \
	-Dgstreamer=disabled -Dv4l2=false -Dpycamera=disabled \
	-Dlc-compliance=disabled -Dtest=false -Ddocumentation=disabled \
	-Dtracing=disabled
ninja -C build
sudo ninja -C build install

LIBDIR=$(dirname "$(find "$PREFIX" -name 'libcamera.so.0*' | head -1)")
sudo tee /usr/local/bin/cam >/dev/null <<EOF
#!/bin/sh
# rs300: libcamera with the simple pipeline handler (build-libcamera-rs300.sh).
# The system cam is /usr/bin/cam.
LD_LIBRARY_PATH=$LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} exec $PREFIX/bin/cam "\$@"
EOF
sudo chmod 755 /usr/local/bin/cam
echo "Installed. Try: cam --list"
