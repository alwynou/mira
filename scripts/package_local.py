#!/usr/bin/env python3
"""Build a reproducible unsigned local Release ZIP from one Git revision."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import stat
import subprocess
import sys
import tarfile
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}
MINIMUM_MACOS = (15, 0, 0)


class PackagingError(RuntimeError):
    """A safe, actionable packaging failure."""


def run(argv: list[str], *, cwd: Path | None = None, output: Path | None = None) -> subprocess.CompletedProcess[str]:
    if output is None:
        return subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=True)
    with output.open("w", encoding="utf-8") as stream:
        return subprocess.run(argv, cwd=cwd, text=True, stdout=stream, stderr=subprocess.STDOUT, check=True)


def git_output(*arguments: str, cwd: Path = ROOT) -> str:
    try:
        return run(["git", *arguments], cwd=cwd).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise PackagingError(f"Git command failed: git {' '.join(arguments)}") from error


def resolve_revision(revision: str) -> str:
    if not revision or any(character in revision for character in "\r\n\x00"):
        raise PackagingError("--revision must name one resolved Git commit.")
    resolved = git_output("rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}")
    if len(resolved) != 40:
        raise PackagingError("--revision did not resolve to a full Git commit.")
    return resolved


def safe_extract_archive(archive: Path, destination: Path) -> Path:
    with tarfile.open(archive, mode="r:") as tar:
        members = tar.getmembers()
        if not members:
            raise PackagingError("The Git archive is empty.")
        for member in members:
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise PackagingError("The Git archive contains an unsafe path.")
            if member.issym() or member.islnk() or not (member.isfile() or member.isdir()) or member.isdev():
                raise PackagingError("The Git archive contains an unsupported entry.")
            target = (destination / relative).resolve()
            if destination.resolve() not in target.parents and target != destination.resolve():
                raise PackagingError("The Git archive escapes its extraction directory.")
        # All members were checked above and links/devices are rejected, so
        # extraction is limited to regular files and directories.
        tar.extractall(destination)
    roots = {Path(member.name).parts[0] for member in members if Path(member.name).parts}
    if len(roots) != 1:
        raise PackagingError("The Git archive must contain one source root.")
    return destination / next(iter(roots))


def sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest(), size


def bundle_digest(bundle: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle).as_posix().encode("utf-8")
        digest.update(relative + b"\0")
        mode = path.lstat().st_mode
        digest.update(f"{stat.S_IFMT(mode):o}:{stat.S_IMODE(mode):o}".encode("ascii") + b"\0")
        if path.is_symlink():
            digest.update(os.readlink(path).encode("utf-8") + b"\0")
        elif path.is_file():
            with path.open("rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
        digest.update(b"\n")
    return digest.hexdigest()


def toolchain_snapshot() -> dict[str, Any]:
    values: dict[str, Any] = {
        "host": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "developerDir": os.environ.get("DEVELOPER_DIR", ""),
    }
    for name, argv in {
        "xcodebuild": ["xcodebuild", "-version"],
        "swift": ["swift", "--version"],
        "xcodeSelect": ["xcode-select", "-p"],
        "macOS": ["sw_vers", "-productVersion"],
        "cpu": ["sysctl", "-n", "machdep.cpu.brand_string"],
        "memoryBytes": ["sysctl", "-n", "hw.memsize"],
    }.items():
        try:
            values[name] = run(argv).stdout.strip()
        except (OSError, subprocess.CalledProcessError) as error:
            values[name] = f"unavailable: {error}"
    return values


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def version_tuple(value: str) -> tuple[int, ...]:
    try:
        components = tuple(int(part) for part in value.split("."))
        return components + (0,) * max(0, 3 - len(components))
    except ValueError as error:
        raise PackagingError(f"The app reports an invalid version: {value!r}.") from error


def inspect_app(app: Path, requested_architectures: set[str]) -> dict[str, Any]:
    if not app.is_dir():
        raise PackagingError(f"Release app was not produced at {app}.")
    plist_path = app / "Contents/Info.plist"
    try:
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackagingError("The Release app Info.plist could not be read.") from error
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    minimum_os = str(info.get("LSMinimumSystemVersion", ""))
    if (not version or not build or version_tuple(minimum_os) != MINIMUM_MACOS
            or info.get("CFBundleIdentifier") != "com.alwynou.mira"):
        raise PackagingError("The Release app version or minimum macOS declaration is invalid.")

    executable = app / "Contents/MacOS" / str(info.get("CFBundleExecutable", "Mira"))
    try:
        architectures = set(run(["lipo", "-archs", str(executable)]).stdout.split())
    except (OSError, subprocess.CalledProcessError) as error:
        raise PackagingError("The Release executable architectures could not be inspected.") from error
    if architectures != requested_architectures:
        raise PackagingError(f"Expected architectures {sorted(requested_architectures)}, found {sorted(architectures)}.")

    required_resources = [
        app / "Contents/Resources/ThirdPartyLicenses.txt",
        app / "Contents/Resources/en.lproj/Localizable.strings",
        app / "Contents/Resources/zh-Hans.lproj/Localizable.strings",
    ]
    if any(not resource.is_file() for resource in required_resources):
        raise PackagingError("The Release app is missing a required license or localization resource.")

    try:
        signing = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], text=True, capture_output=True, check=False)
        signing_details = signing.stdout + signing.stderr
    except OSError as error:
        raise PackagingError("The Release signing metadata could not be inspected.") from error
    if "Signature=adhoc" in signing_details:
        signing_classification = "adhoc"
    elif "code object is not signed" in signing_details:
        signing_classification = "unsigned"
    else:
        raise PackagingError("Expected an unsigned or ad hoc local build; signing metadata was unexpected.")

    return {
        "bundlePath": str(app),
        "version": version,
        "build": build,
        "minimumOS": minimum_os,
        "architectures": sorted(architectures),
        "signing": {"classification": signing_classification, "details": signing_details.strip()},
        "resources": {
            "thirdPartyLicenses": True,
            "english": True,
            "simplifiedChinese": True,
        },
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="Resolved Git commit, tag, or ref to archive and build.")
    parser.add_argument("--output-directory", required=True, type=Path, help="Absolute, newly created output directory.")
    return parser.parse_args()


def main() -> int:
    options = parse_arguments()
    output = options.output_directory
    if not output.is_absolute():
        raise PackagingError("--output-directory must be absolute.")
    if output.exists():
        raise PackagingError("--output-directory must not already exist; no existing files were touched.")
    if not output.parent.is_dir():
        raise PackagingError("The parent of --output-directory must already exist.")
    try:
        output.mkdir(mode=0o700)
    except OSError as error:
        raise PackagingError("The output directory could not be created without overwriting anything.") from error

    toolchain = toolchain_snapshot()
    write_json(output / "toolchain.json", toolchain)
    try:
        commit = resolve_revision(options.revision)
        (output / "revision.txt").write_text(commit + "\n", encoding="utf-8")
        with tempfile.TemporaryDirectory(prefix="mira-local-package-") as temporary:
            temporary_root = Path(temporary)
            archive = temporary_root / "source.tar"
            with archive.open("wb") as stream:
                prefix = f"mira-source-{commit[:12]}/"
                subprocess.run(["git", "archive", "--format=tar", f"--prefix={prefix}", commit], cwd=ROOT, stdout=stream, stderr=subprocess.PIPE, check=True, text=False)
            source_parent = temporary_root / "source"
            source_parent.mkdir(mode=0o700)
            source = safe_extract_archive(archive, source_parent)
            derived_data = temporary_root / "DerivedData"
            build_log = output / "xcodebuild.log"
            build_argv = [
                "xcodebuild", "-project", "Mira.xcodeproj", "-scheme", "Mira",
                "-configuration", "Release", "-destination", "platform=macOS",
                "-derivedDataPath", str(derived_data), "-onlyUsePackageVersionsFromResolvedFile",
                "-disableAutomaticPackageResolution", "-skipMacroValidation",
                "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "ARCHS=arm64 x86_64",
                "ONLY_ACTIVE_ARCH=NO", "build",
            ]
            try:
                run(build_argv, cwd=source, output=build_log)
            except (OSError, subprocess.CalledProcessError) as error:
                raise PackagingError(f"Release build failed; see {build_log}.") from error
            app = derived_data / "Build/Products/Release/Mira.app"
            app_info = inspect_app(app, EXPECTED_ARCHITECTURES)
            zip_name = f"Mira-{app_info['version']}-{commit[:12]}-unsigned.zip"
            zip_path = output / zip_name
            try:
                run(["ditto", "-c", "-k", "--keepParent", str(app), str(zip_path)])
            except (OSError, subprocess.CalledProcessError) as error:
                raise PackagingError("The Release app ZIP could not be created.") from error
            zip_sha, zip_bytes = sha256_file(zip_path)
            unpacked = temporary_root / "unpacked"
            run(["ditto", "-x", "-k", str(zip_path), str(unpacked)])
            unpacked_app = unpacked / "Mira.app"
            inspect_app(unpacked_app, EXPECTED_ARCHITECTURES)
            original_digest = bundle_digest(app)
            if bundle_digest(unpacked_app) != original_digest:
                raise PackagingError("The extracted ZIP does not reproduce the verified app bundle.")
            manifest = {
                "formatVersion": 1,
                "revision": commit,
                "app": {key: value for key, value in app_info.items() if key != "bundlePath"},
                "architecturesRequested": sorted(EXPECTED_ARCHITECTURES),
                "bundleSHA256": original_digest,
                "exactSHA256": zip_sha,
                "zip": {"file": zip_name, "byteCount": zip_bytes, "sha256": zip_sha},
                "checks": {
                    "exactRevisionArchive": True,
                    "releaseBuild": True,
                    "architecture": app_info["architectures"] == sorted(EXPECTED_ARCHITECTURES),
                    "minimumOS": version_tuple(app_info["minimumOS"]) == MINIMUM_MACOS,
                    "zipExtractionParity": True,
                    "unsignedOrAdHoc": True,
                    "licenseResource": app_info["resources"]["thirdPartyLicenses"],
                    "localizationResources": app_info["resources"]["english"] and app_info["resources"]["simplifiedChinese"],
                    "noProviderLaunch": True,
                    "runtimeUI": "not_run_by_this_helper",
                },
                "toolchain": toolchain,
            }
            write_json(output / "manifest.json", manifest)
            (output / f"{zip_name}.sha256").write_text(f"{zip_sha}  {zip_name}\n", encoding="utf-8")
            print(json.dumps({"outputDirectory": str(output), "zip": str(zip_path), "sha256": zip_sha}, sort_keys=True))
    except PackagingError as error:
        (output / "error.txt").write_text(f"{error}\n", encoding="utf-8")
        print(f"package_local.py: {error}", file=sys.stderr)
        return 1
    except (OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        message = "Packaging failed; inspect the preserved output logs."
        (output / "error.txt").write_text(f"{message}\n{error}\n", encoding="utf-8")
        print(f"package_local.py: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PackagingError as error:
        print(f"package_local.py: {error}", file=sys.stderr)
        raise SystemExit(2)
