#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-rootinfo.sh - identity of the booted root: its subvolume and its btrfs filesystem.
#
# SOURCED, never executed. Own file because flipper-bls.sh and flipper-btrfs.sh both need these
# and neither can source the other. Depends on findmnt and btrfs, on neither lib.

[ -n "${_FLIPPER_ROOTINFO:-}" ] && return 0
_FLIPPER_ROOTINFO=1

# The subvolume mounted at / (e.g. @Desktop), empty if there is none. findmnt cannot answer inside a
# chroot, so fall back to asking btrfs.
booted_subvol() {
    _cs=$(findmnt -nro FSROOT / 2>/dev/null | sed 's,^/,,')
    [ -n "$_cs" ] || _cs=$(btrfs subvolume show / 2>/dev/null | sed -n '1{s,^/*,,;s,[[:space:]]*$,,;p}')
    printf '%s' "$_cs"
}

# btrfs FS UUID of the mounted root, empty if unknown. Same reasoning as booted_subvol.
booted_fsuuid() {
    _fu=$(findmnt -nro UUID / 2>/dev/null)
    [ -n "$_fu" ] || _fu=$(btrfs filesystem show / 2>/dev/null | sed -n 's/.*[[:space:]]uuid:[[:space:]]*//p' | head -1)
    printf '%s' "$_fu"
}
