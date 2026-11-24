#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-bls.sh: the BLS boot-entry helpers, shared by the kernel-install plugin
# (90-loaderentry.install) and the profile tools (create-profile, rename-profile). Sourced,
# never executed; functions read globals at call time.
#
# The kernel/initrd staging and devicetree(dir) handling are derived from systemd's
# 90-loaderentry.install (LGPL-2.1-or-later).

[ -r /usr/lib/flipper-rootinfo.sh ] || { echo "flipper-bls: /usr/lib/flipper-rootinfo.sh not found" >&2; exit 1; }
. /usr/lib/flipper-rootinfo.sh
[ -r /usr/lib/flipper-blsname.sh ] || { echo "flipper-bls: /usr/lib/flipper-blsname.sh not found" >&2; exit 1; }
. /usr/lib/flipper-blsname.sh

VENDOR=rockchip
TITLE_MAX="${FLIPPER_TITLE_MAX:-26}"

log() { [ "${KERNEL_INSTALL_VERBOSE:-0}" -gt 0 ] && echo "flipper-bls: $*" >&2; return 0; }
die() { echo "flipper-bls: $*" >&2; exit 1; }
trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
stage_file() { install -m 0644 -o root -g root "$1" "$2" || die "could not copy '$1'"; }

# An absolute path under BOOT_ROOT as a BLS entry names it: relative to the boot partition,
# which is / here, since /boot is a subvolume on the root partition.
boot_rel() { if [ "${BOOT_MNT:-/}" = "/" ]; then printf '%s\n' "$1"; else printf '%s\n' "${1#"${BOOT_MNT}"}"; fi; }

has_config() { [ -f "$KCONFIG" ] && grep -q "^CONFIG_$1=[ym]" "$KCONFIG"; }

# The last rootflags=subvol= in an options string, empty if none.
subvol_of() { printf '%s' "$1" | tr ' ' '\n' | sed -n 's/^rootflags=subvol=//p' | tail -n1; }

# Where a new entry lands in the order. flipper-blsname.sh says what the key and counter mean;
# this is the half that reads the filesystem.

# The autoboot digit a profile's entries carry, or 1 for a profile with none: a kernel install
# joins the order, and exactly-one-zero is set-boot-order's business.
# $1 = subvol
profile_auto_digit() {
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        _a="$(sort_key_field "$_c" auto)"
        case "$_a" in 0|1) printf '%s' "$_a"; return 0 ;; esac
    done
    printf '1'
}

# Step every other entry of $1 down to rank 1, leaving $2 the profile's chosen kernel. Safe
# because the new entry carries a counter: three failed boots make it bad and the previous
# kernel leads again.
# $1 = subvol, $2 = the id that keeps rank 0
demote_others() {
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        [ "$(entry_id_of "$_c")" = "$2" ] && continue
        [ "$(sort_key_field "$_c" rank)" = 1 ] && continue
        restamp_entry "$_c" '-' 1 '-' "${OVERLAY_USER_ROOT:-}"
        log "stepped $(entry_id_of "$_c") down: $2 is newer"
    done
    return 0
}

# The sort-key for a new entry of $1 in filename band $2. An unmappable root gets band 999,
# so it can never become what boots by itself.
# $1 = subvol, $2 = filename band NN
entry_sort_key() {
    _b="$(sort_band "${2:-}")"; [ -n "$_b" ] || _b=999
    # Rank 0: the entry being written is the one its profile boots; demote_others does the rest.
    make_sort_key "$(profile_auto_digit "$1")" "$_b" "$1" "0"
}

# DTB_DIR and DTB_DIRS (primary dir, modules fallback) for $KERNEL_VERSION.
set_dtb_dirs() { DTB_DIR="/usr/lib/linux-image-$KERNEL_VERSION"; DTB_DIRS="$DTB_DIR /usr/lib/modules/$KERNEL_VERSION/dtb"; }

# Entry token for a root: <NN>-flipperos-<subvol sans @>; without NN plain flipperos-<name>.
# $1 = NN (may be empty)  $2 = subvol
make_token() {
    _n="$(printf '%s' "$2" | tr -d '@')"
    [ -n "$1" ] && printf '%s-flipperos-%s' "$1" "$_n" || printf 'flipperos-%s' "$_n"
}

# KERNEL_ENTRY and INITRD_ENTRIES for $KERNEL_VERSION: the profile's own copies under
# /usr/lib/modules/<ver>/ as /@<subvol>/... (U-Boot reads subvolid 5), else the /boot copies.
# $1 = subvol; $2 = its mounted root (default /).
resolve_kernel_paths() {
    _rk_root="${2:-/}"; [ "$_rk_root" = / ] && _rk_root=""
    _rk_um="/usr/lib/modules/$KERNEL_VERSION"
    _rk_pfx="$(fdt_prefix "rootflags=subvol=$1")"
    if   [ -f "$_rk_root$_rk_um/vmlinuz" ];        then KERNEL_ENTRY="$_rk_pfx$_rk_um/vmlinuz"
    elif [ -f "/boot/vmlinuz-$KERNEL_VERSION" ];   then KERNEL_ENTRY="$(boot_rel "/boot/vmlinuz-$KERNEL_VERSION")"
    elif [ -n "${TOP:-}" ] && [ -f "$TOP/boot/vmlinuz-$KERNEL_VERSION" ]; then KERNEL_ENTRY="/boot/vmlinuz-$KERNEL_VERSION"
    else echo "flipper-bls: no kernel image for $KERNEL_VERSION (looked in $_rk_um and /boot)" >&2; return 1; fi
    if   [ -f "$_rk_root$_rk_um/initrd" ];         then INITRD_ENTRIES="$_rk_pfx$_rk_um/initrd"
    elif [ -f "/boot/initrd.img-$KERNEL_VERSION" ];then INITRD_ENTRIES="$(boot_rel "/boot/initrd.img-$KERNEL_VERSION")"
    elif [ -n "${TOP:-}" ] && [ -f "$TOP/boot/initrd.img-$KERNEL_VERSION" ]; then INITRD_ENTRIES="/boot/initrd.img-$KERNEL_VERSION"
    else INITRD_ENTRIES=""; fi
}

# KCONFIG for has_config: the profile's own config, else /boot. $1 = mounted root (default /).
resolve_kconfig() {
    _kc_root="${1:-/}"; [ "$_kc_root" = / ] && _kc_root=""
    if [ -f "$_kc_root/usr/lib/modules/$KERNEL_VERSION/config" ]; then KCONFIG="$_kc_root/usr/lib/modules/$KERNEL_VERSION/config"
    else KCONFIG="/boot/config-$KERNEL_VERSION"; fi
}

# U-Boot reads the btrfs top level, so device tree paths in an entry are prefixed with the
# entry's own root subvolume, from its rootflags=subvol=. FDT_SUBVOL_PREFIX overrides.
# $1 = options string -> "/<rootflags-subvol>" (or $FDT_SUBVOL_PREFIX if set)
fdt_prefix() {
    if [ "${FDT_SUBVOL_PREFIX+x}" = x ]; then printf '%s' "$FDT_SUBVOL_PREFIX"; return 0; fi
    _sv=$(subvol_of "$1")
    [ -n "$_sv" ] && printf '/%s' "$_sv"
    return 0
}

# Remove the entries whose options select $1 and whose version is $2, by content, so other
# roots' entries are untouched. Uses $ENTRIES.
# $1 = subvol  $2 = version
remove_entries() {
    [ -n "$1" ] && [ -n "$2" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(awk '$1=="version"{print $2; exit}' "$_c")" = "$2" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        rm -f "$_c"
    done
    # A non-matching last entry must not fail the loop under set -e
    return 0
}

# Remove the entries of $1 whose kernel is not in the root mounted at $2. An entry loads its
# kernel from inside the root (/<subvol>/usr/lib/modules/<ver>/vmlinuz), so once the root is
# replaced by one with another kernel the entry can never boot. Uses $ENTRIES.
# $1 = subvol  $2 = mounted root
remove_dead_entries() {
    [ -n "$1" ] && [ -d "$2" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        _lx="$(awk '$1=="linux"{print $2; exit}' "$_c")"
        case "$_lx" in "/$1/"*) ;; *) continue ;; esac
        [ -e "$2/${_lx#"/$1/"}" ] && continue
        rm -f "$_c"; echo "removed boot entry $_c: its kernel is not in $1" >&2
    done
    return 0
}

# Remove every entry that selects $1, all versions, and each one's /boot/<token>/ staging
# tree, derived from the entry's own 'linux' line. For delete-profile and rename-profile.
# $1 = subvol
remove_root_entries() {
    [ -n "$1" ] || return 0
    for _c in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_c" ] || continue
        [ "$(entry_subvol_of "$_c")" = "$1" ] || continue
        _lx="$(awk '$1=="linux"{print $2; exit}' "$_c")"
        rm -f "$_c"; echo "removed boot entry $_c" >&2
        case "$_lx" in /boot/*/*/linux)
            _td="${_lx%/*/linux}"; [ "$_td" != /boot ] && rm -rf "$_td" ;;
        esac
    done
    return 0
}

# The profile list to read bands from: the target's own when it has one, else the running
# root's.
target_profiles() {
    if [ -f "${1:-}/etc/kernel/flipper-profiles" ]; then printf '%s' "$1/etc/kernel/flipper-profiles"
    else printf '%s' "${PROFILES:-/etc/kernel/flipper-profiles}"; fi
}

# The menu slot (900, 800, ...) of the listed profile that btrfs parent $1 belongs to: the
# exact name or its _stock/_<stamp>. A hyphen-suffixed clone (@Desktop-2) must not match, so
# origin_base_depth can walk through it. Empty if none.
profile_base_nn() {
    _want="$1"; _pf="${PROFILES:-/etc/kernel/flipper-profiles}"; [ -f "$_pf" ] || return 0
    _j=0
    while IFS='|' read -r _t _s _e _g _d _l; do
        _t="$(echo "$_t" | tr -d '[:space:]')"; case "$_t" in ''|\#*) continue ;; esac
        _sv="$(subvol_of "$_e" | tr -d '[:space:]')"
        [ -n "$_sv" ] && case "$_want" in "$_sv"|"$_sv"_*) printf '%03d' "$((900 - _j * 100))"; return 0 ;; esac
        _j=$((_j + 1))
    done <"$_pf"
    return 0
}

# "BASE DEPTH" for a derived root: walk the parent_uuid chain up from $1, counting hops, until
# an ancestor is a listed profile or its base. Empty if none maps. One `subvolume list` covers
# the filesystem, so ancestors need not be mounted.
# $1 = mounted path (default /)
origin_base_depth() {
    command -v btrfs >/dev/null 2>&1 || return 0
    _mp="${1:-/}"
    _cur="$(btrfs subvolume show "$_mp" 2>/dev/null | sed -n 's/.*[Pp]arent UUID:[[:space:]]*//p' | head -n1)"
    [ -n "$_cur" ] && [ "$_cur" != "-" ] || return 0
    # One row "uuid parent_uuid name" per subvolume
    _tbl="$(btrfs subvolume list -qu "$_mp" 2>/dev/null | awk '{ u="-"; p="-"; for(i=1;i<NF;i++){ if($i=="uuid")u=$(i+1); else if($i=="parent_uuid")p=$(i+1) } print u, p, $NF }')"
    _seen=" "; _depth=0
    while [ -n "$_cur" ] && [ "$_cur" != "-" ]; do
        # Cycle guard
        case "$_seen" in *" $_cur "*) break ;; esac
        _seen="$_seen$_cur "
        _row="$(printf '%s\n' "$_tbl" | awk -v u="$_cur" '$1==u{print $2, $3; exit}')"
        [ -n "$_row" ] || break
        _depth=$((_depth + 1))
        _pn="${_row#* }"; _pn="${_pn##*/}"
        _bn="$(profile_base_nn "$_pn")"
        [ -n "$_bn" ] && { printf '%s %s' "$_bn" "$_depth"; return 0; }
        # Follow parent_uuid to the grandparent
        _cur="${_row%% *}"
    done
    return 0
}

# Menu slot for a derived root: origin base plus clone depth. When the parent chain yields
# nothing (a dangling parent_uuid after a move or receive) the origin hint counts as depth 1.
# $1 = mounted path (default /); $2 = origin hint (optional)
clone_slot() {
    _cs_bd="$(origin_base_depth "${1:-/}")"
    if [ -n "$_cs_bd" ]; then
        printf '%03d' "$(( ${_cs_bd%% *} + ${_cs_bd#* } ))"; return 0
    fi
    if [ -n "${2:-}" ]; then
        _cs_b="$(profile_base_nn "${2##*/}")"
        [ -n "$_cs_b" ] && printf '%03d' "$(( _cs_b + 1 ))"
    fi
    return 0
}

# A title that fits the panel: the label whole, the version trimmed to TITLE_MAX.
make_title() {
    _suf="$1"
    _avail=$(( TITLE_MAX - ${#_suf} - 1 ))
    if [ "$_avail" -ge 1 ]; then
        printf '%s %s' "$_suf" "$(printf '%s' "$KERNEL_VERSION" | cut -c"1-$_avail")"
    else
        printf '%s' "$_suf" | cut -c"1-$TITLE_MAX"
    fi
}

# write_entry FILE TITLE OPTIONS FDTOVERLAYS. Nothing of ours goes on the command line: what
# booted is the running kernel plus the mounted subvolume, which name one entry.
write_entry() {
    _f="$1"; _title="$2"; _opts="$3"; _fdtov="$4"
    _dtdir=""; [ -n "$DEVICETREEDIR_REL" ] && _dtdir="$(fdt_prefix "$_opts")$DEVICETREEDIR_REL"
    {
        echo "# Boot Loader Specification type#1 entry (Flipper One)"
        echo "title      $_title"
        echo "version    $KERNEL_VERSION"
        [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && echo "machine-id $MACHINE_ID"
        [ -n "$SORT_KEY" ] && echo "sort-key   $SORT_KEY"
        [ -n "$_opts" ]  && echo "options    $_opts"
        echo "linux      $KERNEL_ENTRY"
        [ -n "$DEVICETREE_ENTRY" ] && echo "devicetree    $DEVICETREE_ENTRY"
        [ -n "$_dtdir" ]           && echo "devicetreedir $_dtdir"
        [ -n "$_fdtov" ]           && echo "devicetree-overlay $_fdtov"
        for _ird in $INITRD_ENTRIES; do echo "initrd     $_ird"; done
    } >"$_f"
    # Don't let a trailing empty conditional's status abort `set -e`
    return 0
}

# The paths of the named overlays, next to the DTBs; nothing and non-zero if one is missing.
# $1 = subvol prefix (e.g. /@Desktop); remaining args = overlay names
overlay_paths() {
    _pfx="$1"; shift
    _paths=""
    for _n in "$@"; do
        # Check the real on-disk path
        [ -f "$OVERLAY_DIR/$_n.dtbo" ] || return 1
        _paths="$_paths${_paths:+ }$_pfx$OVERLAY_DIR/$_n.dtbo"
    done
    printf '%s' "$_paths"
}

# The user's drop-in overlays: every *.dtbo under a root's /etc/kernel/dtbo. OVERLAY_USER_ROOT
# says whose ("" = the running root); the in-entry path is always the subvol-prefixed one.
OVERLAY_USER_PATH=/etc/kernel/dtbo
# $1 = subvol prefix (e.g. /@Desktop)
user_overlay_paths() {
    _udir="${OVERLAY_USER_ROOT:-}$OVERLAY_USER_PATH"
    [ -d "$_udir" ] || return 0
    _upaths=""
    for _uf in "$_udir"/*.dtbo; do
        # Unmatched glob -> skip
        [ -f "$_uf" ] || continue
        _upaths="$_upaths${_upaths:+ }$1$OVERLAY_USER_PATH/${_uf##*/}"
    done
    printf '%s' "$_upaths"
}

# BASE_OPTS from CONF_ROOT/cmdline plus this kernel's console layout: FIQ kernels get
# console=ttyFIQ0, mainline ttyS0 + ttyS4 + fbcon=map:1.
compute_base_opts() {
    # BusyBox grep has neither -G nor \s; a character class works in both.
    if [ -f "$CONF_ROOT/cmdline" ]; then
        BASE_OPTS="$(grep -v '^[[:space:]]*#' "$CONF_ROOT/cmdline" | tr -s '[:space:]' ' ')"
    elif [ -f /usr/lib/kernel/cmdline ]; then
        BASE_OPTS="$(grep -v '^[[:space:]]*#' /usr/lib/kernel/cmdline | tr -s '[:space:]' ' ')"
    else
        BASE_OPTS=""
    fi
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # A cmdline file that reads as nothing gives an entry with no root, and nothing would say why.
    if [ -z "$BASE_OPTS" ] && { [ -f "$CONF_ROOT/cmdline" ] || [ -f /usr/lib/kernel/cmdline ]; }; then
        echo "flipper-bls: the kernel cmdline file is present but read as empty" >&2
    fi
    # The shipped root=UUID / root=PARTUUID is the build's; the entry boots from this filesystem,
    # which under -d is not the running one.
    _fsuuid="${TARGET_FSUUID:-$(booted_fsuuid)}"
    [ -n "$_fsuuid" ] && BASE_OPTS="$(printf '%s' " $BASE_OPTS " | sed "s/ root=UUID=[^ ]*/ root=UUID=$_fsuuid/")"
    _partuuid="${TARGET_PARTUUID:-$(blkid -o value -s PARTUUID "$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')" 2>/dev/null || true)}"
    [ -n "$_partuuid" ] && BASE_OPTS="$(printf '%s' " $BASE_OPTS " | sed "s/ root=PARTUUID=[^ ]*/ root=PARTUUID=$_partuuid/")"
    BASE_OPTS="$(trim "$BASE_OPTS")"
    # systemd.machine_id= only when entries are named after the machine-id.
    if [ -n "$MACHINE_ID" ] && [ "$ENTRY_TOKEN" = "$MACHINE_ID" ] && ! echo "$BASE_OPTS" | grep -q "systemd.machine_id="; then
        BASE_OPTS="$BASE_OPTS systemd.machine_id=$MACHINE_ID"
    fi
    if [ -f /boot/firmware/cmdline.txt ] \
        || echo " $BASE_OPTS " | grep -q ' fbcon=map:99 ' \
        || { [ -r /proc/device-tree/compatible ] && tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null | grep -q 'raspberrypi'; }; then
        # Raspberry Pi CM0 / CardputerZero: preserve fbcon=map:99 (keep fbcon off /dev/fb_lcd)
        # and NEVER inject console=ttyS0 (14-pin LoRa+GNSS Cap UART).
        :
    elif has_config FIQ_DEBUGGER_CONSOLE; then
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyFIQ0,1500000n8"
    else
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS0,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyS4,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") console=ttyS4,1500000n8"
        BASE_OPTS="$(echo " $BASE_OPTS " | sed 's/ console=ttyFIQ0,1500000n8 / /g')"
        BASE_OPTS="$(trim "$BASE_OPTS") fbcon=map:1"
    fi
}

# DEVICETREEDIR_REL and OVERLAY_DIR for $KERNEL_VERSION (needs DTB_DIRS). Opt-in through an
# /etc/kernel/devicetreedir boolean when no single 'devicetree' is set; always the kernel's own
# installed DTB dir. A kernel shipping none gets no devicetreedir, and U-Boot falls back to
# its control FDT.
discover_devicetreedir() {
    DEVICETREEDIR_SRC=""; DEVICETREEDIR_REL=""
    if [ -z "${DEVICETREE:-}" ] && [ -f "$CONF_ROOT/devicetreedir" ]; then
        _v=""; read -r _v <"$CONF_ROOT/devicetreedir" || :
        case "$_v" in
            1|[Yy]|[Yy][Ee][Ss]|[Tt]|[Tt][Rr][Uu][Ee]|[Oo][Nn])
                for p in $DTB_DIRS; do
                    [ -d "$p" ] && { DEVICETREEDIR_SRC="$p"; break; }
                done
                if [ -n "$DEVICETREEDIR_SRC" ]; then
                    # /usr/lib/...; prefixed per entry
                    DEVICETREEDIR_REL="$(boot_rel "$DEVICETREEDIR_SRC")"
                else
                    log "$KERNEL_VERSION ships no DTB dir; omitting devicetreedir (U-Boot control FDT)"
                fi
                ;;
        esac
    fi
    # Overlays sit next to the .dtb files, in the vendor dir.
    OVERLAY_DIR="${DEVICETREEDIR_SRC:-$DTB_DIR}/$VENDOR"
}

# The devicetree-overlay value for an entry: profile overlays ($2, names) plus user drop-ins,
# prefixed from $1 (options). Empty if none.
dt_overlay_line() {
    _p="$(fdt_prefix "$1")"
    _o="$(overlay_paths "$_p" $2 2>/dev/null)" || _o=""
    _u="$(user_overlay_paths "$_p")"
    printf '%s' "$_o${_o:+${_u:+ }}$_u"
}

# The base profile of a derived root, from its /etc/profile_origin marker
# (origin_stock_name=@Desktop_959_stock -> @Desktop). Empty if unmarked.
# $1 = mounted path
origin_base_of() {
    _po="${1:-/}/etc/profile_origin"; [ -r "$_po" ] || return 0
    sed -n 's/^origin_stock_name=//p' "$_po" | head -n1 | sed 's/_[0-9]*_stock$//'
}

# The factory overlay names of the listed profile whose rootflags select $1, leading '!'
# stripped. Empty if not a listed profile.
# $1 = base subvol (e.g. @Desktop)
profile_dtbos_for() {
    _want="$1"; _pf="${PROFILES:-/etc/kernel/flipper-profiles}"; [ -f "$_pf" ] || return 0
    while IFS='|' read -r _t _s _e _g _d _l; do
        case "$_t" in ''|\#*) continue ;; esac
        if [ "$(subvol_of "$_e")" = "$_want" ]; then _d="$(trim "$_d")"; printf '%s' "${_d#\!}"; return 0; fi
    done <"$_pf"
    return 0
}

# The devicetree-overlay value for a new derived entry ($1 options, $2 source subvol, $3 dest
# mounted path): the source profile's system overlays re-pointed to this subvol, so a clone
# applies exactly what its source does; from the base profile's list when the source has no
# entry (a stock). User drop-ins come from the dest's own /etc/kernel/dtbo.
clone_overlay_line() {
    _clp="$(fdt_prefix "$1")"; _clsrc="$2"; _clsnap="$3"
    _clsys=""
    _clentry="$(grep -lE "rootflags=subvol=$_clsrc( |\$)" "$ENTRIES"/*.conf 2>/dev/null | sort | tail -n1)"
    if [ -n "$_clsrc" ] && [ -n "$_clentry" ]; then
        for _clo in $(sed -n 's/^devicetree-overlay[[:space:]]\{1,\}//p' "$_clentry" | head -n1); do
            # User drop-in: rescanned below
            case "$_clo" in *"$OVERLAY_USER_PATH/"*) continue ;; esac
            # Swap /@Source/ for this subvol
            _clsys="$_clsys${_clsys:+ }$_clp/${_clo#/*/}"
        done
    else
        _clbase="$(origin_base_of "$_clsnap")"
        if [ -n "$_clbase" ]; then
            _clsys="$(overlay_paths "$_clp" $(profile_dtbos_for "$_clbase") 2>/dev/null)" || _clsys=""
        fi
    fi
    _clusr="$(user_overlay_paths "$_clp")"
    printf '%s' "$_clsys${_clsys:+${_clusr:+ }}$_clusr"
}

# emit_entry SUF EXTRA GATE DTBOS [OVERLAY_LINE]: one entry for $ENTRY_TOKEN, named
# $ENTRY_TOKEN-$KERNEL_VERSION so the band leads and U-Boot's filename sort orders by band
# then version. A fifth argument is the overlay line verbatim; otherwise it is derived from
# DTBOS plus user drop-ins. GATE lists CONFIG_ symbols the kernel must have.
emit_entry() {
    _suf="$1"; _extra="$2"; _gate="$3"; _dtbos="$4"
    _ovl_override=0; [ $# -ge 5 ] && _ovl_override=1

    for _g in $_gate; do
        has_config "$_g" || { log "skip $ENTRY_TOKEN (CONFIG_$_g not set for $KERNEL_VERSION)"; return 0; }
    done

    _opts="$BASE_OPTS"
    [ -n "$_extra" ] && _opts="$_opts $_extra"
    # A new entry is untried, so it carries a full counter. Whatever this root has for this
    # kernel goes first, by content: a token can change under a profile, and two entries for
    # one kernel in one subvolume would stop a good boot from being blessed.
    _id="$ENTRY_TOKEN-$(printf '%s' "$KERNEL_VERSION" | tr '+' '_')"
    remove_entries "$(subvol_of "$_opts")" "$KERNEL_VERSION"
    _fn="$ENTRIES/$_id$(new_counter).conf"
    if [ "$_ovl_override" = 1 ]; then
        _line="$5"
    else
        # A leading '!' makes the profile overlays required: no entry without them.
        _required=0
        case "$_dtbos" in '!'*) _required=1; _dtbos="$(trim "${_dtbos#\!}")" ;; esac
        if [ "$_required" = 1 ] && [ -z "$(overlay_paths "$(fdt_prefix "$_opts")" $_dtbos 2>/dev/null)" ]; then
            log "skip $ENTRY_TOKEN (required overlays not found for $KERNEL_VERSION)"
            return 0
        fi
        _line="$(dt_overlay_line "$_opts" "$_dtbos")"
    fi
    write_entry "$_fn" "$(make_title "$_suf")" "$_opts" "$_line"
    # This entry is the profile's chosen kernel now, so the rest of its entries are not.
    demote_others "$(subvol_of "$_opts")" "$_id"
}

# flipper_write_entry <subvol> <mounted-path> [<origin-hint>]: an entry for an existing
# writable top-level subvolume (a restored snapshot or clone), pointing at its own kernel and
# initrd under /usr/lib/modules/<ver>/. Non-zero on a recoverable problem.
flipper_write_entry() {
    _name="$1"; _snap="$2"; _origin="${3:-}"
    { [ -n "$_name" ] && [ -d "$_snap" ]; } || { echo "flipper-bls: usage: flipper_write_entry <name> <mounted-path>" >&2; return 1; }
    ENTRIES="${ENTRIES:-/boot/loader/entries}"
    # The base cmdline belongs to the root being written, not to whatever is running; from a
    # recovery boot the entry otherwise came out with no root= at all.
    if [ -n "${KERNEL_INSTALL_CONF_ROOT:-}" ]; then CONF_ROOT="$KERNEL_INSTALL_CONF_ROOT"
    elif [ -f "$_snap/etc/kernel/cmdline" ]; then CONF_ROOT="$_snap/etc/kernel"
    else CONF_ROOT=/etc/kernel; fi
    MACHINE_ID=""; DEVICETREE=""; DEVICETREE_ENTRY=""
    # The version from the target's own tree, so modules and dtbs agree.
    KERNEL_VERSION="$(ls -1d "$_snap"/usr/lib/linux-image-* 2>/dev/null | sed 's,.*/linux-image-,,' | sort -V | tail -n1)"
    if [ -z "$KERNEL_VERSION" ]; then
        KERNEL_VERSION="$(ls -1d "$_snap"/usr/lib/modules/* 2>/dev/null | sed 's,.*/modules/,,' | sort -V | tail -n1)"
    fi
    [ -n "$KERNEL_VERSION" ] || { echo "flipper-bls: no kernel modules found inside $_name" >&2; return 1; }
    resolve_kconfig "$_snap"
    set_dtb_dirs
    SORT_KEY_OS="$(os_sort_key "$_snap")"
    # The profile list lives inside a profile; under -d the running root may have none.
    PROFILES="${PROFILES:-$(target_profiles "$_snap")}"
    _nn="$(clone_slot "$_snap" "$_origin")"
    ENTRY_TOKEN="$(make_token "$_nn" "$_name")"
    SORT_KEY="$(entry_sort_key "$_name" "$_nn")"
    mkdir -p "$ENTRIES" || { echo "flipper-bls: cannot create $ENTRIES" >&2; return 1; }
    compute_base_opts
    resolve_kernel_paths "$_name" "$_snap" || return 1
    DEVICETREEDIR_REL="/usr/lib/linux-image-$KERNEL_VERSION"
    OVERLAY_DIR="$DTB_DIR/$VENDOR"
    # Scan the TARGET root's drop-ins, not the running one
    OVERLAY_USER_ROOT="$_snap"
    # The root's own entry-token, so a later apt install in it lands in the same band.
    mkdir -p "$_snap/etc/kernel" && printf '%s\n' "$ENTRY_TOKEN" > "$_snap/etc/kernel/entry-token"
    # emit_entry clears whatever this root has for this kernel, whatever token it carries: a
    # re-created profile's snapshot depth moves the sort number, so a new entry would otherwise
    # land beside the old one.
    _ovl="$(clone_overlay_line "$BASE_OPTS rootflags=subvol=$_name" "$_origin" "$_snap")"
    remove_dead_entries "$_name" "$_snap"
    emit_entry "$(printf '%s' "$_name" | tr -d '@')" "rootflags=subvol=$_name" "" "" "$_ovl"
    echo "flipper-bls: wrote entry for $_name (kernel $KERNEL_VERSION, token $ENTRY_TOKEN)"
}

# Rewrite the devicetree-overlay line of the booted profile's entries from the profile
# overlays and /etc/kernel/dtbo, so a change takes effect next boot without a kernel-install.
#   $1 scope: "" = the running kernel's entry only, "all" = every kernel of this profile
flipper_rewrite_overlay() {
    _scope="${1:-}"
    [ "$(id -u)" -eq 0 ] || { echo "flipper-bls: must run as root (use sudo)" >&2; return 1; }
    # Defaults describe the running root; add-dtbo -d sets TARGET_SUBVOL and the roots first.
    ENTRIES="${ENTRIES:-${KERNEL_INSTALL_BOOT_ROOT:-/boot}/loader/entries}"
    CONF_ROOT="${CONF_ROOT:-${KERNEL_INSTALL_CONF_ROOT:-/etc/kernel}}"
    OVERLAY_USER_ROOT="${OVERLAY_USER_ROOT:-}"
    _sv="${TARGET_SUBVOL:-$(booted_subvol)}"
    [ -n "$_sv" ] || { echo "flipper-bls: cannot determine the booted subvol" >&2; return 1; }
    if [ -n "${TARGET_SUBVOL:-}" ]; then
        # No running kernel over there: the default scope is its newest, the one it boots.
        _run="$(ls -1d "$OVERLAY_USER_ROOT"/usr/lib/linux-image-* 2>/dev/null | sed 's,.*/linux-image-,,' | sort -V | tail -n1)"
        [ -n "$_run" ] || { echo "flipper-bls: no kernel found in $_sv" >&2; return 1; }
    else
        _run="$(uname -r)"
    fi

    _dtbos=""
    _pf="${FLIPPER_PROFILES:-$CONF_ROOT/flipper-profiles}"
    if [ -f "$_pf" ]; then
        while IFS='|' read -r _t _s _e _g _d _r; do
            case "$_t" in ''|\#*) continue ;; esac
            if [ "$(subvol_of "$(trim "$_e")")" = "$_sv" ]; then _dtbos="$(trim "${_d#\!}")"; break; fi
        done <"$_pf"
    fi

    _n=0
    for _f in "$ENTRIES"/*.conf; do
        [ -f "$_f" ] || continue
        _opts="$(sed -n 's/^options[[:space:]]*//p' "$_f")"
        [ "$(entry_subvol_of "$_f")" = "$_sv" ] || continue
        KERNEL_VERSION="$(sed -n 's/^version[[:space:]]*//p' "$_f")"
        [ -n "$KERNEL_VERSION" ] || continue
        [ "$_scope" = all ] || [ "$KERNEL_VERSION" = "$_run" ] || continue
        set_dtb_dirs; OVERLAY_DIR="$DTB_DIR/$VENDOR"
        _line="$(dt_overlay_line "$_opts" "$_dtbos")"
        sed -i '/^devicetree-overlay[[:space:]]/d' "$_f"
        [ -n "$_line" ] && printf 'devicetree-overlay %s\n' "$_line" >>"$_f"
        # The device tree this entry boots with changed, so the boot is on trial again.
        _f="$(rearm_entry "$_f")"
        _n=$((_n + 1)); echo "flipper-bls: updated ${_f##*/}"
    done
    [ "$_n" -gt 0 ] || { echo "flipper-bls: no matching entries for $_sv" >&2; return 1; }
    # Or btrfs holds the change in memory for up to `commit=` seconds, and a power cut
    # brings the old overlay back.
    sync
}
