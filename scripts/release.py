"""Validate, assemble, and publish Rokit-compatible release assets (Python 3.11+)."""

import argparse
import hashlib
import re
import stat
import subprocess
import tomllib
import zipfile
from pathlib import Path

PLATFORMS = {
    "windows-x86_64": ("x86_64-pc-windows-msvc", ".exe"),
    "linux-x86_64": ("x86_64-unknown-linux-gnu", ""),
    "linux-aarch64": ("aarch64-unknown-linux-gnu", ""),
    "macos-x86_64": ("x86_64-apple-darwin", ""),
    "macos-aarch64": ("aarch64-apple-darwin", ""),
}
VERSION_PATTERN = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
)


def clean_tag(value: str) -> str:
    """Trim workflow input and accept full Git tag refs without changing tag spelling."""
    return value.strip().removeprefix("refs/tags/")


def normalize_version(value: str) -> str:
    """Ignore surrounding whitespace and v/V prefixes, preserving version suffixes."""
    version = clean_tag(value).lstrip("vV")
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"invalid release version {value!r}: expected MAJOR.MINOR.PATCH with an optional SemVer prerelease and v prefix")
    return version


def resolve_tag(root: Path, value: str) -> str:
    """Resolve equivalent version inputs to an actual local tag before checkout."""
    requested = clean_tag(value)
    version = normalize_version(requested)
    result = subprocess.run(
        ["git", "-C", str(root), "for-each-ref", "--format=%(refname:strip=2)", "refs/tags"],
        capture_output=True, text=True, check=True,
    )
    tags = result.stdout.splitlines()
    if requested in tags:
        return requested
    matches = []
    for tag in tags:
        try:
            if normalize_version(tag) == version:
                matches.append(tag)
        except ValueError:
            continue
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise ValueError(f"no existing Git tag matches version {version!r}; create and push that version tag first")
    raise ValueError(f"multiple Git tags match version {version!r}: {', '.join(matches)}; specify the exact tag")


def validate(root: Path, tag: str) -> str:
    version = normalize_version(tag)
    for filename in ("Cargo.toml", "imposter-render/wally.toml"):
        manifest = tomllib.loads((root / filename).read_text(encoding="utf-8"))
        actual = manifest["package"]["version"]
        if normalize_version(actual) != version:
            raise ValueError(f"{filename} declares {actual!r}, but release {tag!r} requires {version!r}")
    lock = tomllib.loads((root / "Cargo.lock").read_text(encoding="utf-8"))
    versions = [normalize_version(p["version"]) for p in lock["package"] if p["name"] == "imposter-baker"]
    if versions != [version]:
        raise ValueError(f"Cargo.lock contains imposter-baker versions {versions!r}, expected [{version!r}]; run cargo check")
    return version


def package(root: Path, tag: str, platform: str, output: Path) -> Path:
    version = validate(root, tag)
    target, extension = PLATFORMS[platform]
    name = "imposter-baker" + extension
    binary = root / "target" / target / "release" / name
    files = {name: binary, "LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    for source in files.values():
        if not source.is_file():
            raise ValueError(f"missing release input: {source}")
    output.mkdir(parents=True, exist_ok=True)
    path = output / f"imposter-baker-{version}-{platform}.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for archive_name, source in files.items():
            entry = zipfile.ZipInfo(archive_name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = 0o755 if archive_name == name else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, source.read_bytes())
    return path


def checksums(directory: Path, tag: str) -> Path:
    version = normalize_version(tag)
    expected = {f"imposter-baker-{version}-{p}.zip" for p in PLATFORMS}
    expected.update(("imposter-render.zip", "imposter-render.rbxm", "demo.rbxl"))
    actual = {p.name for p in directory.iterdir() if p.is_file() and p.name != "SHA256SUMS"}
    if actual != expected:
        raise ValueError(f"unexpected release assets: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    lines = []
    for name in sorted(expected):
        with (directory / name).open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        lines.append(f"{digest}  {name}\n")
    path = directory / "SHA256SUMS"
    path.write_text("".join(lines), encoding="utf-8", newline="\n")
    return path


def publish(root: Path, tag: str, directory: Path) -> None:
    tag = clean_tag(tag)
    version = validate(root, tag)
    checksums(directory, tag)
    assets = [str(path.resolve()) for path in sorted(directory.iterdir()) if path.is_file()]
    prerelease = "true" if "-" in version else "false"
    latest = "false" if prerelease == "true" else "true"
    existing = subprocess.run(
        ["gh", "release", "view", tag, "--json", "isDraft"],
        capture_output=True, text=True, check=False,
    )
    if existing.returncode == 0:
        # A release created in GitHub's UI can already be published before its
        # build finishes. Draft and published releases both accept these assets.
        subprocess.run(["gh", "release", "upload", tag, *assets, "--clobber"], check=True)
    else:
        subprocess.run(
            ["gh", "release", "create", tag, "--draft", "--verify-tag",
             f"--prerelease={prerelease}", "--title", tag, "--generate-notes", *assets],
            check=True,
        )
    subprocess.run(
        ["gh", "release", "edit", tag, "--draft=false", f"--prerelease={prerelease}", f"--latest={latest}"],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("validate")
    check.add_argument("tag")
    resolve = commands.add_parser("resolve", help="Resolve a version input to an existing Git tag")
    resolve.add_argument("tag")
    pack = commands.add_parser("package")
    pack.add_argument("tag")
    pack.add_argument("platform", choices=PLATFORMS)
    pack.add_argument("--output", type=Path, default=Path("dist"))
    sums = commands.add_parser("checksums")
    sums.add_argument("tag")
    sums.add_argument("directory", type=Path)
    upload = commands.add_parser("publish", help="Upload checked assets to a new or existing GitHub release")
    upload.add_argument("tag")
    upload.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            print(validate(args.root, args.tag))
        elif args.command == "resolve":
            print(resolve_tag(args.root, args.tag))
        elif args.command == "package":
            print(package(args.root, args.tag, args.platform, args.output))
        elif args.command == "checksums":
            print(checksums(args.directory, args.tag))
        else:
            publish(args.root, args.tag, args.directory)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
