#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# flipper-btrfs.sh: shared helpers for the btrfs profile and snapshot tools. Sourced, never
# executed: the root and btrfs checks, the top-level (subvolid=5) mount, and what the tools
# would otherwise each carry a copy of. Functions read globals at call time.

[ -r /usr/lib/flipper-rootinfo.sh ] || { echo "Error: /usr/lib/flipper-rootinfo.sh not found" >&2; exit 1; }
. /usr/lib/flipper-rootinfo.sh

die() { echo "Error: $*" >&2; exit 1; }

need_root()  { [ "$(id -u)" -eq 0 ] || die "Must run as root (use sudo)"; }
need_btrfs() { command -v btrfs >/dev/null 2>&1 || die "Btrfs-progs not installed"; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "Command not installed: $1${2:+ ($2)}"; }
# For the -d/--device value, with the arg count left after shifting the flag off:
#   -d|--device) shift; need_device_arg "$#"; ROOTDEV=$1 ;;
need_device_arg() { [ "$1" -ge 1 ] || { echo "Error: --device needs an argument" >&2; usage >&2; exit 1; }; }

# True if / is a btrfs mount: a booted system, not a RAM recovery root.
root_is_btrfs() { [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; }

# The option lines the tools' usage() texts share, so the wording cannot drift.
HELP_YES="  -y,--yes    assume yes to prompts (non-interactive)"
HELP_DEVICE="  -d,--device operate on btrfs filesystem DEV instead of the booted root (e.g. recovery)"

# UUID of the filesystem being operated on, empty if blkid cannot say. Never the booted root's:
# under -d that is another filesystem.
target_fsuuid() { blkid -o value -s UUID "${ROOTDEV:-}" 2>/dev/null; }
target_partuuid() { blkid -o value -s PARTUUID "${ROOTDEV:-}" 2>/dev/null; }

# Set to 1 by -y/--yes or ASSUME_YES=1 in the environment.
ASSUME_YES=${ASSUME_YES:-0}

# Ask on stderr, read stdin; abort unless yes.
confirm() {
    if [ "$ASSUME_YES" = 1 ]; then printf '%s [auto-yes]\n' "$1" >&2; return 0; fi
    printf '%s [y/N] ' "$1" >&2
    read -r _a || die "Aborted"
    case "$_a" in y|Y|yes|YES) return 0 ;; *) die "Aborted" ;; esac
}

# Subvolumes the tools must never write, delete or rename.
is_reserved_subvol() {
    case "$1" in
        @|@home|@root|@snapshots|@stock-snapshots|@swap|@var-log|@var-cache|boot) return 0 ;;
        *) return 1 ;;
    esac
}

# A profile name that works in rootflags=subvol=: a leading '@' and only [A-Za-z0-9_-].
validate_profile_name() {
    case "$1" in
        *..*|/*|*/*) die "Invalid profile name: $1 (top-level name only, e.g. @Desktop-2)" ;;
    esac
    case "$1" in
        @?*) ;;
        *) die "Profile name must start with '@' (e.g. @Desktop-2): $1" ;;
    esac
    case "$1" in
        *[!@A-Za-z0-9_-]*) die "Profile name has symbols that are not allowed: $1 (use only letters, digits, '-', '_')" ;;
    esac
}

# The writers' lock: flock on FD 9 for the script's lifetime, holder recorded as "PID (tool)".
# Read-only tools do not take it, and native `btrfs` commands honour no lock.
LOCK_FILE=/run/flipper-btrfs.lock

# True if we are the opposite end of a pipe from $1. Sharing the same end does not count:
# siblings from one shell inherit the same stdin.
# $1 = pid
pipe_shared_with() {
    _out=$(readlink "/proc/$$/fd/1" 2>/dev/null || true)
    _in=$(readlink "/proc/$$/fd/0" 2>/dev/null || true)
    case "$_out" in pipe:*) [ "$_out" = "$(readlink "/proc/$1/fd/0" 2>/dev/null || true)" ] && return 0 ;; esac
    case "$_in" in pipe:*) [ "$_in" = "$(readlink "/proc/$1/fd/1" 2>/dev/null || true)" ] && return 0 ;; esac
    return 1
}

set_lock() {
    # <> keeps the holder line
    exec 9<>"$LOCK_FILE" || die "Cannot open lock $LOCK_FILE"
    if ! flock -w 0 9 2>/dev/null; then
        _h=$(cat "$LOCK_FILE" 2>/dev/null); [ -n "$_h" ] || _h="PID unknown"
        # A holder that is gone left a stale line after a crash.
        _hp=${_h#PID }; _hp=${_hp%% *}
        case "$_hp" in
            [0-9]*) kill -0 "$_hp" 2>/dev/null || _h="$_h, which is no longer running; the line is stale" ;;
        esac
        # A holder on the other end of our pipe is blocked on us and can never release.
        case "$_hp" in
            [0-9]*) if kill -0 "$_hp" 2>/dev/null && pipe_shared_with "$_hp"; then
                        die "$_h holds the lock and is on the other end of our pipe, so waiting would deadlock. Piping one of our tools into another on the same machine cannot work: write the stream to a file and read it back, or run one side on another host"
                    fi ;;
        esac
        echo "Another flipper-btrfs operation is in progress ($_h); waiting for it to finish..." >&2
        flock 9 || die "Cannot acquire lock $LOCK_FILE"
    fi
    printf 'PID %s (%s)\n' "$$" "${0##*/}" >"$LOCK_FILE" || true
    LOCK_HELD=1
}

# Drop the lock before a long read-only phase. Children inherited fd 9, so this only frees
# what we start afterwards.
release_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    ( : > "$LOCK_FILE" ) 2>/dev/null || true
    exec 9>&-
    LOCK_HELD=0
}

# Mount the btrfs top level (subvolid=5) at a temp dir, torn down on EXIT. Sets ROOTDEV and
# TOP. Temp files to remove with it go in TOP_TMPFILES first. ROOTDEV may be preset by -d.
mount_top() {
    # Armed first, so a die on the checks below still removes the caller's temp files.
    trap 'top_cleanup' EXIT
    # dash runs the EXIT trap on exit, not on a signal.
    trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
    [ -n "${ROOTDEV:-}" ] || ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
    [ -n "$ROOTDEV" ] || die "Cannot determine root device (use -d/--device)"
    [ -b "$ROOTDEV" ] || die "Not a block device: $ROOTDEV"
    # Not under /tmp: `rm -rf /tmp/tmp.*` while this is mounted recurses into the filesystem,
    # and rmdir deletes an empty subvolume. /run is tmpfs, root-only, swept by nobody.
    TOP=$(mktemp -d /run/flipper-btrfs.mnt.XXXXXX 2>/dev/null || mktemp -d)
    # -t btrfs, or every registered filesystem logs its refusal of `subvolid` first.
    _err=$(mount -t btrfs -o subvolid=5 "$ROOTDEV" "$TOP" 2>&1) || die "Mount failed: $_err"
}

# On a signal the children (btrfs send/receive, zstd) are still dying, so the first umount can
# lose to EBUSY. Retry, then detach lazily.
top_cleanup() {
    # Blank the holder line, which outlives the flock. In a subshell: a failed '>' on the
    # builtin ':' exits the shell before '|| true' can catch it.
    [ "${LOCK_HELD:-0}" = 1 ] && ( : > "$LOCK_FILE" ) 2>/dev/null || true
    if [ -n "${TOP:-}" ]; then
        for _i in 1 2 3 4 5; do
            umount "$TOP" 2>/dev/null && break
            # Under set -e a failing detach would abort the trap and abandon the mount.
            [ "$_i" = 5 ] && umount -l "$TOP" 2>/dev/null || true
            sleep 1
        done
        rmdir "$TOP" 2>/dev/null || true
    fi
    [ -n "${TOP_TMPFILES:-}" ] && rm -f $TOP_TMPFILES || true
    return 0
}

# A subvolume name to its top-relative path: as given, else under @snapshots or
# @stock-snapshots. Empty if none exists. Needs $TOP.
resolve_rel() {
    if   [ -e "$TOP/$1" ];                  then printf '%s' "$1"
    elif [ -e "$TOP/@snapshots/$1" ];       then printf '%s' "@snapshots/$1"
    elif [ -e "$TOP/@stock-snapshots/$1" ]; then printf '%s' "@stock-snapshots/$1"
    fi
}

# One field from `btrfs subvolume show` output. $1 = output text, $2 = key label.
get() { printf '%s\n' "$1" | awk -v k="$2" -F':[[:space:]]+' 'index($0,k){print $2; exit}'; }

subvol_id() { get "$(btrfs subvolume show "$1" 2>/dev/null)" "Subvolume ID"; }

# True only when the filesystem operated on is proven to be another than the booted one.
# Unprovable counts as the same, so the refusals below stay armed.
# needs ROOTDEV
target_fs_differs() {
    root_is_btrfs || return 0
    _bu=$(booted_fsuuid); _tu=$(target_fsuuid)
    [ -n "$_bu" ] && [ -n "$_tu" ] && [ "$_bu" != "$_tu" ]
}

# The running profile on the filesystem operated on, empty when nothing runs from it.
target_running_id()     { target_fs_differs && return 0; subvol_id / ; }
target_running_subvol() { target_fs_differs && return 0; booted_subvol ; }

# True if subvolume id $1 is the running profile's $2. An empty $2 never matches: '=' alone
# would pair it with any lookup that also came back empty.
# $1 = candidate id  $2 = target_running_id
is_running_id() {
    [ -n "$2" ] && [ "$1" = "$2" ]
}

# True if the subvolume at $1 is read-only.
is_ro() {
    case "$(btrfs subvolume show "$1" 2>/dev/null | awk -F':[[:space:]]+' '/Flags/{print $2}')" in
        *readonly*) return 0 ;; *) return 1 ;;
    esac
}

# The timestamp every generated name uses; list-profiles keys KIND=old off this shape.
stamp() { date +%Y-%m-%d_%H-%M-%S; }

# Top-relative path of the subvolume with this uuid, empty if none. $1 = top mount, $2 = uuid.
path_of_uuid() {
    case "$2" in ''|'-') return ;; esac
    btrfs subvolume list -u "$1" 2>/dev/null | awk -v u="$2" '
        { p=""; uu=""
          for (i=1;i<=NF;i++) { if($i=="uuid")uu=$(i+1); else if($i=="path"){p=$(i+1);for(j=i+2;j<=NF;j++)p=p" "$j} }
          if (uu==u){print p; exit} }'
}

# A byte count for a person, decimal: 1 GB is 10^9, as the sticker on the part says.
human() { numfmt --to=si --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%s' "${1:-0}"; }

# uuid -> "id <tab> path" for every subvolume. $1 = top, $2 = out file.
build_uuid_map() {
    btrfs subvolume list -qu "$1" 2>/dev/null | awk '
    {
        id=""; u=""; p=""
        for (i = 1; i <= NF; i++) {
            if      ($i == "ID")   id = $(i+1)
            else if ($i == "uuid") u  = $(i+1)
            else if ($i == "path") { p = $(i+1); for (j = i+2; j <= NF; j++) p = p" "$j; break }
        }
        if (u != "" && u != "-") print u"\t"id"\t"p
    }' > "$2"
}

# A parent UUID as "name (id)" via a build_uuid_map file. $1 = map file, $2 = uuid.
parent_of() {
    case "$2" in ''|'-') printf '%s' "-"; return ;; esac
    awk -F'\t' -v u="$2" '
        $1==u { n=$3; sub(/.*\//,"",n); printf "%s (%s)", n, $2; f=1 }
        END   { if (!f) printf "-" }' "$1"
}

# A TSV file with every column padded to its width, the last left unpadded.
align_table() {
    awk -F'\t' '
    { line[NR]=$0; nf=split($0,a,"\t"); for (i=1;i<=nf;i++) if (length(a[i])>w[i]) w[i]=length(a[i]) }
    END {
        for (r=1; r<=NR; r++) {
            n=split(line[r], a, "\t"); out=""
            # The width goes into the format: some mawk builds refuse "%-*s", and the boot
            # menu image carries one of them.
            for (i=1; i<=n; i++) out = (i<n) ? out sprintf("%-" w[i] "s  ", a[i]) : out a[i]
            print out
        }
    }' "$1"
}

# Run a flipper-bls.sh function against the filesystem operated on. In a subshell, so the
# library's die cannot abort us: the entry is never the point of the operation.
# $1 = what fails, for the warning; rest = function and arguments. Needs TOP
with_bls() {
    _what=$1; shift
    _lib=/usr/lib/flipper-bls.sh
    if [ -r "$_lib" ]; then
        ( ENTRIES="$TOP/boot/loader/entries"; TARGET_FSUUID="$(target_fsuuid)"; TARGET_PARTUUID="$(target_partuuid)"; . "$_lib"; "$@" ) \
            || echo "Warning: $_what" >&2
    else
        echo "Warning: $_lib not found; $_what" >&2
    fi
    return 0
}

# Stamp a _stock's origin marker (/etc/profile_origin), which snapshots inherit, so
# migrate-profile finds a profile's base by name after the parent chain is broken.
# $1 = the stock's mounted dir, $2 = the stock's name (e.g. @Desktop_744_stock).
stamp_stock_origin() {
    printf 'origin_stock_name=%s\n' "$2" > "$1/etc/profile_origin"
}

# Paths every running system writes for itself, identity and runtime state a new root makes
# anew, as anchored regexes one per line: check-profile does not count them as a change, and
# migrate-profile does not carry them as one (the identity among them it carries by policy).
RUNTIME_STATE='^etc/(machine-id|machine-info|hostname|ld\.so\.cache|\.updated)$
^etc/kernel/entry-token$
^etc/ssh/(ssh_host_.*|welcome_banner)$
^etc/avahi/services(/|$)
^var/\.updated$
^var/lib/dbus/machine-id$
^var/lib/systemd/(random-seed|timers|timesync|rfkill|catalog|coredump|pstore)(/|$)
^var/lib/(upower|NetworkManager)(/|$)
^var/(tmp|cache|log)(/|$)
^tmp(/|$)'

# A newline, to split the two-line output of one command run on two files.
NL='
'

# Sets WHY to how path $3 differs between roots $1 and $2, empty when it does not: added, removed,
# "type or mode", "link target" or content. Owner counts, timestamps and xattrs do not. One stat
# for both and no subshell of its own: a profile can have thousands of paths to check.
path_differs() {
    WHY=""
    _pd1="$1/$3"; _pd2="$2/$3"
    if [ ! -e "$_pd1" ] && [ ! -L "$_pd1" ]; then
        if [ -e "$_pd2" ] || [ -L "$_pd2" ]; then WHY=added; else WHY="gone from both"; fi
        return 0
    fi
    if [ ! -e "$_pd2" ] && [ ! -L "$_pd2" ]; then WHY=removed; return 0; fi
    _pdm=$(stat -c '%F %a %u %g' -- "$_pd1" "$_pd2")
    if [ "${_pdm%%"$NL"*}" != "${_pdm#*"$NL"}" ]; then WHY="type or mode"; return 0; fi
    case "$_pdm" in
        "symbolic link "*)
            _pdm=$(readlink -- "$_pd1" "$_pd2")
            [ "${_pdm%%"$NL"*}" = "${_pdm#*"$NL"}" ] || WHY="link target" ;;
        "regular "*)
            cmp -s "$_pd1" "$_pd2" || WHY=content ;;
    esac
    return 0
}
