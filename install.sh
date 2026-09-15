#!/bin/sh
# Install an Attar archive after verifying its caller-supplied digest.
# The digest is an integrity pin; it is not a substitute for a signed release
# index or an independent release signature.
set -eu

exec python3 - "$@" <<'PY'
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request


SCHEMA_VERSION = 1
PACKAGE_NAME = "attar"
LINUX_TARGET = "x86_64-unknown-linux-gnu"
MACOS_TARGET = "aarch64-apple-darwin"
RELEASE_CONFIG = "config/attar-release.json"
MARKER_NAME = ".attar-install.json"
LOCK_NAME = ".attar-install.lock"
DOWNLOAD_TIMEOUT_SECONDS = 30
GPG_TIMEOUT_SECONDS = 60
RELEASE_INDEX_URL = "https://occam-tech.github.io/attar-releases/index.json"
RELEASE_SIGNATURE_URL = RELEASE_INDEX_URL + ".asc"
RELEASE_KEY_URL = "https://occam-tech.github.io/attar-releases/release-key.asc"
# This is the release repository's full primary-key fingerprint.  The
# corresponding public key is fetched from RELEASE_KEY_URL and checked
# against this value before gpgv verifies the index.
RELEASE_KEY_FINGERPRINT = "008A9C99104AB61F27E42FF7BF8BACE579A3DA8E"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+_~-]*$")


def die(message):
    raise SystemExit("ATTAR_DIST_INSTALL_FAIL " + message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + str(key))
        result[key] = value
    return result


def load_json(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (OSError, UnicodeError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        die("invalid " + label + ": " + str(exc))


def safe_path(name):
    if not isinstance(name, str) or not name or "\\" in name or "\x00" in name:
        die("archive contains unsafe path: " + repr(name))
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        die("archive contains unsafe path: " + repr(name))
    canonical = "/".join(path.parts)
    if name != canonical:
        die("archive contains non-canonical path: " + repr(name))
    return path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def mode_value(value, label):
    if isinstance(value, bool):
        die("invalid mode for " + label)
    if isinstance(value, int):
        mode = value
    elif isinstance(value, str) and re.fullmatch(r"0?[0-7]{3,4}", value):
        mode = int(value, 8)
    else:
        die("invalid mode for " + label)
    if mode < 0 or mode > 0o7777:
        die("invalid mode for " + label)
    return mode


def absolute_path(value, label):
    try:
        path = Path(value).expanduser()
    except (OSError, RuntimeError) as exc:
        die("invalid " + label + ": " + str(exc))
    if not path.is_absolute():
        path = Path.cwd() / path
    # normpath is lexical.  In particular, it does not hide a symlink at the
    # path named by the caller, which Path.resolve() would do.
    return Path(os.path.normpath(str(path)))


def check_real_components(path, label):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            die(label + " contains a symlink: " + str(current))


def real_directory(path, label, create=False):
    check_real_components(path, label)
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        die(label + " must be a real directory")
    if create and not path.exists():
        try:
            path.mkdir(parents=True)
        except OSError as exc:
            die("cannot create " + label + ": " + str(exc))


def path_inside(path, base):
    return path == base or base in path.parents


class NoDowngradeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        old_scheme = urllib.parse.urlparse(request.full_url).scheme.lower()
        new_scheme = urllib.parse.urlparse(newurl).scheme.lower()
        if old_scheme == "https" and new_scheme != "https":
            die("refusing HTTPS redirect to " + new_scheme)
        return super().redirect_request(request, fp, code, message, headers, newurl)


def copy_download(url, destination, allow_file=True):
    parsed = urllib.parse.urlparse(url)
    scheme = parsed.scheme.lower()
    allowed_schemes = ("https", "file") if allow_file else ("https",)
    if scheme not in allowed_schemes:
        die("download URL must use https" if not allow_file else "archive URL must use https or file")
    opener = urllib.request.build_opener(NoDowngradeRedirectHandler())
    try:
        with opener.open(url, timeout=DOWNLOAD_TIMEOUT_SECONDS) as source:
            final_scheme = urllib.parse.urlparse(source.geturl()).scheme.lower()
            if scheme == "https" and final_scheme != "https":
                die("refusing HTTPS redirect to " + final_scheme)
            if final_scheme not in allowed_schemes:
                die("download URL must use https" if not allow_file else "archive URL must use https or file")
            with destination.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
    except SystemExit:
        raise
    except (OSError, urllib.error.URLError, TimeoutError) as exc:
        die("download failed: " + str(exc))


def parse_version(value, label):
    if not isinstance(value, str) or not VERSION_RE.fullmatch(value):
        die(label + " is invalid")
    return value


def host_target():
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Linux" and machine in ("x86_64", "amd64"):
        return LINUX_TARGET
    if system == "Darwin" and machine in ("arm64", "aarch64"):
        return MACOS_TARGET
    die("unsupported host for release discovery: " + system + "/" + machine)


def command_output(command, label):
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=GPG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        die(label + " timed out; install a working gpg/gpgv")
    except OSError as exc:
        die("signed release discovery requires installed " + label + "; install gpg and gpgv: " + str(exc))
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        die(label + " failed: " + (detail or "exit status " + str(result.returncode)))
    return result.stdout


def verify_release_key(key_path, keyring_path, temporary):
    if not RELEASE_KEY_FINGERPRINT or not re.fullmatch(r"[0-9A-Fa-f]{40}", RELEASE_KEY_FINGERPRINT):
        die("signed release discovery is not configured; release key fingerprint must be pinned")
    expected = RELEASE_KEY_FINGERPRINT.upper()
    gnupg = shutil.which("gpg")
    gpgv = shutil.which("gpgv")
    if gnupg is None or gpgv is None:
        die("signed release discovery requires installed gpg and gpgv; install gpg and gpgv")
    homedir = Path(temporary) / "gnupg"
    homedir.mkdir(mode=0o700)
    key_info = command_output([gnupg, "--batch", "--no-options", "--homedir", str(homedir), "--no-default-keyring", "--with-colons", "--show-keys", str(key_path)], "gpg key inspection")
    fingerprints = []
    primary = False
    for line in key_info.splitlines():
        fields = line.split(":")
        if not fields:
            continue
        if fields[0] == "pub":
            primary = True
        elif fields[0] == "sub":
            primary = False
        elif fields[0] == "fpr" and primary and len(fields) > 9:
            fingerprints.append(fields[9].upper())
    if fingerprints != [expected]:
        die("release key fingerprint does not match the pinned repository key")
    command_output([gnupg, "--batch", "--yes", "--no-options", "--homedir", str(homedir), "--no-default-keyring", "--dearmor", "--output", str(keyring_path), str(key_path)], "gpg key conversion")
    return gpgv, expected


def verify_signed_index(index_path, signature_path, key_path, temporary):
    keyring = Path(temporary) / "release-keyring.gpg"
    gpgv, expected = verify_release_key(key_path, keyring, temporary)
    try:
        result = subprocess.run([gpgv, "--status-fd", "1", "--keyring", str(keyring), str(signature_path), str(index_path)], check=False, capture_output=True, text=True, timeout=GPG_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        die("release index signature verification timed out; install a working gpgv")
    except OSError as exc:
        die("signed release discovery requires installed gpgv; install gpgv: " + str(exc))
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        die("release index signature verification failed: " + (detail or "exit status " + str(result.returncode)))
    fingerprints = valid_signature_fingerprints(result.stdout)
    if fingerprints != [expected]:
        die("release index signature used an unexpected key")


def valid_signature_fingerprints(status_output):
    fingerprints = []
    for line in status_output.splitlines():
        fields = line.split()
        if len(fields) < 3 or fields[:2] != ["[GNUPG:]", "VALIDSIG"]:
            continue
        # VALIDSIG names the signing subkey in field 2 and, when present,
        # the primary key in field 11.
        fingerprints.append((fields[11] if len(fields) >= 12 and re.fullmatch(r"[0-9A-Fa-f]{40}", fields[11]) else fields[2]).upper())
    return fingerprints


def select_release(index, channel, requested_version, target):
    if not isinstance(index, dict) or index.get("schema_version") != SCHEMA_VERSION or index.get("repository") != "occam-tech/attar-releases":
        die("signed release index has an unsupported schema or repository")
    channels = index.get("channels")
    if not isinstance(channels, dict) or channel not in channels or not isinstance(channels[channel], dict):
        if channel == "stable" and (not isinstance(channels, dict) or not channels.get("stable")):
            die("stable channel has no published releases; use --channel dev")
        die("signed release index has no channel: " + channel)
    channel_data = channels[channel]
    releases = channel_data.get("releases")
    if not isinstance(releases, dict):
        die("signed release channel releases is invalid: " + channel)
    if not releases:
        if channel == "stable":
            die("stable channel has no published releases; use --channel dev")
        die("signed release channel has no published releases: " + channel)
    default_version = parse_version(channel_data.get("default_version"), "signed release default version")
    if default_version not in releases:
        die("signed release default version is not published: " + default_version)
    version = requested_version or default_version
    parse_version(version, "requested release version")
    release = releases.get(version)
    if not isinstance(release, dict):
        die("signed release index has no " + channel + " release version " + version)
    targets = release.get("targets")
    record = targets.get(target) if isinstance(targets, dict) else None
    if not isinstance(record, dict) or set(record) != {"url", "sha256"}:
        die("signed release index has no target " + target + " for " + version)
    url = record["url"]
    if not isinstance(url, str) or urllib.parse.urlparse(url).scheme.lower() != "https":
        die("signed release archive URL must use HTTPS")
    archive_hash = record["sha256"]
    if not isinstance(archive_hash, str) or not SHA256_RE.fullmatch(archive_hash):
        die("signed release archive digest is invalid")
    return version, url, archive_hash


def discover_release(channel, requested_version):
    target = host_target()
    if not RELEASE_KEY_FINGERPRINT:
        die("signed release discovery is not configured; release key fingerprint must be pinned")
    with tempfile.TemporaryDirectory(prefix=".attar-release-discovery-") as temporary:
        root = Path(temporary)
        index_path = root / "index.json"
        signature_path = root / "index.json.asc"
        key_path = root / "release-key.asc"
        copy_download(RELEASE_INDEX_URL, index_path, allow_file=False)
        copy_download(RELEASE_SIGNATURE_URL, signature_path, allow_file=False)
        copy_download(RELEASE_KEY_URL, key_path, allow_file=False)
        verify_signed_index(index_path, signature_path, key_path, root)
        index = load_json(index_path, "signed release index")
        return select_release(index, channel, requested_version, target)


def parse_release_version(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        die(label + " is invalid")
    return tuple(int(part) for part in value.split("."))


def verify_release_config(payload, target):
    config_path = payload / Path(*PurePosixPath(RELEASE_CONFIG).parts)
    if config_path.is_symlink() or not config_path.is_file():
        die("packaged release configuration is missing")
    config = load_json(config_path, "packaged release configuration")
    if not isinstance(config, dict) or config.get("schema_version") != SCHEMA_VERSION:
        die("unsupported packaged release configuration")
    targets = config.get("targets")
    if not isinstance(targets, dict) or target not in targets or not isinstance(targets[target], dict):
        die("packaged release configuration has no target: " + target)
    minimum = targets[target]
    if target == LINUX_TARGET:
        if set(minimum) != {"glibc"}:
            die("packaged Linux release configuration is invalid")
        return ("glibc", parse_release_version(minimum["glibc"], "packaged glibc minimum"))
    if target == MACOS_TARGET:
        if set(minimum) != {"macos"}:
            die("packaged macOS release configuration is invalid")
        return ("macos", parse_release_version(minimum["macos"], "packaged macOS minimum"))
    die("unsupported archive target: " + target)


def host_glibc_version():
    configured = os.confstr("CS_GNU_LIBC_VERSION")
    if configured:
        name, separator, version = configured.partition(" ")
        if separator and name.lower() == "glibc":
            return parse_release_version(version, "host glibc version")
        die("unsupported Linux libc (glibc is required)")
    name, version = platform.libc_ver()
    if name.lower() != "glibc" or not version:
        die("unsupported Linux libc (glibc is required)")
    return parse_release_version(version, "host glibc version")


def verify_host(target, minimum_kind, minimum):
    system = platform.system()
    machine = platform.machine().lower()
    if system == "Linux":
        if target != LINUX_TARGET or machine not in ("x86_64", "amd64"):
            die("archive target is incompatible with this Linux host")
        if minimum_kind != "glibc":
            die("packaged Linux release configuration is invalid")
        actual = host_glibc_version()
        if actual < minimum:
            die("Linux glibc " + ".".join(map(str, actual)) + " is below required " + ".".join(map(str, minimum)))
        return
    if system == "Darwin":
        if target != MACOS_TARGET or machine not in ("arm64", "aarch64"):
            die("archive target is incompatible with this macOS host")
        if minimum_kind != "macos":
            die("packaged macOS release configuration is invalid")
        version = platform.mac_ver()[0]
        if not version:
            die("cannot determine macOS version")
        actual = parse_release_version(version, "host macOS version")
        if actual < minimum:
            die("macOS " + ".".join(map(str, actual)) + " is below required " + ".".join(map(str, minimum)))
        return
    die("unsupported host operating system: " + system)


def verify_payload(payload, expected_version=None, allow_marker=False):
    manifest_path = payload / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        die("archive has no regular manifest.json")
    manifest = load_json(manifest_path, "packaged manifest")
    if not isinstance(manifest, dict):
        die("packaged manifest is not an object")
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("package") != PACKAGE_NAME:
        die("unsupported packaged manifest")
    version = parse_version(manifest.get("version"), "packaged manifest version")
    if expected_version is not None and version != expected_version:
        die("archive manifest version does not match --version")
    target = manifest.get("target")
    if target not in (LINUX_TARGET, MACOS_TARGET):
        die("unsupported archive target: " + str(target))
    minimum_kind, minimum = verify_release_config(payload, target)
    verify_host(target, minimum_kind, minimum)
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        die("packaged manifest files is invalid")
    if "manifest.json" in files:
        die("packaged manifest must not list manifest.json")
    if RELEASE_CONFIG not in files:
        die("packaged manifest must list " + RELEASE_CONFIG)
    if "bin/attar" not in files:
        die("packaged manifest must list bin/attar")
    names = set()
    for name, record in files.items():
        safe_path(name)
        if name in names:
            die("packaged manifest contains duplicate path: " + name)
        names.add(name)
        if not isinstance(record, dict) or set(record) != {"sha256", "mode"}:
            die("manifest record for " + name + " must contain sha256 and mode")
        expected_hash = record.get("sha256")
        if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
            die("invalid sha256 for " + name)
        expected_mode = mode_value(record.get("mode"), name)
        path = payload.joinpath(*PurePosixPath(name).parts)
        if path.is_symlink() or not path.is_file():
            die("packaged file is missing or not regular: " + name)
        if stat.S_IMODE(path.stat().st_mode) != expected_mode:
            die("packaged file mode does not match its manifest: " + name)
        if sha256(path) != expected_hash:
            die("packaged file does not match its manifest: " + name)
    executable = payload / Path(*PurePosixPath("bin/attar").parts)
    if not stat.S_IMODE(executable.stat().st_mode) & 0o111:
        die("packaged bin/attar is not executable")
    for directory, directories, files_on_disk in os.walk(payload, followlinks=False):
        for name in directories:
            if (Path(directory) / name).is_symlink():
                die("packaged payload contains a symlink directory: " + name)
        for name in files_on_disk:
            relative = (Path(directory) / name).relative_to(payload).as_posix()
            if relative == MARKER_NAME and allow_marker and Path(directory) == payload:
                continue
            if relative != "manifest.json" and relative not in names:
                die("unlisted packaged file: " + relative)
    return manifest


def extract_verified(archive_path, destination, expected_version):
    try:
        archive = tarfile.open(archive_path, mode="r:gz")
    except (OSError, tarfile.TarError) as exc:
        die("invalid tar.gz archive: " + str(exc))
    with archive:
        members = archive.getmembers()
        if not members:
            die("archive is empty")
        roots = set()
        seen = set()
        for member in members:
            path = safe_path(member.name)
            canonical = "/".join(path.parts)
            if canonical in seen:
                die("archive contains duplicate path: " + canonical)
            seen.add(canonical)
            roots.add(path.parts[0])
            if member.issym() or member.islnk() or member.isdev() or not (member.isdir() or member.isreg()):
                die("archive contains a link or special file: " + member.name)
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, stat.S_IMODE(member.mode) or 0o755)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    die("archive file cannot be read: " + member.name)
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                os.chmod(target, stat.S_IMODE(member.mode))
        if len(roots) != 1:
            die("archive must contain one root directory")
        root = next(iter(roots))
        payload = destination / root
        if not payload.is_dir() or payload.is_symlink():
            die("archive root is not a real directory")
        return payload, verify_payload(payload, expected_version)


def load_marker(prefix):
    marker = prefix / MARKER_NAME
    if marker.is_symlink() or not marker.is_file():
        die("refusing unmanaged existing prefix")
    marker_data = load_json(marker, "install marker")
    if not isinstance(marker_data, dict) or set(marker_data) != {"schema_version", "package", "version", "archive_sha256"}:
        die("refusing invalid install marker")
    if marker_data.get("schema_version") != SCHEMA_VERSION or marker_data.get("package") != PACKAGE_NAME:
        die("refusing invalid install marker")
    parse_version(marker_data.get("version"), "install marker version")
    archive_hash = marker_data.get("archive_sha256")
    if not isinstance(archive_hash, str) or not SHA256_RE.fullmatch(archive_hash):
        die("refusing invalid install marker digest")
    return marker_data


def inspect_existing(prefix):
    if prefix.is_symlink() or (prefix.exists() and not prefix.is_dir()):
        die("refusing unsafe existing prefix")
    if not prefix.exists():
        return None, None
    marker = load_marker(prefix)
    manifest = verify_payload(prefix, marker["version"], allow_marker=True)
    if stat.S_IMODE((prefix / MARKER_NAME).stat().st_mode) != 0o644:
        die("install marker has unexpected mode")
    return marker, manifest


def inspect_launcher(link, prefix, managed_prefix):
    if link.is_symlink():
        if not managed_prefix or os.path.realpath(link) != os.path.abspath(str(prefix / "bin/attar")):
            die("refusing unmanaged existing launcher")
        return True
    if link.exists():
        die("refusing unmanaged existing launcher")
    return False


def create_launcher(prefix, bin_dir, link):
    real_directory(bin_dir, "bin directory", create=True)
    if inspect_launcher(link, prefix, True):
        return False
    fd, temporary_name = tempfile.mkstemp(prefix=".attar-launcher-", dir=str(bin_dir))
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        temporary.unlink()
        os.symlink(os.path.abspath(str(prefix / "bin/attar")), temporary)
        if link.exists() or link.is_symlink():
            die("refusing unmanaged existing launcher")
        os.replace(temporary, link)
        return True
    finally:
        if temporary.is_symlink() or temporary.exists():
            temporary.unlink()


def remove_owned_tree(path, identity):
    if not path.exists() or path.is_symlink():
        return
    try:
        current = os.stat(path)
    except OSError:
        return
    if (current.st_dev, current.st_ino) != identity:
        return
    shutil.rmtree(path)


def commit_install(payload, prefix, bin_dir, link, version, archive_hash, temporary, prefix_was_present):
    stage = Path(temporary) / "stage"
    shutil.copytree(payload, stage)
    marker = stage / MARKER_NAME
    marker.write_text(json.dumps({"schema_version": SCHEMA_VERSION, "package": PACKAGE_NAME, "version": version, "archive_sha256": archive_hash}, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(marker, 0o644)
    # Verify the exact bytes and modes that are about to be installed.
    verify_payload(stage, version, allow_marker=True)

    real_directory(bin_dir, "bin directory", create=True)
    launcher_temporary = None
    if not inspect_launcher(link, prefix, prefix_was_present):
        fd, temporary_name = tempfile.mkstemp(prefix=".attar-launcher-", dir=str(bin_dir))
        os.close(fd)
        launcher_temporary = Path(temporary_name)
        launcher_temporary.unlink()
        os.symlink(os.path.abspath(str(prefix / "bin/attar")), launcher_temporary)

    stage_identity = os.stat(stage)
    stage_identity = (stage_identity.st_dev, stage_identity.st_ino)
    backup = Path(temporary) / "backup"
    old_moved = False
    new_installed = False
    launcher_installed = False
    try:
        if prefix_was_present:
            os.replace(prefix, backup)
            old_moved = True
        os.replace(stage, prefix)
        new_installed = True
        if launcher_temporary is not None:
            if link.exists() or link.is_symlink():
                die("refusing unmanaged existing launcher")
            os.replace(launcher_temporary, link)
            launcher_installed = True
        if old_moved:
            backup_identity = os.stat(backup)
            remove_owned_tree(backup, (backup_identity.st_dev, backup_identity.st_ino))
    except BaseException:
        if launcher_installed and link.is_symlink() and os.path.realpath(link) == os.path.abspath(str(prefix / "bin/attar")):
            link.unlink()
        if new_installed:
            installed = prefix
            remove_owned_tree(installed, stage_identity)
        if old_moved and backup.exists() and not prefix.exists():
            os.replace(backup, prefix)
        raise


def install(args):
    version = parse_version(args.version, "--version")
    if len(args.sha256) != 64 or not SHA256_RE.fullmatch(args.sha256):
        die("--sha256 must be a lowercase SHA-256 digest")
    prefix = absolute_path(args.prefix, "--prefix")
    bin_dir = absolute_path(args.bin_dir, "--bin-dir")
    parent = prefix.parent
    if prefix == parent or prefix == Path("/") or prefix == Path.home() or parent == Path("/"):
        die("refusing unsafe installation prefix")
    if bin_dir == Path("/") or bin_dir == Path.home():
        die("refusing unsafe bin directory")
    if path_inside(bin_dir, prefix) or path_inside(prefix, bin_dir):
        die("bin directory and installation prefix must be separate")
    check_real_components(prefix, "installation prefix")
    check_real_components(bin_dir, "bin directory")
    real_directory(parent, "prefix parent", create=True)
    lock_path = parent / LOCK_NAME
    if lock_path.is_symlink() or (lock_path.exists() and not lock_path.is_file()):
        die("refusing unsafe install lock")
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    try:
        lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT | no_follow, 0o600)
    except OSError as exc:
        die("cannot open install lock: " + str(exc))
    with os.fdopen(lock_fd, "r+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as exc:
            if isinstance(exc, BlockingIOError) or exc.errno in (errno.EACCES, errno.EAGAIN):
                die("another installation is in progress")
            die("cannot lock installation prefix: " + str(exc))
        prefix_was_present = prefix.exists()
        old_marker, old_manifest = inspect_existing(prefix)
        link = bin_dir / "attar"
        if link.is_symlink() or link.exists():
            inspect_launcher(link, prefix, prefix_was_present)
        with tempfile.TemporaryDirectory(prefix=".attar-install-", dir=str(parent)) as temporary:
            download = Path(temporary) / "archive.tar.gz"
            copy_download(args.url, download, allow_file=not args.discovered)
            actual = sha256(download)
            if actual != args.sha256:
                die("archive SHA-256 mismatch")
            extract = Path(temporary) / "extract"
            extract.mkdir()
            payload, manifest = extract_verified(download, extract, version)
            if old_marker is not None and old_marker["version"] == version:
                if old_marker["archive_sha256"] != actual:
                    die("same version is already installed with a different archive digest")
                repaired = create_launcher(prefix, bin_dir, link) if not link.is_symlink() else False
                print("ATTAR_DIST_INSTALL_PASS idempotent=1 repaired=" + ("1" if repaired else "0") + " prefix=" + str(prefix))
                return
            commit_install(payload, prefix, bin_dir, link, version, actual, temporary, prefix_was_present)
    print("ATTAR_DIST_INSTALL_PASS idempotent=0 version=" + version + " prefix=" + str(prefix))


def main():
    parser = argparse.ArgumentParser(description="Install a digest-pinned Attar tar.gz archive")
    parser.add_argument("--url")
    parser.add_argument("--version")
    parser.add_argument("--sha256")
    parser.add_argument("--channel", choices=("stable", "dev"), default="stable")
    parser.add_argument("--prefix", default="~/.local/share/attar")
    parser.add_argument("--bin-dir", default="~/.local/bin")
    args = parser.parse_args()
    if args.url is None:
        if args.sha256 is not None:
            die("--sha256 requires --url in explicit install mode")
        args.version, args.url, args.sha256 = discover_release(args.channel, args.version)
        args.discovered = True
    else:
        if args.version is None or args.sha256 is None:
            die("explicit install mode requires --url, --version, and --sha256")
        args.discovered = False
    install(args)


try:
    main()
except SystemExit:
    raise
except Exception as exc:
    die(str(exc))
PY
