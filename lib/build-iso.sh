#!/bin/bash
# Rebuilds an Ubuntu Server install image with our answer files baked in.
#
# It reads the original image's own boot layout, so it works across Ubuntu
# versions without any hardcoded offsets. The boot files are reused untouched,
# so Secure Boot still trusts them. Only the menu config and the answer files
# are added.
#
# Usage: build-iso.sh <source.iso> <output.iso> <stage-dir>
#   stage-dir must contain grub.cfg and autoinstall/user-data and autoinstall/meta-data
set -euo pipefail

SRC="${1:?source iso path required}"
OUT="${2:?output iso path required}"
STAGE="${3:?stage dir required}"

# Confirm the inputs exist before doing several minutes of work.
[ -f "$SRC" ] || { echo "ERROR: source iso not found: $SRC" >&2; exit 1; }
for f in "grub.cfg" "autoinstall/user-data" "autoinstall/meta-data"; do
  [ -f "$STAGE/$f" ] || { echo "ERROR: stage file missing: $STAGE/$f" >&2; exit 1; }
done

TREE="$(mktemp -d)"
# Always clean up the multi GB extracted tree, even on failure, so repeated runs
# do not fill the WSL disk.
trap 'rm -rf "$TREE"' EXIT

# Read the exact options that reproduce this image's boot arrangement.
REPORT="$(xorriso -indev "$SRC" -report_el_torito as_mkisofs 2>/dev/null)"

# Turn the report into an argument list, keeping the quoting xorriso emits. The
# report is produced by xorriso itself, so eval here is parsing trusted output.
# shellcheck disable=SC2294,SC2206
eval "ARGS=( $REPORT )"

# After we add files the image grows, so the saved start offset of the EFI
# partition no longer matches. Swap the fixed offset for the name based form so
# xorriso recomputes it, and drop the load size that went with the old offset.
NEWARGS=()
drop_next_loadsize=0
rewrote=0
for a in "${ARGS[@]}"; do
  if [[ "$a" == --interval:appended_partition_2_start_*_size_*:all:: ]]; then
    NEWARGS+=( "--interval:appended_partition_2:all::" )
    drop_next_loadsize=1
    rewrote=1
    continue
  fi
  if [[ "$drop_next_loadsize" == "1" && "$a" == "-boot-load-size" ]]; then
    drop_next_loadsize=2
    continue
  fi
  if [[ "$drop_next_loadsize" == "2" ]]; then
    drop_next_loadsize=0
    continue
  fi
  NEWARGS+=( "$a" )
done

# If the offset rewrite never matched, the xorriso report format has changed for
# this image. Building anyway would likely produce an image that does not boot,
# so stop with a clear message instead.
if [ "$rewrote" -ne 1 ]; then
  echo "ERROR: could not find the EFI partition offset in the boot report. This Ubuntu image or xorriso version may use a different layout. Build stopped to avoid producing an unbootable image." >&2
  exit 2
fi

# Copy out the original contents, apply our two changes.
xorriso -osirrox on -indev "$SRC" -extract / "$TREE"
chmod -R u+w "$TREE"
cp "$STAGE/grub.cfg" "$TREE/boot/grub/grub.cfg"
mkdir -p "$TREE/autoinstall"
cp "$STAGE/autoinstall/user-data" "$STAGE/autoinstall/meta-data" "$TREE/autoinstall/"

rm -f "$OUT"
xorriso -as mkisofs "${NEWARGS[@]}" -o "$OUT" "$TREE"

# Confirm the image was actually produced and is a sensible size.
if [ ! -f "$OUT" ]; then
  echo "ERROR: output image was not created." >&2
  exit 3
fi
echo "ISO_BUILD_OK"
