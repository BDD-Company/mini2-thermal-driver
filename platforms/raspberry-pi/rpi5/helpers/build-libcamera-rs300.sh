#!/bin/bash
# Build and install libcamera with rs300 support for rpicam-apps, cam and
# every other libcamera application.
#
# Builds the Raspberry Pi libcamera tree that matches the Raspberry Pi OS
# package, with libcamera-rs300.patch applied (camera helper, tuning file,
# raw-format filter, 16-bit byte order, linear contrast stretch). Installs to
# /usr/local. The dynamic linker searches /usr/local/lib/<arch> before
# /usr/lib/<arch>, so applications load this build in place of the system
# libcamera. The system package is not changed.
#
# Usage: ./build-libcamera-rs300.sh
# Env:   LIBCAMERA_REF (default bfd68f78 = Raspberry Pi OS 0.5.2+rpt20250903)
#        SRC (default ~/libcamera-rs300)
# Undo:  grep -v '^#' "$SRC/build/meson-logs/install-log.txt" | sudo xargs rm -f
#        sudo ldconfig
set -euo pipefail

REF=${LIBCAMERA_REF:-bfd68f78}
SRC=${SRC:-$HOME/libcamera-rs300}
PATCH=$(cd "$(dirname "$0")" && pwd)/libcamera-rs300.patch
PKG_VERSION=0.5.2+rpt20250903

have=$(dpkg-query -W -f='${Version}' libcamera0.5 2>/dev/null || true)
case "$have" in
	"$PKG_VERSION"*) ;;
	*) echo "WARNING: system libcamera0.5 is '$have', the patch was made for" \
		"$PKG_VERSION. rpicam-apps may not match this build." >&2 ;;
esac

sudo apt-get install -y meson ninja-build pkg-config g++ libyaml-dev \
	python3-yaml python3-ply python3-jinja2 libudev-dev libevent-dev \
	libdrm-dev libssl-dev libpisp-dev

[ -d "$SRC" ] || git clone https://github.com/raspberrypi/libcamera.git "$SRC"
cd "$SRC"
git checkout -q "$REF"
git apply --check "$PATCH" 2>/dev/null && git apply "$PATCH"
grep -q '"rs300"' src/ipa/rpi/cam_helper/cam_helper_rs300.cpp

[ -d build ] || meson setup build --prefix=/usr/local --buildtype=release \
	-Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp \
	-Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dv4l2=false \
	-Dpycamera=disabled -Dlc-compliance=disabled -Dtest=false \
	-Ddocumentation=disabled -Dtracing=disabled
ninja -C build
sudo ninja -C build install
sudo ldconfig
echo "Installed. Try: rpicam-hello --list-cameras"
