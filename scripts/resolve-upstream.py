#!/usr/bin/env python3
"""
resolve-upstream.py — Upstream package, firmware, and driver resolver.

1. Resolves Kali, Raspberry Pi, and Debian APT packages dynamically from
   InRelease-verified Packages.gz indices (including transitive libcamera
   runtime dependencies).
2. Resolves M5Stack CardputerZero upstream components (pi-gen kernel manifest
   and configs, m5stack-linux-dtoverlays, APPLaunch, and hardware app .debs)
   with validation and per-component fallback to upstream.lock.json.
3. Emits resolved-env.sh and resolved-lock.json for build-kali-cardputerzero.sh.
"""

import argparse
import copy
import gzip
import hashlib
import importlib.util
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

KALI_MIRROR = os.environ.get("KALI_MIRROR", "https://kali.download/kali").rstrip("/")
RPI_MIRROR = "https://archive.raspberrypi.com/debian"
DEBIAN_MIRROR = "https://deb.debian.org/debian"
M5_APT_MIRROR = "https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/packages"

RPI_BSP_PKGS = [
    "raspi-firmware",
    "firmware-brcm80211",
    "bluez-firmware",
    "pi-bluetooth",
    "raspberrypi-sys-mods",
    "raspi-utils-core",
    "raspi-utils-dt",
    "libgpiolib0",
    "libdtovl0",
]

CAMERA_TRANSITIVE_PREFIXES = (
    "libcamera",
    "libpisp",
    "libtensorflow-lite",
    "libboost-",
    "libabsl",
)


def log(msg: str) -> None:
    print(f"[*] [resolver] {msg}", file=sys.stderr)


def ok(msg: str) -> None:
    print(f"[+] [resolver] {msg}", file=sys.stderr)


def warn(msg: str, warnings_file: Path | None = None) -> None:
    print(f"[!] [resolver] {msg}", file=sys.stderr)
    if warnings_file is not None:
        warnings_file.parent.mkdir(parents=True, exist_ok=True)
        with warnings_file.open("a", encoding="utf-8") as f:
            f.write(f"- {msg}\n")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def github_token() -> str:
    for k in ("GITHUB_TOKEN", "GH_TOKEN"):
        v = os.environ.get(k, "").strip()
        if v:
            return v
    if shutil.which("gh"):
        try:
            out = subprocess.check_output(["gh", "auth", "token"], stderr=subprocess.DEVNULL, text=True).strip()
            if out:
                return out
        except Exception:
            pass
    return ""


def http_get(url: str, headers: dict | None = None, retries: int = 3, timeout: int = 90) -> bytes:
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmp_path = Path(tf.name)
    try:
        cmd = [
            "curl", "-fsSL",
            "--retry", str(retries),
            "--retry-all-errors",
            "--connect-timeout", "15",
            "--max-time", str(timeout),
            "--speed-limit", "4096",
            "--speed-time", "20",
            "-o", str(tmp_path),
        ]
        if headers:
            for k, v in headers.items():
                cmd.extend(["-H", f"{k}: {v}"])
        cmd.append(url)
        p = subprocess.run(cmd, capture_output=True)
        if p.returncode != 0:
            err_txt = p.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"GET {url} failed: {err_txt}")
        return tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)


def download_file(url: str, dest: Path, expected_sha256: str | None = None, headers: dict | None = None) -> str:
    if dest.exists() and expected_sha256:
        if sha256_file(dest) == expected_sha256.lower():
            return expected_sha256.lower()
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    part.unlink(missing_ok=True)

    cmd = [
        "curl", "-fsSL",
        "--retry", "4",
        "--retry-all-errors",
        "--connect-timeout", "20",
        "--max-time", "300",
        "--speed-limit", "4096",
        "--speed-time", "20",
        "-o", str(part),
    ]
    if headers:
        for k, v in headers.items():
            cmd.extend(["-H", f"{k}: {v}"])
    cmd.append(url)

    p = subprocess.run(cmd, capture_output=True)
    if p.returncode != 0:
        part.unlink(missing_ok=True)
        err_txt = p.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Download {url} failed: {err_txt}")

    actual = sha256_file(part)
    if expected_sha256 and actual != expected_sha256.lower():
        part.unlink(missing_ok=True)
        raise RuntimeError(f"SHA256 mismatch for {url}: got {actual}, expected {expected_sha256}")
    part.replace(dest)
    return actual


def _dpkg_char_order(c: str) -> int:
    if c == "~":
        return -1
    if not c:
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _dpkg_cmp_part(a: str, b: str) -> int:
    ia, ib = 0, 0
    na, nb = len(a), len(b)
    while ia < na or ib < nb:
        while (ia < na and not a[ia].isdigit()) or (ib < nb and not b[ib].isdigit()):
            ca = a[ia] if (ia < na and not a[ia].isdigit()) else ""
            cb = b[ib] if (ib < nb and not b[ib].isdigit()) else ""
            oa, ob = _dpkg_char_order(ca), _dpkg_char_order(cb)
            if oa != ob:
                return 1 if oa > ob else -1
            if ca:
                ia += 1
            if cb:
                ib += 1
        sa = ia
        while ia < na and a[ia].isdigit():
            ia += 1
        sb = ib
        while ib < nb and b[ib].isdigit():
            ib += 1
        va = int(a[sa:ia]) if ia > sa else 0
        vb = int(b[sb:ib]) if ib > sb else 0
        if va != vb:
            return 1 if va > vb else -1
    return 0


def _dpkg_split_ver(v: str) -> tuple[int, str, str]:
    epoch = 0
    if ":" in v:
        ep, v = v.split(":", 1)
        epoch = int(ep or "0")
    if "-" in v:
        up, rev = v.rsplit("-", 1)
    else:
        up, rev = v, "0"
    return epoch, up, rev


def dpkg_ver_gt(v1: str, v2: str) -> bool:
    if v1 == v2:
        return False
    e1, u1, r1 = _dpkg_split_ver(v1)
    e2, u2, r2 = _dpkg_split_ver(v2)
    if e1 != e2:
        return e1 > e2
    c = _dpkg_cmp_part(u1, u2)
    if c != 0:
        return c > 0
    return _dpkg_cmp_part(r1, r2) > 0


def load_apt_index(
    base_url: str,
    dist: str,
    components: list[str],
    arch: str = "arm64",
    cache_dir: Path | None = None,
) -> dict[str, dict]:
    """Fetch InRelease, verify Packages.{xz,gz} SHA256 against InRelease, and return newest stanza per package."""
    inrel_url = f"{base_url}/dists/{dist}/InRelease"
    inrel_txt = http_get(inrel_url).decode("utf-8", errors="replace")

    by_hash = False
    sha_table: dict[str, str] = {}
    in_sha256 = False
    for line in inrel_txt.splitlines():
        if line.startswith("Acquire-By-Hash:") and "yes" in line.lower():
            by_hash = True
        if line.startswith("SHA256:"):
            in_sha256 = True
            continue
        if in_sha256:
            if not line.startswith(" "):
                in_sha256 = False
                continue
            parts = line.split()
            if len(parts) == 3:
                sha_table[parts[2]] = parts[0].lower()

    pkgs: dict[str, dict] = {}
    for comp in components:
        rel_xz = f"{comp}/binary-{arch}/Packages.xz"
        rel_gz = f"{comp}/binary-{arch}/Packages.gz"
        if rel_xz in sha_table:
            rel_path, exp_sha, is_xz = rel_xz, sha_table[rel_xz], True
        elif rel_gz in sha_table:
            rel_path, exp_sha, is_xz = rel_gz, sha_table[rel_gz], False
        else:
            continue

        urls = [f"{base_url}/dists/{dist}/{rel_path}"]
        if by_hash:
            urls.insert(0, f"{base_url}/dists/{dist}/{comp}/binary-{arch}/by-hash/SHA256/{exp_sha}")

        raw_bytes = None
        if cache_dir is not None:
            idx_dest = cache_dir / "indices" / f"{exp_sha}{'.xz' if is_xz else '.gz'}"
            for u in urls:
                try:
                    download_file(u, idx_dest, exp_sha)
                    raw_bytes = idx_dest.read_bytes()
                    break
                except Exception:
                    continue
        if raw_bytes is None:
            for u in urls:
                try:
                    b = http_get(u, timeout=180)
                    if hashlib.sha256(b).hexdigest() == exp_sha:
                        raw_bytes = b
                        break
                except Exception:
                    continue
        if raw_bytes is None:
            raise RuntimeError(f"APT index download/SHA256 verification failed for {base_url}/dists/{dist}/{rel_path}")

        text = (lzma.decompress(raw_bytes) if is_xz else gzip.decompress(raw_bytes)).decode("utf-8", errors="replace")
        for stanza in text.split("\n\n"):
            if not stanza.strip():
                continue
            entry: dict[str, str] = {}
            cur_key = None
            for l in stanza.splitlines():
                if l.startswith((" ", "\t")) and cur_key:
                    entry[cur_key] += " " + l.strip()
                elif ":" in l:
                    k, v = l.split(":", 1)
                    cur_key = k.strip()
                    entry[cur_key] = v.strip()
            name = entry.get("Package")
            ver = entry.get("Version")
            fn = entry.get("Filename")
            sha = entry.get("SHA256")
            if not (name and ver and fn and sha):
                continue
            prev = pkgs.get(name)
            if prev is None or dpkg_ver_gt(ver, prev["Version"]):
                entry["BaseURL"] = base_url
                pkgs[name] = entry
    return pkgs


def load_m5_apt_index() -> dict[str, dict]:
    """Optional fallback index from M5Stack's Aliyun OSS APT repository."""
    try:
        raw = http_get(f"{M5_APT_MIRROR}/dists/stable/main/binary-arm64/Packages", retries=2, timeout=25)
        text = raw.decode("utf-8", errors="replace")
        pkgs: dict[str, dict] = {}
        for stanza in text.split("\n\n"):
            entry: dict[str, str] = {}
            for l in stanza.splitlines():
                if ":" in l and not l.startswith(" "):
                    k, v = l.split(":", 1)
                    entry[k.strip()] = v.strip()
            name, ver, fn, sha = entry.get("Package"), entry.get("Version"), entry.get("Filename"), entry.get("SHA256")
            if name and ver and fn and sha:
                prev = pkgs.get(name)
                if prev is None or dpkg_ver_gt(ver, prev["Version"]):
                    entry["BaseURL"] = M5_APT_MIRROR
                    pkgs[name] = entry
        return pkgs
    except Exception:
        return {}


def gh_api_json(url: str, token: str):
    headers = {"Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return json.loads(http_get(url, headers=headers, retries=3, timeout=30).decode("utf-8"))


def validate_deb_file(deb_path: Path) -> tuple[bool, str]:
    if not deb_path.exists():
        return False, "missing file"
    p = subprocess.run(["dpkg-deb", "-f", str(deb_path), "Package", "Version", "Architecture"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return False, "corrupt .deb archive"
    arch = subprocess.check_output(["dpkg-deb", "-f", str(deb_path), "Architecture"], text=True).strip()
    if arch not in ("arm64", "all"):
        return False, f"unexpected Architecture '{arch}'"
    return True, "ok"


def load_launcher_patcher(script_dir: Path):
    spec = importlib.util.spec_from_file_location(
        "configure_kali_launcher", script_dir / "configure-kali-launcher.py"
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod.patch_applaunch_elf64


def dry_run_applaunch_patch(deb_path: Path, script_dir: Path) -> tuple[bool, str]:
    patch_fn = load_launcher_patcher(script_dir)
    with tempfile.TemporaryDirectory() as td:
        tdir = Path(td)
        subprocess.check_call(["dpkg-deb", "-x", str(deb_path), str(tdir)])
        elf = tdir / "usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch"
        if not elf.exists():
            return False, "M5CardputerZero-APPLaunch binary missing in package"
        try:
            patch_fn(elf)
            return True, "ok"
        except Exception as e:
            return False, str(e)


def detect_camera_libcamera_pkg(camera_deb: Path, rpi_pkgs: dict[str, dict]) -> str:
    """Inspect camera_app's DT_NEEDED strings to pick matching libcamera0.x package."""
    try:
        with tempfile.TemporaryDirectory() as td:
            subprocess.check_call(["dpkg-deb", "-x", str(camera_deb), td])
            cam_bin = Path(td) / "usr/bin/camera_app"
            if cam_bin.exists():
                out = subprocess.check_output(["strings", str(cam_bin)], text=True, errors="replace")
                m = re.search(r"libcamera\.so\.(\d+\.\d+)", out)
                if m:
                    candidate = f"libcamera{m.group(1)}"
                    if candidate in rpi_pkgs:
                        return candidate
    except Exception:
        pass
    for name in sorted(rpi_pkgs.keys(), reverse=True):
        if re.fullmatch(r"libcamera\d+\.\d+", name):
            return name
    return "libcamera0.7"


def resolve_camera_runtime_debs(root_pkg: str, rpi_pkgs: dict[str, dict], deb_pkgs: dict[str, dict]) -> list[dict]:
    """Transitively resolve isolated RPi libcamera + libpisp + tflite + boost + absl .debs."""
    selected: dict[str, dict] = {}
    queue = [root_pkg, "libcamera-ipa"]
    while queue:
        pkg = queue.pop(0)
        if pkg in selected:
            continue
        stanza = rpi_pkgs.get(pkg) or deb_pkgs.get(pkg)
        if not stanza:
            continue
        selected[pkg] = stanza
        deps_raw = stanza.get("Depends", "")
        for group in deps_raw.split(","):
            first_alt = group.strip().split("|")[0].strip()
            dep_name = re.split(r"[\s(:]", first_alt)[0].strip()
            if dep_name and dep_name.startswith(CAMERA_TRANSITIVE_PREFIXES) and dep_name not in selected:
                queue.append(dep_name)
    return list(selected.values())


def parse_kver_from_debs(debs: list[dict]) -> str:
    for d in debs:
        m = re.match(r"^linux-image-(\d+\.\d+\.\d+\+rpt-rpi-v8)_", d["filename"])
        if m:
            return m.group(1)
    raise RuntimeError("Could not determine KVER from kernel debs list")


def cmd_resolve(args: argparse.Namespace) -> int:
    script_dir = Path(__file__).resolve().parent
    lock_path = Path(args.lock_file).resolve()
    cache_dir = Path(args.cache_dir).resolve()
    work_dir = Path(args.work_dir).resolve()
    mode = args.mode

    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    resolved_lock = copy.deepcopy(lock)
    work_dir.mkdir(parents=True, exist_ok=True)
    warnings_file = work_dir / "m5-warnings.md"
    warnings_file.unlink(missing_ok=True)

    for sub in ("keyring", "kernel", "bsp", "pigen", "camera", "apps/active", "apps/locked", "src"):
        (cache_dir / sub).mkdir(parents=True, exist_ok=True)
    for old_f in (cache_dir / "bsp").glob("*.deb"):
        pass

    token = github_token()

    # ── 1. Dynamic GPG/InRelease-Verified APT Resolution (Kali + RPi + Debian) ──
    log("Resolving Kali, Raspberry Pi & Debian APT indices (InRelease SHA256-verified)")
    kali_pkgs = load_apt_index(KALI_MIRROR, "kali-rolling", ["main"], "arm64", cache_dir)
    rpi_pkgs = load_apt_index(RPI_MIRROR, "trixie", ["main"], "arm64", cache_dir)
    deb_pkgs = load_apt_index(DEBIAN_MIRROR, "trixie", ["main"], "arm64", cache_dir)

    kr = kali_pkgs["kali-archive-keyring"]
    kr_deb = cache_dir / "keyring" / Path(kr["Filename"]).name
    download_file(f"{kr['BaseURL']}/{kr['Filename']}", kr_deb, kr["SHA256"])
    with tempfile.TemporaryDirectory() as td:
        subprocess.check_call(["dpkg-deb", "-x", str(kr_deb), td])
        shutil.copy2(Path(td) / "usr/share/keyrings/kali-archive-keyring.gpg",
                     cache_dir / "keyring/kali-archive-keyring.gpg")

    # Clean stale versions in bsp/ before populating resolved versions
    active_bsp_names = set()
    for pkg in RPI_BSP_PKGS:
        st = rpi_pkgs.get(pkg)
        if not st:
            raise RuntimeError(f"Package '{pkg}' missing from Raspberry Pi APT index")
        fn = Path(st["Filename"]).name
        active_bsp_names.add(fn)
        download_file(f"{st['BaseURL']}/{st['Filename']}", cache_dir / "bsp" / fn, st["SHA256"])
    for f in (cache_dir / "bsp").glob("*.deb"):
        if f.name not in active_bsp_names:
            f.unlink()

    # ── 2. M5 CardputerZero/pi-gen Configs & Validated Kernel Manifest ──────────
    pigen_repo = lock["pigen"]["repo"]
    pigen_branch = lock["pigen"]["branch"]
    locked_pigen_commit = lock["pigen"]["commit"]
    cand_pigen_commit = locked_pigen_commit

    if mode == "auto":
        try:
            binfo = gh_api_json(f"https://api.github.com/repos/{pigen_repo}/branches/{pigen_branch}", token)
            cand_pigen_commit = binfo["commit"]["sha"]
        except Exception as e:
            warn(f"`{pigen_repo}` branch query failed ({e}); keeping locked commit `{locked_pigen_commit[:7]}`", warnings_file)

    def fetch_pigen_and_kernel(pigen_commit: str, use_locked_hashes: bool) -> tuple[dict[str, str], str, list[dict]]:
        raw_base = f"https://raw.githubusercontent.com/{pigen_repo}/{pigen_commit}"
        new_assets: dict[str, str] = {}
        with tempfile.TemporaryDirectory() as td:
            tdir = Path(td)
            for rel_path, locked_sha in lock["pigen"]["assets"].items():
                dest = tdir / Path(rel_path).name
                exp = locked_sha if use_locked_hashes else None
                sha = download_file(f"{raw_base}/{rel_path}", dest, exp)
                new_assets[rel_path] = sha

            if use_locked_hashes:
                kdebs = lock["kernel"]["debs"]
            else:
                kmanifest = http_get(f"{raw_base}/stage0/02-firmware/files/kernel-packages.sha256").decode("utf-8")
                kdebs = []
                for line in kmanifest.splitlines():
                    parts = line.split()
                    if len(parts) == 2:
                        kdebs.append({"filename": parts[1], "sha256": parts[0].lower()})
                if not kdebs:
                    raise RuntimeError("Empty kernel-packages.sha256 in pi-gen")

            kver = parse_kver_from_debs(kdebs)
            pool_base = lock["kernel"]["pool_base"]
            active_kfiles = set()
            for kd in kdebs:
                fn = kd["filename"]
                active_kfiles.add(fn)
                download_file(f"{pool_base}/{fn}", cache_dir / "kernel" / fn, kd["sha256"])

            for f in (cache_dir / "kernel").glob("*.deb"):
                if f.name not in active_kfiles:
                    f.unlink()
            for f in tdir.iterdir():
                shutil.copy2(f, cache_dir / "pigen" / f.name)
            return new_assets, kver, kdebs

    if cand_pigen_commit != locked_pigen_commit:
        try:
            log(f"Testing updated {pigen_repo} commit {cand_pigen_commit[:7]} (was {locked_pigen_commit[:7]})")
            new_assets, kver, kdebs = fetch_pigen_and_kernel(cand_pigen_commit, use_locked_hashes=False)
            resolved_lock["pigen"]["commit"] = cand_pigen_commit
            resolved_lock["pigen"]["assets"] = new_assets
            resolved_lock["kernel"]["kver"] = kver
            resolved_lock["kernel"]["debs"] = kdebs
        except Exception as e:
            warn(f"`{pigen_repo}` `{cand_pigen_commit[:7]}` validation failed ({e}); fell back to locked `{locked_pigen_commit[:7]}`", warnings_file)
            _, kver, _ = fetch_pigen_and_kernel(locked_pigen_commit, use_locked_hashes=True)
    else:
        _, kver, _ = fetch_pigen_and_kernel(locked_pigen_commit, use_locked_hashes=True)

    # ── 3. M5 m5stack-linux-dtoverlays & pigpio Source Tarballs ─────────────────
    dto_repo = lock["dtoverlays"]["repo"]
    dto_branch = lock["dtoverlays"]["branch"]
    dto_locked = lock["dtoverlays"]["commit"]
    dto_cand = dto_locked

    def ensure_tarball(url: str, dest: Path) -> None:
        if dest.exists() and tarfile.is_tarfile(dest):
            return
        dest.unlink(missing_ok=True)
        download_file(url, dest)
        if not tarfile.is_tarfile(dest):
            dest.unlink(missing_ok=True)
            raise RuntimeError(f"Invalid tarball from {url}")

    ensure_tarball(
        f"https://codeload.github.com/{dto_repo}/tar.gz/{dto_locked}",
        cache_dir / "src" / f"m5stack-linux-dtoverlays-{dto_locked}.tar.gz",
    )

    if mode == "auto":
        try:
            dto_info = gh_api_json(f"https://api.github.com/repos/{dto_repo}/commits/{dto_branch}", token)
            cand_sha = dto_info.get("sha") or dto_locked
            if cand_sha != dto_locked:
                ensure_tarball(
                    f"https://codeload.github.com/{dto_repo}/tar.gz/{cand_sha}",
                    cache_dir / "src" / f"m5stack-linux-dtoverlays-{cand_sha}.tar.gz",
                )
            dto_cand = cand_sha
        except Exception as e:
            warn(f"`{dto_repo}` latest commit lookup failed ({e}); using locked `{dto_locked[:7]}`", warnings_file)
            dto_cand = dto_locked
    resolved_lock["dtoverlays"]["commit"] = dto_cand

    ensure_tarball(
        "https://codeload.github.com/joan2937/pigpio/tar.gz/master",
        cache_dir / "src/pigpio.tar.gz",
    )

    # ── 4. M5 CardputerZero First-Party Apps (Validation + Lockfile Fallback) ───
    m5_apt_pkgs = None
    for f in (cache_dir / "apps/active").glob("*.deb"):
        f.unlink()

    manifest_lines = []
    camera_deb_path: Path | None = None

    for idx, app in enumerate(lock["apps"]):
        slug = app["slug"]
        pkg_name = app["pkg_name"]
        locked_info = app["locked"]
        locked_deb = cache_dir / "apps/locked" / locked_info["filename"]

        # Always ensure locked fallback .deb is available locally (GitHub -> M5 OSS APT fallback)
        try:
            download_file(locked_info["url"], locked_deb, locked_info["sha256"])
        except Exception as e_lock:
            if m5_apt_pkgs is None:
                m5_apt_pkgs = load_m5_apt_index()
            alt = (m5_apt_pkgs or {}).get(pkg_name)
            if alt:
                locked_deb = cache_dir / "apps/locked" / Path(alt["Filename"]).name
                download_file(f"{alt['BaseURL']}/{alt['Filename']}", locked_deb, alt["SHA256"])
            elif mode == "locked":
                raise RuntimeError(f"Locked package {slug} unavailable ({e_lock})")

        chosen_deb = locked_deb
        chosen_meta = dict(locked_info)

        if mode == "auto":
            cand = None
            rx = re.compile(app["asset_regex"])
            for repo in app["repos"]:
                try:
                    rels = gh_api_json(f"https://api.github.com/repos/{repo}/releases?per_page=25", token)
                    if not isinstance(rels, list):
                        continue
                    matches = []
                    for rel in rels:
                        if rel.get("draft") or rel.get("prerelease"):
                            continue
                        pub = rel.get("published_at") or rel.get("created_at") or ""
                        tag = rel.get("tag_name") or ""
                        for asset in rel.get("assets", []):
                            aname = asset.get("name", "")
                            burl = asset.get("browser_download_url", "")
                            if rx.search(aname) and burl:
                                matches.append((pub, tag, aname, burl))
                    if matches:
                        cand = max(matches)
                        break
                except Exception:
                    continue

            if cand:
                _, c_tag, c_name, c_url = cand
                if c_url != locked_info["url"] or c_name != locked_info["filename"]:
                    log(f"Testing M5 update for {slug}: {c_name} ({c_tag})")
                    try:
                        tmp_cand = cache_dir / "apps" / f".cand_{c_name}"
                        c_sha = download_file(c_url, tmp_cand)
                        ok_deb, reason = validate_deb_file(tmp_cand)
                        if not ok_deb:
                            raise RuntimeError(reason)
                        if slug == "launcher":
                            ok_patch, patch_reason = dry_run_applaunch_patch(tmp_cand, script_dir)
                            if not ok_patch:
                                raise RuntimeError(
                                    f"APPLaunch sort comparator patch incompatible ({patch_reason})"
                                )
                        chosen_deb = tmp_cand
                        chosen_meta = {
                            "tag": c_tag,
                            "filename": c_name,
                            "url": c_url,
                            "sha256": c_sha,
                        }
                        ok(f"Validated M5 update for {slug}: {c_name}")
                    except Exception as e_cand:
                        warn(
                            f"`{slug}`: newest M5 release `{c_tag}` (`{c_name}`) rejected ({e_cand}); kept verified `{locked_info['tag']}` (`{locked_info['filename']}`)",
                            warnings_file,
                        )

        active_dest = cache_dir / "apps/active" / chosen_meta["filename"]
        if chosen_deb != active_dest:
            shutil.copy2(chosen_deb, active_dest)
        if chosen_deb.name.startswith(".cand_"):
            chosen_deb.unlink(missing_ok=True)

        resolved_lock["apps"][idx]["locked"] = chosen_meta
        manifest_lines.append(
            f"{slug}|{pkg_name}|{active_dest}|{locked_deb}"
        )
        if slug == "camera":
            camera_deb_path = active_dest

    (work_dir / "apps-manifest.txt").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")

    # ── 5. Dynamic RPi/Debian libcamera Runtime Tree Matching CameraApp ─────────
    root_cam_pkg = detect_camera_libcamera_pkg(camera_deb_path, rpi_pkgs) if camera_deb_path else "libcamera0.7"
    cam_stanzas = resolve_camera_runtime_debs(root_cam_pkg, rpi_pkgs, deb_pkgs)
    active_cam_files = set()
    for st in cam_stanzas:
        fn = Path(st["Filename"]).name
        active_cam_files.add(fn)
        download_file(f"{st['BaseURL']}/{st['Filename']}", cache_dir / "camera" / fn, st["SHA256"])
    for f in (cache_dir / "camera").glob("*.deb"):
        if f.name not in active_cam_files:
            f.unlink()

    # ── 6. Write resolved-env.sh & resolved-lock.json ───────────────────────────
    kver_base = kver.split("+", 1)[0]
    hold_pkgs = (
        f"linux-image-{kver} linux-image-rpi-v8 "
        f"linux-headers-{kver} linux-headers-rpi-v8 "
        f"linux-headers-{kver_base}+rpt-common-rpi "
        f"linux-kbuild-{kver_base}+rpt "
        f"linux-base-{kver} linux-base-rpi-v8"
    )
    (work_dir / "resolved-env.sh").write_text(
        f'KVER="{kver}"\n'
        f'KERNEL_HOLD_PKGS="{hold_pkgs}"\n'
        f'DTOVERLAYS_CANDIDATE="{dto_cand}"\n'
        f'DTOVERLAYS_LOCKED="{dto_locked}"\n',
        encoding="utf-8",
    )
    (work_dir / "resolved-lock.json").write_text(
        json.dumps(resolved_lock, indent=2) + "\n", encoding="utf-8"
    )
    ok(f"All upstream inputs resolved & verified (KVER={kver}, dtoverlays={dto_cand[:7]}, camera_rt={len(cam_stanzas)} debs)")
    return 0


def cmd_record_fallback(args: argparse.Namespace) -> int:
    work_dir = Path(args.work_dir).resolve()
    lock_path = Path(args.lock_file).resolve()
    rlock_path = work_dir / "resolved-lock.json"
    warnings_file = work_dir / "m5-warnings.md"

    orig_lock = json.loads(lock_path.read_text(encoding="utf-8"))
    rlock = json.loads(rlock_path.read_text(encoding="utf-8")) if rlock_path.exists() else copy.deepcopy(orig_lock)

    comp = args.component
    if comp == "dtoverlays":
        rlock["dtoverlays"] = orig_lock["dtoverlays"]
    elif comp.startswith("app:"):
        slug = comp.split(":", 1)[1]
        for idx, a in enumerate(orig_lock["apps"]):
            if a["slug"] == slug:
                rlock["apps"][idx]["locked"] = a["locked"]
                break

    rlock_path.write_text(json.dumps(rlock, indent=2) + "\n", encoding="utf-8")
    warn(args.reason, warnings_file)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_res = sub.add_parser("resolve")
    p_res.add_argument("--lock-file", required=True)
    p_res.add_argument("--cache-dir", required=True)
    p_res.add_argument("--work-dir", required=True)
    p_res.add_argument("--mode", choices=("auto", "locked"), default="auto")

    p_fb = sub.add_parser("record-fallback")
    p_fb.add_argument("--lock-file", required=True)
    p_fb.add_argument("--work-dir", required=True)
    p_fb.add_argument("--component", required=True)
    p_fb.add_argument("--reason", required=True)

    ns = ap.parse_args()
    if ns.cmd == "resolve":
        return cmd_resolve(ns)
    return cmd_record_fallback(ns)


if __name__ == "__main__":
    raise SystemExit(main())
