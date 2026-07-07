#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR=${1:-"$ROOT_DIR/output"}

DEBIAN_TAG=${DEBIAN_TAG:-13.5-15}
KERNEL_TAG=${KERNEL_TAG:-6.12.94-1}
UPSTREAM_DEBIAN_REPO=${UPSTREAM_DEBIAN_REPO:-KyonLi/ufi003-debian}
UPSTREAM_KERNEL_REPO=${UPSTREAM_KERNEL_REPO:-KyonLi/ufi003-kernel}

ROOTFS_XZ_PATH=${ROOTFS_XZ_PATH:-}
BOOT_IMG_PATH=${BOOT_IMG_PATH:-}
ABOOT_MBN_PATH=${ABOOT_MBN_PATH:-}
WITH_GPT=${WITH_GPT:-1}

SECTOR_SIZE=512

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

need_file() {
	[ -f "$1" ] || {
		echo "Missing required file: $1" >&2
		exit 1
	}
}

check_size() {
	local path=$1
	local max_bytes=$2
	local label=$3
	local size
	size=$(stat -c %s "$path")
	if [ "$size" -gt "$max_bytes" ]; then
		echo "$label is too large: $size bytes > $max_bytes bytes" >&2
		exit 1
	fi
}

need_cmd bash
need_cmd debugfs
need_cmd img2simg
need_cmd mkfs.ext4
need_cmd python3
need_cmd sfdisk
need_cmd sha256sum
need_cmd simg2img
need_cmd stat
need_cmd truncate
need_cmd xz

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/downloads/debian" "$OUT_DIR/downloads/kernel" "$OUT_DIR/bootfs/extlinux"

if [ -n "$ROOTFS_XZ_PATH" ] || [ -n "$BOOT_IMG_PATH" ] || [ -n "$ABOOT_MBN_PATH" ]; then
	need_file "$ROOTFS_XZ_PATH"
	need_file "$BOOT_IMG_PATH"
	need_file "$ABOOT_MBN_PATH"
else
	need_cmd gh
	gh release download "$DEBIAN_TAG" \
		--repo "$UPSTREAM_DEBIAN_REPO" \
		--pattern 'rootfs.img.xz' \
		--pattern 'emmc_appsboot-test-signed.mbn' \
		--dir "$OUT_DIR/downloads/debian"

	gh release download "$KERNEL_TAG" \
		--repo "$UPSTREAM_KERNEL_REPO" \
		--pattern 'boot.img' \
		--dir "$OUT_DIR/downloads/kernel"

	ROOTFS_XZ_PATH="$OUT_DIR/downloads/debian/rootfs.img.xz"
	BOOT_IMG_PATH="$OUT_DIR/downloads/kernel/boot.img"
	ABOOT_MBN_PATH="$OUT_DIR/downloads/debian/emmc_appsboot-test-signed.mbn"
fi

need_file "$ROOTFS_XZ_PATH"
need_file "$BOOT_IMG_PATH"
need_file "$ABOOT_MBN_PATH"

if [ "$WITH_GPT" = "1" ]; then
	bash "$ROOT_DIR/scripts/make-ufi003-gpt.sh" "$OUT_DIR" gpt
	# shellcheck disable=SC1091
	source "$OUT_DIR/gpt.env"
else
	ABOOT_PART_SIZE=$((0x00100000))
	BOOT_PART_SIZE=$((0x01000000))
	SYSTEM_PART_SIZE=$((0x32000000))
	USERDATA_PART_SIZE=$((0x97e6fe00))
	ABOOT_START_SECTOR=264192
	BOOT_START_SECTOR=396384
	SYSTEM_START_SECTOR=429152
	USERDATA_START_SECTOR=2428000
	USERDATA_PARTUUID=598664a9-7976-e692-dd1c-010c5d49b568
fi

cp "$ROOTFS_XZ_PATH" "$OUT_DIR/rootfs.img.xz"
cp "$ABOOT_MBN_PATH" "$OUT_DIR/emmc_appsboot-test-signed.mbn"
xz -dk -f "$OUT_DIR/rootfs.img.xz"
ROOTFS_IMG="$OUT_DIR/rootfs.img"
ROOTFS_RAW="$OUT_DIR/rootfs.raw"

simg2img "$ROOTFS_IMG" "$ROOTFS_RAW" >/dev/null
cat > "$OUT_DIR/fstab" <<EOF
PARTUUID=$USERDATA_PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
debugfs -w -R "rm /etc/fstab" "$ROOTFS_RAW" >/dev/null 2>&1 || true
debugfs -w -R "write $OUT_DIR/fstab /etc/fstab" "$ROOTFS_RAW" >/dev/null
img2simg "$ROOTFS_RAW" "$ROOTFS_IMG" >/dev/null

ROOT_SPEC="PARTUUID=$USERDATA_PARTUUID" \
	bash "$ROOT_DIR/scripts/patch-bootimg.sh" "$BOOT_IMG_PATH" "$OUT_DIR/custom-boot.img" "$KERNEL_TAG"

python3 - "$BOOT_IMG_PATH" "$OUT_DIR/bootfs/vmlinuz" "$OUT_DIR/bootfs/initramfs" <<'PY'
import struct
import sys

boot_img, kernel_out, ramdisk_out = sys.argv[1:4]

with open(boot_img, "rb") as f:
    header = f.read(2048)
    if header[:8] != b"ANDROID!":
        raise SystemExit("Unsupported boot image magic")
    kernel_size = struct.unpack("<I", header[8:12])[0]
    ramdisk_size = struct.unpack("<I", header[16:20])[0]
    second_size = struct.unpack("<I", header[24:28])[0]
    page_size = struct.unpack("<I", header[36:40])[0]

    def align(value, block):
        return ((value + block - 1) // block) * block

    kernel_offset = page_size
    ramdisk_offset = kernel_offset + align(kernel_size, page_size)
    second_offset = ramdisk_offset + align(ramdisk_size, page_size)

    f.seek(kernel_offset)
    kernel = f.read(kernel_size)
    f.seek(ramdisk_offset)
    ramdisk = f.read(ramdisk_size)

    if second_size:
        f.seek(second_offset)
        second = f.read(second_size)
        if second:
            print("warning: second stage payload present but not used", file=sys.stderr)

with open(kernel_out, "wb") as f:
    f.write(kernel)

with open(ramdisk_out, "wb") as f:
    f.write(ramdisk)
PY

cat > "$OUT_DIR/bootfs/extlinux/extlinux.conf" <<EOF
timeout 1
default ufi003-debian

label ufi003-debian
    kernel /vmlinuz
    initrd /initramfs
    append console=ttyMSM0,115200 root=PARTUUID=$USERDATA_PARTUUID no_framebuffer=true rw
EOF

truncate -s 32M "$OUT_DIR/ufi003-bootfs.img"
mkfs.ext4 -q -F -L bootfs -d "$OUT_DIR/bootfs" -b 4096 "$OUT_DIR/ufi003-bootfs.img"
truncate -s 16M "$OUT_DIR/zero-boot.bin"

check_size "$OUT_DIR/emmc_appsboot-test-signed.mbn" "$ABOOT_PART_SIZE" "aboot image"
check_size "$OUT_DIR/ufi003-bootfs.img" "$SYSTEM_PART_SIZE" "bootfs image"
check_size "$OUT_DIR/zero-boot.bin" "$BOOT_PART_SIZE" "zero-boot image"
check_size "$ROOTFS_RAW" "$USERDATA_PART_SIZE" "unsparsed rootfs image"

cat > "$OUT_DIR/rawprogram0.xml" <<EOF
<?xml version="1.0" ?>
<data>
EOF

if [ "$WITH_GPT" = "1" ]; then
cat >> "$OUT_DIR/rawprogram0.xml" <<EOF
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="gpt_main0.bin" label="PrimaryGPT" num_partition_sectors="34" partofsingleimage="true" physical_partition_number="0" readbackverify="false" size_in_KB="17.0" sparse="false" start_byte_hex="0x0" start_sector="0"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="gpt_backup0.bin" label="BackupGPT" num_partition_sectors="33" partofsingleimage="true" physical_partition_number="0" readbackverify="false" size_in_KB="16.5" sparse="false" start_byte_hex="0x$(printf '%x' $((GPT_BACKUP_START * SECTOR_SIZE)))" start_sector="$GPT_BACKUP_START"/>
EOF
fi

cat >> "$OUT_DIR/rawprogram0.xml" <<EOF
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="emmc_appsboot-test-signed.mbn" label="aboot" num_partition_sectors="2048" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="1024.0" sparse="false" start_byte_hex="0x8100000" start_sector="$ABOOT_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="zero-boot.bin" label="boot" num_partition_sectors="32768" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="16384.0" sparse="false" start_byte_hex="0xc18c000" start_sector="$BOOT_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="ufi003-bootfs.img" label="system" num_partition_sectors="1638400" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="819200.0" sparse="false" start_byte_hex="0xd18c000" start_sector="$SYSTEM_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="rootfs.img" label="userdata" num_partition_sectors="4977535" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="2488767.5" sparse="true" start_byte_hex="0x4a18c000" start_sector="$USERDATA_START_SECTOR"/>
</data>
EOF

cat > "$OUT_DIR/patch0.xml" <<'EOF'
<?xml version="1.0" ?>
<data/>
EOF

cat > "$OUT_DIR/flash-ufi003-edl.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$ARTIFACT_DIR/.." && pwd)

if [ -x "$PROJECT_ROOT/.venv-edl/bin/python" ]; then
	EDL_PY=${EDL_PY:-"$PROJECT_ROOT/.venv-edl/bin/python"}
else
	EDL_PY=${EDL_PY:-python3}
fi

EDL_SCRIPT=${EDL_SCRIPT:-"$PROJECT_ROOT/edl/edl.py"}

[ -f "$EDL_SCRIPT" ] || {
	echo "Cannot find $EDL_SCRIPT" >&2
	exit 1
}

echo "Verifying GPT via EDL..."
"$EDL_PY" "$EDL_SCRIPT" printgpt --memory=eMMC

echo "Flashing qfil package..."
"$EDL_PY" "$EDL_SCRIPT" qfil "$ARTIFACT_DIR/rawprogram0.xml" "$ARTIFACT_DIR/patch0.xml" "$ARTIFACT_DIR" --memory=eMMC

echo "Resetting device..."
set +e
"$EDL_PY" "$EDL_SCRIPT" reset
reset_rc=$?
set -e
if [ "$reset_rc" -ne 0 ]; then
	echo "Device likely disconnected immediately after reset; continue with boot checks."
fi

echo
echo "EDL flash finished."
echo "Expected primary path: lk1st boots from the system partition bootfs and mounts userdata as root."
echo "Fallback test if the device lands in fastboot:"
echo "  fastboot boot $ARTIFACT_DIR/custom-boot.img"
EOF
chmod +x "$OUT_DIR/flash-ufi003-edl.sh"

cat > "$OUT_DIR/BUILD_INFO.txt" <<EOF
Upstream Debian release: $UPSTREAM_DEBIAN_REPO $DEBIAN_TAG
Upstream kernel release: $UPSTREAM_KERNEL_REPO $KERNEL_TAG

Package layout:
- aboot <- emmc_appsboot-test-signed.mbn
- boot <- zero-boot.bin
- system <- ufi003-bootfs.img
- userdata <- rootfs.img

Notes:
- The package can restore a known-good UFI003 GPT before writing partitions.
- custom-boot.img is provided for fastboot boot testing only; it is larger than the 16 MiB boot partition.
- ufi003-bootfs.img contains kernel + initramfs + extlinux config and is intended for lk1st/system boot.
- rootfs /etc/fstab is patched to the live userdata PARTUUID.
- rawprogram0.xml + patch0.xml can be used with edl qfil.
EOF

(
	cd "$OUT_DIR"
	files=(
		emmc_appsboot-test-signed.mbn
		zero-boot.bin
		ufi003-bootfs.img
		rootfs.img
		rootfs.img.xz
		rootfs.raw
		custom-boot.img
		fstab
		rawprogram0.xml
		patch0.xml
		flash-ufi003-edl.sh
		BUILD_INFO.txt
	)
	if [ "$WITH_GPT" = "1" ]; then
		files=(
			gpt_both0.bin
			gpt_main0.bin
			gpt_backup0.bin
			gpt.env
			"${files[@]}"
		)
	fi
	sha256sum "${files[@]}" > SHA256SUMS
)

echo "EDL package created in $OUT_DIR"
