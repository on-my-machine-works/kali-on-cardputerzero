# flipper-blsname.sh: what a BLS entry's name and sort-key mean. Sourced by flipper-bls.sh,
# set-boot-order and boot-profile. No die(), no log(), no dependencies: vocabulary, not a tool.
#
# What boots is the first entry in the order, and these two names carry all of it:
#
#   sort-key   debian-0100-Desktop-0
#              │      │└┬┘ └──┬──┘ └── rank:     0 = the profile's chosen kernel, 1 = its others
#              │      │ │     └─────── profile, as the entry token spells it
#              │      │ └───────────── band, ascending: 1000 - the filename band, so this order is
#              │      │                 the one the filenames already produce
#              │      └─────────────── autoboot: 0 for the profile that boots by itself, 1 for the
#              │                        rest; exactly one profile holds the 0
#              └────────────────────── the os-release id, which the BLS spec asks for and which it
#                                       allows to carry "an additional suffix"
#
#   file name  900-flipperos-Desktop-7.2.0-ga0d2d145deeb+2-1.conf
#              └──────────────┬──────────────────────┘ └┬┘
#                             │                         └── boot counter: tries left, tries done.
#                             │                              Absent = blessed, 0 left = bad.
#                             └──────────────────────────── the entry id: what boot-profile takes,
#                                                            unchanged by the counter
#
# The rank exists because the spec orders one key by `version` descending, and git-describe
# versions like 7.2.0-00249-g26619ffca0bd and 7.2.0-ga0d2d145deeb do not compare.

# Attempts a newly armed entry gets: systemd's default. U-Boot's bls bootmeth does no
# counting, so the counter is read and spent by our tools alone.
BLS_TRIES="${FLIPPER_BLS_TRIES:-3}"

# The oldest kernel worth choosing, major.minor: the floor the boot menu hides entries below.
# Lowered to 6.6 on CardputerZero so Raspberry Pi CM0 6.6/6.12 LTS kernels are shown while
# still hiding legacy 6.1 BSP entries.
BLS_MIN_KERNEL="${FLIPPER_BLS_MIN_KERNEL:-6.6}"

# A kernel release as a sortable number: major, minor, patch, five digits each. Only the
# numbers before the first dash count; the git-describe suffix does not compare. No numbers
# ranks 0, behind every real release.
# $1 = version
version_rank() {
    _v="${1%%[-+]*}"
    case "$_v" in
        *.*.*) _a="${_v%%.*}"; _r="${_v#*.}"; _b="${_r%%.*}"; _c="${_r#*.}"; _c="${_c%%.*}" ;;
        *.*)   _a="${_v%%.*}"; _b="${_v#*.}"; _b="${_b%%.*}"; _c=0 ;;
        *)     _a="$_v"; _b=0; _c=0 ;;
    esac
    case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
    case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    printf '%05d%05d%05d' "$_a" "$_b" "$_c"
}

# Whether a release is $2 (major.minor, default $BLS_MIN_KERNEL) or newer. True for one that
# does not parse: showing one kernel too many is the safer mistake.
# $1 = version, $2 = min (optional)
version_at_least() {
    _v="${1%%-*}"; _m="${2:-$BLS_MIN_KERNEL}"
    _vmaj="${_v%%.*}"; _vrest="${_v#*.}"; _vmin="${_vrest%%.*}"
    case "$_vmaj" in ''|*[!0-9]*) return 0 ;; esac
    case "$_vmin" in ''|*[!0-9]*) _vmin=0 ;; esac
    _mmaj="${_m%%.*}"; _mmin="${_m#*.}"; _mmin="${_mmin%%.*}"
    case "$_mmin" in ''|*[!0-9]*) _mmin=0 ;; esac
    [ "$_vmaj" -gt "$_mmaj" ] && return 0
    [ "$_vmaj" -lt "$_mmaj" ] && return 1
    [ "$_vmin" -ge "$_mmin" ]
}

# Names.

# The entry id: the file name without counter or suffix, stable across attempts.
# $1 = a path or file name
entry_id_of() {
    _e="${1##*/}"; _e="${_e%.conf}"; printf '%s' "${_e%%+*}"
}

# The boot counter as named ("+2-1"), or empty for a blessed entry.
# $1 = a path or file name
entry_counter_of() {
    _e="${1##*/}"; _e="${_e%.conf}"
    case "$_e" in *+*) printf '%s' "+${_e#*+}" ;; esac
    return 0
}

# Tries left, or empty without a counter. Zero is 'bad': sorts last, still bootable by name.
# $1 = a path or file name
entry_tries_of() {
    _c="$(entry_counter_of "$1")"; [ -n "$_c" ] || return 0
    _c="${_c#+}"; printf '%s' "${_c%%-*}"
}

# A fresh counter: every try, none done. The done half is written so the width never changes.
new_counter() { printf '+%s-0' "$BLS_TRIES"; }

# Every file belonging to an id, whatever counter it carries. Needs $ENTRIES.
# $1 = id
entry_files_for() {
    for _f in "${ENTRIES:-/boot/loader/entries}/$1.conf" "${ENTRIES:-/boot/loader/entries}/$1"+*.conf; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
    return 0
}

# The subvolume an entry mounts: the one fact that ties an entry to a profile, since names
# and ids repeat across filesystems.
# $1 = entry file
entry_subvol_of() {
    awk '$1=="options"{for(i=2;i<=NF;i++) if($i ~ /^rootflags=subvol=/) s=$i}
         END{sub(/^rootflags=subvol=/,"",s); sub(/,.*/,"",s); print s}' "$1" 2>/dev/null
}

# Put an entry back on trial with a full counter: what it boots has changed, and a kernel
# proven with one device tree is not proven with another. Prints the resulting path.
# $1 = entry file
rearm_entry() {
    _id="$(entry_id_of "$1")"; _dir="${1%/*}"
    _new="$_dir/$_id$(new_counter).conf"
    [ "$1" = "$_new" ] || mv -f "$1" "$_new"
    printf '%s' "$_new"
}

# Count one attempt: tries left down, tries done up. Prints the resulting path. A blessed
# entry and one already at zero are left alone.
# $1 = entry file
decrement_entry() {
    _c="$(entry_counter_of "$1")"
    if [ -z "$_c" ]; then printf '%s' "$1"; return 0; fi
    _c="${_c#+}"; _left="${_c%%-*}"; _done="${_c#*-}"
    # "+3" with no second number
    case "$_done" in "$_left") _done=0 ;; esac
    if [ "$_left" -le 0 ] 2>/dev/null; then printf '%s' "$1"; return 0; fi
    _id="$(entry_id_of "$1")"; _dir="${1%/*}"
    _new="$_dir/$_id+$((_left - 1))-$((_done + 1)).conf"
    mv -f "$1" "$_new" || { printf '%s' "$1"; return 1; }
    printf '%s' "$_new"
}

# The boot order, one path per line, first line boots. flipctl implements the same rule:
#   1. a kernel below the floor sorts after everything else: the menu does not show it
#   2. no tries left sorts after everything else     (the spec)
#   3. sort-key ascending                            (the spec)
#   4. kernel version descending, as far as it compares
#   5. newest file first, separating two builds of one version
#   6. file name descending                          (the spec's last resort)
sorted_entries() {
    for _f in "${ENTRIES:-/boot/loader/entries}"/*.conf; do
        [ -f "$_f" ] || continue
        _ver="$(sed -n 's/^version[[:space:]]\{1,\}//p' "$_f" | head -n1)"
        _old=0; version_at_least "$_ver" || _old=1
        _bad=0; [ "$(entry_tries_of "$_f")" = 0 ] && _bad=1
        printf '%s|%s|%s|%s|%s|%s\n' \
            "$_old" \
            "$_bad" \
            "$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$_f" | head -n1)" \
            "$(version_rank "$_ver")" \
            "$(stat -c %Y "$_f" 2>/dev/null || echo 0)" \
            "$_f"
    done | sort -t'|' -k1,1n -k2,2n -k3,3 -k4,4r -k5,5nr -k6,6r | cut -d'|' -f6-
    return 0
}

# Keys.

# Sort-key prefix from os-release (IMAGE_ID, else ID) of the target root $1 (default /),
# never the running one: under -d or in recovery that would be another image's name.
os_sort_key() {
    _osr="${1:-}/etc/os-release"
    [ -r "$_osr" ] || return 0
    ( . "$_osr"; printf '%s' "${IMAGE_ID:-$ID}" ) || :
}

# Sort band from a filename band: 1000 minus the profile slot, clone depth added back, so a
# clone sits just after its profile rather than before it. Bands step by 100, depth is below:
#     900 -> 100    Desktop            901 -> 101    a clone of Desktop
#     800 -> 200    TV Media Box       802 -> 202    a clone of a clone of TV Media Box
sort_band() {
    [ -n "${1:-}" ] || return 0
    _slot=$(( $1 - $1 % 100 )); _depth=$(( $1 % 100 ))
    printf '%03d' "$(( 1000 - _slot + _depth ))"
}

# The band digits leading a token or id (900-flipperos-Desktop -> 900), or empty.
# $1 = entry token or id
token_band() {
    case "${1%%-*}" in ''|*[!0-9]*) ;; *) printf '%s' "${1%%-*}" ;; esac
    return 0
}

# Compose a sort-key. $1 = autoboot digit, $2 = sort band, $3 = profile name (@ stripped),
# $4 = rank digit. $SORT_KEY_OS leads it when set.
make_sort_key() {
    _n="$(printf '%s' "$3" | tr -d '@')"
    [ -n "${SORT_KEY_OS:-}" ] && printf '%s-' "$SORT_KEY_OS"
    printf '%s%s-%s-%s' "$1" "$2" "$_n" "$4"
}

# Edit an entry file in place without moving its mtime, which the order breaks ties by. Kept
# through a copy, since `touch -d @sec` is GNU-only and this also runs under BusyBox.
# $1 = entry file, rest = sed expressions
edit_entry() {
    _f=$1; shift
    _ref="$_f.order-ref"
    cp -p "$_f" "$_ref" 2>/dev/null || _ref=""
    for _x in "$@"; do sed -i "$_x" "$_f"; done
    [ -n "$_ref" ] && { touch -r "$_ref" "$_f"; rm -f "$_ref"; }
    return 0
}

# Write one entry's sort-key in place.
# $1 = entry file, $2 = key
set_sort_key() {
    if grep -q '^sort-key[[:space:]]' "$1"; then
        edit_entry "$1" "s|^sort-key[[:space:]].*|sort-key   $2|"
    else
        edit_entry "$1" "1a sort-key   $2"
    fi
}

# Rewrite one entry's key, keeping every field passed as '-'. A key without our suffix is
# stamped from scratch, which repairs entries from before the order. The band may be given
# too, since a stamp made under an older rule has to be recomputed rather than believed.
# $5 is the root whose os-release names the key; without it the key gets no os prefix.
# $1 = file, $2 = auto or '-', $3 = rank or '-', $4 = band or '-', $5 = os root
restamp_entry() {
    _f=$1
    _a="$(sort_key_field "$_f" auto)"; _b="$(sort_key_field "$_f" band)"; _r="$(sort_key_field "$_f" rank)"
    _sv="$(entry_subvol_of "$_f")"
    [ "${4:--}" = '-' ] || _b=$4
    [ -n "$_b" ] || _b="$(sort_band "$(token_band "$(entry_id_of "$_f")")")"
    [ -n "$_b" ] || _b=999
    [ -n "$_a" ] || _a=1
    [ -n "$_r" ] || _r=1
    [ "$2" = '-' ] || _a=$2
    [ "$3" = '-' ] || _r=$3
    SORT_KEY_OS="$(os_sort_key "${5:-}")"
    set_sort_key "$_f" "$(make_sort_key "$_a" "$_b" "$_sv" "$_r")"
}

# One field of a sort-key ('auto', 'band', 'rank'), or empty. The rank is the last field; the
# autoboot digit and band are found by shape (one digit of 0 or 1 followed by three more),
# since profile names and os ids carry dashes of their own.
# $1 = entry file, $2 = field
sort_key_field() {
    _k="$(sed -n 's/^sort-key[[:space:]]\{1,\}//p' "$1" 2>/dev/null | head -n1)"
    [ -n "$_k" ] || return 0
    case "$2" in
        rank) printf '%s' "${_k##*-}" ;;
        auto|band)
            _ab="$(printf '%s' "$_k" | awk -F- '{ for (i = 1; i <= NF; i++)
                       if ($i ~ /^[01][0-9][0-9][0-9]$/) { print $i; exit } }')"
            [ -n "$_ab" ] || return 0
            case "$2" in
                auto) printf '%s' "$_ab" | cut -c1 ;;
                band) printf '%s' "$_ab" | cut -c2-4 ;;
            esac
            ;;
    esac
    return 0
}

# Sync Raspberry Pi CM0 /boot/firmware/cmdline.txt rootflags=subvol=@... to the winning
# entry at the head of sorted_entries (only when operating on the live booted filesystem).
sync_rpi_cmdline_autoboot() {
    if command -v target_fs_differs >/dev/null 2>&1 && target_fs_differs; then
        return 0
    fi
    _top_entry="$(sorted_entries | head -n1)"
    [ -n "$_top_entry" ] && [ -f "$_top_entry" ] || return 0
    _win_sv="$(entry_subvol_of "$_top_entry")"
    [ -n "$_win_sv" ] || return 0
    for _cmdf in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        if [ -w "$_cmdf" ] && grep -q 'rootfstype=btrfs' "$_cmdf" 2>/dev/null; then
            if grep -q 'rootflags=' "$_cmdf"; then
                sed -i -E "s/subvol=@[^ ,]+/subvol=$_win_sv/g" "$_cmdf"
            else
                sed -i -E "s/(rootfstype=btrfs)/\1 rootflags=subvol=$_win_sv/" "$_cmdf"
            fi
            break
        fi
    done
    return 0
}
