#!/usr/bin/env bash
set -euo pipefail

OUT_DIR=${1:-.}
PREFIX=${2:-gpt}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

need_cmd dd
need_cmd sfdisk
need_cmd truncate

TMPDIR=$(mktemp -d)
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

SECTOR_SIZE=512
TOTAL_SECTORS=7405568
DISK_BYTES=$((TOTAL_SECTORS * SECTOR_SIZE))
LAST_USABLE=$((TOTAL_SECTORS - 34))

# This is the validated "success-case" GPT layout:
# small firmware partitions first, then a 64 MiB boot partition and
# a large rootfs partition taking the rest of the eMMC.
ROOTFS_START=348194
ROOTFS_SIZE=$((LAST_USABLE - ROOTFS_START + 1))

GPT_IMG="$TMPDIR/${PREFIX}.img"
GPT_BOTH="$OUT_DIR/${PREFIX}_both0.bin"
GPT_MAIN="$OUT_DIR/${PREFIX}_main0.bin"
GPT_BACKUP="$OUT_DIR/${PREFIX}_backup0.bin"
META_ENV="$OUT_DIR/${PREFIX}.env"

truncate -s "$DISK_BYTES" "$GPT_IMG"

cat <<EOF | sfdisk "$GPT_IMG" >/dev/null
label: gpt
label-id: DB708ACF-2E04-8DE2-BAFE-30C9B26444C5
unit: sectors
first-lba: 34
last-lba: $LAST_USABLE
sector-size: $SECTOR_SIZE

${PREFIX}.img1  : start=        4096, size=           2, type=57B90A16-22C9-E33B-8F5D-0E81686A68CB, uuid=89BEF928-6B3F-432E-970E-46926F6BD579, name="fsc"
${PREFIX}.img2  : start=        4098, size=        3072, type=638FF8E2-22C9-E33B-8F5D-0E81686A68CB, uuid=2B772340-E0F0-4A95-B652-27ADE619EF14, name="fsg"
${PREFIX}.img3  : start=        7170, size=      131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=709AEC75-FFB4-4218-9A2E-A38C9D689D6D, name="modem"
${PREFIX}.img4  : start=      138242, size=        3072, type=EBBEADAF-22C9-E33B-8F5D-0E81686A68CB, uuid=D747B414-92EA-4098-AA56-0ED0AAB1F6DC, name="modemst1"
${PREFIX}.img5  : start=      141314, size=        3072, type=0A288B1F-22C9-E33B-8F5D-0E81686A68CB, uuid=057F46B4-9F89-4AA4-9A60-1735B4E2DB4B, name="modemst2"
${PREFIX}.img6  : start=      144386, size=       65536, type=6C95E238-E343-4BA8-B489-8681ED22AD0B, uuid=ACD4F30F-6A99-42B2-9262-A3FECEB2B46B, name="persist"
${PREFIX}.img7  : start=      209922, size=          32, type=303E6AC3-AF15-4C54-9E9B-D9A8FBECF401, uuid=DD07C606-826C-4B5E-BE75-F5FCAA91E623, name="sec"
${PREFIX}.img8  : start=      209954, size=        1024, type=E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A, uuid=CB49D0D3-C49B-4586-986C-BDADBF545FEF, name="hyp"
${PREFIX}.img9  : start=      210978, size=        1024, type=098DF793-D712-413D-9D4E-89D711772228, uuid=B5154BA2-C18D-4A17-A8CD-97EEDC0BEF31, name="rpm"
${PREFIX}.img10 : start=      212002, size=        1024, type=DEA0BA2C-CBDD-4805-B4F9-F428251C3E98, uuid=B166535F-4B99-48F6-AA77-16F27669FD2F, name="sbl1"
${PREFIX}.img11 : start=      213026, size=        2048, type=A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4, uuid=A983B7C4-FC3A-4F88-823E-91D5DB06337F, name="tz"
${PREFIX}.img12 : start=      215074, size=        2048, type=400FFDCD-22E0-47E7-9A23-F16ED9382388, uuid=22675009-60A3-401F-8D3F-44CD32ED394C, name="aboot"
${PREFIX}.img13 : start=      217122, size=      131072, type=20117F86-E985-4357-B9EE-374BC1D8487D, uuid=80780B1D-0FE1-27D3-23E4-9244E62F8C46, name="boot"
${PREFIX}.img14 : start=      $ROOTFS_START, size=     $ROOTFS_SIZE, type=1B81E7E6-F50D-419B-A739-2AEEF8DA3335, uuid=A7AB80E8-E9D1-E8CD-F157-93F69B1D141E, name="rootfs"
EOF

dd if="$GPT_IMG" of="$GPT_MAIN" bs=$SECTOR_SIZE count=34 status=none
dd if="$GPT_IMG" of="$GPT_BACKUP" bs=$SECTOR_SIZE skip=$((TOTAL_SECTORS - 33)) count=33 status=none
cat "$GPT_MAIN" "$GPT_BACKUP" > "$GPT_BOTH"

cat > "$META_ENV" <<EOF
SECTOR_SIZE=$SECTOR_SIZE
TOTAL_SECTORS=$TOTAL_SECTORS
GPT_MAIN_SECTORS=34
GPT_BACKUP_SECTORS=33
GPT_BACKUP_START=$((TOTAL_SECTORS - 33))
ABOOT_START_SECTOR=215074
ABOOT_PART_SIZE=$((2048 * SECTOR_SIZE))
BOOT_START_SECTOR=217122
BOOT_PART_SIZE=$((131072 * SECTOR_SIZE))
ROOTFS_START_SECTOR=$ROOTFS_START
ROOTFS_PART_SIZE=$((ROOTFS_SIZE * SECTOR_SIZE))
ROOTFS_PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e
HYP_START_SECTOR=209954
HYP_PART_SIZE=$((1024 * SECTOR_SIZE))
RPM_START_SECTOR=210978
RPM_PART_SIZE=$((1024 * SECTOR_SIZE))
SBL1_START_SECTOR=212002
SBL1_PART_SIZE=$((1024 * SECTOR_SIZE))
TZ_START_SECTOR=213026
TZ_PART_SIZE=$((2048 * SECTOR_SIZE))
EOF

echo "Wrote:"
echo "  $GPT_BOTH"
echo "  $GPT_MAIN"
echo "  $GPT_BACKUP"
echo "  $META_ENV"
