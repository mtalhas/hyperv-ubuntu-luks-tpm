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

SRC="$1"
OUT="$2"
STAGE="$3"
TREE="$(mktemp -d)"

# Read the exact options that reproduce this image's boot arrangement.
REPORT="$(xorriso -indev "$SRC" -report_el_torito as_mkisofs 2>/dev/null)"

# Turn the report into an argument list, keeping the quoting xorriso emits.
eval "ARGS=( $REPORT )"

# After we add files the image grows, so the saved start offset of the EFI
# partition no longer matches. Swap the fixed offset for the name based form so
# xorriso recomputes it, and drop the load size that went with the old offset.
NEWARGS=()
drop_next_loadsize=0
for a in "${ARGS[@]}"; do
  if [[ "$a" == --interval:appended_partition_2_start_*_size_*:all:: ]]; then
    NEWARGS+=( "--interval:appended_partition_2:all::" )
    drop_next_loadsize=1
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

# Copy out the original contents, apply our two changes.
xorriso -osirrox on -indev "$SRC" -extract / "$TREE"
chmod -R u+w "$TREE"
cp "$STAGE/grub.cfg" "$TREE/boot/grub/grub.cfg"
mkdir -p "$TREE/autoinstall"
cp "$STAGE/autoinstall/user-data" "$STAGE/autoinstall/meta-data" "$TREE/autoinstall/"

rm -f "$OUT"
xorriso -as mkisofs "${NEWARGS[@]}" -o "$OUT" "$TREE"
rm -rf "$TREE"
echo "ISO_BUILD_OK"
