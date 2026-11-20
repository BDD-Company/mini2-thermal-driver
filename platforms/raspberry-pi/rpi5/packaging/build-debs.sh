#!/bin/bash
# Build the two Raspberry Pi 5 packages:
#
#   rs300-dkms_<ver>_all.deb          driver (DKMS), overlay, helpers, service
#   libcamera-rs300_<ver>_arm64.deb   libcamera with rs300 support, in /opt
#
# Run on a Raspberry Pi 5 with Raspberry Pi OS (bookworm, arm64): the libcamera
# package is compiled natively and must match the system libcamera0.5 package.
#
# Usage: packaging/build-debs.sh [driver|libcamera|all]   (default: all)
# Env:   OUT (default packaging/dist), DEB_REV (default: today, YYYYMMDD),
#        LIBCAMERA_REF (default bfd68f78), MAINTAINER
set -euo pipefail

WHAT=${1:-all}
HERE=$(cd "$(dirname "$0")" && pwd)
RPI5=$(dirname "$HERE")
OUT=${OUT:-$HERE/dist}
WORK=${WORK:-$HOME/.cache/rs300-debs}
DEB_REV=${DEB_REV:-$(date +%Y%m%d)}
MAINTAINER=${MAINTAINER:-mini2-thermal-driver <maintainer@invalid>}

# The libcamera tree and package that the patch was made for.
LIBCAMERA_REF=${LIBCAMERA_REF:-bfd68f78}
LIBCAMERA_PKG_VERSION=0.5.2+rpt20250903-1~bpo12+1
PREFIX=/opt/libcamera-rs300

DKMS_VERSION=$(sed -n 's/^PACKAGE_VERSION=//p' "$RPI5/dkms.conf")
mkdir -p "$OUT" "$WORK"

build_driver() {
	local st=$WORK/rs300-dkms ver=$DKMS_VERSION+$DEB_REV
	rm -rf "$st"
	install -D -m 644 "$RPI5/dkms.conf" "$st/usr/src/rs300-$DKMS_VERSION/dkms.conf"
	install -D -m 644 "$RPI5/Makefile" "$st/usr/src/rs300-$DKMS_VERSION/Makefile"
	install -D -m 644 "$RPI5/src/rs300.c" "$st/usr/src/rs300-$DKMS_VERSION/rs300.c"
	# /boot/firmware is FAT: dpkg cannot replace files there on upgrade
	# (no backup hard links), so postinst copies the overlay in.
	mkdir -p "$st/usr/lib/rs300"
	dtc -@ -H epapr -O dtb -o "$st/usr/lib/rs300/rs300.dtbo" \
		"$RPI5/src/rs300-overlay.dts"
	install -D -m 755 "$RPI5/helpers/rs300-stream.py" "$st/usr/bin/rs300-stream"
	install -D -m 755 "$RPI5/helpers/rs300-media-setup.sh" \
		"$st/usr/lib/rs300/rs300-media-setup.sh"
	install -D -m 644 "$RPI5/helpers/rs300-media-setup.service" \
		"$st/lib/systemd/system/rs300-media-setup.service"
	install -D -m 644 "$RPI5/src/99-rs300.rules" "$st/lib/udev/rules.d/99-rs300.rules"
	mkdir -p "$st/etc/modprobe.d"
	cat > "$st/etc/modprobe.d/rs300.conf" <<-EOF
	# rs300 module: mode 0 = 640x512, 1 = 256x192, 2 = 384x288.
	# fps: 30 or 60 for 384x288 and 640x512, 25 or 50 for 256x192.
	# Reboot after a change.
	options rs300 mode=2 fps=60
	EOF
	install -D -m 644 "$RPI5/README.md" "$st/usr/share/doc/rs300-dkms/README.md"

	mkdir -p "$st/DEBIAN"
	echo /etc/modprobe.d/rs300.conf > "$st/DEBIAN/conffiles"
	for s in postinst prerm postrm; do
		sed "s/@DKMS_VERSION@/$DKMS_VERSION/g" "$HERE/rs300-dkms/$s" > "$st/DEBIAN/$s"
		chmod 755 "$st/DEBIAN/$s"
	done
	cat > "$st/DEBIAN/control" <<-EOF
	Package: rs300-dkms
	Version: $ver
	Architecture: all
	Maintainer: $MAINTAINER
	Section: kernel
	Priority: optional
	Depends: dkms, v4l-utils, linux-headers-rpi-2712 | linux-headers-rpi-v8
	Recommends: libcamera-rs300, python3-gi, python3-gi-cairo, gir1.2-gtk-3.0, gir1.2-gstreamer-1.0, gir1.2-gst-plugins-base-1.0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-gtk3
	Homepage: https://github.com/Kodrea/mini2-thermal-driver
	Description: Mini2 / WN2 (rs300) thermal camera driver for Raspberry Pi 5
	 DKMS kernel module, device tree overlay, rs300-stream live viewer and the
	 service that enables the CSI-2 capture link at boot. Installing the
	 package adds dtoverlay=rs300 to /boot/firmware/config.txt.
	 Module resolution and frame rate: /etc/modprobe.d/rs300.conf.
	EOF
	dpkg-deb --root-owner-group --build "$st" "$OUT/rs300-dkms_${ver}_all.deb"
}

build_libcamera() {
	local src=$WORK/libcamera st=$WORK/libcamera-rs300
	local ver=0.5.2+rpt20250903+rs300.$DEB_REV
	[ -d "$src" ] || git clone https://github.com/raspberrypi/libcamera.git "$src"
	git -C "$src" checkout -q -f "$LIBCAMERA_REF"
	git -C "$src" clean -q -fd -e build-deb
	git -C "$src" apply "$RPI5/helpers/libcamera-rs300.patch"

	[ -d "$src/build-deb" ] || meson setup "$src/build-deb" "$src" \
		--prefix=$PREFIX --buildtype=release \
		-Dpipelines=rpi/vc4,rpi/pisp -Dipas=rpi/vc4,rpi/pisp \
		-Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dv4l2=false \
		-Dpycamera=disabled -Dlc-compliance=disabled -Dtest=false \
		-Ddocumentation=disabled -Dtracing=disabled
	ninja -C "$src/build-deb"
	rm -rf "$st"
	DESTDIR=$st meson install -C "$src/build-deb" --no-rebuild >/dev/null

	# Runtime only: no headers or pkg-config files.
	rm -rf "$st$PREFIX/include"
	find "$st$PREFIX" -name pkgconfig -type d -exec rm -rf {} +
	local libdir
	libdir=$(dirname "$(find "$st$PREFIX" -name 'libcamera.so.0*' | head -1)")
	libdir=${libdir#"$st"}
	mkdir -p "$st/etc/ld.so.conf.d"
	echo "$libdir" > "$st/etc/ld.so.conf.d/00-libcamera-rs300.conf"
	install -D -m 644 "$RPI5/helpers/libcamera-rs300.patch" \
		"$st/usr/share/doc/libcamera-rs300/libcamera-rs300.patch"

	# Shared library dependencies, from what the binaries link against.
	local deps
	deps=$(find "$st$PREFIX" -type f | while read -r f; do
			if [ "$(head -c 4 "$f" | tail -c 3)" = ELF ]; then ldd "$f"; fi
		done | awk '/=> \// {print $3}' | grep -vE '^/(usr/local|opt)/' | sort -u |
		while read -r lib; do
			# Merged /usr: dpkg may record the path with or without /usr.
			dpkg -S "$lib" 2>/dev/null || dpkg -S "/usr$lib" 2>/dev/null ||
				dpkg -S "${lib#/usr}" 2>/dev/null || true
		done | grep -v diversion | cut -d: -f1 |
		grep -v '^libcamera' | sort -u | paste -sd, | sed 's/,/, /g')

	mkdir -p "$st/DEBIAN"
	echo "activate-noawait ldconfig" > "$st/DEBIAN/triggers"
	cat > "$st/DEBIAN/control" <<-EOF
	Package: libcamera-rs300
	Version: $ver
	Architecture: arm64
	Maintainer: $MAINTAINER
	Section: libs
	Priority: optional
	Depends: libcamera0.5 (= $LIBCAMERA_PKG_VERSION), $deps
	Homepage: https://github.com/Kodrea/mini2-thermal-driver
	Description: libcamera with Mini2 / WN2 (rs300) thermal camera support
	 Raspberry Pi libcamera ($LIBCAMERA_REF, as in libcamera0.5
	 $LIBCAMERA_PKG_VERSION) with the rs300 camera helper, tuning file and
	 pipeline changes. Installed in $PREFIX. An ld.so.conf.d entry makes
	 rpicam-apps, cam, Picamera2 and GStreamer libcamerasrc load it in place
	 of the system libcamera. The system package is not changed; remove this
	 package to go back to it. It depends on the exact system libcamera
	 version, so upgrade both together.
	EOF
	dpkg-deb --root-owner-group --build "$st" "$OUT/libcamera-rs300_${ver}_arm64.deb"
}

sudo apt-get install -y -q dkms device-tree-compiler git meson ninja-build \
	pkg-config g++ libyaml-dev python3-yaml python3-ply python3-jinja2 \
	libudev-dev libevent-dev libdrm-dev libssl-dev libpisp-dev >/dev/null

case "$WHAT" in
	driver) build_driver ;;
	libcamera) build_libcamera ;;
	all) build_driver; build_libcamera ;;
	*) echo "usage: $0 [driver|libcamera|all]" >&2; exit 2 ;;
esac
ls -l "$OUT"/*.deb
