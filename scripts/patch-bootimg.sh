#!/bin/sh
set -eu

BOOT_IMG="${1:-boot.img}"
OUTPUT="${2:-custom-boot.img}"
KERNEL_VERSION="${3:-6.12.94-1}"

if [ ! -f "$BOOT_IMG" ]; then
	echo "Downloading boot.img for kernel $KERNEL_VERSION ..."
	wget -q -O boot.img \
		"https://github.com/KyonLi/ufi003-kernel/releases/download/$KERNEL_VERSION/boot.img"
	BOOT_IMG="boot.img"
fi

echo "Patching cmdline in $BOOT_IMG -> $OUTPUT"
cp "$BOOT_IMG" "$OUTPUT"

PYTHON=$(command -v python3)
$PYTHON << PYEOF
import struct
with open("$OUTPUT", "r+b") as f:
    new_cmdline = "console=ttyMSM0,115200 root=/dev/mmcblk0p27 no_framebuffer=true rw"
    cmdline_bytes = new_cmdline.encode("ascii").ljust(512, b"\x00")
    data = f.read()
    patched = bytearray(data)
    patched[64:64+512] = cmdline_bytes
    f.seek(0)
    f.write(patched)

with open("$OUTPUT", "rb") as f:
    header = f.read(48)
kernel_size = struct.unpack('<I', header[8:12])[0]
ramdisk_size = struct.unpack('<I', header[16:20])[0]
second_size = struct.unpack('<I', header[24:28])[0]
page_size = struct.unpack('<I', header[36:40])[0]

import os
total = os.path.getsize("$OUTPUT")
print(f"kernel={kernel_size} ramdisk={ramdisk_size} second={second_size} page_size={page_size} total={total}")
PYEOF
echo "Done: $(ls -lh "$OUTPUT")"
