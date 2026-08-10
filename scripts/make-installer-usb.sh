#!/usr/bin/env bash
# Build an Anaconda-based installer ISO from a bootc image (default: the
# niri desktop flavor) with bootc-image-builder, then write it to a USB
# stick. See README.md "Fresh bare metal / VM" for the manual equivalent of
# the build step this script automates.
set -euo pipefail

IMAGE="ghcr.io/eelcoh/kubevirt-host-bootc-image/niri:latest"
OUTPUT_DIR="./output"
DEVICE=""
USERNAME=""
SSH_KEY_FILE=""
# quay.io/fedora/fedora-bootc:44 (what base/Containerfile builds from) ships
# no /usr/lib/bootc/install.toml, so bootc-image-builder has no default
# root-fs-type to fall back on and errors out unless --rootfs is given
# explicitly. ext4 is Fedora's conventional bootc choice (RHEL/CentOS bootc
# images default to xfs instead).
ROOTFS="ext4"

usage() {
	cat <<-EOF
	Usage: $(basename "$0") -d /dev/sdX -u USERNAME [-k SSH_KEY_FILE] [-i IMAGE] [-o OUTPUT_DIR] [-r ROOTFS]

	  -d DEVICE      USB block device to write the installer to (e.g. /dev/sdb).
	                 REQUIRED. The whole device is overwritten, not a partition.
	  -u USERNAME    Login account to create on the installed system (added to
	                 the wheel group for sudo). REQUIRED: none of the images in
	                 this repo create a user or set a root password on their
	                 own (see base/Containerfile), so without this the
	                 installer produces a system nothing can log into. You'll
	                 be prompted for the password interactively.
	  -k SSH_KEY_FILE  Path to a public SSH key file to authorize for USERNAME.
	  -i IMAGE       bootc image reference to build an installer for.
	                 Default: ${IMAGE}
	  -o OUTPUT_DIR  Directory bootc-image-builder writes the ISO into.
	                 Default: ${OUTPUT_DIR}
	  -r ROOTFS      Root filesystem type for the installed system (ext4, xfs, btrfs).
	                 Default: ${ROOTFS}
	  -h             Show this help.

	Example:
	  $(basename "$0") -d /dev/sdb -u eelco
	  $(basename "$0") -d /dev/sdb -u eelco -k ~/.ssh/id_ed25519.pub -i ghcr.io/eelcoh/kubevirt-host-bootc-image/kubevirt:latest
	EOF
}

while getopts ":d:u:k:i:o:r:h" opt; do
	case "$opt" in
	d) DEVICE="$OPTARG" ;;
	u) USERNAME="$OPTARG" ;;
	k) SSH_KEY_FILE="$OPTARG" ;;
	i) IMAGE="$OPTARG" ;;
	o) OUTPUT_DIR="$OPTARG" ;;
	r) ROOTFS="$OPTARG" ;;
	h)
		usage
		exit 0
		;;
	\?)
		echo "Unknown option: -$OPTARG" >&2
		usage
		exit 1
		;;
	:)
		echo "Option -$OPTARG requires an argument" >&2
		usage
		exit 1
		;;
	esac
done

if [[ -z "$DEVICE" ]]; then
	echo "error: -d DEVICE is required" >&2
	usage
	exit 1
fi

if [[ -z "$USERNAME" ]]; then
	echo "error: -u USERNAME is required (see -h) — without it the installed system has no way to log in" >&2
	usage
	exit 1
fi

if [[ -n "$SSH_KEY_FILE" && ! -f "$SSH_KEY_FILE" ]]; then
	echo "error: SSH key file $SSH_KEY_FILE not found" >&2
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "error: must run as root (bootc-image-builder needs --privileged podman, and writing to a raw block device needs root)" >&2
	exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
	echo "error: $DEVICE is not a block device" >&2
	exit 1
fi

# Refuse to touch whatever disk the running system's root filesystem lives
# on, so a typo in -d can't brick the machine running this script.
ROOT_SRC="$(findmnt -no SOURCE / )"
ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
DEVICE_NAME="$(basename "$DEVICE")"
if [[ -n "$ROOT_DISK" && "$DEVICE_NAME" == "$ROOT_DISK" ]]; then
	echo "error: $DEVICE appears to be the disk the running system is booted from. Refusing." >&2
	exit 1
fi

echo "== Target device =="
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$DEVICE"
echo
read -r -p "This will ERASE ALL DATA on $DEVICE. Type the device path to confirm: " CONFIRM
if [[ "$CONFIRM" != "$DEVICE" ]]; then
	echo "Confirmation did not match $DEVICE. Aborting." >&2
	exit 1
fi

# Unmount any mounted partitions on the target device first.
for part in $(lsblk -no NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}'); do
	echo "Unmounting /dev/$part"
	umount "/dev/$part"
done

read -r -s -p "Password for $USERNAME: " USER_PASSWORD
echo
read -r -s -p "Confirm password: " USER_PASSWORD_CONFIRM
echo
if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
	echo "error: passwords did not match" >&2
	exit 1
fi
unset USER_PASSWORD_CONFIRM

mkdir -p "$OUTPUT_DIR"

CONFIG_FILE="$(mktemp)"
cleanup() { rm -f "$CONFIG_FILE"; }
trap cleanup EXIT

{
	echo "[[customizations.user]]"
	echo "name = \"$USERNAME\""
	echo "password = \"$USER_PASSWORD\""
	if [[ -n "$SSH_KEY_FILE" ]]; then
		printf 'key = "%s"\n' "$(cat "$SSH_KEY_FILE")"
	fi
	echo 'groups = ["wheel"]'
} >"$CONFIG_FILE"
unset USER_PASSWORD
chmod 600 "$CONFIG_FILE"

# NOTE: there is no --hostname flag/config here on purpose. bootc-image-builder's
# --type iso path never writes a hostname into the kickstart it generates
# (verified in its source: kickstart.New()'s Options struct has no Hostname
# field), so the install always comes up as whatever DEFAULT_HOSTNAME is set
# to in the source image's /usr/lib/os-release ("fedora" for every flavor
# here). Set a real one after first boot with `hostnamectl set-hostname`.
# See README.md "Fresh bare metal / VM" for the full explanation.
echo "== Building installer ISO for $IMAGE =="
podman run --rm -it --privileged \
	--pull=newer \
	--security-opt label=type:unconfined_t \
	-v "$CONFIG_FILE:/config.toml:ro" \
	-v "$OUTPUT_DIR:/output" \
	-v /var/lib/containers/storage:/var/lib/containers/storage \
	quay.io/centos-bootc/bootc-image-builder:latest \
	--type iso \
	--rootfs "$ROOTFS" \
	"$IMAGE"

mapfile -t ISOS < <(find "$OUTPUT_DIR" -name '*.iso')
if [[ ${#ISOS[@]} -ne 1 ]]; then
	echo "error: expected exactly one .iso under $OUTPUT_DIR, found ${#ISOS[@]}: ${ISOS[*]:-none}" >&2
	exit 1
fi
ISO="${ISOS[0]}"
echo "Built $ISO"

echo "== Writing $ISO to $DEVICE =="
# No oflag=direct: it forces every block to complete synchronously on the
# device with no write-behind buffering, which is much slower than plain
# buffered writes on most USB flash controllers. conv=fsync + the explicit
# sync below still guarantee the script doesn't exit before data has
# actually reached the device.
dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync
sync

echo "Done. $DEVICE now boots the $IMAGE installer, which creates login user '$USERNAME' (wheel/sudo) during install."
