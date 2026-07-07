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
SBL1_PATH=${SBL1_PATH:-"$ROOT_DIR/bootchain/sbl1.mbn"}
RPM_PATH=${RPM_PATH:-"$ROOT_DIR/bootchain/rpm.mbn"}
TZ_PATH=${TZ_PATH:-"$ROOT_DIR/bootchain/tz.mbn"}
HYP_PATH=${HYP_PATH:-"$ROOT_DIR/bootchain/hyp.mbn"}
BACKUP_DIR=${BACKUP_DIR:-}

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
need_cmd python3
need_cmd sha256sum
need_cmd simg2img
need_cmd stat
need_cmd xz

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/downloads/debian" "$OUT_DIR/downloads/kernel"

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

for f in \
	"$ROOTFS_XZ_PATH" \
	"$BOOT_IMG_PATH" \
	"$ABOOT_MBN_PATH" \
	"$SBL1_PATH" \
	"$RPM_PATH" \
	"$TZ_PATH" \
	"$HYP_PATH"
do
	need_file "$f"
done

bash "$ROOT_DIR/scripts/make-ufi003-gpt.sh" "$OUT_DIR" gpt
# shellcheck disable=SC1091
source "$OUT_DIR/gpt.env"

cp "$ROOTFS_XZ_PATH" "$OUT_DIR/rootfs.img.xz"
cp "$ABOOT_MBN_PATH" "$OUT_DIR/aboot.mbn"
cp "$SBL1_PATH" "$OUT_DIR/sbl1.mbn"
cp "$RPM_PATH" "$OUT_DIR/rpm.mbn"
cp "$TZ_PATH" "$OUT_DIR/tz.mbn"
cp "$HYP_PATH" "$OUT_DIR/hyp.mbn"

xz -dk -f "$OUT_DIR/rootfs.img.xz"
ROOTFS_IMG="$OUT_DIR/rootfs.img"
ROOTFS_RAW="$OUT_DIR/rootfs.raw"

simg2img "$ROOTFS_IMG" "$ROOTFS_RAW" >/dev/null
cat > "$OUT_DIR/fstab" <<EOF
PARTUUID=$ROOTFS_PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
debugfs -w -R "rm /etc/fstab" "$ROOTFS_RAW" >/dev/null 2>&1 || true
debugfs -w -R "write $OUT_DIR/fstab /etc/fstab" "$ROOTFS_RAW" >/dev/null
img2simg "$ROOTFS_RAW" "$ROOTFS_IMG" >/dev/null

ROOT_SPEC="PARTUUID=$ROOTFS_PARTUUID" \
	bash "$ROOT_DIR/scripts/patch-bootimg.sh" "$BOOT_IMG_PATH" "$OUT_DIR/boot.bin" "$KERNEL_TAG"

check_size "$OUT_DIR/aboot.mbn" "$ABOOT_PART_SIZE" "aboot image"
check_size "$OUT_DIR/sbl1.mbn" "$SBL1_PART_SIZE" "sbl1 image"
check_size "$OUT_DIR/rpm.mbn" "$RPM_PART_SIZE" "rpm image"
check_size "$OUT_DIR/tz.mbn" "$TZ_PART_SIZE" "tz image"
check_size "$OUT_DIR/hyp.mbn" "$HYP_PART_SIZE" "hyp image"
check_size "$OUT_DIR/boot.bin" "$BOOT_PART_SIZE" "boot image"
check_size "$ROOTFS_RAW" "$ROOTFS_PART_SIZE" "unsparsed rootfs image"

extra_labels=()
if [ -n "$BACKUP_DIR" ]; then
	for label in fsc fsg modem modemst1 modemst2 persist sec; do
		need_file "$BACKUP_DIR/$label.bin"
		cp "$BACKUP_DIR/$label.bin" "$OUT_DIR/$label.bin"
		extra_labels+=("$label")
	done
fi

cat > "$OUT_DIR/rawprogram0.xml" <<EOF
<?xml version="1.0" ?>
<data>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="gpt_main0.bin" label="PrimaryGPT" num_partition_sectors="34" partofsingleimage="true" physical_partition_number="0" readbackverify="false" size_in_KB="17.0" sparse="false" start_byte_hex="0x0" start_sector="0"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="gpt_backup0.bin" label="BackupGPT" num_partition_sectors="33" partofsingleimage="true" physical_partition_number="0" readbackverify="false" size_in_KB="16.5" sparse="false" start_byte_hex="0x$(printf '%x' $((GPT_BACKUP_START * SECTOR_SIZE)))" start_sector="$GPT_BACKUP_START"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="hyp.mbn" label="hyp" num_partition_sectors="$((HYP_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $HYP_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((HYP_START_SECTOR * SECTOR_SIZE)))" start_sector="$HYP_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="rpm.mbn" label="rpm" num_partition_sectors="$((RPM_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $RPM_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((RPM_START_SECTOR * SECTOR_SIZE)))" start_sector="$RPM_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="sbl1.mbn" label="sbl1" num_partition_sectors="$((SBL1_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $SBL1_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((SBL1_START_SECTOR * SECTOR_SIZE)))" start_sector="$SBL1_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="tz.mbn" label="tz" num_partition_sectors="$((TZ_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $TZ_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((TZ_START_SECTOR * SECTOR_SIZE)))" start_sector="$TZ_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="aboot.mbn" label="aboot" num_partition_sectors="$((ABOOT_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $ABOOT_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((ABOOT_START_SECTOR * SECTOR_SIZE)))" start_sector="$ABOOT_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="boot.bin" label="boot" num_partition_sectors="$((BOOT_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $BOOT_PART_SIZE/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((BOOT_START_SECTOR * SECTOR_SIZE)))" start_sector="$BOOT_START_SECTOR"/>
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="rootfs.img" label="rootfs" num_partition_sectors="$((ROOTFS_PART_SIZE / SECTOR_SIZE))" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", $ROOTFS_PART_SIZE/1024 }")" sparse="true" start_byte_hex="0x$(printf '%x' $((ROOTFS_START_SECTOR * SECTOR_SIZE)))" start_sector="$ROOTFS_START_SECTOR"/>
EOF

if [ "${#extra_labels[@]}" -gt 0 ]; then
	for label in "${extra_labels[@]}"; do
		case "$label" in
			fsc) start=4096; sectors=2 ;;
			fsg) start=4098; sectors=3072 ;;
			modem) start=7170; sectors=131072 ;;
			modemst1) start=138242; sectors=3072 ;;
			modemst2) start=141314; sectors=3072 ;;
			persist) start=144386; sectors=65536 ;;
			sec) start=209922; sectors=32 ;;
		esac
		cat >> "$OUT_DIR/rawprogram0.xml" <<EOF
	<program SECTOR_SIZE_IN_BYTES="$SECTOR_SIZE" file_sector_offset="0" filename="$label.bin" label="$label" num_partition_sectors="$sectors" partofsingleimage="false" physical_partition_number="0" readbackverify="false" size_in_KB="$(awk "BEGIN { printf \"%.1f\", ($sectors * $SECTOR_SIZE)/1024 }")" sparse="false" start_byte_hex="0x$(printf '%x' $((start * SECTOR_SIZE)))" start_sector="$start"/>
EOF
	done
fi

cat >> "$OUT_DIR/rawprogram0.xml" <<'EOF'
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
echo "Expected primary path: lk1st boots directly from the boot partition and mounts the rootfs partition."
EOF
chmod +x "$OUT_DIR/flash-ufi003-edl.sh"

cat > "$OUT_DIR/BUILD_INFO.txt" <<EOF
Upstream Debian release: $UPSTREAM_DEBIAN_REPO $DEBIAN_TAG
Upstream kernel release: $UPSTREAM_KERNEL_REPO $KERNEL_TAG

Package layout:
- gpt <- validated success-case boot+rootfs layout
- sbl1/rpm/tz/hyp <- bundled boot-chain blobs
- aboot <- emmc_appsboot-test-signed.mbn
- boot <- patched boot.img
- rootfs <- rootfs.img

Notes:
- This package follows the validated UFI003 boot+rootfs GPT layout.
- boot.bin is a patched Android boot image that mounts root via PARTUUID=$ROOTFS_PARTUUID.
EOF

(
	cd "$OUT_DIR"
	files=(
		gpt_both0.bin
		gpt_main0.bin
		gpt_backup0.bin
		gpt.env
		sbl1.mbn
		rpm.mbn
		tz.mbn
		hyp.mbn
		aboot.mbn
		boot.bin
		rootfs.img
		rootfs.img.xz
		rootfs.raw
		fstab
		rawprogram0.xml
		patch0.xml
		flash-ufi003-edl.sh
		BUILD_INFO.txt
	)
	if [ "${#extra_labels[@]}" -gt 0 ]; then
		files+=("${extra_labels[@]/%/.bin}")
	fi
	sha256sum "${files[@]}" > SHA256SUMS
)

echo "EDL package created in $OUT_DIR"
