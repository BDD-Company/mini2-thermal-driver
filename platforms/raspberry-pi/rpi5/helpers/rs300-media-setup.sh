#!/bin/bash
#
# Enable the CSI-2 bypass capture link for the rs300 sensor on Raspberry Pi 5.
#
# The rs300 driver propagates its source pad format to the CSI-2 receiver, which
# satisfies the receiver's format validation. It does not enable the media link
# that carries frames to the capture node, and the RP1 CFE creates that link
# disabled. Without this step VIDIOC_STREAMON fails with EINVAL and the kernel
# logs "csi2_ch0 node link is not enabled".
#
# Safe to run repeatedly. Every action is idempotent.

set -u

WAIT_SECONDS=30
MEDIA_DEV=""

# Media device numbering is not stable across boots, so the device that carries
# the sensor has to be discovered rather than assumed.
find_media_dev() {
    local d
    for d in /dev/media*; do
        [ -e "$d" ] || continue
        if media-ctl -d "$d" -p 2>/dev/null | grep -q "rs300"; then
            MEDIA_DEV="$d"
            return 0
        fi
    done
    return 1
}

# The sensor registers from an async notifier callback that can land after this
# unit starts, so poll rather than failing on the first miss.
for _ in $(seq 1 "$WAIT_SECONDS"); do
    if find_media_dev; then
        break
    fi
    sleep 1
done

if [ -z "$MEDIA_DEV" ]; then
    echo "rs300-media-setup: no media device exposes the rs300 sensor" >&2
    exit 1
fi

# Source pad 4 of the CSI-2 receiver can route either to the ISP front end or to
# the bypass capture node, but not to both. This driver targets the bypass path.
# Reset all links first: libcamera leaves the front end links enabled, and the
# CFE does not start until every node with an enabled link streams.
media-ctl -d "$MEDIA_DEV" -r

if ! media-ctl -d "$MEDIA_DEV" -l "'csi2':4 -> 'rp1-cfe-csi2_ch0':0 [1]"; then
    echo "rs300-media-setup: failed to enable the bypass capture link on $MEDIA_DEV" >&2
    exit 1
fi

echo "rs300-media-setup: bypass capture link enabled on $MEDIA_DEV"

# libcamera (rpicam-apps, cam) leaves the sensor in its raw Y16 mode. Set YUYV
# again: the driver switches the module to match and passes the format on to
# the CSI-2 receiver. media-ctl -V does not reach the sensor here, so use
# v4l2-ctl on the sensor subdev.
SENSOR=$(media-ctl -d "$MEDIA_DEV" -p | grep -o "rs300 [0-9]*-[0-9a-f]*" | head -1)
SENSOR_DEV=$(media-ctl -d "$MEDIA_DEV" -e "$SENSOR")
read -r WIDTH HEIGHT < <(v4l2-ctl -d "$SENSOR_DEV" --get-subdev-fmt pad=0 |
    awk -F'[:/ ]+' '/Width\/Height/ {print $3, $4}')
if ! v4l2-ctl -d "$SENSOR_DEV" --set-subdev-fmt \
        "pad=0,width=$WIDTH,height=$HEIGHT,code=0x2011" >/dev/null 2>&1; then
    echo "rs300-media-setup: failed to set YUYV on $SENSOR_DEV" >&2
    exit 1
fi
echo "rs300-media-setup: sensor set to YUYV ${WIDTH}x${HEIGHT}"
